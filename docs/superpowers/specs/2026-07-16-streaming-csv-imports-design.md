# Streaming CSV imports + bounded run report (ACC-215)

## Problem

Large CSV imports materialise everything in memory. A 6,377-row (~830KB)
import OOM-killed a 1GB staging machine and, once given 2GB, blocked the
caller for ~42s. Two library-side causes compound:

1. **Input is fully resident.** `Parser.parse/1` calls
   `NimbleCSV.RFC4180.parse_string/2`, turning the whole binary into a list of
   row-lists. No streaming path exists.
2. **All outcomes are retained for the life of the run.** `process_rows/7`
   accumulates one `%RowOutcome{}` per row and reverses the list (a second full
   copy). In `:commit` mode each outcome keeps the **entire created/updated Ash
   struct** (`record:`); in `:dry_run` it keeps the full `input` map. `RunReport`
   wraps the whole list. `import_csv/4`'s contract — "return a fully
   materialised `%RunReport{}`" — forces all of the above.

This is a v0.1.0 library. Breaking changes are acceptable, but ARCC is a live
consumer pinned at commit `9fd2a750`, so the migration path must be documented.

## Scope

This change fixes **memory**: the input is never fully resident and per-row
retention is bounded and O(1) in row count.

It does **not** change how rows are committed — commit stays per-row
`Ash.create/1`, so a large commit is still slow (N queries, N round-trips).
`Ash.bulk_create/2` (issue item 4) is explicitly **out of scope**: the target
actions combine `upsert?` with `manage_relationship` and custom non-atomic
changes and need per-resource verification. That work belongs with ARC-405
(durable Oban-backed commit). The PR/issue must state this so the change is not
mistaken for a full fix to the LiveView stall — the stall is addressed by
consumers moving commit to Oban and consuming rows via the new streaming API,
plus the future `bulk_create` pass.

## Design

The export side already models the shape we want: a lazy primitive
(`stream_export/2`, chunks) and a materialising convenience built on it
(`export_csv/2`). We mirror that on the import side:

- **`stream_import/3`** — the lazy primitive. Yields one `%RowOutcome{}` per
  non-blank data row, processed on demand. In `:commit` mode, DB writes happen
  as the stream is consumed. This is what enables progressive UI and
  Oban-chunked commits.
- **`import_csv/3`** — rebuilt as a bounded consumer of the internal event
  stream. Still returns `{:ok, %RunReport{}}`, but the report is now O(1) in
  row count: exact aggregate counts, a capped preview of outcomes, and no full
  Ash records retained by default.

### 1. Input sources

Both `import_csv/3` and `stream_import/3` accept a `source`:

- a **binary** — in-memory CSV (existing callers, small files)
- `{:path, path}` — the library opens the file itself; contents never fully
  resident
- an **`Enumerable`** of binary chunks that is not a binary (`File.Stream`,
  `Stream`, list of chunks) — caller-controlled source

A file path cannot be a bare string: a CSV binary is also a string, so paths
are tagged `{:path, _}` to disambiguate. Dispatch is by shape: `is_binary/1`
→ in-memory content; `{:path, p}` → file; otherwise treat as an Enumerable of
chunks.

**Constraint:** arbitrary Enumerable sources must be **re-enumerable**
(`File.Stream`, lists, `Stream` built over re-runnable producers). One-shot
sources (e.g. a consumed network body) are not supported — callers wrap them
to `{:path, _}` first. This is documented in `usage-rules.md`.

### 2. Parser: eager header, lazy body

The header row must be read eagerly for two reasons: the existing comma-header
preprocessing operates on the first physical line, and fatal errors
(`:empty_file`, `:missing_required_headers`, `:duplicate_headers`) must still
return `{:error, %Error{}}` **synchronously** before any row processing (a
contract the current tests assert). Everything after the header stays lazy.

`Parser` gains a streaming entry point that:

1. Reads only the first physical line (header) from the source.
2. Applies the existing unquoted-comma-header fix to that line, then parses it
   alone with `parse_string` → the header row.
3. Streams the remaining bytes through `NimbleCSV.RFC4180.parse_stream/2`,
   consumed lazily as `%RowOutcome{}`s are pulled.

Per-source "first line eager, rest lazy":

- **file path** — `File.open!` + `IO.read(file, :line)` for the header, then
  `IO.stream(file, :line)` for the body. Single pass; the handle stays
  positioned after the header. `:line` mode preserves the trailing newline, so
  quoted multi-line fields still parse correctly across the body stream.
- **binary** — split on the first newline (the whole binary is already
  resident; this adds no materialisation).
- **arbitrary re-enumerable stream** — take the first parsed row for the
  header, stream the rest with `skip_headers: true`. This re-reads the source
  (no full materialisation), which is why one-shot sources are unsupported.

Newlines are preserved throughout — no path strips them — so RFC-4180 quoted
fields containing newlines parse identically to the current binary path.

`Parser.parse/1` (binary → eager list) is retained for the in-memory path and
existing callers/tests.

### 3. Error handling on the streaming path

- **Binary path** keeps its upfront `String.valid?/1` UTF-8 check and its
  `NimbleCSV.ParseError` rescue, unchanged.
- **Streaming path** validates UTF-8 per row lazily; an invalid chunk or a
  malformed-CSV parse error raises at *consumption* time — the same model as
  `stream_export/2`, where a partial result is worse than a hard failure.
  - `stream_import/3` lets these propagate to the consumer (documented).
  - `import_csv/3` wraps its fold in a rescue that converts a
    `NimbleCSV.ParseError` / encoding failure surfaced during consumption back
    into `{:error, %Error{kind: :malformed_csv | :encoding}}`, preserving its
    current contract.

### 4. `stream_import/3`

```elixir
{:ok, %AshCsvInterchange.Import.StreamReport{
   warnings: [%Error{kind: :unknown_column} | _],
   source_headers: ["external_id", "name", ...],
   input_keys: %{"external_id" => :external_id, ...},
   outcomes: #Stream<...>   # lazy, one %RowOutcome{} per non-blank data row
}} = AshCsvInterchange.stream_import(:contacts, {:path, path}, mode: :commit)
```

Warnings, source headers, and input keys are all known at setup (from the
header check, which is eager), so they are returned eagerly in a small
`%StreamReport{}` struct alongside the lazy `outcomes` stream. Fatal errors
return `{:error, %Error{}}` synchronously, before the struct.

- Blank rows are **filtered** from `outcomes` (aggregate blank counting belongs
  to the bounded report, §5). Streaming callers see one element per real row.
- `%RowOutcome{}` is unchanged in shape. Whether `record` is populated in
  `:commit` mode follows the same `retain_records?` option as the report
  (default `false`; see §5).
- Options mirror `import_csv/3`: `:mode`, `:actor`, `:tenant`, `:authorize?`,
  `:scope`, `:retain_records?`.

`AshCsvInterchange.stream_import/3` resolves the type via `fetch_import_type/1`
then delegates to `Orchestrator.stream_import/4`, mirroring the existing
`import_csv` delegation.

### 5. Bounded `RunReport`

`import_csv/3` still returns `{:ok, %RunReport{}}`, built by folding an
**internal tagged event stream** (`{:outcome, %RowOutcome{}}` | `{:blank,
line_no}`) so that blank rows can be counted without being surfaced by
`stream_import`. `stream_import`'s public `outcomes` stream is this internal
stream with blanks filtered and tags removed.

`RunReport` fields:

- `counts` — **full and exact.** Tallied over every row (cheap; integers only).
  Unchanged shape (`Counts`).
- `outcomes` — capped at `:max_outcomes` (default **100**). Rows beyond the cap
  are counted but not retained. Serves preview/inspection.
- `outcomes_truncated?` — **new** boolean; `true` when the row count exceeded
  the cap.
- `warnings`, `source_headers`, `input_keys` — unchanged.

Options on `import_csv/3`:

- `:max_outcomes` (default `100`) — size of the retained preview window.
- `:retain_records?` (default `false`) — when `false`, `:commit` outcomes drop
  the full Ash `record` (they keep `line_no`, `status`, `upsert_kind`). When
  `true`, retained outcomes carry `record` — but only within the cap, so
  retention stays bounded either way.

**Behaviour change / migration:** callers that iterated *every* outcome (e.g.
building an error-CSV export of all failures) must move to `stream_import/3`
and collect with their own bound — the report is a bounded preview, not a
complete log. Callers that inspected `record` must pass `retain_records?:
true`. Both are documented in `usage-rules.md`; the report change is why this
lands as a new API (`stream_import`) alongside a bounded `import_csv` rather
than a silent in-place change.

### 6. Module layout

- `lib/ash_csv_interchange/import/parser.ex` — add the streaming entry point;
  keep `parse/1`.
- `lib/ash_csv_interchange/import/orchestrator.ex` — add `stream_import/4`
  (builds the internal tagged stream + setup metadata); rebuild `import_csv/4`
  as a bounded fold over it. Row processing (`process_row`, `build_input`,
  `apply_import_source`, outcome builders) is shared between both paths.
- `lib/ash_csv_interchange/import/stream_report.ex` — **new** `%StreamReport{}`
  struct (`warnings`, `source_headers`, `input_keys`, `outcomes`).
- `lib/ash_csv_interchange/import/run_report.ex` — add `outcomes_truncated?`;
  `counts_from_outcomes/2` is superseded by counts tallied during the fold (the
  full list no longer exists to reduce over).
- `lib/ash_csv_interchange.ex` — add public `stream_import/3`; extend
  `import_csv/3`'s typespec/docs for the new `source` union and options.

## Testing

The load-bearing property — memory is **O(1) in row count** — is verified
deterministically wherever possible, with a single true memory-measuring test
quarantined behind a tag so it cannot flake the main suite.

**Layer 1 — infinite-source laziness (default suite).** Feed an unbounded lazy
source and consume only a few rows:

```elixir
rows = Stream.iterate(1, &(&1 + 1)) |> Stream.map(&"id#{&1},N#{&1},2020-01-01\n")
source = Stream.concat(["external_id,name,date_of_birth\n"], rows)
{:ok, %{outcomes: outcomes}} = AshCsvInterchange.stream_import(:test, source, mode: :dry_run)
assert outcomes |> Stream.take(5) |> Enum.count() == 5
```

If any stage materialises the whole input, this hangs/OOMs; if truly lazy, it
returns immediately. The crispest regression guard against reintroducing
`parse_string` or an accumulating reduce. A `:commit`-mode variant asserts
exactly N `Ash.create`s occurred.

**Layer 2 — pull-counting back-pressure (default suite).** Wrap the source so
each chunk pulled increments an ETS/Agent counter. Consume 10 outcomes; assert
the source was pulled only enough for ~10 rows, not the whole file. Proves
consumption drives reading.

**Layer 3 — bounded-report retention (default suite).** Generate ~10k rows
(well over `max_outcomes`), run `import_csv`; assert `counts.total == 10_000`
(exact), `length(report.outcomes) == 100`, `report.outcomes_truncated?`, and no
`record` retained by default. Proves report size is O(1) in row count.

**Layer 4 — O(1) memory profile (`@tag :memory`, excluded from default run).**
Generate temp CSVs *lazily to disk* (the test never holds them) at 10k and 100k
rows. Run a dry-run import inside a spawned worker pid while a sampler polls
`Process.info(pid, :memory)` and tracks the peak. Assert `peak(100k) <
peak(10k) * 2` — a **ratio**, not an absolute byte threshold, so it encodes
"memory does not scale with input size" without a brittle MB limit. Dry-run is
used so the ETS data layer adds no noise (ETS storage is off the process heap,
which also cleanly isolates library retention from the data store).

- `test/test_helper.exs`: `ExUnit.configure(exclude: [:memory])` so `mix test`
  (and therefore `mix check`) skips layer 4.
- `.github/workflows/elixir.yml`: a new `memory` job (parallel to `check`) that
  runs `mix test --only memory`.

**Functional coverage (default suite).** All three source shapes (binary,
`{:path, _}`, chunk stream) produce identical outcomes; the comma-header fix
still works through the streaming path; malformed/invalid-UTF-8 input yields
`{:error, _}` from `import_csv` and a consumption-time raise from
`stream_import`; blank-row skipping and line numbering preserved; warnings and
setup metadata returned by `stream_import`. Existing commit tests that inspect
`record` gain `retain_records?: true` (expected churn from the item-3 default
flip).

## Docs

- `usage-rules.md`: document `stream_import/3`, the `source` union, the
  re-enumerable constraint, and a "prefer `stream_import` for large files" note
  mirroring the existing export anti-pattern; note the `import_csv` report is a
  bounded preview.
- `README.md`: add a `stream_import` example alongside the existing ones.
- Public `@doc`s / `@spec`s on the new and changed functions.

## Out of scope

- `Ash.bulk_create/2` batching (issue item 4 → ARC-405).
- Any change to per-row commit semantics, upsert behaviour, or the DSL.
- Consumer-side (ARCC) changes: bounded preview, Oban commit.
