defmodule AshCsvInterchange.Export.Orchestrator do
  @moduledoc """
  Builds the lazy stream of CSV chunks for an export type.

  Errors raised by the read action or a formatter propagate through the
  stream as exceptions. We do not swallow them mid-stream because a
  partial CSV is worse than a hard failure.
  """

  alias AshCsvInterchange.Export.{Serializer, Type}

  @default_batch_size 500

  @doc """
  Returns the lazy CSV-chunk stream. The first chunk is the header row;
  subsequent chunks are serialised batches of records read via the
  declared `read_action`. See `AshCsvInterchange.stream_export/2` for
  the `:actor` and `:batch_size` options.
  """
  @spec build_stream(module(), Type.t(), keyword()) :: Enumerable.t()
  def build_stream(resource, %Type{} = type, opts) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    actor = Keyword.get(opts, :actor)

    header_chunk = dump_csv([Serializer.header(type.columns)])

    row_stream =
      resource
      |> Ash.Query.for_read(type.read_action, %{}, actor: actor)
      |> Ash.stream!(batch_size: batch_size)
      |> Stream.chunk_every(batch_size)
      |> Stream.map(fn batch ->
        batch
        |> Enum.map(&Serializer.row(&1, type.columns))
        |> dump_csv()
      end)

    Stream.concat([header_chunk], row_stream)
  end

  defp dump_csv(rows) do
    rows
    |> NimbleCSV.RFC4180.dump_to_iodata()
    |> IO.iodata_to_binary()
  end
end
