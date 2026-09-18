defmodule AshCsvInterchange.Import.HeaderCheck do
  @moduledoc """
  Validates a parsed CSV header row against the type's declared headers.
  Header names are compared after whitespace trim and ASCII case-fold.

  Failures here are fatal because they apply to the whole file, not
  a single row.
  """

  alias AshCsvInterchange.Error
  alias AshCsvInterchange.Import.Headers

  @doc """
  Validates a header row against a headers keyword list of the form
  `[required: [...], optional: [...]]` where each entry is a bare
  string column name or a `{column, input_key}` tuple.
  """
  @spec verify([String.t()], keyword()) ::
          {:ok, %{headers: [String.t()], warnings: [Error.t()]}}
          | {:error, Error.t()}
  def verify(header_row, headers_config) when is_list(header_row) and is_list(headers_config) do
    headers = normalise_all(header_row)
    required_declared = headers_config[:required] |> Enum.map(&Headers.column_name/1)
    optional_declared = headers_config[:optional] |> Enum.map(&Headers.column_name/1)
    ignored_declared = Keyword.get(headers_config, :ignored, [])
    required = normalise_all(required_declared)
    optional = normalise_all(optional_declared)
    ignored = normalise_all(ignored_declared)

    with :ok <- check_no_duplicates(headers, required_declared),
         :ok <- check_required_present(headers, required, required_declared) do
      {:ok,
       %{
         headers: headers,
         warnings: unknown_column_warnings(headers, required ++ optional ++ ignored)
       }}
    end
  end

  defp check_no_duplicates(headers, required_declared) do
    case duplicates(headers) do
      [] ->
        :ok

      dups ->
        base = "Duplicate header columns found"
        hint = comma_split_hint(dups, required_declared)
        message = if hint, do: "#{base}. #{hint}", else: base
        {:error, %Error{kind: :duplicate_headers, message: message, context: %{duplicates: dups}}}
    end
  end

  defp check_required_present(present, required, required_declared) do
    case required -- present do
      [] ->
        :ok

      missing ->
        base = "Missing required header columns"
        hint = missing_comma_hint(missing, required_declared)
        message = if hint, do: "#{base}. #{hint}", else: base

        {:error, %Error{kind: :missing_required_headers, message: message, context: %{missing: missing}}}
    end
  end

  defp unknown_column_warnings(present, known) do
    known_set = MapSet.new(known)

    present
    |> Enum.reject(&MapSet.member?(known_set, &1))
    |> Enum.map(&%Error{kind: :unknown_column, message: "Unknown column", context: %{header: &1}})
  end

  defp duplicates(list) do
    list
    |> Enum.frequencies()
    |> Enum.filter(fn {_, count} -> count > 1 end)
    |> Enum.map(fn {header, _} -> header end)
  end

  defp normalise_all(headers), do: Enum.map(headers, &Headers.normalise/1)

  # An unquoted header splits on its own commas. Each fragment is then a
  # substring of a declared header that contains commas. Match that shape to
  # name the offending column.
  defp comma_split_hint(parsed_fragments, required_declared) do
    required_declared
    |> Enum.find(fn declared ->
      String.contains?(declared, ",") and
        Enum.any?(parsed_fragments, fn p ->
          is_binary(p) and p != "" and
            String.contains?(Headers.normalise(declared), String.trim(p))
        end)
    end)
    |> case do
      nil -> nil
      declared -> quoting_hint(declared)
    end
  end

  # A missing declared header that contains a comma was probably written
  # unquoted. The parser split it into fragments, so the original column is
  # absent.
  defp missing_comma_hint(missing_normalised, required_declared) do
    missing_set = MapSet.new(missing_normalised)

    required_declared
    |> Enum.find(fn declared ->
      String.contains?(declared, ",") and
        MapSet.member?(missing_set, Headers.normalise(declared))
    end)
    |> case do
      nil -> nil
      declared -> quoting_hint(declared)
    end
  end

  defp quoting_hint(header) do
    ~s(Column "#{header}" appears to have unquoted commas. RFC 4180 requires fields containing commas to be enclosed in double quotes — fix the source export or quote the column manually before re-uploading.)
  end
end
