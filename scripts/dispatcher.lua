-- scripts/dispatcher.lua
--
-- The matching loop: on the dispatcher tick, join open demand with
-- above-reserve supply across the registry, pick a source +
-- an idle eligible ship, write a two-planet route, and record two-sided
-- bookkeeping so nothing is double-claimed or double-dispatched.
--
-- Sourcing is PRODUCTION-AGNOSTIC (re-export allowed): any planet holding
-- above-reserve surplus of an item is a candidate, whether it produces the item
-- or merely received it. The single guard that keeps that safe is `exportable`
-- (below): a planet is never a source for an item it currently has open (unmet)
-- demand for -- this prevents a planet importing and exporting the same item.
--
-- Design split (per the plan's pure-function seam):
--   * `exportable`, `best_source`, `pick_ship`, and the whole `plan` planner are
--     PURE over a plain SNAPSHOT table -- no engine globals, no `storage` -- so
--     they load and run under plain `lua` and are unit-tested.
--   * `build_snapshot` / `commit` / `run` are the thin IO layer: they read the
--     engine via the IO wrappers, allocate ids from the monotonic counter,
--     write `storage.assignments`, and call the schedule writer. Verified by
--     manual playtest (watch a delivery with the debug log on).
--
-- Two-sided bookkeeping (the second robustness invariant):
--   * demand side: `inbound_commit` -- read back by `demand.inbound_for` so an
--     in-flight delivery isn't requested again on the next tick.
--   * supply side: `surplus_commit` -- read back by `committed_surplus_by_node`
--     so a source isn't drained twice while its rockets are still launching.
--   * WITHIN a single tick, `plan` decrements the working surplus snapshot as it
--     commits each assignment, so two demands can't claim the same surplus.

local state = require("scripts.state")
local stock = require("scripts.stock")
local demand = require("scripts.demand")
local fleet = require("scripts.fleet")
local schedule = require("scripts.schedule")
local registry = require("scripts.registry")
local watchdog = require("scripts.watchdog")
local qkey = require("scripts.qkey")

local dispatcher = {}

-- Dispatcher cadence + wait-condition timeout, in ticks. INTERVAL is the
-- fallback when the runtime setting is absent (e.g. the pure-Lua test runner);
-- `dispatcher.interval()` reads the real value and control.lua re-registers the
-- on_nth_tick handler when the setting changes. Kept here so the timer/timeout
-- seams are greppable.
dispatcher.INTERVAL = 300       -- 5s at 60 UPS
dispatcher.INTERVAL_SETTING = "planet-express-dispatch-interval"
dispatcher.TIMEOUT = 18000      -- 5 min: every wait-condition has a timeout (invariant #1)

-- No-progress watchdog window: the watchdog frees a ship that makes NO
-- schedule progress for this long. It must EXCEED one leg's travel + a stop's
-- wait, because `schedule.current` only advances at a stop boundary (it is the
-- index of the current DESTINATION, not an arrival flag), so a long inter-planet
-- leg shows no progress mid-travel and must not be mistaken for a stuck ship.
-- Sized as the per-stop wait timeout + a 1x travel budget; tune the budget to the
-- longest route in playtest. (The wait-condition timeout itself stays `TIMEOUT`.)
dispatcher.NO_PROGRESS_WINDOW = 2 * dispatcher.TIMEOUT

-- Max concurrent ships. `0` means UNLIMITED for both. The global cap
-- bounds the whole fleet's simultaneous assignments; the per-route cap bounds
-- ships in flight between a single source->dest pair. Both are enforced in the
-- pure `plan` (over snapshot fields), so they are unit-tested.
dispatcher.MAX_GLOBAL_SETTING = "planet-express-max-ships-global"
dispatcher.MAX_ROUTE_SETTING = "planet-express-max-ships-route"

-- Two-way return trade. When enabled, a finalized forward assignment
-- also picks up a RETURN leg at the destination if the destination has surplus
-- the source still needs (same two planets). TWO_WAY_DEFAULT is the fallback when
-- `settings` is absent (the pure-Lua test runner); the planner reads the resolved
-- flag off the snapshot (set by build_snapshot) so `plan` stays pure/deterministic.
dispatcher.TWO_WAY_SETTING = "planet-express-two-way-return"
dispatcher.TWO_WAY_DEFAULT = true

-- Minimum-load gate (v1.8.0). A percent int 0..100: a ship is only dispatched in
-- Pass 1 when its manifest fills at least this fraction of its slot budget
-- (`0` disables the gate -> ship any load). Read here, converted to a 0..1
-- fraction on the snapshot (`min_load_fraction`) so the pure two-pass planner
-- gates without touching `settings`. MIN_LOAD_DEFAULT is the fallback when
-- `settings` is absent (the pure-Lua test runner); 80% mirrors settings.lua.
dispatcher.MIN_LOAD_SETTING = "planet-express-min-load"
dispatcher.MIN_LOAD_DEFAULT = 80

-- [provisional] Per-platform cargo capacity is now a SLOT BUDGET (the hub's
-- main-inventory slot count), NOT an item count -- the slot-aware manifest packer
-- fills this many slots. DEFAULT_CAPACITY is the fallback slot count used
-- when the hub inventory can't be read (degrade safely). DEFAULT_STACK_SIZE is the
-- fallback per-item stack size used when a prototype is unavailable (e.g. the
-- pure-Lua test runner, which has no `prototypes` global). Confirm both in-engine
-- accessors before flipping the api-notes seams to [confirmed].
dispatcher.DEFAULT_CAPACITY = 80
dispatcher.DEFAULT_STACK_SIZE = 50

-- ---------------------------------------------------------------------------
-- pure thrash guard
-- ---------------------------------------------------------------------------

-- The re-export / thrash guard, the dispatcher's join point. A node's surplus of
-- `item` is exportable ONLY when the node has no open demand for that same item;
-- otherwise it would import and export `item` at once (ships passing each other).
-- `stock.surplus` stays pure stock math -- the demand-awareness lives
-- HERE. Pure over a node snapshot { surplus = {}, unmet_by_item = {} }.
--
-- QUALITY: `item` is a `qkey(item, quality)` and both `surplus`
-- and `unmet_by_item` are keyed by qkey, so the guard is PER (item, quality):
-- a node importing normal-quality iron can still export its uncommon-quality iron
-- (a different cargo key), and surplus of one quality never masks demand for
-- another. The keys are opaque strings here, so the guard logic is unchanged.
function dispatcher.exportable(node, item)
  if not node then
    return 0
  end
  -- A planet physically SHORT of an item it requests is NEVER a source for it --
  -- even when an in-flight delivery has already netted its `unmet` to 0, it still
  -- HOLDS less than it asked for, so exporting would strip stock it is itself
  -- waiting on (the ship then parks where nothing launches and times out). The
  -- gross-import map is inbound-independent (`max(0, requested - on_hand)`), so it
  -- stays positive while the planet is short -- unlike `unmet_by_item`, which inbound
  -- netting drives to 0. Checked FIRST: gross shortfall >= netted unmet pointwise, so
  -- this subsumes the unmet test, but both are kept for clarity. See demand.import_map.
  local short = node.import_by_item and node.import_by_item[item] or 0
  if short > 0 then
    return 0
  end
  local unmet = node.unmet_by_item and node.unmet_by_item[item] or 0
  if unmet > 0 then
    return 0
  end
  return (node.surplus and node.surplus[item]) or 0
end

-- Net above-reserve surplus after the supply-side committed bookkeeping is
-- subtracted, re-clamped against min-trip. `stock.surplus` already applies the
-- min-trip floor to the pre-committed (stock - reserve) value, but the NET value
-- (raw minus what's already in flight) can fall back below min-trip -- e.g. raw
-- 100 passes min-trip 50, minus committed 60 leaves 40, a below-threshold dribble
-- that shouldn't be dispatched. Re-applying min-trip to the smaller net value
-- suppresses it. Pure (plain numbers in/out): unit-tested. `committed` nil ⇒ 0.
function dispatcher.net_surplus(raw, committed, min_trip)
  local net = (raw or 0) - (committed or 0)
  if net < min_trip then
    return 0
  end
  return net
end

-- ---------------------------------------------------------------------------
-- pure concurrency accounting (max-ships caps)
-- ---------------------------------------------------------------------------

-- Canonical key for a route (source node id -> dest node id). Used both to count
-- in-flight assignments per route and to enforce the per-route cap. Stable string
-- so iteration/comparison is deterministic.
function dispatcher.route_key(source_id, dest_id)
  return tostring(source_id) .. "|" .. tostring(dest_id)
end

-- Count in-flight assignments globally and per route from a plain assignments
-- table. Pure (iterates via the sorted helper for determinism). Returns
-- (global_count, { [route_key] = count }).
function dispatcher.active_counts(assignments)
  local total = 0
  local by_route = {}
  for _, a in state.sorted_pairs(assignments or {}) do
    total = total + 1
    local key = dispatcher.route_key(a.source, a.dest)
    by_route[key] = (by_route[key] or 0) + 1
  end
  return total, by_route
end

-- ---------------------------------------------------------------------------
-- distance map (foundation for ETA-aware dispatch, v1.1)
-- ---------------------------------------------------------------------------

-- The large fallback returned for a missing pair / nil planet. Any lookup that
-- can't resolve to a real connection length is DEPRIORITIZED (sorted last), never
-- an index error -- an enrolled ship in transit has a nil `space_location`, and a
-- node whose surface was deleted has a nil planet, so both keys are nil-tolerant.
-- Kept well above any real `length` (km) so a genuine route always beats it.
dispatcher.DISTANCE_FALLBACK = 1e9

-- In-memory symmetric distance map `dist[a][b] = length` (km), rebuilt from
-- `prototypes.space_connection` on load (NOT a `storage` copy -- it is derived
-- static prototype data, so it is reconstructed deterministically rather than
-- serialized into the save). nil until the first build.
local distance_map = nil

-- A SpaceLocationID is recorded as a name string, but stay robust if the runtime
-- hands back the prototype object instead (provisional seam) -- pull `.name` off a
-- table, pass a string through.
local function loc_name(x)
  if type(x) == "table" then
    return x.name
  end
  return x
end

-- IO (thin, engine-touching): iterate the connection prototype universe into a
-- symmetric `dist[a][b] = dist[b][a] = length` map and cache it at module scope.
-- Rebuilt on `on_init` / `on_configuration_changed` / `on_load` from control.lua
-- (`prototypes` is readable in `on_load`). Degrades to an empty map when
-- `prototypes` is absent (the pure-Lua test runner). Returns the map.
function dispatcher.build_distances()
  local map = {}
  if prototypes and prototypes.space_connection then
    for _, conn in pairs(prototypes.space_connection) do
      local a = loc_name(conn.from)
      local b = loc_name(conn.to)
      local length = conn.length
      if a and b and length then
        map[a] = map[a] or {}
        map[b] = map[b] or {}
        map[a][b] = length
        map[b][a] = length
      end
    end
  end
  distance_map = map
  return map
end

-- Accessor for the cached distance map (lazily builds it on first read so a stray
-- call before the load hook still gets a real map, not nil).
function dispatcher.distances()
  if distance_map == nil then
    dispatcher.build_distances()
  end
  return distance_map
end

-- PURE inter-planet distance lookup over a passed-in map (`snapshot.distances`),
-- used as the ETA-routing distance and the source nearest tie-break. Nil-guards
-- BOTH keys and a missing pair, returning the large fallback (never a nil[...]
-- index error). Self-distance is 0 (a ship parked at the source deadheads 0).
-- All call sites MUST go through here -- never raw `map[a][b]`.
function dispatcher.distance(map, a, b)
  if a == nil or b == nil then
    return dispatcher.DISTANCE_FALLBACK
  end
  if a == b then
    return 0
  end
  local row = map and map[a]
  local d = row and row[b]
  if d == nil then
    return dispatcher.DISTANCE_FALLBACK
  end
  return d
end

-- ---------------------------------------------------------------------------
-- pure ETA scorer (v1.1) -- distance + per-ship factor -> ETA in ticks
-- ---------------------------------------------------------------------------

-- Baseline space speed in km/tick. The per-ship `eta_factor` absorbs the real
-- baseline and units (`eta = predicted * factor`, factor ~= NOMINAL_SPEED /
-- real_speed), so any consistent value works; this is picked so a first-trip
-- (factor 1.0) ETA is roughly right, then tuned empirically in-engine. Kept > 0.
dispatcher.NOMINAL_SPEED = 0.1

-- PURE: nominal travel time (ticks) for a raw distance (km), before the per-ship
-- factor. A fallback distance (DISTANCE_FALLBACK) yields a huge time, so an
-- unresolved route is naturally deprioritized by any min-ETA comparison.
function dispatcher.predicted_ticks(dist)
  return (dist or 0) / dispatcher.NOMINAL_SPEED
end

-- PURE: the ETA (ticks) for sending a ship across `deadhead` (its parked planet
-- to the source) then `route` (source to dest), scaled by the ship's learned
-- `factor` (default 1.0). Monotonic in distance and in factor, so min-ETA
-- selection orders ships correctly. A nil factor reads as 1.0.
function dispatcher.eta(deadhead, route, factor)
  return dispatcher.predicted_ticks((deadhead or 0) + (route or 0)) * (factor or 1.0)
end

-- ---------------------------------------------------------------------------
-- pure force isolation (forces don't share logistics)
-- ---------------------------------------------------------------------------

-- [provisional] A stable per-force identifier. Sources, destinations, and ships
-- are matched only WITHIN a force (forces have separate logistic networks and
-- platforms), and the stock cache keys on it too. Confirm `force.index` is the
-- stable 2.0 accessor; falls back to the force name. nil-tolerant.
function dispatcher.force_key(force)
  if not force then
    return nil
  end
  return force.index or force.name
end

-- Ships belonging to `force` (a nil force matches nil-force ships). A ship only
-- flies routes for its own force. Pure over the ship list.
function dispatcher.ships_for_force(ships, force)
  local out = {}
  for _, s in ipairs(ships or {}) do
    if s.force == force then
      out[#out + 1] = s
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- pure within-tick demand netting (mirror of demand.inbound_for)
-- ---------------------------------------------------------------------------

-- Credit a node for cargo committed TO it this tick, so a later destination in
-- the SAME tick can't re-ship what is already on its way. This mirrors
-- `demand.inbound_for` (the cross-tick read), applied to the working snapshot:
--   * forward leg: the DEST node is credited by `manifest` (node as destination),
--   * return leg: the SOURCE node is credited by `return_manifest` (node as the
--     return destination).
-- For each `(item, qty)` it decrements the node's `unmet_by_item[item]` (clamp at
-- 0, REMOVE the key at 0 so `exportable`'s `unmet > 0` test matches next-tick
-- semantics) and the matching `demand` row (`d.unmet = max(0, d.unmet - qty)`).
--
-- Composition side effect (the thrash-guard re-open hole): when an item's
-- `unmet_by_item` reaches 0, the node's working `surplus[item]` is zeroed too --
-- otherwise `exportable(node, item)` (which returns surplus ONLY when unmet == 0)
-- would RE-OPEN for the rest of the tick and let a later destination export the
-- very item this node just received (ships passing each other). The zeroing is
-- keyed strictly off unmet reaching 0; it does NOT subtract the manifest from
-- surplus (the forward leg already drains the SOURCE's surplus in `plan`, and the
-- return leg drains the DEST's surplus there), so it never double-applies over
-- those existing drains. Pure over the node snapshot.
local function credit_inbound(node, commit)
  if not (node and commit) then
    return
  end
  for item, qty in pairs(commit) do
    if qty and qty > 0 then
      if node.unmet_by_item then
        local left = (node.unmet_by_item[item] or 0) - qty
        if left > 0 then
          node.unmet_by_item[item] = left
        else
          node.unmet_by_item[item] = nil
          -- unmet hit 0: an item delivered here this tick is never a sane export
          -- source from here this tick -- zero its working surplus so the thrash
          -- guard stays closed for the rest of the tick.
          if node.surplus then
            node.surplus[item] = nil
          end
        end
      end
      if node.demand then
        for _, d in ipairs(node.demand) do
          if d.item == item then
            local u = (d.unmet or 0) - qty
            d.unmet = u > 0 and u or 0
          end
        end
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- pure best-source selection
-- ---------------------------------------------------------------------------

-- Pick the source for `dest`'s open demand, by the dest force's source strategy
-- (carried on `dest.strategy`, the Monitor "Source" toggle):
--   * FASTEST (default): the source that COVERS the most of the request in one stop
--     -- coverage = sum of min(exportable, unmet) -- so wide-load potential drives it.
--   * MOST_SURPLUS: the source holding the most TOTAL exportable surplus of the
--     requested items -- surplus_total = sum of exportable(source, item), uncapped by
--     unmet -- so the trade is pulled off the biggest relevant stockpile.
-- BOTH break ties NEAREST, then lowest node id (deterministic). A candidate must still
-- COVER something (coverage > 0) to qualify; since both sums range over the demanded
-- items via the guarded `exportable`, surplus_total > 0 <=> coverage > 0, so a
-- most-surplus pick can always actually serve the request. Only SAME-FORCE sources
-- (force isolation). Returns { id, planet, coverage, surplus_total, dist } or nil. Pure
-- over the snapshot; iterates node ids in stable order. A nil/absent `dest.strategy`
-- resolves to FASTEST, so snapshots without the field behave exactly as before.
function dispatcher.best_source(snapshot, dest)
  local by_surplus = dest.strategy == state.SOURCE_SURPLUS
  local best = nil
  for _, sid in ipairs(state.sorted_keys(snapshot.nodes)) do
    local source = snapshot.nodes[sid]
    if sid ~= dest.id and source.force == dest.force then
      local coverage = 0
      local surplus_total = 0
      for _, d in ipairs(dest.demand) do
        local avail = dispatcher.exportable(source, d.item)
        if avail > 0 then
          coverage = coverage + (avail < d.unmet and avail or d.unmet)
          surplus_total = surplus_total + avail
        end
      end
      if coverage > 0 then
        -- nearest tie-break over the GUARDED helper (never raw `distances[a][b]`):
        -- equally-ranked sources break toward the shorter route, then lowest id.
        local dist = dispatcher.distance(snapshot.distances, source.planet, dest.planet)
        local score = by_surplus and surplus_total or coverage
        local best_score = best and (by_surplus and best.surplus_total or best.coverage)
        -- strict comparisons + stable id iteration => lowest id wins full ties.
        if best == nil
          or score > best_score
          or (score == best_score and dist < best.dist) then
          best = { id = sid, planet = source.planet, coverage = coverage,
            surplus_total = surplus_total, dist = dist }
        end
      end
    end
  end
  return best
end

-- Pure: does node `source_id` hold ANY exportable surplus for an item node
-- `dest_id` still demands? The reciprocity test for direction-aware routing:
-- `covers(snapshot, dest_id, src_id)` true means the dest could itself act as a
-- source for the src, so the trade is reciprocal and the route may be flipped to
-- start at whichever planet an idle ship sits on. Pure over the snapshot.
function dispatcher.covers(snapshot, source_id, dest_id)
  local source = snapshot.nodes and snapshot.nodes[source_id]
  local dest = snapshot.nodes and snapshot.nodes[dest_id]
  if not (source and dest and dest.demand) then
    return false
  end
  for _, d in ipairs(dest.demand) do
    if dispatcher.exportable(source, d.item) > 0 then
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- pure ship selection
-- ---------------------------------------------------------------------------

-- Choose an idle eligible ship for the route source_planet -> dest_planet. A
-- manual `pin` (a fleet key set on the Trade tab) overrides auto-pick
-- when that ship is free and eligible; otherwise auto-pick selects the ship that
-- DELIVERS SOONEST (min ETA, v1.1): `eta(deadhead, route, factor)` where
-- `deadhead = distance(ship.planet -> source)`, `route = distance(source -> dest)`,
-- and `factor = ship.eta_factor` (its learned calibration, default 1.0). Lowest id
-- breaks an exact ETA tie (deterministic). Returns the ship entry from `ships` or
-- nil (caller then lets the demand wait for the next tick).
--
-- All distance reads go through the nil-guarded `dispatcher.distance` helper, so a
-- ship with no `planet` (in transit, or the test runner) deadheads the large
-- fallback and a parked-at-source ship deadheads 0 (self-distance) -- the latter
-- preserves the old no-deadhead preference for free, since 0 < any real/fallback
-- distance. With no `distances` map at all, every real pair falls to the fallback
-- so equal-factor ships tie and the lowest id wins (matches the old lowest-id pick).
--
-- `ships` is a list of { id, entry, capacity, planet, eta_factor }; `used` is a set
-- of ship ids already committed this tick; `distances` is `snapshot.distances`.
function dispatcher.pick_ship(ships, used, source_planet, dest_planet, pin, distances)
  local function eligible(s)
    -- `s.ready ~= false` is the ready-signal gate: build_snapshot stamps
    -- `false` only when a gated ship's hub reads `planet-express-ready <= 0`.
    -- Absent / `true` (un-gated or satisfied) stays eligible, so pure tests with
    -- no `ready` field are unaffected.
    return not used[s.id] and s.ready ~= false
      and fleet.idle_eligible(s.entry, source_planet, dest_planet)
  end

  if pin ~= nil then
    for _, s in ipairs(ships) do
      if s.id == pin and eligible(s) then
        return s
      end
    end
  end

  -- Min-ETA pick: the route leg is shared by every candidate; only the deadhead
  -- and the per-ship factor vary. Lowest id breaks an exact tie (stable).
  local route = dispatcher.distance(distances, source_planet, dest_planet)
  local best, best_eta = nil, nil
  for _, s in ipairs(ships) do
    if eligible(s) then
      local deadhead = dispatcher.distance(distances, s.planet, source_planet)
      local eta = dispatcher.eta(deadhead, route, s.eta_factor)
      if best == nil or eta < best_eta or (eta == best_eta and s.id < best.id) then
        best, best_eta = s, eta
      end
    end
  end
  return best
end

-- ---------------------------------------------------------------------------
-- pure return-leg selection (two-way trade)
-- ---------------------------------------------------------------------------

-- Build the return-leg manifest for a forward plan: on the way back, the
-- DESTINATION (acting as a return SOURCE) ships items the SOURCE (the return
-- DESTINATION) still has open demand for, loaded WIDE up to ship capacity in the
-- source's priority order. Pure over the snapshot.
--
-- The return leg sources EXCLUSIVELY through the same `exportable(...)` thrash
-- guard as the forward leg (no separate, unguarded path): a destination is never
-- a return source for an item it still has open demand for. "Below min-trip" and
-- "already inbound" fall out for free -- min-trip suppression already lives in
-- the snapshot's `surplus`, and the source's `demand` is already netted against
-- in-flight inbound by `demand.open_demand` upstream.
--
-- Returns { [item] = qty } (empty when no reciprocal trade exists). The route
-- stays within the SAME TWO PLANETS (no third planet in v1).
function dispatcher.return_manifest(snapshot, source_id, dest_id, capacity)
  local return_dest = snapshot.nodes[source_id]   -- the source planet (needs items back)
  local return_src = snapshot.nodes[dest_id]       -- the dest planet (offers surplus back)
  if not (return_dest and return_src and return_dest.demand) then
    return {}
  end

  local items = {}
  for _, d in ipairs(return_dest.demand) do
    local avail = dispatcher.exportable(return_src, d.item)
    if avail > 0 then
      -- carry stack_size + perishable through (set by build_snapshot) so the
      -- slot-aware packer sizes the return cargo and perishable_filter can isolate
      -- perishables on the return leg too; `capacity` here is the ship's slot budget.
      items[#items + 1] = { item = d.item, surplus = avail, unmet = d.unmet,
        stack_size = d.stack_size, perishable = d.perishable }
    end
  end

  -- Isolate perishables on the return leg too (same load-time rationale as the
  -- forward leg) -- see dispatcher.perishable_filter.
  return schedule.build_manifest(dispatcher.perishable_filter(items), capacity)
end

-- ---------------------------------------------------------------------------
-- pure planner
-- ---------------------------------------------------------------------------

-- Pure: ISOLATE perishables onto their own trip. If ANY candidate item is
-- perishable, return ONLY the perishable items; otherwise return the list
-- unchanged. The source stop's load-wait is an AND of every manifest item's
-- `item_count` (schedule.load_wait), so a perishable bundled with slow bulk cargo
-- rides the 300s timeout -- spoiling aboard -- until that bulk finishes loading.
-- Loading the perishables ALONE makes the wait gate on the fast perishables, so the
-- ship departs the moment they are aboard (the timeout stays only as the invariant-#1
-- backstop; we just stop perishables from hitting it). `items` is ALREADY scoped to
-- what the chosen source can EXPORT (callers filter by exportable surplus first), so a
-- source that can't supply the perishable simply has none in `items` and ships its
-- normal load -- the perishable then waits for a tick whose chosen source bears it,
-- and is never starved. Order-preserving (keeps the caller's priority order). Pure
-- over the items list -- the `perishable` flag is tagged in build_snapshot.
function dispatcher.perishable_filter(items)
  local any = false
  for _, it in ipairs(items) do
    if it.perishable then
      any = true
      break
    end
  end
  if not any then
    return items
  end
  local out = {}
  for _, it in ipairs(items) do
    if it.perishable then
      out[#out + 1] = it
    end
  end
  return out
end

-- Plan this tick's assignments over a plain SNAPSHOT, deterministically and with
-- no IO. Iterates destinations in stable id order; each destination's demand is
-- already priority-sorted. For each destination with open demand:
--   1. pick the best source via `best_source` (production-agnostic, guarded),
--   2. pick an idle eligible ship via `pick_ship` (else the demand waits),
--   3. load WIDE up to ship capacity via `schedule.build_manifest`,
--   4. record the plan and DECREMENT the source's working surplus + mark the ship
--      used, so later destinations this tick can't double-claim either.
--   5. when two-way trade is enabled (`snapshot.two_way`), also pick a RETURN leg
--      via `return_manifest` and DECREMENT the destination's working surplus too.
--
-- Every cargo key below (`demand[i].item`, the `surplus`/`unmet_by_item` keys,
-- and the manifest keys) is a `qkey(item, quality)`: a single item
-- at two qualities is two independent cargo keys that match, source, load, and
-- net out separately. The keys are opaque strings, so coverage, the surplus
-- decrement, and the caps all carry quality through with no structural change.
--
-- snapshot = {
--   two_way = bool,  -- two-way gate (set by build_snapshot from the setting)
--   nodes = { [node_id] = { id, planet, demand = {{item,unmet,priority,stack_size},...},
--                           surplus = { [qkey]=qty },        -- working (mutated)
--                           unmet_by_item = { [qkey]=qty },  -- netted demand
--                           import_by_item = { [qkey]=qty },  -- gross shortfall (export guard)
--                           pin = <fleet key>|nil } },       -- Trade-tab "Preferred ship"
--   ships = { { id, entry, capacity, planet }, ... },  -- planet: where the ship
--                           is parked now (nil in transit), for no-deadhead pick
-- }
--
-- Returns a list of plans: { source_id, source_planet, dest_id, dest_planet,
--   ship_id, ship, manifest = {[qkey]=qty}, items = {{item=qkey,surplus,unmet,
--   stack_size},...}, return_manifest = {[qkey]=qty}|nil }.

-- Pure destination-ordering comparator (anti-starvation aging clock).
--
-- Returns the list of node ids sorted by (last_served ASC, id ASC): the node
-- that has waited longest since it was last served wins the contested ship pick
-- first; ties break by node id for a total deterministic order (multiplayer +
-- save/load safe). `last_served` is `node.last_served_tick` copied onto the
-- snapshot node by `build_snapshot` -- `nil` for a never-served node.
--
-- CRITICAL: coerce `nil` to a sentinel STRICTLY LESS THAN ANY REAL TICK before
-- the `<` so `table.sort` never compares `nil` with a number (which crashes the
-- dispatcher tick -- the normal state is a mix of served + never-served nodes).
-- Use -1, NOT 0: tick 0 is a valid game tick, so a never-served node must sort
-- ahead of a node served at tick 0. A never-served node is "infinitely old"
-- (waiting since map start) and fairly sorts first.
--
-- Pure: no engine globals, no `storage`. (`state.sorted_keys` stays the order
-- for order-independent loops elsewhere; this is the decision order for the
-- destination loop only.)
function dispatcher.dest_order(nodes)
  local ids = {}
  for id in pairs(nodes) do
    ids[#ids + 1] = id
  end
  table.sort(ids, function(a_id, b_id)
    local ta = nodes[a_id].last_served or -1
    local tb = nodes[b_id].last_served or -1
    if ta ~= tb then return ta < tb end   -- oldest (incl. nil) first
    return a_id < b_id                     -- integer-id tiebreak -> total order
  end)
  return ids
end

function dispatcher.plan(snapshot)
  local plans = {}
  local used = {}
  local two_way = snapshot.two_way == true

  -- Max-concurrent-ships caps. 0 == unlimited. `active_*` are the
  -- in-flight counts from storage (set by build_snapshot); we add this tick's
  -- commitments as we go so a single tick can't blow past the cap either.
  -- Absent fields default to unlimited, so existing tests are unaffected.
  local max_global = snapshot.max_ships_global or 0
  local max_route = snapshot.max_ships_route or 0
  local active_global = snapshot.active_global or 0
  local active_by_route = snapshot.active_by_route or {}
  local committed_global = 0
  local committed_by_route = {}

  -- Destinations committed this tick (Pass 1 or Pass 2). Guards Pass 2 so a
  -- destination already served isn't reconsidered.
  local committed_dest = {}

  -- Per-destination "compute candidate + maybe commit" body, run in two passes
  -- with different `min_fill` thresholds over the SAME aging order. Shared state
  -- (used, committed_global, committed_by_route, committed_dest, plans) is
  -- captured so the concurrency caps hold across the WHOLE tick, not per pass.
  --
  -- INVARIANT: best_source / items / manifest / fill are recomputed fresh on
  -- every call -- NEVER cached across passes -- so Pass 2 observes Pass 1's
  -- surplus drains and inbound credits. Do not "optimize" by caching the Pass-1
  -- manifest: a dest deferred in Pass 1 must see the up-to-date working surplus
  -- when reconsidered in Pass 2.
  local function try_plan_dest(dest_id, min_fill, pass)
    local dest = snapshot.nodes[dest_id]
    if dest.demand and #dest.demand > 0 then
      local src = dispatcher.best_source(snapshot, dest)
      if src then
        -- only this force's ships may fly the route (force isolation)
        local route_ships = dispatcher.ships_for_force(snapshot.ships, dest.force)
        local ship = dispatcher.pick_ship(route_ships, used, src.planet, dest.planet, dest.pin, snapshot.distances)

        -- Direction-aware (ETA-gated) routing. best_source + the iteration order
        -- pick src->dest, and the forward pick may fly to the SOURCE first. If the
        -- trade is RECIPROCAL (the dest holds exportable surplus the source demands),
        -- consider FLIPPING the route to start at a ship PARKED AT THE DEST: same two
        -- planets, same goods, reversed leg order -- the first leg then carries cargo
        -- from the dest instead of the chosen ship deadheading to the source. Under
        -- min-ETA the forward pick may DELIBERATELY take a far-but-fast ship, so the
        -- flip must not override it blindly: take the flip ONLY when the best at-dest
        -- ship's reverse ETA beats the forward ETA. A node pin forces a specific ship,
        -- so never flip under a pin. The flip keeps within-tick bookkeeping correct:
        -- it just relabels source vs dest.
        local s_id, s_planet, d_id, d_planet = src.id, src.planet, dest_id, dest.planet
        if ship and dest.pin == nil and dispatcher.covers(snapshot, dest_id, src.id) then
          -- The flip relabels the route to START at the dest, so the chosen ship
          -- loads there immediately instead of the forward pick deadheading to the
          -- source. Only a ship genuinely PARKED AT the dest can do that, so pick
          -- the reverse-leg ship from the AT-DEST SUBSET. Picking the GLOBAL
          -- reverse-min (over all ships) and then rejecting it when it isn't at the
          -- dest would wrongly veto a beneficial flip: a far-but-fast ship can win
          -- the global reverse pick yet not be parked at the dest, leaving a
          -- slightly-slower at-dest ship -- whose reverse ETA still beats the
          -- forward ETA -- never even compared. Among at-dest ships the deadhead is
          -- 0, so `pick_ship` reduces to lowest factor then lowest id.
          local at_dest_ships = {}
          for _, s in ipairs(route_ships) do
            if s.planet == dest.planet then
              at_dest_ships[#at_dest_ships + 1] = s
            end
          end
          local at_dest = dispatcher.pick_ship(at_dest_ships, used, dest.planet, src.planet, nil, snapshot.distances)
          if at_dest then
            -- forward: the chosen ship deadheads to the source, then runs src->dest.
            local fwd_eta = dispatcher.eta(
              dispatcher.distance(snapshot.distances, ship.planet, src.planet),
              dispatcher.distance(snapshot.distances, src.planet, dest.planet),
              ship.eta_factor)
            -- reverse: the at-dest ship loads immediately, then runs dest->src.
            local rev_eta = dispatcher.eta(
              dispatcher.distance(snapshot.distances, at_dest.planet, dest.planet),
              dispatcher.distance(snapshot.distances, dest.planet, src.planet),
              at_dest.eta_factor)
            if rev_eta < fwd_eta then
              ship = at_dest
              s_id, s_planet, d_id, d_planet = dest_id, dest.planet, src.id, src.planet
            end
          end
        end

        if ship then
          local source = snapshot.nodes[s_id]
          local dnode = snapshot.nodes[d_id]
          -- candidate items in the (chosen-direction) destination's priority order,
          -- each capped by the source's guarded exportable surplus.
          local items = {}
          for _, d in ipairs(dnode.demand) do
            local avail = dispatcher.exportable(source, d.item)
            if avail > 0 then
              -- carry stack_size + perishable through (set by build_snapshot) so the
              -- slot-aware packer sizes each item and perishable_filter can isolate
              -- perishables; `capacity` here is the ship's slot budget.
              items[#items + 1] = { item = d.item, surplus = avail, unmet = d.unmet,
                stack_size = d.stack_size, perishable = d.perishable }
            end
          end
          -- Isolate perishables onto their own fast trip BEFORE packing, so they
          -- don't ride the 300s load-wait beside slow bulk cargo and spoil aboard.
          -- Reassigned in place so the stored plan `items` (re-packed by
          -- schedule.build_records at write time) matches this manifest exactly.
          items = dispatcher.perishable_filter(items)

          local manifest = schedule.build_manifest(items, ship.capacity)
          local rkey = dispatcher.route_key(s_id, d_id)
          local within_global = (max_global <= 0)
            or (active_global + committed_global < max_global)
          local within_route = (max_route <= 0)
            or ((active_by_route[rkey] or 0) + (committed_by_route[rkey] or 0) < max_route)
          -- Min-load gate input. `fill` = used slots / ship slot budget; a trip is
          -- exempt when it carries any perishable (isolated to its own fast trip by
          -- perishable_filter -- it must not wait to batch or it rots). Compute fill
          -- ONLY when the manifest is non-empty: build_manifest returns {} for a
          -- 0-capacity ship, and `next(manifest) ~= nil` (kept FIRST in the guard's
          -- `and` chain) short-circuits before the `slots / ship.capacity` division.
          local perishable_trip = false
          for _, it in ipairs(items) do
            if it.perishable then perishable_trip = true break end
          end
          local fill = 0
          if next(manifest) ~= nil then
            fill = schedule.manifest_slots(manifest, items) / ship.capacity
          end
          if next(manifest) ~= nil and within_global and within_route
            and (fill >= min_fill or perishable_trip) then
            used[ship.id] = true
            committed_dest[dest_id] = true
            committed_global = committed_global + 1
            committed_by_route[rkey] = (committed_by_route[rkey] or 0) + 1
            -- supply-side within-tick bookkeeping: drain the working surplus so
            -- the next destination sees only what is genuinely left.
            for item, qty in pairs(manifest) do
              source.surplus[item] = (source.surplus[item] or 0) - qty
            end
            -- demand-side within-tick bookkeeping (mirror of demand.inbound_for):
            -- credit the DEST node for the forward manifest so a later
            -- destination this tick can't re-ship what's already inbound here, and
            -- (when its unmet hits 0) close the export-re-open hole on that item.
            credit_inbound(dnode, manifest)

            -- Two-way return leg: the empty ship loads wide at the destination
            -- on its way home with whatever the source still needs. Same guard,
            -- same two planets. Drain the destination's working surplus too so a
            -- later destination this tick can't double-claim it.
            local return_manifest = nil
            if two_way then
              local ret = dispatcher.return_manifest(snapshot, s_id, d_id, ship.capacity)
              if next(ret) ~= nil then
                for item, qty in pairs(ret) do
                  dnode.surplus[item] = (dnode.surplus[item] or 0) - qty
                end
                -- demand-side bookkeeping for the return leg (mirror of
                -- demand.inbound_for): the return cargo is delivered to the SOURCE
                -- node, so credit IT -- a later destination this tick reading the
                -- source's un-netted demand would otherwise ship the same item to
                -- it again (the reachable 3-node double-serve).
                credit_inbound(source, ret)
                return_manifest = ret
              end
            end

            plans[#plans + 1] = {
              source_id = s_id,
              source_planet = s_planet,
              dest_id = d_id,
              dest_planet = d_planet,
              -- The DEST node's force key, carried onto the assignment in commit so
              -- the Monitor can scope the shipment to the receiving force.
              dest_force = dnode.force,
              ship_id = ship.id,
              ship = ship,
              manifest = manifest,
              items = items,
              return_manifest = return_manifest,
              -- Debug-log breadcrumbs (rendered by commit): which pass committed
              -- this route, and the dest's aging clock (last_served tick, nil =
              -- never served). commit computes elapsed age = tick - last_served.
              pass = pass,
              last_served = dest.last_served,
            }
          end
        end
      end
    end
  end

  -- Frozen aging order, computed ONCE and reused for both passes; the clock is
  -- written in `commit` (to storage), never to snapshot.nodes mid-tick, so the
  -- sort can't shift between passes.
  local order = dispatcher.dest_order(snapshot.nodes)
  -- Pass 1: commit only worthwhile loads (fill >= min_load) or perishable trips.
  for _, dest_id in ipairs(order) do
    try_plan_dest(dest_id, snapshot.min_load_fraction or 0, 1)
  end
  -- Pass 2: leftovers -- ships Pass 1 left idle haul the remaining sub-threshold
  -- routes (still aging order, min_fill 0). A node no ship reached in either pass
  -- keeps aging and wins next tick.
  for _, dest_id in ipairs(order) do
    if not committed_dest[dest_id] then
      try_plan_dest(dest_id, 0, 2)
    end
  end

  return plans
end

-- ---------------------------------------------------------------------------
-- supply-side cross-tick bookkeeping read (mirror of demand.inbound_for)
-- ---------------------------------------------------------------------------

-- Sum surplus already committed FROM each node across in-flight assignments
-- (`surplus_commit`), so the snapshot subtracts it and a source isn't drained
-- twice while its rockets are still launching. Deterministic: iterates
-- assignments via the sorted helper. Returns { [node_id] = { [qkey] = qty } }.
--
-- QUALITY: `surplus_commit` / `return_manifest` are keyed by
-- `qkey(item, quality)` (they are copies of the qkey-keyed manifest), so the
-- per-node totals are qkey-keyed too and `build_snapshot` subtracts them against
-- the matching qkey'd `stock.surplus` read -- the demand-side `inbound_for` nets
-- the same way, so both bookkeeping sides stay uniformly qkey-keyed.
--
-- Two-way return leg: a `return_manifest` is sourced FROM the
-- destination planet, so it is committed surplus on `a.dest` -- counted here too
-- so a destination isn't drained twice for its return cargo either.
function dispatcher.committed_surplus_by_node()
  local out = {}
  local assignments = storage and storage.assignments
  if not assignments then
    return out
  end
  local function add(node_id, commit)
    local m = out[node_id]
    if not m then
      m = {}
      out[node_id] = m
    end
    for item, qty in state.sorted_pairs(commit) do
      m[item] = (m[item] or 0) + qty
    end
  end
  for _, a in state.sorted_pairs(assignments) do
    if a.source and a.surplus_commit then
      add(a.source, a.surplus_commit)
    end
    if a.dest and a.return_manifest then
      add(a.dest, a.return_manifest)
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- IO: snapshot the world (thin, engine-touching)
-- ---------------------------------------------------------------------------

-- [provisional] The space-location/planet name for a node, used as the route
-- station and for the fleet allow-list. Confirm the surface<->planet accessor
-- in-engine before flipping the api-notes seam to [confirmed].
function dispatcher.planet_name(node)
  local s = node and node.surface
  -- Guard `.valid` before `.name`: a node whose surface was deleted has
  -- an invalid `LuaSurface` handle, and reading `.name` off it errors. Plain test
  -- tables have no `.valid` field (absent => nil), so the guard degrades to the
  -- old behavior under the pure-Lua test runner.
  if s and s.valid == false then
    return nil
  end
  return s and s.name or nil
end

-- [provisional] The planet a platform is currently parked at, or nil while it is
-- travelling. `LuaSpacePlatform.space_location` is the space-location prototype it
-- is stopped at (nil in transit), whose `.name` matches the planet/surface name
-- the dispatcher routes on (planets are space locations of the same name). Used
-- ONLY as the no-deadhead preference in ship selection, so a nil (in-transit, or
-- unreadable) location simply yields no preference -- never a wrong route. Confirm
-- `space_location` (+ its `.name`) in-engine before flipping the api-notes seam.
function dispatcher.ship_planet(platform)
  local loc = platform and platform.valid and platform.space_location
  return loc and loc.name or nil
end

-- [provisional] A platform's cargo capacity as a SLOT BUDGET: the number of slots
-- in the hub's main inventory (`hub.get_inventory(defines.inventory.hub_main)`,
-- then `#inv`). This is what the slot-aware packer fills. Cargo bays
-- enlarge the hub inventory, so a freighter reports more slots than a bare hub.
-- Falls back to DEFAULT_CAPACITY slots when the hub/inventory can't be read
-- (degrade safely, never error). Confirm the in-engine accessor before flipping
-- the api-notes seam.
function dispatcher.capacity_of(entry)
  local platform = entry and entry.platform
  local hub = platform and platform.valid and platform.hub
  if hub and hub.valid and defines and defines.inventory and defines.inventory.hub_main then
    local inv = hub.get_inventory(defines.inventory.hub_main)
    if inv then
      local slots = #inv
      if slots > 0 then
        return slots
      end
    end
  end
  return dispatcher.DEFAULT_CAPACITY
end

-- [provisional] The stack size of an item, used by the slot-aware manifest packer
-- to convert an item-count load into a slot count
-- (`ceil(load / stack_size)`). Reads `prototypes.item[name].stack_size`; falls
-- back to DEFAULT_STACK_SIZE when `prototypes` is unavailable (the pure-Lua test
-- runner) or the item has no prototype, so callers degrade safely. Confirm the
-- in-engine accessor before flipping the api-notes seam.
function dispatcher.stack_size_of(name)
  if prototypes and prototypes.item then
    local proto = prototypes.item[name]
    if proto and proto.stack_size then
      return proto.stack_size
    end
  end
  return dispatcher.DEFAULT_STACK_SIZE
end

-- [provisional] Is `name` a PERISHABLE item -- one that spoils over time (food,
-- biter eggs, ...)? Reads the prototype's spoil time via `get_spoil_ticks()` (2.0:
-- a METHOD on LuaItemPrototype returning 0 for non-perishables; its optional quality
-- arg only scales the DURATION, never WHETHER it spoils, so we pass none and test
-- `> 0`). We deliberately never read the spoil DURATION: surviving the trip is the
-- player's concern (a faster ship), so the mod only needs the perishable/not bit.
-- Quality-independent (perishability is a per-NAME property), so the caller decodes
-- the qkey to a bare name first -- mirrors stack_size_of. Returns false when
-- `prototypes` is absent (the pure-Lua test runner) or the item has no prototype, so
-- callers degrade to "not perishable" and tests are unaffected. Confirm the in-engine
-- accessor before flipping the api-notes seam.
function dispatcher.perishable_of(name)
  if prototypes and prototypes.item then
    local proto = prototypes.item[name]
    if proto and proto.get_spoil_ticks then
      return proto.get_spoil_ticks() > 0
    end
  end
  return false
end

-- Runtime-global setting reads go through the shared, fallback-guarded
-- `state.setting` (it floors numeric values, so the integer caps/interval below
-- stay integers, and degrades to the module default when `settings` is absent --
-- the pure-Lua test runner).
local function two_way_enabled()
  return state.setting(dispatcher.TWO_WAY_SETTING, dispatcher.TWO_WAY_DEFAULT)
end

-- The configured dispatcher cadence in ticks. control.lua reads this to register
-- (and re-register on settings change) the on_nth_tick handler.
function dispatcher.interval()
  return state.setting(dispatcher.INTERVAL_SETTING, dispatcher.INTERVAL)
end

-- Build the per-tick snapshot the pure planner consumes. Reads demand + surplus
-- through the IO wrappers (all per-tick cached) and folds in the supply-
-- side committed-surplus bookkeeping. Surplus is computed ONLY for items some
-- node actually demands (production-agnostic, but bounded -- we never price items
-- nobody wants). The map-building loops here are commutative reductions, not
-- game-affecting decisions, so plain `pairs` is fine; every DECISION iteration
-- (in `plan`) goes through the sorted helper.
function dispatcher.build_snapshot(_tick)
  local nodes = {}
  local demanded_items = {}

  for id, node in registry.nodes() do
    -- Skip stale nodes: a node whose pad entity or surface went invalid
    -- (surface deleted, pad gone) must not be snapshotted -- it can't load or
    -- receive cargo, and reading off the dead `LuaSurface` (planet_name, stock
    -- surface-sum) would error. Skipping it here also kills the
    -- "padless ghost planet picked as export source" path. The `.valid` field is
    -- absent on plain test tables (nil), so `== false` only fires on a real dead
    -- engine handle and the pure-Lua test runner is unaffected.
    local entity_ok = not (node.entity and node.entity.valid == false)
    local surface_ok = not (node.surface and node.surface.valid == false)
    if entity_ok and surface_ok then
      local open, import_by_item = demand.open_demand(node)
      local unmet_by_item = {}
      for _, d in ipairs(open) do
        unmet_by_item[d.item] = d.unmet
        demanded_items[d.item] = true
        -- IO read: tag each demanded item with its stack size so the pure
        -- planner can attach it to manifest `items` for the slot-aware packer (Task
        -- 7). Reading here keeps `plan`/`return_manifest` pure (they only copy the
        -- snapshot field, never touch `prototypes`). `d.item` is a `qkey`,
        -- but stack_size is a per-NAME physical property (quality-independent), so
        -- decode to the bare item name before the prototype read.
        local name = qkey.qparse(d.item)
        d.stack_size = dispatcher.stack_size_of(name)
        -- IO read: tag perishability (per-NAME, quality-independent) so the pure
        -- planner can isolate perishables onto their own fast trip without touching
        -- `prototypes`. See dispatcher.perishable_filter.
        d.perishable = dispatcher.perishable_of(name)
      end
      local fkey = dispatcher.force_key(node.force)
      nodes[id] = {
        id = id,
        planet = dispatcher.planet_name(node),
        node = node,
        force = fkey,
        -- Per-force source-selection strategy (Monitor "Source" toggle), read here so
        -- the pure best_source ranks by fastest-route vs most-surplus without storage.
        strategy = state.source_strategy(fkey),
        demand = open,
        unmet_by_item = unmet_by_item,
        -- Gross physical shortfall per item (pre-inbound) -- the export thrash
        -- guard's real input, so a planet short on an item it requested is never
        -- chosen as the source for it even once an in-flight delivery nets its
        -- `unmet` to 0. See demand.import_map / dispatcher.exportable.
        import_by_item = import_by_item or {},
        surplus = {},
        -- The "Preferred ship" pin set on the Trade tab: a fleet key
        -- string | nil. This is the PRODUCER for the `dest.pin` consumers in
        -- `pick_ship` / `plan` / `unserved_reason` -- copied straight through so
        -- the pure planner can prefer that ship when it is free + eligible and
        -- fall through to auto-pick otherwise.
        pin = node.pin_ship,
        -- Aging clock (v1.8.0): the tick this node last received a forward
        -- manifest, copied straight from `storage.nodes[id].last_served_tick`.
        -- `nil` for never-served nodes -- the pure `dest_order` comparator coerces
        -- that to a sentinel strictly less than any real tick so it sorts oldest
        -- (fairest: it has waited since map start). Written back by `commit`.
        last_served = node.last_served_tick,
      }
    end
  end

  local committed = dispatcher.committed_surplus_by_node()
  local min_trip = stock.min_trip()
  for node_id, ns in pairs(nodes) do
    local com = committed[node_id]
    for item in pairs(demanded_items) do
      -- `stock.surplus` already min-trip-suppresses the pre-committed value; net
      -- it against in-flight bookkeeping and re-clamp so a post-commit remainder
      -- below min-trip is dropped rather than dispatched as a dribble (see
      -- dispatcher.net_surplus).
      local raw = stock.surplus(ns.node, item)
      local s = dispatcher.net_surplus(raw, com and com[item] or 0, min_trip)
      if s > 0 then
        ns.surplus[item] = s
      end
    end
  end

  local ships = {}
  for pid, entry in registry.platforms() do
    local platform = entry and entry.platform
    local valid = platform and platform.valid
    -- Skip hub-less platforms (#6). A platform with no valid hub can't load or
    -- deliver -- the manifest is realized as a logistic request on the hub, so a
    -- hub-less ship would be picked here only to abort at apply_records, churning
    -- a `dispatch SKIP` every tick. Filter it out in the IO snapshot; this keeps
    -- `fleet.idle_eligible` pure (no engine hub read there).
    local hub = valid and platform.hub
    if valid and hub and hub.valid then
      -- Ready-signal gate (dispatch-only): when this ship's "Hold until ready
      -- signal" toggle is on, read `planet-express-ready` off its hub (the ONE
      -- shared read wrapper) and stamp the pure readiness verdict; otherwise it
      -- stays unconditionally ready and we skip the per-tick signal read. Only an
      -- explicit `false` blocks the pick, so un-gated ships are unaffected.
      local ready = true
      if entry.require_ready == true then
        ready = fleet.ready_from_signal(true, fleet.read_ready_value(platform))
      end
      ships[#ships + 1] = {
        id = pid,
        entry = entry,
        capacity = dispatcher.capacity_of(entry),
        force = dispatcher.force_key(platform.force),
        planet = dispatcher.ship_planet(platform), -- ETA deadhead leg (v1.1)
        -- Learned per-ship ETA calibration (v1.1). Defaults to 1.0 before the watchdog
        -- lands the stored field / before a ship has flown, so the min-ETA pick
        -- treats an un-calibrated ship at its nominal speed.
        eta_factor = entry.eta_factor or 1.0,
        ready = ready,                             -- ready-signal gate
      }
    end
  end

  -- Concurrency caps + current in-flight counts for the pure planner.
  local active_global, active_by_route = dispatcher.active_counts(storage and storage.assignments)

  return {
    nodes = nodes,
    ships = ships,
    -- The in-memory inter-planet distance map (v1.1), read by best_source's
    -- nearest tie-break and pick_ship's min-ETA leg via the guarded helper.
    distances = dispatcher.distances(),
    two_way = two_way_enabled(),
    max_ships_global = state.setting(dispatcher.MAX_GLOBAL_SETTING, 0),
    max_ships_route = state.setting(dispatcher.MAX_ROUTE_SETTING, 5),
    -- Minimum-load gate as a 0..1 fraction (v1.8.0). The setting is a percent int
    -- 0..100 (floored by state.setting); divide to a fraction and clamp so the
    -- pure two-pass planner can gate on `fill >= min_load_fraction`. Absent setting
    -- (test runner) -> MIN_LOAD_DEFAULT, so the gate is well-defined everywhere.
    min_load_fraction = math.max(0, math.min(100,
      state.setting(dispatcher.MIN_LOAD_SETTING, dispatcher.MIN_LOAD_DEFAULT))) / 100,
    active_global = active_global,
    active_by_route = active_by_route,
  }
end

-- ---------------------------------------------------------------------------
-- IO: commit a plan (allocate id, bookkeep, schedule, set ship state)
-- ---------------------------------------------------------------------------

-- Render a qkey-keyed manifest for the debug decision log. Keys are
-- qkey(item, quality); `qkey.label` decodes each for display (debug-only,
-- cosmetic) so the line reads "iron-plate=500" not "iron-plate@normal=500".
local function manifest_str(m)
  local parts = {}
  for item, qty in state.sorted_pairs(m) do
    parts[#parts + 1] = qkey.label(item) .. "=" .. tostring(qty)
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- Realize one plan: allocate a monotonic assignment id, record two-sided
-- bookkeeping (inbound_commit on the demand side, surplus_commit on the supply
-- side), write the schedule via the writer wrapper, flip the ship to `enroute`,
-- and emit a decision line for the debug log.
function dispatcher.commit(p, tick)
  -- Write the schedule FIRST. If there is nothing to schedule or the engine write
  -- fails, record no commitment and don't claim the ship -- the demand simply
  -- stays open and is retried next tick. (Otherwise a failed write would leave a
  -- phantom assignment holding surplus/inbound bookkeeping against a ship that
  -- never actually left.)
  local platform = p.ship and p.ship.entry and p.ship.entry.platform
  -- Ready-signal gate (v1.2): when the ship's "Hold until ready signal" toggle is on,
  -- carry the signal NAME into the schedule so every stop gets a circuit hold
  -- condition; nil leaves the schedule exactly as before.
  local gate_ready = (p.ship.entry and p.ship.entry.require_ready == true) and fleet.READY_SIGNAL or nil
  local built = schedule.write(platform, {
    source = p.source_planet,
    dest = p.dest_planet,
    capacity = p.ship.capacity,
    timeout = dispatcher.TIMEOUT,
    items = p.items,
    return_manifest = p.return_manifest,
    gate_ready = gate_ready,
  })
  if not built then
    state.debug_log(string.format(
      "dispatch SKIP %s -> %s via ship#%s: nothing scheduled / write failed",
      tostring(p.source_planet), tostring(p.dest_planet), tostring(p.ship_id)))
    return nil
  end

  local id = state.next_id()
  storage.assignments[id] = {
    ship = p.ship_id,
    source = p.source_id,
    dest = p.dest_id,
    source_planet = p.source_planet,
    dest_planet = p.dest_planet,
    manifest = p.manifest,
    inbound_commit = p.manifest,  -- demand side (read by demand.inbound_for)
    surplus_commit = p.manifest,  -- supply side (read by committed_surplus_by_node)
    -- Two-way return leg: cargo carried home from the destination back
    -- to the source. Its bookkeeping is read live -- demand.inbound_for credits
    -- it to the SOURCE planet (the return destination) and
    -- committed_surplus_by_node debits it from the DEST planet (the return
    -- source) -- so the second leg is two-sided too and balances on free.
    return_manifest = p.return_manifest,
    -- No-progress deadline: the watchdog resets it to tick + window each
    -- time the ship reaches a new stop, so a legal multi-stop trip is never timed
    -- out -- only a ship that stops making progress for a whole window is freed.
    -- The window must cover travel + wait (see NO_PROGRESS_WINDOW), which is wider
    -- than the per-stop wait `TIMEOUT`.
    deadline_tick = tick + dispatcher.NO_PROGRESS_WINDOW,
    deadline_window = dispatcher.NO_PROGRESS_WINDOW,
    -- The dest node's force key. Stamped so the fleet Monitor can scope
    -- the shipment / its alerts to the receiving force (read back in
    -- viewmodel.gather and watchdog.raise_alert detail).
    force = p.dest_force,
    -- The per-stop wait-condition timeout used to BUILD the schedule. Stored so the
    -- watchdog can rebuild the wait conditions (after a re-clamp) with the same one.
    wait_timeout = dispatcher.TIMEOUT,
    -- Ready-signal gate name (v1.2), or nil. Stored so the watchdog's re-clamp
    -- (`resync_conditions`) rebuilds the SAME gated conditions instead of dropping
    -- the hold.
    gate_ready = gate_ready,
    phase = "enroute",
    -- Stamp the order-stable schedule signature so the watchdog can
    -- detect a later player edit and withdraw the ship instead of fighting them.
    -- Sign over the CLEANED engine records (station + wait_conditions) -- the same
    -- shape the watchdog reads back from the live LuaSchedule -- so the player-edit
    -- compare is apples-to-apples (cargo lives in the hub request, not the record).
    schedule_signature = watchdog.schedule_signature(schedule.engine_records(built.records)),
  }

  fleet.set_state(p.ship_id, fleet.ENROUTE)
  fleet.set_assignment(p.ship_id, id)

  state.debug_log(string.format(
    "dispatch a#%d: %s -> %s via ship#%s %s",
    id, tostring(p.source_planet), tostring(p.dest_planet),
    tostring(p.ship_id), manifest_str(p.manifest)))

  return id
end

-- ---------------------------------------------------------------------------
-- IO: the dispatcher tick
-- ---------------------------------------------------------------------------

-- The reason a single destination's open demand was NOT dispatched this tick.
-- Pure over the snapshot -- re-runs best_source/pick_ship so the reason matches
-- the planner's real gates. Shared by the per-tick debug log and the /pe-status
-- command. `used` is empty here: this asks "could ANY ship serve it", not "given
-- this tick's commitments".
function dispatcher.unserved_reason(snapshot, dest)
  local src = dispatcher.best_source(snapshot, dest)
  if not src then
    return "no exportable source (every other planet is below reserve+min-trip, "
      .. "has its surplus committed to a shipment, or is itself importing the item)"
  end
  local route_ships = dispatcher.ships_for_force(snapshot.ships, dest.force)
  local ship = dispatcher.pick_ship(route_ships, {}, src.planet, dest.planet, dest.pin, snapshot.distances)
  if not ship then
    -- Held-aware branch: pick_ship returns nil when every candidate is
    -- held by its ready signal just as it does when there is no eligible ship at
    -- all. Tell them apart so /pe-status + the debug log don't misreport a held
    -- ship as missing. A ship that is idle_eligible (ignoring `ready`) but stamped
    -- `ready == false` is held -- if any such ship exists, the block is the gate.
    for _, s in ipairs(route_ships) do
      if s.ready == false and fleet.idle_eligible(s.entry, src.planet, dest.planet) then
        return "source=" .. tostring(src.planet)
          .. " has surplus + an eligible ship, but it is HELD by its ready signal "
          .. "(planet-express-ready <= 0 at the hub) -- emit planet-express-ready > 0 to dispatch"
      end
    end
    return "source=" .. tostring(src.planet)
      .. " has surplus, but NO idle eligible ship for force=" .. tostring(dest.force)
      .. " (enrolled? not reserved? allow-list covers both planets?)"
  end
  -- src + ship both exist, yet the planner didn't dispatch. Reproduce its two
  -- remaining gates -- manifest non-empty, then route cap -- to name WHICH one.
  local source = snapshot.nodes[src.id]
  local items = {}
  for _, d in ipairs(dest.demand) do
    local avail = dispatcher.exportable(source, d.item)
    if avail > 0 then
      -- thread stack_size + perishable so this diagnostic packs by SLOTS and
      -- isolates perishables EXACTLY as `plan` does; without it the "nothing loads"
      -- reason could fire (or not) inconsistently with the planner.
      items[#items + 1] = { item = d.item, surplus = avail, unmet = d.unmet,
        stack_size = d.stack_size, perishable = d.perishable }
    end
  end
  if next(schedule.build_manifest(dispatcher.perishable_filter(items), ship.capacity)) == nil then
    return "source=" .. tostring(src.planet) .. " ship#" .. tostring(ship.id)
      .. " but nothing loads (ship capacity " .. tostring(ship.capacity) .. " or every clamp = 0)"
  end
  local rkey = dispatcher.route_key(src.id, dest.id)
  local max_route = snapshot.max_ships_route or 0
  local active = (snapshot.active_by_route or {})[rkey] or 0
  if max_route > 0 and active >= max_route then
    return string.format(
      "source=%s ship#%s ready, but route %s->%s is AT CAP (%d/%d in flight) -- raise the max-ships-per-route setting",
      tostring(src.planet), tostring(ship.id), tostring(src.planet), tostring(dest.planet), active, max_route)
  end
  return string.format(
    "source=%s ship#%s ready -- would dispatch (if still unserved, a lower-id destination claimed the surplus first this tick)",
    tostring(src.planet), tostring(ship.id))
end

-- Diagnostics (debug-log only): explain, per still-open demand, why this tick did
-- NOT dispatch for it, and dump the fleet exactly as the dispatcher sees it. The
-- planner returns only SUCCESSFUL plans, so a silent no-plan tick otherwise gives
-- the player nothing to go on ("I have an idle ship, why won't it fly?"). Re-runs
-- best_source/pick_ship read-only so the reason matches the planner's real gates.
-- Only called when debug logging is on.
function dispatcher.log_unserved(snapshot, plans)
  local served = {}
  for _, p in ipairs(plans) do
    served[p.dest_id] = true
  end
  local unserved = {}
  for _, did in ipairs(state.sorted_keys(snapshot.nodes)) do
    local d = snapshot.nodes[did]
    if d.demand and #d.demand > 0 and not served[did] then
      unserved[#unserved + 1] = did
    end
  end
  if #unserved == 0 then
    return
  end

  -- The fleet as the dispatcher sees it -- reveals an un-enrolled / reserved /
  -- stale-assignment / wrong-force ship, or a ship the registry never indexed.
  if #snapshot.ships == 0 then
    state.debug_log("  fleet: NO platforms indexed (registry empty)")
  end
  for _, s in ipairs(snapshot.ships) do
    local e = s.entry or {}
    state.debug_log(string.format(
      "  ship#%s enrolled=%s state=%s reserved=%s assignment=%s force=%s",
      tostring(s.id), tostring(e.enrolled), tostring(e.state),
      tostring(e.reserve_for_manual_use), tostring(e.assignment), tostring(s.force)))
  end

  for _, did in ipairs(unserved) do
    local dest = snapshot.nodes[did]
    state.debug_log(string.format("no-dispatch pad#%s (%s): %s",
      tostring(did), tostring(dest.planet), dispatcher.unserved_reason(snapshot, dest)))
  end
end

-- On-demand diagnostic dump (the /pe-status console command). Returns a list of
-- plain strings: settings as the code reads them, every trade node + its open
-- demand, the fleet exactly as the dispatcher sees it, in-flight assignment
-- count, and the per-unserved-demand reason. Independent of the debug-log setting
-- so it ALWAYS produces output -- this is the reliable path when console logging
-- appears silent. IO (reads storage + registry + a fresh snapshot).
function dispatcher.diagnose()
  stock.begin_tick(game and game.tick or 0)
  local snapshot = dispatcher.build_snapshot(0)
  local lines = {}
  local function add(s) lines[#lines + 1] = s end

  add(string.format("settings: debug=%s interval=%d two_way=%s min_trip=%d max_global=%d max_route=%d",
    tostring(state.debug_enabled()), dispatcher.interval(), tostring(two_way_enabled()),
    stock.min_trip(), state.setting(dispatcher.MAX_GLOBAL_SETTING, 0),
    state.setting(dispatcher.MAX_ROUTE_SETTING, 5)))

  local node_ids = state.sorted_keys(snapshot.nodes)
  add("nodes: " .. #node_ids)
  for _, id in ipairs(node_ids) do
    local n = snapshot.nodes[id]
    local parts = {}
    for _, d in ipairs(n.demand) do
      -- d.item is a cargo qkey; decode it for the debug dump (cosmetic).
      parts[#parts + 1] = qkey.label(d.item) .. ":" .. tostring(d.unmet)
    end
    -- Surplus this planet can EXPORT (launchable stock - reserve, min-trip
    -- suppressed), as the mod sees it through the pad's logistic network. This is
    -- the number that clamps a manifest, so a planet that visibly holds plenty but
    -- shows a small surplus here means its stock is not on the cargo-landing-pad's
    -- logistic network (the silo-vs-pad-network caveat, api-notes.md §2).
    local surplus_parts = {}
    for item, qty in state.sorted_pairs(n.surplus or {}) do
      surplus_parts[#surplus_parts + 1] = qkey.label(item) .. ":" .. tostring(qty)
    end
    add(string.format("  pad#%s planet=%s force=%s demand=[%s] surplus=[%s]",
      tostring(id), tostring(n.planet), tostring(n.force), table.concat(parts, ","),
      table.concat(surplus_parts, ",")))
  end

  add("fleet: " .. #snapshot.ships)
  if #snapshot.ships == 0 then
    add("  (no platforms indexed -- registry never saw a hub; check HUB_NAME / force.platforms)")
  end
  for _, s in ipairs(snapshot.ships) do
    local e = s.entry or {}
    local allowed = e.allowed_planets
    add(string.format("  ship#%s enrolled=%s state=%s reserved=%s assignment=%s force=%s cap=%s allowed=%s",
      tostring(s.id), tostring(e.enrolled), tostring(e.state), tostring(e.reserve_for_manual_use),
      tostring(e.assignment), tostring(s.force), tostring(s.capacity),
      allowed == nil and "all" or (type(allowed) == "table" and ("{" .. table.concat(allowed, ",") .. "}") or tostring(allowed))))
  end

  local acount = 0
  for _ in state.sorted_pairs(storage and storage.assignments or {}) do
    acount = acount + 1
  end
  add("assignments in flight: " .. acount)

  -- Cargo-seam probe (read-only). The load is realized as a REQUESTER logistic
  -- request on the platform hub; if that point can't be reached, commit aborts at
  -- the schedule write and the ship silently never leaves. This checks each
  -- enrolled ship's hub reachability WITHOUT writing anything, so a false from
  -- apply_hub_request is diagnosable without enabling the debug log.
  local member = defines and defines.logistic_member_index
    and defines.logistic_member_index.space_platform_hub_requester
  add("cargo-seam probe: member_index(space_platform_hub_requester)=" .. tostring(member))
  for _, s in ipairs(snapshot.ships) do
    local e = s.entry or {}
    if e.enrolled == true then
      local platform = e.platform
      local hub = platform and platform.valid and platform.hub
      local hub_ok = (hub and hub.valid) and true or false
      local has_getlp = (hub_ok and hub.get_logistic_point ~= nil) and true or false
      local point = (has_getlp and member ~= nil) and hub.get_logistic_point(member) or nil
      -- current schedule stop (where the ship is in its route)
      local sched = platform and platform.valid and platform.schedule
      local cur = sched and sched.current
      local station = sched and sched.records and cur and sched.records[cur] and sched.records[cur].station
      add(string.format("  ship#%s state=%s hub_valid=%s requester_point=%s stop=%s@%s",
        tostring(s.id), tostring(e.state), tostring(hub_ok),
        tostring(point ~= nil), tostring(cur), tostring(station)))
      -- READ BACK the mod's logistic request, to see if apply_hub_request wrote it.
      if point and point.sections then
        for si = 1, #point.sections do
          local sec = point.sections[si]
          if sec and sec.is_manual and (sec.group == nil or sec.group == "") then
            local parts = {}
            for _, f in ipairs(sec.filters or {}) do
              local v = f and f.value
              parts[#parts + 1] = (v and tostring(v.name) or "?") .. "x" .. tostring(f and f.min)
                .. (f and f.import_from and ("<-" .. tostring(f.import_from)) or "")
                .. (f and f.minimum_delivery_count and (" payload>=" .. tostring(f.minimum_delivery_count)) or "")
            end
            add("    mod request: [" .. table.concat(parts, ", ") .. "]")
          end
        end
      end
    end
  end

  -- Run the planner to learn what WOULD be served (this mutates `snapshot`'s
  -- working surplus), then read reasons off a PRISTINE snapshot so a node's reason
  -- isn't skewed by surplus the planner just consumed for another node this tick.
  local served = {}
  for _, p in ipairs(dispatcher.plan(snapshot)) do
    served[p.dest_id] = true
  end
  local fresh = dispatcher.build_snapshot(0)
  for _, id in ipairs(state.sorted_keys(fresh.nodes)) do
    local n = fresh.nodes[id]
    if n.demand and #n.demand > 0 and not served[id] then
      add(string.format("no-dispatch pad#%s (%s): %s",
        tostring(id), tostring(n.planet), dispatcher.unserved_reason(fresh, n)))
    end
  end
  return lines
end

-- The on_nth_tick entry: open the per-tick stock cache, snapshot the world, plan
-- deterministically, then commit each plan. Safe to call before any pads/ships
-- exist (it simply plans nothing).
function dispatcher.run(tick)
  if not (storage and storage.assignments) then
    return
  end
  stock.begin_tick(tick)
  local snapshot = dispatcher.build_snapshot(tick)
  local plans = dispatcher.plan(snapshot)
  for _, p in ipairs(plans) do
    dispatcher.commit(p, tick)
  end
  if state.debug_enabled() then
    dispatcher.log_unserved(snapshot, plans)
  end
end

-- Hand the now fully-built table to the watchdog. The dispatcher<->watchdog cycle
-- (watchdog is required at the top of this file) means watchdog finished loading
-- before this point with an empty `dispatcher` reference; injecting here -- still
-- during control.lua parsing -- gives its flight sampler the real table without a
-- runtime `require` (which Factorio forbids). See scripts/watchdog.lua `disp()`.
watchdog.set_dispatcher(dispatcher)

return dispatcher
