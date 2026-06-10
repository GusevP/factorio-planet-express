# Planet Express — user stories & flows

What the player can do, and the path each action takes through the mod. Names in
`code font` are the real modules/functions so this doubles as a map from behaviour
to implementation. See `CLAUDE.md` for the module table and `docs/api-notes.md`
for the confirmed engine seams.

## The model in one paragraph

Planet Express turns the player's **own** space platforms into a merchant fleet.
It reads each planet's **native cargo-landing-pad requests** as demand, finds
another planet holding **above-reserve surplus** of the wanted item — matched per
**(item, quality)** and scoped to that planet's **own** logistic network — picks an
**idle enrolled ship**, and writes that ship a two-planet route plus the hub
logistic request that loads the cargo (sized to the ship's real cargo hold). It never spawns, teleports, or inserts —
the only platform mutation is `platform.schedule = …` (and the hub's own logistic
request). Every game-affecting decision is deterministic (stable sorted iteration,
monotonic ids, no wall-clock/RNG) so it is multiplayer- and save/load-safe.

---

## Setup & configuration

### 1. Enroll a platform into the fleet
**As a player, I want to opt a space platform into auto-dispatch, so the mod can
use it for trade — and never touch ships I didn't opt in.**

Flow:
- The `registry` indexes every space platform hub on build / on rebuild into
  `storage.fleet` (all start `enrolled = false`).
- Open the platform hub → the **Fleet** panel (`gui/fleet_tab.lua`, a collapsible
  relative GUI on the hub window) → tick **Enroll**.
- Gated by the **Interplanetary Trade Logistics** technology
  (`fleet.tech_researched`); un-enrolling is always allowed.
- `fleet.set_enrolled` flips `storage.fleet[id].enrolled`. The dispatcher only
  ever considers enrolled, idle, unassigned ships (`fleet.idle_eligible`).

### 2. Restrict a ship to certain destinations
**As a player, I want to keep a ship off planets it can't reach (no Aquilo-grade
thrusters / heat shielding), so it isn't sent on impossible legs.**

Flow:
- Fleet tab → **Allowed destinations**: one checkbox per planet (read live from
  `game.planets`, labelled with `planet.prototype.localised_name`).
- All ticked = unrestricted (stored as `nil`, so newly discovered planets are
  served too); untick any planet to restrict. `fleet.allowed_from_selection`
  collapses "all ticked" back to `nil`, else stores the sorted allow-list.
- `fleet.idle_eligible` requires the ship's allow-list to cover **both** the
  source and the destination of a route, or the ship is skipped for it.

### 3. Reserve a ship for manual use
**As a player, I want to keep an enrolled ship out of auto-dispatch temporarily,
so I can fly it by hand without un-enrolling it.**

Flow:
- Fleet tab → **Reserve for manual use** → `fleet.set_reserve_for_manual_use`.
- `fleet.idle_eligible` returns false while reserved, so the dispatcher won't
  claim it; the ship still shows in the Monitor roster as idle.

### 4. Tune a planet's reserve floor / import preferences
**As a player, I want to keep N of an item on a planet and choose which items the
fleet may source there, so trade doesn't strip a planet bare.**

Flow:
- Open the cargo landing pad → **Trade** tab (`gui/trade_tab.lua`).
- Reserve floor + per-item import flags persist via the `reserves` writers. These
  are keyed by item **name** (quality-independent): a floor or an import opt-out
  applies to **every** quality of that item (call sites `qparse` a `(item, quality)`
  cargo key back to the bare name before reading the reserve/overlay).
- `stock.surplus = stock − reserve` (with min-trip suppression); only
  above-reserve stock is ever exportable.

---

## The trade loop

### 5. A planet's unmet demand is auto-fulfilled from another planet's surplus
**As a player, I want a planet's missing items delivered automatically from
wherever has spare, so I don't hand-fly cargo.**

Flow (per dispatcher tick, `dispatcher.run`):
1. `demand.open_demand` — native pad request − on-hand − in-flight inbound =
   what's still genuinely wanted, keyed per `(item, quality)`.
2. `dispatcher.build_snapshot` — per-planet open demand + above-reserve surplus
   (read from the planet's **own** logistic network, not the whole surface; minus
   surplus already committed to in-flight shipments), the ship list, caps.
3. `dispatcher.plan` (pure, deterministic):
   - `best_source` — the same-force planet covering the most of the demand, guarded
     by `exportable` (story 8), nearest tie-break.
   - `pick_ship` — lowest-id `idle_eligible` ship.
   - `build_manifest` — **fair-share** across demanded `(item, quality)` rows, then
     priority-leftover, clamped to surplus / the ship's real **slot budget** (its hub
     inventory size, packed `ceil(load / stack_size)` slots per item) / unmet — so
     one bulk item can't hog a ship and the manifest always fits the actual hold.
4. `dispatcher.commit` — allocate a monotonic id, write the route + hub request,
   record two-sided bookkeeping (`inbound_commit` on the demand side,
   `surplus_commit` on the supply side), flip the ship to `enroute`.
5. The ship flies to the source, the hub requests the manifest
   (`schedule.apply_hub_request`, scoped via `import_from`, one filter per
   `(item, quality)`), rockets load it, the per-`(item, quality)` `item_count ≥ qty`
   wait condition fires, it flies to the destination, the pad pulls the cargo, and
   it departs (`item_count == 0` / inactivity / timeout).

### 6. Two-way return trade
**As a player, I want a ship to bring something back instead of deadheading, so
trips do double duty.**

Flow:
- When two-way is on and the destination holds surplus the source still needs,
  `dispatcher.return_manifest` builds the return cargo (same two planets, same
  `exportable` guard).
- `schedule.build_records` emits a **3-stop turnaround**:
  `source(load) → dest(TURNAROUND: pad pulls forward while return loads) → source(drop)`.
  One destination stop, so the hub request re-points at a distinct-station advance
  (the watchdog re-pointer can't fire on two consecutive same-station stops).

### 7. Reserves and minimum trip size are respected
**As a player, I want a floor kept on each planet and tiny dribbles suppressed, so
trade is stable.**

Flow: `stock.compute_surplus(stock, reserve, min_trip)` returns 0 below the floor
or below the min-trip threshold; surplus is the input to `exportable`.

### 8. A planet never imports and exports the same item
**As a player, I don't want ships passing each other carrying the same item.**

Flow: `dispatcher.exportable(node, item)` = the node's surplus **only when it has
no open demand** for that item. Both the forward match and the return leg source
candidates exclusively through `exportable`.

### 9. Rocket-capacity-correct payloads
**As a player, I want a request for 50 to deliver ~50, not a whole 400-item
rocket, so a small need doesn't over-drain the source or overshoot the dest.**

Flow: for each requested item, `schedule.rocket_capacity` =
`rocket_lift_weight / item.weight`. When the request is **smaller than one rocket**,
the filter sets `minimum_delivery_count = qty` so the rocket launches with exactly
that; a request of one rocket or more keeps the default full-rocket chunking.

---

## Visibility

### 10. Monitor the fleet
**As a player, I want one screen showing my ships, shipments, waiting demand, and
recent events.**

Flow: the top-bar **shortcut** opens the Monitor (`gui/monitor.lua`), built from a
pure view model (`viewmodel.gather` → `viewmodel.build`): roster (idle / active /
withdrawn), in-flight assignments, waiting demand with a reason, and the alert log.
Clicking a roster ship centres Remote View on its hub (`player.centered_on`).

### 11. Understand *why* a demand isn't moving
**As a player, when something isn't delivered I want to know the actual reason.**

Flow: `viewmodel.classify_waiting` names the blocker, mirroring the dispatcher's
real gates: `in_transit` (a ship is already carrying it) → `no_ship` (a source
exists, no eligible ship) → `source_busy_importing` → `below_min_trip` →
`no_source`. (Dev: `/pe-status` prints the dispatcher's exact per-demand reason.)

---

## Player control & coexistence

### 12. The player edits a ship's schedule — the mod backs off
**As a player, if I take manual control of a fleet ship's schedule, the mod must
stop fighting me.**

Flow: `dispatcher.commit` stamps an order-stable `schedule_signature`. Each tick
`watchdog.player_edited` recomputes it from the live schedule; on mismatch the ship
is **withdrawn** (assignment freed, state `withdrawn`, schedule left untouched) and
`watchdog.recover_withdrawn` returns it to the fleet once it's idle again.

### 13. Ships keep refuelling via the player's interrupts
**As a player, my refuel/rearm interrupts must keep working while the mod runs the
trade route.**

Flow: the mod writes the simplified `platform.schedule` (records only), which
**preserves the player's interrupts**. Its own fuel/ammo logistic sections are left
alone (`apply_hub_request` only touches a manual, ungrouped section). On cleanup it
clears **only the records** (`schedule.clear_route` via `get_schedule():set_records({})`),
never `platform.schedule = nil` (which would drop interrupts too).

---

## Resilience

### 14. A source runs dry, or a destination stops wanting the cargo, mid-trip
**As a player, if the items are taken (another ship, manual use, production) after
a ship is dispatched, it shouldn't sit idle at the source for the full timeout —
and a ship whose destination no longer wants the cargo shouldn't linger at the pad
or loop re-loading.**

Flow (`watchdog`, each tick):
- **Source dry (load side).** While at a load stop, `maybe_reclamp` re-clamps the
  manifest to the source's **live** surplus and rewrites BOTH the hub request and
  the schedule's wait conditions (`schedule.resync_conditions`) so they stay in
  sync — partial availability ships the partial. If the forward manifest empties
  entirely, `load_impossible` is true and the run loop **aborts** the trip: frees
  the ship to idle and re-opens the demand for the next dispatch (which won't
  re-send while dry, and will once the source recovers).
- **Destination stops wanting it (delivery side, symmetric).** While parked at the
  final stop still holding manifest cargo, `delivery_impossible` reads the drop
  planet's **raw** pad request (`requested − on_hand`, NOT the in-flight-netted
  `open_demand`) for everything the ship still holds; if that's 0 the destination
  genuinely no longer wants the cargo, so `delivery_stalled` **aborts**: frees the
  ship to idle (silent). `completed` (story 15) is evaluated FIRST, so a real
  pad-pull always wins; by definition the dest's raw demand is already 0 here, so
  there's nothing to re-open — the only residue is the leftover cargo aboard the
  idled ship (bounded; reused/cleared on the next dispatch).

### 15. A platform is destroyed, or a trip stalls
**As a player, a lost or stuck ship must not leave a phantom assignment.**

Flow: `watchdog.run` rules, in order — destroyed platform → free + alert; player
edit → withdraw; **completed** delivery → free (silent); no-progress past the
deadline → free + alert; otherwise re-clamp (which is also where the load-/
delivery-impossible aborts of story 14 fire). **Completion is now per-manifest, not
whole-hub:** `watchdog.completed` → `manifest_delivered` fires once the ship is
parked (`speed == 0`) and the hub holds **none of OUR cargo** — each forward +
return item, by `(item, quality)` — so a ship carrying its own fuel/ammo/repair
packs still completes instead of waiting on a hub that never reads empty. Freeing an
assignment reverses both bookkeeping sides (they're read live), so the demand
re-opens cleanly.

### 16. Concurrency caps
**As a player, I want to cap how many ships work a route or the whole fleet, so I
don't overcommit.**

Flow: runtime-global settings `max-ships-per-route` (default 5) and
`max-ships-global` (0 = unlimited), enforced in the pure `plan` against the live
in-flight counts (`active_counts`). `0` means unlimited.

---

## Dev / debugging

### 17. `/pe-status`
On-demand dump: settings, every trade node + its open demand, the fleet as the
dispatcher sees it (enrolled / state / reserved / assignment / force / capacity /
allow-list), in-flight count, a cargo-seam probe (hub reachability + the live mod
request, incl. `payload>=`), and a precise per-unserved-demand reason. Independent
of the debug-log setting, also written to `factorio-current.log`.

### 18. `/pe-reset`
Dev convenience: frees every assignment, clears every enrolled ship's mod route +
hub request (keeping interrupts), wipes alerts, and idles the fleet so the next
dispatch re-plans from a clean slate. Leaves un-enrolled (player) ships alone.

---

## Cross-cutting invariants

- **Determinism:** every ordered/decision loop uses `state.sorted_pairs` /
  `state.sorted_keys`; ids come only from `state.next_id`; no `math.random` /
  `os.time` / wall-clock; all persistent state in `storage`.
- **Item quality:** cargo is keyed by `(item, quality)` end-to-end (demand, surplus,
  manifest, hub request, wait conditions, bookkeeping) via the `scripts/qkey.lua`
  compound key, so normal- and uncommon-quality variants of one item trade
  independently and never cross-contaminate. **Reserve floors, import flags, and
  priorities stay keyed by item NAME** (they apply to all qualities); those call
  sites `qparse` the key back to the bare name before reading the reserve/overlay.
- **Two-sided bookkeeping:** each shipment records `inbound_commit` (demand side,
  read by `demand.inbound_for`) and `surplus_commit` (supply side, read by
  `committed_surplus_by_node`); a single assignment deletion reverses both.
- **Pure seam:** decision/view-model math is pure Lua over plain tables (unit-tested
  in `tests/calc_test.lua`); engine calls are thin wrappers around it.
