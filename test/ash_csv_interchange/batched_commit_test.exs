defmodule AshCsvInterchange.Import.BatchedCommitTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias AshCsvInterchange.{CrashingResource, DbErrorResource, TestDomain, TestResource}
  alias AshCsvInterchange.Import.Orchestrator

  # Runs `fun` inside a fresh process so the Ets-backed resources under test
  # (private tables scoped to the calling process) start from an empty
  # table, letting a single test compare two independent commit runs.
  defp isolated(fun) do
    Task.async(fun) |> Task.await()
  end

  describe "batch_size parity with per-row commit" do
    test "identical outcomes and persisted state for new, updated, invalid, and duplicate-identity rows" do
      csv = """
      external_id,name,date_of_birth
      E1,Alice,2020-01-15
      E2,Bob,2019-03-22
      E1,AliceUpdated,2020-01-15
      E3,Carol,not-a-date
      E4,Dave,2021-01-01
      """

      batched =
        isolated(fn ->
          {:ok, report} =
            Orchestrator.import_csv(TestResource, :test_resource, csv,
              mode: :commit,
              batch_size: 100
            )

          {report, Ash.read!(TestResource) |> Enum.find(&(&1.external_id == "E1"))}
        end)

      per_row =
        isolated(fn ->
          {:ok, report} =
            Orchestrator.import_csv(TestResource, :test_resource, csv,
              mode: :commit,
              batch_size: 1
            )

          {report, Ash.read!(TestResource) |> Enum.find(&(&1.external_id == "E1"))}
        end)

      {batched_report, batched_e1} = batched
      {per_row_report, per_row_e1} = per_row

      assert shape(batched_report.outcomes) == shape(per_row_report.outcomes)
      assert batched_report.counts == per_row_report.counts

      # The duplicated identity (E1) must persist as though the two rows
      # committed sequentially — the later row's values win.
      assert batched_e1.name == "AliceUpdated"
      assert per_row_e1.name == "AliceUpdated"
    end

    defp shape(outcomes) do
      Enum.map(outcomes, &{&1.line_no, &1.status, &1.upsert_kind})
    end
  end

  describe "validation-failure isolation in batch mode" do
    test "an invalid row's batch-mates are still committed and queryable" do
      csv = """
      external_id,name,date_of_birth
      E1,Alice,2020-01-15
      E2,Bob,not-a-date
      E3,Carol,2021-05-01
      """

      assert {:ok, report} =
               Orchestrator.import_csv(TestResource, :test_resource, csv,
                 mode: :commit,
                 batch_size: 100
               )

      [e1, e2, e3] = report.outcomes
      assert e1.status == :ok
      assert e2.status in [:invalid, :errored]
      assert e3.status == :ok

      assert {:ok, records} = Ash.read(TestResource)
      assert Enum.map(records, & &1.external_id) |> Enum.sort() == ["E1", "E3"]
    end
  end

  describe "data-layer-error isolation in batch mode" do
    test "a row that fails after validation still lets its batch-mates commit" do
      csv = """
      name
      ok1
      reject
      ok2
      """

      assert {:ok, report} =
               Orchestrator.import_csv(DbErrorResource, :db_error, csv,
                 mode: :commit,
                 batch_size: 100
               )

      [ok1, rejected, ok2] = report.outcomes
      assert ok1.status == :ok
      assert ok2.status == :ok
      assert rejected.status == :errored
      assert rejected.line_no == 3

      assert {:ok, records} = Ash.read(DbErrorResource)
      assert Enum.map(records, & &1.name) |> Enum.sort() == ["ok1", "ok2"]
    end
  end

  describe "crash isolation in batch mode" do
    test "a raising row's batch-mates are still committed" do
      csv = """
      name
      ok1
      boom
      ok2
      """

      {result, log} =
        with_log(fn ->
          Orchestrator.import_csv(CrashingResource, :crashing, csv,
            mode: :commit,
            batch_size: 100
          )
        end)

      assert {:ok, report} = result

      # The warning is a deliberate signal. Assert it, do not hide it.
      assert log =~ "Ash.bulk_create raised"

      [ok1, crashed, ok2] = report.outcomes
      assert ok1.status == :ok
      assert crashed.status == :crashed
      assert ok2.status == :ok

      # CrashingResource's table isn't private, so scope the read to this
      # test's own rows rather than asserting on the table's full contents.
      assert {:ok, records} = Ash.read(CrashingResource)
      names = records |> MapSet.new(& &1.name)
      assert MapSet.subset?(MapSet.new(["ok1", "ok2"]), names)
      refute MapSet.member?(names, "boom")
    end
  end

  describe "query budget" do
    test "the primary upsert issues at most one dispatch per batch, not per row" do
      domain_short_name = Ash.Domain.Info.short_name(TestDomain)
      bulk_create_event = [:ash, domain_short_name, :bulk_create, :start]
      create_event = [:ash, domain_short_name, :create, :start]
      handler_id = {__MODULE__, :query_budget, make_ref()}

      test_pid = self()

      :telemetry.attach_many(
        handler_id,
        [bulk_create_event, create_event],
        fn event, _measurements, _metadata, _config -> send(test_pid, {:telemetry, event}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      header = "external_id,name,date_of_birth\n"
      rows = Enum.map_join(1..250, "", &"E#{&1},N#{&1},2020-01-01\n")
      csv = header <> rows

      assert {:ok, report} =
               Orchestrator.import_csv(TestResource, :test_resource, csv,
                 mode: :commit,
                 batch_size: 100
               )

      assert report.counts.total == 250
      assert report.counts.succeeded == 250

      bulk_create_dispatches = count_events(bulk_create_event)
      per_row_dispatches = count_events(create_event)

      # ceil(250 / 100) == 3 batches; every row is new and unique, so the
      # batch path should account for all of them without falling back.
      assert bulk_create_dispatches == 3
      assert per_row_dispatches == 0
    end

    defp count_events(event, acc \\ 0) do
      receive do
        {:telemetry, ^event} -> count_events(event, acc + 1)
      after
        0 -> acc
      end
    end
  end

  describe "laziness and bounded buffering" do
    test "consuming fewer outcomes than one batch pulls only that many rows from the source" do
      rows = Stream.map(Stream.iterate(1, &(&1 + 1)), &"E#{&1},N#{&1},2020-01-01\n")
      source = Stream.concat(["external_id,name,date_of_birth\n"], rows)

      assert {:ok, %{outcomes: outcomes}} =
               Orchestrator.stream_import(TestResource, :test_resource, source,
                 mode: :commit,
                 batch_size: 10
               )

      taken = outcomes |> Stream.take(3) |> Enum.to_list()

      assert length(taken) == 3
      assert {:ok, persisted} = Ash.read(TestResource)
      # Consuming 3 of 10 outcomes still forces the whole batch that
      # contains them to be dispatched and committed, but no more —
      # proving the stream buffers at most one batch at a time rather
      # than materialising the (here, unbounded) source.
      assert length(persisted) == 10
    end

    test "consuming outcomes across a batch boundary pulls only up to two batches" do
      rows = Stream.map(Stream.iterate(1, &(&1 + 1)), &"E#{&1},N#{&1},2020-01-01\n")
      source = Stream.concat(["external_id,name,date_of_birth\n"], rows)

      assert {:ok, %{outcomes: outcomes}} =
               Orchestrator.stream_import(TestResource, :test_resource, source,
                 mode: :commit,
                 batch_size: 10
               )

      taken = outcomes |> Stream.take(12) |> Enum.to_list()

      assert length(taken) == 12
      assert {:ok, persisted} = Ash.read(TestResource)
      assert length(persisted) == 20
    end
  end
end
