defmodule AshCsvInterchangeTest do
  use ExUnit.Case, async: true

  test "the extension is compiled into the application" do
    assert AshCsvInterchange.installed?()
  end
end
