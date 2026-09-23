# Exports

A `csv_export` turns a read action's results into CSV. The read action
decides which records are exported and in what order. The export decides
which columns appear and how each value is written.

```elixir
csv_exports do
  csv_export :contacts do
    label "Contacts"
    read_action :for_csv_export

    columns [
      {"external_id", :external_id},
      {"first_name", :first_name},
      {"last_name", :last_name},
      {"date_of_birth", :dob}
    ]
  end
end
```

Export ids must be unique across the configured domains, like import ids.
The two are separate namespaces, so an import and an export may share an
id.

## The read action

The export streams records in batches, which requires keyset pagination on
the read action:

```elixir
read :for_csv_export do
  pagination keyset?: true, required?: false
  prepare build(sort: [external_id: :asc], load: [:full_name])
end
```

Without keyset pagination the export fails when consumed, with
`Ash.Error.Invalid.NonStreamableAction`. `required?: false` keeps the
action usable without a page elsewhere in your app.

Everything else about what's exported lives in the action:

- **Filtering:** `filter expr(is_nil(archived_at))` exports only
  active contacts.
- **Ordering:** sort on a unique field so every export of the same data
  comes out in the same order.
- **Loading:** any calculation or aggregate used as a column must be
  loaded here. See [Calculations and aggregates](#calculations-and-aggregates).
- **Authorisation:** the action's policies apply to the export's actor.

## Columns

Each column is a `{header, field}` or `{header, field, opts}` tuple, in the
order they appear in the file. A field is an attribute, a calculation or
an aggregate on the resource. The extension checks at compile time that
each field exists and that no two columns share a header.

### How values are written

With no `format:` option, a value is written with `to_string/1`:

| Value | Cell |
|-------|------|
| `nil` | empty |
| `"Ada"` | `Ada` |
| `~D[1815-12-10]` | `1815-12-10` |
| `~U[2026-09-23 13:47:38Z]` | `2026-09-23 13:47:38Z` |
| `:active` | `active` |
| `true` | `true` |
| `Decimal.new("12.50")` | `12.50` |

A value `to_string/1` can't handle, such as a map, raises when the export
reaches that record. Give it a formatter.

### Formatters

`format:` takes a one-argument function, or an `{module, function,
extra_args}` tuple that is called with the value first:

```elixir
columns [
  {"external_id", :external_id},
  # ISO 8601, with the "T" that to_string/1 leaves out
  {"inserted_at", :inserted_at, format: &DateTime.to_iso8601/1},
  # a list attribute, as one cell
  {"tags", :tags, format: {Enum, :join, [";"]}},
  # your own function
  {"balance", :balance_cents, format: {MyApp.Money, :format_cents, ["AUD"]}}
]
```

The formatter's result goes through `to_string/1`, so it may return a
string, a number or iodata. Formatters aren't called for `nil`: a `nil`
value is always an empty cell. The extension checks at compile time that a
function formatter takes one argument and that an MFA's function exists
with the right arity.

## Calculations and aggregates

A calculation or aggregate can be a column, as long as the read action
loads it:

```elixir
calculations do
  calculate :full_name, :string, expr(first_name <> " " <> last_name)
  calculate :account_name, :string, expr(account.name)
end

aggregates do
  count :open_deal_count, :deals, filter: expr(status == :open)
end

actions do
  read :for_csv_export do
    pagination keyset?: true, required?: false
    prepare build(load: [:full_name, :account_name, :open_deal_count])
  end
end
```

A column whose field isn't loaded raises `Protocol.UndefinedError` for
`Ash.NotLoaded` when the export runs.

Columns can't name a relationship directly. To export a value from a
related record, wrap it in a calculation, like `:account_name` above.

## Running an export

`AshCsvInterchange.export_csv/2` returns the whole file as one binary:

```elixir
{:ok, csv} = AshCsvInterchange.export_csv(:contacts, actor: current_user)
```

`AshCsvInterchange.stream_export/2` returns a lazy stream of binary chunks.
The first chunk is the header row, and each later chunk is one batch of
records:

```elixir
{:ok, stream} = AshCsvInterchange.stream_export(:contacts, actor: current_user)

stream
|> Stream.into(File.stream!("/tmp/contacts.csv"))
|> Stream.run()
```

Prefer `stream_export/2` for anything large. Only one batch of records is
in memory at a time. `:batch_size` sets the batch, and defaults to `500`.

Both functions return `{:error, %AshCsvInterchange.Error{}}` before
reading anything if the id isn't registered (`:type_not_found`) or the
actor may not run the read action (`:export_action_unauthorised`). Errors
that happen while the stream is consumed, such as a formatter that raises
or a failing read, are raised to the consumer rather than written into the
file. A half-written CSV that looks complete is worse than a failed
download.

### Read-action arguments

Pass the read action's arguments with `:input`:

```elixir
read :for_csv_export_by_owner do
  argument :owner_id, :uuid, allow_nil?: false
  pagination keyset?: true, required?: false
  filter expr(owner_id == ^arg(:owner_id))
end
```

```elixir
AshCsvInterchange.export_csv(:contacts_by_owner,
  input: %{owner_id: user.id},
  actor: user
)
```

`:input` defaults to `%{}`. If the action requires an argument and you
leave it out, the action's own missing-argument error is raised when the
stream is consumed.

### Recipe: a download endpoint

A streamed export fits a chunked HTTP response, so the file is never built
in memory. This sketch uses a Phoenix controller, but the library doesn't
depend on Phoenix. Anything that can write chunks works.

```elixir
def export(conn, _params) do
  actor = conn.assigns.current_user

  case AshCsvInterchange.stream_export(:contacts, actor: actor) do
    {:ok, stream} ->
      conn =
        conn
        |> put_resp_content_type("text/csv")
        |> put_resp_header("content-disposition", ~s(attachment; filename="contacts.csv"))
        |> send_chunked(200)

      Enum.reduce_while(stream, conn, fn chunk, conn ->
        case chunk(conn, chunk) do
          {:ok, conn} -> {:cont, conn}
          {:error, :closed} -> {:halt, conn}
        end
      end)

    {:error, %AshCsvInterchange.Error{kind: :export_action_unauthorised}} ->
      send_resp(conn, 403, "Forbidden")

    {:error, %AshCsvInterchange.Error{kind: :type_not_found}} ->
      send_resp(conn, 404, "Not found")
  end
end
```

## Round trips

When a resource declares an import and an export with the same id and
matching headers, an exported file can be edited and imported straight
back:

```elixir
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
```

The import upserts on `external_id`, so re-importing an unchanged export
leaves the data as it was, and each edited row updates its record. For
values that don't round-trip through `to_string/1`, pair a formatter on the export
with a change on the import that parses the same format. See
[Reshaping values](defining-imports.md#reshaping-values).

## Offering exports to users

`AshCsvInterchange.list_export_types/1` lists every export. Pass an actor
to list only those the actor may read:

```elixir
AshCsvInterchange.list_export_types(actor: current_user)
#=> [%{id: :contacts, label: "Contacts", resource: MyApp.Crm.Contact}]
```
