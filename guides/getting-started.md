# Getting started

This guide takes one resource from nothing to a working CSV import and
export. By the end you will have a `Contact` resource that accepts a
contacts spreadsheet, reports what each row would do, commits it, and
writes the same data back out.

## Install

The package is a private git dependency until it is published to Hex:

```elixir
def deps do
  [
    {:ash_csv_interchange,
     git: "git@github.com:team-alembic/ash_csv_interchange.git"}
  ]
end
```

Run `mix deps.get`, then add the package to `import_deps` in
`.formatter.exs` so `mix format` writes the DSL without parentheses:

```elixir
[
  import_deps: [:ash, :ash_csv_interchange],
  # ...
]
```

## Configure

The library needs two pieces of config: the OTP app that owns your CSV
resources, and the domains to search for CSV types under that app.

```elixir
# config/config.exs
config :ash_csv_interchange, otp_app: :my_app
config :my_app, AshCsvInterchange, domains: [MyApp.Crm]
```

Both lines are required. A library can't tell which app it runs inside, so
without `otp_app` the first call raises and explains what to set.

## Define a resource

Add the extension, then declare an import and an export. This example uses
AshPostgres, but any data layer that supports upserts works.

```elixir
defmodule MyApp.Crm.Contact do
  use Ash.Resource,
    domain: MyApp.Crm,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshCsvInterchange]

  postgres do
    table "contacts"
    repo MyApp.Repo
  end

  csv_imports do
    csv_import :contacts do
      label "Contacts"
      headers required: ["external_id", "first_name"],
              optional: ["last_name", "email"]
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
        {"last_name", :last_name},
        {"email", :email}
      ]
    end
  end

  actions do
    defaults [:read]

    create :import_from_csv do
      accept [:external_id, :first_name, :last_name, :email]
      upsert? true
      upsert_identity :unique_external_id
    end

    read :for_csv_export do
      pagination keyset?: true, required?: false
      prepare build(sort: [external_id: :asc])
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :external_id, :string, allow_nil?: false, public?: true
    attribute :first_name, :string, allow_nil?: false, public?: true
    attribute :last_name, :string, public?: true
    attribute :email, :string, public?: true
    timestamps()
  end

  identities do
    identity :unique_external_id, [:external_id]
  end
end
```

The pieces that matter:

- **The identity** says what makes two rows the same contact. Here it is
  `external_id`, the ID from the system the spreadsheet came from.
- **The upsert action** must be a `:create` action with `upsert? true` and
  an `upsert_identity`. Importing the same file twice then updates the
  existing contacts instead of duplicating them.
- **Every header maps to an input.** `"first_name"` becomes the
  `:first_name` input, so the action must accept that attribute or declare
  that argument. The extension checks this at compile time.
- **`timestamps()`** lets import reports tell created rows from updated
  ones. Without it they only report success or failure.
- **The export's read action** needs keyset pagination, because exports
  stream records in batches. `required?: false` keeps it usable
  unpaginated elsewhere.

## Check a file with a dry run

Imports run in `:dry_run` mode unless you say otherwise. A dry run builds
and validates every row's changeset but writes nothing:

```elixir
csv = """
external_id,first_name,last_name,email
C-1,Ada,Lovelace,ada@example.com
C-2,Grace,,grace@example.com
C-3,,Lamarr,hedy@example.com
"""

{:ok, report} = AshCsvInterchange.import_csv(:contacts, csv)

report.counts
#=> %AshCsvInterchange.Import.RunReport.Counts{
#=>   total: 3, succeeded: 2, failed: 1, created: 0, updated: 0,
#=>   blank_rows_skipped: 0
#=> }

Enum.reject(report.outcomes, &(&1.status == :ok))
#=> [%AshCsvInterchange.Import.RowOutcome{line_no: 4, status: :invalid, ...}]
```

Row 4 (line 1 is the header) has no `first_name`, which the resource
requires. The empty `last_name` on row 3 is fine: empty cells reach the
action as `""`, which Ash casts to `nil`.

## Commit

Fix the file, or accept that bad rows will be skipped, and commit:

```elixir
{:ok, report} = AshCsvInterchange.import_csv(:contacts, csv, mode: :commit)

report.counts
#=> %{total: 3, succeeded: 2, failed: 1, created: 2, updated: 0, ...}
```

A failing row never stops the run. Commit the same file again and the two
good rows come back as `updated: 2`.

## Export

The export reads through `:for_csv_export` and writes one column per
declared tuple, in order:

```elixir
{:ok, csv} = AshCsvInterchange.export_csv(:contacts)
#=> {:ok, "external_id,first_name,last_name,email\r\nC-1,Ada,Lovelace,ada@example.com\r\n..."}
```

The import and export share the `:contacts` id and the same headers, so an
exported file can be edited and imported straight back.

## Next steps

- [Defining imports](defining-imports.md): header mapping, reshaping
  values in the action, stamping imported records, and the compile-time
  checks.
- [Running imports](running-imports.md): reading reports, handling errors,
  streaming large files, and batching.
- [Exports](exports.md): columns, formatters, calculations, read-action
  arguments, and streaming.
- The [DSL reference](DSL-AshCsvInterchange.md) lists every option.
