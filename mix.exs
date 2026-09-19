defmodule AshCsvInterchange.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/team-alembic/ash_csv_interchange"

  def project do
    [
      app: :ash_csv_interchange,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      consolidate_protocols: Mix.env() != :test,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      package: package(),
      description: description(),
      name: "AshCsvInterchange",
      source_url: @source_url,
      homepage_url: @source_url,
      docs: &docs/0,
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_core_path: "priv/plts",
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
      ],
      usage_rules: usage_rules()
    ]
  end

  def cli do
    [
      preferred_envs: [
        ci: :test,
        "test.coverage": :test
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp description do
    "An Ash extension for declaring CSV-importable and CSV-exportable resources via a Spark DSL."
  end

  defp package do
    [
      maintainers: ["Team Alembic"],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      # `README.template.md` is the template-only file; rename.sh promotes
      # it to README.md before the first hex publish, so it isn't shipped.
      files: ~w(lib guides .formatter.exs mix.exs README.md LICENSE* CHANGELOG* usage-rules.md)
    ]
  end

  defp deps do
    [
      # Runtime — the extension is a Spark DSL built on Ash; :spark and
      # :nimble_options arrive transitively via :ash.
      {:ash, "~> 3.0"},
      {:nimble_csv, "~> 1.2"},

      # SAT solver for the policy-bearing test fixtures.
      {:simple_sat, "~> 0.1", only: [:dev, :test]},

      # Docs
      {:ex_doc, "~> 0.34", only: [:dev, :test], runtime: false},

      # Quality
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.21", only: [:dev, :test], runtime: false},
      {:ex_check, "~> 0.16", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},

      # Dev QoL
      {:mix_test_watch, "~> 1.2", only: [:dev, :test], runtime: false},
      {:doctest_formatter, "~> 0.3", only: [:dev, :test], runtime: false},

      # Formatter plugin — rewrites code based on .credo.exs rules.
      {:quokka, "~> 2.12", only: [:dev, :test], runtime: false},

      # Required by `mix spark.formatter`, which regenerates the exported
      # `spark_locals_without_parens` list in .formatter.exs. Declared
      # explicitly so the check runs under MIX_ENV=test in CI.
      {:sourceror, "~> 1.0", only: [:dev, :test], runtime: false},

      # Ash-aware Credo checks (opt-in for Ash packages). Also enable the
      # plugin in .credo.exs and switch the `lint` alias to compile before
      # credo — the compiled-introspection checks need it.
      # {:ash_credo, "~> 0.7", only: [:dev, :test], runtime: false},

      # Release automation (conventional commits -> CHANGELOG + tag)
      {:git_ops, "~> 2.6", only: [:dev, :test], runtime: false},

      # Syncs usage-rules.md from deps into AGENTS.md or agent skills.
      {:usage_rules, "~> 1.1", only: [:dev], runtime: false},

      # Needed by mix igniter.install and mix usage_rules.sync.
      {:igniter, "~> 0.6", only: [:dev], runtime: false}
    ]
  end

  defp aliases do
    [
      ci: [
        "deps.unlock --check-unused",
        "format --check-formatted",
        "spark.formatter --check --extensions AshCsvInterchange",
        "credo --strict",
        "doctor --full --raise",
        "sobelow --config",
        "hex.audit",
        "dialyzer",
        "test"
      ],
      credo: ["credo --strict"],
      # If you enable ash_credo, use `mix lint` instead of `mix credo` — the
      # compiled-introspection checks need modules to be compiled first.
      lint: ["compile", "credo --strict"],
      sobelow: ["sobelow --config"]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url_pattern: "#{@source_url}/blob/main/%{path}#L%{line}",
      extra_section: "GUIDES",
      extras: extras(),
      groups_for_extras: [Guides: ~r"guides/"],
      before_closing_head_tag: fn
        :html -> ~s|<link rel="icon" href="data:,">|
        _ -> ""
      end
    ]
  end

  defp extras do
    ["README.md", "CHANGELOG.md", "usage-rules.md"] ++
      Path.wildcard("guides/**/*.{md,cheatmd,livemd}")
  end

  # `mix usage_rules.sync` materialises this config into committed
  # `.claude/skills/*/SKILL.md` files. Re-run after adding or removing deps.
  defp usage_rules do
    [
      skills: [
        location: ".claude/skills",

        # Auto-generate a `use-<pkg>` skill per listed dependency. Each skill
        # references that package's shipped `usage-rules.md` (if any).
        deps: [
          # :ash, :phoenix, :ecto, :req,
          # ~r/^ash_/,
        ],

        # Pre-built skills shipped by packages in their `usage-rules/skills/`
        # directory — opt in per package.
        package_skills: [
          # :ash, ~r/^ash_/,
        ],

        # Custom composed skills that pull rules from multiple deps and
        # ship them as a single SKILL.md.
        build: [
          # "ash-framework": [
          #   description: "Use when working with Ash Framework or any of its extensions.",
          #   usage_rules: [:ash, ~r/^ash_/]
          # ],
          # "phoenix-framework": [
          #   description: "Use when working with Phoenix — controllers, LiveViews, routes, views.",
          #   usage_rules: [:phoenix, ~r/^phoenix_/]
          # ]
        ]
      ]
    ]
  end
end
