# Defining imports

A `csv_import` declares one CSV shape the resource accepts: which columns
the file must have, where each column's value goes, and which action
writes it. This guide covers each part, using the `Contact` resource from
[Getting started](getting-started.md).

```elixir
csv_imports do
  csv_import :contacts do
    label "Contacts"
    headers required: ["external_id", "first_name"],
            optional: ["last_name", "email"],
            ignored: ["row_colour"]
    upsert_action :import_from_csv
    import_source {:source, :csv}
  end
end
```

The id (`:contacts`) is how callers name the type in
`AshCsvInterchange.import_csv/3`, so it must be unique across every
resource in the configured domains. The `label` is for people, for
example in an upload form's dropdown.

## Headers

`headers` sorts the file's columns into three groups:

| Key         | The file...          | The value...                  |
|-------------|----------------------|-------------------------------|
| `required:` | must have the column | goes to the action            |
| `optional:` | may have the column  | goes to the action if present |
| `ignored:`  | may have the column  | is dropped                    |

A file missing a required column fails before any row is read, with a
`:missing_required_headers` error listing what's absent. A column the type
doesn't mention isn't an error: it's dropped and reported as an
`:unknown_column` warning on the report. List it under `ignored:` to drop
it without the warning.

Column order in the file doesn't matter. Values are matched to columns by
header name.

### How header names match

Headers are compared after trimming whitespace and lowercasing ASCII
letters, so a declared `"external_id"` matches `External_ID` and
` external_id `. Other characters must match exactly: `External ID`, with
a space, does not match `external_id`.

Two file columns that normalise to the same name, such as `Email` and
`email`, fail the import with `:duplicate_headers`.

### Mapping columns to inputs

A bare string passes the value to the action input of the same name, so
`"first_name"` becomes `:first_name`. When the file's header isn't a valid
input name, map it with a `{column, input}` tuple:

```elixir
headers required: [{"Customer ID", :external_id}, {"Given Name", :first_name}],
        optional: [{"Date of Birth", :date_of_birth}]
```

Each input must be an attribute the upsert action accepts or an argument
it declares. The extension checks this when the resource compiles, so a
typo fails the build instead of the import.

### Empty cells and missing columns

Every value reaches the action as a string, exactly as it appears in the
file, and the action's types cast it. This is how the two kinds of absent
data behave on an existing record:

- **An empty cell** arrives as `""`. Ash casts `""` to `nil` for most
  types, so the upsert clears that attribute.
- **A missing optional column** sends nothing for that input. The upsert
  leaves the stored value alone.

Attributes that aren't import columns at all are also left alone. An
upsert only changes what the row sets.

A row whose cells are all empty or whitespace is skipped and counted in
`blank_rows_skipped`. It never reaches the action.

## The upsert action

`upsert_action` names a `:create` action on the same resource. The
extension checks at compile time that it:

- is a `:create` action
- sets `upsert? true` and `upsert_identity`
- accepts or declares every header input
- accepts or declares every key of the upsert identity, so the identity
  can always be filled in

The upsert is what makes imports safe to re-run. A row whose identity
matches an existing record updates it. Any other row creates a new
record.

```elixir
create :import_from_csv do
  accept [:external_id, :first_name, :last_name, :email]
  upsert? true
  upsert_identity :unique_external_id
end
```

Anything the action does applies to every row: validations, changes,
policies and notifications all run as they would for any other create.
That makes the action the place to reshape values the file stores
differently from the resource.

### Reshaping values

Suppose the file writes dates as `10/12/1815` (day first). `:date` expects
ISO 8601, so take the column as a string argument and convert it in a
change:

```elixir
create :import_from_csv do
  accept [:external_id, :first_name, :last_name]
  argument :date_of_birth, :string
  upsert? true
  upsert_identity :unique_external_id

  change {MyApp.Crm.Changes.ParseDayMonthYear,
          argument: :date_of_birth, attribute: :dob}
end
```

```elixir
defmodule MyApp.Crm.Changes.ParseDayMonthYear do
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    argument = Keyword.fetch!(opts, :argument)
    attribute = Keyword.fetch!(opts, :attribute)

    case Ash.Changeset.get_argument(changeset, argument) do
      nil ->
        changeset

      value ->
        case parse(value) do
          {:ok, date} ->
            Ash.Changeset.change_attribute(changeset, attribute, date)

          :error ->
            Ash.Changeset.add_error(changeset,
              field: argument,
              message: "must be DD/MM/YYYY"
            )
        end
    end
  end

  defp parse(value) do
    with [d, m, y] <- String.split(value, "/"),
         {day, ""} <- Integer.parse(d),
         {month, ""} <- Integer.parse(m),
         {year, ""} <- Integer.parse(y),
         {:ok, date} <- Date.new(year, month, day) do
      {:ok, date}
    else
      _ -> :error
    end
  end
end
```

A row with a bad date now fails with a clear message on its outcome,
while the rest of the file imports. An empty cell casts to `nil`, so the
change leaves it alone.

Don't raise inside a change to reject a row. Add an error instead. A
raised exception still fails only that row, but it's reported as
`:crashed` with the exception message rather than as a validation error
on a field.

## Stamping imported records

`import_source` force-sets one attribute on every row the import writes.
Use it to record where a record came from:

```elixir
attribute :source, :atom, public?: true

csv_import :contacts do
  # ...
  import_source {:source, :csv}
end
```

The attribute must exist on the resource. It doesn't need to be accepted
by the action: the value is set after the action's input is cast, so a
file can't override it.

## Several imports on one resource

Declare one `csv_import` per file shape. Each gets its own headers and can
use its own action:

```elixir
csv_imports do
  csv_import :contacts do
    label "Contacts"
    headers required: ["external_id", "first_name"], optional: ["last_name"]
    upsert_action :import_from_csv
  end

  csv_import :legacy_contacts do
    label "Contacts (legacy CRM export)"
    headers required: [{"Contact No", :external_id}, {"Name", :first_name}],
            ignored: ["Created By", "Region"]
    upsert_action :import_legacy
  end
end
```

## Import and export ids

Import ids and export ids are separate namespaces. A resource that
declares `csv_import :contacts` and `csv_export :contacts` with matching
headers marks the two as a pair: a file exported from one can be edited
and imported through the other. See [Exports](exports.md).
