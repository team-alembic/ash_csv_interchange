defmodule AshCsvInterchange.ExportTestResource do
  @moduledoc """
  Ets-backed integration-test resource used by AshCsvInterchange export tests.
  Not compiled in `:dev` or `:prod`.
  """

  use Ash.Resource,
    domain: AshCsvInterchange.ExportTestDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshCsvInterchange]

  csv_imports do
    csv_import :contacts do
      label("Active Contacts")
      headers(required: ["external_id", "first_name", "last_name"], optional: [])
      upsert_action(:import_contacts)
    end
  end

  csv_exports do
    csv_export :contacts do
      label("Active Contacts")
      read_action :for_csv_export

      columns([
        {"external_id", :external_id},
        {"first_name", :first_name},
        {"last_name", :last_name}
      ])
    end

    csv_export :contacts_raising_formatter do
      label("Contacts (formatter raises)")
      read_action :for_csv_export
      columns([{"first_name", :first_name, format: &__MODULE__.boom/1}])
    end
  end

  @doc false
  def boom(_value), do: raise("boom")

  code_interface do
    define :create_contact, action: :create
  end

  actions do
    default_accept [:external_id, :first_name, :last_name]
    defaults [:create, :read, :destroy]

    read :for_csv_export do
      description "Read action driving the :contacts CSV export"
      pagination keyset?: true, required?: false
      prepare build(load: [:full_name])
    end

    create :import_contacts do
      description "Upsert action targeted by the :contacts CSV import"
      upsert? true
      upsert_identity :external_id
      accept [:external_id, :first_name, :last_name]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :external_id, :string, public?: true, allow_nil?: false
    attribute :first_name, :string, public?: true
    attribute :last_name, :string, public?: true
    timestamps()
  end

  calculations do
    calculate :full_name, :string, expr(first_name <> " " <> last_name)
  end

  identities do
    identity :external_id, [:external_id], pre_check_with: AshCsvInterchange.ExportTestDomain
  end
end
