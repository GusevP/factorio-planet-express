-- scripts/viewmodel.lua
--
-- Pure view-model builders for the fleet monitor GUI (Task 8). The GUI itself
-- (scripts/gui/monitor.lua) is dumb render code; ALL the shaping logic lives
-- here as pure functions over plain tables so it is unit-tested under plain
-- `lua` with no engine globals (the same pure-function seam the rest of the mod
-- uses).
--
-- Two layers, matching the dispatcher's split:
--   * PURE (tested): `classify_waiting`, `build`, `apply_filters` -- plain tables
--     in, plain view model out. No `storage`, no `game`, no `settings`.
--   * IO (provisional, verified by playtest): `gather` snapshots `storage` + a
--     fresh dispatcher snapshot into the plain `world` table the pure `build`
--     consumes. It is the only engine-touching function here.
--
-- The view model shape `build` returns:
--   { roster    = { { ship_id, state, from, to, manifest, assignment_id }, ... },
--     shipments = { { id, ship_id, from, to, manifest, return_manifest, phase,
--                     ticks_left }, ... },
--     waiting   = { { item, dest_planet, unmet, reason }, ... },
--     alerts    = { { kind, assignment, tick, detail }, ... },  -- newest first
--     summary   = { ships_total, ships_idle, ships_active, ships_withdrawn,
--                   shipments, waiting, alerts } }

local state = require("scripts.state")
local fleet = require("scripts.fleet")

local viewmodel = {}

-- Waiting-demand reason codes (locale keys are derived from these in the GUI).
viewmodel.REASON_NO_SOURCE = "no_source"
viewmodel.REASON_SOURCE_BUSY = "source_busy_importing"
viewmodel.REASON_NO_SHIP = "no_ship"
viewmodel.REASON_IN_TRANSIT = "in_transit"
viewmodel.REASON_BELOW_MIN_TRIP = "below_min_trip"

-- How many of the most recent alerts the monitor shows.
viewmodel.MAX_ALERTS = 20

-- Ship states that count as "actively running a job" for the summary roll-up.
local ACTIVE_STATES = {
  [fleet.ENROUTE] = true,
  [fleet.LOADING] = true,
  [fleet.UNLOADING] = true,
}

-- ---------------------------------------------------------------------------
-- pure waiting-demand reason classifier
-- ---------------------------------------------------------------------------

-- Why is `dest` still waiting on an item? Pure over a per-item supply picture.
-- `candidates` is a list of OTHER nodes' supply for this item:
--   { surplus = <stock - reserve, clamped >=0, NO min-trip applied>,
--     importing = <bool: this candidate has open demand for the same item> }
-- `min_trip` is the minimum-trip threshold.
--
-- The classifier mirrors the dispatcher's actual blocking logic so the monitor
-- never lies about why nothing moved:
--   * if a shipment carrying this exact item is already in flight to this planet
--     -> `in_transit` (a ship IS coming; "no ship" would be a lie). Takes top
--     priority -- the residual open demand exists only because one ship can't
--     carry it all and the per-route cap blocks adding a second.
--   * a candidate is a REAL source only when it is NOT importing the item (the
--     re-export thrash guard, dispatcher.exportable) AND its surplus is at or
--     above min-trip. If any real source exists yet the item is still open, the
--     only thing missing is a ship  -> `no_ship`.
--   * otherwise, if a candidate HAS the surplus but is guard-suppressed because
--     it is importing the same item                              -> `source_busy_importing`.
--   * otherwise, if a candidate has a positive-but-sub-min-trip surplus -> `below_min_trip`.
--   * otherwise nobody has any surplus to give                  -> `no_source`.
--
-- `in_transit` is supplied by the gather layer (it knows the live assignments);
-- it defaults false so existing pure tests are unaffected.
function viewmodel.classify_waiting(candidates, min_trip, in_transit)
  if in_transit then
    return viewmodel.REASON_IN_TRANSIT
  end
  min_trip = min_trip or 1
  local has_real_source = false
  local has_importing_surplus = false
  local has_below_min = false
  for _, c in ipairs(candidates or {}) do
    local sp = c.surplus or 0
    if sp > 0 then
      if c.importing then
        has_importing_surplus = true
      elseif sp >= min_trip then
        has_real_source = true
      else
        has_below_min = true
      end
    end
  end
  if has_real_source then
    return viewmodel.REASON_NO_SHIP
  end
  if has_importing_surplus then
    return viewmodel.REASON_SOURCE_BUSY
  end
  if has_below_min then
    return viewmodel.REASON_BELOW_MIN_TRIP
  end
  return viewmodel.REASON_NO_SOURCE
end

-- ---------------------------------------------------------------------------
-- pure view-model builder
-- ---------------------------------------------------------------------------

-- Build the full monitor view model from a plain `world` snapshot:
--   world = {
--     fleet       = { [ship_id] = { state, assignment } },
--     assignments = { [id] = { ship, source_planet, dest_planet, manifest,
--                              return_manifest, phase, deadline_tick } },
--     waiting     = { { item, dest_planet, unmet,
--                       reason | (candidates, min_trip) }, ... },
--     alerts      = { { kind, assignment, tick, detail }, ... },
--     tick        = <current tick, for ticks_left> }
-- Deterministic: every list is emitted in stable order (sorted ids / planet+item)
-- so two clients render the same panel.
function viewmodel.build(world)
  world = world or {}
  local fleet_in = world.fleet or {}
  local assignments = world.assignments or {}
  local waiting_in = world.waiting or {}
  local alerts_in = world.alerts or {}
  local tick = world.tick

  -- roster: every enrolled ship, with its current job resolved via assignment.
  -- The registry indexes EVERY platform hub the player builds (all start
  -- un-enrolled), so the merchant fleet is only the opt-in subset. Skip
  -- un-enrolled platforms -- except one still carrying a mod assignment after
  -- being un-enrolled mid-flight, which stays visible until the watchdog frees it
  -- (otherwise its in-flight shipment would show with no ship behind it).
  local roster = {}
  local idle, active, withdrawn = 0, 0, 0
  for _, sid in ipairs(state.sorted_keys(fleet_in)) do
    local e = fleet_in[sid]
    if e.enrolled == true or e.assignment ~= nil then
      local a = e.assignment and assignments[e.assignment] or nil
      roster[#roster + 1] = {
        ship_id = sid,
        state = e.state,
        from = a and a.source_planet or nil,
        to = a and a.dest_planet or nil,
        manifest = a and a.manifest or nil,
        assignment_id = e.assignment,
      }
      if e.state == fleet.IDLE then
        idle = idle + 1
      elseif e.state == fleet.WITHDRAWN then
        withdrawn = withdrawn + 1
      elseif ACTIVE_STATES[e.state] then
        active = active + 1
      end
    end
  end

  -- active shipments: one row per in-flight assignment, in stable id order.
  local shipments = {}
  for _, aid in ipairs(state.sorted_keys(assignments)) do
    local a = assignments[aid]
    shipments[#shipments + 1] = {
      id = aid,
      ship_id = a.ship,
      from = a.source_planet,
      to = a.dest_planet,
      manifest = a.manifest,
      return_manifest = a.return_manifest,
      phase = a.phase,
      ticks_left = (a.deadline_tick and tick) and (a.deadline_tick - tick) or nil,
    }
  end

  -- waiting demand: classify each open item's blocking reason (unless gather
  -- already supplied one), then sort by planet then item for a stable panel.
  local waiting = {}
  for _, w in ipairs(waiting_in) do
    waiting[#waiting + 1] = {
      item = w.item,
      dest_planet = w.dest_planet,
      unmet = w.unmet,
      reason = w.reason or viewmodel.classify_waiting(w.candidates, w.min_trip, w.in_transit),
    }
  end
  table.sort(waiting, function(a, b)
    local ap, bp = tostring(a.dest_planet), tostring(b.dest_planet)
    if ap ~= bp then
      return ap < bp
    end
    return tostring(a.item) < tostring(b.item)
  end)

  -- alerts: newest first, capped to MAX_ALERTS for display.
  local alerts = {}
  for i = #alerts_in, 1, -1 do
    alerts[#alerts + 1] = alerts_in[i]
    if #alerts >= viewmodel.MAX_ALERTS then
      break
    end
  end

  local summary = {
    ships_total = #roster,
    ships_idle = idle,
    ships_active = active,
    ships_withdrawn = withdrawn,
    shipments = #shipments,
    waiting = #waiting,
    alerts = #alerts_in,
  }

  return {
    roster = roster,
    shipments = shipments,
    waiting = waiting,
    alerts = alerts,
    summary = summary,
  }
end

-- ---------------------------------------------------------------------------
-- pure per-node "this planet now" readout (Task 9 Trade tab)
-- ---------------------------------------------------------------------------

-- Build the "This planet now" readout for a single trade node from a plain
-- `world` snapshot:
--   world = {
--     demand   = { { item, unmet, priority }, ... },  -- this node's open demand
--     surplus  = { { item, qty }, ... },              -- guarded exportable surplus
--     inbound  = { { item, qty }, ... } }             -- fleet cargo en route here
-- Returns the same three lists, each in a STABLE order so the panel renders
-- identically on every client: demand by priority desc, then unmet desc, then
-- item asc (matching demand.build_open); surplus and inbound by item asc. Pure:
-- no `storage`, no `game`; the input is not mutated.
function viewmodel.build_node_readout(world)
  world = world or {}

  local function by_item(list)
    local out = {}
    for _, r in ipairs(list or {}) do
      out[#out + 1] = { item = r.item, qty = r.qty }
    end
    table.sort(out, function(a, b)
      return tostring(a.item) < tostring(b.item)
    end)
    return out
  end

  local demand = {}
  for _, d in ipairs(world.demand or {}) do
    demand[#demand + 1] = { item = d.item, unmet = d.unmet, priority = d.priority or 0 }
  end
  table.sort(demand, function(a, b)
    if a.priority ~= b.priority then
      return a.priority > b.priority
    end
    if a.unmet ~= b.unmet then
      return a.unmet > b.unmet
    end
    return tostring(a.item) < tostring(b.item)
  end)

  return {
    demand = demand,
    surplus = by_item(world.surplus),
    inbound = by_item(world.inbound),
  }
end

-- ---------------------------------------------------------------------------
-- pure filters
-- ---------------------------------------------------------------------------

-- Treat empty/whitespace filter strings as "no filter".
local function norm(s)
  if s == nil then
    return nil
  end
  if type(s) ~= "string" then
    return s
  end
  if s:match("^%s*$") then
    return nil
  end
  return s
end

local function manifest_has(manifest, item)
  return manifest ~= nil and manifest[item] ~= nil
end

-- Narrow a built view model by an optional `{ planet, item, state }` filter.
-- Each absent (or blank) field imposes no constraint. The roster/shipments/
-- waiting lists are filtered; the summary stays the GLOBAL network roll-up (the
-- "one-line network summary" is not filtered). Pure: returns a new view; the
-- input is not mutated.
function viewmodel.apply_filters(view, filters)
  filters = filters or {}
  local planet = norm(filters.planet)
  local item = norm(filters.item)
  local fstate = norm(filters.state)

  local roster = {}
  for _, r in ipairs(view.roster or {}) do
    local ok = true
    if planet and r.from ~= planet and r.to ~= planet then
      ok = false
    end
    if ok and item and not manifest_has(r.manifest, item) then
      ok = false
    end
    if ok and fstate and r.state ~= fstate then
      ok = false
    end
    if ok then
      roster[#roster + 1] = r
    end
  end

  local shipments = {}
  for _, s in ipairs(view.shipments or {}) do
    local ok = true
    if planet and s.from ~= planet and s.to ~= planet then
      ok = false
    end
    if ok and item and not (manifest_has(s.manifest, item) or manifest_has(s.return_manifest, item)) then
      ok = false
    end
    if ok then
      shipments[#shipments + 1] = s
    end
  end

  local waiting = {}
  for _, w in ipairs(view.waiting or {}) do
    local ok = true
    if planet and w.dest_planet ~= planet then
      ok = false
    end
    if ok and item and w.item ~= item then
      ok = false
    end
    if ok then
      waiting[#waiting + 1] = w
    end
  end

  return {
    roster = roster,
    shipments = shipments,
    waiting = waiting,
    alerts = view.alerts,
    summary = view.summary,
  }
end

-- ---------------------------------------------------------------------------
-- IO: gather the plain `world` from storage + a fresh dispatcher snapshot
-- (provisional -- engine-touching; verified by manual playtest)
-- ---------------------------------------------------------------------------

local dispatcher = require("scripts.dispatcher")
local stock = require("scripts.stock")
local reserves = require("scripts.reserves")
local demand = require("scripts.demand")

-- Snapshot `storage` + a fresh dispatcher snapshot into the plain `world` the
-- pure `build` consumes. Reuses the per-tick stock cache (begin_tick is a no-op
-- if the dispatcher already opened this tick). Only called in-game.
function viewmodel.gather(tick)
  stock.begin_tick(tick)
  local snapshot = dispatcher.build_snapshot(tick)
  -- Same minimum-trip threshold the stock layer suppresses surplus against, so
  -- `classify_waiting` names `below_min_trip` consistently (one source of truth).
  local mt = stock.min_trip()
  -- Surplus already committed to in-flight shipments, keyed by node id -- the
  -- same bookkeeping build_snapshot folds into the dispatcher's working surplus.
  -- The candidate picture below must subtract it too, or the monitor sees a
  -- source the dispatcher can't actually draw from and reports a false `no_ship`.
  local committed = dispatcher.committed_surplus_by_node()

  -- Items already in flight TO a planet (forward cargo to its dest, return cargo
  -- to its source), keyed by planet -> { [item]=true }. A waiting item already
  -- aboard a ship heading here is `in_transit`, not `no_ship` -- the residual
  -- demand persists only because one ship can't carry it all and the per-route
  -- cap blocks a second. Set-building, so plain pairs is fine.
  local serving = {}
  local function mark_serving(planet, manifest)
    if not (planet and manifest) then
      return
    end
    local m = serving[planet]
    if not m then
      m = {}
      serving[planet] = m
    end
    for item in pairs(manifest) do
      m[item] = true
    end
  end
  for _, a in state.sorted_pairs(storage.assignments or {}) do
    mark_serving(a.dest_planet, a.manifest)
    mark_serving(a.source_planet, a.return_manifest)
  end

  -- fleet roster source (state + assignment only; the rest comes from the
  -- assignment record so the two never disagree).
  local fleet_world = {}
  for id, entry in state.sorted_pairs(storage.fleet or {}) do
    fleet_world[id] = {
      state = entry.state,
      assignment = entry.assignment,
      enrolled = entry.enrolled,
    }
  end

  -- assignments, projected to the display-relevant fields.
  local assignments_world = {}
  for id, a in state.sorted_pairs(storage.assignments or {}) do
    assignments_world[id] = {
      ship = a.ship,
      source_planet = a.source_planet,
      dest_planet = a.dest_planet,
      manifest = a.manifest,
      return_manifest = a.return_manifest,
      phase = a.phase,
      deadline_tick = a.deadline_tick,
    }
  end

  -- waiting demand: anything still in a node's open demand is unserved this
  -- tick. Build its per-item candidate supply picture (raw surplus, NO min-trip,
  -- plus the importing flag) so classify_waiting can name the real blocker.
  local waiting = {}
  for _, did in ipairs(state.sorted_keys(snapshot.nodes)) do
    local dnode = snapshot.nodes[did]
    for _, d in ipairs(dnode.demand) do
      local candidates = {}
      for _, sid in ipairs(state.sorted_keys(snapshot.nodes)) do
        if sid ~= did then
          local snode = snapshot.nodes[sid]
          local com = (committed[sid] and committed[sid][d.item]) or 0
          local raw = stock.stock_count(snode.node, d.item)
            - reserves.reserve(snode.node, d.item) - com
          if raw < 0 then
            raw = 0
          end
          local importing = (snode.unmet_by_item[d.item] or 0) > 0
          candidates[#candidates + 1] = { surplus = raw, importing = importing }
        end
      end
      waiting[#waiting + 1] = {
        item = d.item,
        dest_planet = dnode.planet,
        unmet = d.unmet,
        candidates = candidates,
        min_trip = mt,
        in_transit = (serving[dnode.planet] and serving[dnode.planet][d.item]) == true,
      }
    end
  end

  return {
    fleet = fleet_world,
    assignments = assignments_world,
    waiting = waiting,
    alerts = storage.alerts or {},
    tick = tick,
  }
end

-- Snapshot the live "this planet now" world for a single trade `node` (Task 9
-- Trade tab). Reuses the dispatcher's per-tick snapshot so the readout matches
-- exactly what the dispatcher would see this tick:
--   * demand  = the node's open demand (priority-sorted, inbound already netted),
--   * surplus = its GUARDED exportable surplus (only items some node demands AND
--     that pass the re-export thrash guard -- i.e. what it could actually ship),
--   * inbound = fleet cargo already committed to this node (forward + return leg).
-- Pure shaping is left to `build_node_readout`; this is the only engine-touching
-- half (verified by manual playtest). Only called in-game.
function viewmodel.gather_node(node, tick)
  stock.begin_tick(tick)
  local snapshot = dispatcher.build_snapshot(tick)
  local ns = snapshot.nodes[node.id]

  local demand_list = ns and ns.demand or demand.open_demand(node)

  local surplus = {}
  if ns then
    for _, item in ipairs(state.sorted_keys(ns.surplus)) do
      local exportable = dispatcher.exportable(ns, item)
      if exportable > 0 then
        surplus[#surplus + 1] = { item = item, qty = exportable }
      end
    end
  end

  local inbound = {}
  for item, qty in state.sorted_pairs(demand.inbound_for(node)) do
    inbound[#inbound + 1] = { item = item, qty = qty }
  end

  return { demand = demand_list, surplus = surplus, inbound = inbound }
end

return viewmodel
