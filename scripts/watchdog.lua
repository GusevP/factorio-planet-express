-- scripts/watchdog.lua
--
-- The robustness layer: it watches every in-flight assignment and enforces the
-- three invariants from the plan that the happy-path dispatcher does
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
--     for the forward leg, the destination for the two-way return leg), lower its
--     per-stop request to the CURRENT surplus so a stock drop since dispatch
--     can't strip-mine that planet below its reserve.
--   * partial fill: the ship leaves with whatever loaded (its source stop waits
--     on "cargo FULL or timeout"); on delivery the assignment completes
--     and clears its inbound_commit, so any remaining shortfall re-opens and is
--     reconsidered next dispatcher tick (self-correction via recomputed unmet).
--     No mid-flight bookkeeping needed -- it falls out of completion.
--   * thruster fuel is NEVER managed (the player's responsibility); the watchdog
--     only DETECTS "stuck" via the timeout, it never refuels.
--
-- Design split (per the plan's pure-function seam):
--   * `reclamp_amount`, `schedule_signature`, `expired`, `phase_for`, and
--     `signable_records` are PURE over plain tables/scalars -- no engine globals --
--     so they load and run under plain `lua` and are unit-tested. The signature is
--     order-stable (multiplayer determinism: iterate records in order, requests via
--     the sorted helper) per docs/api-notes.md §4.
--   * everything else (the `run` loop, platform-validity / live-schedule /
--     arrival reads, the request rewrite) is thin IO, marked
--     [provisional] against the engine seams, and verified by manual playtest
--     (the Post-Completion checklist: asteroid loss, fuel starvation, mid-flight
--     edit).

local state = require("scripts.state")
local fleet = require("scripts.fleet")
local stock = require("scripts.stock")
local schedule = require("scripts.schedule")

local watchdog = {}

-- `dispatcher` reference, INJECTED at load time -- never resolved by a runtime
-- `require`. Factorio forbids `require` outside control.lua parsing (it raises
-- "Require can't be used outside of control.lua parsing"), and the
-- dispatcher<->watchdog cycle (dispatcher requires watchdog at its top) forbids a
-- plain top-level require here -- watchdog finishes loading BEFORE dispatcher
-- populates its table. So dispatcher hands its fully-built table back via
-- `set_dispatcher` at the very end of its own load (still during control parse).
-- The plain-`lua` test runner injects nothing, so `disp()` falls back to a one-time
-- `require` -- legal there (no Factorio require gate) and the path the pure
-- `flight_sample` tests already exercise.
local dispatcher

local function disp()
  if not dispatcher then
    dispatcher = require("scripts.dispatcher")
  end
  return dispatcher
end

function watchdog.set_dispatcher(d)
  dispatcher = d
end

-- Watchdog cadence, in ticks -- the REAL period control.lua registers the
-- watchdog `run` loop on (a constant, so it is peer-identical). Kept independent
-- of the dispatcher interval so the two seams are greppable; both firing on the
-- same tick is harmless (deterministic), and control.lua shares one handler when
-- the periods coincide.
watchdog.INTERVAL = 300 -- 5s at 60 UPS

-- Alert kinds recorded in `storage.alerts` for the monitor GUI.
watchdog.ALERT_DESTROYED = "ship_destroyed"
watchdog.ALERT_TIMEOUT = "timeout"
watchdog.ALERT_PLAYER_EDIT = "player_edit"
-- A timeout whose CAUSE is the ready-signal gate (v1.2): the ship held at a stop
-- because `planet-express-ready <= 0` the whole no-progress window. Distinct from a
-- fuel/path strand so the Monitor names WHY it is stuck.
watchdog.ALERT_READY_HELD = "ready_held"
-- The player (or another mod) paused the platform's thrust. Per the 2.0 API,
-- `LuaSpacePlatform.paused` means the platform "has paused thrust and does not
-- advance its schedule" -- so the ship can NEVER reach its next stop, however fast it
-- is still coasting. Distinct from a timeout: nothing is broken, the ship has simply
-- been taken out of service by hand.
watchdog.ALERT_THRUST_PAUSED = "thrust_paused"

-- How many alerts to retain in `storage.alerts`. The Monitor only ever displays
-- the newest handful (viewmodel.MAX_ALERTS = 20); we keep a bounded backlog so a
-- long game with recurring asteroid losses / fuel-starvation timeouts can't grow
-- the save indefinitely. Oldest are evicted first (see raise_alert).
watchdog.MAX_ALERTS = 100

-- No-progress deadline window (ticks) fallback. The dispatcher stamps the real
-- window on each assignment (`deadline_window`); this covers older saves.
-- It must exceed a single leg's travel PLUS the per-stop wait timeout, because
-- `schedule.current` only advances at a stop boundary (it is the index of the
-- current DESTINATION, not an arrival flag), so a long inter-planet leg shows no
-- progress mid-travel and must not be mistaken for a stuck ship. Sized as the
-- per-stop wait timeout (18000) + a 18000-tick travel budget.
watchdog.DEADLINE_WINDOW = 36000

-- EMA smoothing weight for the learned per-ship `eta_factor` (v1.1). Each flight
-- sample blends the freshly-measured `ratio` in at this weight: a low alpha
-- smooths noise but adapts slowly; 0.3 lets a freshly-upgraded (faster) ship's
-- factor converge within a single trip's worth of samples. Tunable in-engine.
watchdog.EMA_ALPHA = 0.3

-- Minimum progress (in the connection's 0..1 fraction) a flight sample must cover
-- before it yields a speed reading (v1.1). A near-stuck ship advancing a sliver
-- over a whole watchdog window measures `actual_speed ~= 0` -> an absurd ratio;
-- requiring a real delta (not merely `> 0`) keeps that noise out of the EMA.
-- Tunable in-engine.
watchdog.MIN_DELTA = 0.01

-- Sane band for a measured speed `ratio` before it feeds the EMA (v1.1).
-- `NOMINAL_SPEED / actual_speed` for a healthy ship sits near 1; a degenerate
-- near-zero `actual_speed` (a sliver of progress over a long window) or a wildly
-- fast reading would otherwise drag the factor ~alpha in a single step, which the
-- factor's own `> 0` floor does NOT catch. Clamping the ratio here does.
watchdog.RATIO_MIN = 0.25
watchdog.RATIO_MAX = 4

-- ---------------------------------------------------------------------------
-- pure math (testable; no engine globals)
-- ---------------------------------------------------------------------------

-- PURE: EMA-update a ship's learned ETA factor. `factor = old*(1-a) + ratio*a`,
-- blending the freshly-measured speed `ratio` (NOMINAL_SPEED / actual_speed)
-- into the running estimate at weight `alpha` (default EMA_ALPHA). A nil/absent
-- `old` starts from the neutral 1.0; the result is clamped strictly > 0 so a
-- degenerate ratio can never zero out (or invert) an ETA. The sampler is
-- responsible for clamping `ratio` into a sane band BEFORE calling this (a
-- near-stuck ship would otherwise feed an absurd ratio); this only enforces the
-- hard > 0 floor.
function watchdog.ema_factor(old, ratio, alpha)
  local a = alpha or watchdog.EMA_ALPHA
  local prev = old or 1.0
  local r = ratio or prev
  local next_factor = prev * (1 - a) + r * a
  if next_factor <= 0 then
    return prev > 0 and prev or 1.0
  end
  return next_factor
end

-- The shared baseline space speed lives on the scorer side (`dispatcher`), read
-- through the load-time-injected reference (`disp()`) so the constant keeps a
-- single source of truth (the sampler's `ratio` must use the SAME nominal the
-- `predicted_ticks` scorer does, or the learned factor mis-calibrates).
local function nominal_speed()
  return disp().NOMINAL_SPEED
end

-- PURE: a speed-calibration `ratio` from two in-flight cursor samples, or `nil`
-- when the pair can't yield a trustworthy reading (v1.1). `prev` / `cur` are
-- `{ connection, distance, tick }` cursors -- `connection` is the connection NAME
-- string (a stable id across save/load), `distance` is the engine's 0..1 position
-- on the connection's FIXED `from`->`to` axis (0=from, 1=to per the 2.0 docs --
-- NOT progress-in-travel-direction), `tick` is the sample tick -- and `length` is
-- that connection's km length (read from the distance map by the IO, so the helper
-- stays unit-closed). It computes
--   actual_speed = |Δdistance| * length / Δtick     (km/tick)
--   ratio        = clamp(NOMINAL_SPEED / actual_speed, RATIO_MIN, RATIO_MAX)
-- which the EMA folds into `eta_factor`. The delta is taken as a MAGNITUDE because
-- a RETURN leg (`to`->`from`) traverses the fixed axis DOWNWARD (Δdistance < 0); the
-- flight speed is the same either way, so signing it would make every return-leg
-- sample fail the gate and never calibrate. Returns `nil` unless BOTH samples are
-- on the SAME connection, `|Δdistance| >= MIN_DELTA`, and `Δtick > 0` -- so a
-- connection change, a near-stuck ship, or a zero/negative time gap is SKIPPED
-- rather than poisoning the factor. Deterministic float math (no random /
-- wall-clock); the ratio clamp is the guard the factor's `> 0` floor cannot provide.
function watchdog.flight_sample(prev, cur, length)
  if not (prev and cur) then
    return nil
  end
  -- same connection: a cursor from a different leg (or no prior connection) can't
  -- be differenced against this one.
  if prev.connection == nil or prev.connection ~= cur.connection then
    return nil
  end
  local dd = (cur.distance or 0) - (prev.distance or 0)
  local moved = dd < 0 and -dd or dd -- magnitude: a return leg counts the axis down
  if moved < watchdog.MIN_DELTA then
    return nil
  end
  local dt = (cur.tick or 0) - (prev.tick or 0)
  if dt <= 0 then
    return nil
  end
  local actual_speed = moved * (length or 0) / dt
  if actual_speed <= 0 then
    return nil -- degenerate (non-positive length) -> no reading
  end
  local ratio = nominal_speed() / actual_speed
  if ratio < watchdog.RATIO_MIN then
    return watchdog.RATIO_MIN
  elseif ratio > watchdog.RATIO_MAX then
    return watchdog.RATIO_MAX
  end
  return ratio
end

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
-- expires (defensive -- every assignment is created with one).
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
-- CANONICALIZATION RULE (load-bearing): every field the engine MATERIALIZES a
-- default for on readback must serialize identically to the commit-time form, or
-- every freshly written schedule mismatches its own live readback on the first
-- watchdog tick and is falsely withdrawn as a player edit. The signature therefore
-- covers ONLY what the 2.0 schedule readback round-trips RELIABLY: the route
-- STATIONS, each record's per-stop `requests`, and each wait condition's `type` /
-- `ticks` / `compare_type` (compare_type absent -> "and", the engine default).
--
-- It DELIBERATELY does NOT sign the `item_count` condition payload (comparator /
-- first_signal / constant) or `allows_unloading`: in-engine those do NOT round-trip
-- verbatim -- the readback normalizes allows_unloading and the circuit-condition
-- fields differently than the mod wrote them -- so signing them made EVERY
-- mod ship mismatch its own schedule the tick after dispatch and be falsely
-- withdrawn as a "player edit", which cleared its hub request and stalled ALL
-- deliveries (playtest 2026-06-10). A player RE-ROUTING the ship still changes the
-- station / condition-type sequence and is detected; a mere wait-quantity tweak is
-- harmlessly re-asserted by `resync_conditions` instead of fought over.
-- Pure over plain record tables (the §1 agnostic shape from schedule.lua).
function watchdog.schedule_signature(records)
  local parts = {}
  for _, rec in ipairs(records or {}) do
    parts[#parts + 1] = "@" .. tostring(rec.station)
    local reqs = {}
    for item, qty in state.sorted_pairs(rec.requests or {}) do
      reqs[#reqs + 1] = item .. "=" .. tostring(qty)
    end
    parts[#parts + 1] = "r[" .. table.concat(reqs, ",") .. "]"
    local conds = {}
    for _, c in ipairs(rec.wait_conditions or {}) do
      conds[#conds + 1] = table.concat({
        tostring(c.type),
        tostring(c.ticks or ""),
        tostring(c.compare_type or "and"),
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

-- Why did this ship stop making progress? Read straight off the engine's own
-- `platform.state` at the moment the no-progress window ran out, so the Monitor can
-- say something actionable instead of a bare "stuck" the player has to guess at.
-- Returns a short key the GUI resolves to `planet-express.strand-<key>`; the
-- `ready_held` caller already knows the ready-signal gate held it. `defines` is
-- absent under the pure test runner -> "unknown" rather than an error.
function watchdog.strand_reason(platform, ready_held)
  if ready_held then
    return "ready"
  end
  local d = defines and defines.space_platform_state
  local s = platform and platform.valid and platform.state
  if not (d and s) then
    return "unknown"
  end
  if s == d.no_path then
    return "no_path"
  elseif s == d.no_schedule then
    return "no_schedule"
  elseif s == d.paused then
    return "paused"
  elseif s == d.on_the_path then
    return "no_thrust" -- following the path but got nowhere: out of thruster fuel
  elseif s == d.waiting_at_station then
    return "waiting" -- parked with a wait condition that never cleared
  end
  return "unknown"
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
    -- Clear the flight sampler cursor so the ship's NEXT trip starts a fresh
    -- same-connection sample window. Otherwise the cursor outlives this freed
    -- assignment and a later trip on the SAME connection differences its first
    -- sample against this trip's stale distance/tick -- a huge Δtick and a
    -- cross-trip Δdistance poison the first measured rate / eta_factor. Mirrors
    -- `sample_flight`'s reset on park / connection change; freeing is the third
    -- lifecycle reset point.
    fleet.set_eta_sample(a.ship, nil)
    fleet.set_assignment(a.ship, nil)
    fleet.set_state(a.ship, ship_state or fleet.IDLE)
  end
  storage.assignments[id] = nil
  if reason then
    watchdog.raise_alert(reason, id, tick, {
      ship = a.ship,
      source = a.source_planet,
      dest = a.dest_planet,
      -- The assignment's force key: lets the Monitor scope this alert to
      -- the owning force. Nil on older assignments -> the alert is visible to
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
-- older save) or an unreadable live schedule => not accused.
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

-- The roundtrip-done gate: the ship has ARRIVED and PARKED at its final stop -- the
-- final stop is the active destination (`schedule.current >= #records`) and the ship
-- is no longer moving (`speed == 0`). The run loop frees the assignment here: the
-- landing pad auto-delivers the carried cargo to the planet whether the ship is on a
-- schedule or idle, so there is no need to read the hub or the destination's demand
-- (a delivered item can overlap the platform's own construction/fuel stock and never
-- clear). Engine-read-thin over `platform.schedule`/`speed`; an unreadable (nil)
-- speed reads as 0 (parked). Returns false on any unreadable schedule seam.
function watchdog.parked_at_last_stop(platform)
  local sched = platform and platform.valid and platform.schedule
  local records = sched and sched.records
  if not (records and #records > 0) then
    return false
  end
  if (sched.current or 0) < #records then
    return false -- the final stop is not yet the active destination
  end
  if (platform.speed or 0) ~= 0 then
    return false -- still moving toward it
  end
  -- AT the final station, not merely released toward it. `current` flips to the
  -- final record the instant the PREVIOUS stop's wait clears, while the platform is
  -- still sitting there at speed 0 for the first ticks of acceleration -- so
  -- `current >= #records and speed == 0` also matched a ship that had just departed,
  -- and freeing it there cleared the route with the cargo still aboard (a two-way
  -- trip's return load, or a one-way load leaving the source). Compare the planet the
  -- platform is actually at against the final record's station; nil (in transit)
  -- never matches.
  local at = platform.space_location
  return at ~= nil and at.name == records[#records].station
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
  -- MOVING IS PROGRESS. `schedule.current` only advances at a stop boundary, so a
  -- healthy ship shows no INDEX progress for the whole of an inter-planet leg; any
  -- leg (plus the stop wait that follows it) longer than the no-progress window was
  -- therefore freed MID-FLIGHT -- which cut the engines, left the route cleared and
  -- the cargo stranded aboard, and flagged the ship "stuck" until the next dispatch
  -- picked it up again. Sizing the window bigger only moves the cliff; the real test
  -- is whether the ship is physically getting anywhere. A genuinely stuck ship (no
  -- thruster fuel, no path, held at a stop) sits at speed 0 and still times out.
  -- Checked BEFORE the interrupt guard below: a ship flying a refuel interrupt is
  -- making progress too.
  if (platform.speed or 0) ~= 0 then
    a.deadline_tick = tick + (a.deadline_window or watchdog.DEADLINE_WINDOW)
  end
  -- Interrupt guard: only act on a stop that is one of OUR route stations. A
  -- refuel/rearm INTERRUPT can splice in its own record(s) (the simplified schedule
  -- the mod wrote excludes interrupts), shifting `current` onto a station we never
  -- wrote; re-pointing the single hub request off that foreign index (stop_request
  -- keys by index) would request the wrong leg's cargo. Skip WITHOUT touching the
  -- request -- it self-corrects once the ship is back on one of our stops.
  -- (Interrupt behavior still-to-confirm in-engine -- docs/api-notes.md §1.)
  if not watchdog.current_is_ours(a, sched and sched.records, current) then
    return
  end
  -- Re-point the single global hub request to whatever the CURRENT stop should load
  -- (forward at the source, the return manifest at the return-load stop, cleared on
  -- unload/drop -- see `stop_request`) EVERY tick the ship is on one of our stops --
  -- NOT only on a monotonic advance. `progress_index` advances one-way, so an
  -- advance-only re-point could never move the request BACK: a refuel/rearm interrupt
  -- that bounces `current` off the forward load stop (advancing it to the return leg
  -- and back) would strand the request on the RETURN manifest, so the forward cargo
  -- is never requested and the ship waits out the timeout with a partial load.
  -- (Observed: a Gleba->Nauvis two-way trip parked at the Gleba load stop still
  -- requesting biter-egg FROM NAUVIS -- the return leg.) Re-pointing by `current`
  -- every tick self-heals it; the write is idempotent when the request already matches.
  local manifest, import_from = watchdog.stop_request(a, current)
  if watchdog.rewrite_source_request(platform, manifest, import_from) == false then
    return -- hub unreachable; retry next tick (the no-progress deadline still trips)
  end
  -- Reset the no-progress deadline ONLY on a genuine ADVANCE to a new stop. The
  -- deadline is a NO-PROGRESS watchdog (a stuck ship is freed); re-pointing the
  -- request on a steady `current` must not keep resetting it, or a stuck ship would
  -- never time out. At the source (stop 1) the request is then refined by
  -- `maybe_reclamp`, which runs after note_progress in the tick loop.
  if watchdog.advanced(a.progress_index, current) then
    a.progress_index = current
    a.deadline_tick = tick + (a.deadline_window or watchdog.DEADLINE_WINDOW)
  end
end

-- A SpaceLocationID is recorded as a name string, but stay robust if the runtime
-- hands back the prototype object instead (provisional seam) -- pull `.name` off a
-- table, pass a string through. Mirrors dispatcher.loc_name (kept local to each
-- module rather than exported, to avoid widening the seam).
local function loc_name(x)
  if type(x) == "table" then
    return x.name
  end
  return x
end

-- IO (thin, engine-touching; v1.1 continuous flight sampler): fold ONE flight
-- observation into the ship's learned `eta_factor`, calibrating it against reality
-- every watchdog tick the ship is travelling. Reads the ship's `space_connection`
-- (nil = parked / not on a connection), its 0..1 `distance`, and the current
-- `tick` into a `{ connection = NAME, distance, tick, rate }` cursor; differences it
-- against the stored `eta_sample` via the PURE `flight_sample` helper (using the
-- connection's km `length` looked up in the distance map, so the unit math stays
-- on the pure side); EMA-updates `eta_factor` when a trustworthy ratio comes back;
-- then stores the new cursor -- which also carries the measured Δdistance/Δtick
-- progress-rate the Monitor ETA reads (so the display reads a STORED rate instead
-- of re-differencing live at a tick the watchdog already advanced). The cursor is
-- RESET (cleared) when the ship is parked or has switched to a different connection,
-- so the next sample differences a clean same-connection pair rather than across a
-- gap. `space_connection` / `.distance` are [provisional] seams (docs/api-notes.md
-- §7) -- playtest-verified. `dispatcher` is read through the load-time-injected
-- reference (`disp()`); a runtime `require` is illegal in Factorio.
function watchdog.sample_flight(a, platform, tick)
  local entry = a and a.ship and fleet.get(a.ship)
  if not entry then
    return
  end
  local conn = platform.space_connection
  if not conn then
    -- parked / between legs: clear the cursor so a fresh departure starts a new
    -- same-connection sample window instead of differencing across the gap.
    if entry.eta_sample ~= nil then
      fleet.set_eta_sample(a.ship, nil)
    end
    return
  end
  local name = conn.name
  local cur = { connection = name, distance = platform.distance or 0, tick = tick }
  local prev = entry.eta_sample
  if prev and prev.connection == name then
    -- Record the measured progress-rate (Δdistance/Δtick) ON the cursor so the
    -- Monitor's ETA reads a STORED rate rather than re-differencing live: the
    -- watchdog and the Monitor refresh co-fire on the SAME tick under the default
    -- (equal) cadence, where a live re-difference has a zero Δtick and yields no
    -- rate. nil until the second same-connection sample (~one watchdog interval).
    local dt = tick - (prev.tick or 0)
    if dt > 0 then
      cur.rate = (cur.distance - (prev.distance or 0)) / dt
    end
    local d = disp()
    local length = d.distance(d.distances(), loc_name(conn.from), loc_name(conn.to))
    -- Only calibrate off a REAL mapped length; a fallback (missing pair) would
    -- make `actual_speed` absurd and the ratio clamp would silently pin the factor.
    if length < d.DISTANCE_FALLBACK then
      local ratio = watchdog.flight_sample(prev, cur, length)
      if ratio then
        fleet.set_eta_factor(a.ship, watchdog.ema_factor(entry.eta_factor, ratio))
      end
    end
  end
  fleet.set_eta_sample(a.ship, cur)
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
    a.manifest, a.return_manifest, a.wait_timeout, a.gate_ready)
  a.schedule_signature = watchdog.read_signature(platform) -- our edit, not the player's
  state.debug_log("watchdog reclamp a#" .. tostring(a.ship))
end

-- Keep each LOAD stop clamped to its planet's CURRENT surplus while the ship sits
-- on that stop, so a stock drop since dispatch can't strip-mine below the
-- reserve. `schedule.current` is only the index of the current DESTINATION -- it
-- covers BOTH the transit toward a stop AND parking on it, NOT the instant of
-- arrival -- so rather than re-clamp once "on arrival" we re-clamp EVERY tick the
-- ship is on a load stop: the forward load at the source (stop 1) and the two-way
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
    -- return leg: the destination turnaround stop loads the return cargo,
    -- so honor the DESTINATION reserve here -- a stock drop at the destination
    -- before the ship loads could otherwise export it below its own reserve.
    reclamp_leg(a, platform, id, a.dest, a.dest_planet, a.return_manifest, function(m)
      a.return_manifest = m
    end)
  end
end

-- ---------------------------------------------------------------------------
-- on-demand diagnostics (read-only; /pe-status)
-- ---------------------------------------------------------------------------

-- Reverse `defines.space_platform_state` (value -> name), built on first use. The
-- numeric state alone is useless in a bug report; the name is the whole point.
local state_names
local function platform_state_name(s)
  if s == nil then
    return "nil"
  end
  if not state_names then
    state_names = {}
    for name, value in pairs((defines and defines.space_platform_state) or {}) do
      state_names[value] = name
    end
  end
  return state_names[s] or ("?" .. tostring(s))
end

-- Which `run` branch would fire for this assignment RIGHT NOW, evaluated in the
-- same order as the tick loop. This is the single most useful line in a bug report:
-- it says what the watchdog is about to do, rather than leaving it to be inferred
-- from the raw fields. Read-only -- it decides nothing and writes nothing.
local function pending_branch(a, platform, tick)
  if not (platform and platform.valid) then
    return "FREE (destroyed/invalid platform)"
  elseif watchdog.player_edited(a, platform) then
    return "WITHDRAW (schedule signature differs -- player edit)"
  elseif watchdog.parked_at_last_stop(platform) then
    return "COMPLETE (parked at final stop)"
  elseif platform.paused == true then
    return "WITHDRAW (thrust paused)"
  elseif watchdog.expired(a.deadline_tick, tick) then
    return "FREE (no-progress deadline expired)"
  elseif watchdog.load_impossible(a, platform) then
    return "ABORT (source cannot supply the forward manifest)"
  end
  return "keep (in transit / working a stop)"
end

-- Dump everything the watchdog reads, per in-flight assignment, as plain lines.
-- Written for a bug report from a save that already contains the fault: it prints
-- the raw engine reads AND the branch they resolve to, so a stuck ship can be
-- diagnosed without reproducing it. Strictly read-only.
function watchdog.diagnose(tick)
  local out = {}
  local function add(fmt, ...)
    out[#out + 1] = string.format(fmt, ...)
  end
  local assignments = storage and storage.assignments or {}
  if next(assignments) == nil then
    add("watchdog: no in-flight assignments")
  end
  for id, a in state.sorted_pairs(assignments) do
    local platform = watchdog.platform_of(a)
    local entry = a.ship and fleet.get(a.ship) or nil
    add("a#%s ship=%s %s -> %s  phase=%s progress_index=%s",
      tostring(id), tostring(a.ship), tostring(a.source_planet), tostring(a.dest_planet),
      tostring(a.phase), tostring(a.progress_index))
    add("  deadline: tick=%s now=%s remaining=%s window=%s",
      tostring(a.deadline_tick), tostring(tick),
      tostring(a.deadline_tick and tick and (a.deadline_tick - tick)), tostring(a.deadline_window))
    if entry then
      add("  fleet: state=%s stranded=%s reason=%s thrust_paused=%s enrolled=%s require_ready=%s",
        tostring(entry.state), tostring(entry.stranded), tostring(entry.stranded_reason),
        tostring(entry.thrust_paused), tostring(entry.enrolled), tostring(entry.require_ready))
    else
      add("  fleet: NO ENTRY for ship key %s", tostring(a.ship))
    end
    if platform and platform.valid then
      local sched = platform.schedule
      local records = sched and sched.records or {}
      local stations = {}
      for i, rec in ipairs(records) do
        stations[#stations + 1] = string.format("%d:%s%s%s", i, tostring(rec.station),
          rec.temporary == true and "(temp)" or "",
          rec.created_by_interrupt == true and "(interrupt)" or "")
      end
      add("  platform: state=%s paused=%s speed=%s distance=%s",
        platform_state_name(platform.state), tostring(platform.paused),
        tostring(platform.speed), tostring(platform.distance))
      add("  where: location=%s connection=%s",
        tostring(platform.space_location and platform.space_location.name),
        tostring(platform.space_connection and platform.space_connection.name))
      add("  schedule: current=%s of %d [%s]",
        tostring(sched and sched.current), #records, table.concat(stations, " "))
      -- The player-edit test is the likeliest silent misfire, so show BOTH sides
      -- rather than just the verdict.
      local live = watchdog.read_signature(platform)
      add("  signature match=%s", tostring(live == a.schedule_signature))
      if live ~= a.schedule_signature then
        add("    stored=%s", tostring(a.schedule_signature))
        add("    live  =%s", tostring(live))
      end
    else
      add("  platform: INVALID / destroyed")
    end
    add("  => would %s", pending_branch(a, platform, tick))
  end
  return out
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
    if entry.state == fleet.WITHDRAWN then
      -- Two different withdrawals, two different recovery tests:
      --   * thrust-paused -> recover as soon as thrust resumes. Its route was left
      --     intact on purpose (clearing it mid-flight is the 2.1.4 bug), so the
      --     platform_idle test below would never fire and it would stay withdrawn
      --     forever.
      --   * player edit -> recover once the player's schedule is idle again.
      local platform = entry.platform
      local recovered
      if entry.thrust_paused == true then
        recovered = not (platform and platform.valid and platform.paused == true)
        if recovered then
          fleet.set_paused(id, false)
        end
      else
        recovered = watchdog.platform_idle(platform)
      end
      if recovered then
        fleet.set_state(id, fleet.IDLE)
        state.debug_log("watchdog recovered withdrawn ship#" .. tostring(id))
      end
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
    elseif watchdog.parked_at_last_stop(platform) then
      -- ROUNDTRIP DONE. The ship has arrived and parked at its FINAL stop, so its
      -- job is over. The landing pad auto-delivers the carried cargo to the planet
      -- whenever a platform is in orbit -- on a schedule or idle alike -- so we do
      -- NOT wait for the hub to read empty (a delivered item can overlap the
      -- platform's own construction/fuel stock and never clear) and we do NOT worry
      -- about under-unload: free the ship now and the pad finishes pulling on its
      -- own. Any over-delivery residue / own stock rides along (bounded); the
      -- dispatcher re-evaluates this idle ship next tick. Freeing also clears the
      -- mod route + hub request, so the cyclic schedule can't loop it around again.
      watchdog.free_assignment(id, nil, fleet.IDLE, tick)
      -- Delivered: a previously-stranded ship has recovered, so clear the flag
      -- (it just completed a roundtrip -- it is demonstrably not stuck).
      fleet.set_stranded(a.ship, false)
    elseif platform.paused == true then
      -- THRUST PAUSED (checked after completion, so a trip that already finished still
      -- completes). `paused` means the engine will not advance the schedule, so this
      -- ship cannot reach its next stop no matter how fast it is still coasting -- and
      -- because it IS still moving, the speed-based progress reset below would keep the
      -- no-progress deadline alive forever, leaving it "en route" indefinitely with its
      -- manifest committed and the destination starving (playtest 2026-08-11).
      --
      -- WITHDRAWN, not IDLE: pausing thrust is a deliberate player action, and the mod's
      -- rule is that the player wins -- withdrawing releases the manifest so another ship
      -- can cover the demand, while `free_assignment` deliberately skips `clear_route`
      -- for WITHDRAWN, so the route survives and the ship resumes it when un-paused.
      -- Clearing it here would cut the engines mid-flight, which is the very bug 2.1.4
      -- fixed.
      watchdog.free_assignment(id, watchdog.ALERT_THRUST_PAUSED, fleet.WITHDRAWN, tick)
      -- Flags the ship so the Monitor says "thrust paused" instead of a bare
      -- "withdrawn", and so `recover_withdrawn` knows to return it on un-pause (its
      -- route is intact, so the platform_idle rule would never fire for it).
      fleet.set_paused(a.ship, true)
    else
      -- Reset the no-progress clock on stop advances BEFORE testing the deadline,
      -- so a ship that just progressed is never falsely timed out.
      watchdog.note_progress(a, platform, tick)
      if watchdog.expired(a.deadline_tick, tick) then
        -- Name the cause: a ship gated by its ready signal that held for the whole
        -- window (require_ready on AND `planet-express-ready <= 0` now) is stuck
        -- BECAUSE of the gate, not a fuel/path strand -- so the Monitor can say so.
        local entry = fleet.get(a.ship)
        local ready_held = entry and entry.require_ready == true
          and fleet.read_ready_value(platform) <= 0
        watchdog.free_assignment(id,
          ready_held and watchdog.ALERT_READY_HELD or watchdog.ALERT_TIMEOUT, fleet.IDLE, tick)
        -- Flag the freed ship STRANDED so the Monitor's "stuck" count surfaces it.
        -- It was just released to idle, but it made no progress for a full deadline
        -- (no fuel / no rockets / blocked / held by its ready signal), so it is stuck,
        -- not merely idle. Cleared once it next reaches a load/unload stop (below) or
        -- completes a delivery. The reason rides along so the roster can name it.
        fleet.set_stranded(a.ship, true, watchdog.strand_reason(platform, ready_held))
      else
        -- Continuous flight calibration (v1.1): fold this tick's travel into the
        -- ship's learned eta_factor (no-op when parked/loading -- it clears the
        -- cursor then). Runs after the completion/timeout checks, before reclamp.
        watchdog.sample_flight(a, platform, tick)
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
        else
          -- The assignment SURVIVES this iteration (in transit, or loading at a
          -- source / turnaround stop): publish the live loading/unloading phase.
          -- `parked` is `speed == 0` AND `current_is_ours` (a foreign / unreadable
          -- stop reads as not-parked so phase_for yields ENROUTE).
          local sched = platform.schedule
          local current = sched and sched.current
          local parked = (platform.speed or 0) == 0
            and watchdog.current_is_ours(a, sched and sched.records, current)
          local phase = watchdog.phase_for(a, current, parked)
          fleet.set_state(a.ship, phase)
          a.phase = phase
          if phase ~= fleet.ENROUTE then
            -- Parked at one of OUR stops loading/unloading -> real progress, so a
            -- previously-stranded ship is no longer stuck. ENROUTE alone does NOT
            -- clear it: a stranded ship re-dispatched reads ENROUTE but still can't
            -- fly, so it must stay stuck until it physically works a stop.
            fleet.set_stranded(a.ship, false)
          end
        end
      end
    end
  end

  watchdog.recover_withdrawn()
end

return watchdog
