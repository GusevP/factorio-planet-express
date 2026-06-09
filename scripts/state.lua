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
-- Migrations: stubbed at 0.0.1. There is no schema change to migrate yet, so
-- `on_configuration_changed` only ensures the schema exists. The first real
-- migration goes where marked below.

local state = {}

-- Current storage schema version. Bump + add a migration branch in
-- `state.on_configuration_changed` when the shape below changes.
state.SCHEMA_VERSION = 1

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

-- on_configuration_changed: keep schema current. STUB at 0.0.1 -- no data
-- migration needed yet, only backfill.
function state.on_configuration_changed(_event)
  state.init()

  -- === FIRST REAL MIGRATION GOES HERE ===
  -- When storage shape changes, bump SCHEMA_VERSION and add:
  --   if storage.schema_version < 2 then ... ; storage.schema_version = 2 end
  -- For now (v1) the schema is unchanged, so there is nothing to migrate.
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
-- debug logging
-- ---------------------------------------------------------------------------

state.DEBUG_SETTING = "planet-express-debug-log"

-- Is debug logging enabled? Reads the runtime-global setting if the engine is
-- present; defaults to false otherwise (e.g. under the pure-Lua test runner).
function state.debug_enabled()
  if settings and settings.global then
    local s = settings.global[state.DEBUG_SETTING]
    if s then
      return s.value == true
    end
  end
  return false
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
