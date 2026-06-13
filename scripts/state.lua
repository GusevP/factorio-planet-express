-- scripts/state.lua
--
-- Determinism & persistence core for Planet Express.
--
-- Responsibilities:
--   * initialize the `storage` schema (control-stage persistent state)
--   * a STABLE sorted-iteration helper used for EVERY game-affecting loop
--     (multiplayer determinism: `pairs` order is non-deterministic across
--     runs/clients, so any decision-affecting iteration MUST go through here)
--   * a MONOTONIC id counter for assignment ids (never derive ids from table
--     address or wall-clock -- those are non-deterministic)
--   * a debug-log helper gated by a runtime setting
--
-- Migrations: `on_configuration_changed` ensures the schema exists and runs any
-- versioned migration branch needed to bring an older save up to
-- `SCHEMA_VERSION`. v2 re-keys `storage.fleet` to the force-qualified fleet key.

local state = {}

-- Current storage schema version. Bump + add a migration branch in
-- `state.on_configuration_changed` when the shape below changes.
--   v2: fleet keyed by "<force key>/<platform index>" (was bare platform index).
-- Additive optional fleet-entry fields do NOT bump the version (they read as
-- their nil-default on old saves, so no migration is needed): e.g.
-- `entry.require_ready` (the "Hold until ready signal" gate -- nil = off);
-- `entry.eta_factor` (v1.1 learned per-ship speed calibration -- nil reads as
-- 1.0) and `entry.eta_sample` (`{ connection, distance, tick }`, the continuous
-- flight sampler's cursor -- `connection` is the connection NAME string, not the
-- `space_connection` LuaObject, so it stays serializable across save/load).
state.SCHEMA_VERSION = 2

-- ---------------------------------------------------------------------------
-- storage initialization
-- ---------------------------------------------------------------------------

-- Ensure every top-level storage field exists. Idempotent: safe to call from
-- on_init AND on_configuration_changed (newly added fields get backfilled
-- without clobbering existing data).
function state.init()
  storage.schema_version = storage.schema_version or state.SCHEMA_VERSION

  -- trade nodes (cargo landing pads), keyed by pad unit_number
  storage.nodes = storage.nodes or {}
  -- enrolled space platforms, keyed by platform id
  storage.fleet = storage.fleet or {}
  -- active assignments, keyed by monotonic id
  storage.assignments = storage.assignments or {}
  -- stranded/destroyed/conflict events for the monitor GUI
  storage.alerts = storage.alerts or {}

  -- monotonic id counter for assignment ids (determinism: never reuse table
  -- address / tick as an id).
  storage.next_assignment_id = storage.next_assignment_id or 1
end

-- ---------------------------------------------------------------------------
-- migrations (pure, so they are unit-tested without an engine)
-- ---------------------------------------------------------------------------

-- v2: re-key the fleet from the bare platform index to the force-qualified fleet
-- key. PURE: takes the live `fleet`/`assignments` tables plus a `key_of(entry)`
-- resolver (the only engine-touching part, injected by the caller) and returns
-- the re-keyed fleet table while rewriting each assignment's `.ship` from the old
-- key to the new one.
--
-- An entry whose `key_of(entry)` returns nil (its platform handle is invalid, so
-- no force can be resolved) is DROPPED -- it is a ghost anyway. Its assignment is
-- left referencing the old key: the watchdog's destroyed-ship path frees it (the
-- `fleet.get(a.ship)` lookup misses and the assignment is re-opened), so we do
-- not need to touch it here.
--
-- The re-key build writes into a fresh map keyed by the new key; that is
-- order-independent (keyed writes, no decision over the set), so plain `pairs`
-- is correct here and introduces no nondeterminism.
function state.migrate_fleet_keys(fleet_tbl, assignments_tbl, key_of)
  local new_fleet = {}
  local old_to_new = {}
  for old_key, entry in pairs(fleet_tbl or {}) do
    local new_key = key_of(entry)
    if new_key ~= nil then
      new_fleet[new_key] = entry
      old_to_new[old_key] = new_key
    end
  end
  for _, a in pairs(assignments_tbl or {}) do
    if a and a.ship ~= nil then
      local mapped = old_to_new[a.ship]
      if mapped ~= nil then
        a.ship = mapped
      end
    end
  end
  return new_fleet
end

-- on_configuration_changed: keep schema current (backfill + versioned
-- migrations). Reads the PRE-migration version: `state.init` preserves an
-- existing `storage.schema_version` (the `or` guard), so the `< 2` branch sees
-- the old value before the unconditional bump below.
--
-- ORDERING (load-bearing): control.lua runs this BEFORE `registry.rebuild()`.
-- The fleet re-key MUST happen first so rebuild re-adds platforms under the new
-- key format (`registry.add_platform` -> `registry.fleet_key`) instead of
-- duplicating the same ships under stale numeric keys. Do not reorder control.lua.
function state.on_configuration_changed(_event)
  state.init()

  -- v2: force-qualify the fleet keys. Resolve each entry's new key from its live
  -- platform handle (mirrors `registry.fleet_key`); an invalid handle yields nil
  -- and the entry is dropped by `migrate_fleet_keys`. The resolver is the only
  -- engine-touching part; the migration itself is pure.
  if storage.schema_version < 2 then
    local function key_of(entry)
      local platform = entry and entry.platform
      if not (platform and platform.valid) then
        return nil
      end
      local force = platform.force
      local fk = force and (force.index or force.name)
      return tostring(fk) .. "/" .. tostring(platform.index)
    end
    storage.fleet = state.migrate_fleet_keys(storage.fleet, storage.assignments, key_of)
  end

  storage.schema_version = state.SCHEMA_VERSION
end

-- ---------------------------------------------------------------------------
-- monotonic id counter
-- ---------------------------------------------------------------------------

-- Allocate the next assignment id. Deterministic and never reused within a
-- save (counter only ever increments).
function state.next_id()
  local id = storage.next_assignment_id
  storage.next_assignment_id = id + 1
  return id
end

-- ---------------------------------------------------------------------------
-- stable sorted iteration
-- ---------------------------------------------------------------------------

-- Default comparator: works for the mixed-type keys Factorio hands us
-- (numeric unit_numbers, string item names). Numbers sort before strings, then
-- by natural order within each type, so the order is total and stable.
local function default_key_less(a, b)
  local ta, tb = type(a), type(b)
  if ta ~= tb then
    return ta < tb
  end
  return a < b
end

-- Return a stably-sorted array of the keys of `tbl`.
-- `comp` (optional) compares two KEYS; defaults to `default_key_less`.
function state.sorted_keys(tbl, comp)
  local keys = {}
  for k in pairs(tbl) do
    keys[#keys + 1] = k
  end
  table.sort(keys, comp or default_key_less)
  return keys
end

-- Deterministic replacement for `pairs`. Iterates `tbl` in stable key order.
-- Usage: for k, v in state.sorted_pairs(tbl) do ... end
-- `comp` (optional) compares two KEYS.
function state.sorted_pairs(tbl, comp)
  local keys = state.sorted_keys(tbl, comp)
  local i = 0
  return function()
    i = i + 1
    local k = keys[i]
    if k == nil then
      return nil
    end
    return k, tbl[k]
  end
end

-- ---------------------------------------------------------------------------
-- guarded runtime-global setting reader
-- ---------------------------------------------------------------------------

-- Read a runtime-global mod setting, degrading safely when the engine is absent
-- (the pure-Lua test runner has no `settings` global). Returns the stored value
-- ONLY when `settings.global` is present AND the value's type matches
-- `type(fallback)`, else the `fallback`. A numeric value is `math.floor`ed --
-- every numeric setting in this mod is an integer, and the dispatcher interval /
-- max-ships caps rely on integers. This is the single source of truth for the
-- module-level-fallback load convention: every pure module that reads a setting
-- goes through here so it still loads under plain `lua`.
function state.setting(name, fallback)
  if settings and settings.global then
    local s = settings.global[name]
    if s ~= nil and type(s.value) == type(fallback) then
      if type(s.value) == "number" then
        return math.floor(s.value)
      end
      return s.value
    end
  end
  return fallback
end

-- ---------------------------------------------------------------------------
-- debug logging
-- ---------------------------------------------------------------------------

state.DEBUG_SETTING = "planet-express-debug-log"

-- Is debug logging enabled? Reads the runtime-global setting via `state.setting`
-- (defaults to false under the pure-Lua test runner). The `== true` keeps the
-- boolean contract even if a non-boolean value somehow slipped through.
function state.debug_enabled()
  return state.setting(state.DEBUG_SETTING, false) == true
end

-- Log a dispatch/decision line when debug logging is on. No-op otherwise.
-- Prefixed so lines are greppable. Goes to BOTH the in-game console (so the
-- player debugging the mod sees decisions live) and factorio-current.log (the
-- persistent record): `log()` alone never reaches the console, which reads as
-- "the mod is silent". `game` is absent under the pure-Lua test runner, but
-- `debug_enabled()` is already false there, so this never reaches the guard.
function state.debug_log(message)
  if not state.debug_enabled() then
    return
  end
  local line = "[planet-express] " .. message
  if log then
    log(line)
  end
  if game then
    game.print(line)
  end
end

return state
