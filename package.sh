#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

if [[ ! -f info.json ]]; then
  echo "Error: info.json not found in $(pwd)" >&2
  exit 1
fi

MOD_NAME=$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' info.json | head -1)
VERSION=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' info.json | head -1)

[[ -n "$MOD_NAME" ]] || { echo "Error: could not extract \"name\" from info.json" >&2; exit 1; }
[[ -n "$VERSION" ]]  || { echo "Error: could not extract \"version\" from info.json" >&2; exit 1; }

# Allowlist of shippable mod entries (files + dirs). Dev-only paths such as
# tests/, docs/, .git, and this script are deliberately excluded. Each entry is
# copied only if it exists, so the build works as the mod grows.
ENTRIES=(
  info.json
  control.lua
  data.lua
  data-updates.lua
  data-final-fixes.lua
  settings.lua
  changelog.txt
  thumbnail.png
  LICENSE
  README.md
  scripts
  prototypes
  locale
  graphics
)

# Factorio requires the zip to contain a single top-level folder
# "<mod-name>_<version>" holding the mod files.
folder="${MOD_NAME}_${VERSION}"
zipfile="${folder}.zip"

echo "Packaging ${folder}..."
rm -rf "$folder" "$zipfile"
mkdir -p "$folder"

for entry in "${ENTRIES[@]}"; do
  if [[ -e "$entry" ]]; then
    cp -r "$entry" "$folder/"
  fi
done

zip -r "$zipfile" "$folder" -x "*.DS_Store" > /dev/null
rm -rf "$folder"

echo "Created ${zipfile} ($(wc -c < "$zipfile" | tr -d ' ') bytes)"
