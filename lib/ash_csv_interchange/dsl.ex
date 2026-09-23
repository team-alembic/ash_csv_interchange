defmodule AshCsvInterchange.Dsl do
  @moduledoc """
  Spark DSL section for AshCsvInterchange. Declares the `csv_imports` block
  resources use to register one or more CSV import types.
  """

  @csv_import %Spark.Dsl.Entity{
    name: :csv_import,
    describe: """
    Declares a single CSV import type for this resource. Multiple
    entities can be declared inside one `csv_imports` block to support
    different CSV shapes against the same resource (e.g. an active
    contacts export vs. an archived one).
    """,
    examples: [
      """
      csv_import :contacts do
        label "Contacts Export"
        headers required: ["external_id", "first_name", {"date_of_birth", :dob}],
                optional: ["middle_name"]
        upsert_action :import_from_csv
      end
      """
    ],
    args: [:id],
    target: AshCsvInterchange.Import.Type,
    schema: [
      id: [
        type: :atom,
        required: true,
        doc: "Stable identifier for this CSV type (e.g. `:contacts`)."
      ],
      label: [
        type: :string,
        required: true,
        doc: "Human-readable name shown in the upload UI dropdown."
      ],
      headers: [
        type: :keyword_list,
        required: true,
        keys: [
          required: [
            type: {:list, {:or, [:string, {:tuple, [:string, :atom]}]}},
            required: true,
            doc:
              "Required column names. Each entry is either a bare string (column name == action input key) " <>
                "or a `{column_name, input_key}` tuple."
          ],
          optional: [
            type: {:list, {:or, [:string, {:tuple, [:string, :atom]}]}},
            default: [],
            doc: "Optional column names, same shape as `:required`."
          ],
          ignored: [
            type: {:list, :string},
            default: [],
            doc:
              "Column names that should be recognised but discarded — useful " <>
                "for source columns that carry no value to the resource. The " <>
                "column is silenced from the unknown-column warning list and " <>
                "its values never reach the upsert action."
          ]
        ],
        doc:
          "Column-to-input mapping for this CSV type. Keys: `required:` (columns " <>
            "the file must contain), `optional:` (columns it may contain) and " <>
            "`ignored:` (columns to accept and discard). A `required`/`optional` " <>
            "entry is a column name, passed to the action under the same key, or " <>
            "a `{column, input_key}` tuple. Columns match after whitespace trim " <>
            "and ASCII case-fold."
      ],
      upsert_action: [
        type: :atom,
        required: true,
        doc:
          "Name of a `:create` action declared on this resource. The action " <>
            "must declare `upsert? true` and `upsert_identity :name` so re-runs " <>
            "upsert rather than insert. The orchestrator calls " <>
            "`Ash.Changeset.for_create/4` with this action name per row."
      ],
      import_source: [
        type: {:or, [{:tuple, [:atom, :any]}, nil]},
        default: nil,
        doc:
          "Optional `{attribute, value}` tuple. When set, every committed " <>
            "record gets `attribute` force-set to `value` — for example, " <>
            "`{:source, :csv}` writes `:csv` to the `:source` attribute on each " <>
            "row, marking it as CSV-imported. The attribute must already exist " <>
            "on the resource. `nil` (the default) skips stamping."
      ]
    ]
  }

  @csv_imports %Spark.Dsl.Section{
    name: :csv_imports,
    describe: """
    Declares this resource as a CSV import target.

    The entities here drive `AshCsvInterchange.list_import_types/0`,
    `AshCsvInterchange.fetch_import_type/1`, and the per-row dispatch in
    `AshCsvInterchange.import_csv/3`.
    """,
    examples: [
      """
      csv_imports do
        csv_import :contacts do
          label "Contacts Export"
          headers required: ["external_id", "first_name"], optional: []
          upsert_action :import_contacts
        end

        csv_import :archived_contacts do
          label "Archived Contacts"
          headers required: ["external_id", "archived_at"], optional: []
          upsert_action :import_archived_contacts
        end
      end
      """
    ],
    entities: [@csv_import]
  }

  @csv_export %Spark.Dsl.Entity{
    name: :csv_export,
    describe: """
    Declares one CSV export type. Repeat the entity inside `csv_exports`
    to expose multiple shapes for the same resource.
    """,
    examples: [
      """
      csv_export :contacts do
        label "Active Contacts"
        read_action :for_csv_export
        columns [
          {"external_id", :external_id},
          {"full_name", :full_name},
          {"date_of_birth", :dob, format: &Date.to_iso8601/1}
        ]
      end
      """
    ],
    args: [:id],
    target: AshCsvInterchange.Export.Type,
    schema: [
      id: [
        type: :atom,
        required: true,
        doc: "Stable identifier for this export type (e.g. `:contacts`)."
      ],
      label: [
        type: :string,
        required: true,
        doc: "Human-readable name shown in the download UI."
      ],
      read_action: [
        type: :atom,
        required: true,
        doc:
          "Name of a `:read` action declared on this resource. The orchestrator " <>
            "calls `Ash.read(resource, action: name, actor: actor)`. The action " <>
            "owns filter/sort/load/auth."
      ],
      columns: [
        type:
          {:list,
           {:or,
            [
              {:tuple, [:string, :atom]},
              {:tuple, [:string, :atom, :keyword_list]}
            ]}},
        required: true,
        doc:
          "Ordered list of `{header, field}` or `{header, field, opts}` tuples. " <>
            "`opts` may set `format:` to a 1-arity function capture or a " <>
            "`{module, function, extra_args}` MFA returning `String.t()` or iodata."
      ]
    ]
  }

  @csv_exports %Spark.Dsl.Section{
    name: :csv_exports,
    describe: """
    Declares this resource as a CSV export source.

    The entities here drive `AshCsvInterchange.list_export_types/0`,
    `AshCsvInterchange.fetch_export_type/1`, and the streaming dispatch in
    `AshCsvInterchange.stream_export/2` / `AshCsvInterchange.export_csv/2`.
    """,
    examples: [
      """
      csv_exports do
        csv_export :contacts do
          label "Active Contacts"
          read_action :for_csv_export
          columns [
            {"external_id", :external_id},
            {"full_name", :full_name}
          ]
        end
      end
      """
    ],
    entities: [@csv_export]
  }

  @doc false
  def csv_imports_section, do: @csv_imports

  @doc false
  def csv_exports_section, do: @csv_exports
end
