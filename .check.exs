[
  tools: [
    {:compiler, "mix compile --warnings-as-errors --force"},
    {:unused_deps, "mix deps.unlock --check-unused"},
    {:formatter, "mix format --check-formatted"},
    # Keeps the exported `spark_locals_without_parens` in sync with the DSL;
    # without it, consuming apps' `mix format` mangles csv_imports blocks.
    {:spark_formatter, "mix spark.formatter --check --extensions AshCsvInterchange"},
    # Fails when documentation/dsls/ is stale; regenerate with
    # `mix spark.cheat_sheets`.
    {:spark_cheat_sheets, "mix spark.cheat_sheets --check"},
    {:credo, "mix credo --strict"},
    {:doctor, "mix doctor --full --raise"},
    {:sobelow, "mix sobelow --config"},
    {:mix_audit, false},
    {:hex_audit, command: "mix hex.audit"},
    {:ex_unit, "mix test"},
    {:dialyzer, "mix dialyzer"},
    {:ex_doc, "mix docs"}
  ]
]
