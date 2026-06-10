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
-- assignments (`inbound_commit`, Task 5), so a request isn't dispatched twice.
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
  for _, row in ipairs(rows) do
    local key = row.item
    local name = qkey.qparse(key)
    if demand.source_via_fleet(node, name) then
      local unmet = demand.compute_unmet(row.requested, row.on_hand, row.inbound)
      if unmet > 0 then
        out[#out + 1] = { item = key, unmet = unmet, priority = demand.priority(node, name) }
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
  return out
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
-- QUALITY (Task 9, #4b): each request filter carries the quality variant
-- (`filter.value.quality`, a quality-name string; nil/absent -> "normal"), so
-- the same item at two qualities is two DISTINCT rows keyed by
-- `qkey(name, quality)`. On-hand is read per quality
-- (`inv.get_item_count(name, quality)`) so a normal-quality on-hand never
-- masks an uncommon-quality shortfall (and vice versa).
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
    for _, section in pairs(point.sections) do
      -- Skip sections the player has DISABLED (`active == false`). A disabled
      -- request slot is not live demand, so counting it would dispatch shipments
      -- for requests the player deliberately turned off. A nil/absent `active`
      -- (defensive -- a partial mock) is treated as enabled.
      if section.active ~= false then
        for _, filter in pairs(section.filters or {}) do
          local value = filter.value
          local name = value and value.name
          if name and filter.min and filter.min > 0 then
            local key = qkey.qkey(name, value.quality)
            requested[key] = (requested[key] or 0) + filter.min
          end
        end
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
      on_hand = inv and inv.get_item_count(name, quality) or 0,
    }
  end
  return rows
end

-- The active reader. Tests replace this with a plain-Lua stub returning rows.
demand.reader = read_native_demand

-- ---------------------------------------------------------------------------
-- inbound lookup (mod bookkeeping -- Task 5 fills storage.assignments)
-- ---------------------------------------------------------------------------

-- Sum the fleet cargo already committed to `node` per item across in-flight
-- assignments. Deterministic: iterates assignments via the sorted helper.
-- Returns a plain { [item] = qty } table. Until Task 5 lands there are no
-- assignments, so this is {}.
--
-- Two sources of inbound (both two-sided bookkeeping, Task 5/7):
--   * forward leg: `inbound_commit`, delivered to the assignment's `dest`.
--   * return leg: `return_manifest`, carried home and delivered to the
--     assignment's `source` (Task 7). Both must net out a node's demand so an
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
-- open_demand (IO read + overlay + inbound + pure build)
-- ---------------------------------------------------------------------------

-- Items this node still needs the fleet to deliver, sorted deterministically
-- (priority then largest shortfall). Reads native rows via `demand.reader`,
-- folds in committed inbound fleet cargo, then runs the pure `build_open`.
function demand.open_demand(node)
  local rows = demand.reader(node) or {}
  local inbound = demand.inbound_for(node)
  for _, row in ipairs(rows) do
    row.inbound = (row.inbound or 0) + (inbound[row.item] or 0)
  end
  return demand.build_open(node, rows)
end

return demand
