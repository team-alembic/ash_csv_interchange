defmodule AshCsvInterchange.Transformers.ValidateReadAction do
  @moduledoc """
  Compile-time validation for `csv_exports` entities. For every
  `csv_export` entity declared on the resource:

  1. The configured `read_action` exists on the resource and is a
     `:read` action.
  2. Every column `field` resolves to an attribute, calculation, or
     aggregate on the resource.
  3. Column headers are unique within the entity.
  4. If a column's `format:` opt is a function, it has arity 1. If it
     is `{module, function, extra_args}`, the module exports
     `function/(length(extra_args) + 1)`.

  Failures raise `Spark.Error.DslError` pointing at the offending entity.
  """

  use Spark.Dsl.Transformer

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshCsvInterchange.Export.Type
  alias Spark.Dsl.Transformer
  alias Spark.Error.DslError

  @impl true
  def after?(Ash.Resource.Transformers.DefaultAccept), do: true
  def after?(_), do: false

  @impl true
  def transform(dsl_state) do
    dsl_state
    |> Transformer.get_entities([:csv_exports])
    |> Enum.reduce_while({:ok, dsl_state}, fn type, {:ok, dsl_state} ->
      case validate_type(dsl_state, type) do
        {:ok, dsl_state} -> {:cont, {:ok, dsl_state}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_type(dsl_state, %Type{} = type) do
    with {:ok, dsl_state} <- validate_action(dsl_state, type),
         {:ok, dsl_state} <- validate_columns_unique(dsl_state, type),
         {:ok, dsl_state} <- validate_column_fields(dsl_state, type) do
      validate_formatters(dsl_state, type)
    end
  end

  defp validate_action(dsl_state, %Type{id: id, read_action: action_name}) do
    case ResourceInfo.action(dsl_state, action_name) do
      %Ash.Resource.Actions.Read{} ->
        {:ok, dsl_state}

      nil ->
        {:error,
         dsl_error(
           dsl_state,
           id,
           "read_action #{inspect(action_name)} not declared on this resource"
         )}

      _other ->
        {:error,
         dsl_error(
           dsl_state,
           id,
           "read_action #{inspect(action_name)} must be a :read action"
         )}
    end
  end

  defp validate_columns_unique(dsl_state, %Type{id: id, columns: columns}) do
    headers = Enum.map(columns, &header_of/1)
    dups = headers -- Enum.uniq(headers)

    case dups do
      [] ->
        {:ok, dsl_state}

      _ ->
        {:error,
         dsl_error(
           dsl_state,
           id,
           "duplicate column header(s): #{inspect(Enum.uniq(dups))}"
         )}
    end
  end

  defp validate_column_fields(dsl_state, %Type{id: id, columns: columns}) do
    columns
    |> Enum.find(fn col -> not field_declared?(dsl_state, field_of(col)) end)
    |> case do
      nil ->
        {:ok, dsl_state}

      bad ->
        {:error,
         dsl_error(
           dsl_state,
           id,
           "column field #{inspect(field_of(bad))} is not declared as an attribute, " <>
             "calculation, or aggregate on this resource"
         )}
    end
  end

  defp validate_formatters(dsl_state, %Type{id: id, columns: columns}) do
    columns
    |> Enum.find_value(fn col -> formatter_error(col) end)
    |> case do
      nil -> {:ok, dsl_state}
      msg -> {:error, dsl_error(dsl_state, id, msg)}
    end
  end

  defp formatter_error({_header, _field}), do: nil
  defp formatter_error({_header, _field, opts}), do: check_format(Keyword.get(opts, :format))

  defp check_format(nil), do: nil

  defp check_format(fun) when is_function(fun) do
    case :erlang.fun_info(fun, :arity) do
      {:arity, 1} -> nil
      {:arity, n} -> "format: function has wrong arity (expected 1, got #{n})"
    end
  end

  defp check_format({m, f, args}) when is_atom(m) and is_atom(f) and is_list(args) do
    arity = length(args) + 1
    _ = Code.ensure_loaded(m)

    if !function_exported?(m, f, arity) do
      "format: #{inspect(m)} does not export #{f}/#{arity}"
    end
  end

  defp check_format(other) do
    "format: must be a 1-arity function or {m, f, args} MFA, got #{inspect(other)}"
  end

  defp header_of({header, _field}), do: header
  defp header_of({header, _field, _opts}), do: header
  defp field_of({_header, field}), do: field
  defp field_of({_header, field, _opts}), do: field

  defp field_declared?(dsl_state, field) do
    ResourceInfo.attribute(dsl_state, field) != nil or
      ResourceInfo.calculation(dsl_state, field) != nil or
      ResourceInfo.aggregate(dsl_state, field) != nil
  end

  defp dsl_error(dsl_state, id, message) do
    DslError.exception(
      module: Transformer.get_persisted(dsl_state, :module),
      path: [:csv_exports, :csv_export, id],
      message: message
    )
  end
end
