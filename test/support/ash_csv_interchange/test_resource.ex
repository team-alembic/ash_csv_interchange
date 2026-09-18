defmodule AshCsvInterchange.TestResource do
  @moduledoc """
  Ets-backed integration-test resource used by AshCsvInterchange tests.
  Not compiled in `:dev` or `:prod`.
  """

  use Ash.Resource,
    domain: AshCsvInterchange.TestDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshCsvInterchange]

  # Private tables are scoped to the calling process, so each test gets a
  # fresh table with no cross-test cleanup needed.
  ets do
    private?(true)
  end

  csv_imports do
    csv_import :test_resource do
      label("Test Resource")

      headers(
        required: ["external_id", "name", {"date_of_birth", :dob}],
        optional: ["note"]
      )

      upsert_action(:import_from_csv)
      import_source({:source, :csv})
    end
  end

  actions do
    defaults [:read]

    create :import_from_csv do
      description "Import a row from a CSV"
      upsert? true
      upsert_identity :external_id

      argument :external_id, :string, allow_nil?: false
      argument :name, :string, allow_nil?: false
      argument :dob, :date
      argument :note, :string

      change set_attribute(:external_id, arg(:external_id))
      change set_attribute(:name, arg(:name))
      change set_attribute(:dob, arg(:dob))
      change set_attribute(:note, arg(:note))
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :external_id, :string, allow_nil?: false
    attribute :name, :string, allow_nil?: false
    attribute :dob, :date
    attribute :note, :string
    attribute :source, :atom
    timestamps()
  end

  identities do
    # Ets cannot check uniqueness during upsert, so this fixture needs
    # `pre_check_with`. Postgres-backed resources do not: the database
    # enforces uniqueness.
    identity :external_id, [:external_id], pre_check_with: AshCsvInterchange.TestDomain
  end
end
