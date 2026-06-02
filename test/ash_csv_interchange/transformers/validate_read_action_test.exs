defmodule AshCsvInterchange.Transformers.ValidateReadActionTest do
  use ExUnit.Case, async: true

  describe "compile-time validation" do
    test "raises when the named read_action does not exist" do
      assert_raise Spark.Error.DslError, ~r/read_action :missing.*not declared/i, fn ->
        Code.eval_string("""
          defmodule AshCsvInterchange.Transformers.ValidateReadActionTest.MissingAction do
            use Ash.Resource,
              domain: nil,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshCsvInterchange],
              validate_domain_inclusion?: false

            csv_exports do
              csv_export :x do
                label "x"
                read_action :missing
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
      end
    end

    test "raises when an action of that name exists but is not a :read" do
      assert_raise Spark.Error.DslError, ~r/must be a :read action/, fn ->
        Code.eval_string("""
          defmodule AshCsvInterchange.Transformers.ValidateReadActionTest.NotARead do
            use Ash.Resource,
              domain: nil,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshCsvInterchange],
              validate_domain_inclusion?: false

            csv_exports do
              csv_export :x do
                label "x"
                read_action :delete_one
                columns [{"id", :id}]
              end
            end

            attributes do
              uuid_v7_primary_key :id
            end

            actions do
              defaults [:read]
              destroy :delete_one
            end
          end
        """)
      end
    end

    test "raises when a column field is not an attribute/calculation/aggregate" do
      assert_raise Spark.Error.DslError, ~r/column field :bogus.*not declared/i, fn ->
        Code.eval_string("""
          defmodule AshCsvInterchange.Transformers.ValidateReadActionTest.BogusField do
            use Ash.Resource,
              domain: nil,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshCsvInterchange],
              validate_domain_inclusion?: false

            csv_exports do
              csv_export :x do
                label "x"
                read_action :read
                columns [{"bogus", :bogus}]
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
      end
    end

    test "raises on duplicate column headers" do
      assert_raise Spark.Error.DslError, ~r/duplicate column header/i, fn ->
        Code.eval_string("""
          defmodule AshCsvInterchange.Transformers.ValidateReadActionTest.DupHeaders do
            use Ash.Resource,
              domain: nil,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshCsvInterchange],
              validate_domain_inclusion?: false

            csv_exports do
              csv_export :x do
                label "x"
                read_action :read
                columns [{"id", :id}, {"id", :id}]
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
      end
    end

    test "raises when format: function has the wrong arity" do
      assert_raise Spark.Error.DslError, ~r/format.*arity/i, fn ->
        Code.eval_string("""
          defmodule AshCsvInterchange.Transformers.ValidateReadActionTest.WrongArity do
            use Ash.Resource,
              domain: nil,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshCsvInterchange],
              validate_domain_inclusion?: false

            csv_exports do
              csv_export :x do
                label "x"
                read_action :read
                columns [{"id", :id, [format: &Map.get/2]}]
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
      end
    end

    test "raises a DslError when a column entry isn't a {header, field} or {header, field, opts} tuple" do
      assert_raise Spark.Error.DslError, fn ->
        Code.eval_string("""
          defmodule AshCsvInterchange.Transformers.ValidateReadActionTest.BadColumnShape do
            use Ash.Resource,
              domain: nil,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshCsvInterchange],
              validate_domain_inclusion?: false

            csv_exports do
              csv_export :x do
                label "x"
                read_action :read
                columns ["external_id"]
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
      end
    end

    test "raises when format: MFA references a missing function" do
      assert_raise Spark.Error.DslError, ~r/format.*does not export/i, fn ->
        Code.eval_string("""
          defmodule AshCsvInterchange.Transformers.ValidateReadActionTest.MissingMfa do
            use Ash.Resource,
              domain: nil,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshCsvInterchange],
              validate_domain_inclusion?: false

            csv_exports do
              csv_export :x do
                label "x"
                read_action :read
                columns [{"id", :id, [format: {Date, :nope, []}]}]
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
      end
    end
  end
end
