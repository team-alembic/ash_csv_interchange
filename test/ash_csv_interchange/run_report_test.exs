defmodule AshCsvInterchange.Import.RunReportTest do
  use ExUnit.Case, async: true

  alias AshCsvInterchange.Import.{RowOutcome, RunReport}
  alias AshCsvInterchange.Import.RunReport.Counts

  test "counts_from_outcomes tallies statuses, upsert kinds, and blanks" do
    outcomes = [
      %RowOutcome{line_no: 2, status: :ok, upsert_kind: :created},
      %RowOutcome{line_no: 3, status: :ok, upsert_kind: :updated},
      %RowOutcome{line_no: 4, status: :ok, upsert_kind: nil},
      %RowOutcome{line_no: 5, status: :errored, errors: []},
      %RowOutcome{line_no: 6, status: :invalid, errors: []}
    ]

    assert %Counts{
             total: 5,
             succeeded: 3,
             failed: 2,
             created: 1,
             updated: 1,
             blank_rows_skipped: 7
           } = RunReport.counts_from_outcomes(outcomes, 7)
  end

  test "tally/2 folds a single outcome" do
    assert %Counts{total: 1, succeeded: 1, created: 1} =
             RunReport.tally(%Counts{}, %RowOutcome{line_no: 2, status: :ok, upsert_kind: :created})
  end
end
