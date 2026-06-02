defmodule AshCsvInterchange.Import.Parser do
  @moduledoc """
  RFC 4180 CSV parser. Strips a leading UTF-8 BOM, enforces UTF-8
  validity, and wraps NimbleCSV parse errors as tagged tuples.

  Accepts a binary of CSV bytes. Callers with a file path read it
  themselves and pass the contents in.
  """

  alias AshCsvInterchange.Error

  @utf8_bom <<0xEF, 0xBB, 0xBF>>

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
end
