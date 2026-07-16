defmodule AshCsvInterchange.Import.Parser do
  @moduledoc """
  RFC 4180 CSV parser with an eager binary path and a streaming path.

  `parse/1` parses a whole binary into a list of rows. `parse_stream/2`
  reads only the header line eagerly — so fatal header/encoding errors
  surface synchronously — and returns the remaining data rows as a lazy
  stream backed by `NimbleCSV.RFC4180.parse_stream/2`.

  Streaming sources may be a binary, a `{:path, path}` tuple (the file is
  opened by the parser), or any **re-enumerable** `Enumerable` of binary
  chunks. One-shot sources are not supported: the header is read by
  enumerating the source once, and the body re-enumerates it.
  """

  alias AshCsvInterchange.Error
  alias AshCsvInterchange.Import.Headers

  defmodule StreamError do
    @moduledoc false
    defexception [:error]

    @impl true
    def message(%__MODULE__{error: %Error{message: message}}), do: message
  end

  @utf8_bom <<0xEF, 0xBB, 0xBF>>

  @type source :: binary() | {:path, Path.t()} | Enumerable.t()

  @doc """
  Parses a CSV binary into a list of row lists. Returns a fatal error
  for invalid UTF-8 or malformed CSV (e.g. unterminated quotes).
  """
  @spec parse(binary()) :: {:ok, [[String.t()]]} | {:error, Error.t()}
  def parse(@utf8_bom <> rest), do: parse(rest)

  def parse(binary) when is_binary(binary) do
    if String.valid?(binary) do
      try do
        {:ok, NimbleCSV.RFC4180.parse_string(binary, skip_headers: false)}
      rescue
        e in NimbleCSV.ParseError ->
          {:error, %Error{kind: :malformed_csv, message: Exception.message(e)}}
      end
    else
      {:error, %Error{kind: :encoding, message: "Input is not valid UTF-8"}}
    end
  end

  @doc """
  Reads the header line eagerly and returns the remaining data rows as a
  lazy stream.

  Returns `{:ok, {header_row, body}}` where `header_row` is a list of
  column strings and `body` is a lazy `Enumerable` of data rows (each a
  list of strings), header excluded. Returns `{:error, %Error{}}` for an
  empty file or a malformed header line.

  Invalid UTF-8 in a *data* row is not detected here; it raises
  `#{inspect(__MODULE__)}.StreamError` when the body stream is consumed.
  """
  @spec parse_stream(source(), keyword()) ::
          {:ok, {[String.t()], Enumerable.t()}} | {:error, Error.t()}
  def parse_stream(source, headers_config) do
    chunks = to_chunks(source)

    with {:ok, first_line} <- read_first_line(chunks),
         {:ok, header_row} <- parse_header(first_line, headers_config) do
      body =
        chunks
        # Required: parse_stream/2 is line-oriented, so a raw binary or a
        # chunk boundary that splits mid-line would mis-parse without this.
        |> NimbleCSV.RFC4180.to_line_stream()
        |> NimbleCSV.RFC4180.parse_stream(skip_headers: true)
        |> Stream.map(&validate_row!/1)

      {:ok, {header_row, body}}
    end
  end

  defp to_chunks(binary) when is_binary(binary), do: [binary]
  defp to_chunks({:path, path}), do: File.stream!(path)
  defp to_chunks(enum), do: enum

  defp read_first_line(chunks) do
    first =
      Enum.reduce_while(chunks, "", fn chunk, acc ->
        combined = acc <> chunk

        case :binary.split(combined, ["\r\n", "\n"]) do
          [line, _rest] -> {:halt, line}
          [partial] -> {:cont, partial}
        end
      end)

    case strip_bom(first) do
      "" -> {:error, %Error{kind: :empty_file, message: "CSV file has no header row"}}
      line -> {:ok, line}
    end
  rescue
    e in File.Error ->
      {:error, %Error{kind: :unreadable_source, message: Exception.message(e)}}
  end

  defp strip_bom(@utf8_bom <> rest), do: rest
  defp strip_bom(other), do: other

  defp parse_header(first_line, headers_config) do
    fixed = quote_known_comma_headers(first_line, comma_headers(headers_config))

    try do
      [header_row | _] = NimbleCSV.RFC4180.parse_string(fixed, skip_headers: false)
      {:ok, header_row}
    rescue
      e in NimbleCSV.ParseError ->
        {:error, %Error{kind: :malformed_csv, message: Exception.message(e)}}
    end
  end

  defp validate_row!(fields) do
    if Enum.all?(fields, &String.valid?/1) do
      fields
    else
      raise StreamError, error: %Error{kind: :encoding, message: "Input is not valid UTF-8"}
    end
  end

  # Real-world exports (e.g. WellSky) sometimes emit headers that contain
  # commas without RFC 4180 quoting, which would split the column into
  # fragments at parse time. When a declared header contains a comma,
  # locate it (case-insensitively) in the raw header line and wrap it in
  # double quotes so NimbleCSV treats it as a single field.
  defp comma_headers(headers_config) do
    (headers_config[:required] ++ headers_config[:optional])
    |> Enum.map(&Headers.column_name/1)
    |> Enum.filter(&String.contains?(&1, ","))
  end

  defp quote_known_comma_headers(line, []), do: line

  defp quote_known_comma_headers(line, comma_headers) do
    Enum.reduce(comma_headers, line, &quote_header_if_present/2)
  end

  defp quote_header_if_present(declared, line) do
    if String.contains?(line, ~s("#{declared}")) do
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
