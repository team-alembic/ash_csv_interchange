# Getting started

`AshCsvInterchange` is an Ash extension for declaring CSV-importable and
CSV-exportable resources.

## Install

While the package is a private git dependency, add it to `mix.exs` the same way
you would `ash_audit` or `ash_workflow`:

```elixir
def deps do
  [
    {:ash_csv_interchange,
     git: "git@github.com:team-alembic/ash_csv_interchange.git"}
  ]
end
```

Then fetch:

```bash
mix deps.get
```

## Your first import

Add the extension to a resource, declare a CSV type, register the domain in
config, and call the public API:

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

# config/config.exs
config :my_app, AshCsvInterchange, domains: [MyApp.Domain]

# anywhere
AshCsvInterchange.import_csv(:contacts, csv_binary, mode: :commit)
```

See the [README](../README.md) for the full set of import and export options.
