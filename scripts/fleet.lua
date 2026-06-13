-- scripts/fleet.lua
--
-- Per-platform enrollment + per-ship limits, and the eligibility filter the
-- dispatcher uses to pick a ship for a route.
--
-- A fleet entry (in `storage.fleet[platform_id]`) is a plain table:
--   { platform, enrolled=bool, allowed_planets={names}|"all"|nil,
--     reserve_for_manual_use=bool, state="idle|enroute|loading|unloading|withdrawn",
--     assignment=<id>|nil, stranded=bool, require_ready=bool,
--     eta_factor=number, eta_sample={ connection, distance, tick } }
--
-- `eta_factor` / `eta_sample` (v1.1, additive, nil-default, no migration) drive
-- the ETA-aware dispatcher: `eta_factor` is the learned per-ship speed
-- calibration (`eta = predicted * factor`, default 1.0 for a never-flown ship),
-- EMA-updated each watchdog flight sample (`watchdog.ema_factor`); `eta_sample`
-- is that sampler's cursor (`connection` is the connection NAME string -- a
-- stable serializable id, never the `space_connection` LuaObject).
--
-- `require_ready` (additive, nil = off, no migration) is the "Hold until ready
-- signal" toggle: when true the dispatcher only sends this ship while the hub
-- reads `planet-express-ready > 0`. See `ready_from_signal` (pure eval) and
-- `read_ready_value` (the thin engine read).
--
-- Design split (per the plan's pure-function seam): the ELIGIBILITY math
-- (`allows_planet`, `idle_eligible`) is PURE over a plain entry table -- no
-- engine globals -- so it loads and runs under plain `lua` and is unit-tested.
-- The WRITERS mutate `storage.fleet`; the Fleet-tab GUI (gui/fleet_tab.lua)
-- calls the enrollment writers, and the dispatcher/watchdog drive the
-- state/assignment writers. The registry (Task 3) creates the entries.

local fleet = {}

-- Ship lifecycle states. `withdrawn` is the player-wins escape hatch (Task 6):
-- a ship whose schedule the player edited is parked here until it goes idle so
-- the dispatcher stops fighting them.
fleet.IDLE = "idle"
fleet.ENROUTE = "enroute"
fleet.LOADING = "loading"
fleet.UNLOADING = "unloading"
fleet.WITHDRAWN = "withdrawn"

-- The single mod gate (Task 10): a platform can only be enrolled once its force
-- has researched "Interplanetary Trade Logistics" -- the same technology that
-- gates the Trade tab. This is the SINGLE source of truth: the Trade tab aliases
-- `fleet.TECH` / `fleet.tech_researched` so all three GUIs gate identically.
fleet.TECH = "interplanetary-trade-logistics"

-- Has `force` researched the gating technology? Tolerates a nil/partial force so
-- it never errors during early init.
function fleet.tech_researched(force)
  if not (force and force.technologies) then
    return false
  end
  local tech = force.technologies[fleet.TECH]
  return tech ~= nil and tech.researched == true
end

-- ---------------------------------------------------------------------------
-- ready-signal gate (pure eval + the ONE shared engine read)
-- ---------------------------------------------------------------------------

-- The dedicated virtual signal players emit to the hub to mark a ship ready.
-- `READY` is the SignalID the `get_signal` read passes; the data-stage prototype
-- of the same name lives in `data.lua`. NOTE the type split: the runtime
-- `SignalIDType` for a virtual signal is `"virtual"` (NOT `"virtual-signal"`,
-- which is the data-stage *prototype* type) -- using the prototype string here
-- makes `get_signal` never match the emitted signal, silently holding the ship.
fleet.READY_SIGNAL = "planet-express-ready"
fleet.READY = { type = "virtual", name = fleet.READY_SIGNAL }

-- Pure readiness decision: given the per-ship `require_ready` toggle and the hub
-- signal `value`, is the ship clear to dispatch? Toggle off (anything other than
-- an explicit `true`) -> always ready (today's behavior, no read needed). Toggle
-- on -> ready only while the signal is positive. Plain inputs, bool out -> the
-- unit-tested decision; the engine read lives in `read_ready_value`.
function fleet.ready_from_signal(require_ready, value)
  if require_ready ~= true then
    return true
  end
  return (value or 0) > 0
end

-- The ONE shared engine read (thin IO wrapper; sits beside `tech_researched`).
-- Reads the `planet-express-ready` value off the platform hub across BOTH circuit
-- wires (red + green), so the signal counts whichever wire carries it. Guards a
-- nil/invalid platform or hub -> 0 (the same "held when gated" outcome as a valid
-- but unwired hub, which `get_signal` itself returns 0 for). IO-only -> verified
-- by playtest, not by the calc tests.
function fleet.read_ready_value(platform)
  local hub = platform and platform.valid and platform.hub
  if not (hub and hub.valid) then
    return 0
  end
  return hub.get_signal(
    fleet.READY,
    defines.wire_connector_id.circuit_red,
    defines.wire_connector_id.circuit_green
  ) or 0
end

-- ---------------------------------------------------------------------------
-- pure eligibility math (testable; no engine globals)
-- ---------------------------------------------------------------------------

-- Does this entry's allow-list cover `planet_name`? An absent list, or the
-- sentinel "all", means "serves every planet". Otherwise the planet must appear
-- in the list. Pure over the entry table.
function fleet.allows_planet(entry, planet_name)
  local allowed = entry and entry.allowed_planets
  if allowed == nil or allowed == "all" then
    return true
  end
  for _, p in ipairs(allowed) do
    if p == planet_name then
      return true
    end
  end
  return false
end

-- Translate a Fleet-tab planet selection into the stored allow-list value.
-- `all_planets` is the full universe of known planet names (game.planets);
-- `allowed_set` is a set `{ [name]=true }` of the ones the player left ticked.
-- Returns nil when EVERY known planet is allowed -- the "serves all" default, so
-- a planet discovered later is served too -- otherwise the SORTED list of allowed
-- names (deterministic). An empty universe yields nil (nothing to restrict);
-- ticking nothing yields an explicit empty list (which `allows_planet` denies).
-- Pure so the collapse-to-unrestricted rule is unit-tested and the GUI stays dumb.
function fleet.allowed_from_selection(all_planets, allowed_set)
  allowed_set = allowed_set or {}
  local list = {}
  local all = true
  for _, name in ipairs(all_planets or {}) do
    if allowed_set[name] then
      list[#list + 1] = name
    else
      all = false
    end
  end
  if all then
    return nil
  end
  table.sort(list)
  return list
end

-- The enrolled, same-force ships offered as "Preferred ship" pins on the Trade
-- tab (Task 9). Returns a SORTED list of `{ id, caption }` (sorted by the fleet
-- key id -- a stable string, so the dropdown renders identically on every client
-- and the GUI can map a `selected_index` back to the key deterministically).
-- Only entries that are enrolled AND belong to `force_key` are offered; an
-- un-enrolled or foreign-force ship is skipped (it can't fly the route anyway).
-- The caption is the live platform name when a valid handle exists, else the
-- fleet key id itself -- the `entry.platform and entry.platform.valid` guard makes
-- it degrade cleanly under the pure-Lua test runner (no engine handle present).
-- Pure over the plain `fleet_tbl` (a `{ [key]=entry }` map) so it is unit-tested.
function fleet.enrolled_for_force(fleet_tbl, force_key)
  local ids = {}
  for id, entry in pairs(fleet_tbl or {}) do
    if entry and entry.enrolled == true and entry.force == force_key then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids)
  local out = {}
  for _, id in ipairs(ids) do
    local entry = fleet_tbl[id]
    local platform = entry.platform
    local caption = (platform and platform.valid and platform.name) or id
    out[#out + 1] = { id = id, caption = caption }
  end
  return out
end

-- Is this ship free AND permitted to fly the route `source` -> `dest`? True only
-- when the entry is enrolled, idle, unassigned, and its allow-list covers BOTH
-- planets. Pure over the entry table -- the dispatcher passes a live
-- `storage.fleet[...]` entry; tests pass plain tables. `source`/`dest` are
-- planet (space-location) names.
function fleet.idle_eligible(entry, source, dest)
  if not entry then
    return false
  end
  if entry.enrolled ~= true then
    return false
  end
  if entry.reserve_for_manual_use == true then
    return false
  end
  if entry.state ~= fleet.IDLE then
    return false
  end
  if entry.assignment ~= nil then
    return false
  end
  return fleet.allows_planet(entry, source) and fleet.allows_planet(entry, dest)
end

-- ---------------------------------------------------------------------------
-- writers (mutate storage.fleet entries)
-- ---------------------------------------------------------------------------

-- Fetch the entry for a platform id, or nil if the platform isn't registered.
function fleet.get(platform_id)
  return storage.fleet and storage.fleet[platform_id]
end

-- Enroll / un-enroll a platform in the fleet. Enrollment is strictly opt-in:
-- the dispatcher only ever touches enrolled, idle ships.
--
-- Gated behind the technology (Task 10): a platform cannot be ENROLLED until its
-- force has researched "Interplanetary Trade Logistics". Un-enrolling is always
-- allowed (so a ship can be released even if the gate somehow regressed). The
-- check is skipped when the entry carries no live platform/force handle (the
-- pure-Lua test path), so it never blocks unit tests.
function fleet.set_enrolled(platform_id, enrolled)
  local entry = fleet.get(platform_id)
  if entry then
    if enrolled == true then
      local force = entry.platform and entry.platform.valid and entry.platform.force
      if force and not fleet.tech_researched(force) then
        return entry  -- gate not met: leave un-enrolled
      end
      entry.enrolled = true
    else
      entry.enrolled = false
    end
  end
  return entry
end

-- Set a ship's allow-list. Pass a list of planet names to restrict it, or nil /
-- "all" to let it serve every planet.
function fleet.set_allowed_planets(platform_id, planets)
  local entry = fleet.get(platform_id)
  if entry then
    entry.allowed_planets = planets
  end
  return entry
end

-- Per-ship "leave this one for me" flag (reserved for manual use). Stored for
-- the GUI/dispatcher; the dispatcher treats a reserved ship as not enrollable
-- regardless of the enrolled toggle.
function fleet.set_reserve_for_manual_use(platform_id, reserved)
  local entry = fleet.get(platform_id)
  if entry then
    entry.reserve_for_manual_use = reserved == true
  end
  return entry
end

-- Per-ship "Hold until ready signal" toggle. When true the dispatch gate
-- (`build_snapshot` + `pick_ship`) only sends this ship while the hub reads
-- `planet-express-ready > 0`. Additive optional field (nil = off), so existing
-- entries read as un-gated with no migration.
function fleet.set_require_ready(platform_id, require_ready)
  local entry = fleet.get(platform_id)
  if entry then
    entry.require_ready = require_ready == true
  end
  return entry
end

-- Set a ship's lifecycle state (idle/enroute/loading/unloading/withdrawn).
function fleet.set_state(platform_id, new_state)
  local entry = fleet.get(platform_id)
  if entry then
    entry.state = new_state
  end
  return entry
end

-- Bind / clear the assignment id a ship is currently serving.
function fleet.set_assignment(platform_id, assignment_id)
  local entry = fleet.get(platform_id)
  if entry then
    entry.assignment = assignment_id
  end
  return entry
end

-- Mark / clear a ship as STRANDED. The watchdog sets this when a ship's
-- assignment times out (no fuel / no rockets / no progress for a full deadline)
-- and clears it once the ship makes real progress again (reaches a load/unload
-- stop) or completes a delivery. DISPLAY-ONLY: it does NOT gate dispatch (a
-- stranded ship is still freed to idle and re-dispatched -- `idle_eligible` never
-- reads it); it drives the Monitor's "stuck" count so a broken ship is visible at
-- a glance instead of hiding in the idle bucket. Additive optional field, so
-- pre-existing fleet entries (nil) read as not-stranded with no migration.
function fleet.set_stranded(platform_id, stranded)
  local entry = fleet.get(platform_id)
  if entry then
    entry.stranded = stranded == true
  end
  return entry
end

-- Store a ship's learned ETA calibration factor (v1.1). The continuous flight
-- sampler (watchdog) computes the EMA-updated value via `watchdog.ema_factor`
-- and writes it back here; `build_snapshot` reads `entry.eta_factor or 1.0`, so
-- a never-flown ship stays at the neutral 1.0 default with no migration. Guards
-- a nil/non-positive value -> leaves the entry untouched (the factor must stay
-- > 0 so it never zeroes out an ETA).
function fleet.set_eta_factor(platform_id, factor)
  local entry = fleet.get(platform_id)
  if entry and type(factor) == "number" and factor > 0 then
    entry.eta_factor = factor
  end
  return entry
end

-- Store the flight sampler's cursor (v1.1): the last-seen `{ connection,
-- distance, tick }` for the travelling ship. `connection` is the connection
-- NAME string (serializable + stable across save/load), NOT the
-- `space_connection` LuaObject. Pass nil to clear the cursor on park / route
-- change so the next sample starts fresh instead of differencing across a gap.
function fleet.set_eta_sample(platform_id, sample)
  local entry = fleet.get(platform_id)
  if entry then
    entry.eta_sample = sample
  end
  return entry
end

return fleet
