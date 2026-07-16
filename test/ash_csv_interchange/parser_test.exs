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

  describe "parse_stream/2" do
    @headers [required: ["external_id", "name"], optional: []]

    test "parses a binary: header eager, body lazy" do
      csv = "external_id,name\nE1,Alice\nE2,Bob\n"

      assert {:ok, {["external_id", "name"], body}} =
               Parser.parse_stream(csv, @headers)

      assert Enum.to_list(body) == [["E1", "Alice"], ["E2", "Bob"]]
    end

    test "parses from a {:path, _} source" do
      path = Path.join(System.tmp_dir!(), "acc215_parse_#{System.unique_integer([:positive])}.csv")
      File.write!(path, "external_id,name\nE1,Alice\n")
      on_exit(fn -> File.rm(path) end)

      assert {:ok, {["external_id", "name"], body}} =
               Parser.parse_stream({:path, path}, @headers)

      assert Enum.to_list(body) == [["E1", "Alice"]]
    end

    test "parses from an arbitrary chunk stream" do
      chunks = ["external_id,na", "me\nE1,Ali", "ce\n"]

      assert {:ok, {["external_id", "name"], body}} =
               Parser.parse_stream(chunks, @headers)

      assert Enum.to_list(body) == [["E1", "Alice"]]
    end

    test "strips a leading UTF-8 BOM from the header" do
      csv = <<0xEF, 0xBB, 0xBF>> <> "external_id,name\nE1,Alice\n"

      assert {:ok, {["external_id", "name"], _body}} =
               Parser.parse_stream(csv, @headers)
    end

    test "is lazy: an unbounded source yields rows on demand" do
      rows = Stream.map(Stream.iterate(1, &(&1 + 1)), &"E#{&1},N#{&1}\n")
      source = Stream.concat(["external_id,name\n"], rows)

      assert {:ok, {_header, body}} = Parser.parse_stream(source, @headers)
      assert body |> Stream.take(3) |> Enum.to_list() == [["E1", "N1"], ["E2", "N2"], ["E3", "N3"]]
    end

    test "returns :empty_file for empty input" do
      assert {:error, %Error{kind: :empty_file}} = Parser.parse_stream("", @headers)
    end

    test "auto-quotes a declared comma-containing header before parsing it" do
      headers = [required: ["external_id", {"a,b", :ab}], optional: []]
      csv = "external_id,a,b\nE1,X\n"

      assert {:ok, {["external_id", "a,b"], _body}} = Parser.parse_stream(csv, headers)
    end

    test "raises StreamError on invalid UTF-8 in a data row when consumed" do
      csv = "external_id,name\nE1," <> <<0xFF, 0xFE>> <> "\n"

      assert {:ok, {_header, body}} = Parser.parse_stream(csv, @headers)

      assert_raise Parser.StreamError, fn -> Enum.to_list(body) end
    end
  end
end
