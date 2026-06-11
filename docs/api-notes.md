# Planet Express — Factorio 2.0 / Space Age API notes

Verified read/write engine seams for the IO wrappers. **This file is the hard
gate for every IO wrapper:** a wrapper task must not write engine-touching code
until the seam it needs is recorded here. Each entry lists the accessor, the
data shape, its **caveats**, and the task(s) it gates.

> Status legend:
> **[confirmed]** — verified against the running engine / official 2.0 docs.
> **[provisional]** — best-known signature from the 2.0 API; the named caveat
> MUST be re-checked in-engine when the gated task is implemented. Provisional
> entries still unblock the *pure* calc work (the math is engine-independent);
> they only gate the thin IO wrapper, where a quick in-game check confirms the
> exact call before it ships.

Engine context: Factorio **2.0** with the **Space Age** expansion. Space Age is
the only configuration that has planets, Cargo Landing Pads, and space
platforms, so every seam below assumes `space-age` is active (declared as a hard
dependency in `info.json`).

---

## 1. `LuaSpacePlatform.schedule` — route + per-stop cargo  → gates Task 4 / 5 / 7

**[provisional — confirm record shape + cargo-request mechanism in-engine before Task 4 ships]**

A space platform is `LuaSpacePlatform` (reachable from its hub entity via
`entity.surface.platform`, or by iterating `force.platforms`). Its travel route
is a **schedule** of records, each record targeting a **space location** (a
planet or the orbit of one) plus **wait conditions**.

In 2.0 the schedule is exposed as a structured object rather than a single
read/modify/write table. The relevant pieces:

- **Read:** `platform.schedule` returns the current schedule (records + the
  index of the current record). Treat the returned value as a snapshot — build a
  new desired schedule and assign/apply it rather than mutating in place.
- **Write: [confirmed in-engine, 2.0.77]** `platform.schedule` is a read/write
  **`PlatformSchedule` PLAIN TABLE** (`{ current, records }`), NOT a `LuaSchedule`.
  It is set by **ASSIGNING a new table** (`platform.schedule = { current = 1,
  records = … }`); assign `nil` to clear. It cannot be mutated in place. (The
  earlier note here claimed the opposite — `set_records`/`get_records`/
  `go_to_station` — which is the `LuaSchedule` returned by `platform.get_schedule()`,
  a DIFFERENT object. Using it on `platform.schedule` silently returned false and
  blocked every dispatch. Fixed 2026-06.) The watchdog reads the live schedule the
  same way: `platform.schedule.records` / `.current`. The pure builder
  (`scripts/schedule.lua`) produces a **plain agnostic table** (`{station,
  wait_conditions, requests}`); the thin wrapper strips `requests` (not a record
  field — see below) and assigns the cleaned records; cargo is realized via the
  hub requester logistic request.

**Record shape (the pure builder targets this):**

```
record = {
  station       = <planet/space-location name as string>,  -- the stop
  -- OR a SpaceLocation-style target; confirm whether platforms key stops by
  --    space-location name string vs. a {type, name} target in-engine.
  wait_conditions = {
    { type = "full",  ... }   -- "cargo full" at the source (load complete)
    -- and/or
    { type = "empty", ... }   -- "cargo empty" at the destination (unload done)
    { type = "time",  ticks = <timeout> }   -- the mandatory timeout (invariant #1)
  },
  temporary = false,
}
```

Wait-condition `type` tokens: **[confirmed, 2.0.77]** `WaitCondition` is
`{type=WaitConditionType, compare_type="and"|"or", ticks=uint?, condition=CircuitCondition?}`
and multiple conditions in one record combine via the per-condition `compare_type`.
Departure is gated on the **MANIFEST items only**, via per-item **`"item_count"`**
conditions (each carries a `condition = {comparator, first_signal={type="item",
name, quality}, constant}` — the `first_signal` carries the QUALITY variant decoded
from the cargo qkey, Task 11 #4d, so the item_count reads the exact quality the mod
shipped; a bare item-name key decodes to `"normal"`), NOT the whole-hold
`"full"`/`"empty"`: a platform hub also
holds the platform's own fuel/ammo/repair-packs, so `"full"` stalls on a partial
load (a manifest is `min(surplus, capacity, unmet)`, usually < hold capacity —
capacity is a SLOT budget since Task 6/7, so the per-item clamp ≈
`min(surplus, free_slots × stack_size, unmet)` packed slot-aware) and
`"empty"` never fires while that fuel/ammo sits in the hold. So:
- **load stop** — `item_count >= qty` per manifest item (AND), `OR time`.
- **unload stop** — `item_count == 0` per manifest item (AND), `OR time` (native
  landing-pad pull drains them).
`time` (with `ticks`) is the mandatory timeout backstop (`compare_type = "or"`).
Conditions are emitted in stable item order (determinism). **[one assumption to
re-confirm in-engine: that `item_count` evaluates the platform HUB cargo; if not,
the stop falls back to the `time` timeout — no regression, just slow.]** Resolved
2026-06 (was `"full"`/`"empty"`, which the player correctly flagged as wrong for
ships carrying their own fuel/ammo).

**Per-stop cargo request — RESOLVED to mechanism (b), hub logistic sections.**
**[confirmed]** A 2.0 `ScheduleRecord` is `{station, rail, rail_direction,
wait_conditions, temporary, created_by_interrupt, allows_unloading}` — there is
**no `requests` / cargo field on the record**. So per-stop cargo is NOT
schedule-record-bound (option (a) is ruled out). Cargo is expressed on the
platform **hub** as **logistic sections** (`LuaLogisticSections` on the hub's
requester `LuaLogisticPoint`,
`hub.get_logistic_point(defines.logistic_member_index.space_platform_hub_requester)`).
The wrapper (`schedule.apply_hub_request`) sets the hub's requester section to the
manifest quantities (`section.set_slot(i, {value={type="item", name, quality},
min=qty})`); vanilla rockets then launch the goods up.

> **Quality at the request seam (Task 11, #4d) [provisional — confirm
> `value.quality` on the hub requester in-engine].** The manifest is keyed by the
> OPAQUE cargo `qkey(item, quality)`; `apply_hub_request` DECODES it at this
> engine-write seam, so each filter `value = {type="item", name, quality}` requests
> the EXACT quality variant (normal- and uncommon-quality iron launch
> independently). A bare item-name key decodes to `"normal"`. The
> `minimum_delivery_count` / rocket-capacity sub-rocket cap uses the BARE item
> name only (`prototypes.item[name].weight` is quality-independent), so the qkey is
> decoded before `rocket_capacity`.

> **Caveat (still verify in-engine, gates the wrapper):** the hub request is a
> SINGLE global request, not natively schedule-scoped, so "request only at the
> source stop / only the return manifest at the dest" is realized by the mod
> **re-issuing** the hub request as the ship advances stops. This lifecycle is now
> implemented: `watchdog.note_progress` re-points the request on every stop
> advance via the pure `watchdog.stop_request(a, current)` selector. The shipped
> route is a **THREE-stop turnaround on the same two planets** (one-way is the
> first two stops): forward manifest at the source (**stop 1**, then refined by
> the re-clamp); at the destination **TURNAROUND (stop 2)** the request becomes
> the **return manifest** (loaded there while the pad pulls the forward cargo via
> `allows_unloading`) for a two-way trip, or is **cleared** for a one-way unload;
> cleared again on the return **drop** back at the source (**stop 3**) — and
> `watchdog.free_assignment` clears it when the assignment completes / times out /
> is withdrawn so a freed ship stops launching cargo. (Previously this note
> described a FOUR-stop two-way re-point lifecycle; the shipped route is the
> three-stop turnaround — see `schedule.records_for` in `scripts/schedule.lua` and
> `watchdog.stop_request`, which keys the return manifest at `current == 2`.)
> Confirm the exact `LuaLogisticSections` add/clear/`set_slot` calls in a running
> game.
>
> Three details the wrapper now bakes in (re-confirm in-engine):
> - **Dedicated mod section.** `schedule.apply_hub_request` never writes
>   `point.sections[1]` blindly (it could be the player's section, a shared
>   logistic-group section, or a non-manual read-only one). It finds/creates a
>   **manual, ungrouped** section via `mod_request_section` and only touches that
>   one — confirm `is_manual` / `group` / `add_section` semantics in-engine.
> - **`import_from` scoping.** Each filter carries `import_from = <source planet>`
>   (forward) / `<dest planet>` (return) so a request can only launch from the
>   intended planet — confirm `LogisticFilter.import_from` is honored on the hub
>   requester.
> - **Failure propagation.** `apply_hub_request` returns false when the
>   hub/point/section can't be reached; `apply_records` / `schedule.write`
>   propagate that, and `dispatcher.commit` records NO commitment and leaves the
>   ship idle on a failed write (the demand retries next tick).
>
> The pure record builder stays agnostic — it emits `{station, wait_conditions,
> requests = {[item]=qty}, import_from}` for its own bookkeeping/signature, and
> `schedule.engine_records` strips everything but `station` + `wait_conditions`
> before the records reach `set_records`. This indirection is the whole reason the
> translation is pure: re-pointing the wrapper costs nothing in the math.

> **Caveat:** "load N at the source" is realized by the hub **requesting** the
> item (vanilla rockets then launch it up). The mod **never** `insert`s into the
> hub — that would be teleporting and is explicitly forbidden by the design.

**Schedule-progress + hub-hold reads (watchdog, Task 6).** The watchdog needs to
know which stop the ship is at and whether its hold has drained:

- **Schedule progress:** `platform.schedule.current` is the **index of the
  current DESTINATION** — the record the platform is travelling TOWARD or parked
  at — compared against `#platform.schedule.get_records()`.
  **[confirmed against the official 2.0 docs: `LuaSchedule.current` is "the
  current destination index"; it advances at a stop boundary, NOT on arrival, so
  it is NOT by itself an "arrived" flag.]** Consequences the watchdog now bakes
  in (the per-`current` reads themselves stay [provisional — confirm in-engine]):
  - **Re-clamp** runs the WHOLE time the ship is on a load stop, not once "on
    arrival": `current == 1` (forward load at the source) / `current == 2` (return
    load at the destination TURNAROUND, three-stop route) each re-clamp every
    watchdog tick, because the single instant of arrival can't be read from
    `current`. Lower-only, so re-clamping through the transit is harmless.
  - **Completion** can't trust `current >= #records` alone (that includes
    travelling to the last stop), so it also requires `platform.speed == 0`
    (parked) AND that the hub holds **none of OUR cargo** (the manifest + return
    manifest), checked per-item rather than whole-hub-empty (see the per-item
    hub-count seam below).
  - **No-progress deadline** uses a window WIDER than the per-stop wait timeout
    (`dispatcher.NO_PROGRESS_WINDOW`), because `current` shows no progress during
    a long inter-planet leg — a legitimately long leg must not be timed out.
- **Platform motion:** `platform.speed` (double) — `0` when parked at a stop,
  non-zero in transit; the completion check uses it to reject "empty hold while
  still travelling to the final stop". A nil read degrades to the empty-hold guard
  alone. **[provisional — confirm `speed` in-engine.]**
- **Refuel/rearm INTERRUPTS vs. `current` (#5):** the mod writes a SIMPLIFIED
  schedule (source → dest [→ source]) that **excludes** the player's interrupts.
  **[STILL-TO-CONFIRM in-engine — gates the GUI/schedule seam flip]** what
  `platform.schedule.current` reports while a refuel interrupt is active, and
  whether the engine splices interrupt-`created_by_interrupt` records into
  `.records` (shifting the index `current` points at). Defensive guard SHIPPED
  regardless: `watchdog.note_progress` re-points its single hub request off the
  numeric `current` index (`watchdog.stop_request` keys cargo by index), so it now
  re-points/commits ONLY when `sched.records[current].station` is one of the
  assignment's own route stations (`watchdog.station_is_ours` →
  `a.source_planet`/`a.dest_planet`); a `current` parked on a foreign interrupt
  stop is ignored (no progress committed) until the ship returns to a route stop.
  Confirm the interrupt record/`current` behavior in a running game, then flip this
  note + this §1 entry to `[confirmed]`.
  - **Player-edit signature filter (#5, Task 4) [provisional — confirm both flags
    in-engine].** Interrupt-spliced platform schedule records carry
    `created_by_interrupt = true` (it is part of the 2.0 `ScheduleRecord` shape,
    listed above) and temporary stops carry `temporary = true`. The watchdog's
    player-edit signature must NOT count these engine-inserted records, or a
    refuel/rearm interrupt would mismatch the stored signature and falsely withdraw
    a healthy ship before the `current_is_ours` guards run. So the readback path
    signs `schedule_signature(watchdog.signable_records(sched.records))`, which
    drops any record where `rec.temporary == true or rec.created_by_interrupt ==
    true`; the commit-time sign is unaffected (the mod never writes
    temporary/interrupt records). The Post-Completion playtest confirms BOTH flags
    on a real interrupt; **documented fallback if either is disproved**: filter on
    `not watchdog.station_is_ours(a, rec.station)` instead (drop records whose
    station is not one of the assignment's own), accepting weaker detection of
    player-added foreign stops.
- **Platform hub per-(item,quality) cargo count:**
  `platform.hub.get_item_count{name, quality}` — gates the watchdog's "unload done
  / completed" check (`watchdog.completed` via the pure `manifest_delivered`) AND
  the delivery-impossible abort (`watchdog.delivery_stalled`). Completion now tests
  the **manifest cargo per-item** (the items the mod shipped) rather than
  whole-hub-empty, because a platform hub also holds the ship's OWN
  fuel/ammo/repair-packs, so a whole-hub
  `get_inventory(defines.inventory.hub_main).is_empty()` would never read empty for
  a ship that stocks its own fuel and the delivery would loop/linger to the
  no-progress timeout instead of completing. `get_item_count` on the hub entity
  counts across the entity's inventories, which still reads 0 for a delivered
  manifest item. **Quality (Task 11, #4d):** the manifest is keyed by the cargo
  `qkey(item, quality)`, so `watchdog.hub_counter` DECODES the qkey and reads
  `get_item_count{name, quality}` — normal- and uncommon-quality iron complete
  independently; a bare item-name key decodes to `"normal"`. **[provisional —
  2.0 `get_item_count` takes a SINGLE `ItemWithQualityID` (`{name, quality}`); the
  earlier two-arg `(name, quality)` form CRASHED in playtest 2026-06-10 ("Expected
  0 or 1 arguments but 2 were given"), corrected per the 2.0 docs, re-confirm the
  table form completes a delivery in-engine.]** (The earlier whole-hub
  `get_inventory(hub_main).is_empty()` read —
  `watchdog.hold_empty` — was retired 2026-06 for this reason.)
- **Platform hub slot budget — per-platform capacity (#3, Task 6):**
  `hub.get_inventory(defines.inventory.hub_main)` → `LuaInventory`, then `#inv`
  is the number of cargo slots. This is the per-platform **SLOT BUDGET** the
  slot-aware manifest packer (Task 7) fills (`ceil(load / stack_size)` slots per
  item). `dispatcher.capacity_of(entry)` reads it and falls back to
  `dispatcher.DEFAULT_CAPACITY` slots when the hub/inventory can't be read
  (degrade safely, never error). **NOTE — this changes the units of
  `ship.capacity` from item-count to SLOT-count**: cargo bays enlarge the hub
  inventory, so a freighter reports more slots than a bare hub (replacing the old
  flat-1000 item stub). **[provisional — confirm
  `get_inventory(defines.inventory.hub_main)` is the cargo hold and `#inv` is its
  slot count in-engine.]**

- **Platform current planet — no-deadhead ship pick:**
  `platform.space_location` is the `LuaSpaceLocationPrototype` the platform is
  stopped at (nil while travelling); its `.name` matches the planet/surface name
  the dispatcher routes on (a planet is a space location of the same name).
  `dispatcher.ship_planet(platform)` reads it and stamps `ship.planet` on the
  snapshot, so `pick_ship` can prefer an idle ship already AT the source planet and
  `plan` can flip a reciprocal route to start where the ship sits (avoiding an empty
  first leg). Read-only and advisory: a nil/unreadable location simply yields no
  preference (never a wrong route). **[provisional — confirm `space_location` and
  its `.name` on a parked platform in-engine.]**

> **Caveat:** these are READ-only progress checks; the only WRITE the watchdog
> makes is lowering a load stop's request on re-clamp (via the hub logistic
> request) — never an `insert`.

---

## 2. Launchable stock accessor — surplus basis  → gates Task 1 / Task 4 (#7)

**[provisional — confirm the per-node network accessor + in-flight caveat before the IO wrapper flips to [confirmed]]**

"Surplus" is computed against **what the planet can currently launch**, i.e. the
logistic-network item count reachable by rocket silos.

**Accessor (Task 4, #7) — the trade node's OWN logistic network:**
`pad.logistic_network` (the `LuaLogisticNetwork` the cargo-landing-pad entity
belongs to), then `network.get_item_count{name, quality}`.
`stock.read_launchable_stock` scopes to THIS network, NOT the whole-surface
aggregate.

- **Per-quality stock (Task 9, #4b) [provisional — 2.0
  `LuaLogisticNetwork.get_item_count` takes a SINGLE `ItemWithQualityID`
  (`{name, quality}`), confirmed against the 2.0 docs; the earlier two-arg
  `(item, quality)` form crashed in playtest 2026-06-10, re-confirm the table form
  in a running game]:** the cargo key is a `qkey(item, quality)`, so the reader
  `qparse`s it and reads launchable stock PER QUALITY —
  `network.get_item_count{name, quality}` (and the fallback surface-sum likewise).
  Normal- and uncommon-quality iron are independent stock pools; a bare item-name
  key decodes to `"normal"` so legacy reads still resolve.

- **Why per-node, not surface-wide:** a planet may host **two or more
  DISCONNECTED logistic networks**. Summing every network on the surface (the
  pre-#7 behavior) over-counts — the mod would promise surplus a silo on a
  different network can't launch, producing impossible dispatches that fall back
  to the no-progress timeout.
- **Fallback (degrade safely, never error):** when the per-node accessor is
  unavailable — no/invalid pad entity, or the pad isn't on a network — the reader
  falls back to the old surface-sum: `force.logistic_networks[surface.name]`, then
  `network.get_item_count(item)` summed over all networks (order-independent
  commutative reduction, so plain `pairs` is fine).

> **Caveat — silo-vs-pad network (must verify in-engine, gates the wrapper):**
> exports launch from rocket **SILOS**, which may sit on a **different** logistic
> network than the landing **PAD**. Scoping surplus to the pad's network removes
> the over-count on disconnected-network planets, but can **under-count** if a
> launching silo isn't on the pad's network. An under-count is the safe direction:
> the re-clamp / `load_impossible` paths cover it (a too-low surplus just means a
> smaller/skipped manifest, never an impossible dispatch). **Flag for playtest
> (#7):** on a real two-network planet, confirm the pad's network is the one the
> silos draw from, or revisit (e.g. union the silos' networks) if exports starve.

> **Caveat — in-flight / committed items:** the raw stock number does **not**
> subtract items already committed to an in-flight launch or a rocket being
> filled. The mod compensates on its own side via `surplus_commit` bookkeeping
> (Task 5), and **re-clamps on arrival** (Task 6) so a stale-high reading never
> strip-mines below the reserve. The stock accessor itself stays pure-stock; the
> demand/commitment awareness lives in the dispatcher (`exportable()`), not here.

> **Caveat — rocket capacity / silo availability:** a high stock number does not
> guarantee it can all launch this trip (silo count, rocket capacity, fuel). The
> mod does not model this; partial fills self-correct next tick (Task 6). The
> per-stop `load` is clamped to `min(surplus, ship_capacity, unmet)` in Task 4
> (capacity is a SLOT budget since Task 6/7; the per-item clamp ≈
> `min(surplus, free_slots × stack_size, unmet)`, packed slot-aware).

`scripts/stock.lua` caches reads per dispatcher tick (tagged with `game.tick`),
so one tick never pays for the same item twice and a stale value never leaks
across ticks (Task 1 cache-invalidation contract).

---

## 3. Cargo Landing Pad — request slots + on-hand  → gates Task 2

**[provisional — confirm request-slot + on-hand accessors before Task 2's IO wrapper]**

In Space Age there is exactly **one Cargo Landing Pad per planet**, so the pad
== the per-planet trade node. Demand = the pad's **native logistic request
slots**.

**Request slots (the demand source):** the landing pad is a logistic requester.
Its requests live as **logistic sections** on its `LuaLogisticPoint`:

- `pad.get_logistic_point(defines.logistic_member_index.cargo_landing_pad_requester)`
  → `LuaLogisticPoint`, whose `.sections` (`LuaLogisticSections`) hold the request
  filters: each filter is `{value = {name=item,...}, min = requested_count, ...}`.
- **[confirmed against the 2.0 API defines]** the cargo landing pad's requester
  member index is `cargo_landing_pad_requester` (the defines list also has
  `cargo_landing_pad_provider` / `cargo_landing_pad_trash_provider`, and the hub's
  is `space_platform_hub_requester`). `logistic_container` is a *different* point
  and returns no logistic point on a pad — using it leaves every pad reporting
  zero demand. Re-confirm the filter/section read shape in-engine.

**On-hand (what's already delivered):** the pad's inventory.

- `pad.get_inventory(defines.inventory.cargo_landing_pad_main)` → `LuaInventory`,
  then `inventory.get_item_count{name, quality}` (Task 9, #4b — per quality). The
  code commits to `cargo_landing_pad_main` as the provisional choice; confirm
  this is the right `defines.inventory.*` constant for the landing pad's hold
  in-engine.

**Quality (Task 9, #4b) [provisional — confirm in-engine]:** an item name alone is
no longer a unique demand key — `iron-plate` at normal vs. uncommon quality are
distinct requests.

- **Request quality:** each request filter carries the quality variant on
  `filter.value.quality` (a quality-name string; nil/absent → `"normal"` via
  `qkey`). `demand.reader` keys each request by `qkey(name, quality)`, so two
  qualities of one item are two distinct demand rows. Confirm the filter
  `value.quality` shape on the cargo-landing-pad requester in-engine.
- **Per-quality on-hand:** `inv.get_item_count{name, quality}` — so a
  normal-quality on-hand never masks an uncommon-quality shortfall. 2.0
  `get_item_count` takes a SINGLE `ItemWithQualityID` table; the earlier two-arg
  `(name, quality)` form CRASHED in playtest 2026-06-10 ("Expected 0 or 1 arguments
  but 2 were given") — corrected per the 2.0 docs, re-confirm the table form reads
  on-hand correctly in a running game.

`demand.unmet(item) = requested - on_hand - already_inbound_from_fleet`, clamped
at 0 (Task 2). The pure unmet/sort math is engine-independent and can be written
and tested now; only the reads above wait on this confirmation.

> **Caveat:** the per-slot `source via fleet` toggle + priority are **mod
> overlay state** in `storage.nodes`, NOT native pad data — the native pad only
> tells us item + requested count. The overlay is keyed by item NAME (a flag /
> priority applies to ALL qualities of an item), so `demand.build_open` `qparse`s
> each demand `qkey` back to its bare name before `source_via_fleet` / `priority`
> (Task 9, #4b). Same rule as the reserve floor in §2 / `stock.surplus`.

---

## 4. Player-edit detection — decision  → gates Task 6

**[decision recorded — confirm whether a schedule-changed event exists in 2.0]**

The watchdog must notice when the **player** manually edits a ship's schedule so
the mod can **withdraw** that ship instead of fighting the player (invariant #3).

Two mechanisms were weighed:

- **(a) Event-based:** if 2.0 raises an event when a platform/train schedule
  changes (e.g. an `on_*_schedule_changed`), subscribe and compare the new
  schedule to what the mod last wrote.
- **(b) Stored signature/hash:** when the mod writes a schedule, store an
  **order-stable signature** (a deterministic serialization of the records —
  stations in order, each stop's sorted wait-conditions and sorted request
  pairs). On each watchdog tick, recompute the signature from the live schedule
  and compare. Any mismatch ⇒ the player (or another mod) changed it ⇒ withdraw.

**Decision: use (b), the stored order-stable signature**, as the primary
mechanism, because:

- it is **engine-version-robust** (no dependency on a specific 2.0 event
  existing), and
- the signature must be **deterministic / order-stable anyway** for multiplayer
  (built via `state.sorted_pairs` over the request map and the fixed record
  order), which we already have.

If a schedule-changed event does exist in 2.0, Task 6 may *additionally*
subscribe to it as a cheap early-out (skip the per-tick rehash for unchanged
ships), but correctness rests on the signature compare, not the event.

> **Caveat (gates Task 6):** the signature serialization MUST be order-stable —
> iterate records in their fixed schedule order, and within a record iterate
> wait-conditions and request `{item=qty}` pairs via the sorted helper. A
> `pairs`-order serialization would produce false "player edited it" positives
> across save/load and across clients.

> **What we sign [confirmed 2026-06-10 in-engine].** Per record: `station`, the
> per-stop `requests` (always empty in the signed records — `engine_records`
> strips cargo), and each wait condition's `type` / `ticks` / `compare_type`
> (`compare_type` absent → `"and"`). **That is ALL.** The signature deliberately
> does NOT sign the `item_count` `condition` payload (comparator / first_signal /
> constant) or the record-level `allows_unloading`. Task 5 DID sign those, but the
> 2.0 schedule readback does **not** return them verbatim — `allows_unloading` and
> the circuit-condition fields come back normalized differently than written — so
> the commit-time signature mismatched its own live readback, and EVERY mod ship
> was falsely withdrawn as a "player edit" the tick after dispatch, clearing its
> hub request and stalling all deliveries (playtest 2026-06-10). Reverted to the
> route-shape-only signature: a player RE-ROUTING the ship (station / condition
> type / ticks / compare_type) is still detected; a mere wait-quantity tweak is
> harmlessly re-asserted by `resync_conditions`.

> **Caveat (engine default normalization):** the signature must canonicalize a
> `WaitCondition` written without a `compare_type` to the engine default
> **`"and"`** (`watchdog.schedule_signature` does `c.compare_type or "and"`). The
> mod writes the leading `full`/`empty` condition with no `compare_type`, but the
> engine stores AND reads it back as `"and"`, so a `compare_type or ""`
> serialization would make the commit-time signature mismatch its own live
> readback and falsely withdraw every fresh assignment on the first watchdog tick.
> (The pure builder still emits the ABSTRACT `full`/`empty` tokens; when the
> wrapper maps those to the real 2.0 `WaitConditionType`s in-engine, sign over the
> mapped records so the readback compare stays apples-to-apples.)

---

## 5. Misc seams (already exercised / low-risk)

- `script.on_nth_tick(interval, handler)` — dual-cadence registrar. **[confirmed]**
  Registered in `control.lua`: the dispatcher runs on the dispatch-interval setting
  and the watchdog on the constant `watchdog.INTERVAL`. Equal periods share one
  handler; differing periods register two. Re-registers when the dispatch-interval
  setting changes (clearing any orphaned period).
- `script.on_init` / `script.on_configuration_changed` — storage init +
  schema migration. **[confirmed]** Wired to `scripts/state.lua`
  (`on_configuration_changed` runs the v1→v2 `migrate_fleet_keys`).
- Entity build/destroy events for the registry (Task 3):
  `on_built_entity`, `on_robot_built_entity`, `script_raised_built`,
  `on_entity_died`, `on_player_mined_entity`, `on_robot_mined_entity`,
  `script_raised_destroy`, plus platform create/destroy events. **[provisional
  — confirm the full 2.0 event set + the platform-specific events in Task 3.]**
  Filter to cargo landing pads (and platform hubs) by `entity.name`/`type`.
- Surface deletion for the registry (Task 6): `on_pre_surface_deleted` →
  `registry.on_pre_surface_deleted(event.surface_index)`. **[provisional —
  confirm `on_pre_surface_deleted` and its `event.surface_index` field in-engine.]**
  We hook the PRE event (not `on_surface_deleted`) deliberately: in the pre-event
  the surface is **still valid**, so each stored `node.surface` handle is readable
  and its `.index` can be matched against `event.surface_index`; by the time
  `on_surface_deleted` fires those handles are already invalid and unmatchable.
  The handler prunes every node on the deleted surface (and any unassigned fleet
  entry resolvable to it). The `build_snapshot` / `stock.lua` `.valid` guards are
  the primary defense against a dead surface; this handler only stops ghosts
  lingering until the next `registry.rebuild()`.
- `LuaGuiElement` for both windows (Tasks 8/9). **[confirmed surface; details
  per task.]**
- Trade tab relative-GUI anchor (Task 9): the Trade overlay is a
  `player.gui.relative` frame anchored to the Cargo Landing Pad window via
  `{ gui = defines.relative_gui_type.cargo_landing_pad_gui, position = right }`,
  built on `on_gui_opened` (entity gui_type) and torn down on `on_gui_closed`.
  **[provisional — confirm the exact `relative_gui_type` for the cargo landing
  pad in-engine.]** The rest of the module (overlay persistence into
  `storage.nodes`, the pure readout) is anchor-independent.
- Fleet tab relative-GUI anchor (`gui/fleet_tab.lua`): the enrollment overlay is a
  `player.gui.relative` frame anchored to the Space Platform Hub window via
  `{ gui = defines.relative_gui_type.space_platform_hub_gui, position = right }`,
  built on `on_gui_opened` and torn down on `on_gui_closed`. The opened hub
  resolves to its platform via `entity.surface.platform` (then `.index`, the
  fleet key). **[provisional — confirm the exact `relative_gui_type` for the
  space platform hub in-engine.]** The writers (`fleet.set_enrolled` /
  `set_reserve_for_manual_use`) and tech gate are anchor-independent.
- Monitor recenter (`gui/monitor.lua`): clicking a roster ship sets
  `player.centered_on = hub` (Remote View, follows the entity), falling back to
  `player.set_controller({ type = defines.controllers.remote, surface = … })`
  when there is no hub. **[confirmed]** `LuaPlayer.zoom_to_world` does NOT exist
  in 2.0 (it was a 1.1 API); Space Age replaced world-zoom with Remote View, so
  use `centered_on` (entity) or `set_controller{type=remote, surface, position}`.
  `set_controller` remote takes `surface`/`position` but no `zoom`.
- Planet box component (`gui/common.lua` `planet_box`): a shared label rendering a
  planet's icon + localised name, reused by every GUI that references a planet
  (Monitor roster first; shipments / waiting / Trade & Fleet tabs to follow). The
  localised name is `game.planets[name].prototype.localised_name` (**[confirmed]**,
  same as the Fleet tab allow-list below); the icon is the `[planet=<name>]`
  rich-text tag. **[provisional — confirm the `[planet=<name>]` rich-text tag
  renders in 2.0; if the tag name is wrong it degrades to visible literal text, not
  a crash, so it is safe to ship behind a playtest check.]**
- Monitor roster ship name + current location (`gui/monitor.lua`): each row shows
  the ship's `platform.name` (the button caption) and the planet it is currently
  parked at via the existing `dispatcher.ship_planet` seam (`platform.space_location.name`,
  nil in transit). **[provisional — `platform.name` is read surface-only; the
  location reuses the same `space_location` seam as ship selection, still to flip.]**
  Cargo is NOT shown in the roster for now (manifest still rides on the row for the
  item filter).
- Item components (`gui/common.lua` `item_box` / `item_chips`): shared item
  renderers reused across GUIs. `item_box` = icon + localised name (line-per-item
  views, e.g. Monitor waiting detail); `item_chips` = a compact "[item=…]×N …" run
  (collapsed waiting summary, future cargo views). The icon is the
  `[item=<name>,quality=<q>]` rich-text tag (quality omitted for normal); the name is
  `prototypes.item[name].localised_name`. **[provisional — confirm the
  `[item=…,quality=…]` rich-text tag and `prototypes.item[name].localised_name` in
  2.0; the tag degrades to literal text if wrong.]**
- Monitor Demand section is per-planet COLLAPSIBLE: groups come from the pure
  `viewmodel.group_demand(shipments, waiting)`, which buckets each planet's inbound
  cargo into delivering / loading (by the in-flight assignment's phase) / waiting
  (blocked open demand). Collapsed shows the bucket COUNTS; expanded lists each item.
  The per-player expanded-planet set persists in
  `storage.monitor_expanded[player_index]` (survives the body rebuild + save/load),
  toggled from `on_gui_click` on a per-planet button (planet carried in `tags`).
  Storage write on a per-player MP-synced input -> deterministic; read only for that
  player's view. No new engine seam (plain `on_gui_click` + `storage`).
- Fleet-tab per-ship allow-list (`gui/fleet_tab.lua`): the planet universe comes
  from `game.planets` (a `LuaCustomTable[name -> LuaPlanet]`). `planet.name` is the
  internal name and MATCHES the surface name the dispatcher compares against
  (`dispatcher.planet_name` = `node.surface.name`), so it is the allow-list key;
  `planet.prototype.localised_name` is the checkbox caption. **[confirmed]** The
  decision (collapse "all ticked" -> nil) lives in the pure
  `fleet.allowed_from_selection`; the writer is `fleet.set_allowed_planets`.
- Per-item stack size — capacity packing (#3, Task 6): `prototypes.item[name].stack_size`
  (uint). The slot-aware packer (Task 7) converts an item-count load into slots via
  `ceil(load / stack_size)`. `dispatcher.stack_size_of(name)` reads it (tagging each
  demanded item in `build_snapshot` so the pure planner only copies the value) and
  falls back to `dispatcher.DEFAULT_STACK_SIZE` when `prototypes` is absent (the
  pure-Lua test runner) or the item has no prototype. **[provisional — confirm
  `prototypes.item[name].stack_size`; `prototypes` is the 2.0 replacement for the
  old `game.item_prototypes`.]**
- Top-bar shortcut prototype + sprite in `data.lua` (Task 8). **[confirmed
  surface.]**
- Monitor top-left dock (`gui/monitor.lua`): an always-visible folded status panel
  is a `player.gui.top` frame holding one status button, built/updated for every
  player on the dispatcher cadence (`monitor.refresh_all`, plus an immediate nudge
  on `on_player_created` / `on_research_finished`) and gated by the same
  `fleet.tech_researched` check as the centered Monitor (no tech -> the dock is
  torn down). The button click toggles the centered Monitor (`monitor.toggle`).
  **[provisional — confirm `player.gui.top` is the intended top-left anchor in 2.0
  (vs. the `mod-gui` lualib button flow), and that mutating `button.style.font_color`
  / `caption` per refresh is well-behaved there.]** The counts come from the pure
  `viewmodel.build` summary (`ships_active` = working, `ships_idle`, and
  `ships_stuck` = enrolled ships the watchdog flagged `stranded`, a DISJOINT roster
  bucket), so the shaping stays testable; only the frame/button render here is
  engine-touching. The `stranded` flag itself (`fleet.set_stranded`) is set by the
  watchdog on an assignment timeout and cleared when the ship next works a stop or
  completes a delivery -- it is display-only and never gates dispatch.
- Technology researched-state read: `force.technologies["interplanetary-trade-logistics"].researched`
  gates the Trade tab + fleet toggle (Tasks 9/10). **[confirmed]** The minimal
  technology prototype already exists (Task 0 `data.lua`).
- Tips and Tricks (`data.lua`): a `tips-and-tricks-item-category` + text-only
  `tips-and-tricks-item` entries (one `is_title` overview + per-feature sub-tips),
  all `starting_status = "unlocked"` (browsable any time, no popups). Names /
  descriptions under the `[tips-and-tricks-item-category|name|description]` locale
  sections. **[confirmed]** against the 2.0 prototype docs: `image`/`simulation` are
  optional (text-only is valid) and `"unlocked"` is a valid `TipStatus`. Static
  data only -- the control stage never reads these.

---

## How provisional entries unblock work

The plan's testing seam splits **decision/view-model math** (pure, engine-free)
from **IO wrappers** (thin, engine-touching). Provisional API entries here gate
ONLY the wrappers. So:

- Pure surplus/unmet/exportable/schedule-record/return-leg/reason-classifier
  math (Tasks 1,2,4,5,7,8) can be written and unit-tested now under plain `lua`.
- Each IO wrapper does a 2-minute in-engine confirmation of its one seam and
  flips the entry from **[provisional]** to **[confirmed]** here when it lands.

Update this file (and flip statuses) as wrappers are implemented — it is the
living record of what the engine actually does, per the plan's Task 12.

---

## Implementation notes (Tasks 1–11)

Captured after building the control-stage code. The pure-math layer is complete
and unit-tested (251 assertions, `lua tests/calc_test.lua`). **No running engine
was available during implementation**, so every IO-touching seam (§§1–4 and the
relative-GUI anchor in §5) remains **[provisional]**: each was implemented as a
thin, swappable wrapper around the pure builder so that flipping it to the
confirmed call is a one-line change, not a rewrite. The status flips happen
during the in-game playtest pass (Post-Completion), not in the code-only phase.

What landed as a deliberate seam, ready for the in-engine confirmation:

- **`stock.reader`** (§2) — swappable launchable-stock accessor; pure
  `surplus`/`compute_surplus` fully tested around it.
- **`demand.reader`** (§3) — swappable request-slot + on-hand reader; pure
  `compute_unmet`/`build_open` fully tested around it.
- **`schedule.writer`** (§1) — swappable schedule write; pure `build_records`/
  `build_manifest`/`clamp_load` fully tested around it. One-way is 2 stops
  (`source(load) → dest(unload)`, dest `requests` empty = native unload). Two-way
  is 3 stops on the **same two planets**: `source(load fwd) → dest(TURNAROUND) →
  source(drop return)`. The destination is ONE turnaround stop — the dest stop
  carries the RETURN request (loaded there) AND `allows_unloading=true` so the pad
  pulls the forward cargo at the same time. (It is NOT split into unload-then-load:
  the hub's single request is re-pointed per stop by the watchdog, and that
  re-pointer only fires on a DISTINCT-station advance — two consecutive same-station
  stops never re-pointed, so the return cargo was never requested. Fixed 2026-06.)
- **Player-edit detection** (§4) — implemented as the stored order-stable
  `schedule_signature` (decision (b)), stamped at commit and recompared each
  watchdog tick; mismatch ⇒ withdraw, never fight. No dependency on a 2.0
  schedule-changed event existing.
- **Re-clamp on arrival** (§2 in-flight caveat) — `watchdog.reclamp_amount`
  (`new = min(old, current surplus)`) is pure and tested; the arrival
  trigger + request rewrite are the provisional IO around it.
- **Distance metric** (Task 5 tie-break) — a provisional swappable seam;
  `best_source` tie-breaks nearest then lowest node id, so it stays
  deterministic regardless of the metric chosen in-engine.

Audit results recorded during Task 11:

- **No-teleport invariant holds.** The only platform mutations are the schedule
  write (`LuaSchedule.set_records` / `go_to_station`) and the hub's requester
  **logistic request** (`schedule.apply_hub_request` → `section.set_slot`, in
  `scripts/schedule.lua`); cargo is REQUESTED, never inserted. There is zero
  `insert`/`teleport`/`create_entity`/`destroy` against game entities.
- **Determinism holds.** No `math.random`/`os.time`/wall-clock; ids only from
  `state.next_id()`; every ordered/decision iteration uses the sorted helper, and
  the two map→list conversions (`monitor.lua` manifest, `trade_tab.lua`
  overrides) `table.sort` first.
- **Locale complete.** Every GUI/tech/shortcut/setting key resolves in the
  `[planet-express]` / `[mod-setting-*]` sections; no reachable `Unknown key:`.

---

## Implementation notes (edge-case hardening)

The edge-case-hardening pass (real slot-aware capacity, item quality, the
delivery-impossible abort, network-scoped surplus, manifest-delivered completion)
added new IO seams, all already recorded above:

- per-node logistic network for surplus + per-quality `network.get_item_count{name, quality}` (§2);
- hub slot budget `get_inventory(defines.inventory.hub_main)` `#inv` + `prototypes.item[name].stack_size` (§1 / §5);
- per-`(item, quality)` hub `get_item_count{name, quality}` and the pad-request `value.quality` read (§1 / §3);
- `set_slot` filter `value.quality` and `item_count` `first_signal.quality` (§1).

**Every one of these stays `[provisional]` and is deliberately NOT flipped here.**
A flip to `[confirmed]` requires an in-engine check, which is Post-Completion (a
human in a running game), not part of the autonomous code/doc pass. They await the
in-engine seam confirmations and the playtest scenarios listed in the
edge-case-hardening plan's **Post-Completion** section (and mirrored in the
checklist below). The pure calc layer around each seam is complete and unit-tested
(`lua tests/calc_test.lua`, 443 assertions).

---

## Manual playtest checklist (run in a real game before publishing)

These cannot be faked by the calc tests — a human at the keyboard is required.
Run with the **debug-log setting on** so every dispatch decision is recorded.

**Confirm the provisional seams first** (flip each §1–§5 entry to `[confirmed]`
as you verify it in-engine):

1. `LuaSpacePlatform.schedule` record shape + per-stop cargo mechanism, plus the
   watchdog's `schedule.current` progress (= the current DESTINATION index, not an
   arrival flag), `platform.speed` (parked vs. in transit), and
   `defines.inventory.hub_main` hold read (§1). Confirm the re-clamp fires through
   the whole load stop and the completion check only fires when parked + empty.
   **Specifically confirm the partial-load departure (§1 caveat):** a source stop
   with a request smaller than hold capacity must still depart promptly on
   "load complete", not sit until the timeout because `"full"` never fires.
2. Launchable-stock accessor (§2).
3. Cargo Landing Pad request-slot + on-hand accessors incl.
   `defines.inventory.cargo_landing_pad_main` (§3).
4. Registry build/destroy event set incl. platform events (§5).
5. Trade tab `relative_gui_type` (cargo landing pad), Fleet tab `relative_gui_type`
   (space platform hub), and the Monitor recenter seams (§5).

**Then exercise behavior:**

- **Happy path:** set a pad request, enroll a ship on a planet with surplus,
  watch a delivery happen end-to-end with the debug log on.
- **Registry across save/load:** build/scrap a platform and a pad, toggle
  enrollment, save+reload, confirm the registry and overlay survive.
- **Trade tab round-trip:** edit import flag / priority / reserve, save+reload,
  confirm they persist; "this planet now" reflects live demand/surplus/inbound.
- **Asteroid loss:** destroy a ship mid-route → watchdog frees the assignment,
  re-opens demand, raises an alert.
- **Fuel starvation:** send a fuel-less ship → flagged stuck (not silently hung),
  demand retried elsewhere.
- **Mid-flight manual edit:** edit a busy ship's schedule → ship withdrawn, not
  fought; its demand re-opens.
- **Re-clamp:** drop source stock after dispatch but before arrival → loaded
  quantity respects the current reserve.
- **Two-way return:** give the destination surplus the source needs → return leg
  added on the same two planets; toggle the setting off → no return leg.
- **Tech gate:** Trade tab and fleet enrollment hidden until "Interplanetary
  Trade Logistics" is researched.
- **Multiplayer desync:** headless server + client against the same save under
  active trading → no desync (validates the determinism work).
- **Performance:** large multi-planet save, many enrolled ships → acceptable UPS
  at the chosen dispatch interval.
