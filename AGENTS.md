# AGENTS.md

Guidance for AI agents (Claude Code, Factory, Copilot, Cursor, ...) working in
this repository. This file is the source of truth; `CLAUDE.md` forwards to it.

## Project

<!-- TODO: Replace with a one-paragraph description of this package. -->

`ash_csv_interchange` is an Elixir library distributed via Hex. Keep the public API
small, documented, and backwards-compatible between minor releases.

## Stack

| Layer       | Choice                                  |
|-------------|-----------------------------------------|
| Language    | Elixir (see `.tool-versions`)           |
| Lint        | Credo strict mode (`mix credo --strict`, or `mix lint` when `ash_credo` is on) |
| Types       | Dialyxir (`mix dialyzer`)               |
| Test        | ExUnit (`mix test`)                     |
| Docs        | ExDoc (`mix docs`)                      |
| Style       | `mix format` + Quokka (enforced in CI)  |
| Security    | Sobelow, `mix hex.audit`, `mix deps.audit` |
| Coverage    | Doctor doc-coverage (`mix doctor`)      |
| Release     | `git_ops` (conventional commits → tag + CHANGELOG) |
| Agent rules | `usage_rules` (skills mode)             |

## Agent skills

Runtime agent knowledge lives in `.claude/skills/` and is generated from
`deps/*/usage-rules.md` files by `mix usage_rules.sync`. See the `usage_rules`
block in `mix.exs` for the config (deps, package_skills, and composed skills).

- **Run after adding / removing deps**: `mix usage_rules.sync`
- **Skills are committed** — downstream collaborators don't need to re-sync on
  clone. Stale skills are pruned automatically when the config changes.
- **Customising a generated skill**: write content above the
  `<!-- usage-rules-skill-start -->` marker in any SKILL.md; custom content is
  preserved across syncs.

Skills are auto-discovered by Claude Code once the file exists — no extra
registration needed.

## Common commands

```bash
mix deps.get
mix check                      # full local quality suite
mix test                       # just the tests
mix test test/path_test.exs:42
mix test.watch                 # re-run tests on file change
mix format
mix format --check-formatted
mix credo --strict
mix dialyzer
mix docs
mix usage_rules.sync           # regenerate .claude/skills/ from deps
```

## Rules

### Before writing code
1. Check for a relevant generated skill in `.claude/skills/` or invoke one of
   the `alembic-elixir-ash` plugin skills (`ash-framework`, `elixir-style`,
   `phoenix-liveview`, `postgres-patterns`).
2. Prefer editing existing modules over creating new ones.
3. Search `deps/*/usage-rules.md` with `mix usage_rules.search_docs` for
   package-specific guidance that isn't in a skill yet.

### While writing code
- Every public function has a `@doc`.
- Every module has a `@moduledoc`.
- Prefer pattern matching and `with` over nested `case`/`if`.
- Let it crash; supervise.
- No compiler warnings. CI runs with `--warnings-as-errors`.
- `snake_case` for variables, `CamelCase` for modules.
- Comments only when the *why* is non-obvious.

### Before committing
- `mix format` and `mix credo --strict` must pass.
- Add or update tests for any behavior change.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/):
  `feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `test:`, `ci:`.
- Update `usage-rules.md` if the change affects how downstream consumers use
  this package.
- **Do not** edit `CHANGELOG.md` by hand — `mix git_ops.release` generates it.

## Package-specific rules

See [`usage-rules.md`](./usage-rules.md) for the rules this package publishes
to its consumers.

## Recommended Claude Code plugins

Install the Alembic marketplace once per machine, then these plugins per
project:

```
/plugin marketplace add team-alembic/alembic-claude-tools
/plugin install alembic-core@alembic-claude-tools
/plugin install alembic-elixir-ash@alembic-claude-tools
/plugin install alembic-reviewer@alembic-claude-tools
```

- **`alembic-core`** — `/plan`, `/work`, `/review`, `/compound`, worktree,
  skill-creator.
- **`alembic-elixir-ash`** — Elixir/Ash/Phoenix/Postgres skills + reviewers +
  `/sync-ash-rules`.
- **`alembic-reviewer`** — security, performance, data-integrity reviewers.
