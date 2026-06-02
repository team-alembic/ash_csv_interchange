defmodule AshCsvInterchangeTest do
  use ExUnit.Case, async: false

  alias Ash.DataLayer.Ets
  alias AshCsvInterchange.Export.Type, as: ExportType

  alias AshCsvInterchange.{
    ExportTestDomain,
    ExportTestResource,
    RestrictedDomain,
    RestrictedExportDomain,
    TestDomain,
    TestResource
  }

  alias AshCsvInterchange.Import.{RowOutcome, RunReport}

  setup_all do
    original = Application.get_env(:ash_csv_interchange, AshCsvInterchange, [])
    domains = Keyword.get(original, :domains, [])

    Application.put_env(
      :ash_csv_interchange,
      AshCsvInterchange,
      Keyword.put(original, :domains, domains ++ [TestDomain, ExportTestDomain])
    )

    on_exit(fn -> Application.put_env(:ash_csv_interchange, AshCsvInterchange, original) end)
    :ok
  end

  describe "list_import_types/0" do
    test "includes every resource that has the AshCsvInterchange extension" do
      types = AshCsvInterchange.list_import_types()

      assert %{id: :test_resource, label: "Test Resource", resource: TestResource} in types
    end
  end

  describe "list_import_types/1 with actor filtering" do
    setup do
      original = Application.get_env(:ash_csv_interchange, AshCsvInterchange, [])
      domains = Keyword.get(original, :domains, [])

      Application.put_env(
        :ash_csv_interchange,
        AshCsvInterchange,
        Keyword.put(original, :domains, domains ++ [RestrictedDomain])
      )

      on_exit(fn -> Application.put_env(:ash_csv_interchange, AshCsvInterchange, original) end)
      :ok
    end

    test "without an actor, returns every registered type" do
      ids = AshCsvInterchange.list_import_types() |> Enum.map(& &1.id)
      assert :test_resource in ids
      assert :restricted in ids
    end

    test "with an actor, filters out types the actor cannot perform the upsert action on" do
      ids = AshCsvInterchange.list_import_types(actor: %{id: "anyone"}) |> Enum.map(& &1.id)
      assert :test_resource in ids
      refute :restricted in ids
    end
  end

  describe "fetch_import_type/1" do
    test "returns {:ok, %{resource:, type:}} for a known id" do
      assert {:ok, %{resource: TestResource, type: %AshCsvInterchange.Import.Type{id: :test_resource}}} =
               AshCsvInterchange.fetch_import_type(:test_resource)
    end

    test "returns {:error, %Error{kind: :type_not_found}} for an unknown id" do
      assert {:error, %AshCsvInterchange.Error{kind: :type_not_found}} =
               AshCsvInterchange.fetch_import_type(:does_not_exist)
    end
  end

  describe "import_csv/4" do
    setup do
      on_exit(fn -> Ets.stop(TestResource) end)
      :ok
    end

    test "delegates to Orchestrator end-to-end" do
      csv = """
      external_id,name,date_of_birth
      E1,Alice,2020-01-15
      """

      assert {:ok, %RunReport{outcomes: [%RowOutcome{status: :ok}]}} =
               AshCsvInterchange.import_csv(:test_resource, csv, mode: :commit)
    end
  end

  describe "list_export_types/0" do
    test "includes every resource that declares a csv_export" do
      types = AshCsvInterchange.list_export_types()

      assert %{id: :contacts, label: "Active Contacts", resource: ExportTestResource} in types
    end
  end

  describe "list_export_types/1 with actor filtering" do
    setup do
      original = Application.get_env(:ash_csv_interchange, AshCsvInterchange, [])
      domains = Keyword.get(original, :domains, [])

      Application.put_env(
        :ash_csv_interchange,
        AshCsvInterchange,
        Keyword.put(original, :domains, domains ++ [RestrictedExportDomain])
      )

      on_exit(fn -> Application.put_env(:ash_csv_interchange, AshCsvInterchange, original) end)
      :ok
    end

    test "without an actor, returns every registered type" do
      ids = AshCsvInterchange.list_export_types() |> Enum.map(& &1.id)
      assert :contacts in ids
      assert :restricted_export in ids
    end

    test "with an actor, filters out types the actor cannot perform the read action on" do
      ids = AshCsvInterchange.list_export_types(actor: %{id: "anyone"}) |> Enum.map(& &1.id)
      assert :contacts in ids
      refute :restricted_export in ids
    end
  end

  describe "fetch_export_type/1" do
    test "returns {:ok, %{resource:, type:}} for a known id" do
      assert {:ok, %{resource: ExportTestResource, type: %ExportType{id: :contacts}}} =
               AshCsvInterchange.fetch_export_type(:contacts)
    end

    test "returns {:error, %Error{kind: :type_not_found}} for an unknown id" do
      assert {:error, %AshCsvInterchange.Error{kind: :type_not_found}} =
               AshCsvInterchange.fetch_export_type(:does_not_exist)
    end
  end

  describe "stream_export/2" do
    setup do
      on_exit(fn -> Ets.stop(ExportTestResource) end)

      ExportTestResource.create_contact!(%{
        external_id: "C-1",
        first_name: "Ada",
        last_name: "Lovelace"
      })

      :ok
    end

    test "returns {:ok, stream} that yields header then rows" do
      assert {:ok, stream} = AshCsvInterchange.stream_export(:contacts)
      rendered = stream |> Enum.join() |> String.trim_trailing()

      [header, row] = String.split(rendered, "\r\n")
      assert header == "external_id,first_name,last_name"
      assert row == "C-1,Ada,Lovelace"
    end

    test "returns {:error, type_not_found} for an unknown id" do
      assert {:error, %AshCsvInterchange.Error{kind: :type_not_found}} =
               AshCsvInterchange.stream_export(:does_not_exist)
    end

    test "errors raised mid-stream propagate to the consumer" do
      assert {:ok, stream} = AshCsvInterchange.stream_export(:contacts_raising_formatter)

      assert_raise RuntimeError, "boom", fn ->
        Enum.to_list(stream)
      end
    end
  end

  describe "stream_export/2 with an unauthorised actor" do
    setup do
      original = Application.get_env(:ash_csv_interchange, AshCsvInterchange, [])
      domains = Keyword.get(original, :domains, [])

      Application.put_env(
        :ash_csv_interchange,
        AshCsvInterchange,
        Keyword.put(original, :domains, domains ++ [RestrictedExportDomain])
      )

      on_exit(fn -> Application.put_env(:ash_csv_interchange, AshCsvInterchange, original) end)
      :ok
    end

    test "returns {:error, :export_action_unauthorised} synchronously before any read" do
      assert {:error, %AshCsvInterchange.Error{} = error} =
               AshCsvInterchange.stream_export(:restricted_export, actor: %{id: "anyone"})

      assert error.kind == :export_action_unauthorised
      assert error.context.action == :read_restricted
    end
  end

  describe "export_csv/2" do
    setup do
      on_exit(fn -> Ets.stop(ExportTestResource) end)

      ExportTestResource.create_contact!(%{
        external_id: "C-1",
        first_name: "Ada",
        last_name: "Lovelace"
      })

      :ok
    end

    test "returns {:ok, binary} for a known id" do
      assert {:ok, binary} = AshCsvInterchange.export_csv(:contacts)
      assert binary =~ "external_id,first_name,last_name"
      assert binary =~ "C-1,Ada,Lovelace"
    end

    test "propagates errors from stream_export" do
      assert {:error, %AshCsvInterchange.Error{kind: :type_not_found}} =
               AshCsvInterchange.export_csv(:does_not_exist)
    end
  end
end
