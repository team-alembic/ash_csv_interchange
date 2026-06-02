defmodule AshCsvInterchange.Info do
  @moduledoc """
  Introspection helpers for `AshCsvInterchange`-using resources.

  Covers both directions: `csv_import_types/1`/`csv_import_type/2` for
  import entities declared under `csv_imports`, and
  `csv_export_types/1`/`csv_export_type/2` for export entities declared
  under `csv_exports`.
  """

  alias AshCsvInterchange.Export
  alias AshCsvInterchange.Import
  alias Spark.Dsl.Extension

  @doc """
  Returns every CSV import type declared on a resource. Returns `[]`
  for a resource that doesn't have the `AshCsvInterchange` extension.
  """
  @spec csv_import_types(module()) :: [Import.Type.t()]
  def csv_import_types(resource) when is_atom(resource) do
    if AshCsvInterchange in Spark.extensions(resource) do
      Extension.get_entities(resource, [:csv_imports])
    else
      []
    end
  end

  @doc """
  Looks up a single CSV import type on a resource by id. Returns
  `:error` if the resource doesn't declare a type with that id.
  """
  @spec csv_import_type(module(), atom()) :: {:ok, Import.Type.t()} | :error
  def csv_import_type(resource, id) when is_atom(resource) and is_atom(id) do
    case Enum.find(csv_import_types(resource), &(&1.id == id)) do
      nil -> :error
      type -> {:ok, type}
    end
  end

  @doc """
  Returns every CSV export type declared on a resource. Returns `[]`
  for a resource that doesn't have the `AshCsvInterchange` extension.
  """
  @spec csv_export_types(module()) :: [Export.Type.t()]
  def csv_export_types(resource) when is_atom(resource) do
    if AshCsvInterchange in Spark.extensions(resource) do
      Extension.get_entities(resource, [:csv_exports])
    else
      []
    end
  end

  @doc """
  Looks up a single CSV export type on a resource by id. Returns
  `:error` if the resource doesn't declare a type with that id.
  """
  @spec csv_export_type(module(), atom()) :: {:ok, Export.Type.t()} | :error
  def csv_export_type(resource, id) when is_atom(resource) and is_atom(id) do
    case Enum.find(csv_export_types(resource), &(&1.id == id)) do
      nil -> :error
      type -> {:ok, type}
    end
  end
end
