# Running imports

There are two ways to run an import:

- `AshCsvInterchange.import_csv/3` processes the whole file and returns a
  `%RunReport{}` summary. Use it for uploads a person is waiting on.
- `AshCsvInterchange.stream_import/3` returns a lazy stream with one
  outcome per row. Use it for large files, or whenever you need every
  outcome rather than a sample.

Both accept the same sources and options. The examples use the
`:contacts` type from [Getting started](getting-started.md).

## Dry run, then commit

Every import runs in `:dry_run` mode unless you pass `mode: :commit`. A
dry run builds each row's changeset and runs the action's validations and
changes, but never calls the data layer.

```elixir
{:ok, preview} = AshCsvInterchange.import_csv(:contacts, csv)

if preview.counts.failed == 0 do
  AshCsvInterchange.import_csv(:contacts, csv, mode: :commit)
end
```

A dry run can't catch everything, because some checks only happen when a
row is written:

- database constraints, such as a unique index outside the upsert
  identity or a foreign key
- policies. Building a changeset doesn't authorise it, so an actor's
  permissions are checked at commit.
- anything in an `after_action` hook

A row that passes a dry run can still fail at commit. The report shows
which rows failed and why.

## Reading a report

`import_csv/3` returns `{:ok, %AshCsvInterchange.Import.RunReport{}}` when
the file itself is readable, however many rows fail.

| Field                  | Contents |
|------------------------|----------|
| `counts`               | Exact totals over every row (see below) |
| `outcomes`             | The first `:max_outcomes` row outcomes (default 100) |
| `outcomes_truncated?`  | `true` when there were more outcomes than were kept |
| `warnings`             | Non-fatal file issues, such as unknown columns |
| `source_headers`       | The header row as it appeared in the file |
| `input_keys`           | Normalised header → action input |
| `mode`, `type_id`, `resource` | What ran |

`counts` has `total`, `succeeded`, `failed` and `blank_rows_skipped`. In
`:commit` mode it also splits `succeeded` into `created` and `updated`,
provided the resource has `inserted_at` and `updated_at` timestamps.

`outcomes` is capped so a million-row file doesn't produce a million-row
report. The counts stay exact. To see every outcome, use
[`stream_import/3`](#large-files).

### Row outcomes

Each `%AshCsvInterchange.Import.RowOutcome{}` records one row:

| `status`   | Meaning |
|------------|---------|
| `:ok`      | Valid (dry run) or written (commit). `upsert_kind` is `:created` or `:updated` on commit. |
| `:invalid` | Dry run: the changeset has errors |
| `:errored` | Commit: the create returned an error |
| `:crashed` | Something raised while the row was processed |

`line_no` is the row's position in the file, counting the header as 1. It
matches the row numbers a spreadsheet shows, unless a quoted cell spans
several lines. `input` is the map passed to the action.

For `:invalid` and `:errored`, `errors` holds Ash errors, which are
exceptions. For `:crashed` it holds an `%AshCsvInterchange.Error{}` with
`kind: :transform_crashed`. A helper that handles both:

```elixir
defp describe(%AshCsvInterchange.Error{message: message}), do: message
defp describe(error), do: Exception.message(error)

for %{status: status} = outcome <- report.outcomes, status != :ok do
  "Row #{outcome.line_no}: " <> Enum.map_join(outcome.errors, "; ", &describe/1)
end
```

`record` is `nil` unless you pass `retain_records?: true`. Keeping every
written record in memory adds up on large files, so turn it on only when
you need the records.

## When the whole file fails

A problem that affects the whole file returns
`{:error, %AshCsvInterchange.Error{}}` and no rows are processed:

| `kind`                     | Cause |
|----------------------------|-------|
| `:type_not_found`          | No `csv_import` with that id in the configured domains |
| `:empty_file`              | No header row |
| `:missing_required_headers`| `context.missing` lists the absent columns |
| `:duplicate_headers`       | Two columns normalise to the same name |
| `:encoding`                | The file isn't valid UTF-8 |
| `:malformed_csv`           | The CSV can't be parsed, for example an unclosed quote |
| `:unreadable_source`       | A `{:path, path}` that can't be opened |

The header is checked before any row, so header problems never leave a
file half-imported. Encoding and parse errors can appear anywhere in the
file, though, and the next section covers what they leave behind.

A UTF-8 byte-order mark at the start of the file is stripped, so files
saved by Excel import cleanly.

## Commits are not atomic

`:commit` mode writes rows as it reads them. If row 5,000 has an unclosed
quote, rows before it are already written when `import_csv/3` returns
`{:error, %Error{kind: :malformed_csv}}`.

That's safe because imports are upserts: fix the file and import it
again, and rows already written are updated in place rather than
duplicated. If you need all-or-nothing, run a dry run first. It reads the
whole file, so it finds encoding and parse errors before anything is
written.

## Large files

Both functions parse the file as a stream, so a `{:path, path}` source is
never loaded whole. `import_csv/3` keeps only the counts and the capped
`outcomes` list. When you need every outcome, for example
to give the uploader back a file of their failed rows, use
`stream_import/3`:

```elixir
{:ok, report} =
  AshCsvInterchange.stream_import(:contacts, {:path, upload_path}, mode: :commit)

report.warnings        # known up front
report.outcomes        # lazy: nothing has been written yet
```

`stream_import/3` returns once the header has been checked, so fatal
header errors come back as `{:error, %Error{}}` straight away. Rows are
processed, and in `:commit` mode written, only as you consume
`report.outcomes`. A stream that is never consumed writes nothing.

An encoding or parse error further into the file raises while you consume
the stream: `NimbleCSV.ParseError` for malformed CSV, and an exception
whose message is `"Input is not valid UTF-8"` for bad encoding. Rescue
around the consumer if you need to report it.

The stream report has no counts. Build them with
`AshCsvInterchange.Import.RunReport.tally/2`, which is the function
`import_csv/3` uses:

```elixir
alias AshCsvInterchange.Import.RunReport

counts = Enum.reduce(report.outcomes, %RunReport.Counts{}, &RunReport.tally(&2, &1))
```

The stream skips blank rows, so `blank_rows_skipped` stays `0` here.

### Sources

Both functions take the same sources:

- a binary: `csv`
- a file path: `{:path, "/tmp/contacts.csv"}`
- a stream of binary chunks: `File.stream!(path, 64_000)`, a list of
  binaries, or any `Stream` you can enumerate more than once

The source is read twice, once for the header and once for the rows. A
one-shot source, such as an HTTP response body you can only read once,
won't work. Write it to a temporary file and pass `{:path, path}`.

### Recipe: an error file for the uploader

This streams a committed import and writes every failed row, with the
reason, to a CSV the uploader can fix and send back:

```elixir
defmodule MyApp.Crm.ContactImport do
  alias AshCsvInterchange.Import.RunReport

  def run(path, actor) do
    with {:ok, report} <-
           AshCsvInterchange.stream_import(:contacts, {:path, path},
             mode: :commit,
             actor: actor
           ) do
      error_path = Path.rootname(path) <> "-errors.csv"
      file = File.open!(error_path, [:write, :utf8])

      try do
        IO.write(file, NimbleCSV.RFC4180.dump_to_iodata([["line", "error"]]))

        counts =
          Enum.reduce(report.outcomes, %RunReport.Counts{}, fn outcome, counts ->
            if outcome.status != :ok do
              message = Enum.map_join(outcome.errors, "; ", &describe/1)
              IO.write(file, NimbleCSV.RFC4180.dump_to_iodata([[outcome.line_no, message]]))
            end

            RunReport.tally(counts, outcome)
          end)

        {:ok, counts, error_path}
      after
        File.close(file)
      end
    end
  end

  defp describe(%AshCsvInterchange.Error{message: message}), do: message
  defp describe(error), do: Exception.message(error)
end
```

Memory stays flat however big the file is: rows are read, written and
reported one batch at a time.

### Recipe: a background job

A long import shouldn't run inside a web request. Save the upload
somewhere durable and run the import from a job. This sketch uses
[Oban](https://hexdocs.pm/oban), but the library doesn't depend on it.
Any job runner, or a `Task` under a supervisor, works the same way.

```elixir
defmodule MyApp.Workers.ImportContacts do
  use Oban.Worker, queue: :imports, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"path" => path, "user_id" => user_id}}) do
    actor = MyApp.Accounts.get_user!(user_id)

    case MyApp.Crm.ContactImport.run(path, actor) do
      {:ok, counts, error_path} ->
        MyApp.Notifications.import_finished(actor, counts, error_path)

      {:error, %AshCsvInterchange.Error{} = error} ->
        MyApp.Notifications.import_rejected(actor, error.message)
    end
  end
end
```

Retrying is safe because imports are upserts. A retried job updates the
rows its earlier attempt already wrote.

## Batching

In `:commit` mode, rows are written through `Ash.bulk_create/4` in batches
of `:batch_size` (default `100`), so a batch costs one round-trip to the
database. The outcomes are the same as writing one row at a time: any row
a batch doesn't cleanly write is retried on its own and gets its own
outcome. Rows in one batch that share an identity are written one after
another, so the last one in the file wins.

Pass `batch_size: 1` only if you need one write per row, for example
because the action has side effects that must happen in row order.
`:batch_size` has no effect on dry runs.

## Actors, tenants and authorisation

`:actor`, `:tenant`, `:authorize?` and `:scope` are passed to every row's
changeset, so the upsert action's policies apply to each row. A row the
actor may not write fails as `:errored` with a forbidden error. The rest
of the file still imports.

To offer only the import types a user may run, filter by actor:

```elixir
AshCsvInterchange.list_import_types(actor: current_user)
#=> [%{id: :contacts, label: "Contacts", resource: MyApp.Crm.Contact}]
```

Without an actor, `list_import_types/1` returns every registered type.
