defmodule AshCsvInterchange.RoundTripTest do
  use ExUnit.Case, async: false

  alias AshCsvInterchange.ExportTestDomain
  alias AshCsvInterchange.ExportTestResource

  setup_all do
    original = Application.get_env(:ash_csv_interchange, AshCsvInterchange, [])
    domains = Keyword.get(original, :domains, [])

    Application.put_env(
      :ash_csv_interchange,
      AshCsvInterchange,
      Keyword.put(original, :domains, domains ++ [ExportTestDomain])
    )

    on_exit(fn -> Application.put_env(:ash_csv_interchange, AshCsvInterchange, original) end)
    :ok
  end

  test "export → import → same record set" do
    for {ext, first, last} <- [
          {"C-1", "Ada", "Lovelace"},
          {"C-2", "Grace", "Hopper"},
          {"C-3", "Hedy", "Lamarr"}
        ] do
      ExportTestResource.create_contact!(%{
        external_id: ext,
        first_name: first,
        last_name: last
      })
    end

    {:ok, csv} = AshCsvInterchange.export_csv(:contacts)

    ExportTestResource
    |> Ash.read!(domain: ExportTestDomain)
    |> Enum.each(&Ash.destroy!(&1, domain: ExportTestDomain))

    assert {:ok, %AshCsvInterchange.Import.RunReport{counts: %{succeeded: 3, failed: 0}}} =
             AshCsvInterchange.import_csv(:contacts, csv, mode: :commit)

    reimported =
      ExportTestResource
      |> Ash.Query.sort(external_id: :asc)
      |> Ash.read!(domain: ExportTestDomain)
      |> Enum.map(&{&1.external_id, &1.first_name, &1.last_name})

    assert reimported == [
             {"C-1", "Ada", "Lovelace"},
             {"C-2", "Grace", "Hopper"},
             {"C-3", "Hedy", "Lamarr"}
           ]
  end

  test "export → import → export is idempotent against existing records" do
    for {ext, first, last} <- [
          {"C-1", "Ada", "Lovelace"},
          {"C-2", "Grace", "Hopper"},
          {"C-3", "Hedy", "Lamarr"}
        ] do
      ExportTestResource.create_contact!(%{
        external_id: ext,
        first_name: first,
        last_name: last
      })
    end

    ids_before = primary_keys_by_external_id()

    {:ok, first_csv} = AshCsvInterchange.export_csv(:contacts)

    # No clearing of records here: importing against the live rows must upsert on the
    # external_id identity rather than insert duplicates.
    assert {:ok, %AshCsvInterchange.Import.RunReport{counts: %{succeeded: 3, failed: 0}}} =
             AshCsvInterchange.import_csv(:contacts, first_csv, mode: :commit)

    # Same records (same primary keys), not a fresh set re-created by the import.
    assert primary_keys_by_external_id() == ids_before

    {:ok, second_csv} = AshCsvInterchange.export_csv(:contacts)
    assert second_csv == first_csv
  end

  defp primary_keys_by_external_id do
    ExportTestResource
    |> Ash.Query.sort(external_id: :asc)
    |> Ash.read!(domain: ExportTestDomain)
    |> Enum.map(&{&1.external_id, &1.id})
  end
end
