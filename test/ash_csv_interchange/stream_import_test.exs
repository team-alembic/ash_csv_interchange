defmodule AshCsvInterchange.Import.StreamImportTest do
  use ExUnit.Case, async: false

  alias AshCsvInterchange.{Error, TestResource}
  alias AshCsvInterchange.Import.{Orchestrator, RowOutcome, StreamReport}

  describe "stream_import/4" do
    test "yields one lazy RowOutcome per non-blank row and returns setup metadata" do
      csv = "external_id,name,date_of_birth\nE1,Alice,2020-01-15\nE2,Bob,2019-03-22\n"

      assert {:ok, %StreamReport{outcomes: outcomes} = report} =
               Orchestrator.stream_import(TestResource, :test_resource, csv, mode: :dry_run)

      assert report.source_headers == ["external_id", "name", "date_of_birth"]
      assert report.warnings == []

      assert [
               %RowOutcome{line_no: 2, status: :ok},
               %RowOutcome{line_no: 3, status: :ok}
             ] = Enum.to_list(outcomes)
    end

    test "filters blank rows but preserves following line numbers" do
      csv = "external_id,name,date_of_birth\nE1,Alice,2020-01-15\n,,\nE2,Bob,2019-03-22\n"

      assert {:ok, %StreamReport{outcomes: outcomes}} =
               Orchestrator.stream_import(TestResource, :test_resource, csv, mode: :dry_run)

      assert [%RowOutcome{line_no: 2}, %RowOutcome{line_no: 4}] = Enum.to_list(outcomes)
    end

    test "is lazy: an unbounded source commits only the rows consumed" do
      rows = Stream.map(Stream.iterate(1, &(&1 + 1)), &"E#{&1},N#{&1},2020-01-01\n")
      source = Stream.concat(["external_id,name,date_of_birth\n"], rows)

      assert {:ok, %StreamReport{outcomes: outcomes}} =
               Orchestrator.stream_import(TestResource, :test_resource, source, mode: :commit)

      taken = outcomes |> Stream.take(5) |> Enum.to_list()

      assert length(taken) == 5
      assert Enum.all?(taken, &(&1.status == :ok))
      assert {:ok, persisted} = Ash.read(TestResource)
      assert length(persisted) == 5
    end

    test "does not retain the Ash record by default in commit mode" do
      csv = "external_id,name,date_of_birth\nE1,Alice,2020-01-15\n"

      assert {:ok, %StreamReport{outcomes: outcomes}} =
               Orchestrator.stream_import(TestResource, :test_resource, csv, mode: :commit)

      assert [%RowOutcome{status: :ok, record: nil, upsert_kind: :created}] = Enum.to_list(outcomes)
    end

    test "retains the record when retain_records?: true" do
      csv = "external_id,name,date_of_birth\nE1,Alice,2020-01-15\n"

      assert {:ok, %StreamReport{outcomes: outcomes}} =
               Orchestrator.stream_import(TestResource, :test_resource, csv,
                 mode: :commit,
                 retain_records?: true
               )

      assert [%RowOutcome{record: record}] = Enum.to_list(outcomes)
      assert record.external_id == "E1"
    end

    test "emits unknown-column warnings in the stream report" do
      csv = "external_id,name,date_of_birth,extra\nE1,Alice,2020-01-15,boo\n"

      assert {:ok, %StreamReport{warnings: [warning]}} =
               Orchestrator.stream_import(TestResource, :test_resource, csv, mode: :dry_run)

      assert warning.kind == :unknown_column
      assert warning.context.header == "extra"
    end

    test "returns fatal errors synchronously before any streaming" do
      assert {:error, %Error{kind: :empty_file}} =
               Orchestrator.stream_import(TestResource, :test_resource, "", mode: :dry_run)

      assert {:error, %Error{kind: :missing_required_headers}} =
               Orchestrator.stream_import(TestResource, :test_resource, "name\nAlice\n", mode: :dry_run)
    end
  end
end
