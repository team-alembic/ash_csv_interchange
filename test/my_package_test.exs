defmodule MyPackageTest do
  use ExUnit.Case, async: true

  doctest MyPackage

  test "greets the world" do
    assert MyPackage.hello() == :world
  end
end
