defmodule AshCsvInterchange.Error do
  @moduledoc """
  An `AshCsvInterchange` error or non-fatal warning, used by both the
  import and export sides.

  Fatal errors come back as `{:error, %Error{}}` from the entry-point
  functions. Per-row import errors are carried inside
  `AshCsvInterchange.Import.RowOutcome.errors`. Non-fatal issues like
  an unknown column collect on `RunReport.warnings` with the same
  shape, distinguished by `kind`.
  """

  @enforce_keys [:kind, :message]
  defstruct [:kind, :message, context: %{}]

  @type kind ::
          :extension_not_loaded
          | :type_not_found
          | :duplicate_type_ids
          | :empty_file
          | :encoding
          | :unreadable_source
          | :malformed_csv
          | :missing_required_headers
          | :duplicate_headers
          | :ash_validation
          | :ash_action_failed
          | :transform_crashed
          | :unknown_column
          | :export_action_unauthorised

  @type t :: %__MODULE__{
          kind: kind(),
          message: String.t(),
          context: map()
        }
end
