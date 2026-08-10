#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# --- Release lines ----------------------------------------------------------
# This one source tree ships as TWO Mod Portal uploads that differ ONLY in
# info.json's `version` + `factorio_version`. Factorio gates compatibility by
# the minor series, so a 2.0 upload and a 2.1 upload are separate releases even
# though the code is identical.
#
#   PRIMARY (2.1) line -> version + factorio_version come straight from info.json.
#   COMPAT  (2.0) line -> same tree, those two fields overridden to the values below.
#
# Bump the 2.1 line by editing info.json as usual; bump the 2.0 line here.
COMPAT_MOD_VERSION="1.10.7"
COMPAT_FACTORIO_VERSION="2.0"
# ----------------------------------------------------------------------------

if [[ ! -f info.json ]]; then
  echo "Error: info.json not found in $(pwd)" >&2
  exit 1
fi

# Derive name + the primary (2.1) version/factorio_version from info.json so
# they never drift from what the mod actually declares.
MOD_NAME=$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' info.json | head -1)
PRIMARY_VERSION=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' info.json | head -1)
PRIMARY_FACTORIO_VERSION=$(sed -n 's/.*"factorio_version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' info.json | head -1)

[[ -n "$MOD_NAME" ]]                || { echo "Error: could not extract \"name\" from info.json" >&2; exit 1; }
[[ -n "$PRIMARY_VERSION" ]]         || { echo "Error: could not extract \"version\" from info.json" >&2; exit 1; }
[[ -n "$PRIMARY_FACTORIO_VERSION" ]] || { echo "Error: could not extract \"factorio_version\" from info.json" >&2; exit 1; }

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

# Rewrite exactly the two string fields in a COPY of info.json (never the source
# tree). Tolerant of surrounding whitespace; line-based because info.json keeps
# one field per line.
patch_info() {
  local file="$1" version="$2" fv="$3"
  sed -i.bak \
    -e 's/\("version"[[:space:]]*:[[:space:]]*"\)[^"]*\(".*\)/\1'"$version"'\2/' \
    -e 's/\("factorio_version"[[:space:]]*:[[:space:]]*"\)[^"]*\(".*\)/\1'"$fv"'\2/' \
    "$file"
  rm -f "$file.bak"
}

# Build one zip. Args: <version> <factorio_version>. Factorio requires the zip to
# contain a single top-level folder "<mod-name>_<version>" holding the mod files.
build() {
  local version="$1" fv="$2"
  local folder="${MOD_NAME}_${version}"
  local zipfile="${folder}.zip"

  echo "Packaging ${folder} (factorio_version ${fv})..."
  rm -rf "$folder" "$zipfile"
  mkdir -p "$folder"

  for entry in "${ENTRIES[@]}"; do
    if [[ -e "$entry" ]]; then
      cp -r "$entry" "$folder/"
    fi
  done

  # Patch the copy so each release declares its own version + series (the .bak is
  # removed inside patch_info, before the zip is created, so it never ships).
  patch_info "$folder/info.json" "$version" "$fv"

  zip -r "$zipfile" "$folder" -x "*.DS_Store" > /dev/null
  rm -rf "$folder"

  local size
  size=$(wc -c < "$zipfile" | tr -d ' ')
  echo "Created ${zipfile} (${size} bytes)"
}

# Build both release lines from the one source tree.
build "$PRIMARY_VERSION" "$PRIMARY_FACTORIO_VERSION"
build "$COMPAT_MOD_VERSION" "$COMPAT_FACTORIO_VERSION"
