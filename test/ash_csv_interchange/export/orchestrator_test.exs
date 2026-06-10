defmodule AshCsvInterchange.Export.OrchestratorTest do
  use ExUnit.Case, async: false

  alias Ash.DataLayer.Ets
  alias AshCsvInterchange.Export.Orchestrator
  alias AshCsvInterchange.ExportTestResource

  setup do
    on_exit(fn -> Ets.stop(ExportTestResource) end)
    :ok
  end

  defp type!(id \\ :contacts) do
    {:ok, type} = AshCsvInterchange.Info.csv_export_type(ExportTestResource, id)
    type
  end

  defp seed!(attrs), do: ExportTestResource.create_contact!(attrs)

  describe "build_stream/3" do
    test "emits a header chunk followed by row chunks" do
      seed!(%{external_id: "C-1", first_name: "Ada", last_name: "Lovelace"})
      seed!(%{external_id: "C-2", first_name: "Grace", last_name: "Hopper"})

      output =
        ExportTestResource
        |> Orchestrator.build_stream(type!(), [])
        |> Enum.join()

      [header_line | rows] = String.split(output, "\r\n", trim: true)
      assert header_line == "external_id,first_name,last_name"
      assert "C-1,Ada,Lovelace" in rows
      assert "C-2,Grace,Hopper" in rows
    end

    test "empty result set yields header-only output" do
      output =
        ExportTestResource
        |> Orchestrator.build_stream(type!(), [])
        |> Enum.join()

      assert String.trim_trailing(output) == "external_id,first_name,last_name"
    end

    test "streams every record when the row count exceeds batch_size" do
      record_count = 7
      batch_size = 3

      for i <- 1..record_count do
        seed!(%{external_id: "C-#{i}", first_name: "First#{i}", last_name: "Last#{i}"})
      end

      chunks =
        ExportTestResource
        |> Orchestrator.build_stream(type!(), batch_size: batch_size)
        |> Enum.to_list()

      # Header chunk + one chunk per batch of rows — proves the stream
      # actually emits multiple chunks rather than buffering everything.
      assert length(chunks) >= 1 + ceil(record_count / batch_size)

      rows =
        chunks
        |> Enum.join()
        |> String.split("\r\n", trim: true)
        |> tl()

      assert length(rows) == record_count

      for i <- 1..record_count do
        assert "C-#{i},First#{i},Last#{i}" in rows
      end
    end
  end

  describe "build_stream/3 with :input" do
    test "passes input to the read action so its filter applies" do
      seed!(%{external_id: "C-1", first_name: "Ada", last_name: "Lovelace"})
      seed!(%{external_id: "C-2", first_name: "Grace", last_name: "Hopper"})

      output =
        ExportTestResource
        |> Orchestrator.build_stream(type!(:contacts_by_last_name), input: %{last_name: "Lovelace"})
        |> Enum.join()

      [header_line | rows] = String.split(output, "\r\n", trim: true)
      assert header_line == "external_id,first_name,last_name"
      assert rows == ["C-1,Ada,Lovelace"]
    end

    test "omitting :input on a required-argument read action raises when the stream runs" do
      seed!(%{external_id: "C-1", first_name: "Ada", last_name: "Lovelace"})

      stream = Orchestrator.build_stream(ExportTestResource, type!(:contacts_by_last_name), [])

      assert_raise Ash.Error.Invalid, ~r/last_name is required/, fn ->
        Enum.join(stream)
      end
    end
  end
end
