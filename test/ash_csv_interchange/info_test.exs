defmodule AshCsvInterchange.InfoTest do
  use ExUnit.Case, async: true

  alias AshCsvInterchange.Export.Type, as: ExportType
  alias AshCsvInterchange.ExportTestResource
  alias AshCsvInterchange.Import.Type
  alias AshCsvInterchange.{Info, InfoPlainResource, InfoTestResource}

  describe "csv_import_types/1" do
    test "returns every declared csv_import entity as a Type struct" do
      types = Info.csv_import_types(InfoTestResource)

      assert [%Type{id: :info_test}, %Type{id: :info_test_archived}] = types
    end

    test "returns [] for a resource without the extension" do
      assert Info.csv_import_types(InfoPlainResource) == []
    end
  end

  describe "csv_import_type/2" do
    test "returns {:ok, type} when the id is declared on the resource" do
      assert {:ok, %Type{} = type} = Info.csv_import_type(InfoTestResource, :info_test)
      assert type.id == :info_test
      assert type.label == "Info Test"

      assert type.headers == [
               required: ["name", {"date_of_birth", :dob}],
               optional: [],
               ignored: []
             ]

      assert type.upsert_action == :create_action
      assert type.import_source == {:source, :csv}
    end

    test "returns :error when the id is not declared" do
      assert :error == Info.csv_import_type(InfoTestResource, :nope)
    end

    test "returns :error for a resource without the extension" do
      assert :error == Info.csv_import_type(InfoPlainResource, :anything)
    end
  end

  describe "csv_export_types/1" do
    test "returns every declared csv_export entity as a Type struct" do
      types = Info.csv_export_types(ExportTestResource)

      assert Enum.any?(types, fn t ->
               match?(%ExportType{id: :contacts, label: "Active Contacts"}, t)
             end)
    end

    test "returns [] for a resource without the extension" do
      assert Info.csv_export_types(InfoPlainResource) == []
    end
  end

  describe "csv_export_type/2" do
    test "returns {:ok, type} when the id is declared on the resource" do
      assert {:ok, %ExportType{} = type} = Info.csv_export_type(ExportTestResource, :contacts)
      assert type.id == :contacts
      assert type.read_action == :for_csv_export
    end

    test "returns :error when the id is not declared" do
      assert :error == Info.csv_export_type(ExportTestResource, :nope)
    end

    test "returns :error for a resource without the extension" do
      assert :error == Info.csv_export_type(InfoPlainResource, :anything)
    end
  end
end
