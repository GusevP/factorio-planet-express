-- scripts/watchdog.lua
--
-- The robustness layer: it watches every in-flight assignment and enforces the
-- three invariants from the plan that the happy-path dispatcher (Task 5) does
-- not.
--
--   (1) every wait-condition has a timeout  -> per-assignment `deadline_tick`;
--       a stuck ship (no fuel, no rockets, stranded) is freed and its demand
--       retried, never left hung.
--   (2) two-sided bookkeeping              -> freeing an assignment DELETES its
--       record, which reverses BOTH commit sides at once (inbound_commit /
--       surplus_commit are read live off `storage.assignments` by
--       `demand.inbound_for` / `dispatcher.committed_surplus_by_node`), so the
--       demand re-opens on the next dispatcher tick.
--   (3) the player always wins             -> if a busy ship's schedule no longer
--       matches what the mod wrote, the ship is WITHDRAWN (parked, not fought)
--       until it is idle again.
--
-- Edge cases handled here:
--   * ship destroyed / platform invalid (asteroid loss) -> free + alert.
--   * no-progress timeout (fuel starvation / stranded)  -> free + alert.
--   * player edited the schedule mid-flight             -> withdraw + free.
--   * re-clamp on the load stop: while the ship sits on a LOAD stop (the source
--     for the forward leg, the destination for the Task-7 return leg), lower its
--     per-stop request to the CURRENT surplus so a stock drop since dispatch
--     can't strip-mine that planet below its reserve.
--   * partial fill: the ship leaves with whatever loaded (its source stop waits
--     on "cargo FULL or timeout", Task 4); on delivery the assignment completes
--     and clears its inbound_commit, so any remaining shortfall re-opens and is
--     reconsidered next dispatcher tick (self-correction via recomputed unmet).
--     No mid-flight bookkeeping needed -- it falls out of completion.
--   * thruster fuel is NEVER managed (the player's responsibility); the watchdog
--     only DETECTS "stuck" via the timeout, it never refuels.
--
-- Design split (per the plan's pure-function seam):
--   * `reclamp_amount`, `schedule_signature`, `expired`, and `manifest_delivered`
--     (completion over an injected hub count_fn) are PURE over plain tables/scalars
--     -- no engine globals -- so they load and run under plain `lua` and are
--     unit-tested. The signature is order-stable (multiplayer
--     determinism: iterate records in order, requests via the sorted helper) per
--     docs/api-notes.md §4.
--   * everything else (the `run` loop, platform-validity / live-schedule /
--     arrival / manifest-delivered reads, the request rewrite) is thin IO, marked
--     [provisional] against the engine seams, and verified by manual playtest
--     (the Post-Completion checklist: asteroid loss, fuel starvation, mid-flight
--     edit).

local state = require("scripts.state")
local fleet = require("scripts.fleet")
local stock = require("scripts.stock")
local schedule = require("scripts.schedule")
local demand = require("scripts.demand")
local qkey = require("scripts.qkey")

local watchdog = {}

-- Watchdog cadence, in ticks -- the REAL period control.lua registers the
-- watchdog `run` loop on (a constant, so it is peer-identical). Kept independent
-- of the dispatcher interval so the two seams are greppable; both firing on the
-- same tick is harmless (deterministic), and control.lua shares one handler when
-- the periods coincide.
watchdog.INTERVAL = 300 -- 5s at 60 UPS

-- Alert kinds recorded in `storage.alerts` for the monitor GUI (Task 8).
watchdog.ALERT_DESTROYED = "ship_destroyed"
watchdog.ALERT_TIMEOUT = "timeout"
watchdog.ALERT_PLAYER_EDIT = "player_edit"

-- How many alerts to retain in `storage.alerts`. The Monitor only ever displays
-- the newest handful (viewmodel.MAX_ALERTS = 20); we keep a bounded backlog so a
-- long game with recurring asteroid losses / fuel-starvation timeouts can't grow
-- the save indefinitely. Oldest are evicted first (see raise_alert).
watchdog.MAX_ALERTS = 100

-- No-progress deadline window (ticks) fallback. The dispatcher stamps the real
-- window on each assignment (`deadline_window`); this covers pre-Task-6 saves.
-- It must exceed a single leg's travel PLUS the per-stop wait timeout, because
-- `schedule.current` only advances at a stop boundary (it is the index of the
-- current DESTINATION, not an arrival flag), so a long inter-planet leg shows no
-- progress mid-travel and must not be mistaken for a stuck ship. Sized as the
-- per-stop wait timeout (18000) + a 18000-tick travel budget.
watchdog.DEADLINE_WINDOW = 36000

-- ---------------------------------------------------------------------------
-- pure math (testable; no engine globals)
-- ---------------------------------------------------------------------------

-- Re-clamp amount on arrival: never request MORE than originally committed, and
-- never more than the current surplus. `new = clamp0(min(old, current_surplus))`.
-- Lowering-only (it can't raise a request the player/dispatcher didn't size).
function watchdog.reclamp_amount(old, current_surplus)
  local n = old or 0
  local s = current_surplus or 0
  if s < n then
    n = s
  end
  if n < 0 then
    n = 0
  end
  return n
end

-- Has this assignment's no-progress deadline passed? Pure. A nil deadline never
-- expires (defensive -- every assignment is created with one in Task 5).
function watchdog.expired(deadline_tick, tick)
  if not deadline_tick then
    return false
  end
  return tick >= deadline_tick
end

-- Pure: has the ship advanced to a later schedule stop since we last looked?
-- `prev` is the last-seen 1-based record index (nil on the first observation),
-- `current` the live one. Any forward move is progress; a non-numeric current is
-- treated as no progress (defensive -- the live read may be unavailable). Drives
-- the no-progress deadline reset so a normal multi-stop trip is never timed out.
function watchdog.advanced(prev, current)
  if type(current) ~= "number" then
    return false
  end
  return prev == nil or current > prev
end

-- Pure: has the ship delivered all of OUR cargo? True when the hub holds zero of
-- every item in BOTH the forward `manifest` and the `return_manifest`
-- (`count_fn(item)` returns the hub count of that item). This deliberately ignores
-- the platform's own fuel/ammo/repair-packs and any other non-manifest cargo: a
-- ship that stocks its own fuel would never read whole-hub-empty, so completion
-- gates on the MANIFEST cargo, not the whole hold. An empty manifest (nothing to
-- deliver) is trivially delivered. Iterates via the sorted helper for determinism
-- (the boolean is order-independent, but keep iteration stable). Pure over the
-- injected `count_fn` + plain manifest tables.
function watchdog.manifest_delivered(count_fn, manifest, return_manifest)
  local function all_zero(m)
    for item in state.sorted_pairs(m or {}) do
      if (count_fn(item) or 0) > 0 then
        return false
      end
    end
    return true
  end
  return all_zero(manifest) and all_zero(return_manifest)
end

-- Pure: should a parked delivery be ABORTED as impossible? True when the ship
-- STILL holds some of OUR cargo (`count_fn(item) > 0` for a manifest/return item)
-- AND the drop planet's RAW request for EVERY held item is 0 -- i.e. the
-- destination genuinely no longer wants any of it. `request_fn(item)` is the RAW
-- native unmet (`max(0, requested - on_hand)`, EXCLUDING fleet inbound) -- NOT
-- `demand.open_demand`, which nets out THIS assignment's own `inbound_commit` and
-- so reads ~0 for the whole unload window of any in-flight cargo; gating on it
-- would abort HEALTHY deliveries (review finding). If ANY held item is still
-- wanted (raw request > 0) the delivery is healthy -> false. If the ship holds
-- NONE of our cargo (the pad already pulled it) -> false: that is `completed`'s
-- job, checked FIRST in the run loop. Iterates via the sorted helper for
-- determinism (the boolean is order-independent). Pure over the injected fns +
-- plain manifest tables.
function watchdog.delivery_impossible(a, request_fn, count_fn)
  if not a then
    return false
  end
  local held_any = false
  local function scan(m)
    for item in state.sorted_pairs(m or {}) do
      if (count_fn(item) or 0) > 0 then
        held_any = true
        if (request_fn(item) or 0) > 0 then
          return true -- a still-held item is still wanted -> healthy, not impossible
        end
      end
    end
    return false
  end
  if scan(a.manifest) then
    return false
  end
  if scan(a.return_manifest) then
    return false
  end
  return held_any
end

-- Pure: which hub request the ship should be holding at schedule stop `current`,
-- and the planet to import it from. The hub request is a SINGLE global request
-- (api-notes §1) re-pointed as the ship advances stops, because a ScheduleRecord
-- carries no cargo. The route is:
--   one-way: 1 source(load fwd) -> 2 dest(unload)
--   two-way: 1 source(load fwd) -> 2 dest(TURNAROUND: pull fwd + load return) -> 3 source(drop)
-- So: forward manifest at the source (stop 1); at the destination (stop 2) the
-- request becomes the return manifest for a two-way trip (loaded there while the
-- pad pulls the forward cargo) or is cleared for a one-way trip; cleared again on
-- the drop (stop 3). An empty manifest means "clear the request". The return
-- request is re-pointed at the DISTINCT-station 1->2 advance, which the watchdog
-- detects reliably. Returns (manifest, import_from_planet). Pure over `a`.
function watchdog.stop_request(a, current)
  if current == 1 then
    return a.manifest or {}, a.source_planet
  elseif current == 2 and a.return_manifest and next(a.return_manifest) ~= nil then
    return a.return_manifest, a.dest_planet
  end
  return {}, nil
end

-- Pure: is `station` one of THIS assignment's OWN route stations (its source or
-- destination planet)? The mod writes a SIMPLIFIED schedule (source -> dest [->
-- source]) that EXCLUDES the player's refuel/rearm interrupts; when such an
-- interrupt fires, the engine can splice in its own record(s) and shift
-- `platform.schedule.current` onto a station the mod never wrote. The watchdog
-- re-points its single hub request off the numeric `current` index
-- (`stop_request` keys by index), so acting on a foreign interrupt stop would
-- request the WRONG leg's cargo. This guard lets the run loop ignore any `current`
-- whose record station is not one of ours. A nil station (unreadable record) or
-- nil assignment is treated as NOT ours (defensive -- never act blindly). Pure
-- over `a` + the station string. (Interrupt behavior is still-to-confirm in-engine
-- -- see docs/api-notes.md §1; this guard is correct defensive hygiene regardless.)
function watchdog.station_is_ours(a, station)
  if not (a and station) then
    return false
  end
  return station == a.source_planet or station == a.dest_planet
end

-- Pure: is the ship's CURRENT schedule stop one of THIS assignment's OWN route
-- stations? Resolves the station at `records[current]` and defers to
-- `station_is_ours`. Shared by BOTH `note_progress` and `maybe_reclamp` so neither
-- re-points the single hub request off a foreign interrupt stop -- both key cargo
-- by the numeric `current` index, so a spliced refuel/rearm record that shifts
-- `current` onto a station the mod never wrote would otherwise re-point to the
-- WRONG leg's cargo. A nil records / current / station -> NOT ours (defensive --
-- never act blindly). Pure over `a` + the records list + the index.
function watchdog.current_is_ours(a, records, current)
  local rec = records and current and records[current]
  return watchdog.station_is_ours(a, rec and rec.station)
end

-- Pure: which fleet lifecycle phase a ship is in, derived from its CURRENT route
-- stop and whether it is parked. The route is 1 source(load fwd) -> 2 dest(unload,
-- or TURNAROUND load on a two-way trip) -> 3 source(return drop). So:
--   * parked at stop 1                       -> LOADING (the forward load),
--   * parked at stop 2 with a non-empty       \ the two-way turnaround loads return
--     `return_manifest`                       / cargo while the pad pulls forward,
--                                            -> LOADING,
--   * parked at ANY OTHER own stop (one-way   \ stop 2 plain unload, stop 3 return
--     unload at stop 2, return drop at stop 3) / drop                  -> UNLOADING,
--   * otherwise (in transit, or a foreign /  -> ENROUTE.
--     unreadable stop)
-- `parked` is the caller's `(speed == 0) AND current_is_ours` observation, so a
-- foreign/unreadable `current` arrives here as `parked == false` and falls through
-- to ENROUTE. A nil `current` is likewise not-parked -> ENROUTE. Pure over `a` +
-- the scalars: its inputs are replicated engine reads on the shared watchdog tick,
-- so the derived state is deterministic across peers and save/load.
function watchdog.phase_for(a, current, parked)
  if not parked then
    return fleet.ENROUTE
  end
  if current == 1 then
    return fleet.LOADING
  end
  if current == 2 and a and a.return_manifest and next(a.return_manifest) ~= nil then
    return fleet.LOADING -- two-way turnaround: load the return cargo
  end
  return fleet.UNLOADING -- any other own stop is an unload (stop 2 one-way, stop 3 drop)
end

-- Order-stable serialization of a schedule's records (docs/api-notes.md §4).
-- The signature must be deterministic across save/load and across clients, so:
--   * iterate RECORDS in their fixed schedule order (array order),
--   * within a record, iterate request `{item=qty}` pairs via the sorted helper,
--   * iterate wait-conditions in their fixed array order.
-- A `pairs`-order serialization would produce false "player edited it" positives.
-- Pure over plain record tables (the §1 agnostic shape from schedule.lua).
--
-- CANONICALIZATION RULE (load-bearing -- mirrors the existing `compare_type or
-- "and"` pattern): every field the engine MATERIALIZES a default for on readback
-- must serialize identically to the commit-time form, or every freshly written
-- schedule mismatches its own live readback on the first watchdog tick and is
-- falsely withdrawn as a player edit. So:
--   * `compare_type` absent -> "and" (the engine default),
--   * `allows_unloading` absent -> false (the engine default),
--   * an `item_count` condition's `first_signal.quality` absent -> "normal",
--   * its `constant` absent -> 0.
-- `first_signal.type` is DELIBERATELY EXCLUDED: item signals round-trip it
-- inconsistently (omitted vs "item"), which would be a first-tick false positive.
-- Conditions WITHOUT a `condition` payload (time / inactivity are only
-- {type, ticks, compare_type}) serialize the payload slot as EMPTY, identically
-- on commit and readback -- the `if c.condition then` guard descends only when a
-- payload is present so the empty slot is byte-identical on both sides.
function watchdog.schedule_signature(records)
  local parts = {}
  for _, rec in ipairs(records or {}) do
    parts[#parts + 1] = "@" .. tostring(rec.station)
    parts[#parts + 1] = "u=" .. tostring(rec.allows_unloading == true)
    local reqs = {}
    for item, qty in state.sorted_pairs(rec.requests or {}) do
      reqs[#reqs + 1] = item .. "=" .. tostring(qty)
    end
    parts[#parts + 1] = "r[" .. table.concat(reqs, ",") .. "]"
    local conds = {}
    for _, c in ipairs(rec.wait_conditions or {}) do
      -- Serialize the CircuitCondition payload (item_count conditions carry one;
      -- time/inactivity do not) so a player editing a wait quantity or unload flag
      -- IS detected instead of silently overwritten by the next resync_conditions.
      local payload = ""
      if c.condition then
        local cond = c.condition
        local fs = cond.first_signal or {}
        payload = table.concat({
          tostring(cond.comparator or ""),
          tostring(fs.name or ""),
          tostring(fs.quality or "normal"),
          tostring(cond.constant or 0),
        }, "/")
      end
      conds[#conds + 1] = table.concat({
        tostring(c.type),
        tostring(c.ticks or ""),
        tostring(c.compare_type or "and"),
        payload,
      }, ":")
    end
    parts[#parts + 1] = "w[" .. table.concat(conds, ",") .. "]"
  end
  return table.concat(parts, "|")
end

-- Pure: drop the records the ENGINE splices into a live schedule so the player-edit
-- signature compares only the records the mod actually wrote. A refuel/rearm
-- INTERRUPT (or a temporary stop) makes the engine insert its own record(s) into
-- `platform.schedule.records`; those carry `created_by_interrupt = true` (the marker
-- api-notes §1 records on the 2.0 ScheduleRecord shape) and temporary stops carry
-- `temporary = true`. Signing the raw live records would then mismatch the stored
-- signature and falsely withdraw a HEALTHY ship as a "player edit" the moment an
-- interrupt fires -- before `current_is_ours` ever guards it. So `read_signature`
-- signs `schedule_signature(signable_records(sched.records))` and these spliced
-- records are filtered out, while records the player adds at OUR stations / new
-- stations still change the signature. `schedule_signature` itself stays unchanged
-- (this is a pre-filter, not a signature change). Commit-time signing in
-- `dispatcher.commit` is UNAFFECTED: the mod never writes temporary/interrupt
-- records, so the commit-time record list is already free of them and filtering it
-- is a no-op (the readback filter is what closes the asymmetry). Pure over the §1
-- plain record tables.
function watchdog.signable_records(records)
  local out = {}
  for _, rec in ipairs(records or {}) do
    if not (rec.temporary == true or rec.created_by_interrupt == true) then
      out[#out + 1] = rec
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- alerts + freeing (IO over storage; verified by playtest)
-- ---------------------------------------------------------------------------

-- Record an alert for the monitor GUI. Newest appended last; the backlog is
-- capped at `watchdog.MAX_ALERTS` (oldest evicted first) so it never grows the
-- save without bound. Alerts arrive one at a time, so at most one shift per call.
function watchdog.raise_alert(kind, assignment_id, tick, detail)
  storage.alerts = storage.alerts or {}
  storage.alerts[#storage.alerts + 1] = {
    kind = kind,
    assignment = assignment_id,
    tick = tick,
    detail = detail,
  }
  while #storage.alerts > watchdog.MAX_ALERTS do
    table.remove(storage.alerts, 1)
  end
end

-- Free an assignment: release its ship to `ship_state` (idle for a normal
-- free/completion, withdrawn for a player-edit) and DELETE the assignment record
-- -- that single deletion reverses both commit sides (they are read live), so the
-- demand re-opens next dispatcher tick. A non-nil `reason` raises an alert; a nil
-- reason is a silent free (used for normal completion). Idempotent.
function watchdog.free_assignment(id, reason, ship_state, tick)
  local a = storage.assignments[id]
  if not a then
    return
  end
  if a.ship then
    -- Clear the mod's hub request so a completed / timed-out / withdrawn ship
    -- stops requesting (and launching) cargo. Only the mod's own section is
    -- touched (api-notes §1), so withdrawing for a player edit never wipes the
    -- player's requests. Skipped for a destroyed/invalid platform.
    local platform = watchdog.platform_of(a)
    if platform and platform.valid then
      schedule.apply_hub_request(platform, {}, nil)
      -- Clear the mod's route so a freed ship PARKS instead of cycling the
      -- schedule forever (a platform follows its schedule indefinitely, so a
      -- delivered ship would otherwise fly the empty loop back to the source and
      -- repeat). `schedule.clear_route` removes only the RECORDS, preserving the
      -- player's interrupts (refuel/rearm) -- nil-ing the schedule would drop those
      -- too. NOT cleared on a player-edit withdraw: there the player has taken the
      -- schedule over (the whole point of withdrawing), so the mod leaves it be.
      if (ship_state or fleet.IDLE) ~= fleet.WITHDRAWN then
        schedule.clear_route(platform)
      end
    end
    fleet.set_assignment(a.ship, nil)
    fleet.set_state(a.ship, ship_state or fleet.IDLE)
  end
  storage.assignments[id] = nil
  if reason then
    watchdog.raise_alert(reason, id, tick, {
      ship = a.ship,
      source = a.source_planet,
      dest = a.dest_planet,
      -- The assignment's force key (Task 8): lets the Monitor scope this alert to
      -- the owning force. Nil on pre-Task-8 assignments -> the alert is visible to
      -- all viewers (apply_force_scope keeps nil-force rows for everyone).
      force = a.force,
    })
  end
  state.debug_log(string.format(
    "watchdog free a#%s reason=%s ship=%s -> %s",
    tostring(id), tostring(reason or "complete"), tostring(a.ship), tostring(ship_state or fleet.IDLE)))
end

-- ---------------------------------------------------------------------------
-- provisional engine reads (docs/api-notes.md §1/§4; confirm in-engine)
-- ---------------------------------------------------------------------------

-- The live platform handle for an assignment's ship (via the fleet entry the
-- registry maintains). Not engine-touching itself -- just a storage read.
function watchdog.platform_of(a)
  local entry = a and a.ship and fleet.get(a.ship)
  return entry and entry.platform
end

-- Recompute the order-stable signature from the platform's LIVE schedule, to
-- compare against the stored one. In 2.0 `LuaSpacePlatform.schedule` is a
-- `PlatformSchedule` plain table, so records are read off its `.records` field --
-- the {station, wait_conditions} shape matching what the dispatcher signed at
-- write time. Returns nil if it can't be read (then we never false-accuse the
-- player).
function watchdog.read_signature(platform)
  if not (platform and platform.valid) then
    return nil
  end
  local sched = platform.schedule
  if not (sched and sched.records) then
    return nil
  end
  -- Filter out engine-spliced refuel/rearm interrupt + temporary records before
  -- signing (see `watchdog.signable_records`), else a mid-route interrupt would
  -- mismatch the stored signature and falsely withdraw a healthy ship as a "player
  -- edit" before the `current_is_ours` guards run.
  return watchdog.schedule_signature(watchdog.signable_records(sched.records))
end

-- Did the player (or another mod) change a schedule the mod owns? Compares the
-- live signature to the one stored at write time. No stored signature (e.g. a
-- pre-Task-6 save) or an unreadable live schedule => not accused.
function watchdog.player_edited(a, platform)
  if not a.schedule_signature then
    return false
  end
  local live = watchdog.read_signature(platform)
  if live == nil then
    return false
  end
  return live ~= a.schedule_signature
end

-- [provisional] Per-(item,quality) hub cargo count, bound to this platform.
-- Returns a `count_fn(key) -> count` where `key` is a manifest cargo qkey: this is
-- an engine-read seam, so it DECODES the qkey and reads
-- `hub.get_item_count(name, quality)` (api-notes §1, Task 11 #4d) -- normal- and
-- uncommon-quality iron count independently, so completion/abort test the exact
-- variant the mod shipped. A bare item-name key decodes to "normal". Returns nil
-- when the hub can't be read (then completion never fires -- we don't "complete" a
-- ship whose hold we can't read). Used by `completed`/`delivery_stalled` to test
-- the MANIFEST cargo specifically rather than the whole hold. Confirm the two-arg
-- `get_item_count(name, quality)` in-engine.
function watchdog.hub_counter(platform)
  local hub = platform and platform.valid and platform.hub
  if not (hub and hub.valid and hub.get_item_count) then
    return nil
  end
  return function(key)
    local name, quality = qkey.qparse(key)
    return hub.get_item_count(name, quality)
  end
end

-- [provisional] Has the ship delivered and finished its mod route? v1 definition:
-- the final stop is its current destination, it is no longer moving, AND its hub
-- no longer holds any of OUR cargo (the manifest + return manifest -- NOT the whole
-- hold, which also carries the platform's own fuel/ammo). `schedule.current` is the
-- index of the current DESTINATION (the stop the ship is travelling toward OR
-- parked at), NOT an arrival flag, so `current >= #records` alone can't mean
-- "arrived at the last stop". The manifest-delivered check is the real completion
-- guard (a ship in transit to the final stop still holds its cargo, so it won't read
-- delivered until the native drop finishes); the `speed == 0` check additionally
-- rejects the edge where the cargo is already gone WHILE still travelling to the
-- final stop (e.g. a return leg that failed to load) -- a parked ship has zero
-- speed. `speed` degrades safely: an unreadable (nil) speed falls back to the
-- manifest-delivered guard alone. Confirm `schedule.current`, `get_item_count`, and
-- `speed` in-engine.
-- Shared "arrived + parked at the final stop" gate for `completed` and
-- `delivery_stalled`: the final stop is the active destination
-- (`schedule.current >= #records`) AND the ship is no longer moving
-- (`speed == 0`). Engine-read-thin over `platform.schedule`/`speed`. `speed`
-- degrades safely: an unreadable (nil) speed reads as 0 (parked), so the caller
-- falls through to its own cargo guard. Returns false on any unreadable schedule
-- seam (never act blindly).
function watchdog.parked_at_last_stop(platform)
  local sched = platform and platform.valid and platform.schedule
  local records = sched and sched.records
  if not (records and #records > 0) then
    return false
  end
  if (sched.current or 0) < #records then
    return false -- the final stop is not yet the active destination
  end
  return (platform.speed or 0) == 0 -- parked at the final stop, not still moving
end

function watchdog.completed(platform, a)
  if not watchdog.parked_at_last_stop(platform) then
    return false -- not yet arrived + parked at the final stop
  end
  local count_fn = watchdog.hub_counter(platform)
  if not count_fn then
    return false -- can't read the hold -> never complete blindly
  end
  return watchdog.manifest_delivered(count_fn, a and a.manifest, a and a.return_manifest)
end

-- [provisional] Is the platform idle with no active mod schedule? Used to recover
-- a withdrawn ship once the player is done with it. Confirm in-engine.
function watchdog.platform_idle(platform)
  local sched = platform and platform.valid and platform.schedule
  if not sched then
    return true
  end
  local records = sched.records
  return records == nil or #records == 0
end

-- Is the ship at the forward LOAD stop (current == 1) with an EMPTY forward
-- manifest? Happens when a re-clamp drains the manifest (the source can't supply
-- any of it anymore). The trip can never load anything, so the run loop aborts it
-- rather than wait out the per-stop timeout. Read of `schedule.current` + the
-- (re-clamped) `a.manifest`.
function watchdog.load_impossible(a, platform)
  local sched = platform and platform.valid and platform.schedule
  return sched ~= nil and sched.current == 1
    and a.manifest ~= nil and next(a.manifest) == nil
end

-- [provisional] The DROP node's RAW native request as a `request_fn(item) ->
-- max(0, requested - on_hand)`, for the delivery-impossible abort. CRITICAL: this
-- is the RAW pad request EXCLUDING fleet inbound -- deliberately NOT
-- `demand.open_demand` (which nets out this very assignment's `inbound_commit`, so
-- a destination's *open* demand reads ~0 for the whole unload window and would
-- abort healthy deliveries). The raw request also self-guards a mid-pull: while
-- the pad is still draining cargo, `on_hand` is low so raw unmet stays > 0. The
-- drop node is the DESTINATION for a one-way trip (last stop = the unload) and the
-- SOURCE for a two-way return drop (last stop = the return drop), mirroring
-- `stop_request`'s forward/return split. Reuses the `demand.reader` §3 seam and the
-- pure `compute_unmet` (inbound forced to 0 = raw). Returns nil when the node or
-- its request can't be read, so the caller never aborts blindly.
--
-- QUALITY (Task 11, #4d): `demand.reader` already keys each row by
-- `qkey(name, quality)` (Task 9 -- the per-quality pad-request read decodes there,
-- the engine-read seam), so `raw` is qkey-keyed. `delivery_impossible` calls this
-- `request_fn` with the manifest's cargo qkeys, so the lookup is qkey-to-qkey: the
-- raw request resolves per (name, quality) WITHOUT a second decode here (normal-
-- and uncommon-quality iron net independently).
function watchdog.dest_request_fn(a)
  local two_way = a and a.return_manifest and next(a.return_manifest) ~= nil
  local node_id = two_way and a.source or (a and a.dest)
  local node = storage and storage.nodes and storage.nodes[node_id]
  if not node then
    return nil
  end
  local raw = {}
  for _, row in ipairs(demand.reader(node) or {}) do
    raw[row.item] = demand.compute_unmet(row.requested, row.on_hand, 0)
  end
  return function(key)
    return raw[key] or 0
  end
end

-- [provisional] Should a parked, no-longer-wanted cargo be aborted? Gated
-- CONCRETELY: the ship must be parked at the LAST stop (`schedule.current >=
-- #records` AND `speed == 0`) -- the same "arrived + stopped" gate as `completed`,
-- which the run loop checks FIRST so a genuine pad-pull COMPLETES (idles, no
-- residue) instead. Only then does the pure `delivery_impossible` decide, over the
-- drop node's RAW request (`dest_request_fn`) and the live hub count
-- (`hub_counter`). The `current >= #records` gate scopes this to the ONE-WAY
-- delivery (last stop) and the two-way RETURN drop (last stop), NOT a two-way
-- forward turnaround (stop 2 of 3) -- that case waits its per-stop timeout, residue
-- self-heals at the stop-3 drop. Returns false on any unreadable seam (never abort
-- blindly). Confirm `schedule.current` / `speed` / the pad request read in-engine.
function watchdog.delivery_stalled(a, platform)
  if not watchdog.parked_at_last_stop(platform) then
    return false -- not yet arrived + parked at the final stop
  end
  local count_fn = watchdog.hub_counter(platform)
  local request_fn = watchdog.dest_request_fn(a)
  if not (count_fn and request_fn) then
    return false -- can't read the hold or the drop request -> never abort blindly
  end
  return watchdog.delivery_impossible(a, request_fn, count_fn)
end

-- [provisional] Re-issue the active stop's cargo request as `manifest` (scoped to
-- the `import_from` planet). Cargo is the hub's requester logistic request
-- (api-notes.md §1), NOT a schedule-record field, so the re-clamp lowers it and
-- the per-stop re-point switches it (forward -> cleared -> return -> cleared)
-- through the same hub-request path the dispatcher's writer uses. The mod NEVER
-- inserts into the hub (teleporting); it only changes what is REQUESTED.
function watchdog.rewrite_source_request(platform, manifest, import_from)
  return schedule.apply_hub_request(platform, manifest, import_from)
end

-- [provisional read] Reset the no-progress deadline whenever the ship reaches a
-- new schedule stop. The assignment deadline is a NO-PROGRESS watchdog (a stuck
-- ship is freed), NOT a whole-trip budget: a legal trip is multi-stop (load,
-- travel, unload, travel, return) and each stop may itself wait up to the per-stop
-- timeout, so a single fixed deadline covering the entire assignment would free
-- ships that are operating normally. Reading `schedule.current` is provisional IO.
function watchdog.note_progress(a, platform, tick)
  local sched = platform and platform.valid and platform.schedule
  local current = sched and sched.current
  if not watchdog.advanced(a.progress_index, current) then
    return
  end
  -- Interrupt guard: only re-point/commit on a stop that is one of OUR route
  -- stations. A refuel/rearm INTERRUPT can splice in its own record(s) (the
  -- simplified schedule the mod wrote excludes interrupts), shifting `current` onto
  -- a station we never wrote; re-pointing the single hub request off that foreign
  -- index (stop_request keys by index) would request the wrong leg's cargo. Skip
  -- WITHOUT committing progress, so the advance is re-detected and handled once the
  -- ship returns to a route stop. (Interrupt behavior still-to-confirm in-engine --
  -- docs/api-notes.md §1; defensive hygiene regardless.)
  if not watchdog.current_is_ours(a, sched.records, current) then
    return
  end
  -- Re-point the single global hub request to whatever this stop should load
  -- (forward at the source, cleared during unload, the return manifest at the
  -- return-load stop, cleared on the drop -- see `stop_request`). Commit the new
  -- progress index + reset the no-progress deadline ONLY when the re-point
  -- succeeds: a failed hub write leaves `progress_index` behind so the advance is
  -- re-detected and retried next tick, instead of silently skipping (e.g.) the
  -- return-load request and carrying nothing home. A ship whose hub stays
  -- unreachable still trips the existing deadline and is freed. At the source
  -- (stop 1) the request is then refined by `maybe_reclamp`, which runs after
  -- note_progress in the tick loop.
  local manifest, import_from = watchdog.stop_request(a, current)
  if watchdog.rewrite_source_request(platform, manifest, import_from) == false then
    return
  end
  a.progress_index = current
  a.deadline_tick = tick + (a.deadline_window or watchdog.DEADLINE_WINDOW)
end

-- Surplus already committed FROM `source_id` by OTHER in-flight assignments
-- (every assignment except `exclude_id`): forward legs sourced there
-- (`surplus_commit`) plus return legs whose DESTINATION is there (a return
-- manifest is loaded at the forward dest). Mirrors
-- dispatcher.committed_surplus_by_node, but for a single node minus self, so the
-- re-clamp sizes against what is GENUINELY free -- otherwise several ships
-- converging on one source each clamp to the full raw surplus and collectively
-- breach the reserve. Deterministic (sorted helper). Returns { [item] = qty }.
function watchdog.other_committed(source_id, exclude_id)
  local totals = {}
  local assignments = storage and storage.assignments
  if not assignments then
    return totals
  end
  local function add(commit)
    for item, qty in state.sorted_pairs(commit) do
      totals[item] = (totals[item] or 0) + qty
    end
  end
  for aid, a in state.sorted_pairs(assignments) do
    if aid ~= exclude_id then
      if a.source == source_id and a.surplus_commit then
        add(a.surplus_commit)
      end
      if a.dest == source_id and a.return_manifest then
        add(a.return_manifest)
      end
    end
  end
  return totals
end

-- ---------------------------------------------------------------------------
-- re-clamp on the load stop (pure amount tested; stop/rewrite provisional)
-- ---------------------------------------------------------------------------

-- Re-clamp ONE leg's `manifest` down to the live surplus at node `node_id` (net
-- of what OTHER in-flight assignments already commit from it -- `exclude_id` is
-- self), rewrite the hub request scoped to `import_from`, commit the lowered
-- bookkeeping via `commit`, and re-stamp the signature -- but ONLY when the hub
-- rewrite succeeds. A failed rewrite records NOTHING: the larger request +
-- bookkeeping stay intact and are retried next tick, so we never claim to have
-- lowered a request the hub did not actually accept. Lower-only
-- (`reclamp_amount`); a no-op when surplus is steady. Re-stamping keeps our own
-- edit from being mistaken for a player edit next tick.
local function reclamp_leg(a, platform, exclude_id, node_id, import_from, manifest, commit)
  local node = storage.nodes and storage.nodes[node_id]
  if not node then
    return
  end
  local other = watchdog.other_committed(node_id, exclude_id)
  local new_manifest = {}
  local changed = false
  for item, qty in state.sorted_pairs(manifest or {}) do
    local available = stock.surplus(node, item) - (other[item] or 0)
    local clamped = watchdog.reclamp_amount(qty, available)
    -- OMIT items that clamp to zero (source can no longer spare any) rather than
    -- keep a min=0 request / item>=0 condition. The manifest may then go EMPTY,
    -- which the abort check (load_impossible) uses to free a pointless trip.
    if clamped > 0 then
      new_manifest[item] = clamped
    end
    if clamped ~= qty then
      changed = true
    end
  end
  if not changed then
    return
  end
  if watchdog.rewrite_source_request(platform, new_manifest, import_from) == false then
    return -- leave the larger request + bookkeeping intact; retry next tick
  end
  commit(new_manifest)
  -- Lower the schedule's wait conditions to match the lowered request, else the
  -- load condition (item >= old qty) strands above the new request and the ship
  -- waits out the timeout. `commit` already updated a.manifest/a.return_manifest,
  -- so rebuild from the current pair.
  schedule.resync_conditions(platform, a.source_planet, a.dest_planet,
    a.manifest, a.return_manifest, a.wait_timeout)
  a.schedule_signature = watchdog.read_signature(platform) -- our edit, not the player's
  state.debug_log("watchdog reclamp a#" .. tostring(a.ship))
end

-- Keep each LOAD stop clamped to its planet's CURRENT surplus while the ship sits
-- on that stop, so a stock drop since dispatch can't strip-mine below the
-- reserve. `schedule.current` is only the index of the current DESTINATION -- it
-- covers BOTH the transit toward a stop AND parking on it, NOT the instant of
-- arrival -- so rather than re-clamp once "on arrival" we re-clamp EVERY tick the
-- ship is on a load stop: the forward load at the source (stop 1) and the Task-7
-- return load at the destination TURNAROUND (stop 2). Lower-only and idempotent
-- when surplus is steady; an over-correction on a transient dip simply under-loads
-- and re-opens next dispatcher tick. Runs after note_progress in the tick loop.
function watchdog.maybe_reclamp(a, platform, id)
  local sched = platform and platform.valid and platform.schedule
  local current = sched and sched.current
  -- Interrupt guard (same as note_progress): re-clamp only when `current` is one of
  -- OUR route stops. A refuel/rearm interrupt can splice in its own record(s) and
  -- shift `current` onto a station the mod never wrote; the `current == 1`/`== 2`
  -- branches below key the re-clamp off that numeric index, so acting on a foreign
  -- stop would re-clamp the WRONG leg's cargo against the wrong reserve.
  if not watchdog.current_is_ours(a, sched and sched.records, current) then
    return
  end
  if current == 1 then
    -- forward leg: source surplus honors the SOURCE reserve
    reclamp_leg(a, platform, id, a.source, a.source_planet, a.manifest, function(m)
      a.manifest = m
      a.inbound_commit = m
      a.surplus_commit = m
    end)
  elseif current == 2 and a.return_manifest and next(a.return_manifest) ~= nil then
    -- return leg (Task 7): the destination turnaround stop loads the return cargo,
    -- so honor the DESTINATION reserve here -- a stock drop at the destination
    -- before the ship loads could otherwise export it below its own reserve.
    reclamp_leg(a, platform, id, a.dest, a.dest_planet, a.return_manifest, function(m)
      a.return_manifest = m
    end)
  end
end

-- ---------------------------------------------------------------------------
-- the watchdog tick (IO; verified by playtest)
-- ---------------------------------------------------------------------------

-- Once the player is done with a WITHDRAWN ship (its schedule is idle again),
-- return it to the fleet so the dispatcher can use it. Iterates fleet via the
-- sorted helper (determinism).
function watchdog.recover_withdrawn()
  if not (storage and storage.fleet) then
    return
  end
  for id, entry in state.sorted_pairs(storage.fleet) do
    if entry.state == fleet.WITHDRAWN and watchdog.platform_idle(entry.platform) then
      fleet.set_state(id, fleet.IDLE)
      state.debug_log("watchdog recovered withdrawn ship#" .. tostring(id))
    end
  end
end

-- The on_nth_tick entry. Iterates assignments in stable id order (determinism)
-- and, for each, applies the first matching rule:
--   destroyed -> free+alert; player-edited -> withdraw+free; completed -> free
--   (silent); timed out -> free+alert; otherwise -> re-clamp at the source.
-- Safe to call before any assignments exist.
function watchdog.run(tick)
  if not (storage and storage.assignments) then
    return
  end
  stock.begin_tick(tick) -- fresh surplus reads for re-clamping this tick

  for id, a in state.sorted_pairs(storage.assignments) do
    local platform = watchdog.platform_of(a)
    if not (platform and platform.valid) then
      watchdog.free_assignment(id, watchdog.ALERT_DESTROYED, fleet.IDLE, tick)
    elseif watchdog.player_edited(a, platform) then
      watchdog.free_assignment(id, watchdog.ALERT_PLAYER_EDIT, fleet.WITHDRAWN, tick)
    elseif watchdog.completed(platform, a) then
      watchdog.free_assignment(id, nil, fleet.IDLE, tick) -- silent: normal delivery
    else
      -- Reset the no-progress clock on stop advances BEFORE testing the deadline,
      -- so a ship that just progressed is never falsely timed out.
      watchdog.note_progress(a, platform, tick)
      if watchdog.expired(a.deadline_tick, tick) then
        watchdog.free_assignment(id, watchdog.ALERT_TIMEOUT, fleet.IDLE, tick)
      else
        watchdog.maybe_reclamp(a, platform, id)
        if watchdog.load_impossible(a, platform) then
          -- The source can no longer supply ANY of the forward manifest (drained
          -- since dispatch -- another ship, manual use, or production consumed it),
          -- so the re-clamp emptied it. Don't sit out the timeout for cargo that
          -- will never arrive: abort, free the ship to idle, and re-open the demand
          -- so the next dispatch re-evaluates (and won't re-dispatch while dry).
          state.debug_log("watchdog abort a#" .. tostring(id)
            .. ": source can't supply the forward manifest -- nothing to load")
          watchdog.free_assignment(id, nil, fleet.IDLE, tick)
        elseif watchdog.delivery_stalled(a, platform) then
          -- Parked at the last stop, still holding manifest cargo, and the drop
          -- planet's RAW request for everything it holds is 0 -- the destination no
          -- longer wants this cargo (the request was removed/satisfied mid-flight).
          -- `completed` was tested first, so a genuine pad-pull already won; here
          -- the pad simply will not pull. Don't loop or sit out the no-progress
          -- deadline: free the ship to idle (silent). By definition the dest's raw
          -- demand is already 0, so there is nothing to "re-open" -- the only residue
          -- is the leftover cargo aboard the idled ship (bounded; reused/cleared on
          -- the next dispatch).
          state.debug_log("watchdog abort a#" .. tostring(id)
            .. ": destination no longer requests the delivered cargo -- idling (residue aboard)")
          watchdog.free_assignment(id, nil, fleet.IDLE, tick)
        else
          -- The assignment SURVIVES this iteration: derive and publish its live
          -- loading/unloading phase. This write is in the surviving path only -- the
          -- load_impossible / delivery_stalled branches above already freed the
          -- ship to IDLE, and that IDLE state write must win, not race a stale
          -- phase. `parked` is `speed == 0` AND `current_is_ours` (a foreign /
          -- unreadable stop reads as not-parked so phase_for yields ENROUTE).
          local sched = platform.schedule
          local current = sched and sched.current
          local parked = (platform.speed or 0) == 0
            and watchdog.current_is_ours(a, sched and sched.records, current)
          local phase = watchdog.phase_for(a, current, parked)
          fleet.set_state(a.ship, phase)
          a.phase = phase
        end
      end
    end
  end

  watchdog.recover_withdrawn()
end

return watchdog
