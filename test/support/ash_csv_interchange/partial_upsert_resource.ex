defmodule AshCsvInterchange.PartialUpsertDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshCsvInterchange.PartialUpsertResource
  end
end

defmodule AshCsvInterchange.PartialUpsertResource do
  @moduledoc """
  Ets-backed fixture for upserts that change only some attributes: an
  optional column the file may leave out (`nickname`), an attribute no
  import writes (`notes`), a change that writes `notes` for some rows
  only, and an action that declares its own `upsert_fields`.
  """

  use Ash.Resource,
    domain: AshCsvInterchange.PartialUpsertDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshCsvInterchange]

  ets do
    private?(true)
  end

  csv_imports do
    csv_import :partial_upsert do
      label("Partial upsert")
      headers(required: ["external_id", "name"], optional: ["nickname"])
      upsert_action(:import_from_csv)
    end

    csv_import :partial_upsert_conditional do
      label("Partial upsert, conditional change")
      headers(required: ["external_id", "name"], optional: [])
      upsert_action(:import_with_conditional_notes)
    end

    csv_import :partial_upsert_declared_fields do
      label("Partial upsert, declared upsert_fields")
      headers(required: ["external_id", "name"], optional: ["nickname"])
      upsert_action(:import_name_only)
    end
  end

  actions do
    defaults [:read]

    create :seed do
      primary? true
      accept [:external_id, :name, :nickname, :notes]
    end

    create :import_from_csv do
      accept [:external_id, :name, :nickname]
      upsert? true
      upsert_identity :external_id
    end

    create :import_with_conditional_notes do
      accept [:external_id, :name]
      upsert? true
      upsert_identity :external_id

      change fn changeset, _context ->
        if Ash.Changeset.get_attribute(changeset, :name) == "SetNotes" do
          Ash.Changeset.change_attribute(changeset, :notes, "from change")
        else
          changeset
        end
      end
    end

    create :import_name_only do
      accept [:external_id, :name, :nickname]
      upsert? true
      upsert_identity :external_id
      upsert_fields [:name]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :external_id, :string, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :nickname, :string, public?: true
    attribute :notes, :string, public?: true
    timestamps()
  end

  identities do
    identity :external_id, [:external_id], pre_check_with: AshCsvInterchange.PartialUpsertDomain
  end
end
