# AshCsvInterchange

[![CI](https://github.com/team-alembic/ash_csv_interchange/actions/workflows/elixir.yml/badge.svg)](https://github.com/team-alembic/ash_csv_interchange/actions/workflows/elixir.yml)
[![Hex version badge](https://img.shields.io/hexpm/v/ash_csv_interchange.svg)](https://hex.pm/packages/ash_csv_interchange)
[![Hexdocs badge](https://img.shields.io/badge/docs-hexdocs-purple)](https://hexdocs.pm/ash_csv_interchange)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

An Ash extension for declaring CSV-importable and CSV-exportable resources via a Spark DSL.

Resources that use the extension expose:

- a `csv_imports do … end` block declaring one or more named CSV types via
  `csv_import :id do … end` entities, dispatched to per-row Ash `:create`
  actions and re-run idempotently through Ash's upsert mechanism
- a `csv_exports do … end` block declaring `csv_export :id do … end` entities
  that stream a read action's records out to CSV

## Installation

This is a private git dependency for now (it will be published to Hex later).
Add it to your `mix.exs` the same way you would `ash_audit` or `ash_workflow`:

```elixir
def deps do
  [
    {:ash_csv_interchange,
     git: "git@github.com:team-alembic/ash_csv_interchange.git"}
  ]
end
```

## Usage

Configure the app that owns your CSV resources and the domains to search:

```elixir
config :ash_csv_interchange, otp_app: :my_app
config :my_app, AshCsvInterchange, domains: [MyApp.Crm]
```

Add the extension to a resource and declare its CSV types:

```elixir
defmodule MyApp.Crm.Contact do
  use Ash.Resource,
    domain: MyApp.Crm,
    extensions: [AshCsvInterchange]

  csv_imports do
    csv_import :contacts do
      label "Contacts"
      headers required: ["external_id", "first_name"], optional: ["last_name"]
      upsert_action :import_from_csv
    end
  end

  csv_exports do
    csv_export :contacts do
      label "Contacts"
      read_action :for_csv_export
      columns [
        {"external_id", :external_id},
        {"first_name", :first_name},
        {"last_name", :last_name}
      ]
    end
  end

  # ... an upsert action, a keyset-paginated read action, attributes and
  # an identity. See the getting started guide for the full resource.
end
```

Then import and export:

```elixir
# Check a file without writing anything, then commit it.
{:ok, report} = AshCsvInterchange.import_csv(:contacts, csv)
{:ok, report} = AshCsvInterchange.import_csv(:contacts, csv, mode: :commit)

# Stream a large file; rows are written as the stream is consumed.
{:ok, %{outcomes: outcomes}} =
  AshCsvInterchange.stream_import(:contacts, {:path, "/tmp/contacts.csv"}, mode: :commit)

# Export as one binary, or as a stream of chunks.
{:ok, csv} = AshCsvInterchange.export_csv(:contacts)
{:ok, stream} = AshCsvInterchange.stream_export(:contacts, batch_size: 500)
```

## Guides

- [Getting started](guides/getting-started.md): a complete resource, from
  first dry run to first export
- [Defining imports](guides/defining-imports.md): headers, the upsert
  action, reshaping values, stamping imported records
- [Running imports](guides/running-imports.md): reports, errors, large
  files, batching and authorisation
- [Exports](guides/exports.md): columns, formatters, calculations,
  streaming and round trips
- [DSL reference](documentation/dsls/DSL-AshCsvInterchange.md)

The same guides are in the [online documentation](https://hexdocs.pm/ash_csv_interchange).

## Development

Requires Elixir / OTP as pinned in [`.tool-versions`](https://github.com/team-alembic/ash_csv_interchange/blob/main/.tool-versions).

```bash
mix deps.get
mix check        # full local quality suite
mix test         # just the tests
mix format       # format all files
```

Or use the included [devcontainer](./.devcontainer/devcontainer.json) — opens
with VS Code or any devcontainer-compatible editor and sets up Elixir + asdf
automatically.

## Releases

Releases are automated via [`git_ops`](https://hex.pm/packages/git_ops) and
conventional commits. To cut a release:

```bash
mix git_ops.release
git push && git push --tags
```

Then create a GitHub Release from the tag — the `release.yml` workflow
publishes to Hex on your behalf.

## License

Apache 2.0. See [LICENSE](https://github.com/team-alembic/ash_csv_interchange/blob/main/LICENSE).

---

<sub>This repository was generated from [team-alembic/elixir_package_template](https://github.com/team-alembic/elixir_package_template).</sub>
