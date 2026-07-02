-- scripts/demand.lua
--
-- Demand reading for a trade node (cargo landing pad).
--
-- A planet's demand is NATIVE: it is the cargo landing pad's own logistic
-- request slots (item + requested count). The mod adds only a thin overlay in
-- `storage.nodes` -- a per-item `source via fleet` flag (default on) and an
-- optional priority -- so the player can steer which requests the fleet fills.
--
--   unmet(item) = max(0, requested - on_hand - already_inbound_from_fleet)
--
-- The `inbound` term is the qty already committed to this node by in-flight
-- assignments (`inbound_commit`), so a request isn't dispatched twice.
--
-- Design split (per the plan's pure-function seam, same as stock.lua):
--   * the unmet/flag/priority/sort math is PURE over plain tables -- unit-tested
--     under plain `lua` with no engine globals.
--   * the native request-slot + on-hand READ is a thin IO wrapper
--     (`demand.reader`) around the provisional accessors in docs/api-notes.md §3.
--     It is swappable so the sort/filter logic can be exercised without a
--     running engine.

local state = require("scripts.state")
local qkey = require("scripts.qkey")

local demand = {}

-- ---------------------------------------------------------------------------
-- overlay reads (mod state in storage.nodes -- pure over the node table)
-- ---------------------------------------------------------------------------

-- Whether `item`'s native request should be filled by the fleet. Default ON:
-- only an explicit `false` in the node's `import_flags` opts an item out, so a
-- node with no overlay behaves as "fleet fills everything it requests".
function demand.source_via_fleet(node, item)
  local flags = node and node.import_flags
  if flags and flags[item] == false then
    return false
  end
  return true
end

-- Priority of `item`'s request (higher = filled first). Absent -> 0.
function demand.priority(node, item)
  local pr = node and node.priorities
  if pr then
    local p = pr[item]
    if type(p) == "number" then
      return p
    end
  end
  return 0
end

-- Minimum shortfall before `item`'s request is dispatched (per item NAME). The
-- fleet ignores the request until the deficit (requested - on_hand - inbound)
-- reaches this many items, so a small shortfall never triggers a near-empty trip;
-- once it does, the FULL deficit ships as usual. Absent / <= 0 -> 0 (no minimum,
-- the default: ship as soon as anything is short).
function demand.threshold(node, item)
  local th = node and node.thresholds
  if th then
    local t = th[item]
    if type(t) == "number" and t > 0 then
      return t
    end
  end
  return 0
end

-- ---------------------------------------------------------------------------
-- pure unmet math
-- ---------------------------------------------------------------------------

-- Pure: shortfall after on-hand stock and already-committed inbound fleet
-- cargo, clamped at zero (never negative -- an over-satisfied request has no
-- demand).
function demand.compute_unmet(requested, on_hand, inbound)
  local u = (requested or 0) - (on_hand or 0) - (inbound or 0)
  if u < 0 then
    return 0
  end
  return u
end

-- ---------------------------------------------------------------------------
-- pure open-demand builder
-- ---------------------------------------------------------------------------

-- Build the node's open demand from already-read rows. PURE: this is the
-- testable core. `rows` is a list of plain tables
--   { item = <qkey>, requested = N, on_hand = N, inbound = N }
-- where `item` is the compound `qkey(item, quality)` key (on_hand / inbound
-- default to 0). Returns a list of
--   { item = <qkey>, unmet = N, priority = P }
-- for every row that is fleet-eligible AND has unmet > 0, sorted
-- DETERMINISTICALLY: priority desc, then unmet (largest shortfall) desc, then
-- qkey asc as the final stable tie-break (multiplayer determinism -- never rely
-- on `rows` order or `pairs` order).
--
-- The fleet-flag + priority OVERLAY is keyed by bare item NAME (a reserve / opt-
-- out / priority applies to ALL qualities of an item -- per the plan's
-- Decisions), so the qkey is `qparse`d back to its name before
-- `source_via_fleet` / `priority`. A bare item-name key (legacy / quality-
-- agnostic) decodes to the same name, so old rows still resolve. Still PURE:
-- `qkey.qparse` is plain string math, no engine globals.
function demand.build_open(node, rows)
  local out = {}
  local held = {}
  for _, row in ipairs(rows) do
    local key = row.item
    local name = qkey.qparse(key)
    if demand.source_via_fleet(node, name) then
      local unmet = demand.compute_unmet(row.requested, row.on_hand, row.inbound)
      if unmet > 0 then
        -- Per-item dispatch threshold: suppress the request until the shortfall is
        -- big enough to be worth a trip (default 0 = no minimum). A sub-threshold
        -- item is NOT dispatchable, but it is surfaced separately (`held`, display
        -- only) so the Monitor can show "below threshold" instead of the item
        -- silently vanishing.
        if unmet >= demand.threshold(node, name) then
          out[#out + 1] = { item = key, unmet = unmet, priority = demand.priority(node, name) }
        else
          held[#held + 1] = { item = key, unmet = unmet }
        end
      end
    end
  end
  table.sort(out, function(a, b)
    if a.priority ~= b.priority then
      return a.priority > b.priority
    end
    if a.unmet ~= b.unmet then
      return a.unmet > b.unmet
    end
    return a.item < b.item
  end)
  -- `held` in stable qkey order for a deterministic Monitor panel (no decision
  -- reads it -- it is display-only, kept out of the dispatchable open list).
  table.sort(held, function(a, b) return a.item < b.item end)
  return out, held
end

-- ---------------------------------------------------------------------------
-- native request-slot + on-hand IO wrapper (provisional -- docs/api-notes.md §3)
-- ---------------------------------------------------------------------------

-- [provisional] Read the pad's native request slots and on-hand inventory into
-- demand rows. Returns a list of { item = <qkey>, requested, on_hand } -- the
-- `inbound` term is layered in by `open_demand` from the assignment bookkeeping
-- (it is mod state, not native pad data). Confirm the exact logistic-point /
-- inventory accessors in-engine before flipping §3 to [confirmed].
--
-- QUALITY: each request filter carries the quality variant
-- (`filter.value.quality`, a quality-name string; nil/absent -> "normal"), so
-- the same item at two qualities is two DISTINCT rows keyed by
-- `qkey(name, quality)`. On-hand is read per quality via a SINGLE
-- `ItemWithQualityID` table (`inv.get_item_count{name, quality}`) so a normal-
-- quality on-hand never masks an uncommon-quality shortfall (and vice versa). The
-- old two-arg `(name, quality)` form crashed in-engine (2.0 `get_item_count` takes
-- 0 or 1 args).
-- Pure: the effective per-(item, quality) request ONE logistic section contributes,
-- as a { [qkey] = amount } map. The section's `multiplier` (the request group's small
-- "x N" edit button) scales EVERY filter before the game uses it, so the effective
-- amount is `floor(filter.min * multiplier)` -- reading `filter.min` alone
-- under-requested a multiplied group (a 50 x100 group read as 50, and only 50 shipped).
-- A DISABLED section (`active == false`) contributes nothing. Floor because item counts
-- are integers and `multiplier` is a float. Default multiplier 1. PURE (qkey is plain
-- string math, no engine globals) -> unit-tested; `read_native_demand` just sums these.
function demand.section_requests(section)
  local out = {}
  if not section or section.active == false then
    return out
  end
  local mult = section.multiplier or 1
  for _, filter in pairs(section.filters or {}) do
    local value = filter.value
    local name = value and value.name
    if name and filter.min and filter.min > 0 then
      local key = qkey.qkey(name, value.quality)
      out[key] = (out[key] or 0) + math.floor(filter.min * mult)
    end
  end
  return out
end

local function read_native_demand(node)
  local pad = node and node.entity
  if not (pad and pad.valid) then
    return {}
  end

  -- requested counts, keyed by qkey(item, quality), from the pad's requester
  -- logistic sections. A cargo landing pad's requester point is
  -- `defines.logistic_member_index.cargo_landing_pad_requester` (confirmed against
  -- the 2.0 API defines, §3). `logistic_container` is a different member index and
  -- returns no point here -- which would leave every pad reporting zero demand.
  local requested = {}
  local point = pad.get_logistic_point(defines.logistic_member_index.cargo_landing_pad_requester)
  if point and point.sections then
    -- Sum each section's EFFECTIVE (multiplier-scaled, disabled-skipped) requests per
    -- qkey. The per-section math lives in the pure demand.section_requests (tested);
    -- summing across sections is an order-independent keyed reduction (plain pairs ok).
    for _, section in pairs(point.sections) do
      for key, amt in pairs(demand.section_requests(section)) do
        requested[key] = (requested[key] or 0) + amt
      end
    end
  end

  local inv = pad.get_inventory(defines.inventory.cargo_landing_pad_main)

  local rows = {}
  for key, req in pairs(requested) do
    local name, quality = qkey.qparse(key)
    rows[#rows + 1] = {
      item = key,
      requested = req,
      on_hand = inv and inv.get_item_count({ name = name, quality = quality }) or 0,
    }
  end
  return rows
end

-- The active reader. Tests replace this with a plain-Lua stub returning rows.
demand.reader = read_native_demand

-- ---------------------------------------------------------------------------
-- inbound lookup (mod bookkeeping -- the dispatcher fills storage.assignments)
-- ---------------------------------------------------------------------------

-- Sum the fleet cargo already committed to `node` per item across in-flight
-- assignments. Deterministic: iterates assignments via the sorted helper.
-- Returns a plain { [item] = qty } table (empty when nothing is in flight).
--
-- Two sources of inbound (both two-sided bookkeeping):
--   * forward leg: `inbound_commit`, delivered to the assignment's `dest`.
--   * return leg: `return_manifest`, carried home and delivered to the
--     assignment's `source`. Both must net out a node's demand so an
--     in-flight delivery isn't requested again.
function demand.inbound_for(node)
  local totals = {}
  local assignments = storage and storage.assignments
  if not assignments then
    return totals
  end
  local node_id = node and node.id
  local function add(commit)
    for item, qty in state.sorted_pairs(commit) do
      totals[item] = (totals[item] or 0) + qty
    end
  end
  for _, a in state.sorted_pairs(assignments) do
    if a.dest == node_id and a.inbound_commit then
      add(a.inbound_commit)
    end
    if a.source == node_id and a.return_manifest then
      add(a.return_manifest)
    end
  end
  return totals
end

-- ---------------------------------------------------------------------------
-- pure gross-import map (export thrash-guard input)
-- ---------------------------------------------------------------------------

-- Pure: the node's GROSS physical shortfall per item, `max(0, requested - on_hand)`
-- over the raw rows -- PRE-inbound, and IGNORING the source-via-fleet opt-out (a
-- planet physically short of an item must never EXPORT it, whether or not the fleet
-- is what fills that request). This is the signal the dispatcher's export thrash
-- guard needs: the netted `unmet` that `build_open` produces folds inbound in and
-- hits 0 the moment an in-flight delivery covers the remaining gap -- but the planet
-- still physically HOLDS LESS than it asked for, so sourcing the item FROM it strips
-- stock it is itself waiting on (the ship then parks at a planet that won't launch
-- its own pending stock and times out). Gross shortfall is inbound-independent, so it
-- stays positive for exactly as long as the planet is short. Keyed by qkey; only
-- positive entries kept. PURE -- plain arithmetic over the rows.
function demand.import_map(rows)
  local out = {}
  for _, row in ipairs(rows or {}) do
    local short = (row.requested or 0) - (row.on_hand or 0)
    if short > 0 then
      out[row.item] = short
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- open_demand (IO read + overlay + inbound + pure build)
-- ---------------------------------------------------------------------------

-- Items this node still needs the fleet to deliver, sorted deterministically
-- (priority then largest shortfall). Reads native rows via `demand.reader`, folds
-- in committed inbound fleet cargo, then runs the pure `build_open`. Returns TWO
-- values: the netted open-demand list AND the pre-inbound gross-import map
-- (`demand.import_map`) the dispatcher uses as its export thrash guard -- both from
-- the same single read. Callers wanting only the list (`local open = ...`) ignore
-- the second value harmlessly.
function demand.open_demand(node)
  local rows = demand.reader(node) or {}
  local inbound = demand.inbound_for(node)
  for _, row in ipairs(rows) do
    row.inbound = (row.inbound or 0) + (inbound[row.item] or 0)
  end
  local open, held = demand.build_open(node, rows)
  -- THREE values: open-demand list, gross-import map (thrash guard), and the held
  -- sub-threshold list (Monitor display only). Callers wanting fewer ignore the rest.
  return open, demand.import_map(rows), held
end

return demand
