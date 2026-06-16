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
--   { roster    = { { ship_id, name, state, stranded, location, from, to,
--                     manifest, assignment_id }, ... },
--     shipments = { { id, ship_id, from, to, manifest, return_manifest, phase,
--                     ticks_left }, ... },
--     waiting   = { { item, dest_planet, unmet, reason }, ... },
--     alerts    = { { kind, assignment, tick, detail }, ... },  -- newest first
--     summary   = { ships_total, ships_idle, ships_active, ships_withdrawn,
--                   ships_stuck, shipments, waiting, alerts } }

local state = require("scripts.state")
local fleet = require("scripts.fleet")
local qkey = require("scripts.qkey")
-- Required up here (not lazily in the IO section) so the PURE ETA helpers below
-- can reach `predicted_ticks` / `NOMINAL_SPEED`. dispatcher does not require
-- viewmodel, so there is no load cycle.
local dispatcher = require("scripts.dispatcher")

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
-- pure in-flight ETA (Task 8 -- Monitor display)
-- ---------------------------------------------------------------------------

-- Minimum trustworthy progress-rate (Δdistance per tick, where `distance` is the
-- 0..1 leg progress). Just after a cursor reset (fresh departure / connection
-- change) the measured Δdistance/Δtick can be a sliver for up to one watchdog
-- interval, which would yield an absurd multi-hour ETA; a rate at or below this
-- floor is treated as "no rate yet" and the row shows a fallback instead. A real
-- leg's rate is ~1/leg_ticks (e.g. ~1.7e-4 for a 600 km leg at NOMINAL_SPEED),
-- comfortably above this floor.
viewmodel.MIN_RATE = 1e-5

-- Pure remaining-flight ETA in TICKS for an in-flight ship, from the measured
-- progress-rate -- unit-free, it NEVER reads `platform.speed` (whose km/tick units
-- are unconfirmed). `live`:
--   { distance  = <0..1 progress along the CURRENT leg>,
--     rate      = <Δdistance/Δtick measured between the last two samples>,
--     remaining = <km of WHOLE legs still to fly AFTER the current one; default 0,
--                  v1 routes are two-stop so this is 0 today>,
--     factor    = <the ship's learned eta_factor; default 1.0> }
-- Current leg: `remaining_fraction / |rate|`. `distance` is the engine's 0..1
-- position on the connection's FIXED `from`->`to` axis (0=from, 1=to per the 2.0
-- docs), so a RETURN leg (`to`->`from`) counts the axis DOWN and the measured
-- `rate` (Δdistance/Δtick) is NEGATIVE. The SIGN of the rate therefore tells the
-- travel direction -- rate>0 climbs toward `to` (remaining = `1 - distance`),
-- rate<0 descends toward `from` (remaining = `distance`) -- and `|rate|` is the
-- speed. Remaining whole legs: the same NOMINAL_SPEED scorer the dispatcher uses
-- (`predicted_ticks`), scaled by the ship's factor. Returns `nil` when there is no
-- usable rate (missing, or a magnitude at/below MIN_RATE -- zero or near-zero) so
-- the caller renders a "calculating" fallback rather than dividing by ~0.
function viewmodel.remaining_eta(live)
  if not live then
    return nil
  end
  local rate = live.rate
  if not rate then
    return nil
  end
  local speed = rate < 0 and -rate or rate -- |rate|: a return leg measures it negative
  if speed < viewmodel.MIN_RATE then
    return nil
  end
  local distance = live.distance or 0
  if distance < 0 then
    distance = 0
  elseif distance > 1 then
    distance = 1
  end
  -- remaining 0..1 fraction toward THIS leg's destination, per travel direction.
  local remaining_frac = rate > 0 and (1 - distance) or distance
  local current = remaining_frac / speed
  if current < 0 then
    current = 0
  end
  local rest = dispatcher.predicted_ticks(live.remaining or 0) * (live.factor or 1.0)
  return current + rest
end

-- Format a tick count as "m:ss" (Factorio runs 60 ticks/sec). Sub-minute reads
-- "0:SS"; zero/negative reads "0:00"; large values keep counting minutes (no hour
-- rollover -- a cargo run is minutes, and even an absurd value renders rather than
-- overflowing). Pure string math -> unit-tested at the boundaries.
function viewmodel.format_eta(ticks)
  if not ticks or ticks < 0 then
    ticks = 0
  end
  local secs = math.floor(ticks / 60 + 0.5)
  local m = math.floor(secs / 60)
  local s = secs % 60
  return string.format("%d:%02d", m, s)
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
  local idle, active, withdrawn, stuck = 0, 0, 0, 0
  for _, sid in ipairs(state.sorted_keys(fleet_in)) do
    local e = fleet_in[sid]
    if e.enrolled == true or e.assignment ~= nil then
      local a = e.assignment and assignments[e.assignment] or nil
      roster[#roster + 1] = {
        ship_id = sid,
        name = e.name, -- platform name for display (nil under the pure test runner)
        state = e.state,
        stranded = e.stranded == true,
        held = e.held == true, -- ready-signal "held" (Task 6); ROW-only display label
        location = e.location, -- planet the ship is currently AT (nil in transit)
        from = a and a.source_planet or nil,
        to = a and a.dest_planet or nil,
        manifest = a and a.manifest or nil,
        assignment_id = e.assignment,
        -- Live in-flight ETA (ticks) from the measured progress-rate, if gather
        -- stamped the live fields (`eta_live`); nil for parked / un-sampled ships.
        eta_ticks = viewmodel.remaining_eta(e.eta_live),
      }
      -- DISJOINT buckets so working+idle+stuck+withdrawn partitions the roster.
      -- `stranded` takes precedence over the lifecycle state: a stranded ship reads
      -- idle (freed by the watchdog) or enroute (re-dispatched, still can't fly), but
      -- either way it is STUCK, not idle/working -- the dock's "N stuck" must not
      -- double-count it into another bucket.
      if e.stranded == true then
        stuck = stuck + 1
      elseif e.state == fleet.IDLE then
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
    -- The live ETA is a per-SHIP measurement (gather stamps it on the fleet
    -- entry), so resolve it through the carrying ship; nil unless that ship is
    -- in-flight and sampled. group_demand propagates it onto delivering items.
    local carrier = a.ship and fleet_in[a.ship] or nil
    shipments[#shipments + 1] = {
      id = aid,
      ship_id = a.ship,
      from = a.source_planet,
      to = a.dest_planet,
      manifest = a.manifest,
      return_manifest = a.return_manifest,
      phase = a.phase,
      progress_index = a.progress_index, -- route stop (1/2/3), for forward-vs-return leg
      ticks_left = (a.deadline_tick and tick) and (a.deadline_tick - tick) or nil,
      eta_ticks = carrier and viewmodel.remaining_eta(carrier.eta_live) or nil,
      -- provider holdings per loaded item (Monitor display): forward + return loads.
      source_avail = a.source_avail,
      dest_avail = a.dest_avail,
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
    ships_stuck = stuck,
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

-- Roll the flat `shipments` (in-flight assignments) + `waiting` (blocked open
-- demand) into a per-RECEIVING-planet status summary for the Monitor's collapsible
-- Demand section. Each (item,quality) a planet is receiving or still wants is
-- bucketed by how it is being handled RIGHT NOW:
--   * loading    -- a ship is at the source loading it for this planet
--   * delivering -- a ship is en route / unloading it to this planet
--   * waiting    -- open demand with no ship on it (carries the blocker reason)
-- Returns a planet-sorted list:
--   { { planet,
--       items  = { { item, qty, status, reason? }, ... },  -- status-then-item order
--       counts = { delivering, loading, waiting } }, ... }
-- `qty` is the in-flight amount (delivering/loading) or the unmet amount (waiting).
-- `delivering` wins over `loading` for the same item (the more-progressed ship);
-- an item already in flight never also lists as waiting (its residual open demand
-- reads `in_transit`, excluded here). Two-way return legs ARE surfaced: a ship past
-- the turnaround buckets its RETURN manifest under the SOURCE planet (loading at the
-- dest, then delivering home) via `contributions_of` (keyed off `progress_index` +
-- `phase`). Deterministic: planets and items are sorted; the qty maps are summed
-- order-independently (plain pairs). PURE -> unit-tested.
function viewmodel.group_demand(shipments, waiting)
  local planets = {}
  local order = {}
  local function planet(p)
    local g = planets[p]
    if not g then
      -- deliver/load: qkey -> qty; wait: qkey -> {unmet,reason}; deliver_eta:
      -- qkey -> soonest live ETA (ticks) among the ships delivering it;
      -- deliver_ships: qkey -> list of ship ids delivering it (for the Monitor's
      -- 1s in-place ETA refresh, which recomputes the soonest live ETA itself).
      -- load_from / load_avail: qkey -> the source PLANET a loading item is picked
      -- up at, and the provider's gross launchable surplus there (Monitor display).
      g = { deliver = {}, load = {}, wait = {}, deliver_eta = {}, deliver_ships = {},
            load_from = {}, load_avail = {} }
      planets[p] = g
      order[#order + 1] = p
    end
    return g
  end

  -- One shipment can touch TWO planets across a two-way (3-stop) trip: the FORWARD
  -- cargo goes to the destination, then the RETURN cargo comes back to the source.
  -- Which cargo is live -- which manifest, which planet, loading vs delivering -- is
  -- decided by the ship's current stop (`progress_index`: 1 = source load, 2 = dest
  -- turnaround, 3 = source drop) together with `phase`.
  --
  -- The lifecycle of any cargo is loading -> delivering -> (delivered, gone):
  --   * loading    -- parked at / heading to the pickup stop.
  --   * delivering -- ENROUTE carrying it toward the receiving planet.
  --   * delivered  -- once PARKED at the receiving planet the pad pulls it (sub-second),
  --                   so it is dropped from the view rather than lingering as "delivering"
  --                   until the assignment is freed. (Previously the forward cargo stayed
  --                   shown -- "loading"/"delivering" -- at the destination right through
  --                   the turnaround and return legs; that was the bug.)
  local function contributions_of(sh)
    if not (sh.to and sh.manifest) then
      return {}
    end
    local ret = sh.return_manifest
    local has_ret = ret ~= nil and next(ret) ~= nil
    local pi = sh.progress_index or 1
    local enroute = (sh.phase == fleet.ENROUTE)

    if pi <= 1 then
      -- Forward leg, at/heading to the SOURCE: loading the forward cargo there for the
      -- destination (parked loading), or in transit toward it (delivering). Bucketed
      -- under the destination either way.
      return { {
        planet = sh.to, items = sh.manifest,
        status = enroute and "delivering" or "loading",
        from = sh.from, avail = sh.source_avail,
        eta_ticks = sh.eta_ticks, ship_id = sh.ship_id,
      } }
    elseif pi == 2 then
      if enroute then
        -- forward cargo in transit to the destination
        return { {
          planet = sh.to, items = sh.manifest, status = "delivering",
          eta_ticks = sh.eta_ticks, ship_id = sh.ship_id,
        } }
      end
      -- PARKED at the destination: the forward cargo has been delivered (the pad pulled
      -- it), so it is dropped. On a two-way trip the return cargo is now LOADING here (the
      -- turnaround) for the source; on a one-way trip nothing remains (the ship just
      -- holds until the watchdog frees it).
      if has_ret then
        return { {
          planet = sh.from, items = ret, status = "loading",
          from = sh.to, avail = sh.dest_avail,
        } }
      end
      return {}
    else
      -- pi >= 3 (two-way return leg): delivering while in transit; once PARKED at the
      -- source the return cargo has been dropped (delivered) -> nothing shown.
      if has_ret and enroute then
        return { {
          planet = sh.from, items = ret, status = "delivering",
          eta_ticks = sh.eta_ticks, ship_id = sh.ship_id,
        } }
      end
      return {}
    end
  end

  for _, sh in ipairs(shipments or {}) do
    for _, c in ipairs(contributions_of(sh)) do
      local g = planet(c.planet)
      if c.status == "loading" then
        for k, qty in pairs(c.items or {}) do
          g.load[k] = (g.load[k] or 0) + qty
          -- where it loads from + the provider's holdings there (Monitor "from (N avail)").
          -- A given (planet,item) is almost always one source; last contribution wins.
          g.load_from[k] = c.from
          g.load_avail[k] = c.avail and c.avail[k] or nil
        end
      else -- delivering
        for k, qty in pairs(c.items or {}) do
          g.deliver[k] = (g.deliver[k] or 0) + qty
          -- soonest live ETA per delivering item (a planet may receive it on >1 ship);
          -- loading items have no in-flight ETA yet.
          if c.eta_ticks then
            local cur = g.deliver_eta[k]
            if cur == nil or c.eta_ticks < cur then
              g.deliver_eta[k] = c.eta_ticks
            end
          end
          -- record every delivering ship for the Monitor's 1s in-place ETA refresh
          -- (order-independent -- a min over these ships -- so append order is irrelevant).
          if c.ship_id ~= nil then
            local ships = g.deliver_ships[k]
            if not ships then
              ships = {}
              g.deliver_ships[k] = ships
            end
            ships[#ships + 1] = c.ship_id
          end
        end
      end
    end
  end

  for _, w in ipairs(waiting or {}) do
    if w.reason ~= viewmodel.REASON_IN_TRANSIT then
      planet(w.dest_planet).wait[w.item] = { unmet = w.unmet, reason = w.reason }
    end
  end

  table.sort(order)
  local out = {}
  for _, p in ipairs(order) do
    local g = planets[p]
    for k in pairs(g.deliver) do
      g.load[k] = nil -- delivering wins over loading for the same item
    end
    local items = {}
    local function emit(map, status)
      local keys = {}
      for k in pairs(map) do
        -- an item already in flight never also lists as waiting
        if not (status == "waiting" and (g.deliver[k] or g.load[k])) then
          keys[#keys + 1] = k
        end
      end
      table.sort(keys)
      for _, k in ipairs(keys) do
        if status == "waiting" then
          items[#items + 1] = { item = k, qty = map[k].unmet, status = status, reason = map[k].reason }
        else
          -- `eta_ticks` only on delivering rows that have a live measurement;
          -- loading rows (no in-flight progress yet) carry none. `eta_ships` is the
          -- delivering ships behind that ETA, for the Monitor's in-place 1s refresh.
          -- `from` / `avail` only on LOADING rows (the source it is picked up at +
          -- the provider's holdings there); delivering rows leave them nil.
          local loading = (status == "loading")
          items[#items + 1] = { item = k, qty = map[k], status = status,
            from = loading and g.load_from[k] or nil,
            avail = loading and g.load_avail[k] or nil,
            eta_ticks = g.deliver_eta[k], eta_ships = g.deliver_ships[k] }
        end
      end
    end
    emit(g.deliver, "delivering")
    emit(g.load, "loading")
    emit(g.wait, "waiting")
    local counts = { delivering = 0, loading = 0, waiting = 0 }
    for _, it in ipairs(items) do
      counts[it.status] = counts[it.status] + 1
    end
    if #items > 0 then
      out[#out + 1] = { planet = p, items = items, counts = counts }
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- pure per-node "this planet now" readout (Task 9 Trade tab)
-- ---------------------------------------------------------------------------

-- Build the "This planet now" readout for a single trade node from a plain
-- `world` snapshot. Each input row is keyed by the compound cargo `qkey`
-- (`item@quality`):
--   world = {
--     demand   = { { item = <qkey>, unmet, priority }, ... },  -- open demand
--     surplus  = { { item = <qkey>, qty }, ... },              -- exportable
--     inbound  = { { item = <qkey>, qty }, ... } }             -- fleet en route
-- Each output row DECODES the qkey into a bare `item` NAME + `quality` so the
-- dumb Trade-tab view shows real items ("iron-plate", not "iron-plate@normal").
-- Returns the three lists in a STABLE order so the panel renders identically on
-- every client: demand by priority desc, then unmet desc, then name asc, quality
-- asc; surplus and inbound by name asc, quality asc. A bare item-name key
-- (legacy / quality-agnostic) decodes to the same name at "normal" quality. Pure:
-- no `storage`, no `game`; the input is not mutated (qparse is plain string math).
function viewmodel.build_node_readout(world)
  world = world or {}

  -- name asc, then quality asc -- a deterministic order independent of the qkey's
  -- "@" byte position, so two qualities of one item always sort adjacent.
  local function by_name(a, b)
    if a.item ~= b.item then
      return a.item < b.item
    end
    return a.quality < b.quality
  end

  local function by_item(list)
    local out = {}
    for _, r in ipairs(list or {}) do
      local name, quality = qkey.qparse(r.item)
      out[#out + 1] = { item = name, quality = quality, qty = r.qty }
    end
    table.sort(out, by_name)
    return out
  end

  local demand = {}
  for _, d in ipairs(world.demand or {}) do
    local name, quality = qkey.qparse(d.item)
    demand[#demand + 1] = { item = name, quality = quality, unmet = d.unmet, priority = d.priority or 0 }
  end
  table.sort(demand, function(a, b)
    if a.priority ~= b.priority then
      return a.priority > b.priority
    end
    if a.unmet ~= b.unmet then
      return a.unmet > b.unmet
    end
    return by_name(a, b)
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

-- Does `manifest` (a `{ [qkey] = qty }` cargo map) carry the bare item NAME
-- `item`? The filter the player types is a bare name, but the manifest is keyed
-- by `qkey(item, quality)`, so a direct `manifest[item]` lookup would miss every
-- quality variant. Decode each key to its name so `iron-plate` matches
-- `iron-plate@normal` (and every other quality of iron-plate). A bare item-name
-- key (legacy) decodes to itself, so old manifests still match.
local function manifest_has(manifest, item)
  if manifest == nil then
    return false
  end
  for key in pairs(manifest) do
    if qkey.qparse(key) == item then
      return true
    end
  end
  return false
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
    -- `w.item` is a cargo qkey; decode to its bare name so a free-text `iron-plate`
    -- filter matches a waiting `iron-plate@normal` row (a bare name decodes to
    -- itself).
    if ok and item and qkey.qparse(w.item) ~= item then
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
-- pure force scoping (the testable seam between gather's stamps and build)
-- ---------------------------------------------------------------------------

-- Keep a row iff it belongs to the viewing force. A row's `force` stamp matching
-- `force_key` is in-scope; a row with a NIL stamp is visible to EVERY viewer --
-- that covers pre-existing saves (fleet/assignment/alert rows created before the
-- stamp existed) so the Monitor never goes mysteriously empty after the upgrade
-- (those rows self-heal as assignments complete and alerts age out of the cap).
local function in_force_scope(row_force, force_key)
  return row_force == nil or row_force == force_key
end

-- Scope a plain gathered `world` to `force_key`, returning a NEW world holding
-- only the rows this force may see (plus nil-stamped rows, visible to all). PURE:
-- plain table in, plain table out, no `storage`/`game` -- so the calc test drives
-- it directly with a hand-built two-force world. A nil `force_key` (no viewing
-- force resolvable) keeps everything, matching the gather-only behavior.
--
-- fleet/assignments are KEYED maps (id -> row), rebuilt by keyed write (order-
-- independent, plain pairs is fine); waiting/alerts are ordered LISTS, rebuilt
-- by ipairs so the gather/build's deterministic order is preserved.
function viewmodel.apply_force_scope(world, force_key)
  world = world or {}
  if force_key == nil then
    return world
  end

  local fleet_out = {}
  for id, e in pairs(world.fleet or {}) do
    if in_force_scope(e.force, force_key) then
      fleet_out[id] = e
    end
  end

  local assignments_out = {}
  for id, a in pairs(world.assignments or {}) do
    if in_force_scope(a.force, force_key) then
      assignments_out[id] = a
    end
  end

  local waiting_out = {}
  for _, w in ipairs(world.waiting or {}) do
    if in_force_scope(w.force, force_key) then
      waiting_out[#waiting_out + 1] = w
    end
  end

  local alerts_out = {}
  for _, al in ipairs(world.alerts or {}) do
    if in_force_scope(al.force, force_key) then
      alerts_out[#alerts_out + 1] = al
    end
  end

  return {
    fleet = fleet_out,
    assignments = assignments_out,
    waiting = waiting_out,
    alerts = alerts_out,
    tick = world.tick,
  }
end

-- ---------------------------------------------------------------------------
-- IO: gather the plain `world` from storage + a fresh dispatcher snapshot
-- (provisional -- engine-touching; verified by manual playtest)
-- ---------------------------------------------------------------------------

local stock = require("scripts.stock")
local reserves = require("scripts.reserves")
local demand = require("scripts.demand")

-- IO (thin, engine-touching; v1.1 Monitor ETA): read a ship's live progress for
-- the pure `remaining_eta`. The watchdog's `sample_flight` already measured the
-- progress-rate (Δdistance/Δtick) and stored it on the `eta_sample` cursor, so we
-- read that STORED rate rather than re-differencing here: the watchdog write and
-- this refresh co-fire on the same tick under the default (equal) cadence, where a
-- live re-difference would have a zero Δtick and yield no rate. The rate is the
-- SAME unit-free measure the sampler/factor use, never `platform.speed`. Returns
-- nil for a parked / un-sampled ship, or one still on its first post-departure
-- interval (no rate measured yet); the current `distance` is read LIVE so the ETA
-- stays fresh between watchdog samples. `remaining` is 0 today (v1 routes are
-- two-stop, the ship is on its only leg). `space_connection` / `.name` /
-- `.distance` are [provisional] seams (docs/api-notes.md §7), playtest-verified.
local function gather_eta_live(entry)
  local p = entry.platform
  if not (p and p.valid) then
    return nil
  end
  local conn = p.space_connection
  if not conn then
    return nil -- parked / between legs: no in-flight ETA
  end
  local s = entry.eta_sample
  -- Need a measured rate on a cursor for the CURRENT connection. The watchdog
  -- clears/replaces the cursor on park or connection change, so a stale cross-leg
  -- rate never leaks through; the pure side still rejects a near-zero rate.
  if not (s and s.connection == conn.name and s.rate) then
    return nil
  end
  return { distance = p.distance or 0, rate = s.rate, remaining = 0, factor = entry.eta_factor or 1.0 }
end

-- IO (thin): the CURRENT live ETA in ticks for ONE ship by id, recomputed from its
-- live progress (distance read now, vs the rate the watchdog stored on the cursor).
-- This is the per-ship value `build` stamps onto a roster row, but callable for a
-- single ship without a full gather -- the Monitor's 1s ETA-only refresh repaints
-- each label with it between full rebuilds. Returns nil on the same gate as
-- gather_eta_live (parked / unsampled / arrived).
function viewmodel.live_eta_ticks(ship_id)
  local entry = ship_id ~= nil and fleet.get(ship_id) or nil
  if not entry then
    return nil
  end
  return viewmodel.remaining_eta(gather_eta_live(entry))
end

-- Snapshot `storage` + a fresh dispatcher snapshot into the plain `world` the
-- pure `build` consumes. Reuses the per-tick stock cache (begin_tick is a no-op
-- if the dispatcher already opened this tick). Only called in-game.
--
-- gather STAMPS a `force` key onto every projected row (fleet entry, assignment,
-- waiting-demand, alert) but does NOT filter -- the pure `apply_force_scope`
-- below does the scoping (the call site composes them:
-- `apply_force_scope(gather(tick), force_key)`).
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

  -- Per-ship readiness verdict from the SAME snapshot build_snapshot already
  -- computed (no third hub read here -- reuse Task 4's stamp). Keyed by fleet id;
  -- only gated ships carry an explicit `false`, so absent/`true` means ready.
  local ready_by_id = {}
  for _, s in ipairs(snapshot.ships or {}) do
    ready_by_id[s.id] = s.ready
  end

  -- fleet roster source (state + assignment only; the rest comes from the
  -- assignment record so the two never disagree).
  local fleet_world = {}
  for id, entry in state.sorted_pairs(storage.fleet or {}) do
    fleet_world[id] = {
      state = entry.state,
      assignment = entry.assignment,
      enrolled = entry.enrolled,
      stranded = entry.stranded, -- watchdog's stuck flag -> summary.ships_stuck
      -- Ready-signal "held" (Task 6): an idle, gated ship whose hub reads
      -- `planet-express-ready <= 0` is held back from dispatch -- a distinct roster
      -- label so it isn't mistaken for a missing ship. Reuses the snapshot's
      -- `ready` verdict (no extra read); display-only (the gate already applied).
      held = entry.require_ready == true and entry.state == fleet.IDLE and ready_by_id[id] == false,
      force = entry.force, -- force stamp (Task 7) for Monitor scoping
      -- Display-only (Monitor roster): the ship's platform name + the planet it is
      -- currently parked at (nil in transit, via the existing space_location seam).
      name = (entry.platform and entry.platform.valid and entry.platform.name) or nil,
      location = dispatcher.ship_planet(entry.platform),
      -- Live in-flight progress-rate fields for the pure ETA (nil unless sampled).
      eta_live = gather_eta_live(entry),
    }
  end

  -- Provider holdings (Monitor display): the GROSS launchable surplus above reserve
  -- at `node_id` for each item in `manifest` -- "what the provider currently holds it
  -- could launch". Read off the EXACT node (a node id), so it is force-correct even
  -- when two forces share a planet name. Deliberately the gross above-reserve count
  -- (same launchable basis as stock.surplus) WITHOUT min-trip suppression or the
  -- in-flight-commit subtraction: the player wants the source's holdings to see WHY a
  -- load is small (the bug-2 lens), not the allocatable remainder. Keyed by the cargo
  -- qkey; the reserve is per bare NAME. Keyed write over the manifest -> plain pairs is
  -- fine. nil when the node isn't in this tick's snapshot (degrade: no readout).
  local function avail_at(node_id, manifest)
    local n = node_id and snapshot.nodes[node_id]
    if not (n and n.node and manifest) then
      return nil
    end
    local out = {}
    for item in pairs(manifest) do
      local nm = qkey.qparse(item)
      local v = stock.stock_count(n.node, item) - reserves.reserve(n.node, nm)
      out[item] = v > 0 and v or 0
    end
    return out
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
      -- The ship's current route stop (1 = source load, 2 = dest turnaround, 3 = source
      -- drop), so group_demand can tell the forward leg from the return leg. nil until
      -- the watchdog's first advance -> group_demand treats it as the forward leg.
      progress_index = a.progress_index,
      deadline_tick = a.deadline_tick,
      force = a.force, -- force stamp (dispatcher.commit) for Monitor scoping
      -- Provider holdings per loaded item (Monitor "from (N avail)"): source for the
      -- FORWARD load, dest for the RETURN load (loaded at the destination turnaround).
      source_avail = avail_at(a.source, a.manifest),
      dest_avail = avail_at(a.dest, a.return_manifest),
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
          -- `d.item` is a cargo qkey; the stock read + committed surplus are
          -- qkey-keyed (per-quality), but the reserve floor is keyed by bare item
          -- NAME (a reserve applies to ALL qualities -- same rule as stock.surplus
          -- / demand.build_open), so decode the qkey before reserves.reserve.
          local sname = qkey.qparse(d.item)
          local com = (committed[sid] and committed[sid][d.item]) or 0
          local raw = stock.stock_count(snode.node, d.item)
            - reserves.reserve(snode.node, sname) - com
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
        force = dnode.force, -- force stamp (build_snapshot) for Monitor scoping
      }
    end
  end

  -- alerts, projected so each carries a top-level `force` stamp (lifted from the
  -- alert detail the watchdog records). build keeps the original shape (kind /
  -- assignment / tick / detail); the extra `force` is read only by the scope step.
  local alerts = {}
  for _, al in ipairs(storage.alerts or {}) do
    alerts[#alerts + 1] = {
      kind = al.kind,
      assignment = al.assignment,
      tick = al.tick,
      detail = al.detail,
      force = al.detail and al.detail.force or nil,
    }
  end

  return {
    fleet = fleet_world,
    assignments = assignments_world,
    waiting = waiting,
    alerts = alerts,
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
