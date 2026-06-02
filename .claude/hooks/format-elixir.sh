#!/usr/bin/env bash
# Format any Elixir files that were just edited.
# Reads Claude Code's hook payload from stdin.
set -euo pipefail

payload=$(cat)
files=$(
  echo "$payload" \
    | jq -r '
        [.tool_input.file_path // empty]
        + [((.tool_input.edits // []) | map(.file_path // empty))[]]
        | .[]? | select(length > 0)
      ' 2>/dev/null \
    | sort -u \
    | grep -E '\.(ex|exs|heex)$' \
    || true
)

[[ -z "$files" ]] && exit 0

# shellcheck disable=SC2086
mix format $files 2>&1 || true
