# Planet Express — project conventions

A Factorio: Space Age mod (Lua: data stage + control stage). The mod orchestrates
the player's real cargo space platforms; it **never** spawns, destroys, teleports,
or `insert`s into game entities. The only platform mutation allowed is
`platform.schedule = …`. If you find yourself reaching for `create_entity`,
`destroy`, `insert`, or `teleport` against game entities, you are off-spec. The
mod performs exactly one circuit-network **read** — `hub.get_signal(planet-express-ready, …)`
in `fleet.read_ready_value`, gating dispatch on a player-emitted readiness signal.
It never *writes* a signal, wire, or combinator; the no-mutation spec is about
writes, so reads are fine.

## Determinism (hard constraint — multiplayer)

Every game-affecting decision MUST be deterministic across peers and across
save/load:

- **Stable sorted iteration** for any ordered/decision loop. Use
  `state.sorted_pairs` / `state.sorted_keys`. Raw `pairs()` is allowed ONLY for
  order-independent work (summation, set-building, keyed writes). Any
  map→list conversion that feeds a decision must `table.sort` first.
- **Ids come only from `state.next_id()`** (monotonic `storage.next_assignment_id`).
  Never derive ids from table address or wall-clock.
- **No `math.random`, `os.time`, or wall-clock** anywhere in control logic.
- **All persistent state lives in `storage`** — `storage.nodes`, `storage.fleet`,
  `storage.assignments`, `storage.alerts`. Two pieces of non-`storage` in-memory
  state exist: the per-tick stock cache (rebuilt each tick, never read across
  ticks), and the inter-planet `distance_map` in `dispatcher.lua` — derived static
  prototype data rebuilt from `prototypes.space_connection` on
  `on_init`/`on_configuration_changed`/`on_load` (`prototypes` is readable in
  `on_load`) and read across ticks. It is deterministic without being serialized
  because every peer rebuilds the identical map from identical prototypes.
  `storage.fleet` is keyed by the force-qualified fleet key
  `"<forcekey>/<platform.index>"` (`registry.fleet_key`; `forcekey` =
  `force.index or force.name`) — a stable string so `state.sorted_keys` ordering
  stays total. Storage schema is **v2** (`state.SCHEMA_VERSION`): the v1→v2
  migration (`state.migrate_fleet_keys`) re-keys `storage.fleet` and rewrites
  each `storage.assignments[*].ship`.
- The player-edit signature is an **order-stable** serialization (records in
  fixed order; wait-conditions and request pairs via the sorted helper). A
  `pairs`-order signature would cause false "player edited it" positives.

## Pure-function seam + testing convention

The codebase is split into:

- **Pure calc / view-model functions** — plain Lua over plain tables (stock,
  demand, reserves, fleet, assignments) returning plain tables (assignments,
  schedule records, GUI view models). No `game`/engine globals, so they load and
  run under plain `lua`.
- **Thin IO wrappers** — the only engine-touching code (reads from pads/networks,
  the `schedule.writer`, GUI render + event routing). Each wraps a pure function.

**Tests cover pure calculations ONLY**, collected in a single
`tests/calc_test.lua`, run with:

```
lua tests/calc_test.lua   # no game engine, no framework
```

This is a hobby game mod, not a production service: **there is no per-task "tests
must pass" gate and no in-engine/integration harness in use.** Run the calc tests
whenever you touch that math; verify everything else by **playing the mod** with
the debug decision-log setting on. See `docs/plans/completed/` for the testing
philosophy. (`control.lua` does wire a dormant `factorio-test` hook driven by an
empty `tests/test_list.lua`; it loads only when the optional `factorio-test` mod
is present, so it never runs in normal play — it is a stub seam, not a harness.)

When adding logic, keep the decision/view-model math pure and testable; push
engine calls into a thin wrapper around it. Pure modules must `require` cleanly
with module-level fallbacks so the test runner (which has no `settings`/`game`
globals) still loads them.

## Module seams (`scripts/`)

| Module | Responsibility |
| --- | --- |
| `state.lua` | storage init, schema migration (`migrate_fleet_keys`, v1→v2), `next_id`, `sorted_pairs`/`sorted_keys`, `setting`, `debug_log` |
| `reserves.lua` | reserve config read/write + `reserve(node, item)` resolver |
| `stock.lua` | launchable stock read, per-tick cache (`begin_tick`), `surplus()` |
| `demand.lua` | native pad requests → `unmet`/`open_demand`, inbound netting |
| `registry.lua` | event-maintained index of trade nodes (pads) + fleet platforms |
| `fleet.lua` | per-platform enroll toggle + per-ship limits, `idle_eligible`; ready-signal gate (`require_ready` toggle, pure `ready_from_signal`, and the mod's only circuit read `read_ready_value`) |
| `schedule.lua` | pure route→records builder + `schedule.writer` wrapper |
| `dispatcher.lua` | `on_nth_tick` match/assign/bookkeep, `exportable` thrash guard, return leg; anti-starvation aging order (`dest_order` by `last_served_tick`, `nil`=oldest) + two-pass min-load gate (`min_load_fraction`) |
| `watchdog.lua` | timeouts, destroyed/stranded, re-clamp, player-edit signature; continuous flight sampler (`sample_flight`/`flight_sample`/`ema_factor`) that EMA-calibrates each ship's `eta_factor` and records the progress-rate for the Monitor ETA |
| `gui/monitor.lua` | fleet monitor render + event routing (dumb view) |
| `gui/trade_tab.lua` | Trade tab on the landing pad GUI (dumb view) |
| `gui/fleet_tab.lua` | Fleet tab on the platform hub GUI — enroll / reserve-for-manual toggles (dumb view) |
| `gui/common.lua` | shared GUI trust glue: `ancestor_frame` (element-ancestry check) + `force_key` (force-match key), used by the three dumb views |
| `viewmodel.lua` | pure builders for GUI view models (testable) |
| `qkey.lua` | pure `(item, quality)` compound-key helper (`qkey`/`qparse`/`label`) |

**Item quality.** Cargo is keyed by `(item, quality)` end-to-end (demand, surplus,
manifest, hub request, wait conditions, bookkeeping) via `scripts/qkey.lua`
(`item .. "@" .. quality`). All decision maps stay string-keyed so
`state.sorted_pairs` iteration stays deterministic; the thin IO wrappers `qparse`
back to (name, quality) at the engine seam. **Reserves, import flags, and
priorities stay keyed by item NAME** (quality-independent — a floor / opt-out /
priority applies to all qualities of an item), so any call site holding a qkey must
`qparse` it back to the bare name before reading reserves/overlay.

The **`exportable(node, item)`** thrash guard lives in `dispatcher.lua` (the
demand↔supply join point), NOT in `stock.lua`: `surplus()` stays pure stock math;
`exportable` = `surplus` only when `unmet == 0`. Both the forward match and the
return leg source candidates exclusively through `exportable`.

## Engineering guardrails

KISS / DRY / YAGNI. No speculative abstraction, no gold-plating. Split a module
only where it earns its keep (testability or a clear seam). Routes are modeled as
an ordered stop list even though v1 emits only two stops — that is the one
deliberate seam for v1.2 multi-stop, not gold-plating.

## API seams

`docs/api-notes.md` is the **hard gate for every IO wrapper**: a wrapper must not
ship engine-touching code until the seam it needs is recorded there. Entries are
`[provisional]` (best-known 2.0 signature, re-confirm in-engine before the wrapper
ships) or `[confirmed]`. Flip the status when you confirm a seam in a running game.
