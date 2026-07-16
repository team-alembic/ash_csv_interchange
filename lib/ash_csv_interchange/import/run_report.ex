defmodule AshCsvInterchange.Import.RunReport do
  @moduledoc """
  Structured result of a CSV import run.

  `counts` is exact over every row. `outcomes` is a **bounded preview** —
  the first `:max_outcomes` row outcomes (default 100); `outcomes_truncated?`
  is `true` when more rows were processed than retained. Callers needing
  every per-row outcome should use `AshCsvInterchange.stream_import/3` and
  fold the lazy stream themselves.
  """

  alias AshCsvInterchange.Error
  alias AshCsvInterchange.Import.RowOutcome

  defmodule Counts do
    @moduledoc """
    Aggregate counts derived from the per-row outcomes. `created` and
    `updated` are commit-mode only.
    """

    defstruct total: 0,
              succeeded: 0,
              failed: 0,
              created: 0,
              updated: 0,
              blank_rows_skipped: 0

    @type t :: %__MODULE__{
            total: non_neg_integer(),
            succeeded: non_neg_integer(),
            failed: non_neg_integer(),
            created: non_neg_integer(),
            updated: non_neg_integer(),
            blank_rows_skipped: non_neg_integer()
          }
  end

  @enforce_keys [
    :mode,
    :resource,
    :type_id,
    :outcomes,
    :outcomes_truncated?,
    :warnings,
    :counts,
    :source_headers,
    :input_keys
  ]
  defstruct [
    :mode,
    :resource,
    :type_id,
    :outcomes,
    :outcomes_truncated?,
    :warnings,
    :counts,
    :source_headers,
    :input_keys
  ]

  @type t :: %__MODULE__{
          mode: :dry_run | :commit,
          resource: module(),
          type_id: atom(),
          outcomes: [RowOutcome.t()],
          outcomes_truncated?: boolean(),
          warnings: [Error.t()],
          counts: Counts.t(),
          source_headers: [String.t()],
          input_keys: %{String.t() => atom()}
        }

  @doc """
  Folds a single outcome into a `Counts` accumulator. Public so callers
  folding a `stream_import/3` outcome stream can build the same aggregate
  that the bounded `import_csv/3` report uses.
  """
  @spec tally(Counts.t(), RowOutcome.t()) :: Counts.t()
  def tally(counts, outcome) do
    counts = %{counts | total: counts.total + 1}

    case outcome.status do
      :ok ->
        counts = %{counts | succeeded: counts.succeeded + 1}

        case outcome.upsert_kind do
          :created -> %{counts | created: counts.created + 1}
          :updated -> %{counts | updated: counts.updated + 1}
          _ -> counts
        end

      _ ->
        %{counts | failed: counts.failed + 1}
    end
  end

  @doc """
  Builds a `Counts` struct from a list of outcomes.
  """
  @spec counts_from_outcomes([RowOutcome.t()], non_neg_integer()) :: Counts.t()
  def counts_from_outcomes(outcomes, blank_rows_skipped) do
    Enum.reduce(outcomes, %Counts{blank_rows_skipped: blank_rows_skipped}, fn outcome, acc ->
      tally(acc, outcome)
    end)
  end
end
