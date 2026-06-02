defmodule AshCsvInterchange.Transformers.ValidateImportActionTest do
  use ExUnit.Case, async: true

  describe "compile-time validation" do
    test "raises when upsert_action does not exist on the resource" do
      assert_raise Spark.Error.DslError,
                   ~r/upsert_action :nope must be declared as a `:create` action/,
                   fn ->
                     Code.eval_string("""
                       defmodule AshCsvInterchange.Transformers.ValidateImportActionTest.MissingAction do
                         use Ash.Resource,
                           domain: nil,
                           validate_domain_inclusion?: false,
                           data_layer: Ash.DataLayer.Ets,
                           extensions: [AshCsvInterchange]

                         csv_imports do
                           csv_import :missing_action do
                             label "Missing Action"
                             headers required: ["name"]
                             upsert_action :nope
                           end
                         end

                         identities do
                           identity :name, [:name]
                         end

                         actions do
                           defaults [:read]
                         end

                         attributes do
                           uuid_v7_primary_key :id
                           attribute :name, :string
                         end
                       end
                     """)
                   end
    end

    test "raises when upsert_action is not declared with upsert? true and upsert_identity" do
      assert_raise Spark.Error.DslError,
                   ~r/upsert_action :create_action must be declared as a `:create` action/,
                   fn ->
                     Code.eval_string("""
                       defmodule AshCsvInterchange.Transformers.ValidateImportActionTest.NotUpsert do
                         use Ash.Resource,
                           domain: nil,
                           validate_domain_inclusion?: false,
                           data_layer: Ash.DataLayer.Ets,
                           extensions: [AshCsvInterchange]

                         csv_imports do
                           csv_import :not_upsert do
                             label "Not Upsert"
                             headers required: ["name"]
                             upsert_action :create_action
                           end
                         end

                         identities do
                           identity :name, [:name]
                         end

                         actions do
                           defaults [:read]

                           create :create_action do
                             argument :name, :string
                             change set_attribute(:name, arg(:name))
                           end
                         end

                         attributes do
                           uuid_v7_primary_key :id
                           attribute :name, :string
                         end
                       end
                     """)
                   end
    end

    test "raises when a header input key is not an action argument or attribute" do
      assert_raise Spark.Error.DslError, ~r/header input key\(s\) \[:nope\]/, fn ->
        Code.eval_string("""
          defmodule AshCsvInterchange.Transformers.ValidateImportActionTest.BadHeaderKey do
            use Ash.Resource,
                           domain: nil,
              validate_domain_inclusion?: false,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshCsvInterchange]

            csv_imports do
              csv_import :bad_header do
                label "Bad Header"
                headers required: [{"some_col", :nope}]
                upsert_action :create_action
              end
            end

            identities do
              identity :name, [:name]
            end

            actions do
              defaults [:read]

              create :create_action do
                upsert? true
                upsert_identity :name
                argument :name, :string
                change set_attribute(:name, arg(:name))
              end
            end

            attributes do
              uuid_v7_primary_key :id
              attribute :name, :string
            end
          end
        """)
      end
    end

    test "raises when two headers normalise to the same key" do
      assert_raise Spark.Error.DslError, ~r/duplicate column/i, fn ->
        Code.eval_string("""
          defmodule AshCsvInterchange.Transformers.ValidateImportActionTest.DuplicateHeaders do
            use Ash.Resource,
                           domain: nil,
              validate_domain_inclusion?: false,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshCsvInterchange]

            csv_imports do
              csv_import :dup do
                label "Dup"
                headers required: ["Name", "name"]
                upsert_action :create_action
              end
            end

            identities do
              identity :name, [:name]
            end

            actions do
              defaults [:read]

              create :create_action do
                upsert? true
                upsert_identity :name
                argument :name, :string
                change set_attribute(:name, arg(:name))
              end
            end

            attributes do
              uuid_v7_primary_key :id
              attribute :name, :string
            end
          end
        """)
      end
    end

    test "raises when an upsert_identity key is not declared on the action" do
      assert_raise Spark.Error.DslError,
                   ~r/upsert_identity :external_id key\(s\) \[:external_id\]/,
                   fn ->
                     Code.eval_string("""
                       defmodule AshCsvInterchange.Transformers.ValidateImportActionTest.IdentityNotKnownToAction do
                         use Ash.Resource,
                           domain: nil,
                           validate_domain_inclusion?: false,
                           data_layer: Ash.DataLayer.Ets,
                           extensions: [AshCsvInterchange]

                         csv_imports do
                           csv_import :identity_not_known_to_action do
                             label "Identity Not Known To Action"
                             headers required: ["name"]
                             upsert_action :create_action
                           end
                         end

                         identities do
                           identity :external_id, [:external_id]
                         end

                         actions do
                           defaults [:read]

                           create :create_action do
                             upsert? true
                             upsert_identity :external_id
                             argument :name, :string
                             change set_attribute(:name, arg(:name))
                           end
                         end

                         attributes do
                           uuid_v7_primary_key :id
                           attribute :name, :string
                           attribute :external_id, :string
                         end
                       end
                     """)
                   end
    end

    test "accepts an upsert_identity key declared as an action argument even without a matching header" do
      assert {{:module, _, _, _}, _binding} =
               Code.eval_string("""
                 defmodule AshCsvInterchange.Transformers.ValidateImportActionTest.IdentityDeclaredAsArgument do
                   use Ash.Resource,
                     domain: nil,
                     validate_domain_inclusion?: false,
                     data_layer: Ash.DataLayer.Ets,
                     extensions: [AshCsvInterchange]

                   csv_imports do
                     csv_import :identity_declared_as_argument do
                       label "Identity Declared As Argument"
                       headers required: ["name"]
                       upsert_action :create_action
                     end
                   end

                   identities do
                     identity :external_id, [:external_id]
                   end

                   actions do
                     defaults [:read]

                     create :create_action do
                       upsert? true
                       upsert_identity :external_id
                       argument :name, :string
                       argument :external_id, :string
                       change set_attribute(:name, arg(:name))
                       change set_attribute(:external_id, arg(:external_id))
                     end
                   end

                   attributes do
                     uuid_v7_primary_key :id
                     attribute :name, :string
                     attribute :external_id, :string
                   end
                 end
               """)
    end

    test "raises when import_source attribute does not exist on the resource" do
      assert_raise Spark.Error.DslError,
                   ~r/import_source attribute :missing_source is not declared/,
                   fn ->
                     Code.eval_string("""
                       defmodule AshCsvInterchange.Transformers.ValidateImportActionTest.BadImportSource do
                         use Ash.Resource,
                           domain: nil,
                           validate_domain_inclusion?: false,
                           data_layer: Ash.DataLayer.Ets,
                           extensions: [AshCsvInterchange]

                         csv_imports do
                           csv_import :bad_import_source do
                             label "Bad Import Source"
                             headers required: ["name"]
                             upsert_action :create_action
                             import_source {:missing_source, :csv}
                           end
                         end

                         identities do
                           identity :name, [:name]
                         end

                         actions do
                           defaults [:read]

                           create :create_action do
                             upsert? true
                             upsert_identity :name
                             argument :name, :string
                             change set_attribute(:name, arg(:name))
                           end
                         end

                         attributes do
                           uuid_v7_primary_key :id
                           attribute :name, :string
                         end
                       end
                     """)
                   end
    end
  end
end
