-- scripts/schedule.lua
--
-- Route builder: an assignment -> an ordered list of stops -> a
-- `LuaSpacePlatform.schedule` records array.
--
-- v1 is a TWO-STOP emitter (Source -> Destination -> back), NOT a generic
-- multi-stop solver. The route is still modeled as an ORDERED LIST of stops so
-- v1.2 multi-stop becomes a change to route construction only, not a rewrite of
-- the records translation.
--
--   source stop:  per-stop cargo request  load = min(surplus, capacity, unmet),
--                 loaded WIDE across items up to ship capacity (priority order);
--                 wait-condition = cargo FULL  OR  timeout.
--   dest stop:    no explicit unload (native landing-pad pull does it);
--                 wait-condition = cargo EMPTY  OR  timeout.
--
-- Design split (per the plan's pure-function seam, same as stock.lua/demand.lua):
--   * `build_manifest` / `build_records` are PURE over plain tables -- unit-tested
--     under plain `lua` with no engine globals. They emit the engine-AGNOSTIC
--     record shape recorded in docs/api-notes.md §1
--     ({ station, wait_conditions, requests = {[item]=qty} }).
--   * `schedule.write` is the thin IO wrapper (`schedule.writer`) that hands the
--     records to the engine. It is gated by the [provisional] §1 seam and is
--     swappable so the pure builder can be exercised without a running engine.

local state = require("scripts.state")
local qkey = require("scripts.qkey")

local schedule = {}

-- Wait-condition tokens. Departure is gated on the MANIFEST items only (per-item
-- `item_count`), never the whole-hold `full`/`empty`: a platform hub also holds
-- its own fuel / ammo / repair-packs, so a whole-hold wait stalls on a partial
-- load and never reads empty. `time` is the mandatory timeout backstop (#1).
schedule.WAIT_ITEM_COUNT = "item_count"
schedule.WAIT_INACTIVITY = "inactivity"
schedule.WAIT_TIME = "time"

-- Ticks of no cargo movement that mean "the landing-pad pull has finished" at an
-- unload stop. Departing on item_count==0 alone stalls when the ship legitimately
-- RETAINS some of a delivered item (its own fuel/ammo, or a partial pad pull), so
-- inactivity is the robust fallback. 5s: long enough that a brief gap between
-- cargo-pod transfers doesn't fire it early, short enough to beat the timeout.
schedule.UNLOAD_INACTIVITY = 300

-- ---------------------------------------------------------------------------
-- pure load clamp + slot-aware wide manifest
-- ---------------------------------------------------------------------------

-- Default per-item stack size used by build_manifest when an item carries no
-- `stack_size`. 1 == "one item per slot" (the conservative reading), so an
-- un-annotated caller's slot budget behaves as a plain item-count budget. The
-- dispatcher always supplies a real `stack_size` (its own fallback is 50), so this
-- only matters to the pure-Lua test runner.
schedule.DEFAULT_STACK_SIZE = 1

-- Pure: how much of one item to request at the source stop, never more than the
-- surplus offered, the destination's unmet demand, or the per-item capacity still
-- free on the ship. Generic min-clamp over plain item-count units -- build_manifest
-- supplies `capacity` as `available_slots * stack_size` (the slot->item conversion
-- lives in the packer, this stays a pure min). Clamped at zero.
function schedule.clamp_load(surplus, capacity, unmet)
  local load = surplus or 0
  local u = unmet or 0
  if u < load then
    load = u
  end
  local cap = capacity or 0
  if cap < load then
    load = cap
  end
  if load < 0 then
    load = 0
  end
  return load
end

-- Pure: build the source manifest by packing `items` (already in the caller's
-- priority order) into a SLOT budget. `slot_budget` is a hub-inventory slot count
-- (Task 6 made ship capacity a slot count, not an item count); each item consumes
-- `ceil(load / stack_size)` slots. Two passes so one high-demand item can't
-- monopolize a tight hold and starve the rest -- the planet asked for many items,
-- so a single trip should carry many:
--   1. FAIR SHARE -- give each loadable item up to `slot_budget / loadable` SLOTS
--      (its need if smaller), so every requested item gets aboard. The slot
--      allowance converts to an item cap of `share_slots * stack_size`.
--   2. LEFTOVER -- distribute any unused slots greedily in PRIORITY order, topping
--      up the highest-priority items first (a top-up may also fill the slack in an
--      item's existing partial slot for free).
-- When slots comfortably cover everything both passes collapse to "load each item
-- to its full min(surplus, unmet)". Items that clamp to zero are omitted.
-- Returns { [item] = qty } (item counts, not slots).
--
-- `items` is a list of plain tables { item = <key>, surplus = N, unmet = N,
-- stack_size = N|nil } (missing stack_size defaults to DEFAULT_STACK_SIZE). The
-- `item` field is the dispatcher's cargo key -- a `qkey(item, quality)` (Task 10,
-- #4c) -- carried through OPAQUELY: the packer keys the manifest by it but never
-- decodes it (the engine write decodes qkey -> name+quality at the seam, Task 11).
-- `stack_size` is a per-NAME property the dispatcher supplies, so the slot math is
-- quality-independent.
function schedule.build_manifest(items, slot_budget)
  local manifest = {}
  local slots = math.floor(slot_budget or 0)
  if slots <= 0 then
    return manifest
  end

  local loadable = 0
  for _, it in ipairs(items or {}) do
    if (it.surplus or 0) > 0 and (it.unmet or 0) > 0 then
      loadable = loadable + 1
    end
  end
  if loadable == 0 then
    return manifest
  end

  local remaining = slots
  -- pass 1: fair per-item SLOT share (every requested item gets aboard)
  local share = math.max(1, math.floor(slots / loadable))
  for _, it in ipairs(items or {}) do
    if remaining <= 0 then
      break
    end
    local ss = it.stack_size or schedule.DEFAULT_STACK_SIZE
    -- item cap = (slots offered this pass) * stack_size, then clamped to need.
    local item_cap = math.min(share, remaining) * ss
    local load = schedule.clamp_load(it.surplus, item_cap, it.unmet)
    if load > 0 then
      manifest[it.item] = load
      remaining = remaining - math.ceil(load / ss)
    end
  end
  -- pass 2: top up in priority order with whatever slots are left. An item may
  -- grow to fill the slack in its current top slot PLUS all remaining free slots,
  -- so convert that slot allowance back to item units before clamping.
  for _, it in ipairs(items or {}) do
    if remaining <= 0 then
      break
    end
    local ss = it.stack_size or schedule.DEFAULT_STACK_SIZE
    local already = manifest[it.item] or 0
    local already_slots = math.ceil(already / ss)
    local item_cap = (already_slots + remaining) * ss
    local total = schedule.clamp_load(it.surplus, item_cap, it.unmet)
    if total > already then
      manifest[it.item] = total
      remaining = remaining - (math.ceil(total / ss) - already_slots)
    end
  end
  return manifest
end

-- ---------------------------------------------------------------------------
-- pure wait-condition builders
-- ---------------------------------------------------------------------------

-- Decode a manifest cargo `key` (a `qkey(item, quality)`) into the engine
-- `item_count` signal it gates on -- `{ type = "item", name, quality }` (Task 11,
-- #4d). The manifest is keyed by the OPAQUE qkey, but an `item_count` wait
-- condition reads a SPECIFIC quality variant of an item, so the signal must carry
-- both name and quality (normal- and uncommon-quality iron count independently).
-- A bare item-name key decodes to "normal" so legacy/quality-agnostic manifests
-- still gate on the right item. PURE: `qkey.qparse` is plain string math.
local function item_signal(key)
  local name, quality = qkey.qparse(key)
  return { type = "item", name = name, quality = quality }
end

-- "manifest loaded OR timeout" at a load stop: one `item_count >= qty` condition
-- per manifest item (AND-combined, stable item order for determinism), plus the
-- mandatory timeout (`compare_type = "or"`, invariant #1). Scoped to the manifest
-- ONLY, so the platform's own fuel/ammo cargo is ignored and a partial load still
-- departs promptly. Each item_count carries a CircuitCondition.
local function load_wait(manifest, timeout)
  local conds = {}
  for item, qty in state.sorted_pairs(manifest or {}) do
    conds[#conds + 1] = {
      type = schedule.WAIT_ITEM_COUNT,
      compare_type = "and",
      condition = {
        comparator = ">=",
        first_signal = item_signal(item),
        constant = qty,
      },
    }
  end
  if timeout then
    conds[#conds + 1] = { type = schedule.WAIT_TIME, ticks = timeout, compare_type = "or" }
  end
  return conds
end

-- Departure at an unload stop, as: (every manifest item == 0) OR inactivity OR
-- timeout. The per-item `item_count == 0` is the FAST path for a clean delivery
-- (the landing-pad pull emptied those items). But the ship can legitimately RETAIN
-- some of a delivered item -- it stocks its own fuel/ammo/repair-kits, or the pad
-- only pulled part of the load -- so `== 0` may never hit; `inactivity` then fires
-- once the pull goes quiet, and the timeout is the final backstop (invariant #1).
local function unload_wait(manifest, timeout)
  local conds = {}
  for item in state.sorted_pairs(manifest or {}) do
    conds[#conds + 1] = {
      type = schedule.WAIT_ITEM_COUNT,
      compare_type = "and",
      condition = {
        comparator = "=",
        first_signal = item_signal(item),
        constant = 0,
      },
    }
  end
  conds[#conds + 1] = {
    type = schedule.WAIT_INACTIVITY,
    ticks = schedule.UNLOAD_INACTIVITY,
    compare_type = "or",
  }
  if timeout then
    conds[#conds + 1] = { type = schedule.WAIT_TIME, ticks = timeout, compare_type = "or" }
  end
  return conds
end

-- Departure at the two-way TURNAROUND stop (the destination): the pad pulls the
-- forward cargo (allows_unloading) while rockets bring the return cargo up. Leave
-- once every RETURN item is aboard (>= qty) -- that is the ship's whole purpose for
-- this stop -- or on inactivity / timeout.
--
-- We deliberately DO NOT gate departure on the forward items reaching 0. Rockets
-- are atomic, so the SOURCE over-delivers any non-rocket-multiple request (e.g. 12
-- of a 10/rocket item -> two full rockets = 20 launched); the dest pulls only what
-- it requested (12) and 8 stay aboard, so a forward `== 0` condition NEVER clears.
-- AND-combined with the return condition that stranded the ship at the turnaround
-- until the 5-min timeout even though the return was loaded and the forward cargo
-- was long delivered. The pad pulls via logistics (sub-second) well before the
-- rockets finish loading the return, so by the time `return >= qty` holds the
-- forward is delivered; any over-delivery residue rides home and is cleared at the
-- final stop by the watchdog (delivery_stalled). `unload_manifest` is kept in the
-- signature for caller symmetry but intentionally NOT conditioned on.
local function turnaround_wait(unload_manifest, load_manifest, timeout)
  local _ = unload_manifest
  local conds = {}
  for item, qty in state.sorted_pairs(load_manifest or {}) do
    conds[#conds + 1] = {
      type = schedule.WAIT_ITEM_COUNT,
      compare_type = "and",
      condition = { comparator = ">=", first_signal = item_signal(item), constant = qty },
    }
  end
  conds[#conds + 1] = {
    type = schedule.WAIT_INACTIVITY,
    ticks = schedule.UNLOAD_INACTIVITY,
    compare_type = "or",
  }
  if timeout then
    conds[#conds + 1] = { type = schedule.WAIT_TIME, ticks = timeout, compare_type = "or" }
  end
  return conds
end

-- ---------------------------------------------------------------------------
-- pure route -> records
-- ---------------------------------------------------------------------------

-- Pure: build the ordered-stop route + records array for an assignment.
--
-- `assignment` is a plain table:
--   { source   = <planet name>,
--     dest     = <planet name>,
--     capacity = <ship cargo capacity, in SLOTS (hub inventory slot count)>,
--     timeout  = <ticks for the wait-condition timeout>,
--     items    = { { item, surplus, unmet, stack_size }, ... },  -- priority order
--     return_manifest = { [item] = qty } | nil }      -- Task 7 (two-way return)
-- Every `item` key here is the dispatcher's cargo key, a `qkey(item, quality)`
-- (Task 10, #4c), carried OPAQUELY through the records; the engine write decodes
-- it to a real item name + quality at the seam (apply_hub_request, Task 11).
--
-- Returns a table { records = {...}, manifest = { [item] = qty },
-- return_manifest = { [item] = qty } | nil } where `records` is the engine-
-- agnostic schedule (docs/api-notes.md §1). If the clamped forward manifest is
-- empty (nothing worth loading), returns nil -- no schedule for an empty trip.
--
-- `allows_unloading` is set per stop: FALSE at load stops so the planet we are
-- loading FROM can't immediately pull our cargo back down (it should only ever be
-- filling us, via the import-scoped hub request), TRUE where the planet's pad is
-- meant to take the cargo. (Defaulting it on every stop reads confusingly --
-- "Unload" on a load stop -- and lets a source pad tug a freshly-loaded hold.)
--
-- Two-way return leg (Task 7): when `return_manifest` is non-empty the route is
-- THREE stops in the SAME TWO PLANETS:
--   source(load fwd) -> dest(TURNAROUND: pad pulls fwd while return loads) -> source(drop return).
-- The destination is ONE turnaround stop, not an unload-then-reload pair: the hub
-- carries a SINGLE request that is re-pointed per stop, and the re-pointer only
-- fires reliably on a DISTINCT-station advance -- two consecutive same-station
-- stops (the old split) never re-pointed, so the return cargo was never requested.
-- Forward (== 0) and return (>= qty) are different items, so the turnaround wait
-- composes them; the pad pulls the forward cargo while rockets bring the return.
-- Pure: the ordered records for a route given the ALREADY-COMPUTED manifests (a
-- forward `manifest` map and an optional `ret` return map). Split out from
-- build_records so the watchdog can rebuild the SAME structure from re-clamped
-- manifests (keeping wait conditions in sync with the lowered request). Wait
-- conditions are derived from the manifests, so qty changes here automatically
-- update the conditions. See build_records for the route shape + allows_unloading.
function schedule.records_for(source, dest, manifest, ret, timeout)
  local has_return = ret ~= nil and next(ret) ~= nil
  local records = {
    {
      station = source,
      requests = manifest,
      import_from = source,
      wait_conditions = load_wait(manifest, timeout),
      allows_unloading = false,
    },
  }
  if has_return then
    -- Stop 2 (TURNAROUND): request the return manifest at the dest AND allow the
    -- pad to pull the forward cargo. Stop 3: drop the return back at the source.
    records[#records + 1] = {
      station = dest,
      requests = ret,
      import_from = dest,
      wait_conditions = turnaround_wait(manifest, ret, timeout),
      allows_unloading = true,
    }
    records[#records + 1] = {
      station = source,
      requests = {},
      wait_conditions = unload_wait(ret, timeout),
      allows_unloading = true,
    }
  else
    -- One-way: just unload the forward manifest at the destination.
    records[#records + 1] = {
      station = dest,
      requests = {},
      wait_conditions = unload_wait(manifest, timeout),
      allows_unloading = true,
    }
  end
  return records
end

function schedule.build_records(assignment)
  local manifest = schedule.build_manifest(assignment.items, assignment.capacity)

  if next(manifest) == nil then
    return nil
  end

  local ret = assignment.return_manifest
  local has_return = ret ~= nil and next(ret) ~= nil
  local records = schedule.records_for(assignment.source, assignment.dest, manifest, ret, assignment.timeout)

  return { records = records, manifest = manifest, return_manifest = has_return and ret or nil }
end

-- ---------------------------------------------------------------------------
-- engine write IO wrapper (docs/api-notes.md §1)
-- ---------------------------------------------------------------------------

-- The engine ScheduleRecord shape (confirmed against the 2.0 API): a record is
-- `{ station, wait_conditions, allows_unloading, ... }` with NO cargo field. The
-- agnostic builder above carries a per-stop `requests` map for the mod's own
-- bookkeeping; strip it here so what reaches the engine is a valid ScheduleRecord
-- array, but KEEP `allows_unloading` (a real record field — false on load stops,
-- true on drop stops). Per-stop cargo is realized separately via the hub's
-- requester logistic request (`apply_hub_request`). Pure -- exercised indirectly
-- by the build_records tests.
function schedule.engine_records(records)
  local out = {}
  for i, rec in ipairs(records or {}) do
    out[i] = {
      station = rec.station,
      wait_conditions = rec.wait_conditions,
      allows_unloading = rec.allows_unloading,
    }
  end
  return out
end

-- Find (or, when `create`, lazily add) the mod's OWN logistic section on a hub
-- requester point. We never write `sections[1]` blindly: it may be the player's
-- section, a shared logistic-group section, or a non-manual (read-only) one --
-- clearing it would destroy the player's requests or raise. So we only touch a
-- manual, ungrouped section, which on an enrolled (mod-managed) platform is the
-- mod's own. [provisional — confirm `is_manual`/`group`/`add_section` in-engine.]
local function mod_request_section(point, create)
  local sections = point.sections or {}
  for i = 1, #sections do
    local sec = sections[i]
    if sec and sec.is_manual and (sec.group == nil or sec.group == "") then
      return sec
    end
  end
  if create and point.add_section then
    return point.add_section()
  end
  return nil
end

-- Rocket capacity for an item = how many fit in ONE cargo rocket
-- (`rocket_lift_weight / item.weight`, floored, min 1). Used to decide whether a
-- request is smaller than a single rocket. Takes the BARE item name (not a qkey):
-- `weight` is a per-name prototype property, quality-independent, so the caller
-- decodes the qkey first. Returns nil if it can't be read (then the caller leaves
-- the default full-rocket delivery rather than guess). IO: reads `prototypes`, so
-- only meaningful in-engine.
local function rocket_capacity(item)
  local consts = prototypes and prototypes.utility_constants
  local lift = consts and consts["rocket_lift_weight"]
  local proto = prototypes and prototypes.item and prototypes.item[item]
  local weight = proto and proto.weight
  if type(lift) ~= "number" or type(weight) ~= "number" or weight <= 0 then
    return nil
  end
  local cap = math.floor(lift / weight)
  return cap >= 1 and cap or 1
end

-- [provisional] Realize a stop's cargo as the platform HUB's requester logistic
-- request. A 2.0 ScheduleRecord has no cargo field (confirmed: station +
-- wait_conditions only), so "load N of item X" is expressed by REQUESTING X on
-- the hub's requester logistic point (`space_platform_hub_requester`, confirmed
-- from the 2.0 defines); vanilla rockets then launch it up. The mod NEVER inserts
-- into the hub (that would be teleporting). `import_from` scopes each filter to
-- the planet the cargo is sourced from (api-notes §1) so a stale request can't
-- launch from the wrong planet. An empty `manifest` CLEARS the mod's request.
-- Returns true on success, false if the hub/point/section can't be reached (so
-- the caller can refuse to mark the ship enroute). The exact LuaLogisticSections
-- write calls are the one step to re-confirm in-engine before flipping §1.
function schedule.apply_hub_request(platform, manifest, import_from)
  local hub = platform and platform.valid and platform.hub
  if not (hub and hub.valid and hub.get_logistic_point) then
    return false
  end
  local point = hub.get_logistic_point(defines.logistic_member_index.space_platform_hub_requester)
  if not point then
    return false
  end
  manifest = manifest or {}
  local want = next(manifest) ~= nil
  -- Only create a section when there is something to request; clearing a request
  -- that was never made is a no-op (don't leak an empty mod section).
  local section = mod_request_section(point, want)
  if not section then
    return not want
  end
  -- Rewrite the mod's section to exactly the manifest (deterministic order) by
  -- ASSIGNING the whole `filters` array at once. (set_slot after clearing to {}
  -- did not grow the section, so the request stayed empty and nothing loaded.)
  -- Each LogisticFilter: value is a SignalFilter (quality is mandatory when min>0),
  -- min is the requested amount, import_from scopes it to the source planet.
  -- The manifest is keyed by the OPAQUE cargo qkey; DECODE it here -- this is the
  -- engine-write seam -- so the filter requests the exact (name, quality) variant
  -- (Task 11, #4d). A bare item-name key decodes to "normal".
  local filters = {}
  for item, qty in state.sorted_pairs(manifest) do
    local name, quality = qkey.qparse(item)
    local filter = {
      value = { type = "item", name = name, quality = quality, comparator = "=" },
      min = qty,
      import_from = import_from,
    }
    -- Cap the rocket launch payload ONLY when we want LESS than a full rocket:
    -- minimum_delivery_count = qty then launches with exactly `qty` instead of
    -- waiting to fill to the item's full rocket capacity (which would over-deliver
    -- -- e.g. requesting 50 of a 400/rocket item ships a whole 400-rocket, draining
    -- the source past its reserve and overshooting the dest). For a request of one
    -- rocket OR MORE the default full-rocket chunking is already right (and a min
    -- payload above capacity can't be met), so leave it unset. Capacity unknown ->
    -- also leave default (never guess a payload cap). `rocket_capacity` takes the
    -- bare NAME (weight is quality-independent), so pass the decoded name.
    local cap = rocket_capacity(name)
    if cap and qty < cap then
      filter.minimum_delivery_count = qty
    end
    filters[#filters + 1] = filter
  end
  section.filters = filters
  return true
end

-- Apply built `records` to a platform. CRITICAL: `platform.schedule = {...}`
-- assigns a `PlatformSchedule`, which is the SIMPLIFIED schedule that EXCLUDES
-- groups and interrupts -- so that assignment WIPES the player's refuel/rearm
-- interrupts (playtest 2026-06-10 confirmed the loss; the earlier "preserves
-- interrupts" note was wrong). Instead write the records through the FULL
-- `LuaSchedule` (`get_schedule():set_records`), which touches only the records --
-- interrupts and groups have their own `get/set_interrupts` API and are left
-- intact -- then `go_to_station(1)` to start the ship heading to the source stop in
-- automatic mode. The simplified assignment remains only as a last-resort fallback
-- when `get_schedule` is unavailable (that path DOES drop interrupts). A
-- ScheduleRecord carries no cargo, so the source stop's load is realized as the
-- hub's requester logistic request, applied FIRST: if it can't be applied the
-- dispatcher records NO assignment, and the schedule is never installed (demand
-- retries next tick). The watchdog re-issues the request at later stops.
local function apply_records(platform, records)
  if not (platform and platform.valid) then
    return false
  end
  local first = records and records[1]
  if schedule.apply_hub_request(
       platform, first and first.requests or {}, first and first.import_from) == false then
    return false
  end
  local eng = schedule.engine_records(records)
  local sched = platform.get_schedule and platform.get_schedule()
  if sched and sched.set_records then
    sched.set_records(eng)                                  -- records only: interrupts preserved
    if sched.go_to_station then
      sched.go_to_station(1)                                -- head to the source stop, automatic mode
    end
  else
    platform.schedule = { current = 1, records = eng }      -- fallback (drops interrupts)
  end
  return true
end

-- The active writer. Tests replace this with a plain-Lua stub.
schedule.writer = apply_records

-- Build the route for `assignment` and write it to `platform`. Returns the
-- built table ({ records, manifest }) on success, or nil if there was nothing to
-- schedule OR the engine write failed (the writer returned false). The pure
-- builder does all the math; this only performs the IO. The caller treats a nil
-- return as "not dispatched" and records no commitment.
function schedule.write(platform, assignment)
  local built = schedule.build_records(assignment)
  if not built then
    return nil
  end
  if schedule.writer(platform, built.records) == false then
    return nil
  end
  return built
end

-- Remove the mod's trade route from a platform on cleanup (free / reset), WITHOUT
-- touching the player's interrupts (refuel / rearm). Clear only the records via the
-- full `LuaSchedule` (`get_schedule():set_records({})`) -- the records-only clear
-- that leaves interrupts/groups intact (they have their own get/set_interrupts API).
-- The simplified `platform.schedule = {...}` assignment is the fallback ONLY when
-- get_schedule is unavailable; note it WIPES interrupts (a PlatformSchedule excludes
-- them), so it is genuinely a last resort. No-op on a dead platform.
function schedule.clear_route(platform)
  if not (platform and platform.valid) then
    return
  end
  local sched = platform.get_schedule and platform.get_schedule()
  if sched and sched.set_records then
    sched.set_records({})
  else
    platform.schedule = { current = 1, records = {} }
  end
end

-- Re-sync the live schedule's wait conditions to the given manifests, KEEPING the
-- current stop. Called after a re-clamp lowers a manifest: the load condition is
-- derived from the manifest (item >= qty), so without this it would still demand the
-- old, higher count while the request was lowered -- stranding the ship until
-- timeout. Writes the rebuilt records through the full `LuaSchedule`
-- (`set_records`) so the player's interrupts survive (the simplified
-- `platform.schedule` assignment would wipe them); `set_records` replaces only the
-- records and leaves `current` (the active stop) where it is. Falls back to the
-- simplified assignment only if get_schedule is unavailable. No-op on a dead platform.
function schedule.resync_conditions(platform, source, dest, manifest, ret, timeout)
  if not (platform and platform.valid) then
    return
  end
  local eng = schedule.engine_records(schedule.records_for(source, dest, manifest, ret, timeout))
  local sched = platform.get_schedule and platform.get_schedule()
  if sched and sched.set_records then
    sched.set_records(eng)                                  -- records only: interrupts preserved, current kept
  elseif platform.schedule then
    platform.schedule = { current = platform.schedule.current or 1, records = eng } -- fallback (drops interrupts)
  end
end

return schedule
