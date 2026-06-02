#!/usr/bin/env bash
# Bootstrap the devcontainer: install Erlang/Elixir via asdf, fetch deps.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -f .tool-versions ]]; then
  echo ".tool-versions not found — aborting" >&2
  exit 1
fi

# Install all asdf plugins referenced by .tool-versions.
while read -r plugin _; do
  [[ -z "$plugin" || "$plugin" =~ ^# ]] && continue
  if asdf plugin list 2>/dev/null | grep -q "^${plugin}$"; then
    asdf plugin update "$plugin" || true
  else
    asdf plugin add "$plugin" || true
  fi
done < .tool-versions

asdf install
mix local.hex --force --if-missing
mix local.rebar --force --if-missing
mix deps.get
