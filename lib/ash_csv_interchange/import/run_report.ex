defmodule AshCsvInterchange.Import.RunReport do
  @moduledoc """
  Structured result of a CSV import run.

  `outcomes` is an eager list (not a stream). `counts` is computed once
  at the end of the run from `outcomes`.
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
          warnings: [Error.t()],
          counts: Counts.t(),
          source_headers: [String.t()],
          input_keys: %{String.t() => atom()}
        }

  @doc """
  Builds a `Counts` struct from a list of outcomes.
  """
  @spec counts_from_outcomes([RowOutcome.t()], non_neg_integer()) :: Counts.t()
  def counts_from_outcomes(outcomes, blank_rows_skipped) do
    Enum.reduce(outcomes, %Counts{blank_rows_skipped: blank_rows_skipped}, fn outcome, acc ->
      acc = %{acc | total: acc.total + 1}

      case outcome.status do
        :ok ->
          acc = %{acc | succeeded: acc.succeeded + 1}

          case outcome.upsert_kind do
            :created -> %{acc | created: acc.created + 1}
            :updated -> %{acc | updated: acc.updated + 1}
            _ -> acc
          end

        _ ->
          %{acc | failed: acc.failed + 1}
      end
    end)
  end
end
