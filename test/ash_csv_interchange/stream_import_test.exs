defmodule AshCsvInterchange.Import.StreamImportTest do
  use ExUnit.Case, async: false

  alias AshCsvInterchange.{Error, TestResource}
  alias AshCsvInterchange.Import.{Orchestrator, RowOutcome, RunReport, StreamReport}

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
      # batch_size: 1 pins the commit granularity to one row per write, so
      # taking 5 outcomes provably touches only 5 rows. Batched laziness
      # (bounded to one batch's worth at a time) is covered separately below.
      rows = Stream.map(Stream.iterate(1, &(&1 + 1)), &"E#{&1},N#{&1},2020-01-01\n")
      source = Stream.concat(["external_id,name,date_of_birth\n"], rows)

      assert {:ok, %StreamReport{outcomes: outcomes}} =
               Orchestrator.stream_import(TestResource, :test_resource, source,
                 mode: :commit,
                 batch_size: 1
               )

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

      assert [%RowOutcome{status: :ok, record: nil, upsert_kind: :created}] =
               Enum.to_list(outcomes)
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

    test "back-pressure: consuming N outcomes pulls only ~N rows from the source" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      # `Agent.start_link/1` links the counter to the test process. ExUnit
      # exits that process with `:shutdown`, which kills the agent before
      # `on_exit` runs. Guard against the dead agent so `on_exit` does not
      # fail on a noproc.
      on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)

      raw =
        Stream.concat(
          ["external_id,name,date_of_birth\n"],
          Stream.map(1..10_000, &"E#{&1},N#{&1},2020-01-01\n")
        )

      counted =
        Stream.map(raw, fn chunk ->
          Agent.update(counter, &(&1 + 1))
          chunk
        end)

      assert {:ok, %StreamReport{outcomes: outcomes}} =
               Orchestrator.stream_import(TestResource, :test_resource, counted, mode: :dry_run)

      taken = outcomes |> Stream.take(10) |> Enum.to_list()

      assert length(taken) == 10
      # Header read enumerates once and the body re-enumerates; even so,
      # producing 10 outcomes must not pull anywhere near all 10_000 rows.
      assert Agent.get(counter, & &1) < 100
    end

    test "returns :unreadable_source for a missing file path" do
      path =
        Path.join(System.tmp_dir!(), "acc215_missing_#{System.unique_integer([:positive])}.csv")

      assert {:error, %Error{kind: :unreadable_source}} =
               Orchestrator.stream_import(TestResource, :test_resource, {:path, path}, mode: :dry_run)
    end
  end

  describe "import_csv/4 bounded report" do
    test "counts are exact but outcomes are capped at :max_outcomes" do
      header = "external_id,name,date_of_birth\n"
      rows = Enum.map_join(1..250, "", &"E#{&1},N#{&1},2020-01-01\n")
      csv = header <> rows

      assert {:ok, %RunReport{counts: counts, outcomes: outcomes, outcomes_truncated?: true}} =
               Orchestrator.import_csv(TestResource, :test_resource, csv,
                 mode: :dry_run,
                 max_outcomes: 100
               )

      assert counts.total == 250
      assert counts.succeeded == 250
      assert length(outcomes) == 100
    end

    test "outcomes_truncated? is false when under the cap" do
      csv = "external_id,name,date_of_birth\nE1,Alice,2020-01-15\n"

      assert {:ok, %RunReport{outcomes_truncated?: false, outcomes: [_]}} =
               Orchestrator.import_csv(TestResource, :test_resource, csv, mode: :dry_run)
    end

    test "counts blank rows separately from outcomes" do
      csv = "external_id,name,date_of_birth\nE1,Alice,2020-01-15\n,,\nE2,Bob,2019-03-22\n"

      assert {:ok, %RunReport{counts: counts}} =
               Orchestrator.import_csv(TestResource, :test_resource, csv, mode: :dry_run)

      assert counts.total == 2
      assert counts.blank_rows_skipped == 1
    end

    test "does not retain records by default; retains them with retain_records?: true" do
      csv = "external_id,name,date_of_birth\nE1,Alice,2020-01-15\n"

      assert {:ok, %RunReport{outcomes: [%RowOutcome{record: nil}]}} =
               Orchestrator.import_csv(TestResource, :test_resource, csv, mode: :commit)

      assert {:ok, %RunReport{outcomes: [%RowOutcome{record: record}]}} =
               Orchestrator.import_csv(TestResource, :test_resource, csv,
                 mode: :commit,
                 retain_records?: true
               )

      assert record.external_id == "E1"
    end

    test "malformed CSV in the body returns a fatal error" do
      csv = ~s(external_id,name,date_of_birth\nE1,"unterminated,2020-01-15\n)

      assert {:error, %Error{kind: :malformed_csv}} =
               Orchestrator.import_csv(TestResource, :test_resource, csv, mode: :dry_run)
    end

    test "invalid UTF-8 in the body returns an encoding error" do
      csv = "external_id,name,date_of_birth\nE1," <> <<0xFF>> <> ",2020-01-15\n"

      assert {:error, %Error{kind: :encoding}} =
               Orchestrator.import_csv(TestResource, :test_resource, csv, mode: :dry_run)
    end
  end
end
