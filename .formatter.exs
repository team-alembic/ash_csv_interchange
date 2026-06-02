[
  # Import the :ash and :spark formatter rules. This extension is a Spark DSL,
  # and without these `mix format` mangles the `csv_imports`/`csv_exports` DSL
  # blocks in consuming resources and our own tests.
  import_deps: [:ash, :spark],
  plugins: [DoctestFormatter, Quokka],
  inputs: ["{mix,.formatter,.credo,.check,.doctor}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  quokka: [
    # Quokka reads .credo.exs and rewrites based on those rules.
    # Exclude a few rewrites that tend to be noisy in a library context.
    exclude: [:line_length]
  ]
]
