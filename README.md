# Elixir Package Template

A starter template for team-alembic Elixir packages. `mix new` plus every
nicety we use across [ash_authentication](https://github.com/team-alembic/ash_authentication),
[ash_graphql](https://github.com/team-alembic/ash_graphql),
[ash_diagram](https://github.com/team-alembic/ash_diagram),
[clarity](https://github.com/team-alembic/clarity),
and friends — pre-wired and ready to go.

## Quick start

### 1. Create the repo

Either via the GitHub UI (**Use this template → Create a new repository**) or:

```bash
gh repo create team-alembic/your_package \
  --template team-alembic/elixir_package_template \
  --private --clone

cd your_package
```

### 2. Rename the placeholder

The template uses `my_package` / `MyPackage` everywhere. Run the bundled
script with your real names:

```bash
./rename.sh your_package YourPackage
```

This rewrites every file, renames any path containing `my_package`, swaps the
template-facing README for the package-facing one, and (when you're done)
deletes itself plus `TEMPLATE.md`:

```bash
git add -A
git commit -m "chore: initial rename"
rm rename.sh TEMPLATE.md
```

### 3. Wire up CI secrets

In your new repo's settings → **Secrets and variables → Actions**, add:

- `HEX_API_KEY` — required for `release.yml`. Generate one with
  `mix hex.user.key generate`.

Then under **Settings → Pages**, set Source to **GitHub Actions** so the CI
pipeline can deploy your docs.

### 4. Sync agent skills (if using Ash / Phoenix / etc.)

Edit the `usage_rules()` function in `mix.exs` to list the deps you want
exposed as agent skills, then:

```bash
mix deps.get
mix usage_rules.sync
git add .claude/skills && git commit -m "chore: sync agent skills"
```

That's it. See [TEMPLATE.md](./TEMPLATE.md) for the full walkthrough including
first release.

## What's in the box

**CI** ([.github/workflows/elixir.yml](./.github/workflows/elixir.yml))
delegates to [team-alembic/staple-actions](https://github.com/team-alembic/staple-actions):
deps → hex.audit → compile → format / credo --strict / doctor / sobelow /
dialyzer / test / unused-deps / conventional-commit → docs build + deploy to
GitHub Pages → automatic `git_ops.release` on main.

**Hex publishing** ([.github/workflows/release.yml](./.github/workflows/release.yml))
runs `mix hex.publish` on GitHub Release publication.

**Quality stack** mirroring [ash-project](https://github.com/ash-project) house style:

- `credo` strict, with `AliasUsage` / `Specs` / `StrictModuleLayout` off
- `quokka` formatter that auto-rewrites code based on `.credo.exs`
- `dialyxir` type checking
- `doctor` doc-coverage gate
- `sobelow` security checks
- `mix_audit` / `hex.audit` for dep vulnerabilities
- `ex_check` to run the full suite locally
- `mix_test_watch` for `mix test.watch`
- `doctest_formatter` so doctests format on `mix format`

**Release automation** via [`git_ops`](https://hex.pm/packages/git_ops) —
conventional-commit history → `CHANGELOG.md` + `mix.exs` version bump + tag,
all with one command.

**Agent tooling**

- [`AGENTS.md`](./AGENTS.md) — source of truth for AI agents (stack, commands, rules)
- [`CLAUDE.md`](./CLAUDE.md) — thin pointer at AGENTS.md
- [`usage-rules.md`](./usage-rules.md) — Ash-ecosystem convention published via Hex
- `usage_rules` skills mode — generates `.claude/skills/*/SKILL.md` from
  dependencies' rules; stale skills auto-pruned, custom content preserved
- [`.claude/`](./.claude) — format-on-edit hook, pre-approved mix commands,
  `/check` and `/release` slash commands

**Dependabot** ([.github/dependabot.yml](./.github/dependabot.yml)) — monthly,
grouped, lockfile-only; covers mix, GitHub Actions, and devcontainers.

**Devcontainer** ([.devcontainer/](./.devcontainer)) — Debian + Erlang build
deps + asdf + Claude Code + Node + GitHub CLI; mounts `~/.claude` so plugins
travel with you.

**Issue + PR templates**, **Apache 2.0 LICENSE**, **CHANGELOG seed**,
**`guides/` directory** for narrative docs (reference docs are auto-generated
by ExDoc from `@doc`/`@moduledoc`).

**Opt-in extras** (commented out in the relevant files):

- `ash_credo` Credo plugin with Ash-aware checks
- Per-package `usage-rules.md` and composed multi-dep skills
- Plausible analytics for hexdocs (matches ash-project convention)
- `ASH_VERSION` env override pattern for developing against unreleased Ash

## Background

Built from prior art across the team-alembic and ash-project Elixir
ecosystems. The full survey and design decisions are documented in the
initial commit message; in short: it picks staple-actions over the
ash-project reusable workflow (so non-Ash packages aren't dragged into
that ecosystem), defaults to skills mode for `usage_rules` (so package
knowledge ships as Claude Code skills, not a single monolithic AGENTS.md),
and mirrors ash-project's `.credo.exs` so the strictness bar matches what
Alembic devs already work to.

## License

Apache 2.0. See [LICENSE](./LICENSE).
