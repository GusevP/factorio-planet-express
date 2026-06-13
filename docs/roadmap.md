# Planet Express — roadmap

Candidate work after the 1.3.0 ETA-aware dispatcher, in priority order.
Written 2026-06-12. Each item keeps the project invariants: pure decision math
behind thin IO wrappers, multiplayer determinism, schedule-only platform
mutation, and the `docs/api-notes.md` seam gate.

## 0. Ship 1.3.0 (close-out, not a feature)

The `eta-dispatcher` branch is unmerged to `main` and no
`planet-express_1.3.0.zip` exists. The ETA work added `[provisional]` seams in
`docs/api-notes.md` that must be confirmed in-engine before release — notably
the platform `speed` read, the per-`current` schedule reads, and
`space_location` / `space_connection` distances.

- Playtest with the debug decision-log on: watch one eta_factor calibration
  converge, one ETA-gated route flip, one Monitor ETA count down.
- Flip the confirmed seams to `[confirmed]`.
- Merge to `main`, package (`package.sh`), publish to the mod portal.

## 1. Multi-stop routes — the milk run (v1.4 headline)

Cash in the one deliberate architectural seam: routes are already an ordered
stop list even though the emitter writes two stops, and the ETA work supplies
the missing prerequisite (a real distance map + per-ship speed factors), so
candidate stop orders can be *scored* instead of guessed.

Scope — **milk run only**: when one source's surplus covers small demands on
two or three planets and no single demand fills the hold, emit
`source → dest1 → dest2 → home` instead of three separate trips.

- Coverage stays primary: pick the stop set covering the most demand; ETA
  breaks ties (same principle as 1.3.0).
- `exportable` guards every leg; `build_records` already takes an ordered list.
- Per-stop manifests + per-stop wait conditions extend the existing
  `(item, quality)` bookkeeping; two-sided commits gain a per-stop dimension.
- **Out of scope:** the top-up variant (two sources → one destination). It
  doubles the planning search space for a rarer payoff. Revisit only if milk
  runs prove out.

## 2. Trade ledger / statistics tab in the Monitor

Nothing survives a completed delivery today — the assignment is freed and the
history is gone. Add a bounded ring buffer in `storage` (item, qty, from→to,
tick, ship) written at the watchdog `completed` transition, plus a pure
view-model aggregation layer:

- Per-planet imports/exports over the last N minutes.
- Per-ship trip counts / cargo moved; busiest routes.
- Fleet utilization % — answers "is my fleet keeping up, do I need another
  ship?", which the Monitor cannot answer today.

Almost entirely pure, testable math; the only IO is the ring-buffer write and
a new Monitor tab (dumb view).

## 3. Starvation forecast in the Demand view

Reuse the EMA trick from per-ship speed calibration on each planet's
consumption rate per `(item, quality)`: display "stockout in m:ss" next to the
inbound "ETA m:ss", and flag the row when stockout < ETA — the player learns a
delivery will arrive too late *before* the assembler stalls.

- Read-only, no dispatch behavior change; pure math over numbers the stock
  cache already reads.
- Later increment (separate decision): feed the forecast into dispatch
  ordering — serve the soonest-starving demand first. Display-only ships
  first.

## 4. Small QoL sweep

- ETA on the top-left fleet panel rows (the Monitor roster has it; the
  always-visible panel does not).
- Translatable-strings pass: `locale/` is en-only; tidy keys and invite
  community locales if the portal release gets traction.
