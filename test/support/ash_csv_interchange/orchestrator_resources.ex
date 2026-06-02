defmodule AshCsvInterchange.PlainResource do
  @moduledoc """
  Resource fixture without the AshCsvInterchange extension. Used by the
  orchestrator test to verify the `:extension_not_loaded` error path.
  """

  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read]
  end

  attributes do
    uuid_v7_primary_key :id
    timestamps()
  end
end

defmodule AshCsvInterchange.CrashingDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshCsvInterchange.CrashingResource
  end
end

defmodule AshCsvInterchange.CrashingResource do
  @moduledoc """
  Test action that raises on `name=boom`, used to verify the
  orchestrator captures per-row exceptions as `:crashed` outcomes
  without aborting the run.
  """

  use Ash.Resource,
    domain: AshCsvInterchange.CrashingDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshCsvInterchange]

  csv_imports do
    csv_import :crashing do
      label("Crashing")
      headers(required: ["name"], optional: [])
      upsert_action(:create_action)
    end
  end

  actions do
    defaults [:read]

    create :create_action do
      description "Test action that raises on name=boom"
      upsert? true
      upsert_identity :name
      argument :name, :string

      change fn changeset, _ ->
        if Ash.Changeset.get_argument(changeset, :name) == "boom" do
          raise "kaboom"
        else
          Ash.Changeset.force_change_attribute(
            changeset,
            :name,
            Ash.Changeset.get_argument(changeset, :name)
          )
        end
      end
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :string, allow_nil?: false
    timestamps()
  end

  identities do
    identity :name, [:name], pre_check_with: AshCsvInterchange.CrashingDomain
  end
end

defmodule AshCsvInterchange.ActorAwareDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshCsvInterchange.ActorAwareResource
  end
end

defmodule AshCsvInterchange.ActorAwareResource do
  @moduledoc """
  Stamps the actor's id onto the record so the orchestrator test can
  assert that the actor opt is propagated through to the Ash action.
  """

  use Ash.Resource,
    domain: AshCsvInterchange.ActorAwareDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshCsvInterchange]

  csv_imports do
    csv_import :actor_aware do
      label("Actor-aware")
      headers(required: ["name"], optional: [])
      upsert_action(:create_action)
    end
  end

  actions do
    defaults [:read]

    create :create_action do
      description "Stamps the actor's id on the record"
      upsert? true
      upsert_identity :name
      argument :name, :string

      change fn changeset, %{actor: actor} ->
        changeset
        |> Ash.Changeset.force_change_attribute(
          :name,
          Ash.Changeset.get_argument(changeset, :name)
        )
        |> Ash.Changeset.force_change_attribute(:imported_by, actor && actor.id)
      end
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :string, allow_nil?: false
    attribute :imported_by, :string
    timestamps()
  end

  identities do
    identity :name, [:name], pre_check_with: AshCsvInterchange.ActorAwareDomain
  end
end

defmodule AshCsvInterchange.LockedDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshCsvInterchange.LockedResource
  end
end

defmodule AshCsvInterchange.LockedResource do
  @moduledoc """
  Resource with a deny-all policy on the create action, used by the
  orchestrator test to verify the `authorize?: false` opt bypasses
  policy denial.
  """

  use Ash.Resource,
    domain: AshCsvInterchange.LockedDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshCsvInterchange],
    authorizers: [Ash.Policy.Authorizer]

  csv_imports do
    csv_import :locked do
      label("Locked")
      headers(required: ["name"], optional: [])
      upsert_action(:create_action)
    end
  end

  actions do
    defaults [:read]

    create :create_action do
      description "Locked-down action used to test authorize? bypass"
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
    identity :name, [:name], pre_check_with: AshCsvInterchange.LockedDomain
  end
end

defmodule AshCsvInterchange.TenantAwareDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshCsvInterchange.TenantAwareResource
  end
end

defmodule AshCsvInterchange.Import.OrchestratorTest.UnquotedHeaderDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshCsvInterchange.Import.OrchestratorTest.UnquotedHeaderResource
  end
end

defmodule AshCsvInterchange.Import.OrchestratorTest.UnquotedHeaderResource do
  @moduledoc """
  Declares a comma-containing header in its `csv_imports` config so the
  orchestrator test can verify that unquoted occurrences of the header
  in the source CSV are auto-quoted before parsing.
  """

  use Ash.Resource,
    domain: AshCsvInterchange.Import.OrchestratorTest.UnquotedHeaderDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshCsvInterchange]

  csv_imports do
    csv_import :unquoted_test do
      label("Unquoted Test")

      headers(
        required: [
          "external_id",
          "name",
          {"Substr(b,5,2)!!'/'!!substr(b,7,2)!!'/'!!substr(b,1,4)", :dob}
        ],
        optional: []
      )

      upsert_action(:create_action)
    end
  end

  actions do
    defaults [:read]

    create :create_action do
      description "Test upsert exercising auto-quoting of comma-containing headers."
      upsert? true
      upsert_identity :external_id
      accept [:external_id, :name, :dob]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :external_id, :string, allow_nil?: false
    attribute :name, :string
    attribute :dob, :date
    timestamps()
  end

  identities do
    identity :external_id, [:external_id],
      pre_check_with: AshCsvInterchange.Import.OrchestratorTest.UnquotedHeaderDomain
  end
end

defmodule AshCsvInterchange.TenantAwareResource do
  @moduledoc """
  Captures the changeset's tenant onto the record so the orchestrator
  test can assert that the tenant opt is propagated to Ash.
  """

  use Ash.Resource,
    domain: AshCsvInterchange.TenantAwareDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshCsvInterchange]

  csv_imports do
    csv_import :tenant_aware do
      label("Tenant-aware")
      headers(required: ["name"], optional: [])
      upsert_action(:create_action)
    end
  end

  actions do
    defaults [:read]

    create :create_action do
      description "Captures the tenant onto the record for assertion"
      upsert? true
      upsert_identity :name
      argument :name, :string

      change fn changeset, _ ->
        changeset
        |> Ash.Changeset.force_change_attribute(
          :name,
          Ash.Changeset.get_argument(changeset, :name)
        )
        |> Ash.Changeset.force_change_attribute(:captured_tenant, changeset.tenant)
      end
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :string, allow_nil?: false
    attribute :captured_tenant, :string
    timestamps()
  end

  identities do
    identity :name, [:name], pre_check_with: AshCsvInterchange.TenantAwareDomain
  end
end
