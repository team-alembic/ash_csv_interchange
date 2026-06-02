defmodule AshCsvInterchange do
  @moduledoc """
  An Ash extension for declaring CSV-importable resources. Resources that
  use this extension expose:

  * a `csv_imports do ... end` block, declaring one or more named CSV
    types via `csv_import :id do ... end` entities
  * per-row Ash `:create` actions that the extension dispatches to
  * idempotent re-runs through Ash's upsert mechanism

  ## Setup

  Tell the extension which OTP app owns your CSV resources, then register the
  domains holding them under that app:

      config :ash_csv_interchange, otp_app: :my_app
      config :my_app, AshCsvInterchange, domains: [MyApp.Domain]

  `otp_app` is required: it names the application whose config the extension
  reads its domain registry from. Without it, type discovery raises rather
  than silently finding nothing.

  Then add the extension to each resource:

      defmodule MyApp.Contact do
        use Ash.Resource,
          extensions: [AshCsvInterchange]

        csv_imports do
          csv_import :contacts do
            label "Contacts Export"
            headers required: ["external_id", "first_name"], optional: []
            upsert_action :import_from_csv
          end
        end

        # ... actions, attributes, identities ...
      end

  And import a CSV:

      AshCsvInterchange.import_csv(:contacts, csv_binary, mode: :commit)
  """

  use Spark.Dsl.Extension,
    sections: [
      AshCsvInterchange.Dsl.csv_imports_section(),
      AshCsvInterchange.Dsl.csv_exports_section()
    ],
    transformers: [
      AshCsvInterchange.Transformers.ValidateImportAction,
      AshCsvInterchange.Transformers.ValidateReadAction
    ]

  alias AshCsvInterchange.{Error, Info}
  alias AshCsvInterchange.Import.{Orchestrator, RunReport}

  @doc """
  Lists every CSV import type registered across configured domains.

  Reads the host app's `AshCsvInterchange, domains: [...]` (defaults to `[]`)
  — the host app being `config :ash_csv_interchange, otp_app: ...` when set,
  otherwise the app that owns this module — walks each domain via
  `Ash.Domain.Info.resources/1`, and emits one entry per
  declared `csv_import` entity on resources that use the extension.

  Raises if two resources declare the same `:id` — type ids must be unique
  across the configured registry.

  Options:

  * `:actor` — when provided, filters out types whose configured upsert
    action the actor is not authorised to perform (via `Ash.can?/2`).
    When absent, every registered type is returned — callers needing
    role-gated discovery should pass an actor.
  """
  @spec list_import_types(keyword()) :: [%{id: atom(), label: String.t(), resource: module()}]
  def list_import_types(opts \\ []) do
    list_types(:import, opts)
  end

  @doc """
  Lists every CSV export type registered across the configured domains.

  Pass `:actor` to filter to types the actor is allowed to read; without
  one, every registered type comes back.

  Raises if two export entities share an `:id`. The import and export
  namespaces are independent, so the same `:id` may appear in both
  sections of one resource as a round-trip pairing signal.
  """
  @spec list_export_types(keyword()) :: [%{id: atom(), label: String.t(), resource: module()}]
  def list_export_types(opts \\ []) do
    list_types(:export, opts)
  end

  defp list_types(direction, opts) do
    actor = Keyword.get(opts, :actor)

    all =
      for domain <- configured_domains(),
          resource <- Ash.Domain.Info.resources(domain),
          type <- types_for(direction, resource) do
        {type.id, type.label, resource, action_for(direction, type)}
      end

    :ok = ensure_unique_type_ids!(direction, all)

    for {id, label, resource, action} <- all, authorised?(resource, action, actor) do
      %{id: id, label: label, resource: resource}
    end
  end

  defp types_for(:import, resource), do: Info.csv_import_types(resource)
  defp types_for(:export, resource), do: Info.csv_export_types(resource)

  defp action_for(:import, type), do: type.upsert_action
  defp action_for(:export, type), do: type.read_action

  defp authorised?(_resource, _action, nil), do: true
  defp authorised?(resource, action, actor), do: Ash.can?({resource, action}, actor)

  defp ensure_unique_type_ids!(direction, all) do
    dups =
      all
      |> Enum.group_by(fn {id, _, _, _} -> id end)
      |> Enum.filter(fn {_, group} -> length(group) > 1 end)
      |> Enum.map(fn {id, group} -> {id, Enum.map(group, fn {_, _, r, _} -> r end)} end)

    case dups do
      [] ->
        :ok

      _ ->
        details =
          Enum.map_join(dups, "\n", fn {id, resources} ->
            "  #{inspect(id)}: #{inspect(resources)}"
          end)

        entity = if direction == :import, do: "csv_import", else: "csv_export"

        raise """
        AshCsvInterchange: duplicate CSV #{direction} type ids detected across registered resources. \
        Each `#{entity} :id do … end` declaration must use an id unique across all \
        resources in the configured domains.

        Duplicates:
        #{details}
        """
    end
  end

  @doc """
  Looks up a registered CSV import type by id, returning the owning
  resource module and the resolved `%AshCsvInterchange.Import.Type{}` struct.

  Returns `{:error, %AshCsvInterchange.Error{kind: :type_not_found}}` if no such id
  is registered.
  """
  @spec fetch_import_type(atom()) ::
          {:ok, %{resource: module(), type: AshCsvInterchange.Import.Type.t()}}
          | {:error, Error.t()}
  def fetch_import_type(id) when is_atom(id) do
    case Enum.find(list_import_types(), &(&1.id == id)) do
      nil ->
        {:error,
         %Error{
           kind: :type_not_found,
           message: "No CSV import type registered with id #{inspect(id)}",
           context: %{id: id}
         }}

      %{resource: resource} ->
        {:ok, type} = Info.csv_import_type(resource, id)
        {:ok, %{resource: resource, type: type}}
    end
  end

  @doc """
  Resolves a registered CSV export `id` to `{:ok, %{resource:, type:}}`,
  where `:type` is the full `%AshCsvInterchange.Export.Type{}` struct.

  Returns `{:error, %Error{kind: :type_not_found}}` if the id isn't registered.
  """
  @spec fetch_export_type(atom()) ::
          {:ok, %{resource: module(), type: AshCsvInterchange.Export.Type.t()}}
          | {:error, Error.t()}
  def fetch_export_type(id) when is_atom(id) do
    case Enum.find(list_export_types(), &(&1.id == id)) do
      nil ->
        {:error,
         %Error{
           kind: :type_not_found,
           message: "No CSV export type registered with id #{inspect(id)}",
           context: %{id: id}
         }}

      %{resource: resource} ->
        {:ok, type} = Info.csv_export_type(resource, id)
        {:ok, %{resource: resource, type: type}}
    end
  end

  @doc """
  Imports a CSV binary against a registered type id. Resolves the owning
  resource via `fetch_import_type/1`, then delegates to
  `AshCsvInterchange.Import.Orchestrator.import_csv/4`. See its docs for options.
  """
  @spec import_csv(atom(), binary(), keyword()) ::
          {:ok, RunReport.t()} | {:error, Error.t()}
  def import_csv(id, binary, opts \\ []) when is_atom(id) and is_binary(binary) do
    with {:ok, %{resource: resource}} <- fetch_import_type(id) do
      Orchestrator.import_csv(resource, id, binary, opts)
    end
  end

  @doc """
  Builds a lazy stream of CSV chunks for the named export type. The
  first chunk is the header row, subsequent chunks are serialised
  batches of records from the declared read action.

  Options:

    * `:actor` runs the stream as this actor; authorisation honours the
      resource's policies on the read action.
    * `:batch_size` page size for the underlying read. Defaults to `500`.

  Returns `{:error, %Error{}}` synchronously before any database work
  when the id isn't registered or the actor can't perform the declared
  read action. Errors raised once the stream is being consumed (a
  calculation crash, a formatter exception) propagate through to the
  consumer rather than being swallowed.
  """
  @spec stream_export(atom(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def stream_export(id, opts \\ []) when is_atom(id) do
    with {:ok, %{resource: resource, type: type}} <- fetch_export_type(id) do
      actor = Keyword.get(opts, :actor)

      if authorised?(resource, type.read_action, actor) do
        {:ok, AshCsvInterchange.Export.Orchestrator.build_stream(resource, type, opts)}
      else
        {:error,
         %Error{
           kind: :export_action_unauthorised,
           message: "Actor cannot perform read action #{inspect(type.read_action)} on #{inspect(resource)}",
           context: %{id: id, resource: resource, action: type.read_action, actor: actor}
         }}
      end
    end
  end

  @doc """
  Runs an export and returns the full CSV as a single binary. For large
  exports prefer `stream_export/2` so the whole result never lives in
  memory at once.

  Accepts the same options as `stream_export/2`.
  """
  @spec export_csv(atom(), keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def export_csv(id, opts \\ []) when is_atom(id) do
    case stream_export(id, opts) do
      {:ok, stream} -> {:ok, Enum.into(stream, "")}
      {:error, _} = err -> err
    end
  end

  # The library can't assume a particular host app name: it resolves the host
  # OTP app from its own config (`config :ash_csv_interchange, otp_app: ...`)
  # and reads the domain registry from that app's config. The lookup is
  # mandatory — an unconfigured `otp_app` raises rather than silently
  # registering no types, which would otherwise surface much later as a
  # baffling "no CSV types found".
  defp configured_domains do
    host_app()
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:domains, [])
  end

  defp host_app do
    Application.get_env(:ash_csv_interchange, :otp_app) ||
      raise """
      AshCsvInterchange is not configured. Set the host OTP app that owns your
      CSV resources, then register the domains holding them under that app:

          config :ash_csv_interchange, otp_app: :my_app
          config :my_app, AshCsvInterchange, domains: [MyApp.Domain]

      Without `otp_app` the extension has no app whose config to read, so no
      `csv_import`/`csv_export` types can be discovered.
      """
  end
end
