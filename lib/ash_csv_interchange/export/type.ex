defmodule AshCsvInterchange.Export.Type do
  @moduledoc """
  Resolved DSL config for one `csv_export` entity. Spark builds one
  struct per entity in a resource's `csv_exports` block, keyed by `id`.
  """

  defstruct [:id, :label, :read_action, :columns, __spark_metadata__: nil]

  @type column_opts :: keyword()
  @type column :: {String.t(), atom()} | {String.t(), atom(), column_opts()}

  @type t :: %__MODULE__{
          id: atom(),
          label: String.t(),
          read_action: atom(),
          columns: [column()]
        }
end
