defmodule AshCsvInterchange.Import.Orchestrator do
  @moduledoc """
  Drives the CSV import pipeline at runtime. Given a resource module,
  a CSV type id, and a CSV source, `import_csv/4`:

  1. Looks up the named `csv_import` entity on the resource via
     `AshCsvInterchange.Info`. Missing extension or unknown id is fatal.
  2. Parses the source via `Parser.parse_stream/2`, which reads the
     header row eagerly (encoding errors, malformed CSV, and an empty
     file short-circuit fatally) and returns the remaining data rows
     as a lazy stream.
  3. Validates the header row against the type's schema. Missing
     required headers and duplicates are fatal; unknown columns become
     warnings on the run report.
  4. Walks each non-blank data row, building an Ash changeset for the
     configured upsert action and either validating it (`:dry_run`) or
     committing it (`:commit`). Per-row failures — validation errors,
     action errors, raised exceptions — become `:invalid` / `:errored`
     / `:crashed` outcomes; the run never aborts on one bad row.
  5. Aggregates the per-row outcomes into a `%RunReport{}` with
     summary counts and the file-level warnings collected along
     the way.
  """

  alias AshCsvInterchange.{Error, Info}

  alias AshCsvInterchange.Import.{
    HeaderCheck,
    Headers,
    Parser,
    RowOutcome,
    RunReport,
    RunReport.Counts,
    StreamReport
  }

  @ash_forwarded_opts [:actor, :tenant, :authorize?, :scope]
  @default_max_outcomes 100

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

  In `:commit` mode rows are written as the input is consumed. If a
  malformed-CSV or encoding error is encountered partway through the file,
  rows before the failure are already committed and this returns
  `{:error, %Error{}}` — the commit is not atomic across a mid-file parse
  failure. Imports are idempotent upserts, so re-running the corrected file
  converges. For large or untrusted input prefer `stream_import/4`.
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
          counts = RunReport.tally(counts, outcome)

          if kept < max_outcomes do
            {[outcome | retained], kept + 1, counts}
          else
            {retained, kept, counts}
          end
      end)

    {retained, counts}
  end

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
         process_row(
           row,
           line_no,
           headers,
           input_keys,
           type,
           resource,
           mode,
           ash_opts,
           retain_records?
         )}
      end
    end)
  end

  defp fetch_type(resource, id) do
    if AshCsvInterchange in Spark.extensions(resource) do
      case Info.csv_import_type(resource, id) do
        {:ok, type} ->
          {:ok, type}

        :error ->
          {:error,
           %Error{
             kind: :type_not_found,
             message: "Resource #{inspect(resource)} does not declare a csv_import with id #{inspect(id)}",
             context: %{resource: resource, id: id}
           }}
      end
    else
      {:error,
       %Error{
         kind: :extension_not_loaded,
         message: "Resource #{inspect(resource)} does not have the AshCsvInterchange extension loaded",
         context: %{resource: resource}
       }}
    end
  end

  defp build_input_keys(headers_config) do
    (headers_config[:required] ++ headers_config[:optional])
    |> Map.new(fn
      {column, input_key} ->
        {Headers.normalise(column), input_key}

      column when is_binary(column) ->
        {Headers.normalise(column), String.to_existing_atom(Headers.normalise(column))}
    end)
  end

  defp blank_row?(row), do: Enum.all?(row, &(String.trim(&1) == ""))

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

  defp build_input(row, headers, input_keys) do
    headers
    |> Enum.zip(row)
    |> Enum.filter(fn {header, _value} -> Map.has_key?(input_keys, header) end)
    |> Map.new(fn {header, value} -> {Map.fetch!(input_keys, header), value} end)
  end

  defp apply_import_source(changeset, nil), do: changeset

  defp apply_import_source(changeset, {attribute, value}) do
    Ash.Changeset.force_change_attribute(changeset, attribute, value)
  end

  defp dry_run_outcome(changeset, line_no, input) do
    if changeset.valid? do
      %RowOutcome{line_no: line_no, status: :ok, input: input}
    else
      %RowOutcome{
        line_no: line_no,
        status: :invalid,
        errors: changeset.errors,
        input: input
      }
    end
  end

  defp commit_outcome(changeset, line_no, input, retain_records?) do
    case Ash.create(changeset) do
      {:ok, record} ->
        %RowOutcome{
          line_no: line_no,
          status: :ok,
          upsert_kind: upsert_kind(record),
          record: if(retain_records?, do: record),
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

  defp upsert_kind(%{inserted_at: %DateTime{} = i, updated_at: %DateTime{} = u}) do
    classify(DateTime.compare(i, u))
  end

  defp upsert_kind(%{inserted_at: %NaiveDateTime{} = i, updated_at: %NaiveDateTime{} = u}) do
    classify(NaiveDateTime.compare(i, u))
  end

  defp upsert_kind(_), do: nil

  defp classify(:eq), do: :created
  defp classify(:lt), do: :updated
  defp classify(:gt), do: :created
end
