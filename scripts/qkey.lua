-- scripts/qkey.lua
--
-- Compound (item, quality) key helper for Planet Express.
--
-- Quality variants (Space Age) mean an item name alone is no longer a unique
-- cargo key: "iron-plate" at normal vs. uncommon quality must dispatch, load,
-- and net out independently. This module encodes a (item, quality) pair into a
-- single STABLE string key -- `item .. "@" .. quality` -- so every decision map
-- (demand, surplus, manifest, commit bookkeeping) can stay string-keyed and
-- still iterate deterministically through `state.sorted_pairs`: string keys
-- sort stably across peers and across save/load (the multiplayer hard
-- constraint), whereas a structured {item, quality} table key would not.
--
-- Factorio prototype names are restricted to letters, digits, hyphen and
-- underscore -- neither an item name nor a quality name can contain "@" -- so a
-- well-formed key has exactly one "@" and round-trips unambiguously. A key with
-- no separator (a bare item name, e.g. legacy item-name-keyed data from before
-- the quality upgrade) decodes as the default quality, so old maps degrade
-- safely.
--
-- PURE: no `game`/engine globals, so it loads and runs under the plain-`lua`
-- calc test runner. The engine-touching seams decode keys back to
-- (name, quality) at the IO boundary.

local qkey = {}

-- The default quality every Space Age item ships at. An item with no explicit
-- quality is encoded -- and an undecorated key parsed back -- as "normal".
qkey.DEFAULT_QUALITY = "normal"

-- Separator between the item name and the quality name. Chosen because it
-- cannot appear inside a Factorio prototype name, keeping the key unambiguous.
local SEP = "@"

-- Encode (item, quality) -> "item@quality". `quality` defaults to "normal" when
-- nil, so callers that don't care about quality get the same key the engine
-- would produce for a normal-quality item.
function qkey.qkey(item, quality)
  return item .. SEP .. (quality or qkey.DEFAULT_QUALITY)
end

-- Decode "item@quality" -> item, quality. A key with no separator (a bare item
-- name) parses as (item, "normal"); an empty quality segment also falls back to
-- "normal". Splits on the FIRST separator: item names never contain "@", so the
-- first one always divides name from quality.
function qkey.qparse(key)
  local at = string.find(key, SEP, 1, true)
  if not at then
    return key, qkey.DEFAULT_QUALITY
  end
  local item = string.sub(key, 1, at - 1)
  local quality = string.sub(key, at + 1)
  if quality == "" then
    quality = qkey.DEFAULT_QUALITY
  end
  return item, quality
end

-- Human-readable label from an already-decoded (name, quality) pair, for DISPLAY
-- only. Drops the "normal"-quality noise: a normal-quality item shows as the bare
-- name ("iron-plate"), any other quality is parenthesised ("iron-plate
-- (uncommon)"). The single source of truth for the player-facing label format,
-- shared by `qkey.label` (key in) and the view-model readouts (parts already in
-- hand). PURE string math -- no engine globals.
function qkey.label_parts(name, quality)
  if quality == nil or quality == qkey.DEFAULT_QUALITY then
    return name
  end
  return name .. " (" .. quality .. ")"
end

-- Human-readable label for a cargo key, for DISPLAY only (the monitor manifests,
-- the debug decision log). Decodes the key, then formats it via `label_parts`, so
-- every dumb-view / debug call site shows "iron-plate" (or "iron-plate
-- (uncommon)") instead of the raw "iron-plate@normal".
function qkey.label(key)
  return qkey.label_parts(qkey.qparse(key))
end

return qkey
