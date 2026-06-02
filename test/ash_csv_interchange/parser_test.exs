defmodule AshCsvInterchange.Import.ParserTest do
  use ExUnit.Case, async: true

  alias AshCsvInterchange.Error
  alias AshCsvInterchange.Import.Parser

  describe "parse/1" do
    test "parses a simple two-row CSV" do
      csv = "name,email\nAlice,alice@example.com\nBob,bob@example.com\n"
      assert {:ok, rows} = Parser.parse(csv)

      assert Enum.to_list(rows) == [
               ["name", "email"],
               ["Alice", "alice@example.com"],
               ["Bob", "bob@example.com"]
             ]
    end

    test "strips a leading UTF-8 BOM" do
      csv = <<0xEF, 0xBB, 0xBF>> <> "name\nAlice\n"
      assert {:ok, rows} = Parser.parse(csv)
      assert Enum.to_list(rows) == [["name"], ["Alice"]]
    end

    test "handles quoted fields with embedded commas" do
      csv = ~s|name,location\n"Smith, John","New York"\n|
      assert {:ok, rows} = Parser.parse(csv)

      assert Enum.to_list(rows) == [
               ["name", "location"],
               ["Smith, John", "New York"]
             ]
    end

    test "handles escaped quotes within quoted fields" do
      csv = ~s|quote\n"He said ""hi"""\n|
      assert {:ok, rows} = Parser.parse(csv)
      assert Enum.to_list(rows) == [["quote"], [~s|He said "hi"|]]
    end

    test "returns an encoding error for invalid UTF-8 bytes" do
      csv = <<"name\n", 0xFF, 0xFE>>
      assert {:error, %Error{kind: :encoding}} = Parser.parse(csv)
    end

    test "returns a malformed_csv error for an unterminated quote" do
      csv = ~s|name\n"unterminated\n|
      assert {:error, %Error{kind: :malformed_csv}} = Parser.parse(csv)
    end

    test "produces an empty result for an empty binary" do
      assert {:ok, rows} = Parser.parse("")
      assert Enum.to_list(rows) == []
    end
  end
end
