defmodule AshCsvInterchange.Import.Headers do
  @moduledoc false
  # Shared helpers for working with the `headers:` keyword list shape that
  # appears in a resource's `csv_import` config and in CSV header rows.

  @doc "Extracts the column-name string from a header entry."
  @spec column_name(String.t() | {String.t(), atom()}) :: String.t()
  def column_name({column, _input_key}) when is_binary(column), do: column
  def column_name(column) when is_binary(column), do: column

  @doc "Trim whitespace and ASCII case-fold a header string for comparison."
  @spec normalise(String.t()) :: String.t()
  def normalise(header) when is_binary(header) do
    header |> String.trim() |> String.downcase(:ascii)
  end
end
