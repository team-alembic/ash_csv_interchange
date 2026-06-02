[
  tools: [
    {:compiler, "mix compile --warnings-as-errors --force"},
    {:unused_deps, "mix deps.unlock --check-unused"},
    {:formatter, "mix format --check-formatted"},
    {:credo, "mix credo --strict"},
    {:doctor, "mix doctor --full --raise"},
    {:sobelow, "mix sobelow --config"},
    {:hex_audit, "mix hex.audit"},
    {:deps_audit, "mix deps.audit"},
    {:ex_unit, "mix test"},
    {:dialyzer, "mix dialyzer"},
    {:ex_doc, "mix docs"}
  ]
]
