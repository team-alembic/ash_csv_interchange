defmodule AshCsvInterchange.Import.StreamReport do
  @moduledoc """
  Result of `AshCsvInterchange.stream_import/3`.

  Setup metadata (`warnings`, `source_headers`, `input_keys`) is known
  after the header check and is returned eagerly. `outcomes` is a **lazy**
  stream of `%AshCsvInterchange.Import.RowOutcome{}` — one per non-blank
  data row. In `:commit` mode the underlying database writes happen as the
  stream is consumed. Blank rows are filtered from `outcomes`; aggregate
  counts (including blanks) are the domain of `import_csv/3`'s
  `%RunReport{}`.
  """

  alias AshCsvInterchange.Error

  @enforce_keys [:warnings, :source_headers, :input_keys, :outcomes]
  defstruct [:warnings, :source_headers, :input_keys, :outcomes]

  @type t :: %__MODULE__{
          warnings: [Error.t()],
          source_headers: [String.t()],
          input_keys: %{String.t() => atom()},
          outcomes: Enumerable.t()
        }
end
