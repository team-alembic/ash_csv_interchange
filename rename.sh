#!/usr/bin/env bash
# rename.sh - Rename the template placeholder (my_package / MyPackage) to your
# actual package name.
#
# Usage:
#   ./rename.sh <snake_case_name> <CamelCaseName>
#
# Example:
#   ./rename.sh ash_widget AshWidget

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <snake_case> <CamelCase>" >&2
  echo "Example: $0 ash_widget AshWidget" >&2
  exit 1
fi

snake="$1"
camel="$2"

if ! [[ "$snake" =~ ^[a-z][a-z0-9_]*$ ]]; then
  echo "snake_case name must match ^[a-z][a-z0-9_]*$" >&2
  exit 1
fi

if ! [[ "$camel" =~ ^[A-Z][A-Za-z0-9]*$ ]]; then
  echo "CamelCase name must match ^[A-Z][A-Za-z0-9]*$" >&2
  exit 1
fi

cd "$(dirname "$0")"

# Files and directories to process (excluding .git, deps, _build, etc.)
mapfile -t files < <(
  git ls-files 2>/dev/null \
    || find . \
      -type f \
      -not -path './.git/*' \
      -not -path './_build/*' \
      -not -path './deps/*' \
      -not -path './doc/*' \
      -not -path './cover/*' \
      -not -path './rename.sh'
)

for f in "${files[@]}"; do
  [[ "$f" == "rename.sh" || "$f" == "./rename.sh" ]] && continue
  [[ -f "$f" ]] || continue
  # Skip binary files
  if file "$f" | grep -q 'binary'; then continue; fi
  # Portable in-place sed (macOS + Linux)
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' -e "s/MyPackage/${camel}/g" -e "s/my_package/${snake}/g" "$f"
  else
    sed -i -e "s/MyPackage/${camel}/g" -e "s/my_package/${snake}/g" "$f"
  fi
done

# Rename files/dirs that contain the placeholder in their path.
while IFS= read -r -d '' path; do
  new="${path//my_package/$snake}"
  if [[ "$path" != "$new" ]]; then
    mkdir -p "$(dirname "$new")"
    mv "$path" "$new"
  fi
done < <(find . -depth -name '*my_package*' -not -path './.git/*' -print0)

# Swap the template-facing README for the package-facing one.
if [[ -f "README.template.md" ]]; then
  mv -f README.template.md README.md
  echo "Replaced README.md with the package README."
fi

echo "Renamed my_package -> $snake and MyPackage -> $camel."
echo "Review the diff with: git diff"
echo "When happy, delete this script and TEMPLATE.md:"
echo "  rm rename.sh TEMPLATE.md"
