defmodule AshCsvInterchange.Import.OrchestratorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias AshCsvInterchange.{
    ActorAwareResource,
    CrashingResource,
    Error,
    LockedResource,
    PlainResource,
    TenantAwareResource,
    TestResource
  }

  alias AshCsvInterchange.Import.{Orchestrator, RowOutcome, RunReport}

  describe "import_csv/4 in :dry_run mode" do
    test "returns :ok outcomes for valid rows without persisting" do
      csv = """
      external_id,name,date_of_birth
      E1,Alice,2020-01-15
      E2,Bob,2019-03-22
      """

      assert {:ok, %RunReport{mode: :dry_run, outcomes: outcomes, counts: counts} = report} =
               Orchestrator.import_csv(TestResource, :test_resource, csv, mode: :dry_run)

      assert report.source_headers == ["external_id", "name", "date_of_birth"]

      assert report.input_keys == %{
               "external_id" => :external_id,
               "name" => :name,
               "date_of_birth" => :dob,
               "note" => :note
             }

      assert [
               %RowOutcome{line_no: 2, status: :ok, record: nil, upsert_kind: nil},
               %RowOutcome{line_no: 3, status: :ok, record: nil, upsert_kind: nil}
             ] = outcomes

      assert counts.total == 2
      assert counts.succeeded == 2
      assert counts.failed == 0

      assert {:ok, []} = Ash.read(TestResource)
    end

    test "returns :invalid outcomes for rows with validation errors" do
      csv = """
      external_id,name,date_of_birth
      E1,,2020-01-15
      """

      assert {:ok, %RunReport{outcomes: [outcome]}} =
               Orchestrator.import_csv(TestResource, :test_resource, csv, mode: :dry_run)

      assert outcome.status == :invalid
      assert outcome.errors != nil
    end

    test "auto-quotes declared comma-containing headers when source is unquoted" do
      # The source leaves the comma-bearing header unquoted, as some exports
      # do. Without auto-quoting, NimbleCSV splits it and HeaderCheck reports
      # :duplicate_headers.
      unquoted_csv = """
      external_id,name,Substr(b,5,2)!!'/'!!substr(b,7,2)!!'/'!!substr(b,1,4)
      EXT1,Alice,1990-04-12
      """

      resource = AshCsvInterchange.Import.OrchestratorTest.UnquotedHeaderResource

      assert {:ok, %RunReport{} = report} =
               Orchestrator.import_csv(resource, :unquoted_test, unquoted_csv, mode: :dry_run)

      assert report.counts.total == 1
      assert report.counts.succeeded == 1

      assert report.source_headers == [
               "external_id",
               "name",
               "Substr(b,5,2)!!'/'!!substr(b,7,2)!!'/'!!substr(b,1,4)"
             ]
    end
  end

  describe "import_csv/4 in :commit mode" do
    test "persists valid rows and reports them as :created" do
      csv = """
      external_id,name,date_of_birth
      E1,Alice,2020-01-15
      E2,Bob,2019-03-22
      """

      assert {:ok, %RunReport{mode: :commit, outcomes: outcomes, counts: counts}} =
               Orchestrator.import_csv(TestResource, :test_resource, csv, mode: :commit)

      assert Enum.count(outcomes) == 2
      assert Enum.all?(outcomes, &(&1.status == :ok))
      assert Enum.all?(outcomes, &(&1.upsert_kind == :created))
      assert counts.created == 2
      assert counts.updated == 0

      assert {:ok, [_, _]} = Ash.read(TestResource)
    end

    test "marks re-imported rows as :updated" do
      csv = """
      external_id,name,date_of_birth
      E1,Alice,2020-01-15
      """

      {:ok, _} = Orchestrator.import_csv(TestResource, :test_resource, csv, mode: :commit)

      updated_csv = """
      external_id,name,date_of_birth
      E1,Alicia,2020-01-15
      """

      assert {:ok, %RunReport{counts: counts, outcomes: [outcome]}} =
               Orchestrator.import_csv(TestResource, :test_resource, updated_csv, mode: :commit)

      assert outcome.upsert_kind == :updated
      assert counts.updated == 1
      assert counts.created == 0
    end
  end

  describe "import_csv/4 fatal errors" do
    test "returns :extension_not_loaded for a resource without the extension" do
      assert {:error, %Error{kind: :extension_not_loaded}} =
               Orchestrator.import_csv(PlainResource, :anything, "name\nA\n", mode: :dry_run)
    end

    test "returns :empty_file for empty input" do
      assert {:error, %Error{kind: :empty_file}} =
               Orchestrator.import_csv(TestResource, :test_resource, "", mode: :dry_run)
    end

    test "returns :missing_required_headers when headers are incomplete" do
      assert {:error, %Error{kind: :missing_required_headers}} =
               Orchestrator.import_csv(TestResource, :test_resource, "name\nAlice\n", mode: :dry_run)
    end
  end

  describe "import_csv/4 per-row error isolation" do
    test "captures Ash action errors as :errored or :invalid and continues" do
      bad_csv = """
      external_id,name,date_of_birth
      E2,Bob,not-a-date
      E3,Carol,2021-05-01
      """

      assert {:ok, %RunReport{outcomes: outcomes, counts: counts}} =
               Orchestrator.import_csv(TestResource, :test_resource, bad_csv, mode: :commit)

      [bob, carol] = outcomes

      assert bob.status in [:invalid, :errored]
      assert carol.status == :ok
      assert counts.failed == 1
      assert counts.succeeded == 1
    end

    test "captures exceptions raised during row processing as :crashed" do
      csv = """
      name
      ok
      boom
      still_ok
      """

      {result, log} =
        with_log(fn ->
          Orchestrator.import_csv(CrashingResource, :crashing, csv, mode: :commit)
        end)

      assert {:ok, %RunReport{outcomes: outcomes}} = result
      assert log =~ "Ash.bulk_create raised"

      [ok1, crashed, ok2] = outcomes
      assert ok1.status == :ok
      assert crashed.status == :crashed
      assert crashed.errors != nil
      assert ok2.status == :ok
    end
  end

  describe "import_csv/4 blank rows and unknown columns" do
    test "skips blank rows and preserves spreadsheet line numbers for following rows" do
      csv = "external_id,name,date_of_birth\nE1,Alice,2020-01-15\n,,\nE2,Bob,2019-03-22\n"

      assert {:ok, %RunReport{outcomes: outcomes, counts: counts}} =
               Orchestrator.import_csv(TestResource, :test_resource, csv, mode: :commit)

      assert [%RowOutcome{line_no: 2}, %RowOutcome{line_no: 4}] = outcomes
      assert counts.blank_rows_skipped == 1
    end

    test "emits unknown-column warnings while still processing rows" do
      csv = """
      external_id,name,date_of_birth,extra
      E1,Alice,2020-01-15,boo
      """

      assert {:ok, %RunReport{warnings: [warning], outcomes: [outcome]}} =
               Orchestrator.import_csv(TestResource, :test_resource, csv, mode: :commit)

      assert warning.kind == :unknown_column
      assert warning.context.header == "extra"
      assert outcome.status == :ok
    end
  end

  describe "import_csv/4 import_source stamping" do
    test "sets the configured attribute on every committed record" do
      csv = """
      external_id,name,date_of_birth
      E1,Alice,2020-01-15
      """

      assert {:ok, %RunReport{outcomes: [%RowOutcome{record: record}]}} =
               Orchestrator.import_csv(TestResource, :test_resource, csv, mode: :commit, retain_records?: true)

      assert record.source == :csv
    end
  end

  describe "import_csv/4 row shape edge cases" do
    test "blank middle cell is preserved at the correct column position" do
      # The middle column (name) is empty — input map should pair every header
      # with its position-aligned value, including the empty string.
      csv = "external_id,name,date_of_birth\nE1,,2020-01-15\n"

      assert {:ok, %RunReport{outcomes: [outcome]}} =
               Orchestrator.import_csv(TestResource, :test_resource, csv, mode: :dry_run)

      assert outcome.input == %{external_id: "E1", name: "", dob: "2020-01-15"}
    end

    test "ragged-right row drops missing trailing keys from the input map" do
      # Row "E1,Alice" omits the date_of_birth cell entirely. The input map
      # carries only the cells that were present.
      csv = "external_id,name,date_of_birth\nE1,Alice\n"

      assert {:ok, %RunReport{outcomes: [outcome]}} =
               Orchestrator.import_csv(TestResource, :test_resource, csv, mode: :dry_run)

      assert outcome.input == %{external_id: "E1", name: "Alice"}
    end
  end

  describe "import_csv/4 actor propagation" do
    test "propagates the actor opt to the Ash action" do
      csv = "name\nAlice\n"
      actor = %{id: "actor-123"}

      assert {:ok, %RunReport{outcomes: [%RowOutcome{record: record}]}} =
               Orchestrator.import_csv(ActorAwareResource, :actor_aware, csv,
                 mode: :commit,
                 actor: actor,
                 retain_records?: true
               )

      assert record.imported_by == "actor-123"
    end

    test "passes nil when no actor is supplied" do
      csv = "name\nBob\n"

      assert {:ok, %RunReport{outcomes: [%RowOutcome{record: record}]}} =
               Orchestrator.import_csv(ActorAwareResource, :actor_aware, csv,
                 mode: :commit,
                 retain_records?: true
               )

      assert record.imported_by == nil
    end
  end

  describe "import_csv/4 authorize? opt" do
    test "with default authorize?, deny-all policies surface as :errored outcomes" do
      csv = "name\nAlice\n"

      assert {:ok, %RunReport{outcomes: [%RowOutcome{status: :errored}]}} =
               Orchestrator.import_csv(LockedResource, :locked, csv,
                 mode: :commit,
                 actor: %{id: "anyone"}
               )
    end

    test "authorize?: false bypasses policy denial" do
      csv = "name\nAlice\n"

      # credo:disable-for-next-line AshCredo.Check.Warning.AuthorizeFalse
      opts = [mode: :commit, actor: %{id: "anyone"}, authorize?: false, retain_records?: true]

      assert {:ok, %RunReport{outcomes: [%RowOutcome{status: :ok, record: record}]}} =
               Orchestrator.import_csv(LockedResource, :locked, csv, opts)

      assert record.name == "Alice"
    end
  end

  describe "import_csv/4 tenant propagation" do
    test "propagates the tenant opt to the Ash changeset" do
      csv = "name\nAlice\n"

      assert {:ok, %RunReport{outcomes: [%RowOutcome{record: record}]}} =
               Orchestrator.import_csv(TenantAwareResource, :tenant_aware, csv,
                 mode: :commit,
                 tenant: "tenant-acme",
                 retain_records?: true
               )

      assert record.captured_tenant == "tenant-acme"
    end
  end
end
