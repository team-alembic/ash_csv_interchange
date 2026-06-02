defmodule AshCsvInterchange.Export.SerializerTest do
  use ExUnit.Case, async: true

  alias AshCsvInterchange.Export.Serializer

  defmodule Record do
    @moduledoc false
    defstruct [:external_id, :first_name, :date, :active?, :amount]
  end

  defp record(overrides \\ []) do
    base = [
      external_id: "C-1",
      first_name: "Ada",
      date: ~D[2025-01-15],
      active?: true,
      amount: Decimal.new("12.50")
    ]

    struct(Record, Keyword.merge(base, overrides))
  end

  describe "row/2" do
    test "maps {header, field} entries using to_string on plain values" do
      columns = [{"external_id", :external_id}, {"first_name", :first_name}]
      assert Serializer.row(record(), columns) == ["C-1", "Ada"]
    end

    test "renders nil as an empty cell without calling the formatter" do
      caller = self()

      columns = [
        {"first_name", :first_name,
         [
           format: fn _ ->
             send(caller, :formatter_called)
             "should not appear"
           end
         ]}
      ]

      assert Serializer.row(record(first_name: nil), columns) == [""]
      refute_received :formatter_called
    end

    test "applies a 1-arity function formatter" do
      columns = [{"date", :date, [format: &Date.to_iso8601/1]}]
      assert Serializer.row(record(), columns) == ["2025-01-15"]
    end

    test "applies an MFA formatter, prepending the value" do
      columns = [{"date", :date, [format: {Date, :to_iso8601, [:extended]}]}]
      assert Serializer.row(record(), columns) == ["2025-01-15"]
    end

    test "renders false as \"false\" (not empty)" do
      columns = [{"active?", :active?}]
      assert Serializer.row(record(active?: false), columns) == ["false"]
    end

    test "renders Decimal via to_string" do
      columns = [{"amount", :amount}]
      assert Serializer.row(record(), columns) == ["12.50"]
    end
  end

  describe "header/1" do
    test "returns the column header strings in order" do
      columns = [
        {"external_id", :external_id},
        {"first_name", :first_name, [format: &to_string/1]},
        {"date_of_birth", :dob}
      ]

      assert Serializer.header(columns) == ["external_id", "first_name", "date_of_birth"]
    end
  end
end
