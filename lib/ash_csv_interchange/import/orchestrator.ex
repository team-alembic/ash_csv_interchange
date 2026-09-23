defmodule AshCsvInterchange.Import.Orchestrator do
  @moduledoc """
  Runs the CSV import pipeline. `import_csv/4` returns a bounded
  `%RunReport{}`. `stream_import/4` returns lazy per-row outcomes.

  Both resolve the named `csv_import` entity, then parse with
  `Parser.parse_stream/2`. The header is read eagerly, so encoding,
  malformed-CSV, empty-file, missing-header and duplicate-header errors
  are all fatal. Unknown columns become warnings.

  Each non-blank row goes to the configured upsert action. A failing row
  becomes an `:invalid`, `:errored` or `:crashed` outcome and never
  aborts the run.

  In `:commit` mode with `batch_size > 1`, rows are chunked and dispatched
  via `Ash.bulk_create/4` so a batch costs one write round-trip instead of
  one per row. Any row a batch didn't clearly succeed on — invalid input,
  a data-layer error, a crash, or an aborted batch — is re-committed
  through the single-row path, so outcomes stay identical to `batch_size:
  1` regardless of why the batch didn't take it all the way.
  """

  alias AshCsvInterchange.{Error, Info}

  alias AshCsvInterchange.Import.{
    HeaderCheck,
    Headers,
    Parser,
    RowOutcome,
    RunReport,
    RunReport.Counts,
    StreamReport
  }

  require Logger

  @ash_forwarded_opts [:actor, :tenant, :authorize?, :scope]
  @default_max_outcomes 100
  @default_batch_size 100

  @doc """
  Parses a CSV source and sends each non-blank row to the type's upsert
  action. Returns a bounded `%RunReport{}`: `counts` is exact, `outcomes`
  is capped at `:max_outcomes`, and `outcomes_truncated?` marks when rows
  exceeded the cap.

  The `source` is a binary, a `{:path, path}` tuple, or a re-enumerable
  `Enumerable` of binary chunks.

  Options:

    * `:mode` — `:dry_run` (default) or `:commit`
    * `:max_outcomes` — retained outcome preview size (default `100`)
    * `:retain_records?` — keep the full Ash `record` on committed
      outcomes (default `false`)
    * `:batch_size` — commit-mode rows per `Ash.bulk_create/4` dispatch
      (default `100`). `batch_size: 1` commits one row per write
      round-trip, identical to pre-batching behaviour. Ignored in
      `:dry_run` mode.
    * `:actor`, `:tenant`, `:authorize?`, `:scope` — forwarded to
      `Ash.Changeset.for_create/4` for every row.

  `:commit` mode is not atomic. Rows are written as the input is consumed,
  so a parse or encoding error partway through leaves earlier rows
  committed and still returns `{:error, %Error{}}`. Imports are idempotent
  upserts, so re-running the corrected file converges. Prefer
  `stream_import/4` for large or untrusted input.
  """
  @spec import_csv(module(), atom(), Parser.source(), keyword()) ::
          {:ok, RunReport.t()} | {:error, Error.t()}
  def import_csv(resource, id, source, opts \\ []) when is_atom(resource) and is_atom(id) do
    mode = Keyword.get(opts, :mode, :dry_run)
    max_outcomes = Keyword.get(opts, :max_outcomes, @default_max_outcomes)

    with {:ok, {type, warnings, header_row, input_keys, events}} <-
           stream_events(resource, id, source, opts) do
      try do
        {retained_reversed, counts} = fold_events(events, max_outcomes)

        {:ok,
         %RunReport{
           mode: mode,
           resource: resource,
           type_id: type.id,
           outcomes: Enum.reverse(retained_reversed),
           outcomes_truncated?: counts.total > length(retained_reversed),
           warnings: warnings,
           counts: counts,
           source_headers: header_row,
           input_keys: input_keys
         }}
      rescue
        e in NimbleCSV.ParseError ->
          {:error, %Error{kind: :malformed_csv, message: Exception.message(e)}}

        e in Parser.StreamError ->
          {:error, e.error}
      end
    end
  end

  defp fold_events(events, max_outcomes) do
    {retained, _kept, counts} =
      Enum.reduce(events, {[], 0, %Counts{}}, fn
        {:blank, _line_no}, {retained, kept, counts} ->
          {retained, kept, %{counts | blank_rows_skipped: counts.blank_rows_skipped + 1}}

        {:outcome, outcome}, {retained, kept, counts} ->
          counts = RunReport.tally(counts, outcome)

          if kept < max_outcomes do
            {[outcome | retained], kept + 1, counts}
          else
            {retained, kept, counts}
          end
      end)

    {retained, counts}
  end

  @doc """
  Streams a CSV import as a lazy sequence of per-row outcomes.

  Reads the header eagerly, so fatal header and encoding errors return
  `{:error, %Error{}}` at once. Returns a `%StreamReport{}` whose
  `outcomes` field is a lazy stream of one `%RowOutcome{}` per non-blank
  data row. In `:commit` mode, writes happen as the stream is consumed.

  Takes the same `source` shapes and options as `import_csv/4`. The
  returned stream yields outcomes one batch at a time — it never buffers
  more than one batch's worth of rows.
  """
  @spec stream_import(module(), atom(), Parser.source(), keyword()) ::
          {:ok, StreamReport.t()} | {:error, Error.t()}
  def stream_import(resource, id, source, opts \\ []) when is_atom(resource) and is_atom(id) do
    with {:ok, {_type, warnings, header_row, input_keys, events}} <-
           stream_events(resource, id, source, opts) do
      outcomes =
        Stream.flat_map(events, fn
          {:outcome, outcome} -> [outcome]
          {:blank, _line_no} -> []
        end)

      {:ok,
       %StreamReport{
         warnings: warnings,
         source_headers: header_row,
         input_keys: input_keys,
         outcomes: outcomes
       }}
    end
  end

  defp stream_events(resource, id, source, opts) do
    mode = Keyword.get(opts, :mode, :dry_run)
    ash_opts = Keyword.take(opts, @ash_forwarded_opts)
    retain_records? = Keyword.get(opts, :retain_records?, false)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)

    with {:ok, type} <- fetch_type(resource, id),
         {:ok, {header_row, body}} <- Parser.parse_stream(source, type.headers),
         {:ok, %{headers: headers, warnings: warnings}} <-
           HeaderCheck.verify(header_row, type.headers) do
      input_keys = build_input_keys(type.headers)

      events =
        event_stream(
          body,
          headers,
          input_keys,
          type,
          resource,
          mode,
          ash_opts,
          retain_records?,
          batch_size
        )

      {:ok, {type, warnings, header_row, input_keys, events}}
    end
  end

  defp event_stream(body, headers, input_keys, type, resource, mode, ash_opts, retain_records?, batch_size) do
    numbered_rows = Stream.with_index(body, 2)

    if mode == :commit and batch_size > 1 do
      numbered_rows
      |> Stream.chunk_every(batch_size)
      |> Stream.flat_map(&process_commit_batch(&1, headers, input_keys, type, resource, ash_opts, retain_records?))
    else
      Stream.map(numbered_rows, fn {row, line_no} ->
        if blank_row?(row) do
          {:blank, line_no}
        else
          {:outcome,
           process_row(
             row,
             line_no,
             headers,
             input_keys,
             type,
             resource,
             mode,
             ash_opts,
             retain_records?
           )}
        end
      end)
    end
  end

  defp fetch_type(resource, id) do
    if AshCsvInterchange in Spark.extensions(resource) do
      case Info.csv_import_type(resource, id) do
        {:ok, type} ->
          {:ok, type}

        :error ->
          {:error,
           %Error{
             kind: :type_not_found,
             message: "Resource #{inspect(resource)} does not declare a csv_import with id #{inspect(id)}",
             context: %{resource: resource, id: id}
           }}
      end
    else
      {:error,
       %Error{
         kind: :extension_not_loaded,
         message: "Resource #{inspect(resource)} does not have the AshCsvInterchange extension loaded",
         context: %{resource: resource}
       }}
    end
  end

  defp build_input_keys(headers_config) do
    (headers_config[:required] ++ headers_config[:optional])
    |> Map.new(fn
      {column, input_key} ->
        {Headers.normalise(column), input_key}

      column when is_binary(column) ->
        {Headers.normalise(column), String.to_existing_atom(Headers.normalise(column))}
    end)
  end

  defp blank_row?(row), do: Enum.all?(row, &(String.trim(&1) == ""))

  defp process_row(row, line_no, headers, input_keys, type, resource, mode, ash_opts, retain_records?) do
    input = build_input(row, headers, input_keys)
    process_input(input, line_no, type, resource, mode, ash_opts, retain_records?)
  end

  defp process_input(input, line_no, type, resource, mode, ash_opts, retain_records?) do
    changeset =
      resource
      |> Ash.Changeset.for_create(type.upsert_action, input, ash_opts)
      |> apply_import_source(type.import_source)

    case mode do
      :dry_run -> dry_run_outcome(changeset, line_no, input)
      :commit -> commit_outcome(changeset, line_no, input, retain_records?)
    end
  rescue
    exception ->
      %RowOutcome{
        line_no: line_no,
        status: :crashed,
        errors: [
          %Error{
            kind: :transform_crashed,
            message: Exception.message(exception),
            context: %{exception: inspect(exception.__struct__)}
          }
        ],
        input: input
      }
  end

  # Batches are dispatched with `Ash.bulk_create/4`, but the row-level
  # outcome for anything the batch didn't cleanly persist — an invalid
  # row, a data-layer error, a raised exception, or the whole batch
  # aborting — is produced by re-running `process_input/7` for that row
  # alone. This keeps every such failure mode converging on the exact
  # same outcome `batch_size: 1` would have produced, without needing to
  # parse `Ash.bulk_create/4`'s internal error/index representation.
  #
  # Rows sharing an upsert identity within the same batch are pulled out
  # of the bulk dispatch entirely and committed sequentially through that
  # same per-row fallback instead. A single `INSERT ... ON CONFLICT`
  # covering both rows would have Postgres reject the whole statement
  # ("cannot affect row a second time"), and even data layers that don't
  # raise can't be trusted to apply "last row wins" across two changesets
  # for the same identity in one batch — sequential per-row commits are
  # the only way to reproduce that guarantee.
  defp process_commit_batch(chunk, headers, input_keys, type, resource, ash_opts, retain_records?) do
    prepared =
      Enum.map(chunk, fn {row, line_no} ->
        if blank_row?(row) do
          {:blank, line_no}
        else
          {:row, line_no, build_input(row, headers, input_keys)}
        end
      end)

    rows = for {:row, line_no, input} <- prepared, do: {line_no, input}
    identity_keys = upsert_identity_keys(resource, type.upsert_action)

    successes =
      bulk_commit(
        rows_with_unique_identity(rows, identity_keys),
        type,
        resource,
        ash_opts,
        identity_keys
      )

    Enum.map(prepared, fn
      {:blank, line_no} ->
        {:blank, line_no}

      {:row, line_no, input} ->
        outcome =
          case Map.fetch(successes, line_no) do
            {:ok, record} ->
              success_outcome(line_no, input, record, retain_records?)

            :error ->
              process_input(input, line_no, type, resource, :commit, ash_opts, retain_records?)
          end

        {:outcome, outcome}
    end)
  end

  # Rows sharing an identity within the batch are left out, so they take
  # the per-row path in file order (see `process_commit_batch/7`).
  defp rows_with_unique_identity(rows, identity_keys) do
    keyed =
      Enum.map(rows, fn {_line_no, input} = row ->
        {identity_group_key(input, identity_keys), row}
      end)

    frequencies = keyed |> Enum.map(&elem(&1, 0)) |> Enum.frequencies()

    for {key, row} <- keyed, key == :unknown or frequencies[key] == 1, do: row
  end

  # `identity_keys` are always argument names or accepted-attribute names
  # of the upsert action (enforced at compile time by
  # `ValidateImportAction`), so they resolve directly against the row's
  # input map. A row whose identity value can't be determined this way
  # (e.g. populated by a change instead of a header) reports `:unknown`
  # rather than being grouped with every other such row as if they shared
  # one identity.
  defp identity_group_key(input, identity_keys) do
    values = Enum.map(identity_keys, &Map.get(input, &1))

    if Enum.all?(values, &is_nil/1) do
      :unknown
    else
      values
    end
  end

  defp bulk_commit([], _type, _resource, _ash_opts, _identity_keys), do: %{}

  # Returns `%{line_no => record}` for every row a bulk dispatch wrote.
  # Rows missing from the map take the per-row path.
  #
  # A bulk upsert writes the same `upsert_fields` for every row in the
  # dispatch, but a per-row upsert writes only the attributes its own
  # changeset sets. Rows are grouped by that set and each group is
  # dispatched with it, so an optional column the file leaves out, or an
  # attribute no import writes, keeps its stored value exactly as it would
  # with `batch_size: 1`.
  defp bulk_commit(rows, type, resource, ash_opts, identity_keys) do
    rows
    |> Enum.group_by(&upsert_fields_for(&1, type, resource, ash_opts, identity_keys))
    |> Enum.reject(fn {upsert_fields, _rows} -> upsert_fields == :per_row end)
    |> Enum.reduce(%{}, fn {upsert_fields, group}, successes ->
      Map.merge(successes, bulk_commit_group(group, upsert_fields, type, resource, ash_opts))
    end)
  end

  defp bulk_commit_group(rows, upsert_fields, type, resource, ash_opts) do
    {line_nos, inputs} = Enum.unzip(rows)
    line_nos = List.to_tuple(line_nos)

    inputs
    |> Ash.bulk_create(
      resource,
      type.upsert_action,
      bulk_create_opts(ash_opts, type, upsert_fields)
    )
    |> successes_by_index()
    |> Map.new(fn {index, record} -> {elem(line_nos, index), record} end)
  rescue
    # every row falls back to the per-row path, so outcomes stay correct —
    # but a raise here on each batch silently forfeits the batching win,
    # so make it visible
    exception ->
      Logger.warning(
        "Ash.bulk_create raised; falling back to per-row commits for this batch: " <>
          inspect(exception.__struct__)
      )

      %{}
  end

  defp bulk_create_opts(ash_opts, type, upsert_fields) do
    upsert_opts = if upsert_fields == :declared, do: [], else: [upsert_fields: upsert_fields]

    ash_opts
    |> Keyword.merge(upsert_opts)
    |> Keyword.merge(
      upsert?: true,
      stop_on_error?: false,
      return_records?: true,
      return_errors?: false,
      transform_changeset: fn changeset -> apply_import_source(changeset, type.import_source) end
    )
  end

  # The fields a per-row upsert of this row would write, which is the
  # group key for `bulk_commit/5`. An action that declares `upsert_fields`
  # writes those for every row, so `Ash.bulk_create/4` reads them off the
  # action (`:declared`). A row whose changeset is invalid or raises would
  # fail in the batch anyway, so it goes straight to the per-row path
  # (`:per_row`) for its outcome.
  #
  # Otherwise this mirrors `Ash.Changeset.set_on_upsert/2`: the attributes
  # the changeset sets explicitly, not by default, less the identity and
  # primary key. `update_default` attributes (e.g. `updated_at`) are left
  # out: naming one would make the bulk upsert copy its create-time value,
  # the same instant as `inserted_at`, instead of recomputing it, and
  # `upsert_kind/1` would report every update as a create.
  defp upsert_fields_for({_line_no, input}, type, resource, ash_opts, identity_keys) do
    changeset =
      resource
      |> Ash.Changeset.for_create(type.upsert_action, input, ash_opts)
      |> apply_import_source(type.import_source)

    cond do
      not changeset.valid? -> :per_row
      changeset.action.upsert_fields -> :declared
      true -> explicitly_changed_attributes(changeset, resource, identity_keys)
    end
  rescue
    _exception -> :per_row
  end

  defp explicitly_changed_attributes(changeset, resource, identity_keys) do
    update_defaults =
      for %{name: name, update_default: default} <- Ash.Resource.Info.attributes(resource),
          default != nil,
          do: name

    exclude = identity_keys ++ Ash.Resource.Info.primary_key(resource) ++ update_defaults

    (Map.keys(changeset.attributes) -- Map.get(changeset, :defaults, []))
    |> Enum.reject(&(&1 in exclude))
    |> Enum.sort()
  end

  defp upsert_identity_keys(resource, upsert_action) do
    action = Ash.Resource.Info.action(resource, upsert_action)
    identity = Ash.Resource.Info.identity(resource, action.upsert_identity)
    identity.keys
  end

  defp successes_by_index(%Ash.BulkResult{records: nil}), do: %{}

  defp successes_by_index(%Ash.BulkResult{records: records}) do
    Map.new(records, fn record -> {record.__metadata__.bulk_create_index, record} end)
  end

  defp success_outcome(line_no, input, record, retain_records?) do
    %RowOutcome{
      line_no: line_no,
      status: :ok,
      upsert_kind: upsert_kind(record),
      record: if(retain_records?, do: record),
      input: input
    }
  end

  defp build_input(row, headers, input_keys) do
    headers
    |> Enum.zip(row)
    |> Enum.filter(fn {header, _value} -> Map.has_key?(input_keys, header) end)
    |> Map.new(fn {header, value} -> {Map.fetch!(input_keys, header), value} end)
  end

  defp apply_import_source(changeset, nil), do: changeset

  defp apply_import_source(changeset, {attribute, value}) do
    Ash.Changeset.force_change_attribute(changeset, attribute, value)
  end

  defp dry_run_outcome(changeset, line_no, input) do
    if changeset.valid? do
      %RowOutcome{line_no: line_no, status: :ok, input: input}
    else
      %RowOutcome{
        line_no: line_no,
        status: :invalid,
        errors: changeset.errors,
        input: input
      }
    end
  end

  defp commit_outcome(changeset, line_no, input, retain_records?) do
    case Ash.create(changeset) do
      {:ok, record} ->
        %RowOutcome{
          line_no: line_no,
          status: :ok,
          upsert_kind: upsert_kind(record),
          record: if(retain_records?, do: record),
          input: input
        }

      {:error, error} ->
        %RowOutcome{
          line_no: line_no,
          status: :errored,
          errors: List.wrap(error),
          input: input
        }
    end
  end

  defp upsert_kind(%{inserted_at: %DateTime{} = i, updated_at: %DateTime{} = u}) do
    classify(DateTime.compare(i, u))
  end

  defp upsert_kind(%{inserted_at: %NaiveDateTime{} = i, updated_at: %NaiveDateTime{} = u}) do
    classify(NaiveDateTime.compare(i, u))
  end

  defp upsert_kind(_), do: nil

  defp classify(:eq), do: :created
  defp classify(:lt), do: :updated
  defp classify(:gt), do: :created
end
