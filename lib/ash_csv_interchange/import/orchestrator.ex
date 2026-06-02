defmodule AshCsvInterchange.Import.Orchestrator do
  @moduledoc """
  Drives the CSV import pipeline at runtime. Given a resource module,
  a CSV type id, and a CSV binary, `import_csv/4`:

  1. Looks up the named `csv_import` entity on the resource via
     `AshCsvInterchange.Info`. Missing extension or unknown id is fatal.
  2. Parses the CSV into rows. Encoding errors and malformed CSV
     short-circuit with a fatal error.
  3. Pulls the header row off the front. An empty file is fatal.
  4. Validates the header row against the type's schema. Missing
     required headers and duplicates are fatal; unknown columns become
     warnings on the run report.
  5. Walks each non-blank data row, building an Ash changeset for the
     configured upsert action and either validating it (`:dry_run`) or
     committing it (`:commit`). Per-row failures — validation errors,
     action errors, raised exceptions — become `:invalid` / `:errored`
     / `:crashed` outcomes; the run never aborts on one bad row.
  6. Aggregates the per-row outcomes into a `%RunReport{}` with
     summary counts and the file-level warnings collected along
     the way.
  """

  alias AshCsvInterchange.{Error, Info}
  alias AshCsvInterchange.Import.{HeaderCheck, Headers, Parser, RowOutcome, RunReport}

  @ash_forwarded_opts [:actor, :tenant, :authorize?, :scope]

  @doc """
  Parses a CSV binary and dispatches each non-blank row to the
  resource's configured upsert action for the named type. Returns a
  `%RunReport{}` with per-row outcomes and aggregate counts.

  Options:

  * `:mode` — `:dry_run` (default) or `:commit`
  * `:actor`, `:tenant`, `:authorize?`, `:scope` — forwarded to
    `Ash.Changeset.for_create/4` for every row, controlling
    authorization, multitenancy, and scope.
  """
  @spec import_csv(module(), atom(), binary(), keyword()) ::
          {:ok, RunReport.t()} | {:error, Error.t()}
  def import_csv(resource, id, binary, opts \\ []) when is_atom(resource) and is_atom(id) and is_binary(binary) do
    mode = Keyword.get(opts, :mode, :dry_run)
    ash_opts = Keyword.take(opts, @ash_forwarded_opts)

    with {:ok, type} <- fetch_type(resource, id),
         binary = preprocess_unquoted_headers(binary, type.headers),
         {:ok, parsed_rows} <- Parser.parse(binary),
         {:ok, header_row, data_rows} <- pull_header_row(parsed_rows),
         {:ok, %{headers: headers, warnings: warnings}} <-
           HeaderCheck.verify(header_row, type.headers) do
      input_keys = build_input_keys(type.headers)

      {outcomes, blank_count} =
        process_rows(data_rows, headers, input_keys, type, resource, mode, ash_opts)

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

  defp pull_header_row([]) do
    {:error, %Error{kind: :empty_file, message: "CSV file has no header row"}}
  end

  defp pull_header_row([header | rest]), do: {:ok, header, rest}

  defp build_input_keys(headers_config) do
    (headers_config[:required] ++ headers_config[:optional])
    |> Map.new(fn
      {column, input_key} ->
        {Headers.normalise(column), input_key}

      column when is_binary(column) ->
        {Headers.normalise(column), String.to_existing_atom(Headers.normalise(column))}
    end)
  end

  defp process_rows(data_rows, headers, input_keys, type, resource, mode, ash_opts) do
    {outcomes, blank_count} =
      data_rows
      |> Enum.with_index(2)
      |> Enum.reduce({[], 0}, fn {row, line_no}, {acc, blanks} ->
        if blank_row?(row) do
          {acc, blanks + 1}
        else
          {[process_row(row, line_no, headers, input_keys, type, resource, mode, ash_opts) | acc], blanks}
        end
      end)

    {Enum.reverse(outcomes), blank_count}
  end

  defp blank_row?(row), do: Enum.all?(row, &(String.trim(&1) == ""))

  defp process_row(row, line_no, headers, input_keys, type, resource, mode, ash_opts) do
    input = build_input(row, headers, input_keys)

    try do
      changeset =
        resource
        |> Ash.Changeset.for_create(type.upsert_action, input, ash_opts)
        |> apply_import_source(type.import_source)

      case mode do
        :dry_run -> dry_run_outcome(changeset, line_no, input)
        :commit -> commit_outcome(changeset, line_no, input)
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

  defp commit_outcome(changeset, line_no, input) do
    case Ash.create(changeset) do
      {:ok, record} ->
        %RowOutcome{
          line_no: line_no,
          status: :ok,
          upsert_kind: upsert_kind(record),
          record: record,
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

  # Real-world exports (e.g. WellSky) sometimes emit headers that contain
  # commas without RFC 4180 quoting, which would split the column into
  # fragments at parse time. When a declared header contains a comma,
  # locate it (case-insensitively) in the raw first line and wrap it in
  # double quotes so NimbleCSV treats it as a single field. Headers that
  # are already quoted, or that don't appear in the source, are left
  # alone — HeaderCheck's existing RFC 4180 hint covers those cases.
  defp preprocess_unquoted_headers(binary, headers_config) do
    comma_headers =
      (headers_config[:required] ++ headers_config[:optional])
      |> Enum.map(&Headers.column_name/1)
      |> Enum.filter(&String.contains?(&1, ","))

    if comma_headers == [] do
      binary
    else
      quote_known_comma_headers(binary, comma_headers)
    end
  end

  defp quote_known_comma_headers(binary, comma_headers) do
    case String.split(binary, ~r/(\r?\n)/, parts: 2, include_captures: true) do
      [header_line, separator, rest] ->
        Enum.reduce(comma_headers, header_line, &quote_header_if_present/2) <>
          separator <>
          rest

      [header_line] ->
        Enum.reduce(comma_headers, header_line, &quote_header_if_present/2)
    end
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
