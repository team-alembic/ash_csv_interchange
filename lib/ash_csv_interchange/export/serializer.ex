defmodule AshCsvInterchange.Export.Serializer do
  @moduledoc """
  Renders Ash records into CSV cells per the column declarations on an
  `AshCsvInterchange.Export.Type`.

  Formatter resolution for `{header, field, opts}`:

    * no `format:` opt: `to_string(value)`
    * 1-arity function capture: `to_string(fun.(value))`
    * `{m, f, args}`: `to_string(apply(m, f, [value | args]))`

  Nil values render as empty cells; the formatter is not called for them.

  The serializer does not introspect Ash types. The orchestrator must
  load any calculations or relationships the columns reference.
  """

  @doc """
  Returns the CSV cells for `record` in column order.
  """
  @spec row(struct() | map(), [AshCsvInterchange.Export.Type.column()]) :: [String.t()]
  def row(record, columns) do
    Enum.map(columns, &cell(record, &1))
  end

  @doc """
  Returns the column header strings in declaration order.
  """
  @spec header([AshCsvInterchange.Export.Type.column()]) :: [String.t()]
  def header(columns) do
    Enum.map(columns, fn
      {header, _field} -> header
      {header, _field, _opts} -> header
    end)
  end

  defp cell(record, {_header, field}), do: cell(record, {nil, field, []})

  defp cell(record, {_header, field, opts}) do
    render(Map.get(record, field), Keyword.get(opts, :format))
  end

  defp render(nil, _format), do: ""
  defp render(value, nil), do: to_string(value)
  defp render(value, fun) when is_function(fun, 1), do: to_string(fun.(value))
  defp render(value, {m, f, args}), do: to_string(apply(m, f, [value | args]))
end
