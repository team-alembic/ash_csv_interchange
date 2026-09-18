# Populated by `mix spark.formatter --extensions AshCsvInterchange`. Exported so
# consuming apps that `import_deps: [:ash_csv_interchange]` format their
# `csv_imports`/`csv_exports` blocks the way the docs write them.
spark_locals_without_parens = [
  columns: 1,
  csv_export: 1,
  csv_export: 2,
  csv_import: 1,
  csv_import: 2,
  headers: 1,
  import_source: 1,
  label: 1,
  read_action: 1,
  upsert_action: 1
]

[
  # Import the :ash and :spark formatter rules. This extension is a Spark DSL,
  # and without these `mix format` mangles the `csv_imports`/`csv_exports` DSL
  # blocks in consuming resources and our own tests.
  import_deps: [:ash, :spark],
  plugins: [DoctestFormatter, Quokka],
  inputs: ["{mix,.formatter,.credo,.check,.doctor}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: spark_locals_without_parens,
  export: [locals_without_parens: spark_locals_without_parens],
  quokka: [
    # Quokka reads .credo.exs and rewrites based on those rules.
    # Exclude a few rewrites that tend to be noisy in a library context.
    exclude: [:line_length]
  ]
]
