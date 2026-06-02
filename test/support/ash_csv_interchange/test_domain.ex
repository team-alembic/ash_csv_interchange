defmodule AshCsvInterchange.TestDomain do
  @moduledoc """
  Ash domain for AshCsvInterchange integration tests. Not compiled in `:dev`
  or `:prod`.
  """

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshCsvInterchange.TestResource
  end
end
