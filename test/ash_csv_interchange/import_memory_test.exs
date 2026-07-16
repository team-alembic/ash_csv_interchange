defmodule AshCsvInterchange.Import.MemoryTest do
  @moduledoc """
  Load-bearing proof for ACC-215: import memory is O(1) in row count.

  Excluded from the default suite (`@moduletag :memory`); run with
  `mix test --only memory`. Generates CSV fixtures lazily to disk so the
  test itself never holds them, imports each inside a worker process, and
  samples that worker's peak heap. Asserts peak does not scale with input
  size (a ratio, not an absolute byte threshold, to stay robust across
  machines and GC timing).
  """
  use ExUnit.Case, async: false

  alias AshCsvInterchange.Import.Orchestrator
  alias AshCsvInterchange.TestResource

  @moduletag :memory

  test "peak import memory does not scale with row count" do
    small = generate_csv(10_000)
    large = generate_csv(100_000)
    on_exit(fn -> Enum.each([small, large], &File.rm/1) end)

    peak_small = peak_memory(fn -> import_file(small) end)
    peak_large = peak_memory(fn -> import_file(large) end)

    # 10x the rows must not mean anywhere near 10x the peak heap. Factor is
    # generous to absorb GC/measurement noise; tighten only if it proves stable.
    assert peak_large < peak_small * 2,
           "expected flat memory; peak(10k)=#{peak_small} peak(100k)=#{peak_large}"
  end

  defp import_file(path) do
    {:ok, _report} =
      Orchestrator.import_csv(TestResource, :test_resource, {:path, path}, mode: :dry_run)
  end

  defp generate_csv(rows) do
    path = Path.join(System.tmp_dir!(), "acc215_mem_#{rows}_#{System.unique_integer([:positive])}.csv")

    File.open!(path, [:write], fn file ->
      IO.write(file, "external_id,name,date_of_birth\n")
      Enum.each(1..rows, fn i -> IO.write(file, "E#{i},Name#{i},2020-01-01\n") end)
    end)

    path
  end

  defp peak_memory(fun) do
    test = self()

    pid =
      spawn(fn ->
        fun.()
        send(test, :worker_done)
      end)

    ref = Process.monitor(pid)
    sample(pid, ref, 0)
  end

  defp sample(pid, ref, peak) do
    peak =
      case Process.info(pid, :memory) do
        {:memory, mem} -> max(peak, mem)
        nil -> peak
      end

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> peak
    after
      1 -> sample(pid, ref, peak)
    end
  end
end
