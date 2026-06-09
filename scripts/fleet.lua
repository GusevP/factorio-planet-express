-- scripts/fleet.lua
--
-- Per-platform enrollment + per-ship limits, and the eligibility filter the
-- dispatcher uses to pick a ship for a route.
--
-- A fleet entry (in `storage.fleet[platform_id]`) is a plain table:
--   { platform, enrolled=bool, allowed_planets={names}|"all"|nil,
--     reserve_for_manual_use=bool, state="idle|enroute|loading|unloading|withdrawn",
--     assignment=<id>|nil }
--
-- Design split (per the plan's pure-function seam): the ELIGIBILITY math
-- (`allows_planet`, `idle_eligible`) is PURE over a plain entry table -- no
-- engine globals -- so it loads and runs under plain `lua` and is unit-tested.
-- The WRITERS mutate `storage.fleet`; the dispatcher (Task 5) and Trade-tab GUI
-- (Task 9) call them. The registry (Task 3) creates the entries.

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
-- gates the Trade tab. Mirrors trade_tab.tech_researched so the two GUIs gate
-- identically.
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

return fleet
