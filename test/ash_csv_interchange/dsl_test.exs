defmodule AshCsvInterchange.DslTest do
  use ExUnit.Case, async: true

  alias AshCsvInterchange.Export.Type
  alias AshCsvInterchange.ExportTestResource
  alias Spark.Dsl.Extension

  describe "csv_exports DSL" do
    test "compiles and exposes the export type via Spark introspection" do
      types = Extension.get_entities(ExportTestResource, [:csv_exports])
      type = Enum.find(types, &(&1.id == :contacts))

      assert %Type{
               id: :contacts,
               label: "Active Contacts",
               read_action: :for_csv_export
             } = type

      assert type.columns == [
               {"external_id", :external_id},
               {"first_name", :first_name},
               {"last_name", :last_name}
             ]
    end

    test "compiles when a column uses format: as a 1-arity function capture" do
      {{:module, mod, _, _}, _} =
        Code.eval_string("""
          defmodule AshCsvInterchange.DslTest.FormatFun do
            use Ash.Resource,
              domain: nil,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshCsvInterchange],
              validate_domain_inclusion?: false

            csv_exports do
              csv_export :x do
                label "x"
                read_action :read
                columns [{"id", :id, [format: &Kernel.inspect/1]}]
              end
            end

            attributes do
              uuid_v7_primary_key :id
            end

            actions do
              defaults [:read]
            end
          end
        """)

      [type] = Extension.get_entities(mod, [:csv_exports])
      assert [{"id", :id, opts}] = type.columns
      assert is_function(Keyword.fetch!(opts, :format), 1)
    end

    test "compiles when a column uses format: as a valid MFA tuple" do
      {{:module, mod, _, _}, _} =
        Code.eval_string("""
          defmodule AshCsvInterchange.DslTest.FormatMfa do
            use Ash.Resource,
              domain: nil,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshCsvInterchange],
              validate_domain_inclusion?: false

            csv_exports do
              csv_export :x do
                label "x"
                read_action :read
                columns [{"id", :id, [format: {Kernel, :inspect, []}]}]
              end
            end

            attributes do
              uuid_v7_primary_key :id
            end

            actions do
              defaults [:read]
            end
          end
        """)

      [type] = Extension.get_entities(mod, [:csv_exports])
      assert [{"id", :id, [format: {Kernel, :inspect, []}]}] = type.columns
    end

    test "compiles with multiple csv_export entities in the same block" do
      {{:module, mod, _, _}, _} =
        Code.eval_string("""
          defmodule AshCsvInterchange.DslTest.MultipleExports do
            use Ash.Resource,
              domain: nil,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshCsvInterchange],
              validate_domain_inclusion?: false

            csv_exports do
              csv_export :active do
                label "Active"
                read_action :read
                columns [{"id", :id}]
              end

              csv_export :archived do
                label "Archived"
                read_action :read
                columns [{"id", :id}]
              end
            end

            attributes do
              uuid_v7_primary_key :id
            end

            actions do
              defaults [:read]
            end
          end
        """)

      types = Extension.get_entities(mod, [:csv_exports])
      assert [%Type{id: :active}, %Type{id: :archived}] = types
    end

    test "compiles when a column field resolves to an aggregate" do
      {{:module, mod, _, _}, _} =
        Code.eval_string("""
          defmodule AshCsvInterchange.DslTest.AggregateField do
            use Ash.Resource,
              domain: nil,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshCsvInterchange],
              validate_domain_inclusion?: false

            csv_exports do
              csv_export :x do
                label "x"
                read_action :read
                columns [{"id", :id}, {"name_length", :name_length}]
              end
            end

            attributes do
              uuid_v7_primary_key :id
              attribute :name, :string, public?: true
            end

            aggregates do
              first :name_length, [], :name
            end

            actions do
              defaults [:read]
            end
          end
        """)

      [type] = Extension.get_entities(mod, [:csv_exports])
      assert [{"id", :id}, {"name_length", :name_length}] = type.columns
    end
  end
end
