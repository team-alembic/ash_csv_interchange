defmodule AshCsvInterchange.RestrictedExportDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshCsvInterchange.RestrictedExportResource
  end
end

defmodule AshCsvInterchange.RestrictedExportResource do
  @moduledoc """
  Always-forbidden export-side resource used by `AshCsvInterchangeTest` to
  verify that `list_export_types/1` and `stream_export/2` honour actor
  authorisation on the declared read action.
  """

  use Ash.Resource,
    domain: AshCsvInterchange.RestrictedExportDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshCsvInterchange],
    authorizers: [Ash.Policy.Authorizer]

  csv_exports do
    csv_export :restricted_export do
      label("Restricted Export")
      read_action :read_restricted
      columns([{"name", :name}])
    end
  end

  actions do
    defaults [:read]

    read :read_restricted do
      description "Always-forbidden read action used to test actor filtering"
      pagination keyset?: true, required?: false
    end
  end

  policies do
    default_access_type :strict

    policy action(:read_restricted) do
      authorize_if never()
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :string, public?: true
    timestamps()
  end
end
