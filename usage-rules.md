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

## Anti-patterns

- Do **not** reuse the same `:id` across resources in one configured domain set
  — duplicate ids raise at registry-resolution time.
- Avoid loading a whole export into memory with `export_csv/2` for large data
  sets; prefer `stream_export/2`, which streams batches.

## See also

- [HexDocs](https://hexdocs.pm/ash_csv_interchange)
