defmodule AshCsvInterchange.RestrictedDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshCsvInterchange.RestrictedResource
  end
end

defmodule AshCsvInterchange.RestrictedResource do
  @moduledoc """
  Always-forbidden resource used by `AshCsvInterchangeTest` to verify that
  `list_import_types/1` filters out CSV types whose upsert action the actor
  isn't authorised to perform.
  """

  use Ash.Resource,
    domain: AshCsvInterchange.RestrictedDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshCsvInterchange],
    authorizers: [Ash.Policy.Authorizer]

  csv_imports do
    csv_import :restricted do
      label("Restricted")
      headers(required: ["name"], optional: [])
      upsert_action(:create_action)
    end
  end

  actions do
    defaults [:read]

    create :create_action do
      description "Always-forbidden action used to test actor filtering"
      upsert? true
      upsert_identity :name
      argument :name, :string
      change set_attribute(:name, arg(:name))
    end
  end

  policies do
    policy action(:create_action) do
      forbid_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :string, allow_nil?: false
    timestamps()
  end

  identities do
    identity :name, [:name], pre_check_with: AshCsvInterchange.RestrictedDomain
  end
end
