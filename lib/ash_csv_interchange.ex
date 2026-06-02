defmodule AshCsvInterchange do
  @moduledoc """
  An Ash extension for declaring CSV-importable and CSV-exportable resources.

  Resources that use this extension expose a `csv_imports do … end` and/or
  `csv_exports do … end` block, declaring named CSV types that the extension
  dispatches to the resource's Ash actions. Imports re-run idempotently through
  Ash's upsert mechanism; exports stream the declared read action to CSV.

  See the [README](readme.html) for installation, configuration, and usage.

  > #### Scaffold {: .info}
  >
  > This repository is the standalone home for `ash_csv_interchange`, extracted
  > from the ARCC Center platform. The extension implementation is moved in as a
  > follow-up — this module is the package entry point that documentation and
  > the public API hang off.
  """

  @doc """
  Reports that the extension is compiled into the host application.

  A placeholder smoke check that the dependency is wired up correctly. It is
  superseded by the real public API (`import_csv/3`, `export_csv/2`,
  `stream_export/2`, …) when the extension implementation lands in this repo.
  """
  @spec installed?() :: boolean()
  def installed?, do: true
end
