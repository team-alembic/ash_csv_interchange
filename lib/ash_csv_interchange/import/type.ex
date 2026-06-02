defmodule AshCsvInterchange.Import.Type do
  @moduledoc """
  Struct that holds a single `csv_import` entity's resolved DSL config.
  Each entity inside a resource's `csv_imports do ... end` block is built
  into one `%AshCsvInterchange.Import.Type{}` keyed by `id`.
  """

  defstruct [:id, :label, :headers, :upsert_action, :import_source, __spark_metadata__: nil]

  @type t :: %__MODULE__{
          id: atom(),
          label: String.t(),
          headers: keyword(),
          upsert_action: atom(),
          import_source: {atom(), term()} | nil
        }
end
