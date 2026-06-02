defmodule AshCsvInterchange.InfoTestDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshCsvInterchange.InfoTestResource
    resource AshCsvInterchange.InfoPlainResource
  end
end

defmodule AshCsvInterchange.InfoTestResource do
  @moduledoc """
  Resource fixture exercised by `AshCsvInterchange.InfoTest` to verify the
  `Info.csv_import_types/1` and `Info.csv_import_type/2` helpers across
  multiple `csv_import` entities.
  """

  use Ash.Resource,
    domain: AshCsvInterchange.InfoTestDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshCsvInterchange]

  csv_imports do
    csv_import :info_test do
      label("Info Test")
      headers(required: ["name", {"date_of_birth", :dob}], optional: [])
      upsert_action(:create_action)
      import_source({:source, :csv})
    end

    csv_import :info_test_archived do
      label("Info Test Archived")
      headers(required: ["name"], optional: [])
      upsert_action(:create_action)
    end
  end

  actions do
    defaults [:read]

    create :create_action do
      description "Test action used by Info tests"
      upsert? true
      upsert_identity :name
      argument :name, :string, allow_nil?: false
      argument :dob, :date

      change set_attribute(:name, arg(:name))
      change set_attribute(:dob, arg(:dob))
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :string, allow_nil?: false
    attribute :dob, :date
    attribute :source, :atom
    timestamps()
  end

  identities do
    identity :name, [:name], pre_check_with: AshCsvInterchange.InfoTestDomain
  end
end

defmodule AshCsvInterchange.InfoPlainResource do
  @moduledoc """
  Plain resource fixture (no `AshCsvInterchange` extension) used to verify
  the Info helpers return empty/`:error` for non-CSV resources.
  """

  use Ash.Resource, domain: AshCsvInterchange.InfoTestDomain, data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read]
  end

  attributes do
    uuid_v7_primary_key :id
    timestamps()
  end
end
