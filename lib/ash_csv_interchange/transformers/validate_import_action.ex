defmodule AshCsvInterchange.Transformers.ValidateImportAction do
  @moduledoc """
  Compile-time validation for AshCsvInterchange DSL config. For every
  `csv_import` entity declared on the resource:

  1. The configured `upsert_action` is a `:create` action declared on
     the resource with `upsert? true` and `upsert_identity` set.
  2. Every header input key resolves to an argument on the upsert
     action or an accepted attribute.
  3. No two header columns collide after whitespace trim and ASCII
     case-fold.
  4. Every key on the action's `upsert_identity` is known to the
     upsert action — i.e. declared as an argument or in the action's
     `accept` list. Whether the value arrives from a CSV header or is
     populated by a change is the action author's responsibility; this
     check just catches the common typo case where an identity key has
     nowhere to land.
  5. If `import_source` is set, its attribute exists on the resource.

  Failures raise `Spark.Error.DslError` pointing at the offending
  entity.
  """

  use Spark.Dsl.Transformer

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshCsvInterchange.Import.{Headers, Type}
  alias Spark.Dsl.Transformer
  alias Spark.Error.DslError

  @impl true
  def after?(Ash.Resource.Transformers.DefaultAccept), do: true
  def after?(_), do: false

  @impl true
  def transform(dsl_state) do
    dsl_state
    |> Transformer.get_entities([:csv_imports])
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
         {:ok, dsl_state} <- validate_header_input_keys(dsl_state, type),
         {:ok, dsl_state} <- validate_identity_keys_known_to_action(dsl_state, type) do
      validate_import_source(dsl_state, type)
    end
  end

  defp validate_action(dsl_state, %Type{id: id, upsert_action: action_name}) do
    case ResourceInfo.action(dsl_state, action_name) do
      %Ash.Resource.Actions.Create{upsert?: true, upsert_identity: identity}
      when not is_nil(identity) ->
        {:ok, dsl_state}

      _ ->
        {:error,
         DslError.exception(
           module: Transformer.get_persisted(dsl_state, :module),
           path: [:csv_imports, :csv_import, id],
           message:
             "upsert_action #{inspect(action_name)} must be declared as a `:create` action with `upsert? true` and `upsert_identity` set"
         )}
    end
  end

  defp validate_columns_unique(dsl_state, %Type{id: id, headers: headers}) do
    ignored = Keyword.get(headers, :ignored, [])

    columns =
      Enum.map(headers[:required] ++ headers[:optional] ++ ignored, &Headers.column_name/1)

    normalised = Enum.map(columns, &Headers.normalise/1)

    duplicates =
      normalised
      |> Enum.frequencies()
      |> Enum.filter(fn {_, count} -> count > 1 end)
      |> Enum.map(fn {col, _} -> col end)

    if duplicates == [] do
      {:ok, dsl_state}
    else
      {:error,
       DslError.exception(
         module: Transformer.get_persisted(dsl_state, :module),
         path: [:csv_imports, :csv_import, id],
         message: "duplicate column name(s) after normalisation: #{inspect(duplicates)}"
       )}
    end
  end

  defp validate_header_input_keys(dsl_state, %Type{id: id, headers: headers, upsert_action: action_name}) do
    action = ResourceInfo.action(dsl_state, action_name)

    valid_key_strings =
      MapSet.new(
        Enum.map(action.arguments, &Atom.to_string(&1.name)) ++
          Enum.map(action.accept, &Atom.to_string/1)
      )

    invalid =
      (headers[:required] ++ headers[:optional])
      |> Enum.reject(&MapSet.member?(valid_key_strings, input_key_string_for(&1)))
      |> Enum.map(&input_key_for/1)

    case invalid do
      [] ->
        {:ok, dsl_state}

      keys ->
        {:error,
         DslError.exception(
           module: Transformer.get_persisted(dsl_state, :module),
           path: [:csv_imports, :csv_import, id],
           message:
             "header input key(s) #{inspect(keys)} not declared as arguments on " <>
               "or accepted attributes of #{inspect(action_name)}"
         )}
    end
  end

  defp validate_identity_keys_known_to_action(dsl_state, %Type{id: id, upsert_action: action_name}) do
    action = ResourceInfo.action(dsl_state, action_name)
    identity = ResourceInfo.identity(dsl_state, action.upsert_identity)

    known_keys =
      MapSet.new(
        Enum.map(action.arguments, & &1.name) ++
          action.accept ++
          managed_relationship_fks(dsl_state, action.changes)
      )

    missing = Enum.reject(identity.keys, &MapSet.member?(known_keys, &1))

    case missing do
      [] ->
        {:ok, dsl_state}

      keys ->
        {:error,
         DslError.exception(
           module: Transformer.get_persisted(dsl_state, :module),
           path: [:csv_imports, :csv_import, id],
           message:
             "upsert_identity #{inspect(action.upsert_identity)} key(s) #{inspect(keys)} " <>
               "are not declared as arguments or accepted attributes of " <>
               "#{inspect(action_name)} — the action has nowhere to receive " <>
               "the value, so upserts will never match an existing row"
         )}
    end
  end

  defp validate_import_source(dsl_state, %Type{import_source: nil}), do: {:ok, dsl_state}

  defp validate_import_source(dsl_state, %Type{id: id, import_source: {attribute, _value}}) do
    case ResourceInfo.attribute(dsl_state, attribute) do
      nil ->
        {:error,
         DslError.exception(
           module: Transformer.get_persisted(dsl_state, :module),
           path: [:csv_imports, :csv_import, id],
           message: "import_source attribute #{inspect(attribute)} is not declared as an attribute on this resource"
         )}

      _ ->
        {:ok, dsl_state}
    end
  end

  # Returns the source attribute (FK) of each `manage_relationship` change on
  # the action. Ash sets these FKs at action time. An upsert identity that
  # references one is therefore satisfied, with no header or accepted
  # attribute needed.
  defp managed_relationship_fks(dsl_state, changes) do
    for %{change: {Ash.Resource.Change.ManageRelationship, opts}} <- changes,
        relationship = Keyword.get(opts, :relationship),
        rel_info = ResourceInfo.relationship(dsl_state, relationship),
        not is_nil(rel_info),
        do: rel_info.source_attribute
  end

  defp input_key_for({_col, input_key}) when is_atom(input_key), do: input_key
  defp input_key_for(col) when is_binary(col), do: col

  defp input_key_string_for({_col, input_key}) when is_atom(input_key), do: Atom.to_string(input_key)

  defp input_key_string_for(col) when is_binary(col), do: Headers.normalise(col)
end
