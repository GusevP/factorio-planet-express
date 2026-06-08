#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

if [[ ! -f info.json ]]; then
  echo "Error: info.json not found in $(pwd)" >&2
  exit 1
fi

# Derive both name and version from info.json so they never drift.
MOD_NAME=$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' info.json | head -1)
VERSION=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' info.json | head -1)

if [[ -z "$MOD_NAME" ]]; then
  echo "Error: Could not extract \"name\" from info.json" >&2
  exit 1
fi
if [[ -z "$VERSION" ]]; then
  echo "Error: Could not extract \"version\" from info.json" >&2
  exit 1
fi

FOLDER="${MOD_NAME}_${VERSION}"
ZIPFILE="${FOLDER}.zip"

echo "Packaging ${FOLDER}..."

cleanup() { rm -rf "$FOLDER"; }
trap cleanup EXIT

# Clean up any previous build artifacts
rm -rf "$FOLDER" "$ZIPFILE"

# Factorio requires the zip to contain a single top-level folder named
# "<mod-name>_<version>" holding the mod files.
mkdir -p "$FOLDER"

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

for entry in "${ENTRIES[@]}"; do
  if [[ -e "$entry" ]]; then
    cp -r "$entry" "$FOLDER/"
  fi
done

# Create the zip (skip macOS metadata)
zip -r "$ZIPFILE" "$FOLDER" -x "*.DS_Store" > /dev/null

SIZE=$(wc -c < "$ZIPFILE" | tr -d ' ')
echo "Created ${ZIPFILE} (${SIZE} bytes)"
