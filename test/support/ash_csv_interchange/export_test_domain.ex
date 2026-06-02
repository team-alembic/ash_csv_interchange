defmodule AshCsvInterchange.ExportTestDomain do
  @moduledoc """
  Ash domain for AshCsvInterchange export integration tests. Not compiled in
  `:dev` or `:prod`.
  """

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshCsvInterchange.ExportTestResource
  end
end
