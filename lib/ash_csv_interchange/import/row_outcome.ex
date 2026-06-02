defmodule AshCsvInterchange.Import.RowOutcome do
  @moduledoc """
  The result of processing a single CSV row.

  Status values:

  * `:ok` (dry-run) — changeset valid, not persisted
  * `:ok` (commit) — persisted; `:upsert_kind` is `:created` or `:updated`
  * `:invalid` (dry-run) — changeset has validation errors; see `:errors`
  * `:errored` (commit) — `Ash.create/1` returned `{:error, _}`; see `:errors`
  * `:crashed` (both) — exception caught during row processing; see `:errors`
  """

  @enforce_keys [:line_no, :status]
  defstruct [
    :line_no,
    :status,
    :upsert_kind,
    :record,
    :errors,
    :input
  ]

  @type status :: :ok | :invalid | :errored | :crashed
  @type upsert_kind :: :created | :updated | nil

  @type t :: %__MODULE__{
          line_no: pos_integer(),
          status: status(),
          upsert_kind: upsert_kind(),
          record: struct() | nil,
          errors: list() | nil,
          input: map() | nil
        }
end
