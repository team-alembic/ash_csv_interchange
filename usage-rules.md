# Rules for working with AshCsvInterchange

<!--
  This file is published to Hex alongside the package and is consumed by
  downstream AI agents via `mix usage_rules.sync`. Keep it focused on how to
  USE this package. Developer-facing rules belong in AGENTS.md.
-->

## Understanding AshCsvInterchange

`AshCsvInterchange` is an Ash extension (a Spark DSL) for moving CSV data in and
out of Ash resources. A resource declares named CSV `import` and `export` types;
imports dispatch to a resource `:create`/upsert action and re-run idempotently,
exports stream a read action's records out to CSV. It is for teams that need
operator-facing CSV round-trips without hand-rolling parsing, header validation,
and per-row error reporting.

## Core concepts

- **CSV type**: a named declaration (`csv_import :id` / `csv_export :id`) on a
  resource. Type ids must be unique across all configured domains.
- **Registry**: the extension discovers types by walking the resources of the
  domains listed under `config :my_app, AshCsvInterchange, domains: [...]`.
  `config :ash_csv_interchange, otp_app: :my_app` is also required: it names
  the app whose config holds that list. Without it, the first call raises.
- **Idempotent import**: imports go through the resource's upsert action, so
  re-running the same file is safe.

## Basic usage

```elixir
defmodule MyApp.Contact do
  use Ash.Resource,
    extensions: [AshCsvInterchange]

  csv_imports do
    csv_import :contacts do
      label "Contacts Export"
      headers required: ["external_id", "first_name"], optional: []
      upsert_action :import_from_csv
    end
  end
end

AshCsvInterchange.import_csv(:contacts, csv_binary, mode: :commit)
{:ok, csv} = AshCsvInterchange.export_csv(:contacts)
```

Imports default to `mode: :dry_run`, which validates every row and writes
nothing. Pass `mode: :commit` to write.

An export's read action must support keyset pagination
(`pagination keyset?: true, required?: false`), because exports stream in
batches. Any calculation or aggregate used as a column must be loaded by
that read action (`prepare build(load: [...])`).

If the export's read action takes arguments, pass them with `:input` (a map,
default `%{}`). Read actions with required arguments raise their
missing-argument error when `:input` is omitted:

```elixir
{:ok, csv} =
  AshCsvInterchange.export_csv(:contacts_by_last_name,
    input: %{last_name: "Lovelace"},
    actor: actor
  )
```

```elixir
# Stream a large import so the file is never fully resident, committing
# rows as the stream is consumed (ideal for progressive UI or Oban chunks).
{:ok, %{outcomes: outcomes}} =
  AshCsvInterchange.stream_import(:contacts, {:path, "/tmp/contacts.csv"}, mode: :commit)

Enum.each(outcomes, &handle_outcome/1)
```

## Anti-patterns

- Do **not** reuse the same `:id` across resources in one configured domain set
  — duplicate ids raise at registry-resolution time.
- Avoid loading a whole export into memory with `export_csv/2` for large data
  sets; prefer `stream_export/2`, which streams batches.
- For large imports, prefer `stream_import/3` over `import_csv/3`. The
  `%RunReport{}` from `import_csv/3` is **bounded**: counts are exact, but it
  keeps only the first `:max_outcomes` outcomes (default 100), and no Ash
  `record` unless you pass `retain_records?: true`. To see every failure — to
  build an error CSV, say — fold the `stream_import/3` outcome stream yourself.
- Streaming sources must be **re-enumerable** (a binary, `{:path, path}`, a
  `File.Stream`, a list, or a `Stream` over a re-runnable producer). One-shot
  sources (a consumed network body) are not supported — write them to a file
  and pass `{:path, path}`.
- `:commit` mode batches writes through `Ash.bulk_create/4` (`batch_size:`
  option, default 100). Outcomes are identical to per-row commits — rows a
  batch can't cleanly persist fall back to the single-row path — so only set
  `batch_size: 1` when you specifically need one write round-trip per row.
- `import_csv/3` in `:commit` mode is not atomic. Rows before a malformed or
  invalid-UTF-8 row are already committed when it returns `{:error, _}`.
  Imports are idempotent upserts, so re-running the fixed file is safe.

## See also

- [HexDocs](https://hexdocs.pm/ash_csv_interchange)
