---
description: Cut a new release using git_ops and push the tag
---

Cut a new release of this package.

Steps:

1. Confirm the working tree is clean: `git status --short`. Abort if not.
2. Confirm we're on `main` and up to date: `git rev-parse --abbrev-ref HEAD` and `git pull --ff-only`.
3. Run the full quality suite: `mix check`. Abort if anything fails.
4. Run `mix git_ops.release` — this bumps the version in `mix.exs` based on
   conventional-commit history, writes `CHANGELOG.md`, commits, and tags.
5. Show me the diff and the tag that was created. **Stop and wait for my
   confirmation** before pushing.
6. On my go-ahead: `git push && git push --tags`. The `release.yml` workflow
   will publish to Hex when a GitHub Release is created for the tag.

Never run destructive operations (`git reset --hard`, `git push --force`)
without explicit permission.
