defmodule AshCsvInterchange.Import.HeaderCheckTest do
  use ExUnit.Case, async: true

  alias AshCsvInterchange.Error
  alias AshCsvInterchange.Import.HeaderCheck

  @config [
    required: ["name", "email", {"date_of_birth", :dob}],
    optional: ["note"]
  ]

  describe "verify/2" do
    test "accepts a header row containing exactly the required headers" do
      assert {:ok, %{headers: ["name", "email", "date_of_birth"], warnings: []}} =
               HeaderCheck.verify(["name", "email", "date_of_birth"], @config)
    end

    test "accepts a header row with all required and some optional headers" do
      assert {:ok, %{headers: ["name", "email", "date_of_birth", "note"], warnings: []}} =
               HeaderCheck.verify(["name", "email", "date_of_birth", "note"], @config)
    end

    test "normalises whitespace and casing before comparison" do
      assert {:ok, %{headers: ["name", "email", "date_of_birth"], warnings: []}} =
               HeaderCheck.verify([" Name ", "EMAIL", "Date_Of_Birth"], @config)
    end

    test "returns an error listing every missing required header" do
      assert {:error, %Error{kind: :missing_required_headers, context: context}} =
               HeaderCheck.verify(["note"], @config)

      assert Enum.sort(context.missing) == ["date_of_birth", "email", "name"]
    end

    test "emits a warning for each header that is neither required nor optional" do
      assert {:ok, %{warnings: warnings}} =
               HeaderCheck.verify(
                 ["name", "email", "date_of_birth", "extra1", "extra2"],
                 @config
               )

      kinds = Enum.map(warnings, & &1.kind)
      headers = warnings |> Enum.map(&get_in(&1.context, [:header])) |> Enum.sort()

      assert kinds == [:unknown_column, :unknown_column]
      assert headers == ["extra1", "extra2"]
    end

    test "silences warnings for ignored columns without surfacing them as inputs" do
      config = [
        required: ["name"],
        optional: [],
        ignored: ["Resource #", "Unit Type"]
      ]

      assert {:ok, %{headers: headers, warnings: warnings}} =
               HeaderCheck.verify(["name", "Resource #", "Unit Type"], config)

      assert headers == ["name", "resource #", "unit type"]
      assert warnings == []
    end

    test "returns an error when the header row contains a duplicate" do
      assert {:error, %Error{kind: :duplicate_headers, context: context}} =
               HeaderCheck.verify(["name", "email", "name"], @config)

      assert context.duplicates == ["name"]
    end

    test "treats headers that collide after normalisation as duplicates" do
      assert {:error, %Error{kind: :duplicate_headers, context: context}} =
               HeaderCheck.verify(["Name", "name", "email"], @config)

      assert context.duplicates == ["name"]
    end
  end

  describe "verify/2 — unquoted comma hint" do
    test "duplicate-headers error message includes a hint when fragments come from a comma-containing declared header" do
      declared = [
        required: [
          "name",
          {"Substr(b,5,2)!!'/'!!substr(b,7,2)!!'/'!!substr(b,1,4)", :dob}
        ],
        optional: []
      ]

      parsed_header_row = [
        "name",
        "Substr(b",
        "5",
        "2)!!'/'!!substr(b",
        "7",
        "2)!!'/'!!substr(b",
        "1",
        "4)"
      ]

      assert {:error, %Error{kind: :duplicate_headers, message: message}} =
               HeaderCheck.verify(parsed_header_row, declared)

      assert message =~ "unquoted commas"
      assert message =~ "RFC 4180"
      assert message =~ "Substr(b,5,2)!!'/'!!substr(b,7,2)!!'/'!!substr(b,1,4)"
    end

    test "missing-required-headers error message includes a hint when the missing column has commas" do
      declared = [
        required: [
          "name",
          {"Substr(b,5,2)!!'/'!!substr(b,7,2)!!'/'!!substr(b,1,4)", :dob}
        ],
        optional: []
      ]

      parsed_header_row = ["name"]

      assert {:error, %Error{kind: :missing_required_headers, message: message}} =
               HeaderCheck.verify(parsed_header_row, declared)

      assert message =~ "unquoted commas"
      assert message =~ "RFC 4180"
      assert message =~ "Substr(b,5,2)!!'/'!!substr(b,7,2)!!'/'!!substr(b,1,4)"
    end

    test "no hint added when no declared header contains a comma" do
      declared = [required: ["name", "email"], optional: []]
      parsed_header_row = ["name", "name"]

      assert {:error, %Error{kind: :duplicate_headers, message: message}} =
               HeaderCheck.verify(parsed_header_row, declared)

      refute message =~ "unquoted commas"
      refute message =~ "RFC 4180"
    end

    test "hint fires even when declared header has no lowercase letters" do
      declared = [
        required: [{"FOO,BAR,BAZ", :foobar}],
        optional: []
      ]

      parsed = ["foo", "bar", "bar", "baz"]

      assert {:error, %Error{kind: :duplicate_headers, message: msg}} =
               HeaderCheck.verify(parsed, declared)

      assert msg =~ "RFC 4180"
      assert msg =~ "FOO,BAR,BAZ"
    end
  end
end
