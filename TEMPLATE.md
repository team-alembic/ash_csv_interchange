# Using this template

This repo is a [GitHub template](https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-repository-from-a-template)
for new team-alembic Elixir packages. It ships with:

- `mix new` skeleton (lib + test + config)
- **CI** via GitHub Actions + `team-alembic/staple-actions` (tests, format,
  credo strict, doctor, sobelow, dialyzer, hex audit, unused deps,
  conventional-commit check, docs deploy to Pages, automatic `git_ops` release
  on main)
- **Hex release** workflow triggered on GitHub Release publication
- **Dependabot** monthly, grouped, for mix + actions + devcontainers
- **Dev container** with Erlang build deps, asdf, Claude Code, Node, GitHub CLI
- **AGENTS.md** + `CLAUDE.md` forwarder + `usage-rules.md` stub
- **`usage_rules` skills mode** — agent skills (`.claude/skills/*/SKILL.md`)
  generated from your deps' `usage-rules.md` via `mix usage_rules.sync`. Stale
  skills auto-pruned; custom content preserved across syncs.
- **`.claude/`** with format-on-save hook, pre-approved mix commands, and
  `/check`, `/release` slash commands
- **Quality tooling**: `ex_check`, `credo`, `dialyxir`, `doctor`, `sobelow`,
  `mix_audit`, `quokka` (formatter rewrites based on Credo config), `git_ops`,
  `usage_rules`, `igniter`, `ex_doc`
- **Documentation** folder with Diátaxis sections
  (`tutorials/`, `how-to/`, `topics/`, `reference/`)
- **Issue + PR templates**
- **Standard config**: `.formatter.exs`, `.credo.exs`, `.check.exs`,
  `.doctor.exs`, `.sobelow-conf`, `.tool-versions`, `.gitignore`

## 1. Create your repo

Click **Use this template → Create a new repository** on GitHub, or:

```bash
gh repo create team-alembic/my_real_package --template team-alembic/elixir_package_template --private --clone
cd my_real_package
```

## 2. Rename the placeholder

The template uses `my_package` / `MyPackage` everywhere. Rename with:

```bash
./rename.sh my_real_package MyRealPackage
rm rename.sh TEMPLATE.md
git add -A
git commit -m "chore: initial rename"
```

## 3. Sync agent skills

Edit the `usage_rules()` function in `mix.exs` to list the deps you want
exposed as agent skills, then:

```bash
mix deps.get
mix usage_rules.sync
git add .claude/skills
git commit -m "chore: sync agent skills"
```

## 4. Set secrets

In GitHub repo settings → Secrets and variables → Actions:

- `HEX_API_KEY` — required for `release.yml` to publish to Hex. Get one via
  `mix hex.user.key generate`.

## 5. Enable GitHub Pages

Repo settings → Pages → Source: **GitHub Actions**. The CI pipeline deploys
docs automatically on merges to `main`.

## 6. First release

Merge some conventional-commit-formatted work to `main`, then:

```bash
mix git_ops.release
git push && git push --tags
```

Create a GitHub Release from the new tag — `release.yml` will publish to Hex.

---

Delete this file once you've done all of the above.
