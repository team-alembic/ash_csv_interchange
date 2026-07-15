# Streaming CSV Imports Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make CSV imports stream so the input is never fully resident and per-row retention is O(1) in row count, fixing the OOM described in ACC-215.

**Architecture:** Mirror the export side. Add a lazy primitive `stream_import/3` that yields one `%RowOutcome{}` per non-blank data row (DB writes happen as the stream is consumed), and rebuild `import_csv/3` as a bounded consumer that returns a `%RunReport{}` with exact aggregate counts but a capped preview of outcomes and no full Ash records retained by default. The parser reads only the header line eagerly (so fatal errors stay synchronous) and streams the body via `NimbleCSV.RFC4180.parse_stream/2`.

**Tech Stack:** Elixir, Ash, Spark DSL, NimbleCSV 1.3, ExUnit, Ash.DataLayer.Ets (test fixtures).

## Global Constraints

- Elixir/OTP as pinned in `.tool-versions`; CI compiles with `--warnings-as-errors` — **no compiler warnings**.
- Every module has `@moduledoc` (or `@moduledoc false`); every **public** function has `@doc` and `@spec` — `mix doctor --full --raise` gates this.
- `mix format` and `mix credo --strict` must pass before every commit.
- Prefer pattern matching and `with` over nested `case`/`if`. `snake_case` vars, `CamelCase` modules. Comments only when the *why* is non-obvious.
- Commit messages follow Conventional Commits (`feat:`, `fix:`, `test:`, `docs:`, `refactor:`). **Never** add `Co-Authored-By` lines. **Never** edit `CHANGELOG.md` by hand.
- Keep the public API small, documented, backwards-compatible where the design allows. This is v0.1.0 — the deliberate behaviour changes in Task 3 (bounded report, `record` dropped by default) are permitted and documented.
- **Out of scope:** `Ash.bulk_create/2` (issue item 4 → ARC-405); any change to per-row commit/upsert semantics or the DSL.

## File Structure

- `lib/ash_csv_interchange/import/parser.ex` — **modify.** Keep `parse/1` (binary → eager list). Add `parse_stream/2` (source → `{header_row, lazy_body_stream}`), source normalisation, first-line read + BOM strip, comma-header fix (moved here from the orchestrator), lazy per-row UTF-8 validation. Add nested `Parser.StreamError` exception.
- `lib/ash_csv_interchange/import/stream_report.ex` — **create.** `%StreamReport{}` returned by `stream_import`: eager `warnings`/`source_headers`/`input_keys` + lazy `outcomes` stream.
- `lib/ash_csv_interchange/import/run_report.ex` — **modify.** Add `outcomes_truncated?` field. Keep `counts_from_outcomes/2` (now used by callers folding a full stream, no longer by the lib internally).
- `lib/ash_csv_interchange/import/row_outcome.ex` — unchanged (shape stays the same; `record` is simply left `nil` unless retained).
- `lib/ash_csv_interchange/import/orchestrator.ex` — **modify.** Add `stream_import/4`; rebuild `import_csv/4` as a bounded fold; extract shared `stream_events/4` + per-row processing; move comma-header helpers out to the parser; tally counts incrementally.
- `lib/ash_csv_interchange.ex` — **modify.** Add public `stream_import/3`; widen `import_csv/3` to the `source` union; add `@type source`.
- `test/test_helper.exs` — **modify.** Exclude `:memory` tag from the default run.
- `test/ash_csv_interchange/parser_test.exs` — **modify.** Streaming-parse tests.
- `test/ash_csv_interchange/stream_import_test.exs` — **create.** Orchestrator-level streaming/bounded/laziness tests.
- `test/ash_csv_interchange/import_memory_test.exs` — **create.** `@moduletag :memory` O(1)-memory profile.
- `test/ash_csv_interchange/orchestrator_test.exs` — **modify.** Add `retain_records?: true` to the record-inspecting commit tests.
- `test/ash_csv_interchange_test.exs` — **modify.** Public-API integration tests for `stream_import/3` and `import_csv/3` source variants.
- `.github/workflows/elixir.yml` — **modify.** Add a `memory` job running `mix test --only memory`.
- `usage-rules.md`, `README.md` — **modify.** Document the streaming API, the source union, the re-enumerable constraint, and the bounded-report behaviour.

---

## Task 1: Streaming parser

**Files:**
- Modify: `lib/ash_csv_interchange/import/parser.ex`
- Test: `test/ash_csv_interchange/parser_test.exs`

**Interfaces:**
- Consumes: `AshCsvInterchange.Error`, `AshCsvInterchange.Import.Headers.column_name/1`.
- Produces:
  - `AshCsvInterchange.Import.Parser.parse_stream(source, headers_config) :: {:ok, {[String.t()], Enumerable.t()}} | {:error, Error.t()}` where `source :: binary() | {:path, Path.t()} | Enumerable.t()` and `headers_config` is the `[required: [...], optional: [...]]` keyword list. The second tuple element is a **lazy** stream of data rows (each a `[String.t()]`), header excluded.
  - `AshCsvInterchange.Import.Parser.StreamError` — exception raised at stream-consumption time for invalid UTF-8, carrying `:error` (`Error.t()`).

- [ ] **Step 1: Write the failing tests**

Append to `test/ash_csv_interchange/parser_test.exs` (inside the existing `defmodule AshCsvInterchange.ParserTest`):

```elixir
  describe "parse_stream/2" do
    @headers [required: ["external_id", "name"], optional: []]

    test "parses a binary: header eager, body lazy" do
      csv = "external_id,name\nE1,Alice\nE2,Bob\n"

      assert {:ok, {["external_id", "name"], body}} =
               Parser.parse_stream(csv, @headers)

      assert Enum.to_list(body) == [["E1", "Alice"], ["E2", "Bob"]]
    end

    test "parses from a {:path, _} source" do
      path = Path.join(System.tmp_dir!(), "acc215_parse_#{System.unique_integer([:positive])}.csv")
      File.write!(path, "external_id,name\nE1,Alice\n")
      on_exit(fn -> File.rm(path) end)

      assert {:ok, {["external_id", "name"], body}} =
               Parser.parse_stream({:path, path}, @headers)

      assert Enum.to_list(body) == [["E1", "Alice"]]
    end

    test "parses from an arbitrary chunk stream" do
      chunks = ["external_id,na", "me\nE1,Ali", "ce\n"]

      assert {:ok, {["external_id", "name"], body}} =
               Parser.parse_stream(chunks, @headers)

      assert Enum.to_list(body) == [["E1", "Alice"]]
    end

    test "strips a leading UTF-8 BOM from the header" do
      csv = <<0xEF, 0xBB, 0xBF>> <> "external_id,name\nE1,Alice\n"

      assert {:ok, {["external_id", "name"], _body}} =
               Parser.parse_stream(csv, @headers)
    end

    test "is lazy: an unbounded source yields rows on demand" do
      rows = Stream.map(Stream.iterate(1, &(&1 + 1)), &"E#{&1},N#{&1}\n")
      source = Stream.concat(["external_id,name\n"], rows)

      assert {:ok, {_header, body}} = Parser.parse_stream(source, @headers)
      assert body |> Stream.take(3) |> Enum.to_list() == [["E1", "N1"], ["E2", "N2"], ["E3", "N3"]]
    end

    test "returns :empty_file for empty input" do
      assert {:error, %Error{kind: :empty_file}} = Parser.parse_stream("", @headers)
    end

    test "auto-quotes a declared comma-containing header before parsing it" do
      headers = [required: ["external_id", {"a,b", :ab}], optional: []]
      csv = "external_id,a,b\nE1,X\n"

      assert {:ok, {["external_id", "a,b"], _body}} = Parser.parse_stream(csv, headers)
    end

    test "raises StreamError on invalid UTF-8 in a data row when consumed" do
      csv = "external_id,name\nE1," <> <<0xFF, 0xFE>> <> "\n"

      assert {:ok, {_header, body}} = Parser.parse_stream(csv, @headers)

      assert_raise Parser.StreamError, fn -> Enum.to_list(body) end
    end
  end
```

Ensure the module aliases `Error` at the top of the test file:

```elixir
  alias AshCsvInterchange.Error
  alias AshCsvInterchange.Import.Parser
```
(Add whichever alias is missing; `Parser` is almost certainly already aliased.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/ash_csv_interchange/parser_test.exs`
Expected: FAIL — `parse_stream/2` is undefined.

- [ ] **Step 3: Implement `parse_stream/2` and helpers**

Replace the entire contents of `lib/ash_csv_interchange/import/parser.ex` with:

```elixir
defmodule AshCsvInterchange.Import.Parser do
  @moduledoc """
  RFC 4180 CSV parser with an eager binary path and a streaming path.

  `parse/1` parses a whole binary into a list of rows. `parse_stream/2`
  reads only the header line eagerly — so fatal header/encoding errors
  surface synchronously — and returns the remaining data rows as a lazy
  stream backed by `NimbleCSV.RFC4180.parse_stream/2`.

  Streaming sources may be a binary, a `{:path, path}` tuple (the file is
  opened by the parser), or any **re-enumerable** `Enumerable` of binary
  chunks. One-shot sources are not supported: the header is read by
  enumerating the source once, and the body re-enumerates it.
  """

  alias AshCsvInterchange.Error
  alias AshCsvInterchange.Import.Headers

  defmodule StreamError do
    @moduledoc false
    defexception [:error]

    @impl true
    def message(%__MODULE__{error: %Error{message: message}}), do: message
  end

  @utf8_bom <<0xEF, 0xBB, 0xBF>>

  @type source :: binary() | {:path, Path.t()} | Enumerable.t()

  @doc """
  Parses a CSV binary into a list of row lists. Returns a fatal error
  for invalid UTF-8 or malformed CSV (e.g. unterminated quotes).
  """
  @spec parse(binary()) :: {:ok, [[String.t()]]} | {:error, Error.t()}
  def parse(@utf8_bom <> rest), do: parse(rest)

  def parse(binary) when is_binary(binary) do
    if String.valid?(binary) do
      try do
        {:ok, NimbleCSV.RFC4180.parse_string(binary, skip_headers: false)}
      rescue
        e in NimbleCSV.ParseError ->
          {:error, %Error{kind: :malformed_csv, message: Exception.message(e)}}
      end
    else
      {:error, %Error{kind: :encoding, message: "Input is not valid UTF-8"}}
    end
  end

  @doc """
  Reads the header line eagerly and returns the remaining data rows as a
  lazy stream.

  Returns `{:ok, {header_row, body}}` where `header_row` is a list of
  column strings and `body` is a lazy `Enumerable` of data rows (each a
  list of strings), header excluded. Returns `{:error, %Error{}}` for an
  empty file or a malformed header line.

  Invalid UTF-8 in a *data* row is not detected here; it raises
  `#{inspect(__MODULE__)}.StreamError` when the body stream is consumed,
  mirroring how the export side propagates mid-stream failures.
  """
  @spec parse_stream(source(), keyword()) ::
          {:ok, {[String.t()], Enumerable.t()}} | {:error, Error.t()}
  def parse_stream(source, headers_config) do
    chunks = to_chunks(source)

    with {:ok, first_line} <- read_first_line(chunks),
         {:ok, header_row} <- parse_header(first_line, headers_config) do
      body =
        chunks
        |> NimbleCSV.RFC4180.parse_stream(skip_headers: true)
        |> Stream.map(&validate_row!/1)

      {:ok, {header_row, body}}
    end
  end

  defp to_chunks(binary) when is_binary(binary), do: [binary]
  defp to_chunks({:path, path}), do: File.stream!(path)
  defp to_chunks(enum), do: enum

  defp read_first_line(chunks) do
    first =
      Enum.reduce_while(chunks, "", fn chunk, acc ->
        combined = acc <> chunk

        case :binary.split(combined, ["\r\n", "\n"]) do
          [line, _rest] -> {:halt, line}
          [partial] -> {:cont, partial}
        end
      end)

    case strip_bom(first) do
      "" -> {:error, %Error{kind: :empty_file, message: "CSV file has no header row"}}
      line -> {:ok, line}
    end
  end

  defp strip_bom(@utf8_bom <> rest), do: rest
  defp strip_bom(other), do: other

  defp parse_header(first_line, headers_config) do
    fixed = quote_known_comma_headers(first_line, comma_headers(headers_config))

    try do
      case NimbleCSV.RFC4180.parse_string(fixed, skip_headers: false) do
        [header_row | _] -> {:ok, header_row}
        [] -> {:error, %Error{kind: :empty_file, message: "CSV file has no header row"}}
      end
    rescue
      e in NimbleCSV.ParseError ->
        {:error, %Error{kind: :malformed_csv, message: Exception.message(e)}}
    end
  end

  defp validate_row!(fields) do
    if Enum.all?(fields, &String.valid?/1) do
      fields
    else
      raise StreamError, error: %Error{kind: :encoding, message: "Input is not valid UTF-8"}
    end
  end

  # Real-world exports (e.g. WellSky) sometimes emit headers that contain
  # commas without RFC 4180 quoting, which would split the column into
  # fragments at parse time. When a declared header contains a comma,
  # locate it (case-insensitively) in the raw header line and wrap it in
  # double quotes so NimbleCSV treats it as a single field.
  defp comma_headers(headers_config) do
    (headers_config[:required] ++ headers_config[:optional])
    |> Enum.map(&Headers.column_name/1)
    |> Enum.filter(&String.contains?(&1, ","))
  end

  defp quote_known_comma_headers(line, []), do: line

  defp quote_known_comma_headers(line, comma_headers) do
    Enum.reduce(comma_headers, line, &quote_header_if_present/2)
  end

  defp quote_header_if_present(declared, line) do
    if String.contains?(line, ~s("#{declared}")) do
      # Already quoted — leave it alone.
      line
    else
      pattern = Regex.compile!(Regex.escape(declared), "i")

      case Regex.run(pattern, line, return: :index) do
        [{start, length}] ->
          prefix = binary_part(line, 0, start)
          matched = binary_part(line, start, length)
          suffix_start = start + length
          suffix = binary_part(line, suffix_start, byte_size(line) - suffix_start)
          prefix <> ~s("#{matched}") <> suffix

        nil ->
          line
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/ash_csv_interchange/parser_test.exs`
Expected: PASS (existing `parse/1` tests plus the new `parse_stream/2` describe block).

- [ ] **Step 5: Format, then commit**

```bash
mix format
git add lib/ash_csv_interchange/import/parser.ex test/ash_csv_interchange/parser_test.exs
git commit -m "feat: add streaming parse_stream/2 to the CSV parser"
```

---

## Task 2: StreamReport struct + Orchestrator.stream_import/4

**Files:**
- Create: `lib/ash_csv_interchange/import/stream_report.ex`
- Modify: `lib/ash_csv_interchange/import/orchestrator.ex`
- Test: `test/ash_csv_interchange/stream_import_test.exs`

**Interfaces:**
- Consumes: `Parser.parse_stream/2` (Task 1), `HeaderCheck.verify/2`, `RowOutcome`, `Error`, `AshCsvInterchange.Info`.
- Produces:
  - `%AshCsvInterchange.Import.StreamReport{warnings: [Error.t()], source_headers: [String.t()], input_keys: %{String.t() => atom()}, outcomes: Enumerable.t()}`.
  - `AshCsvInterchange.Import.Orchestrator.stream_import(resource, id, source, opts) :: {:ok, StreamReport.t()} | {:error, Error.t()}`. `outcomes` yields one `%RowOutcome{}` per non-blank data row, lazily; blank rows are filtered. Options: `:mode` (`:dry_run` default / `:commit`), `:actor`, `:tenant`, `:authorize?`, `:scope`, `:retain_records?` (default `false`).
  - Private `stream_events/4` returning `{:ok, {type, warnings, header_row, input_keys, events}} | {:error, Error.t()}`, where `events` is a lazy stream of `{:outcome, RowOutcome.t()} | {:blank, pos_integer()}`. Consumed by `import_csv/4` in Task 3.

- [ ] **Step 1: Create the StreamReport struct**

Create `lib/ash_csv_interchange/import/stream_report.ex`:

```elixir
defmodule AshCsvInterchange.Import.StreamReport do
  @moduledoc """
  Result of `AshCsvInterchange.stream_import/3`.

  Setup metadata (`warnings`, `source_headers`, `input_keys`) is known
  after the header check and is returned eagerly. `outcomes` is a **lazy**
  stream of `%AshCsvInterchange.Import.RowOutcome{}` — one per non-blank
  data row. In `:commit` mode the underlying database writes happen as the
  stream is consumed. Blank rows are filtered from `outcomes`; aggregate
  counts (including blanks) are the domain of `import_csv/3`'s
  `%RunReport{}`.
  """

  alias AshCsvInterchange.Error

  @enforce_keys [:warnings, :source_headers, :input_keys, :outcomes]
  defstruct [:warnings, :source_headers, :input_keys, :outcomes]

  @type t :: %__MODULE__{
          warnings: [Error.t()],
          source_headers: [String.t()],
          input_keys: %{String.t() => atom()},
          outcomes: Enumerable.t()
        }
end
```

- [ ] **Step 2: Write the failing tests**

Create `test/ash_csv_interchange/stream_import_test.exs`:

```elixir
defmodule AshCsvInterchange.Import.StreamImportTest do
  use ExUnit.Case, async: false

  alias AshCsvInterchange.{Error, TestResource}
  alias AshCsvInterchange.Import.{Orchestrator, RowOutcome, StreamReport}

  describe "stream_import/4" do
    test "yields one lazy RowOutcome per non-blank row and returns setup metadata" do
      csv = "external_id,name,date_of_birth\nE1,Alice,2020-01-15\nE2,Bob,2019-03-22\n"

      assert {:ok, %StreamReport{outcomes: outcomes} = report} =
               Orchestrator.stream_import(TestResource, :test_resource, csv, mode: :dry_run)

      assert report.source_headers == ["external_id", "name", "date_of_birth"]
      assert report.warnings == []

      assert [
               %RowOutcome{line_no: 2, status: :ok},
               %RowOutcome{line_no: 3, status: :ok}
             ] = Enum.to_list(outcomes)
    end

    test "filters blank rows but preserves following line numbers" do
      csv = "external_id,name,date_of_birth\nE1,Alice,2020-01-15\n,,\nE2,Bob,2019-03-22\n"

      assert {:ok, %StreamReport{outcomes: outcomes}} =
               Orchestrator.stream_import(TestResource, :test_resource, csv, mode: :dry_run)

      assert [%RowOutcome{line_no: 2}, %RowOutcome{line_no: 4}] = Enum.to_list(outcomes)
    end

    test "is lazy: an unbounded source commits only the rows consumed" do
      rows = Stream.map(Stream.iterate(1, &(&1 + 1)), &"E#{&1},N#{&1},2020-01-01\n")
      source = Stream.concat(["external_id,name,date_of_birth\n"], rows)

      assert {:ok, %StreamReport{outcomes: outcomes}} =
               Orchestrator.stream_import(TestResource, :test_resource, source, mode: :commit)

      taken = outcomes |> Stream.take(5) |> Enum.to_list()

      assert length(taken) == 5
      assert Enum.all?(taken, &(&1.status == :ok))
      assert {:ok, persisted} = Ash.read(TestResource)
      assert length(persisted) == 5
    end

    test "does not retain the Ash record by default in commit mode" do
      csv = "external_id,name,date_of_birth\nE1,Alice,2020-01-15\n"

      assert {:ok, %StreamReport{outcomes: outcomes}} =
               Orchestrator.stream_import(TestResource, :test_resource, csv, mode: :commit)

      assert [%RowOutcome{status: :ok, record: nil, upsert_kind: :created}] = Enum.to_list(outcomes)
    end

    test "retains the record when retain_records?: true" do
      csv = "external_id,name,date_of_birth\nE1,Alice,2020-01-15\n"

      assert {:ok, %StreamReport{outcomes: outcomes}} =
               Orchestrator.stream_import(TestResource, :test_resource, csv,
                 mode: :commit,
                 retain_records?: true
               )

      assert [%RowOutcome{record: record}] = Enum.to_list(outcomes)
      assert record.external_id == "E1"
    end

    test "emits unknown-column warnings in the stream report" do
      csv = "external_id,name,date_of_birth,extra\nE1,Alice,2020-01-15,boo\n"

      assert {:ok, %StreamReport{warnings: [warning]}} =
               Orchestrator.stream_import(TestResource, :test_resource, csv, mode: :dry_run)

      assert warning.kind == :unknown_column
      assert warning.context.header == "extra"
    end

    test "returns fatal errors synchronously before any streaming" do
      assert {:error, %Error{kind: :empty_file}} =
               Orchestrator.stream_import(TestResource, :test_resource, "", mode: :dry_run)

      assert {:error, %Error{kind: :missing_required_headers}} =
               Orchestrator.stream_import(TestResource, :test_resource, "name\nAlice\n", mode: :dry_run)
    end
  end
end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `mix test test/ash_csv_interchange/stream_import_test.exs`
Expected: FAIL — `Orchestrator.stream_import/4` is undefined.

- [ ] **Step 4: Refactor the orchestrator and add `stream_import/4`**

In `lib/ash_csv_interchange/import/orchestrator.ex`:

a) Update the alias line to add `StreamReport` and `RunReport.Counts`, and alias the parser (already aliased). The alias block becomes:

```elixir
  alias AshCsvInterchange.{Error, Info}
  alias AshCsvInterchange.Import.{HeaderCheck, Headers, Parser, RowOutcome, RunReport, StreamReport}
  alias AshCsvInterchange.Import.RunReport.Counts

  @ash_forwarded_opts [:actor, :tenant, :authorize?, :scope]
  @default_max_outcomes 100
```

b) Add the new `stream_import/4` public function and the shared private `stream_events/4` and `event_stream/8`. Insert `stream_import/4` immediately after the existing `import_csv/4` (which Task 3 rewrites). For now, add these:

```elixir
  @doc """
  Streams a CSV import as a lazy sequence of per-row outcomes.

  Reads the header eagerly (fatal header/encoding errors return
  `{:error, %Error{}}` synchronously), then returns a
  `%AshCsvInterchange.Import.StreamReport{}` whose `outcomes` field is a
  lazy stream of `%RowOutcome{}` — one per non-blank data row. In
  `:commit` mode, database writes happen as the stream is consumed.

  Accepts the same `source` shapes and options as `import_csv/4`, plus
  `:retain_records?` (default `false`) controlling whether committed
  outcomes carry the full Ash `record`.
  """
  @spec stream_import(module(), atom(), Parser.source(), keyword()) ::
          {:ok, StreamReport.t()} | {:error, Error.t()}
  def stream_import(resource, id, source, opts \\ []) when is_atom(resource) and is_atom(id) do
    with {:ok, {_type, warnings, header_row, input_keys, events}} <-
           stream_events(resource, id, source, opts) do
      outcomes =
        Stream.flat_map(events, fn
          {:outcome, outcome} -> [outcome]
          {:blank, _line_no} -> []
        end)

      {:ok,
       %StreamReport{
         warnings: warnings,
         source_headers: header_row,
         input_keys: input_keys,
         outcomes: outcomes
       }}
    end
  end

  defp stream_events(resource, id, source, opts) do
    mode = Keyword.get(opts, :mode, :dry_run)
    ash_opts = Keyword.take(opts, @ash_forwarded_opts)
    retain_records? = Keyword.get(opts, :retain_records?, false)

    with {:ok, type} <- fetch_type(resource, id),
         {:ok, {header_row, body}} <- Parser.parse_stream(source, type.headers),
         {:ok, %{headers: headers, warnings: warnings}} <-
           HeaderCheck.verify(header_row, type.headers) do
      input_keys = build_input_keys(type.headers)

      events =
        event_stream(body, headers, input_keys, type, resource, mode, ash_opts, retain_records?)

      {:ok, {type, warnings, header_row, input_keys, events}}
    end
  end

  defp event_stream(body, headers, input_keys, type, resource, mode, ash_opts, retain_records?) do
    body
    |> Stream.with_index(2)
    |> Stream.map(fn {row, line_no} ->
      if blank_row?(row) do
        {:blank, line_no}
      else
        {:outcome,
         process_row(row, line_no, headers, input_keys, type, resource, mode, ash_opts, retain_records?)}
      end
    end)
  end
```

c) Update `process_row` and `commit_outcome` to thread `retain_records?`. Replace the existing `process_row/8` and `commit_outcome/3` definitions with:

```elixir
  defp process_row(row, line_no, headers, input_keys, type, resource, mode, ash_opts, retain_records?) do
    input = build_input(row, headers, input_keys)

    try do
      changeset =
        resource
        |> Ash.Changeset.for_create(type.upsert_action, input, ash_opts)
        |> apply_import_source(type.import_source)

      case mode do
        :dry_run -> dry_run_outcome(changeset, line_no, input)
        :commit -> commit_outcome(changeset, line_no, input, retain_records?)
      end
    rescue
      exception ->
        %RowOutcome{
          line_no: line_no,
          status: :crashed,
          errors: [
            %Error{
              kind: :transform_crashed,
              message: Exception.message(exception),
              context: %{exception: inspect(exception.__struct__)}
            }
          ],
          input: input
        }
    end
  end
```

```elixir
  defp commit_outcome(changeset, line_no, input, retain_records?) do
    case Ash.create(changeset) do
      {:ok, record} ->
        %RowOutcome{
          line_no: line_no,
          status: :ok,
          upsert_kind: upsert_kind(record),
          record: if(retain_records?, do: record, else: nil),
          input: input
        }

      {:error, error} ->
        %RowOutcome{
          line_no: line_no,
          status: :errored,
          errors: List.wrap(error),
          input: input
        }
    end
  end
```

d) Delete the now-unused `process_rows/7` (Task 3 replaces its caller) and the comma-header helpers that moved to the parser. Remove these private functions from the orchestrator: `process_rows/7`, `preprocess_unquoted_headers/2`, `quote_known_comma_headers/2`, `quote_header_if_present/2`. Keep `blank_row?/1`, `build_input/3`, `build_input_keys/1`, `apply_import_source/2`, `dry_run_outcome/3`, `upsert_kind/1`, `classify/1`, `fetch_type/2`, `pull_header_row/1` (see Task 3 note).

> Note: `import_csv/4` still references `process_rows`/`preprocess_unquoted_headers` until Task 3. To keep the tree compiling **and** commit this task independently, do Step 4e.

e) Temporarily bridge `import_csv/4` onto the new machinery so the module compiles and existing tests keep passing. Replace the body of the existing `import_csv/4` with a delegation that folds the event stream (this is the same logic Task 3 will formalise with capping; here we keep full outcomes so existing tests are unaffected):

```elixir
  def import_csv(resource, id, source, opts \\ []) when is_atom(resource) and is_atom(id) do
    with {:ok, {type, warnings, header_row, input_keys, events}} <-
           stream_events(resource, id, source, opts) do
      mode = Keyword.get(opts, :mode, :dry_run)

      {outcomes, blank_count} =
        Enum.reduce(events, {[], 0}, fn
          {:blank, _line_no}, {acc, blanks} -> {acc, blanks + 1}
          {:outcome, outcome}, {acc, blanks} -> {[outcome | acc], blanks}
        end)

      outcomes = Enum.reverse(outcomes)
      counts = RunReport.counts_from_outcomes(outcomes, blank_count)

      {:ok,
       %RunReport{
         mode: mode,
         resource: resource,
         type_id: type.id,
         outcomes: outcomes,
         warnings: warnings,
         counts: counts,
         source_headers: header_row,
         input_keys: input_keys
       }}
    end
  end
```

Also delete the now-unused `pull_header_row/1` (header extraction is handled inside `Parser.parse_stream/2`), and drop `:empty_file` construction from the orchestrator (the parser now returns it). Update the moduledoc's numbered steps to reflect that parsing/header-pulling is delegated to `Parser.parse_stream/2`.

> This task's `import_csv/4` still returns a **full** outcomes list and no `outcomes_truncated?` field — that field doesn't exist yet (Task 3 adds it). Existing orchestrator tests must still pass here.

- [ ] **Step 5: Run the full suite to verify green**

Run: `mix test test/ash_csv_interchange/stream_import_test.exs test/ash_csv_interchange/orchestrator_test.exs`
Expected: PASS. The new stream_import tests pass; existing orchestrator tests still pass (record retained because commit tests haven't yet flipped — but wait: the default is now `retain_records?: false`).

> **Important:** flipping the default to `false` breaks the record-inspecting orchestrator tests **now**. Do Step 6 before running, or expect those specific failures. To keep this task self-contained, apply the Task 3 test edits (adding `retain_records?: true`) as part of Step 6 here.

- [ ] **Step 6: Update record-inspecting orchestrator tests**

In `test/ash_csv_interchange/orchestrator_test.exs`, add `retain_records?: true` to the option lists of the commit tests that assert on `record`:

- "sets the configured attribute on every committed record" (import_source stamping) — change the call to:
  ```elixir
  Orchestrator.import_csv(TestResource, :test_resource, csv, mode: :commit, retain_records?: true)
  ```
- "propagates the actor opt to the Ash action":
  ```elixir
  Orchestrator.import_csv(ActorAwareResource, :actor_aware, csv,
    mode: :commit,
    actor: actor,
    retain_records?: true
  )
  ```
- "passes nil when no actor is supplied":
  ```elixir
  Orchestrator.import_csv(ActorAwareResource, :actor_aware, csv,
    mode: :commit,
    retain_records?: true
  )
  ```
- "authorize?: false bypasses policy denial" — update the `opts` binding:
  ```elixir
  # credo:disable-for-next-line AshCredo.Check.Warning.AuthorizeFalse
  opts = [mode: :commit, actor: %{id: "anyone"}, authorize?: false, retain_records?: true]
  ```
- "propagates the tenant opt to the Ash changeset":
  ```elixir
  Orchestrator.import_csv(TenantAwareResource, :tenant_aware, csv,
    mode: :commit,
    tenant: "tenant-acme",
    retain_records?: true
  )
  ```

Leave the `:created`/`:updated` and error-isolation tests unchanged (they assert on `upsert_kind`/`status`, not `record`).

- [ ] **Step 7: Run the suite again**

Run: `mix test test/ash_csv_interchange/stream_import_test.exs test/ash_csv_interchange/orchestrator_test.exs`
Expected: PASS.

- [ ] **Step 8: Format, credo, then commit**

```bash
mix format
mix credo --strict
git add lib/ash_csv_interchange/import/stream_report.ex lib/ash_csv_interchange/import/orchestrator.ex \
        test/ash_csv_interchange/stream_import_test.exs test/ash_csv_interchange/orchestrator_test.exs
git commit -m "feat: add Orchestrator.stream_import/4 with lazy per-row outcomes"
```

---

## Task 3: Bounded RunReport in import_csv/4

**Files:**
- Modify: `lib/ash_csv_interchange/import/run_report.ex`
- Modify: `lib/ash_csv_interchange/import/orchestrator.ex`
- Test: `test/ash_csv_interchange/stream_import_test.exs` (add a `describe` block)

**Interfaces:**
- Consumes: `stream_events/4` (Task 2), `RunReport.Counts`, `Parser.StreamError` (Task 1).
- Produces:
  - `%RunReport{}` gains `outcomes_truncated?: boolean()`.
  - `AshCsvInterchange.Import.Orchestrator.import_csv(resource, id, source, opts) :: {:ok, RunReport.t()} | {:error, Error.t()}`. `outcomes` is capped at `:max_outcomes` (default 100); `counts` is exact over all rows; `outcomes_truncated?` is `true` when the outcome count exceeded the cap. `record` is dropped unless `retain_records?: true`. Malformed CSV / invalid UTF-8 surfaced during the fold become `{:error, %Error{}}`.

- [ ] **Step 1: Add the `outcomes_truncated?` field to RunReport**

In `lib/ash_csv_interchange/import/run_report.ex`:

- Add `:outcomes_truncated?` to `@enforce_keys`, to `defstruct`, and to the `@type t`. The struct block becomes:

```elixir
  @enforce_keys [
    :mode,
    :resource,
    :type_id,
    :outcomes,
    :outcomes_truncated?,
    :warnings,
    :counts,
    :source_headers,
    :input_keys
  ]
  defstruct [
    :mode,
    :resource,
    :type_id,
    :outcomes,
    :outcomes_truncated?,
    :warnings,
    :counts,
    :source_headers,
    :input_keys
  ]

  @type t :: %__MODULE__{
          mode: :dry_run | :commit,
          resource: module(),
          type_id: atom(),
          outcomes: [RowOutcome.t()],
          outcomes_truncated?: boolean(),
          warnings: [Error.t()],
          counts: Counts.t(),
          source_headers: [String.t()],
          input_keys: %{String.t() => atom()}
        }
```

- Update the module's `@moduledoc` to note `outcomes` is a bounded preview: replace the "`outcomes` is an eager list" sentence with:

```elixir
  @moduledoc """
  Structured result of a CSV import run.

  `counts` is exact over every row. `outcomes` is a **bounded preview** —
  the first `:max_outcomes` row outcomes (default 100); `outcomes_truncated?`
  is `true` when more rows were processed than retained. Callers needing
  every per-row outcome should use `AshCsvInterchange.stream_import/3` and
  fold the lazy stream themselves.
  """
```

- [ ] **Step 2: Write the failing tests**

Add to `test/ash_csv_interchange/stream_import_test.exs` a new describe block (and add `RunReport` to the aliases at the top: `alias AshCsvInterchange.Import.{Orchestrator, RowOutcome, RunReport, StreamReport}`):

```elixir
  describe "import_csv/4 bounded report" do
    test "counts are exact but outcomes are capped at :max_outcomes" do
      header = "external_id,name,date_of_birth\n"
      rows = Enum.map_join(1..250, "", &"E#{&1},N#{&1},2020-01-01\n")
      csv = header <> rows

      assert {:ok, %RunReport{counts: counts, outcomes: outcomes, outcomes_truncated?: true}} =
               Orchestrator.import_csv(TestResource, :test_resource, csv,
                 mode: :dry_run,
                 max_outcomes: 100
               )

      assert counts.total == 250
      assert counts.succeeded == 250
      assert length(outcomes) == 100
    end

    test "outcomes_truncated? is false when under the cap" do
      csv = "external_id,name,date_of_birth\nE1,Alice,2020-01-15\n"

      assert {:ok, %RunReport{outcomes_truncated?: false, outcomes: [_]}} =
               Orchestrator.import_csv(TestResource, :test_resource, csv, mode: :dry_run)
    end

    test "counts blank rows separately from outcomes" do
      csv = "external_id,name,date_of_birth\nE1,Alice,2020-01-15\n,,\nE2,Bob,2019-03-22\n"

      assert {:ok, %RunReport{counts: counts}} =
               Orchestrator.import_csv(TestResource, :test_resource, csv, mode: :dry_run)

      assert counts.total == 2
      assert counts.blank_rows_skipped == 1
    end

    test "does not retain records by default; retains them with retain_records?: true" do
      csv = "external_id,name,date_of_birth\nE1,Alice,2020-01-15\n"

      assert {:ok, %RunReport{outcomes: [%RowOutcome{record: nil}]}} =
               Orchestrator.import_csv(TestResource, :test_resource, csv, mode: :commit)

      assert {:ok, %RunReport{outcomes: [%RowOutcome{record: record}]}} =
               Orchestrator.import_csv(TestResource, :test_resource, csv,
                 mode: :commit,
                 retain_records?: true
               )

      assert record.external_id == "E1"
    end

    test "malformed CSV in the body returns a fatal error" do
      csv = ~s(external_id,name,date_of_birth\nE1,"unterminated,2020-01-15\n)

      assert {:error, %Error{kind: :malformed_csv}} =
               Orchestrator.import_csv(TestResource, :test_resource, csv, mode: :dry_run)
    end

    test "invalid UTF-8 in the body returns an encoding error" do
      csv = "external_id,name,date_of_birth\nE1," <> <<0xFF>> <> ",2020-01-15\n"

      assert {:error, %Error{kind: :encoding}} =
               Orchestrator.import_csv(TestResource, :test_resource, csv, mode: :dry_run)
    end
  end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `mix test test/ash_csv_interchange/stream_import_test.exs`
Expected: FAIL — `import_csv/4` doesn't cap outcomes, `outcomes_truncated?` is missing, and malformed/encoding errors aren't caught mid-fold.

- [ ] **Step 4: Rewrite `import_csv/4` as a bounded, rescue-wrapped fold**

In `lib/ash_csv_interchange/import/orchestrator.ex`, replace the bridge `import_csv/4` (from Task 2 Step 4e) with the final version:

```elixir
  @doc """
  Parses a CSV source and dispatches each non-blank row to the resource's
  configured upsert action for the named type. Returns a bounded
  `%RunReport{}`: `counts` is exact, `outcomes` is a preview capped at
  `:max_outcomes`, and `outcomes_truncated?` flags when rows exceeded it.

  The `source` may be a binary, a `{:path, path}` tuple, or a
  re-enumerable `Enumerable` of binary chunks.

  Options:

    * `:mode` — `:dry_run` (default) or `:commit`
    * `:max_outcomes` — retained outcome preview size (default `100`)
    * `:retain_records?` — keep the full Ash `record` on committed
      outcomes (default `false`)
    * `:actor`, `:tenant`, `:authorize?`, `:scope` — forwarded to
      `Ash.Changeset.for_create/4` for every row.
  """
  @spec import_csv(module(), atom(), Parser.source(), keyword()) ::
          {:ok, RunReport.t()} | {:error, Error.t()}
  def import_csv(resource, id, source, opts \\ []) when is_atom(resource) and is_atom(id) do
    mode = Keyword.get(opts, :mode, :dry_run)
    max_outcomes = Keyword.get(opts, :max_outcomes, @default_max_outcomes)

    with {:ok, {type, warnings, header_row, input_keys, events}} <-
           stream_events(resource, id, source, opts) do
      try do
        {retained_reversed, counts} = fold_events(events, max_outcomes)

        {:ok,
         %RunReport{
           mode: mode,
           resource: resource,
           type_id: type.id,
           outcomes: Enum.reverse(retained_reversed),
           outcomes_truncated?: counts.total > length(retained_reversed),
           warnings: warnings,
           counts: counts,
           source_headers: header_row,
           input_keys: input_keys
         }}
      rescue
        e in NimbleCSV.ParseError ->
          {:error, %Error{kind: :malformed_csv, message: Exception.message(e)}}

        e in Parser.StreamError ->
          {:error, e.error}
      end
    end
  end

  defp fold_events(events, max_outcomes) do
    {retained, _kept, counts} =
      Enum.reduce(events, {[], 0, %Counts{}}, fn
        {:blank, _line_no}, {retained, kept, counts} ->
          {retained, kept, %{counts | blank_rows_skipped: counts.blank_rows_skipped + 1}}

        {:outcome, outcome}, {retained, kept, counts} ->
          counts = tally(counts, outcome)

          if kept < max_outcomes do
            {[outcome | retained], kept + 1, counts}
          else
            {retained, kept, counts}
          end
      end)

    {retained, counts}
  end

  defp tally(counts, outcome) do
    counts = %{counts | total: counts.total + 1}

    case outcome.status do
      :ok ->
        counts = %{counts | succeeded: counts.succeeded + 1}

        case outcome.upsert_kind do
          :created -> %{counts | created: counts.created + 1}
          :updated -> %{counts | updated: counts.updated + 1}
          _ -> counts
        end

      _ ->
        %{counts | failed: counts.failed + 1}
    end
  end
```

> `counts.total` counts only `:outcome` events (blanks are tracked in `blank_rows_skipped`), so `outcomes_truncated? = counts.total > length(retained)` is correct: when `total <= max_outcomes` every outcome is retained and the flag is `false`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/ash_csv_interchange/stream_import_test.exs test/ash_csv_interchange/orchestrator_test.exs`
Expected: PASS.

- [ ] **Step 6: Confirm no other constructor of %RunReport{} needs the new key**

Run: `grep -rn "%RunReport{" lib test`
Expected: the only construction site is `lib/ash_csv_interchange/import/orchestrator.ex`. If any other site exists, add `outcomes_truncated?:` there. (Tests only pattern-match, which tolerates the extra field.)

- [ ] **Step 7: Format, credo, then commit**

```bash
mix format
mix credo --strict
git add lib/ash_csv_interchange/import/run_report.ex lib/ash_csv_interchange/import/orchestrator.ex \
        test/ash_csv_interchange/stream_import_test.exs
git commit -m "feat: bound the import RunReport and drop retained records by default"
```

---

## Task 4: Public API — stream_import/3 and widened import_csv/3

**Files:**
- Modify: `lib/ash_csv_interchange.ex`
- Test: `test/ash_csv_interchange_test.exs`

**Interfaces:**
- Consumes: `Orchestrator.stream_import/4`, `Orchestrator.import_csv/4`, `fetch_import_type/1`.
- Produces:
  - `AshCsvInterchange.stream_import(id, source, opts) :: {:ok, StreamReport.t()} | {:error, Error.t()}`.
  - `AshCsvInterchange.import_csv(id, source, opts)` widened: `source :: binary() | {:path, Path.t()} | Enumerable.t()`.
  - `@type AshCsvInterchange.source`.

- [ ] **Step 1: Write the failing tests**

In `test/ash_csv_interchange_test.exs`, add `StreamReport` to the import aliases:

```elixir
  alias AshCsvInterchange.Import.{RowOutcome, RunReport, StreamReport}
```

Add a new describe block (the `setup_all` already registers `TestDomain`):

```elixir
  describe "stream_import/3 and import_csv/3 sources" do
    test "stream_import/3 resolves the type and streams outcomes" do
      csv = "external_id,name,date_of_birth\nE1,Alice,2020-01-15\n"

      assert {:ok, %StreamReport{outcomes: outcomes}} =
               AshCsvInterchange.stream_import(:test_resource, csv, mode: :dry_run)

      assert [%RowOutcome{line_no: 2, status: :ok}] = Enum.to_list(outcomes)
    end

    test "stream_import/3 returns type_not_found for an unregistered id" do
      assert {:error, %AshCsvInterchange.Error{kind: :type_not_found}} =
               AshCsvInterchange.stream_import(:nope, "a\nb\n")
    end

    test "import_csv/3 accepts a {:path, _} source" do
      path = Path.join(System.tmp_dir!(), "acc215_pub_#{System.unique_integer([:positive])}.csv")
      File.write!(path, "external_id,name,date_of_birth\nE1,Alice,2020-01-15\n")
      on_exit(fn -> File.rm(path) end)

      assert {:ok, %RunReport{counts: counts}} =
               AshCsvInterchange.import_csv(:test_resource, {:path, path}, mode: :dry_run)

      assert counts.total == 1
    end

    test "import_csv/3 accepts an arbitrary chunk stream" do
      chunks = ["external_id,name,date_of_birth\n", "E1,Alice,2020-01-15\n"]

      assert {:ok, %RunReport{counts: counts}} =
               AshCsvInterchange.import_csv(:test_resource, chunks, mode: :dry_run)

      assert counts.total == 1
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/ash_csv_interchange_test.exs`
Expected: FAIL — `AshCsvInterchange.stream_import/3` is undefined; `import_csv/3`'s `is_binary` guard rejects `{:path, _}` and lists.

- [ ] **Step 3: Widen the public API**

In `lib/ash_csv_interchange.ex`:

a) Add `StreamReport` to the alias and a `source` type. Change:

```elixir
  alias AshCsvInterchange.Import.{Orchestrator, RunReport}
```
to:
```elixir
  alias AshCsvInterchange.Import.{Orchestrator, RunReport, StreamReport}

  @typedoc """
  A CSV import source: an in-memory binary, a `{:path, path}` tuple, or a
  re-enumerable `Enumerable` of binary chunks.
  """
  @type source :: binary() | {:path, Path.t()} | Enumerable.t()
```

b) Replace the existing `import_csv/3` with the widened version (drop the `is_binary` guard, rename the param):

```elixir
  @doc """
  Imports a CSV source against a registered type id. Resolves the owning
  resource via `fetch_import_type/1`, then delegates to
  `AshCsvInterchange.Import.Orchestrator.import_csv/4`. See its docs for the
  `source` shapes and options.
  """
  @spec import_csv(atom(), source(), keyword()) ::
          {:ok, RunReport.t()} | {:error, Error.t()}
  def import_csv(id, source, opts \\ []) when is_atom(id) do
    with {:ok, %{resource: resource}} <- fetch_import_type(id) do
      Orchestrator.import_csv(resource, id, source, opts)
    end
  end

  @doc """
  Streams a CSV import against a registered type id as a lazy sequence of
  per-row outcomes. Resolves the owning resource via `fetch_import_type/1`,
  then delegates to `AshCsvInterchange.Import.Orchestrator.stream_import/4`.

  Returns `{:ok, %AshCsvInterchange.Import.StreamReport{}}` whose `outcomes`
  field is a lazy stream. In `:commit` mode, writes happen as the stream is
  consumed — prefer this over `import_csv/3` for large files. See
  `AshCsvInterchange.Import.Orchestrator.stream_import/4` for options.
  """
  @spec stream_import(atom(), source(), keyword()) ::
          {:ok, StreamReport.t()} | {:error, Error.t()}
  def stream_import(id, source, opts \\ []) when is_atom(id) do
    with {:ok, %{resource: resource}} <- fetch_import_type(id) do
      Orchestrator.stream_import(resource, id, source, opts)
    end
  end
```

c) Update the `AshCsvInterchange` moduledoc's import example line to mention the streaming option (optional but keeps docs coherent). After the existing `AshCsvInterchange.import_csv(:contacts, csv_binary, mode: :commit)` line, it's fine to leave as-is; no change strictly required.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/ash_csv_interchange_test.exs`
Expected: PASS.

- [ ] **Step 5: Format, credo, then commit**

```bash
mix format
mix credo --strict
git add lib/ash_csv_interchange.ex test/ash_csv_interchange_test.exs
git commit -m "feat: expose AshCsvInterchange.stream_import/3 and widen import_csv/3 sources"
```

---

## Task 5: Load-bearing tests — pull-counting + O(1) memory + CI

**Files:**
- Modify: `test/ash_csv_interchange/stream_import_test.exs` (pull-counting)
- Create: `test/ash_csv_interchange/import_memory_test.exs`
- Modify: `test/test_helper.exs`
- Modify: `.github/workflows/elixir.yml`

**Interfaces:**
- Consumes: `Orchestrator.stream_import/4`, `Orchestrator.import_csv/4`.
- Produces: no library code — tests + CI only.

- [ ] **Step 1: Add the pull-counting back-pressure test**

Add to the `describe "stream_import/4"` block in `test/ash_csv_interchange/stream_import_test.exs`:

```elixir
    test "back-pressure: consuming N outcomes pulls only ~N rows from the source" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> Agent.stop(counter) end)

      raw =
        Stream.concat(
          ["external_id,name,date_of_birth\n"],
          Stream.map(1..10_000, &"E#{&1},N#{&1},2020-01-01\n")
        )

      counted = Stream.map(raw, fn chunk -> Agent.update(counter, &(&1 + 1)); chunk end)

      assert {:ok, %StreamReport{outcomes: outcomes}} =
               Orchestrator.stream_import(TestResource, :test_resource, counted, mode: :dry_run)

      taken = outcomes |> Stream.take(10) |> Enum.to_list()

      assert length(taken) == 10
      # Header read enumerates once and the body re-enumerates; even so,
      # producing 10 outcomes must not pull anywhere near all 10_000 rows.
      assert Agent.get(counter, & &1) < 100
    end
```

Add `on_exit`/`Agent` — no extra alias needed (`Agent` and `Stream` are auto-imported).

- [ ] **Step 2: Run it to verify it passes**

Run: `mix test test/ash_csv_interchange/stream_import_test.exs`
Expected: PASS.

- [ ] **Step 3: Create the memory-profile test**

Create `test/ash_csv_interchange/import_memory_test.exs`:

```elixir
defmodule AshCsvInterchange.Import.MemoryTest do
  @moduledoc """
  Load-bearing proof for ACC-215: import memory is O(1) in row count.

  Excluded from the default suite (`@moduletag :memory`); run with
  `mix test --only memory`. Generates CSV fixtures lazily to disk so the
  test itself never holds them, imports each inside a worker process, and
  samples that worker's peak heap. Asserts peak does not scale with input
  size (a ratio, not an absolute byte threshold, to stay robust across
  machines and GC timing).
  """
  use ExUnit.Case, async: false

  @moduletag :memory

  alias AshCsvInterchange.Import.Orchestrator
  alias AshCsvInterchange.TestResource

  test "peak import memory does not scale with row count" do
    small = generate_csv(10_000)
    large = generate_csv(100_000)
    on_exit(fn -> Enum.each([small, large], &File.rm/1) end)

    peak_small = peak_memory(fn -> import_file(small) end)
    peak_large = peak_memory(fn -> import_file(large) end)

    # 10x the rows must not mean anywhere near 10x the peak heap. Factor is
    # generous to absorb GC/measurement noise; tighten only if it proves stable.
    assert peak_large < peak_small * 2,
           "expected flat memory; peak(10k)=#{peak_small} peak(100k)=#{peak_large}"
  end

  defp import_file(path) do
    {:ok, _report} =
      Orchestrator.import_csv(TestResource, :test_resource, {:path, path}, mode: :dry_run)
  end

  defp generate_csv(rows) do
    path = Path.join(System.tmp_dir!(), "acc215_mem_#{rows}_#{System.unique_integer([:positive])}.csv")

    File.open!(path, [:write], fn file ->
      IO.write(file, "external_id,name,date_of_birth\n")
      Enum.each(1..rows, fn i -> IO.write(file, "E#{i},Name#{i},2020-01-01\n") end)
    end)

    path
  end

  defp peak_memory(fun) do
    test = self()
    pid = spawn(fn -> fun.(); send(test, :worker_done) end)
    ref = Process.monitor(pid)
    sample(pid, ref, 0)
  end

  defp sample(pid, ref, peak) do
    peak =
      case Process.info(pid, :memory) do
        {:memory, mem} -> max(peak, mem)
        nil -> peak
      end

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> peak
    after
      1 -> sample(pid, ref, peak)
    end
  end
end
```

- [ ] **Step 4: Exclude `:memory` from the default run**

Replace the contents of `test/test_helper.exs` with:

```elixir
ExUnit.start(exclude: [:memory])
```

- [ ] **Step 5: Verify the tag wiring**

Run: `mix test` (memory test must be skipped)
Expected: PASS, and the summary shows excluded tests (no memory test executed).

Run: `mix test --only memory`
Expected: PASS — the single memory test runs and asserts flat memory. (This is slower; it generates a 100k-row file.)

- [ ] **Step 6: Add the CI job**

In `.github/workflows/elixir.yml`, add a `memory` job after the `check` job (sibling, same `jobs:` level). It mirrors `check`'s setup and caching but runs only the tagged test:

```yaml
  memory:
    name: memory profile
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - id: beam
        uses: erlef/setup-beam@v1
        with:
          version-file: .tool-versions
          version-type: strict

      - name: Cache deps
        uses: actions/cache@v4
        with:
          path: deps
          key: deps-${{ runner.os }}-${{ steps.beam.outputs.elixir-version }}-${{ steps.beam.outputs.otp-version }}-${{ hashFiles('mix.lock') }}
          restore-keys: deps-${{ runner.os }}-${{ steps.beam.outputs.elixir-version }}-${{ steps.beam.outputs.otp-version }}-

      - name: Cache _build
        uses: actions/cache@v4
        with:
          path: _build
          key: build-${{ runner.os }}-${{ steps.beam.outputs.elixir-version }}-${{ steps.beam.outputs.otp-version }}-${{ hashFiles('mix.lock') }}
          restore-keys: build-${{ runner.os }}-${{ steps.beam.outputs.elixir-version }}-${{ steps.beam.outputs.otp-version }}-

      - run: mix deps.get
      - run: mix test --only memory
```

- [ ] **Step 7: Format check, then commit**

```bash
mix format --check-formatted
git add test/ash_csv_interchange/stream_import_test.exs test/ash_csv_interchange/import_memory_test.exs \
        test/test_helper.exs .github/workflows/elixir.yml
git commit -m "test: prove O(1) import memory with back-pressure and a tagged memory job"
```

---

## Task 6: Documentation

**Files:**
- Modify: `usage-rules.md`
- Modify: `README.md`

**Interfaces:** none (docs only).

- [ ] **Step 1: Update `usage-rules.md`**

In the "Basic usage" section, after the existing import/export example lines, add a streaming import example:

```elixir
# Stream a large import so the file is never fully resident, committing
# rows as the stream is consumed (ideal for progressive UI or Oban chunks).
{:ok, %{outcomes: outcomes}} =
  AshCsvInterchange.stream_import(:contacts, {:path, "/tmp/contacts.csv"}, mode: :commit)

Enum.each(outcomes, &handle_outcome/1)
```

In the "Anti-patterns" section, add:

```markdown
- For large imports, prefer `stream_import/3` over `import_csv/3`. `import_csv/3`
  returns a **bounded** `%RunReport{}` — exact counts, but only the first
  `:max_outcomes` (default 100) per-row outcomes and no Ash `record` unless you
  pass `retain_records?: true`. If you need every failure (e.g. to build an
  error CSV), fold the `stream_import/3` outcome stream yourself.
- Streaming sources must be **re-enumerable** (a binary, `{:path, path}`, a
  `File.Stream`, a list, or a `Stream` over a re-runnable producer). One-shot
  sources (a consumed network body) are not supported — write them to a file
  and pass `{:path, path}`.
```

- [ ] **Step 2: Update `README.md`**

In the "Usage" section, after the existing `import_csv`/`export_csv` examples, add:

```elixir
# Stream a large import lazily; rows commit as the stream is consumed.
{:ok, %{outcomes: outcomes}} =
  AshCsvInterchange.stream_import(:contacts, {:path, "/tmp/contacts.csv"}, mode: :commit)
```

- [ ] **Step 3: Verify docs build**

Run: `mix docs`
Expected: builds without warnings.

- [ ] **Step 4: Commit**

```bash
git add usage-rules.md README.md
git commit -m "docs: document stream_import/3 and the bounded import report"
```

---

## Final verification

- [ ] **Step 1: Run the full local quality suite**

Run: `mix check`
Expected: every tool passes (compiler with `--warnings-as-errors`, formatter, credo strict, doctor, sobelow, hex/deps audit, `mix test`, dialyzer, docs). The `:memory` test is excluded from `mix test`.

- [ ] **Step 2: Run the memory job locally once**

Run: `mix test --only memory`
Expected: PASS.

- [ ] **Step 3: Sanity-check the diff against the spec**

Run: `git diff --stat main...HEAD`
Expected: changes limited to the files in the File Structure section. No `CHANGELOG.md` edits, no `Co-Authored-By` lines in `git log`.

---

## Self-Review (completed during planning)

**Spec coverage:**
- §1 input sources → Task 1 (`to_chunks/1`), Task 4 (public `source` type + tests for binary/`{:path,_}`/stream). ✓
- §2 eager header / lazy body → Task 1 (`read_first_line`, `parse_header`, `parse_stream`). ✓
- §3 error handling (binary upfront; streaming raises, `import_csv` re-wraps) → Task 1 (`validate_row!`, `StreamError`), Task 3 (rescue in `import_csv/4`). ✓
- §4 `stream_import/3` + `StreamReport` (eager warnings/headers/keys, lazy outcomes, blanks filtered) → Task 2, Task 4. ✓
- §5 bounded `RunReport` (exact counts, capped outcomes, `outcomes_truncated?`, `retain_records?` default false) → Task 3. ✓
- §6 module layout → matches File Structure. ✓
- Testing layers 1–4 → Task 2 (infinite-source laziness), Task 5 (pull-counting, memory), Task 3 (bounded retention), plus functional coverage across Tasks 1–4. CI memory job → Task 5. ✓
- Docs → Task 6. ✓
- Out-of-scope (`bulk_create`) → stated in Global Constraints and not implemented. ✓

**Placeholder scan:** no TBD/TODO; every code step shows complete code. ✓

**Type consistency:** `parse_stream/2` returns `{:ok, {header_row, body}}` consistently (Tasks 1–2); `stream_events/4` returns the 5-tuple `{type, warnings, header_row, input_keys, events}` consumed identically by `stream_import/4` and `import_csv/4`; `%RowOutcome{}` shape unchanged; `outcomes_truncated?` added to the struct before it's read. ✓
