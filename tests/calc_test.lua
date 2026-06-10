-- tests/calc_test.lua -- plain-Lua unit tests for Planet Express pure calcs.
--
-- Run:  lua tests/calc_test.lua
--
-- This file is the ONLY automated test layer (see docs/plans -- "Testing
-- Strategy"). It exercises pure-calculation modules ONLY: surplus/reserve,
-- unmet demand + sort, the exportable() thrash guard, schedule-record building,
-- return-leg selection, and the monitor reason classifier. Those modules must
-- `require` cleanly with no `game`/engine globals so they load under plain lua.
--
-- No framework, no engine. Just assert helpers and a pass/fail tally. Each
-- later task appends its own `describe(...)` block.

-- Make `require("scripts.foo")` work regardless of the cwd the runner uses, by
-- adding the project root (this file's parent's parent) to package.path.
local here = arg and arg[0] or "tests/calc_test.lua"
local root = here:gsub("[/\\]?tests[/\\]calc_test%.lua$", "")
if root == "" or root == here then
  root = "."
end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

-- ---------------------------------------------------------------------------
-- tiny assert harness
-- ---------------------------------------------------------------------------

local total, failed = 0, 0
local current_group = "(top level)"

local function describe(name, fn)
  current_group = name
  fn()
  current_group = "(top level)"
end

local function check(ok, msg)
  total = total + 1
  if not ok then
    failed = failed + 1
    io.write(string.format("  FAIL [%s] %s\n", current_group, msg or "assertion failed"))
  end
end

-- Deep-equality for plain tables of comparable scalars (numbers/strings/bools).
local function deep_equal(a, b)
  if type(a) ~= type(b) then
    return false
  end
  if type(a) ~= "table" then
    return a == b
  end
  for k, v in pairs(a) do
    if not deep_equal(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

-- Small one-level serializer for failure messages: a `table: 0x...` address is
-- useless when a manifest deep-compare fails, so dump the (shallow) key/value
-- pairs in sorted order instead. Scalars fall through to tostring().
local function dump(v)
  if type(v) ~= "table" then
    return tostring(v)
  end
  local keys = {}
  for k in pairs(v) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then
      return ta < tb
    end
    return a < b
  end)
  local parts = {}
  for _, k in ipairs(keys) do
    local val = v[k]
    -- one level of nesting is enough for the tables this suite compares
    parts[#parts + 1] = string.format("%s=%s",
      tostring(k), type(val) == "table" and "{...}" or tostring(val))
  end
  return "{ " .. table.concat(parts, ", ") .. " }"
end

local assert_eq = function(got, want, msg)
  check(deep_equal(got, want), string.format(
    "%s\n      got:  %s\n      want: %s",
    msg or "values differ", dump(got), dump(want)))
end

local assert_true = function(v, msg)
  check(v == true, msg or "expected true")
end

-- Monotonic tick source for stock-cache blocks. Hand-picked tick literals risk
-- two blocks reusing the same tick and silently serving a stale cache entry from
-- an earlier block; this counter guarantees every begin_tick() argument is unique
-- and strictly increasing across the whole run. Starts high so it never collides
-- with any remaining literal.
local _next_tick = 1000000
local function fresh_tick()
  _next_tick = _next_tick + 1
  return _next_tick
end

-- Expose helpers so later task blocks can be split into files if desired; for
-- now everything lives inline in this file.
local T = {
  describe = describe,
  check = check,
  assert_eq = assert_eq,
  assert_true = assert_true,
  deep_equal = deep_equal,
  dump = dump,
  fresh_tick = fresh_tick,
}

-- ---------------------------------------------------------------------------
-- Task 0: prove the harness itself works.
-- ---------------------------------------------------------------------------

describe("harness sanity", function()
  assert_true(true, "true is true")
  assert_eq(1 + 1, 2, "arithmetic")
  assert_eq({ a = 1, b = { 2, 3 } }, { a = 1, b = { 2, 3 } }, "deep equal nested")
end)

-- ---------------------------------------------------------------------------
-- Later tasks append their describe(...) blocks below this line.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Task 1: reserves resolution + surplus computation + per-tick cache.
-- ---------------------------------------------------------------------------

local reserves = require("scripts.reserves")
local stock = require("scripts.stock")

describe("reserves.reserve", function()
  -- per-item override beats the default (even when the override is 0)
  local node = { reserves = { default = 100, items = { ["iron-plate"] = 250, ["coal"] = 0 } } }
  assert_eq(reserves.reserve(node, "iron-plate"), 250, "override beats default")
  assert_eq(reserves.reserve(node, "coal"), 0, "zero override is honored (not treated as absent)")
  -- item with no override falls back to the global default
  assert_eq(reserves.reserve(node, "copper-plate"), 100, "default fallback")
  -- no config at all -> 0
  assert_eq(reserves.reserve({}, "iron-plate"), 0, "no reserves table -> 0")
  assert_eq(reserves.reserve(nil, "iron-plate"), 0, "nil node -> 0")
  -- default missing but items present -> 0 default
  assert_eq(reserves.reserve({ reserves = { items = {} } }, "x"), 0, "missing default -> 0")
end)

describe("reserves write helpers", function()
  local node = {}
  reserves.set_default(node, 50)
  assert_eq(node.reserves.default, 50, "set_default seeds config")
  reserves.set_item(node, "iron-plate", 300)
  assert_eq(reserves.reserve(node, "iron-plate"), 300, "set_item override")
  reserves.set_item(node, "iron-plate", nil) -- clear override
  assert_eq(reserves.reserve(node, "iron-plate"), 50, "cleared override falls back to default")
  -- ensure with a default_floor seed only applies on first creation
  local n2 = {}
  reserves.ensure(n2, 17)
  assert_eq(n2.reserves.default, 17, "ensure seeds default_floor")
  reserves.ensure(n2, 999)
  assert_eq(n2.reserves.default, 17, "ensure does not clobber existing default")
end)

describe("stock.compute_surplus", function()
  -- min_trip = 1 for these (default exporting behavior: any positive surplus ok)
  assert_eq(stock.compute_surplus(500, 100, 1), 400, "above reserve -> stock - reserve")
  assert_eq(stock.compute_surplus(100, 100, 1), 0, "equal reserve -> 0")
  assert_eq(stock.compute_surplus(50, 100, 1), 0, "below reserve -> 0 (clamped, never negative)")
  assert_eq(stock.compute_surplus(0, 0, 1), 0, "zero stock zero reserve -> 0")
  -- min-trip suppression: positive surplus under threshold reports as 0
  assert_eq(stock.compute_surplus(105, 100, 10), 0, "surplus 5 below min-trip 10 -> 0")
  assert_eq(stock.compute_surplus(115, 100, 10), 15, "surplus 15 at/above min-trip 10 -> 15")
  assert_eq(stock.compute_surplus(110, 100, 10), 10, "surplus exactly min-trip -> kept")
  -- nil-safety
  assert_eq(stock.compute_surplus(nil, nil, nil), 0, "nil inputs -> 0")
end)

describe("stock per-tick cache", function()
  -- counting stub reader: records how many times the engine would be hit
  local saved_reader = stock.reader
  local hits = {}
  stock.reader = function(node, item)
    local k = node.cache_key .. "/" .. item
    hits[k] = (hits[k] or 0) + 1
    return node.values[item] or 0
  end

  local node = { cache_key = "nauvis", values = { ["iron-plate"] = 500 } }

  stock.begin_tick(fresh_tick())
  assert_eq(stock.stock_count(node, "iron-plate"), 500, "first read returns stock")
  assert_eq(stock.stock_count(node, "iron-plate"), 500, "second read same tick returns stock")
  assert_eq(hits["nauvis/iron-plate"], 1, "reader hit only once within a tick")

  -- value changes underneath but the tick has NOT advanced -> cached value holds
  node.values["iron-plate"] = 999
  assert_eq(stock.stock_count(node, "iron-plate"), 500, "stale-tick read serves cached value")
  assert_eq(hits["nauvis/iron-plate"], 1, "still only one reader hit (no recompute mid-tick)")

  -- advance the tick -> cache invalidated -> recompute picks up the new value
  stock.begin_tick(fresh_tick())
  assert_eq(stock.stock_count(node, "iron-plate"), 999, "new tick recomputes")
  assert_eq(hits["nauvis/iron-plate"], 2, "reader hit again on the new tick")

  -- restore the real reader so nothing else is affected
  stock.reader = saved_reader
end)

describe("stock.surplus end-to-end (stubbed reader, no engine)", function()
  local saved_reader = stock.reader
  local saved_min_trip = stock.MIN_TRIP
  stock.reader = function(node, item)
    return node.values[item] or 0
  end
  stock.MIN_TRIP = 1 -- explicit (no `settings` global under the test runner)

  local node = {
    cache_key = "vulcanus",
    values = { ["iron-plate"] = 500, ["coal"] = 80 },
    reserves = { default = 100, items = { ["coal"] = 100 } },
  }
  stock.begin_tick(fresh_tick())
  assert_eq(stock.surplus(node, "iron-plate"), 400, "stock 500 - default reserve 100 = 400")
  assert_eq(stock.surplus(node, "coal"), 0, "stock 80 below per-item reserve 100 -> 0")
  assert_eq(stock.surplus(node, "stone"), 0, "missing item (zero stock) -> 0")

  -- min-trip suppression through the full path
  stock.MIN_TRIP = 50
  stock.begin_tick(fresh_tick()) -- new tick so the cache recomputes against the new threshold path
  node.values["iron-plate"] = 130 -- surplus 30, below min-trip 50
  assert_eq(stock.surplus(node, "iron-plate"), 0, "surplus 30 below min-trip 50 -> 0")

  stock.reader = saved_reader
  stock.MIN_TRIP = saved_min_trip
end)

-- ---------------------------------------------------------------------------
-- Task 2: demand reading -- unmet math, fleet flag, priority/shortfall sort.
-- ---------------------------------------------------------------------------

local demand = require("scripts.demand")

describe("demand.compute_unmet", function()
  assert_eq(demand.compute_unmet(100, 0, 0), 100, "nothing on hand, nothing inbound -> full request")
  assert_eq(demand.compute_unmet(100, 30, 0), 70, "on-hand subtracts")
  assert_eq(demand.compute_unmet(100, 30, 20), 50, "inbound also subtracts")
  assert_eq(demand.compute_unmet(100, 100, 0), 0, "fully on hand -> 0")
  assert_eq(demand.compute_unmet(100, 60, 60), 0, "over-satisfied (on-hand+inbound > req) clamps at 0")
  assert_eq(demand.compute_unmet(100, 200, 0), 0, "more on hand than requested clamps at 0")
  assert_eq(demand.compute_unmet(nil, nil, nil), 0, "nil inputs -> 0")
end)

describe("demand.source_via_fleet", function()
  -- default ON: no overlay at all -> fleet fills everything
  assert_true(demand.source_via_fleet({}, "iron-plate"), "no overlay -> default on")
  assert_true(demand.source_via_fleet(nil, "iron-plate"), "nil node -> default on")
  -- explicit false opts an item out; other items stay on
  local node = { import_flags = { ["coal"] = false } }
  assert_eq(demand.source_via_fleet(node, "coal"), false, "explicit false opts out")
  assert_true(demand.source_via_fleet(node, "iron-plate"), "unlisted item still on")
  -- explicit true is honored
  assert_true(demand.source_via_fleet({ import_flags = { ["coal"] = true } }, "coal"), "explicit true on")
end)

describe("demand.priority", function()
  assert_eq(demand.priority({}, "iron-plate"), 0, "no overlay -> 0")
  assert_eq(demand.priority(nil, "iron-plate"), 0, "nil node -> 0")
  assert_eq(demand.priority({ priorities = { ["iron-plate"] = 5 } }, "iron-plate"), 5, "override read")
  assert_eq(demand.priority({ priorities = { ["iron-plate"] = 5 } }, "coal"), 0, "unlisted -> 0")
end)

describe("demand.build_open -- filtering + deterministic sort", function()
  -- fleet-flag filtering: coal opted out, so it never appears even though unmet
  local node = {
    import_flags = { ["coal"] = false },
    priorities = { ["iron-plate"] = 2, ["copper-plate"] = 2, ["stone"] = 5 },
  }
  local rows = {
    { item = "iron-plate", requested = 100, on_hand = 0, inbound = 0 },   -- unmet 100, pri 2
    { item = "copper-plate", requested = 100, on_hand = 40, inbound = 0 },-- unmet 60,  pri 2
    { item = "coal", requested = 100, on_hand = 0, inbound = 0 },         -- opted out -> dropped
    { item = "stone", requested = 50, on_hand = 0, inbound = 0 },         -- unmet 50,  pri 5
    { item = "wood", requested = 30, on_hand = 30, inbound = 0 },         -- satisfied -> dropped
    { item = "uranium-ore", requested = 10, on_hand = 0, inbound = 10 },  -- inbound covers -> dropped
  }
  local open = demand.build_open(node, rows)
  -- expected order: stone (pri 5) first; then pri-2 items by largest shortfall
  -- (iron 100 before copper 60); coal/wood/uranium excluded.
  assert_eq(#open, 3, "only fleet-eligible, still-unmet items survive")
  assert_eq(open[1], { item = "stone", unmet = 50, priority = 5 }, "highest priority first")
  assert_eq(open[2], { item = "iron-plate", unmet = 100, priority = 2 }, "same priority: largest shortfall first")
  assert_eq(open[3], { item = "copper-plate", unmet = 60, priority = 2 }, "smaller shortfall after")
end)

describe("demand.build_open -- item-name tie-break (full determinism)", function()
  -- identical priority AND identical shortfall -> stable by item name asc,
  -- independent of input row order.
  local node = {}
  local rows_a = {
    { item = "zinc", requested = 10, on_hand = 0 },
    { item = "alpha", requested = 10, on_hand = 0 },
    { item = "mango", requested = 10, on_hand = 0 },
  }
  local rows_b = {
    { item = "mango", requested = 10, on_hand = 0 },
    { item = "zinc", requested = 10, on_hand = 0 },
    { item = "alpha", requested = 10, on_hand = 0 },
  }
  local open_a = demand.build_open(node, rows_a)
  local open_b = demand.build_open(node, rows_b)
  assert_eq(open_a, open_b, "sort is independent of input order")
  assert_eq(open_a[1].item, "alpha", "name tie-break asc (1)")
  assert_eq(open_a[2].item, "mango", "name tie-break asc (2)")
  assert_eq(open_a[3].item, "zinc", "name tie-break asc (3)")
end)

describe("demand.build_open -- empty edges", function()
  assert_eq(demand.build_open({}, {}), {}, "no requests -> empty open demand")
  -- everything satisfied -> empty
  local rows = { { item = "iron-plate", requested = 50, on_hand = 50 } }
  assert_eq(demand.build_open({}, rows), {}, "fully satisfied -> empty open demand")
  -- on_hand / inbound default to 0 when omitted
  local open = demand.build_open({}, { { item = "iron-plate", requested = 7 } })
  assert_eq(open[1], { item = "iron-plate", unmet = 7, priority = 0 }, "missing on_hand/inbound treated as 0")
end)

-- ---------------------------------------------------------------------------
-- Task 3: fleet eligibility -- allow-list + idle/enrolled filter (pure).
-- (The registry's event wiring is engine-touching and verified by playtest.)
-- ---------------------------------------------------------------------------

local fleet = require("scripts.fleet")

describe("fleet.allows_planet", function()
  -- absent list / "all" sentinel -> serves everything
  assert_true(fleet.allows_planet({}, "nauvis"), "nil allow-list -> all planets")
  assert_true(fleet.allows_planet({ allowed_planets = "all" }, "vulcanus"), "\"all\" -> all planets")
  -- explicit list restricts
  local entry = { allowed_planets = { "nauvis", "vulcanus" } }
  assert_true(fleet.allows_planet(entry, "nauvis"), "listed planet allowed")
  assert_true(fleet.allows_planet(entry, "vulcanus"), "listed planet allowed (2)")
  assert_eq(fleet.allows_planet(entry, "gleba"), false, "unlisted planet denied")
  assert_eq(fleet.allows_planet(entry, "fulgora"), false, "unlisted planet denied (2)")
  -- empty list denies everything (an explicit empty allow-list)
  assert_eq(fleet.allows_planet({ allowed_planets = {} }, "nauvis"), false, "empty list denies")
end)

describe("fleet.allowed_from_selection", function()
  local universe = { "vulcanus", "nauvis", "gleba" } -- deliberately unsorted
  -- every planet ticked collapses to nil: "serves all", future planets included
  assert_true(
    fleet.allowed_from_selection(universe, { nauvis = true, vulcanus = true, gleba = true }) == nil,
    "all selected -> nil (unrestricted)")
  -- a strict subset is stored as a SORTED list (deterministic across peers)
  local sub = fleet.allowed_from_selection(universe, { nauvis = true, gleba = true })
  assert_eq(#sub, 2, "subset -> two entries")
  assert_eq(sub[1], "gleba", "subset sorted [1]")
  assert_eq(sub[2], "nauvis", "subset sorted [2]")
  -- ticking nothing -> explicit empty list (allows_planet denies everything)
  assert_eq(#fleet.allowed_from_selection(universe, {}), 0, "none selected -> empty list")
  -- empty universe -> nil (there is nothing to restrict)
  assert_true(fleet.allowed_from_selection({}, {}) == nil, "empty universe -> nil")
  -- round-trips through allows_planet: a stored subset denies the unticked planet
  local restricted = fleet.allowed_from_selection(universe, { nauvis = true, gleba = true })
  assert_true(fleet.allows_planet({ allowed_planets = restricted }, "nauvis"), "subset allows ticked")
  assert_eq(fleet.allows_planet({ allowed_planets = restricted }, "vulcanus"), false,
    "subset denies unticked")
end)

describe("fleet.idle_eligible", function()
  -- the happy path: enrolled, idle, unassigned, serves both planets
  local function base()
    return { enrolled = true, state = fleet.IDLE, assignment = nil, allowed_planets = nil }
  end
  assert_true(fleet.idle_eligible(base(), "nauvis", "vulcanus"), "enrolled+idle+unassigned+covers both")

  -- each disqualifier on its own blocks eligibility
  assert_eq(fleet.idle_eligible(nil, "nauvis", "vulcanus"), false, "nil entry -> not eligible")

  local not_enrolled = base(); not_enrolled.enrolled = false
  assert_eq(fleet.idle_eligible(not_enrolled, "nauvis", "vulcanus"), false, "un-enrolled -> not eligible")

  local busy = base(); busy.state = fleet.ENROUTE
  assert_eq(fleet.idle_eligible(busy, "nauvis", "vulcanus"), false, "non-idle state -> not eligible")

  local assigned = base(); assigned.assignment = 42
  assert_eq(fleet.idle_eligible(assigned, "nauvis", "vulcanus"), false, "already assigned -> not eligible")

  local withdrawn = base(); withdrawn.state = fleet.WITHDRAWN
  assert_eq(fleet.idle_eligible(withdrawn, "nauvis", "vulcanus"), false, "withdrawn -> not eligible")

  local reserved = base(); reserved.reserve_for_manual_use = true
  assert_eq(fleet.idle_eligible(reserved, "nauvis", "vulcanus"), false, "reserved for manual use -> not eligible")

  -- allow-list must cover BOTH endpoints of the route
  local restricted = base(); restricted.allowed_planets = { "nauvis", "vulcanus" }
  assert_true(fleet.idle_eligible(restricted, "nauvis", "vulcanus"), "both endpoints in allow-list -> eligible")
  assert_eq(fleet.idle_eligible(restricted, "nauvis", "gleba"), false, "dest not in allow-list -> not eligible")
  assert_eq(fleet.idle_eligible(restricted, "gleba", "nauvis"), false, "source not in allow-list -> not eligible")
end)

-- ---------------------------------------------------------------------------
-- Task 4: schedule builder -- pure route -> records (load clamping, wide load,
-- 2-stop shape, wait-conditions, zero-manifest). The engine write-wrapper is
-- verified by playtest.
-- ---------------------------------------------------------------------------

local schedule = require("scripts.schedule")

describe("schedule.clamp_load", function()
  -- Generic min-clamp over item-count units: load = min(surplus, capacity, unmet),
  -- clamped at 0. build_manifest supplies `capacity` as available_slots*stack_size
  -- (the slot->item conversion lives in the packer; this stays a pure min).
  assert_eq(schedule.clamp_load(500, 1000, 800), 500, "surplus is the binding limit")
  assert_eq(schedule.clamp_load(500, 1000, 300), 300, "unmet is the binding limit")
  assert_eq(schedule.clamp_load(500, 200, 800), 200, "capacity is the binding limit")
  assert_eq(schedule.clamp_load(0, 1000, 800), 0, "no surplus -> 0")
  assert_eq(schedule.clamp_load(500, 0, 800), 0, "no capacity -> 0")
  assert_eq(schedule.clamp_load(500, 1000, 0), 0, "no unmet -> 0")
  assert_eq(schedule.clamp_load(nil, nil, nil), 0, "nil inputs -> 0")
end)

describe("schedule.build_manifest -- item-count fallback (stack_size = 1)", function()
  -- Items with NO stack_size default to 1 item/slot, so the slot budget behaves as
  -- a plain item-count budget -- the dispatcher always supplies a real stack_size,
  -- this just keeps un-annotated callers (and the engine fallback) sane.
  local items = {
    { item = "iron-plate", surplus = 500, unmet = 800 },   -- -> 500
    { item = "copper-plate", surplus = 300, unmet = 200 }, -- -> 200
  }
  assert_eq(schedule.build_manifest(items, 1000),
    { ["iron-plate"] = 500, ["copper-plate"] = 200 }, "ample slots: both items, each clamped")

  -- tight: fair share first (iron 300, copper 200), then leftover (100) tops up
  -- the higher-priority iron -> iron 400, copper fully satisfied at 200
  assert_eq(schedule.build_manifest(items, 600),
    { ["iron-plate"] = 400, ["copper-plate"] = 200 },
    "fair share carries BOTH; leftover tops up priority item")

  -- very tight: still carries BOTH items (50 each) instead of one item
  assert_eq(schedule.build_manifest(items, 100),
    { ["iron-plate"] = 50, ["copper-plate"] = 50 },
    "fair share -> variety even when budget < one item's demand")

  -- 500 slots: share 250 each; copper needs only 200, leftover tops up iron
  assert_eq(schedule.build_manifest(items, 500),
    { ["iron-plate"] = 300, ["copper-plate"] = 200 },
    "fair share carries both; leftover goes to the priority item")

  -- an item with no surplus is omitted but does not consume slots
  local with_empty = {
    { item = "stone", surplus = 0, unmet = 50 },
    { item = "iron-plate", surplus = 500, unmet = 800 },
  }
  assert_eq(schedule.build_manifest(with_empty, 1000),
    { ["iron-plate"] = 500 }, "zero-surplus item skipped, slots preserved for the next")

  assert_eq(schedule.build_manifest({}, 1000), {}, "no items -> empty manifest")
  assert_eq(schedule.build_manifest(items, 0), {}, "no slots -> empty manifest")
end)

describe("schedule.build_manifest -- packs by SLOTS (ceil(load/stack_size))", function()
  -- FULL FIT: ample slots, both items reach their full min(surplus,unmet).
  -- iron stacks 100 -> 500 items = 5 slots; copper stacks 50 -> 200 items = 4 slots.
  local full = {
    { item = "iron-plate", surplus = 500, unmet = 800, stack_size = 100 },
    { item = "copper-plate", surplus = 300, unmet = 200, stack_size = 50 },
  }
  assert_eq(schedule.build_manifest(full, 20),
    { ["iron-plate"] = 500, ["copper-plate"] = 200 },
    "full fit: 5 + 4 slots comfortably inside a 20-slot hold")

  -- TIGHT SLOTS SPLIT FAIRLY: 6 slots, two items stacking 100 each -> 3 slots
  -- (300 items) apiece, not one item hogging all 6.
  local tight = {
    { item = "iron-plate", surplus = 1000, unmet = 1000, stack_size = 100 },
    { item = "copper-plate", surplus = 1000, unmet = 1000, stack_size = 100 },
  }
  assert_eq(schedule.build_manifest(tight, 6),
    { ["iron-plate"] = 300, ["copper-plate"] = 300 },
    "tight: 6 slots split fairly -> 3 slots (300 items) each")

  -- MIXED STACK SIZES: equal SLOT share (2 each of 4) carries very different item
  -- counts -- small stacks 10 -> 20 items, big stacks 200 -> 400 items.
  local mixed = {
    { item = "small", surplus = 1000, unmet = 1000, stack_size = 10 },
    { item = "big", surplus = 1000, unmet = 1000, stack_size = 200 },
  }
  assert_eq(schedule.build_manifest(mixed, 4),
    { ["small"] = 20, ["big"] = 400 },
    "mixed stacks: equal slot share, different item counts")

  -- LEFTOVER in slot units tops up the priority item: iron (ss 100) takes its fair
  -- 5 slots = 500; copper (ss 50) needs only 50 = 1 slot; the 4 freed slots top up
  -- iron to 900 (9 slots).
  local leftover = {
    { item = "iron-plate", surplus = 1000, unmet = 1000, stack_size = 100 },
    { item = "copper-plate", surplus = 50, unmet = 50, stack_size = 50 },
  }
  assert_eq(schedule.build_manifest(leftover, 10),
    { ["iron-plate"] = 900, ["copper-plate"] = 50 },
    "leftover slots top up the priority item")

  -- PARTIAL-SLOT BOUND: 250 wanted at stack 100 needs 3 slots, but only 2 are free
  -- -> capped at 200 (2 full slots), never the impossible 3rd partial slot.
  local partial = {
    { item = "iron-plate", surplus = 250, unmet = 250, stack_size = 100 },
  }
  assert_eq(schedule.build_manifest(partial, 2),
    { ["iron-plate"] = 200 },
    "slot bound caps load at slots * stack_size")

  -- ZERO SLOTS: nothing loads regardless of demand.
  assert_eq(schedule.build_manifest(full, 0), {}, "zero slots -> empty manifest")

  -- SAME-NAME QUALITIES are DISTINCT cargo qkeys: normal- and uncommon-quality iron
  -- pack as two independent items, so a tight slot budget fair-shares between them
  -- instead of letting one quality monopolize the hold (stack_size is per-NAME, so
  -- the two share the same stack size). 6 slots, stack 100 -> 3 slots (300) each.
  local same_name = {
    { item = "iron-plate@normal",   surplus = 1000, unmet = 1000, stack_size = 100 },
    { item = "iron-plate@uncommon", surplus = 1000, unmet = 1000, stack_size = 100 },
  }
  assert_eq(schedule.build_manifest(same_name, 6),
    { ["iron-plate@normal"] = 300, ["iron-plate@uncommon"] = 300 },
    "two same-name qualities each get a fair slot share (300 items apiece)")
end)

describe("schedule.build_records -- 2-stop route + wait-conditions", function()
  local built = schedule.build_records({
    source = "nauvis",
    dest = "vulcanus",
    capacity = 1000,
    timeout = 3600,
    items = {
      { item = "iron-plate", surplus = 500, unmet = 800 },
      { item = "copper-plate", surplus = 300, unmet = 200 },
    },
  })

  assert_eq(#built.records, 2, "exactly two stops (v1 emitter)")

  -- wait conditions are scoped to the manifest items (per-item item_count), in
  -- stable item order, with the timeout OR-ed on -- never a whole-hold full/empty.
  -- The item_count first_signal carries (name, quality) decoded from the cargo
  -- qkey (Task 11, #4d); a bare item-name key decodes to "normal".
  local function loaded(item, qty)
    return { type = "item_count", compare_type = "and",
      condition = { comparator = ">=",
        first_signal = { type = "item", name = item, quality = "normal" }, constant = qty } }
  end
  local function delivered(item)
    return { type = "item_count", compare_type = "and",
      condition = { comparator = "=",
        first_signal = { type = "item", name = item, quality = "normal" }, constant = 0 } }
  end
  local timeout_or = { type = "time", ticks = 3600, compare_type = "or" }

  -- source stop: the clamped wide manifest as per-stop requests
  local src = built.records[1]
  assert_eq(src.station, "nauvis", "first stop is the source planet")
  assert_eq(src.requests, { ["iron-plate"] = 500, ["copper-plate"] = 200 },
    "source requests are the clamped wide manifest")
  assert_eq(src.import_from, "nauvis", "source request is scoped to the source planet")
  assert_eq(src.allows_unloading, false, "load stop must NOT allow unloading (source won't pull our cargo back)")
  -- copper sorts before iron, so its item_count comes first
  assert_eq(src.wait_conditions[1], loaded("copper-plate", 200), "source waits on copper loaded")
  assert_eq(src.wait_conditions[2], loaded("iron-plate", 500), "source waits on iron loaded")
  assert_eq(src.wait_conditions[3], timeout_or, "source manifest-loaded OR timeout")

  -- dest stop: native unload -> no requests, per-item delivered (==0) OR timeout
  local dst = built.records[2]
  assert_eq(dst.station, "vulcanus", "second stop is the destination planet")
  assert_eq(dst.requests, {}, "destination has no explicit cargo request (native unload)")
  assert_eq(dst.allows_unloading, true, "drop stop allows unloading (dest pad pulls the cargo)")
  assert_eq(dst.wait_conditions[1], delivered("copper-plate"), "destination waits on copper delivered")
  assert_eq(dst.wait_conditions[2], delivered("iron-plate"), "destination waits on iron delivered")
  assert_eq(dst.wait_conditions[3], { type = "inactivity", ticks = 300, compare_type = "or" },
    "destination also departs on inactivity (retained cargo never hits item==0)")
  assert_eq(dst.wait_conditions[4], timeout_or, "... or the timeout backstop")

  -- the built manifest is exposed for the dispatcher's bookkeeping (Task 5)
  assert_eq(built.manifest, { ["iron-plate"] = 500, ["copper-plate"] = 200 },
    "manifest mirrors the source requests")
end)

describe("schedule.build_records -- zero manifest -> no schedule", function()
  -- nothing loadable (no surplus) -> no records at all
  assert_eq(schedule.build_records({
    source = "nauvis", dest = "vulcanus", capacity = 1000, timeout = 3600,
    items = { { item = "iron-plate", surplus = 0, unmet = 800 } },
  }), nil, "no surplus anywhere -> nil (no schedule written)")

  -- zero capacity -> nothing loads -> no schedule
  assert_eq(schedule.build_records({
    source = "nauvis", dest = "vulcanus", capacity = 0, timeout = 3600,
    items = { { item = "iron-plate", surplus = 500, unmet = 800 } },
  }), nil, "zero capacity -> nil")

  -- no items at all -> no schedule
  assert_eq(schedule.build_records({
    source = "nauvis", dest = "vulcanus", capacity = 1000, timeout = 3600, items = {},
  }), nil, "empty items -> nil")
end)

describe("schedule.write -- thin wrapper over the pure builder", function()
  -- stub writer captures what would hit the engine; save the real one so we don't
  -- clobber the module default (apply_records) on restore.
  local saved_writer = schedule.writer
  local captured = nil
  schedule.writer = function(_platform, records)
    captured = records
    return true
  end

  local assignment = {
    source = "nauvis", dest = "vulcanus", capacity = 1000, timeout = 3600,
    items = { { item = "iron-plate", surplus = 500, unmet = 800 } },
  }
  local built = schedule.write({ valid = true }, assignment)
  assert_eq(built.manifest, { ["iron-plate"] = 500 }, "write returns the built manifest")
  assert_eq(captured, built.records, "writer receives the built records")

  -- empty trip writes nothing
  captured = nil
  local none = schedule.write({ valid = true }, {
    source = "nauvis", dest = "vulcanus", capacity = 1000, timeout = 3600,
    items = { { item = "iron-plate", surplus = 0, unmet = 800 } },
  })
  assert_eq(none, nil, "empty trip -> write returns nil")
  assert_eq(captured, nil, "writer not called for an empty trip")

  schedule.writer = saved_writer
end)

-- ---------------------------------------------------------------------------
-- Task 5: dispatcher -- exportable() thrash guard, best-source selection,
-- ship pick, and the pure planner (wide load, no-double-claim, re-export,
-- no-source / all-busy edges). The on_nth_tick wiring + real ship/schedule IO
-- are verified by manual playtest.
-- ---------------------------------------------------------------------------

local dispatcher = require("scripts.dispatcher")

describe("dispatcher.exportable -- thrash guard", function()
  -- surplus is exportable only when the node has NO open demand for the item
  local node = {
    surplus = { ["iron-plate"] = 400, ["coal"] = 50 },
    unmet_by_item = { ["coal"] = 30 }, -- node still importing coal
  }
  assert_eq(dispatcher.exportable(node, "iron-plate"), 400, "no open demand -> full surplus exportable")
  assert_eq(dispatcher.exportable(node, "coal"), 0, "open demand for the item -> NOT a source (guard)")
  assert_eq(dispatcher.exportable(node, "stone"), 0, "no surplus -> 0")
  assert_eq(dispatcher.exportable(nil, "iron-plate"), 0, "nil node -> 0")
  -- re-export: a node that merely RECEIVED an item (surplus, no demand) is a
  -- valid source -- production is irrelevant.
  local hub = { surplus = { ["uranium-235"] = 12 }, unmet_by_item = {} }
  assert_eq(dispatcher.exportable(hub, "uranium-235"), 12, "received-only stock is exportable (re-export)")
end)

describe("dispatcher.net_surplus -- min-trip re-clamp on the post-committed value", function()
  -- raw already passes min-trip (stock.surplus floors it pre-commit); the NET
  -- value after subtracting in-flight bookkeeping can fall back below min-trip
  -- and must be suppressed rather than dispatched as a dribble.
  assert_eq(dispatcher.net_surplus(100, 0, 50), 100, "no commitment, above min-trip -> full net")
  assert_eq(dispatcher.net_surplus(100, 20, 50), 80, "net 80 >= min-trip 50 -> net survives")
  assert_eq(dispatcher.net_surplus(100, 50, 50), 50, "net exactly at min-trip -> survives (inclusive)")
  assert_eq(dispatcher.net_surplus(100, 60, 50), 0, "net 40 < min-trip 50 -> suppressed dribble")
  assert_eq(dispatcher.net_surplus(100, 100, 50), 0, "net 0 (fully committed) -> 0")
  assert_eq(dispatcher.net_surplus(100, 120, 50), 0, "over-committed (negative net) -> clamped to 0")
  assert_eq(dispatcher.net_surplus(40, 0, 50), 0, "raw below min-trip with no commit -> still suppressed")
  assert_eq(dispatcher.net_surplus(100, nil, 50), 100, "nil committed treated as 0")
  assert_eq(dispatcher.net_surplus(80, nil, 50), 80, "nil committed, above min-trip -> full raw")
end)

describe("dispatcher.best_source -- most coverage, nearest tie-break, id tie-break", function()
  -- dest needs iron 100 + copper 100. nauvis covers both (200), vulcanus only
  -- iron (100). Most-coverage picks nauvis even though vulcanus also qualifies.
  local snapshot = {
    nodes = {
      [1] = { id = 1, planet = "dest", demand = {
        { item = "iron-plate", unmet = 100, priority = 0 },
        { item = "copper-plate", unmet = 100, priority = 0 },
      } },
      [2] = { id = 2, planet = "nauvis", surplus = { ["iron-plate"] = 500, ["copper-plate"] = 500 }, unmet_by_item = {} },
      [3] = { id = 3, planet = "vulcanus", surplus = { ["iron-plate"] = 500 }, unmet_by_item = {} },
    },
  }
  local best = dispatcher.best_source(snapshot, snapshot.nodes[1])
  assert_eq(best.id, 2, "source covering the most demand is chosen")
  assert_eq(best.coverage, 200, "coverage sums min(exportable,unmet) across items")

  -- coverage capped by unmet (not raw surplus): unmet 40 caps the 500 surplus.
  local capped = {
    nodes = {
      [1] = { id = 1, planet = "dest", demand = { { item = "iron-plate", unmet = 40, priority = 0 } } },
      [2] = { id = 2, planet = "src", surplus = { ["iron-plate"] = 500 }, unmet_by_item = {} },
    },
  }
  assert_eq(dispatcher.best_source(capped, capped.nodes[1]).coverage, 40, "coverage capped by unmet")

  -- the guard removes a candidate that is itself importing the item
  local guarded = {
    nodes = {
      [1] = { id = 1, planet = "dest", demand = { { item = "coal", unmet = 100, priority = 0 } } },
      [2] = { id = 2, planet = "importer", surplus = { ["coal"] = 500 }, unmet_by_item = { ["coal"] = 10 } },
    },
  }
  assert_eq(dispatcher.best_source(guarded, guarded.nodes[1]), nil, "guarded candidate is not a source -> nil")

  -- nearest tie-break: equal coverage, override distance so node 3 is nearer
  local tie = {
    nodes = {
      [1] = { id = 1, planet = "dest", demand = { { item = "iron-plate", unmet = 100, priority = 0 } } },
      [2] = { id = 2, planet = "far", surplus = { ["iron-plate"] = 500 }, unmet_by_item = {} },
      [3] = { id = 3, planet = "near", surplus = { ["iron-plate"] = 500 }, unmet_by_item = {} },
    },
  }
  local saved_distance = dispatcher.distance
  dispatcher.distance = function(planet, _dest) return planet == "near" and 1 or 9 end
  assert_eq(dispatcher.best_source(tie, tie.nodes[1]).id, 3, "equal coverage -> nearest wins")

  -- id tie-break: equal coverage AND equal distance -> lowest id
  dispatcher.distance = function(_a, _b) return 5 end
  assert_eq(dispatcher.best_source(tie, tie.nodes[1]).id, 2, "equal coverage+distance -> lowest id")
  dispatcher.distance = saved_distance

  -- no source can cover anything -> nil
  local none = {
    nodes = {
      [1] = { id = 1, planet = "dest", demand = { { item = "iron-plate", unmet = 100, priority = 0 } } },
      [2] = { id = 2, planet = "src", surplus = {}, unmet_by_item = {} },
    },
  }
  assert_eq(dispatcher.best_source(none, none.nodes[1]), nil, "no surplus anywhere -> no source")
end)

describe("dispatcher force isolation -- sources/ships matched within a force", function()
  -- two forces on the same planets. Force A's surplus must NOT feed force B's
  -- demand: the only eligible source for A's dest is the same-force node 3.
  local snapshot = {
    nodes = {
      [1] = { id = 1, planet = "dest", force = "A",
        demand = { { item = "iron-plate", unmet = 100, priority = 0 } } },
      [2] = { id = 2, planet = "src", force = "B",            -- other force: ineligible
        surplus = { ["iron-plate"] = 500 }, unmet_by_item = {} },
      [3] = { id = 3, planet = "src", force = "A",            -- same force: the source
        surplus = { ["iron-plate"] = 500 }, unmet_by_item = {} },
    },
  }
  assert_eq(dispatcher.best_source(snapshot, snapshot.nodes[1]).id, 3,
    "only the same-force source is chosen (the other force's surplus is skipped)")

  -- ship filter keeps only the route's force, preserving order.
  local ships = { { id = 10, force = "A" }, { id = 11, force = "B" }, { id = 12, force = "A" } }
  local a_ships = dispatcher.ships_for_force(ships, "A")
  assert_eq(#a_ships, 2, "two force-A ships kept")
  assert_eq(a_ships[1].id, 10, "force-A ships retained in order (first)")
  assert_eq(a_ships[2].id, 12, "force-A ships retained in order (second); force-B dropped")

  -- nil force matches nil-force ships (the single-force / test default path)
  assert_eq(#dispatcher.ships_for_force(ships, nil), 0, "a nil route force keeps no force-tagged ship")
  assert_eq(#dispatcher.ships_for_force({ { id = 1 }, { id = 2 } }, nil), 2,
    "nil route force keeps nil-force ships (single-force default)")
end)

describe("dispatcher.pick_ship -- eligibility, determinism, pin override", function()
  local function ship(id, opts)
    opts = opts or {}
    return {
      id = id,
      capacity = 1000,
      entry = {
        enrolled = opts.enrolled ~= false,
        state = opts.state or fleet.IDLE,
        assignment = opts.assignment,
        allowed_planets = opts.allowed_planets,
        reserve_for_manual_use = opts.reserved,
      },
    }
  end

  -- lowest-id eligible ship is chosen
  local ships = { ship(5), ship(2), ship(9) }
  assert_eq(dispatcher.pick_ship(ships, {}, "nauvis", "vulcanus").id, 2, "lowest-id eligible ship")

  -- already-used ships are skipped
  assert_eq(dispatcher.pick_ship(ships, { [2] = true }, "nauvis", "vulcanus").id, 5, "used ship skipped")

  -- ineligible ships (busy / un-enrolled / reserved) are skipped
  local mixed = {
    ship(1, { state = fleet.ENROUTE }),
    ship(2, { enrolled = false }),
    ship(3, { reserved = true }),
    ship(4),
  }
  assert_eq(dispatcher.pick_ship(mixed, {}, "nauvis", "vulcanus").id, 4, "first eligible after ineligibles")

  -- allow-list must cover both endpoints
  local restricted = { ship(1, { allowed_planets = { "nauvis" } }), ship(2) }
  assert_eq(dispatcher.pick_ship(restricted, {}, "nauvis", "vulcanus").id, 2, "ship not covering both planets skipped")

  -- none free -> nil (demand waits)
  assert_eq(dispatcher.pick_ship({ ship(1, { state = fleet.ENROUTE }) }, {}, "nauvis", "vulcanus"), nil,
    "no eligible ship -> nil (demand waits)")

  -- a manual pin overrides auto-pick when the pinned ship is free + eligible
  assert_eq(dispatcher.pick_ship(ships, {}, "nauvis", "vulcanus", 9).id, 9, "pin overrides lowest-id auto-pick")
  -- pin that is ineligible falls back to auto-pick
  local pinnable = { ship(2), ship(7, { state = fleet.ENROUTE }) }
  assert_eq(dispatcher.pick_ship(pinnable, {}, "nauvis", "vulcanus", 7).id, 2, "ineligible pin falls back to auto-pick")
end)

describe("dispatcher.plan -- wide load, re-export, deterministic assignment", function()
  -- one source has both items the dest needs; ample-capacity ship loads WIDE.
  local snapshot = {
    nodes = {
      [1] = { id = 1, planet = "gleba", demand = {
        { item = "iron-plate", unmet = 300, priority = 5 },
        { item = "copper-plate", unmet = 200, priority = 1 },
      }, surplus = {}, unmet_by_item = {} },
      -- source only RECEIVED these goods (re-export); no production modeled.
      [2] = { id = 2, planet = "nauvis",
        surplus = { ["iron-plate"] = 500, ["copper-plate"] = 500 }, unmet_by_item = {} },
    },
    ships = { { id = 10, capacity = 1000, entry = { enrolled = true, state = fleet.IDLE } } },
  }
  local plans = dispatcher.plan(snapshot)
  assert_eq(#plans, 1, "one assignment planned")
  assert_eq(plans[1].source_id, 2, "re-export source selected (received-only stock)")
  assert_eq(plans[1].dest_id, 1, "destination is the demanding node")
  assert_eq(plans[1].ship_id, 10, "the only eligible ship is used")
  assert_eq(plans[1].manifest, { ["iron-plate"] = 300, ["copper-plate"] = 200 },
    "wide load: both items, each clamped to unmet")
end)

describe("dispatcher.plan -- wide load clamped to ship capacity (priority order)", function()
  local snapshot = {
    nodes = {
      [1] = { id = 1, planet = "dest", demand = {
        { item = "iron-plate", unmet = 800, priority = 5 },   -- higher priority first
        { item = "copper-plate", unmet = 800, priority = 1 },
      }, surplus = {}, unmet_by_item = {} },
      [2] = { id = 2, planet = "src",
        surplus = { ["iron-plate"] = 1000, ["copper-plate"] = 1000 }, unmet_by_item = {} },
    },
    ships = { { id = 1, capacity = 600, entry = { enrolled = true, state = fleet.IDLE } } },
  }
  local plans = dispatcher.plan(snapshot)
  -- 600 capacity, both items demanded: fair share gives each 300, so a single
  -- ship carries BOTH items instead of one filling the whole hold.
  assert_eq(plans[1].manifest, { ["iron-plate"] = 300, ["copper-plate"] = 300 },
    "fair share: one ship carries both demanded items")
end)

describe("dispatcher.plan -- no-double-claim across destinations sharing a source", function()
  -- two destinations both want iron from the same source; only 300 surplus.
  -- The first-served destination (stable id order) takes it; the second gets
  -- only the remainder. A second ship exists so ship supply isn't the limit.
  local snapshot = {
    nodes = {
      [1] = { id = 1, planet = "destA", demand = { { item = "iron-plate", unmet = 250, priority = 0 } },
        surplus = {}, unmet_by_item = {} },
      [2] = { id = 2, planet = "destB", demand = { { item = "iron-plate", unmet = 250, priority = 0 } },
        surplus = {}, unmet_by_item = {} },
      [3] = { id = 3, planet = "src", surplus = { ["iron-plate"] = 300 }, unmet_by_item = {} },
    },
    ships = {
      { id = 1, capacity = 1000, entry = { enrolled = true, state = fleet.IDLE } },
      { id = 2, capacity = 1000, entry = { enrolled = true, state = fleet.IDLE } },
    },
  }
  local plans = dispatcher.plan(snapshot)
  assert_eq(#plans, 2, "both destinations get an assignment")
  -- destA (lower id) served first: takes 250
  assert_eq(plans[1].dest_id, 1, "lower-id destination served first")
  assert_eq(plans[1].manifest, { ["iron-plate"] = 250 }, "first destination claims its full demand")
  -- destB gets only the remaining 50 (300 - 250) -- surplus was decremented
  assert_eq(plans[2].dest_id, 2, "second destination served next")
  assert_eq(plans[2].manifest, { ["iron-plate"] = 50 }, "remaining surplus only -> no double-claim")
end)

describe("dispatcher.active_counts -- global + per-route tallies", function()
  local g, by_route = dispatcher.active_counts({
    [1] = { source = 3, dest = 1 },
    [2] = { source = 3, dest = 1 },
    [3] = { source = 4, dest = 2 },
  })
  assert_eq(g, 3, "global count = total in-flight assignments")
  assert_eq(by_route["3|1"], 2, "two ships on route 3->1")
  assert_eq(by_route["4|2"], 1, "one ship on route 4->2")

  local g0, br0 = dispatcher.active_counts(nil)
  assert_eq(g0, 0, "nil assignments -> 0 global")
  assert_eq(next(br0), nil, "nil assignments -> empty per-route map")
end)

describe("dispatcher.plan -- max concurrent ships caps (Task 10)", function()
  -- Two independent routes, each with its own source + idle ship: uncapped this
  -- plans two assignments.
  local function two_route_snapshot(extra)
    local snap = {
      nodes = {
        [1] = { id = 1, planet = "destA", demand = { { item = "iron-plate", unmet = 100, priority = 0 } },
          surplus = {}, unmet_by_item = {} },
        [2] = { id = 2, planet = "destB", demand = { { item = "copper-plate", unmet = 100, priority = 0 } },
          surplus = {}, unmet_by_item = {} },
        [3] = { id = 3, planet = "srcA", surplus = { ["iron-plate"] = 500 }, unmet_by_item = {} },
        [4] = { id = 4, planet = "srcB", surplus = { ["copper-plate"] = 500 }, unmet_by_item = {} },
      },
      ships = {
        { id = 1, capacity = 1000, entry = { enrolled = true, state = fleet.IDLE } },
        { id = 2, capacity = 1000, entry = { enrolled = true, state = fleet.IDLE } },
      },
    }
    for k, v in pairs(extra or {}) do
      snap[k] = v
    end
    return snap
  end

  assert_eq(#dispatcher.plan(two_route_snapshot()), 2, "uncapped (caps absent) -> both routes plan")
  assert_eq(#dispatcher.plan(two_route_snapshot({ max_ships_global = 0 })), 2, "0 = unlimited global")

  -- global cap of 1: only the lower-id destination is served this tick.
  local capped = dispatcher.plan(two_route_snapshot({ max_ships_global = 1 }))
  assert_eq(#capped, 1, "global cap 1 -> only one assignment this tick")
  assert_eq(capped[1].dest_id, 1, "lower-id destination wins the single slot")

  -- existing in-flight count already at the cap -> nothing new dispatches.
  assert_eq(#dispatcher.plan(two_route_snapshot({ max_ships_global = 2, active_global = 2 })), 0,
    "already at global cap -> demand waits")

  -- per-route cap: route 3->1 already has a ship in flight, cap 1 -> route 3->1
  -- is blocked, but route 4->2 still plans.
  local route_capped = dispatcher.plan(two_route_snapshot({
    max_ships_route = 1,
    active_by_route = { ["3|1"] = 1 },
  }))
  assert_eq(#route_capped, 1, "per-route cap blocks the saturated route only")
  assert_eq(route_capped[1].dest_id, 2, "the unsaturated route still dispatches")
end)

describe("dispatcher.plan -- all-busy and no-source edges", function()
  -- demand exists, source exists, but no eligible ship -> nothing planned (waits)
  local busy = {
    nodes = {
      [1] = { id = 1, planet = "dest", demand = { { item = "iron-plate", unmet = 100, priority = 0 } },
        surplus = {}, unmet_by_item = {} },
      [2] = { id = 2, planet = "src", surplus = { ["iron-plate"] = 500 }, unmet_by_item = {} },
    },
    ships = { { id = 1, capacity = 1000, entry = { enrolled = true, state = fleet.ENROUTE } } },
  }
  assert_eq(#dispatcher.plan(busy), 0, "no eligible ship -> demand waits (no plan)")

  -- demand exists but no surplus anywhere -> nothing planned
  local no_src = {
    nodes = {
      [1] = { id = 1, planet = "dest", demand = { { item = "iron-plate", unmet = 100, priority = 0 } },
        surplus = {}, unmet_by_item = {} },
      [2] = { id = 2, planet = "src", surplus = {}, unmet_by_item = {} },
    },
    ships = { { id = 1, capacity = 1000, entry = { enrolled = true, state = fleet.IDLE } } },
  }
  assert_eq(#dispatcher.plan(no_src), 0, "no source -> no plan")

  -- no demand at all -> nothing planned
  local idle = {
    nodes = { [1] = { id = 1, planet = "dest", demand = {}, surplus = {}, unmet_by_item = {} } },
    ships = { { id = 1, capacity = 1000, entry = { enrolled = true, state = fleet.IDLE } } },
  }
  assert_eq(#dispatcher.plan(idle), 0, "no demand -> no plan")
end)

describe("dispatcher.plan -- guard blocks importing-and-exporting the same item", function()
  -- the only candidate source has surplus of iron but ALSO open demand for iron;
  -- the guard removes it, so no source -> no plan (it never re-exports what it
  -- is still importing).
  local snapshot = {
    nodes = {
      [1] = { id = 1, planet = "dest", demand = { { item = "iron-plate", unmet = 100, priority = 0 } },
        surplus = {}, unmet_by_item = {} },
      [2] = { id = 2, planet = "conflicted", surplus = { ["iron-plate"] = 500 },
        unmet_by_item = { ["iron-plate"] = 20 } },
    },
    ships = { { id = 1, capacity = 1000, entry = { enrolled = true, state = fleet.IDLE } } },
  }
  assert_eq(#dispatcher.plan(snapshot), 0, "thrash guard: a node importing iron is never an iron source")
end)

describe("dispatcher.plan -- two-way return leg nets the source's demand within the tick", function()
  -- Reciprocal trade: A needs X / has Y, B needs Y / has X, two idle ships,
  -- two_way enabled. The first plan (A as dest) ships X A<-B and picks up a
  -- RETURN leg of Y B<-A. That return leg covers ALL of B's demand for Y, so
  -- when B is considered as a destination next, the planner must NOT re-ship Y
  -- to B again -- the within-tick credit_inbound on the SOURCE (A's forward = B's
  -- return dest) nets B's demand to zero.
  local snapshot = {
    two_way = true,
    nodes = {
      [1] = { id = 1, planet = "A", demand = { { item = "X", unmet = 200, priority = 0 } },
        surplus = { ["Y"] = 500 }, unmet_by_item = { ["X"] = 200 } },
      [2] = { id = 2, planet = "B", demand = { { item = "Y", unmet = 200, priority = 0 } },
        surplus = { ["X"] = 500 }, unmet_by_item = { ["Y"] = 200 } },
    },
    ships = {
      { id = 1, capacity = 1000, entry = { enrolled = true, state = fleet.IDLE } },
      { id = 2, capacity = 1000, entry = { enrolled = true, state = fleet.IDLE } },
    },
  }
  local plans = dispatcher.plan(snapshot)
  -- exactly ONE forward plan (A<-B for X) with a Y return leg; B is fully served
  -- by that return leg, so it produces no second forward plan.
  assert_eq(#plans, 1, "reciprocal trade fits one ship round-trip -> a single plan")
  assert_eq(plans[1].dest_id, 1, "lower-id destination (A) planned")
  assert_eq(plans[1].source_id, 2, "B is the forward source")
  assert_eq(plans[1].manifest, { ["X"] = 200 }, "forward leg ships X to A")
  assert_eq(plans[1].return_manifest, { ["Y"] = 200 }, "return leg ships Y back to B")
end)

describe("dispatcher.plan -- 3-node forward-then-return decrements the SOURCE's demand", function()
  -- S(1) needs X / has W, T(2) has X, D(3) needs W / has X. The forward leg
  -- T->S ships X to S (S as a destination). Then D (as a destination) needs W
  -- and sources it from S, picking up a RETURN leg of X back to... no -- the
  -- forward T->S leg already credited S with X, so when D's plan considers
  -- shipping X anywhere to S, S's demand for X is already netted to zero. This
  -- pins the FORWARD-side decrement: without crediting S on the forward leg,
  -- D's return leg would re-read S's un-netted X demand and ship it again.
  local snapshot = {
    two_way = true,
    nodes = {
      [1] = { id = 1, planet = "S", demand = { { item = "X", unmet = 150, priority = 0 } },
        surplus = { ["W"] = 500 }, unmet_by_item = { ["X"] = 150 } },
      [2] = { id = 2, planet = "T", demand = {},
        surplus = { ["X"] = 500 }, unmet_by_item = {} },
      [3] = { id = 3, planet = "D", demand = { { item = "W", unmet = 150, priority = 0 } },
        surplus = { ["X"] = 500 }, unmet_by_item = { ["W"] = 150 } },
    },
    ships = {
      { id = 1, capacity = 1000, entry = { enrolled = true, state = fleet.IDLE } },
      { id = 2, capacity = 1000, entry = { enrolled = true, state = fleet.IDLE } },
    },
  }
  local plans = dispatcher.plan(snapshot)
  -- S (id 1) served first: X from T. D (id 3) served next: W from S, with a
  -- return leg of X back to S -- BUT S's X demand was already netted by the
  -- forward T->S leg, so the return leg must carry NO X.
  assert_eq(#plans, 2, "both demanding nodes planned")
  assert_eq(plans[1].dest_id, 1, "S served first (X from T)")
  assert_eq(plans[1].manifest, { ["X"] = 150 }, "forward leg ships X to S")
  assert_eq(plans[2].dest_id, 3, "D served next (W from S)")
  assert_eq(plans[2].source_id, 1, "D sources W from S")
  assert_eq(plans[2].manifest, { ["W"] = 150 }, "forward leg ships W to D")
  assert_eq(plans[2].return_manifest, nil,
    "return leg carries NO X to S: the forward T->S leg already netted S's X demand")
end)

describe("dispatcher.plan -- partial return coverage leaves only the remainder plannable", function()
  -- A needs 200 X / has Y; B needs Y / has X. B can only return 50 Y (small
  -- surplus), so A's forward leg covers X but the return leg covers only PART of
  -- B's Y demand (50 of 200). The remainder (150) must still be plannable -- a
  -- third node C with Y surplus + an idle ship serves it.
  local snapshot = {
    two_way = true,
    nodes = {
      [1] = { id = 1, planet = "A", demand = { { item = "X", unmet = 200, priority = 0 } },
        surplus = { ["Y"] = 50 }, unmet_by_item = { ["X"] = 200 } },
      [2] = { id = 2, planet = "B", demand = { { item = "Y", unmet = 200, priority = 0 } },
        surplus = { ["X"] = 500 }, unmet_by_item = { ["Y"] = 200 } },
      [3] = { id = 3, planet = "C", demand = {},
        surplus = { ["Y"] = 500 }, unmet_by_item = {} },
    },
    ships = {
      { id = 1, capacity = 1000, entry = { enrolled = true, state = fleet.IDLE } },
      { id = 2, capacity = 1000, entry = { enrolled = true, state = fleet.IDLE } },
    },
  }
  local plans = dispatcher.plan(snapshot)
  assert_eq(#plans, 2, "A's round-trip plus a second plan for B's remainder")
  assert_eq(plans[1].dest_id, 1, "A served first")
  assert_eq(plans[1].return_manifest, { ["Y"] = 50 }, "return leg covers only A's small Y surplus")
  assert_eq(plans[2].dest_id, 2, "B's remaining Y demand still served")
  assert_eq(plans[2].source_id, 3, "remainder sourced from C")
  assert_eq(plans[2].manifest, { ["Y"] = 150 },
    "only the remainder (200 - 50 already inbound) is shipped -- no double-serve, no under-serve")
end)

describe("dispatcher.plan -- forward-served demand closes the export-re-open hole", function()
  -- A both DEMANDS X (200) and HOLDS X surplus (500). A is served forward this
  -- tick (X from B), which nets A's X demand to 0. The composition rule must then
  -- ZERO A's working X surplus -- otherwise exportable(A, X) re-opens (unmet == 0
  -- now) and a later destination C could export the very X A just received.
  local snapshot = {
    two_way = false,  -- isolate the forward-leg export-re-open path (no return leg)
    nodes = {
      [1] = { id = 1, planet = "A", demand = { { item = "X", unmet = 200, priority = 0 } },
        surplus = { ["X"] = 500 }, unmet_by_item = { ["X"] = 200 } },
      [2] = { id = 2, planet = "B", demand = {},
        surplus = { ["X"] = 500 }, unmet_by_item = {} },
      [3] = { id = 3, planet = "C", demand = { { item = "X", unmet = 200, priority = 0 } },
        surplus = {}, unmet_by_item = { ["X"] = 200 } },
    },
    ships = {
      { id = 1, capacity = 1000, entry = { enrolled = true, state = fleet.IDLE } },
      { id = 2, capacity = 1000, entry = { enrolled = true, state = fleet.IDLE } },
    },
  }
  local plans = dispatcher.plan(snapshot)
  -- A (id 1) served from B. C (id 3) served next: its X must come from B (B still
  -- has 300 left), NEVER from A -- A's surplus was zeroed when its X demand hit 0.
  assert_eq(#plans, 2, "A and C both served")
  assert_eq(plans[1].dest_id, 1, "A served first")
  assert_eq(plans[1].source_id, 2, "A sources X from B")
  assert_eq(plans[2].dest_id, 3, "C served next")
  assert_eq(plans[2].source_id, 2,
    "C sources X from B, NOT from A: A's surplus was zeroed when its demand hit 0 (no export re-open)")
  -- belt-and-braces: exportable(A, X) is 0 after the forward leg nets A's demand
  assert_eq(dispatcher.exportable(snapshot.nodes[1], "X"), 0,
    "exportable(A, X) stays 0: surplus zeroed alongside the unmet decrement")
end)

describe("dispatcher.unserved_reason -- one branch per gate (diagnostic over the snapshot)", function()
  -- helper: contains-substring assertion (the reason strings are human prose).
  local function reason_has(reason, needle, msg)
    assert_true(type(reason) == "string" and reason:find(needle, 1, true) ~= nil, msg)
  end

  -- BRANCH 1: no exportable source. Demand exists; the only other node has no
  -- surplus, so best_source returns nil.
  local no_source = {
    nodes = {
      [1] = { id = 1, planet = "dest", force = "A",
        demand = { { item = "iron-plate", unmet = 100, priority = 0 } },
        surplus = {}, unmet_by_item = {} },
      [2] = { id = 2, planet = "src", force = "A", surplus = {}, unmet_by_item = {} },
    },
    ships = { { id = 1, capacity = 1000, force = "A", entry = { enrolled = true, state = fleet.IDLE } } },
  }
  reason_has(dispatcher.unserved_reason(no_source, no_source.nodes[1]),
    "no exportable source", "no-source branch names the missing source")

  -- BRANCH 2: source exists, but no idle eligible ship for the dest's force.
  local no_ship = {
    nodes = {
      [1] = { id = 1, planet = "dest", force = "A",
        demand = { { item = "iron-plate", unmet = 100, priority = 0 } },
        surplus = {}, unmet_by_item = {} },
      [2] = { id = 2, planet = "src", force = "A",
        surplus = { ["iron-plate"] = 500 }, unmet_by_item = {} },
    },
    -- the only ship belongs to a DIFFERENT force, so ships_for_force drops it
    ships = { { id = 1, capacity = 1000, force = "B", entry = { enrolled = true, state = fleet.IDLE } } },
  }
  reason_has(dispatcher.unserved_reason(no_ship, no_ship.nodes[1]),
    "NO idle eligible ship", "no-ship branch names the ship gate")

  -- BRANCH 3: source + ship both exist, but the ship has ZERO slots -> the
  -- manifest re-pack loads nothing. stack_size IS threaded into that re-pack
  -- (the demand row carries one); with 0 slots it cannot matter, proving the
  -- branch is reached, and the next case proves stack_size doesn't FALSELY trip it.
  local nothing_loads = {
    nodes = {
      [1] = { id = 1, planet = "dest", force = "A",
        demand = { { item = "iron-plate", unmet = 100, priority = 0, stack_size = 100 } },
        surplus = {}, unmet_by_item = {} },
      [2] = { id = 2, planet = "src", force = "A",
        surplus = { ["iron-plate"] = 500 }, unmet_by_item = {} },
    },
    ships = { { id = 1, capacity = 0, force = "A", entry = { enrolled = true, state = fleet.IDLE } } },
  }
  reason_has(dispatcher.unserved_reason(nothing_loads, nothing_loads.nodes[1]),
    "nothing loads", "nothing-loads branch fires when capacity (slots) is 0")

  -- stack_size threading (positive): a ship with slots > 0 and a stacked demand
  -- DOES load (re-pack uses stack_size to convert slots->items), so the reason is
  -- the would-dispatch tail, NOT a false "nothing loads".
  local loads_ok = {
    nodes = {
      [1] = { id = 1, planet = "dest", force = "A",
        demand = { { item = "iron-plate", unmet = 100, priority = 0, stack_size = 100 } },
        surplus = {}, unmet_by_item = {} },
      [2] = { id = 2, planet = "src", force = "A",
        surplus = { ["iron-plate"] = 500 }, unmet_by_item = {} },
    },
    ships = { { id = 1, capacity = 5, force = "A", entry = { enrolled = true, state = fleet.IDLE } } },
  }
  local ok_reason = dispatcher.unserved_reason(loads_ok, loads_ok.nodes[1])
  assert_true(type(ok_reason) == "string" and ok_reason:find("nothing loads", 1, true) == nil,
    "stack_size threaded: a stacked manifest loads (not a false nothing-loads)")
  reason_has(ok_reason, "would dispatch", "loadable + free ship + uncapped route -> would-dispatch tail")

  -- BRANCH 4: source + ship + loadable manifest, but the route is AT CAP.
  local at_cap = {
    nodes = {
      [1] = { id = 1, planet = "dest", force = "A",
        demand = { { item = "iron-plate", unmet = 100, priority = 0, stack_size = 100 } },
        surplus = {}, unmet_by_item = {} },
      [2] = { id = 2, planet = "src", force = "A",
        surplus = { ["iron-plate"] = 500 }, unmet_by_item = {} },
    },
    ships = { { id = 1, capacity = 5, force = "A", entry = { enrolled = true, state = fleet.IDLE } } },
    max_ships_route = 1,
    active_by_route = { [dispatcher.route_key(2, 1)] = 1 },
  }
  reason_has(dispatcher.unserved_reason(at_cap, at_cap.nodes[1]),
    "AT CAP", "route-cap branch fires when the route is saturated")
end)

-- ---------------------------------------------------------------------------
-- Task 6: watchdog -- pure re-clamp amount, order-stable schedule signature,
-- and deadline expiry. The watchdog loop itself (timeout / destroyed / player-
-- edit / arrival re-clamp IO) is verified by manual playtest.
-- ---------------------------------------------------------------------------

local watchdog = require("scripts.watchdog")

describe("watchdog.reclamp_amount -- lower-only min(old, current surplus)", function()
  assert_eq(watchdog.reclamp_amount(500, 800), 500, "surplus higher than committed -> keep committed (no raise)")
  assert_eq(watchdog.reclamp_amount(500, 300), 300, "surplus dropped -> lower to current surplus")
  assert_eq(watchdog.reclamp_amount(500, 500), 500, "equal -> unchanged")
  assert_eq(watchdog.reclamp_amount(500, 0), 0, "surplus gone -> request nothing")
  assert_eq(watchdog.reclamp_amount(0, 500), 0, "nothing committed -> stays zero")
  assert_eq(watchdog.reclamp_amount(nil, nil), 0, "nil inputs -> 0")
  assert_eq(watchdog.reclamp_amount(500, -10), 0, "negative surplus clamps at 0")
end)

describe("watchdog.expired -- no-progress deadline", function()
  assert_eq(watchdog.expired(1000, 999), false, "before the deadline -> not expired")
  assert_true(watchdog.expired(1000, 1000), "at the deadline tick -> expired")
  assert_true(watchdog.expired(1000, 1001), "past the deadline -> expired")
  assert_eq(watchdog.expired(nil, 999999), false, "no deadline -> never expires (defensive)")
end)

describe("watchdog.advanced -- progress (stop advance) resets the deadline", function()
  assert_true(watchdog.advanced(nil, 1), "first observation counts as progress")
  assert_true(watchdog.advanced(1, 2), "moving to a later stop is progress")
  assert_eq(watchdog.advanced(2, 2), false, "same stop is not progress")
  assert_eq(watchdog.advanced(2, 1), false, "a lower index is not progress")
  assert_eq(watchdog.advanced(1, nil), false, "unreadable current -> no progress (defensive)")
end)

describe("watchdog.other_committed -- re-clamp nets out concurrent commitments", function()
  local saved_storage = storage
  storage = { assignments = {
    [1] = { source = 7, surplus_commit = { ["iron-plate"] = 500 } },
    [2] = { source = 7, surplus_commit = { ["iron-plate"] = 300, ["copper-plate"] = 100 } },
    [3] = { source = 9, surplus_commit = { ["iron-plate"] = 999 } },        -- different source
    [4] = { dest = 7, return_manifest = { ["iron-plate"] = 50 } },          -- return loads AT 7
  } }

  -- excluding assignment 1: other commitments from source 7 = a2 (300 iron + 100
  -- copper) + a4's return leg (50 iron). a3 sources from a different node -> ignored.
  assert_eq(watchdog.other_committed(7, 1),
    { ["iron-plate"] = 350, ["copper-plate"] = 100 },
    "sums OTHER assignments' commitments from the source (forward + return), minus self")

  -- excluding assignment 2: a1 (500 iron) + a4's return (50 iron).
  assert_eq(watchdog.other_committed(7, 2), { ["iron-plate"] = 550 },
    "excludes the named assignment, keeps the rest")

  assert_eq(watchdog.other_committed(9, 3), {}, "only self commits from that source -> nothing else")
  storage = saved_storage
end)

describe("watchdog.schedule_signature -- order-stable, edit-sensitive", function()
  -- the §1 record shape schedule.lua emits
  local function records(iron, copper)
    return {
      {
        station = "nauvis",
        requests = { ["iron-plate"] = iron, ["copper-plate"] = copper },
        wait_conditions = {
          { type = "full" },
          { type = "time", ticks = 3600, compare_type = "or" },
        },
      },
      {
        station = "vulcanus",
        requests = {},
        wait_conditions = {
          { type = "empty" },
          { type = "time", ticks = 3600, compare_type = "or" },
        },
      },
    }
  end

  -- NOTE: production signs `schedule.engine_records(...)`, which STRIPS the
  -- `requests` map (a 2.0 ScheduleRecord has no cargo field -- cargo is the hub's
  -- logistic request), and `read_signature` reads those engine records back. So the
  -- signature only detects STATION + WAIT-CONDITION edits, NOT load-qty edits; we
  -- therefore do not assert request-qty sensitivity here (it would test a dead path).

  -- identical schedules -> identical signatures
  assert_eq(watchdog.schedule_signature(records(500, 200)), watchdog.schedule_signature(records(500, 200)),
    "identical schedules -> identical signature")

  -- a changed station (re-routed) -> different signature
  local rerouted = records(500, 200)
  rerouted[2].station = "gleba"
  check(watchdog.schedule_signature(records(500, 200)) ~= watchdog.schedule_signature(rerouted),
    "changed station -> signature differs (re-route detected)")

  -- a changed wait-condition -> different signature
  local retimed = records(500, 200)
  retimed[1].wait_conditions[2].ticks = 1800
  check(watchdog.schedule_signature(records(500, 200)) ~= watchdog.schedule_signature(retimed),
    "changed wait-condition -> signature differs")

  -- empty / nil records are stable and equal
  assert_eq(watchdog.schedule_signature(nil), watchdog.schedule_signature({}), "nil records == empty records")
end)

describe("watchdog.schedule_signature -- compare_type default round-trips engine readback", function()
  -- The engine stores AND reads back a condition written without a compare_type
  -- as compare_type="and". The mod writes the leading full/empty condition WITHOUT
  -- a compare_type, so the commit-time signature must canonicalize an omitted
  -- compare_type to "and" -- otherwise the live readback (which carries "and")
  -- never matches and every fresh assignment is falsely withdrawn as a player edit
  -- on the first watchdog tick.
  local omitted = { {
    station = "nauvis", requests = {},
    wait_conditions = {
      { type = "full" },                                           -- no compare_type (as written)
      { type = "time", ticks = 3600, compare_type = "or" },
    },
  } }
  local readback = { {
    station = "nauvis", requests = {},
    wait_conditions = {
      { type = "full", compare_type = "and" },                     -- engine-filled default
      { type = "time", ticks = 3600, compare_type = "or" },
    },
  } }
  assert_eq(watchdog.schedule_signature(omitted), watchdog.schedule_signature(readback),
    "omitted compare_type signs identically to the engine default 'and' (no false player-edit)")
  -- a genuinely different compare_type still diverges (edit sensitivity preserved)
  local edited = { {
    station = "nauvis", requests = {},
    wait_conditions = { { type = "full", compare_type = "or" } },
  } }
  local plain = { { station = "nauvis", requests = {}, wait_conditions = { { type = "full" } } } }
  check(watchdog.schedule_signature(edited) ~= watchdog.schedule_signature(plain),
    "an explicit non-default compare_type still changes the signature")
end)

describe("watchdog.manifest_delivered -- completion over OUR cargo only (not whole hold)", function()
  -- count_fn from a plain hold table; items not present read as 0 (delivered).
  local function counter(hold)
    return function(item) return hold[item] or 0 end
  end
  local manifest = { ["iron-plate"] = 300, ["copper-plate"] = 150 }

  -- everything pulled by the pad -> hub holds none of our cargo -> delivered
  assert_true(watchdog.manifest_delivered(counter({}), manifest, nil),
    "hub holds 0 of every manifest item -> delivered")
  -- the platform's own fuel/ammo sits in the hold but is NOT in the manifest, so
  -- it must NOT block completion (the whole-hub is_empty check used to)
  assert_true(watchdog.manifest_delivered(counter({ ["nuclear-fuel"] = 5, ["uranium-rounds-magazine"] = 80 }), manifest, nil),
    "non-manifest fuel/ammo in the hold -> still delivered (ignored)")
  -- one manifest item not yet pulled -> not delivered
  assert_eq(watchdog.manifest_delivered(counter({ ["copper-plate"] = 40 }), manifest, nil), false,
    "one manifest item remaining -> not delivered")
  -- empty / nil manifest -> nothing to deliver -> trivially delivered
  assert_true(watchdog.manifest_delivered(counter({ ["iron-plate"] = 999 }), {}, nil),
    "empty manifest -> trivially delivered (ignores unrelated cargo)")
  assert_true(watchdog.manifest_delivered(counter({}), nil, nil),
    "nil manifests -> delivered")
  -- two-way: forward pulled but the RETURN manifest is still aboard -> not delivered
  assert_eq(watchdog.manifest_delivered(counter({ ["copper-plate"] = 150 }), {}, { ["copper-plate"] = 150 }), false,
    "return manifest still aboard -> not delivered")
  -- two-way: both forward + return drained -> delivered
  assert_true(watchdog.manifest_delivered(counter({}), { ["iron-plate"] = 300 }, { ["copper-plate"] = 150 }),
    "forward + return both drained -> delivered")
end)

describe("watchdog.stop_request -- per-stop hub request (forward/return lifecycle)", function()
  local a = {
    manifest = { ["iron-plate"] = 300 },
    return_manifest = { ["copper-plate"] = 150 },
    source_planet = "nauvis", dest_planet = "vulcanus",
  }
  local m1, i1 = watchdog.stop_request(a, 1)
  assert_eq(m1, { ["iron-plate"] = 300 }, "stop 1 requests the forward manifest")
  assert_eq(i1, "nauvis", "stop 1 imports from the source planet")
  -- stop 2 is the TURNAROUND at the destination: the request becomes the return
  -- manifest (loaded there while the pad pulls the forward cargo).
  local m2, i2 = watchdog.stop_request(a, 2)
  assert_eq(m2, { ["copper-plate"] = 150 }, "stop 2 (turnaround) requests the return manifest")
  assert_eq(i2, "vulcanus", "stop 2 imports the return from the destination planet")
  assert_eq(watchdog.stop_request(a, 3), {}, "stop 3 (drop return) clears the request")

  -- forward-only assignment (no return manifest): the destination stop is a plain
  -- unload, so the request is cleared there.
  local fwd = { manifest = { ["iron-plate"] = 300 }, source_planet = "nauvis", dest_planet = "vulcanus" }
  assert_eq(watchdog.stop_request(fwd, 2), {}, "no return manifest -> stop 2 clears (plain unload)")
  -- an empty return manifest is treated the same as none
  local empty_ret = { manifest = {}, return_manifest = {}, source_planet = "nauvis", dest_planet = "vulcanus" }
  assert_eq(watchdog.stop_request(empty_ret, 2), {}, "empty return manifest -> stop 2 clears")
end)

describe("watchdog.station_is_ours -- interrupt guard (only act on OUR route stops)", function()
  local a = { source_planet = "nauvis", dest_planet = "vulcanus" }
  assert_true(watchdog.station_is_ours(a, "nauvis"), "the source planet is one of ours")
  assert_true(watchdog.station_is_ours(a, "vulcanus"), "the destination planet is one of ours")
  -- a refuel/rearm INTERRUPT can splice in a stop the mod never wrote; the watchdog
  -- must NOT re-point the hub request off it (it keys cargo by stop INDEX).
  assert_eq(watchdog.station_is_ours(a, "gleba"), false,
    "a foreign station (e.g. a refuel-interrupt stop) is NOT ours")
  assert_eq(watchdog.station_is_ours(a, "shattered-planet"), false,
    "any other space location is NOT ours")
  -- defensive edges: an unreadable record / nil assignment -> never act blindly
  assert_eq(watchdog.station_is_ours(a, nil), false,
    "an unreadable (nil) station is NOT ours (defensive)")
  assert_eq(watchdog.station_is_ours(nil, "nauvis"), false,
    "no assignment -> NOT ours (defensive)")
end)

describe("watchdog.current_is_ours -- index-keyed interrupt guard (note_progress + maybe_reclamp)", function()
  local a = { source_planet = "nauvis", dest_planet = "vulcanus" }
  local records = {
    { station = "nauvis" },   -- stop 1: our forward load (source)
    { station = "vulcanus" }, -- stop 2: our turnaround (dest)
    { station = "nauvis" },   -- stop 3: our return drop (source)
  }
  assert_true(watchdog.current_is_ours(a, records, 1), "current at our source stop -> ours")
  assert_true(watchdog.current_is_ours(a, records, 2), "current at our dest stop -> ours")
  assert_true(watchdog.current_is_ours(a, records, 3), "current at our return-drop stop -> ours")
  -- a refuel/rearm INTERRUPT splices a foreign record and shifts `current` onto it:
  -- both note_progress and maybe_reclamp key off this numeric index, so neither may
  -- re-point/re-clamp the hub request against the wrong leg's cargo.
  local spliced = {
    { station = "nauvis" },
    { station = "gleba" },    -- foreign refuel-interrupt stop (current shifted here)
    { station = "vulcanus" },
  }
  assert_eq(watchdog.current_is_ours(a, spliced, 2), false,
    "current shifted onto a foreign interrupt stop -> NOT ours (no re-point/re-clamp)")
  -- defensive edges: an unreadable index / missing records -> never act blindly
  assert_eq(watchdog.current_is_ours(a, records, nil), false, "nil current -> NOT ours")
  assert_eq(watchdog.current_is_ours(a, nil, 1), false, "nil records -> NOT ours")
  assert_eq(watchdog.current_is_ours(a, records, 9), false, "out-of-range index -> NOT ours")
end)

describe("watchdog.load_impossible -- abort a trip whose source ran dry", function()
  local function plat(current)
    return { valid = true, schedule = { current = current } }
  end
  -- at the forward load stop with an emptied manifest -> the source can supply
  -- nothing, so the trip is impossible (abort instead of waiting out the timeout)
  assert_true(watchdog.load_impossible({ manifest = {} }, plat(1)),
    "current=1 + empty manifest -> impossible")
  -- still has something loadable -> not impossible (ships the partial)
  assert_eq(watchdog.load_impossible({ manifest = { ["iron-plate"] = 5 } }, plat(1)), false,
    "non-empty manifest -> loadable")
  -- past the load stop (return leg / drop) -> never aborted here
  assert_eq(watchdog.load_impossible({ manifest = {} }, plat(2)), false,
    "current!=1 -> not the forward load stop")
  -- no platform -> false (never abort blindly)
  assert_eq(watchdog.load_impossible({ manifest = {} }, nil), false, "no platform -> false")
end)

describe("watchdog.delivery_impossible -- abort a parked, no-longer-wanted delivery", function()
  -- count_fn = what the hub STILL holds; request_fn = the drop planet's RAW unmet
  -- (requested - on_hand, EXCLUDING fleet inbound -- deliberately NOT open_demand,
  -- which would net out this assignment's own inbound and read ~0 mid-unload).
  local function held(hold) return function(item) return hold[item] or 0 end end
  local function wants(req) return function(item) return req[item] or 0 end end
  local a = { manifest = { ["iron-plate"] = 300, ["copper-plate"] = 150 } }

  -- cargo still aboard AND the destination no longer requests ANY of it -> abort
  assert_true(
    watchdog.delivery_impossible(a,
      wants({}),                                       -- dest wants nothing now
      held({ ["iron-plate"] = 300, ["copper-plate"] = 150 })),
    "cargo aboard + dest requests none -> impossible (abort)")

  -- the destination STILL requests one of the held items (raw unmet > 0) -> healthy
  assert_eq(
    watchdog.delivery_impossible(a,
      wants({ ["iron-plate"] = 120 }),                 -- still short on iron
      held({ ["iron-plate"] = 300, ["copper-plate"] = 150 })),
    false, "a held item still wanted (raw unmet > 0) -> NOT impossible")

  -- the pad already pulled everything -> hub holds none of our cargo -> not our job
  -- here (completed wins, checked first in the run loop); never impossible.
  assert_eq(
    watchdog.delivery_impossible(a, wants({}), held({})),
    false, "cargo already pulled (nothing held) -> NOT impossible (completed wins)")

  -- "not at the unload stop": en route / mid-pull the destination still has its
  -- full raw demand (on_hand low -> requested - on_hand > 0), so even with cargo
  -- aboard the predicate reads healthy. (The run loop ALSO gates on parked-at-last-
  -- stop, so this is never even called before arrival.)
  assert_eq(
    watchdog.delivery_impossible(a,
      wants({ ["iron-plate"] = 300, ["copper-plate"] = 150 }),
      held({ ["iron-plate"] = 300, ["copper-plate"] = 150 })),
    false, "dest still fully requests (pre-delivery / mid-pull) -> NOT impossible")

  -- mixed: the dest dropped its iron request but still wants copper -> a single
  -- still-wanted held item keeps the delivery healthy (it'll deliver the rest).
  assert_eq(
    watchdog.delivery_impossible(a,
      wants({ ["copper-plate"] = 80 }),
      held({ ["iron-plate"] = 300, ["copper-plate"] = 150 })),
    false, "one held item still wanted -> NOT impossible")

  -- return-only cargo (two-way drop at the source): forward already delivered
  -- (count 0), only the return manifest aboard. Source no longer wants it -> abort;
  -- source still wants it -> healthy.
  local twoway = { manifest = { ["iron-plate"] = 300 }, return_manifest = { ["copper-plate"] = 150 } }
  assert_true(
    watchdog.delivery_impossible(twoway, wants({}), held({ ["copper-plate"] = 150 })),
    "return cargo aboard + source requests none -> impossible")
  assert_eq(
    watchdog.delivery_impossible(twoway, wants({ ["copper-plate"] = 60 }), held({ ["copper-plate"] = 150 })),
    false, "return cargo still wanted at the source -> NOT impossible")

  -- empty / nil edges -> nothing held -> never impossible (defensive)
  assert_eq(watchdog.delivery_impossible({}, wants({}), held({})), false,
    "no manifest -> NOT impossible")
  assert_eq(watchdog.delivery_impossible(nil, wants({}), held({})), false,
    "nil assignment -> NOT impossible")
end)

-- ---------------------------------------------------------------------------
-- Task 7: two-way return leg -- pure return-manifest selection (guarded,
-- capacity-clamped), the 3-stop schedule it produces, the plan gate, and the
-- two-sided return bookkeeping. The mid-flight IO is verified by manual playtest.
-- ---------------------------------------------------------------------------

describe("dispatcher.return_manifest -- reciprocal need + surplus (guarded)", function()
  -- source(1) needs copper back; dest(2) has copper surplus and no demand for it.
  local snapshot = {
    nodes = {
      [1] = { id = 1, planet = "src", demand = { { item = "copper-plate", unmet = 150, priority = 0 } },
        surplus = {}, unmet_by_item = { ["copper-plate"] = 150 } },
      [2] = { id = 2, planet = "dest", demand = {},
        surplus = { ["copper-plate"] = 500 }, unmet_by_item = {} },
    },
  }
  assert_eq(dispatcher.return_manifest(snapshot, 1, 2, 1000), { ["copper-plate"] = 150 },
    "return leg added: dest surplus covers the source's reciprocal need (clamped to unmet)")
end)

describe("dispatcher.return_manifest -- absent when no reciprocal trade", function()
  -- dest has surplus, but of an item the source does NOT need.
  local no_need = {
    nodes = {
      [1] = { id = 1, planet = "src", demand = { { item = "iron-plate", unmet = 100, priority = 0 } },
        surplus = {}, unmet_by_item = { ["iron-plate"] = 100 } },
      [2] = { id = 2, planet = "dest", demand = {},
        surplus = { ["copper-plate"] = 500 }, unmet_by_item = {} },
    },
  }
  assert_eq(dispatcher.return_manifest(no_need, 1, 2, 1000), {},
    "no return leg: dest surplus is not something the source needs")

  -- source has no open demand at all (e.g. fully satisfied / already inbound):
  -- demand.open_demand already nets in-flight inbound, so an item already on its
  -- way home simply isn't in the source's demand -> no duplicate return leg.
  local satisfied = {
    nodes = {
      [1] = { id = 1, planet = "src", demand = {}, surplus = {}, unmet_by_item = {} },
      [2] = { id = 2, planet = "dest", demand = {},
        surplus = { ["copper-plate"] = 500 }, unmet_by_item = {} },
    },
  }
  assert_eq(dispatcher.return_manifest(satisfied, 1, 2, 1000), {},
    "no return leg: source has no open demand (satisfied / already inbound)")
end)

describe("dispatcher.return_manifest -- thrash guard applies to the destination", function()
  -- dest has copper surplus the source needs, but dest ALSO has open demand for
  -- copper -> the guard forbids using it as a return source (no import+export).
  local snapshot = {
    nodes = {
      [1] = { id = 1, planet = "src", demand = { { item = "copper-plate", unmet = 150, priority = 0 } },
        surplus = {}, unmet_by_item = { ["copper-plate"] = 150 } },
      [2] = { id = 2, planet = "dest", demand = {},
        surplus = { ["copper-plate"] = 500 }, unmet_by_item = { ["copper-plate"] = 30 } },
    },
  }
  assert_eq(dispatcher.return_manifest(snapshot, 1, 2, 1000), {},
    "thrash guard: a destination importing copper is never a return source for copper")
end)

describe("dispatcher.return_manifest -- wide load clamped to ship capacity", function()
  -- source needs two items back; the empty ship loads wide in priority order.
  local snapshot = {
    nodes = {
      [1] = { id = 1, planet = "src", demand = {
        { item = "iron-plate", unmet = 800, priority = 5 },
        { item = "copper-plate", unmet = 800, priority = 1 },
      }, surplus = {}, unmet_by_item = { ["iron-plate"] = 800, ["copper-plate"] = 800 } },
      [2] = { id = 2, planet = "dest", demand = {},
        surplus = { ["iron-plate"] = 1000, ["copper-plate"] = 1000 }, unmet_by_item = {} },
    },
  }
  assert_eq(dispatcher.return_manifest(snapshot, 1, 2, 600),
    { ["iron-plate"] = 300, ["copper-plate"] = 300 },
    "return leg fair-shares capacity so both needed items come back in one trip")
end)

describe("schedule.build_records -- two-way is a 3-stop turnaround (same two planets)", function()
  local built = schedule.build_records({
    source = "nauvis",
    dest = "vulcanus",
    capacity = 1000,
    timeout = 3600,
    items = { { item = "iron-plate", surplus = 500, unmet = 800 } },
    return_manifest = { ["copper-plate"] = 150 },
  })

  assert_eq(#built.records, 3,
    "three stops: source(load fwd) -> dest(turnaround) -> source(drop return)")

  local function loaded(item, qty)
    return { type = "item_count", compare_type = "and",
      condition = { comparator = ">=",
        first_signal = { type = "item", name = item, quality = "normal" }, constant = qty } }
  end
  local function delivered(item)
    return { type = "item_count", compare_type = "and",
      condition = { comparator = "=",
        first_signal = { type = "item", name = item, quality = "normal" }, constant = 0 } }
  end
  local inactivity = { type = "inactivity", ticks = 300, compare_type = "or" }
  local timeout_or = { type = "time", ticks = 3600, compare_type = "or" }

  -- stop 1: load forward at the source
  local src = built.records[1]
  assert_eq(src.station, "nauvis", "stop 1 is the source planet")
  assert_eq(src.requests, { ["iron-plate"] = 500 }, "stop 1 requests the forward manifest")
  assert_eq(src.import_from, "nauvis", "forward request scoped to the source")
  assert_eq(src.wait_conditions[1], loaded("iron-plate", 500), "source loads iron")
  assert_eq(src.allows_unloading, false, "load stop does not allow unloading")

  -- stop 2: the TURNAROUND at the destination -- requests the RETURN manifest
  -- (loaded there) AND allows unloading so the pad pulls the forward cargo. Waits
  -- on forward delivered (iron==0) AND return loaded (copper>=150), OR inactivity/time.
  local turn = built.records[2]
  assert_eq(turn.station, "vulcanus", "stop 2 is the destination turnaround")
  assert_eq(turn.requests, { ["copper-plate"] = 150 }, "turnaround requests the RETURN manifest")
  assert_eq(turn.import_from, "vulcanus", "return request scoped to the destination")
  assert_eq(turn.allows_unloading, true, "turnaround allows the pad to pull the forward cargo")
  assert_eq(turn.wait_conditions[1], delivered("iron-plate"), "forward iron delivered (==0)")
  assert_eq(turn.wait_conditions[2], loaded("copper-plate", 150), "return copper loaded (>=qty)")
  assert_eq(turn.wait_conditions[3], inactivity, "... or inactivity")
  assert_eq(turn.wait_conditions[4], timeout_or, "... or timeout")

  -- stop 3: drop the return cargo back at the source
  local back = built.records[3]
  assert_eq(back.station, "nauvis", "stop 3 drops the return at the source")
  assert_eq(back.requests, {}, "return drop carries no request")
  assert_eq(back.allows_unloading, true, "drop stop allows unloading")
  assert_eq(back.wait_conditions[1], delivered("copper-plate"), "return copper delivered (==0)")

  assert_eq(built.return_manifest, { ["copper-plate"] = 150 }, "built exposes the return manifest")
end)

describe("schedule.build_records -- empty return manifest stays a 2-stop route", function()
  -- an empty (or nil) return manifest must NOT add a third stop -- regression.
  local built = schedule.build_records({
    source = "nauvis", dest = "vulcanus", capacity = 1000, timeout = 3600,
    items = { { item = "iron-plate", surplus = 500, unmet = 800 } },
    return_manifest = {},
  })
  assert_eq(#built.records, 2, "empty return manifest -> still two stops")
  assert_eq(built.records[2].wait_conditions[1],
    { type = "item_count", compare_type = "and",
      condition = { comparator = "=",
        first_signal = { type = "item", name = "iron-plate", quality = "normal" }, constant = 0 } },
    "dest reverts to a 2-stop unload (iron delivered)")
  assert_eq(built.return_manifest, nil, "no return manifest exposed")
end)

describe("dispatcher.plan -- two-way gate (setting off vs on)", function()
  local function snap()
    return {
      nodes = {
        [1] = { id = 1, planet = "src", demand = { { item = "copper-plate", unmet = 150, priority = 0 } },
          surplus = { ["iron-plate"] = 500 }, unmet_by_item = { ["copper-plate"] = 150 } },
        [2] = { id = 2, planet = "dest", demand = { { item = "iron-plate", unmet = 300, priority = 0 } },
          surplus = { ["copper-plate"] = 500 }, unmet_by_item = { ["iron-plate"] = 300 } },
      },
      ships = { { id = 10, capacity = 1000, entry = { enrolled = true, state = fleet.IDLE } } },
    }
  end

  -- gate OFF (two_way absent/false): forward leg only, no return manifest.
  local off = dispatcher.plan(snap())
  assert_eq(#off, 1, "one forward assignment")
  assert_eq(off[1].return_manifest, nil, "setting off -> no return leg")

  -- gate ON: the only destination served is node 1 (needs copper, sourced from
  -- node 2); on the way home the empty ship carries iron back to node 2 (which
  -- needs it). Forward = copper to node 1; return = iron to node 2.
  local on_snap = snap()
  on_snap.two_way = true
  local on = dispatcher.plan(on_snap)
  assert_eq(#on, 1, "still one assignment (same ship, same two planets)")
  assert_eq(on[1].source_id, 2, "forward source is node 2 (has the copper)")
  assert_eq(on[1].dest_id, 1, "forward destination is node 1 (needs the copper)")
  assert_eq(on[1].manifest, { ["copper-plate"] = 150 }, "forward leg delivers copper")
  assert_eq(on[1].return_manifest, { ["iron-plate"] = 300 },
    "return leg carries iron back to the source planet, which needs it")
end)

describe("dispatcher.plan -- return leg drains the return-source's working surplus", function()
  -- node 1 (forward dest) receives copper from node 2; on the way back the ship
  -- loads iron at node 1 for node 2. That return claim must DECREMENT node 1's
  -- working iron surplus so it can't be double-claimed later this tick.
  local snapshot = {
    two_way = true,
    nodes = {
      [1] = { id = 1, planet = "src", demand = { { item = "copper-plate", unmet = 150, priority = 0 } },
        surplus = { ["iron-plate"] = 500 }, unmet_by_item = { ["copper-plate"] = 150 } },
      [2] = { id = 2, planet = "dest", demand = { { item = "iron-plate", unmet = 300, priority = 0 } },
        surplus = { ["copper-plate"] = 500 }, unmet_by_item = { ["iron-plate"] = 300 } },
    },
    ships = { { id = 10, capacity = 1000, entry = { enrolled = true, state = fleet.IDLE } } },
  }
  local plans = dispatcher.plan(snapshot)
  assert_eq(plans[1].return_manifest, { ["iron-plate"] = 300 }, "return leg loads 300 iron at node 1")
  -- forward leg drained node 2's copper; return leg drained node 1's iron.
  assert_eq(snapshot.nodes[2].surplus["copper-plate"], 350, "forward claim decremented copper (500-150)")
  assert_eq(snapshot.nodes[1].surplus["iron-plate"], 200, "return claim decremented iron (500-300)")
end)

describe("two-way return bookkeeping balances (inbound + committed surplus)", function()
  -- a single in-flight assignment carrying a forward leg (iron, src->dest) and a
  -- return leg (copper, dest->src). The two-sided bookkeeping must credit/debit
  -- the correct planets so neither leg is double-dispatched.
  local saved_storage = storage
  storage = { assignments = {
    [1] = {
      source = 7, dest = 9,
      inbound_commit = { ["iron-plate"] = 300 },
      surplus_commit = { ["iron-plate"] = 300 },
      return_manifest = { ["copper-plate"] = 150 },
    },
  } }

  -- demand side: dest(9) sees the forward iron inbound; source(7) sees the
  -- return copper inbound (so the source won't request copper again next tick).
  assert_eq(demand.inbound_for({ id = 9 }), { ["iron-plate"] = 300 },
    "forward leg credits inbound iron to the destination")
  assert_eq(demand.inbound_for({ id = 7 }), { ["copper-plate"] = 150 },
    "return leg credits inbound copper to the source (its reciprocal need)")

  -- supply side: source(7) committed iron; dest(9) committed copper for the
  -- return leg (so its copper isn't drained twice while rockets launch).
  local committed = dispatcher.committed_surplus_by_node()
  assert_eq(committed[7], { ["iron-plate"] = 300 }, "forward leg debits surplus from the source")
  assert_eq(committed[9], { ["copper-plate"] = 150 }, "return leg debits surplus from the destination")

  storage = saved_storage
end)

-- ---------------------------------------------------------------------------
-- Task 8: monitor view model (pure builders + reason classifier + filters)
-- ---------------------------------------------------------------------------

local viewmodel = require("scripts.viewmodel")

describe("classify_waiting: a real (exportable) source exists -> no ship", function()
  -- one candidate with surplus above min-trip and NOT importing the item: a
  -- valid source. The only thing that can be missing is a ship.
  local reason = viewmodel.classify_waiting(
    { { surplus = 500, importing = false } }, 100)
  assert_eq(reason, viewmodel.REASON_NO_SHIP, "exportable source => no_ship")
end)

describe("classify_waiting: surplus exists but guard-suppressed -> source busy importing", function()
  -- the candidate HAS the surplus but also has open demand for the same item, so
  -- the re-export thrash guard suppresses it. This must read as 'busy importing',
  -- NOT 'no source' (the key distinction called out in the plan).
  local reason = viewmodel.classify_waiting(
    { { surplus = 500, importing = true } }, 100)
  assert_eq(reason, viewmodel.REASON_SOURCE_BUSY, "importing surplus => source_busy_importing")
end)

describe("classify_waiting: only sub-min-trip surplus -> below min-trip", function()
  local reason = viewmodel.classify_waiting(
    { { surplus = 40, importing = false } }, 100)
  assert_eq(reason, viewmodel.REASON_BELOW_MIN_TRIP, "tiny surplus => below_min_trip")
end)

describe("classify_waiting: nobody holds the item -> no source", function()
  assert_eq(viewmodel.classify_waiting({}, 100),
    viewmodel.REASON_NO_SOURCE, "no candidates => no_source")
  assert_eq(viewmodel.classify_waiting({ { surplus = 0, importing = false } }, 100),
    viewmodel.REASON_NO_SOURCE, "zero surplus => no_source")
end)

describe("classify_waiting: precedence -- a real source wins over busy/below", function()
  -- mixed candidates: one exportable, one importing, one sub-min-trip. The real
  -- source dominates: it's a ship problem, not a sourcing problem.
  local reason = viewmodel.classify_waiting({
    { surplus = 30, importing = false },   -- below min-trip
    { surplus = 500, importing = true },   -- busy importing
    { surplus = 500, importing = false },  -- REAL source
  }, 100)
  assert_eq(reason, viewmodel.REASON_NO_SHIP, "any real source => no_ship")
end)

describe("classify_waiting: in_transit takes top priority", function()
  -- a real source AND a shipment already in flight -> in_transit, not no_ship
  -- (a ship IS carrying it; the residual persists only because of the route cap)
  assert_eq(viewmodel.classify_waiting({ { surplus = 500, importing = false } }, 100, true),
    viewmodel.REASON_IN_TRANSIT, "in_transit wins over a real source")
  -- in_transit even with no source at all (the in-flight ship will still deliver)
  assert_eq(viewmodel.classify_waiting({}, 100, true),
    viewmodel.REASON_IN_TRANSIT, "in_transit wins over no_source")
  -- without the flag, behaviour is unchanged
  assert_eq(viewmodel.classify_waiting({ { surplus = 500, importing = false } }, 100, false),
    viewmodel.REASON_NO_SHIP, "no in_transit -> still no_ship")
end)

describe("build: roster/state mapping + summary counts", function()
  local world = {
    fleet = {
      [10] = { enrolled = true, state = fleet.IDLE },
      [11] = { enrolled = true, state = fleet.ENROUTE, assignment = 1 },
      [12] = { enrolled = true, state = fleet.WITHDRAWN },
    },
    assignments = {
      [1] = { ship = 11, source_planet = "nauvis", dest_planet = "vulcanus",
              manifest = { ["iron-plate"] = 300 }, phase = "enroute", deadline_tick = 500 },
    },
    alerts = {},
    tick = 200,
  }
  local view = viewmodel.build(world)

  -- roster is sorted by ship id; the enroute ship resolves its From->To+manifest
  -- from the assignment, the idle one carries none.
  assert_eq(view.roster[1].ship_id, 10, "roster sorted: ship 10 first")
  assert_eq(view.roster[1].from, nil, "idle ship has no source")
  assert_eq(view.roster[2].ship_id, 11, "ship 11 second")
  assert_eq(view.roster[2].from, "nauvis", "enroute ship resolves source from assignment")
  assert_eq(view.roster[2].to, "vulcanus", "enroute ship resolves dest from assignment")
  assert_eq(view.roster[2].manifest, { ["iron-plate"] = 300 }, "enroute ship resolves manifest")

  -- summary roll-up counts states correctly.
  assert_eq(view.summary.ships_total, 3, "3 ships total")
  assert_eq(view.summary.ships_idle, 1, "1 idle")
  assert_eq(view.summary.ships_active, 1, "1 active (enroute)")
  assert_eq(view.summary.ships_withdrawn, 1, "1 withdrawn")
  assert_eq(view.summary.shipments, 1, "1 active shipment")

  -- shipment row carries ticks_left = deadline - tick.
  assert_eq(view.shipments[1].ticks_left, 300, "ticks_left = 500 - 200")
end)

describe("build: roster excludes un-enrolled platforms (registry indexes every hub)", function()
  -- registry.add_platform indexes EVERY platform hub the player builds, all
  -- un-enrolled. Only the opt-in subset is the merchant fleet, so an un-enrolled
  -- idle platform must NOT appear on the monitor or inflate the counts -- but one
  -- un-enrolled mid-flight (still carrying a mod assignment) must stay visible.
  local world = {
    fleet = {
      [1] = { enrolled = true, state = fleet.IDLE },                     -- shown
      [2] = { enrolled = false, state = fleet.IDLE },                    -- hidden
      [3] = { enrolled = false, state = fleet.ENROUTE, assignment = 7 }, -- shown (assigned)
    },
    assignments = {
      [7] = { ship = 3, source_planet = "nauvis", dest_planet = "vulcanus",
              manifest = { ["iron-plate"] = 100 } },
    },
    alerts = {},
    tick = 0,
  }
  local view = viewmodel.build(world)

  assert_eq(#view.roster, 2, "only enrolled (1) + un-enrolled-but-assigned (3) on the roster")
  assert_eq(view.roster[1].ship_id, 1, "enrolled idle ship shown")
  assert_eq(view.roster[2].ship_id, 3, "un-enrolled ship still flying its assignment shown")
  assert_eq(view.summary.ships_total, 2, "summary counts only the merchant fleet, not every hub")
  assert_eq(view.summary.ships_idle, 1, "the un-enrolled idle platform is not counted as idle fleet")
  assert_eq(view.summary.ships_active, 1, "the still-flying un-enrolled ship counts as active")
end)

describe("build: waiting classification + deterministic sort", function()
  local world = {
    fleet = {},
    assignments = {},
    alerts = {},
    tick = 0,
    waiting = {
      -- vulcanus needs copper; a real source exists -> no_ship.
      { item = "copper-plate", dest_planet = "vulcanus", unmet = 100,
        candidates = { { surplus = 500, importing = false } }, min_trip = 50 },
      -- nauvis needs iron; the only holder is importing it -> source busy.
      { item = "iron-plate", dest_planet = "nauvis", unmet = 200,
        candidates = { { surplus = 500, importing = true } }, min_trip = 50 },
    },
  }
  local view = viewmodel.build(world)

  -- sorted by dest_planet then item: nauvis before vulcanus.
  assert_eq(view.waiting[1].dest_planet, "nauvis", "waiting sorted by planet")
  assert_eq(view.waiting[1].reason, viewmodel.REASON_SOURCE_BUSY, "nauvis iron busy-importing")
  assert_eq(view.waiting[2].dest_planet, "vulcanus", "vulcanus second")
  assert_eq(view.waiting[2].reason, viewmodel.REASON_NO_SHIP, "vulcanus copper no_ship")
  assert_eq(view.summary.waiting, 2, "2 waiting items")
end)

describe("apply_filters: planet / item / state narrowing", function()
  local view = {
    roster = {
      { ship_id = 1, state = "idle", from = nil, to = nil, manifest = nil },
      { ship_id = 2, state = "enroute", from = "nauvis", to = "vulcanus",
        manifest = { ["iron-plate"] = 300 } },
    },
    shipments = {
      { id = 1, ship_id = 2, from = "nauvis", to = "vulcanus",
        manifest = { ["iron-plate"] = 300 } },
    },
    waiting = {
      { item = "copper-plate", dest_planet = "vulcanus", unmet = 100, reason = "no_ship" },
      { item = "iron-plate", dest_planet = "nauvis", unmet = 200, reason = "no_source" },
    },
    summary = { ships_total = 2 },
  }

  -- planet filter keeps only rows touching vulcanus.
  local byplanet = viewmodel.apply_filters(view, { planet = "vulcanus" })
  assert_eq(#byplanet.roster, 1, "planet filter: 1 roster row")
  assert_eq(byplanet.roster[1].ship_id, 2, "planet filter keeps the vulcanus ship")
  assert_eq(#byplanet.shipments, 1, "planet filter: shipment kept")
  assert_eq(#byplanet.waiting, 1, "planet filter: only vulcanus waiting")
  assert_eq(byplanet.waiting[1].item, "copper-plate", "vulcanus waits on copper")

  -- item filter keeps only rows carrying/needing iron-plate.
  local byitem = viewmodel.apply_filters(view, { item = "iron-plate" })
  assert_eq(#byitem.roster, 1, "item filter: only the iron carrier")
  assert_eq(#byitem.waiting, 1, "item filter: only the iron waiter")
  assert_eq(byitem.waiting[1].dest_planet, "nauvis", "iron waiter is nauvis")

  -- state filter keeps only idle ships.
  local bystate = viewmodel.apply_filters(view, { state = "idle" })
  assert_eq(#bystate.roster, 1, "state filter: 1 idle ship")
  assert_eq(bystate.roster[1].ship_id, 1, "state filter keeps the idle ship")

  -- blank filters impose no constraint; summary passes through unfiltered.
  local none = viewmodel.apply_filters(view, { planet = "  ", item = "" })
  assert_eq(#none.roster, 2, "blank filters keep everything")
  assert_eq(none.summary.ships_total, 2, "summary is the global roll-up (unfiltered)")
end)

-- ---------------------------------------------------------------------------
-- viewmodel.build_node_readout (Task 9 -- Trade tab "This planet now")
-- ---------------------------------------------------------------------------

describe("viewmodel.build_node_readout", function()
  local viewmodel = require("scripts.viewmodel")

  -- demand sorts priority desc, then unmet desc, then item asc (matches
  -- demand.build_open); surplus + inbound sort by item asc. Pure: input order
  -- must not leak into the output.
  local view = viewmodel.build_node_readout({
    demand = {
      { item = "iron-plate", unmet = 50, priority = 0 },
      { item = "copper-plate", unmet = 200, priority = 5 },
      { item = "steel-plate", unmet = 200, priority = 5 },
    },
    surplus = {
      { item = "stone", qty = 300 },
      { item = "coal", qty = 100 },
    },
    inbound = {
      { item = "uranium", qty = 7 },
      { item = "ammonia", qty = 3 },
    },
  })

  assert_eq(#view.demand, 3, "demand: all rows kept")
  assert_eq(view.demand[1].item, "copper-plate", "demand: higher priority first, item asc tie-break")
  assert_eq(view.demand[2].item, "steel-plate", "demand: equal priority+unmet -> item asc")
  assert_eq(view.demand[3].item, "iron-plate", "demand: lowest priority last")

  assert_eq(view.surplus[1].item, "coal", "surplus sorted by item asc")
  assert_eq(view.surplus[2].item, "stone", "surplus second by item asc")
  assert_eq(view.surplus[1].qty, 100, "surplus qty carried through")

  assert_eq(view.inbound[1].item, "ammonia", "inbound sorted by item asc")
  assert_eq(view.inbound[2].item, "uranium", "inbound second by item asc")
  assert_eq(view.inbound[2].qty, 7, "inbound qty carried through")

  -- empty / missing inputs degrade to empty lists (no crash on a bare pad).
  local empty = viewmodel.build_node_readout({})
  assert_eq(#empty.demand, 0, "empty world -> no demand")
  assert_eq(#empty.surplus, 0, "empty world -> no surplus")
  assert_eq(#empty.inbound, 0, "empty world -> no inbound")

  -- absent priority defaults to 0.
  local nopri = viewmodel.build_node_readout({ demand = { { item = "x", unmet = 1 } } })
  assert_eq(nopri.demand[1].priority, 0, "absent priority defaults to 0")
end)

describe("build: alerts newest-first, display-capped, full count in summary", function()
  -- more alerts than the display cap: the panel shows the newest MAX_ALERTS in
  -- newest-first order, while the summary still reports the full backlog count.
  local alerts = {}
  for i = 1, 25 do
    alerts[i] = { kind = "timeout", assignment = i, tick = i }
  end
  local view = viewmodel.build({ fleet = {}, assignments = {}, alerts = alerts, tick = 0 })
  assert_eq(#view.alerts, viewmodel.MAX_ALERTS, "display capped to MAX_ALERTS")
  assert_eq(view.alerts[1].assignment, 25, "newest (last appended) shown first")
  assert_eq(view.alerts[viewmodel.MAX_ALERTS].assignment, 25 - viewmodel.MAX_ALERTS + 1,
    "oldest displayed is exactly MAX_ALERTS back")
  assert_eq(view.summary.alerts, 25, "summary reports the full backlog, not the capped display")
end)

describe("build: ticks_left is nil when the deadline or world tick is absent", function()
  -- no deadline_tick on the assignment -> nil (not a bogus 0, no nil arithmetic).
  local view = viewmodel.build({
    fleet = { [5] = { state = fleet.ENROUTE, assignment = 1 } },
    assignments = { [1] = { ship = 5, source_planet = "a", dest_planet = "b",
                            manifest = { x = 1 } } },
    alerts = {},
    tick = 100,
  })
  assert_eq(view.shipments[1].ticks_left, nil, "no deadline -> ticks_left nil")

  -- a deadline but no world tick -> also nil (the guard must short-circuit before
  -- the subtraction so it never errors on nil arithmetic).
  local view2 = viewmodel.build({
    fleet = {},
    assignments = { [1] = { ship = 5, deadline_tick = 500 } },
    alerts = {},
  })
  assert_eq(view2.shipments[1].ticks_left, nil, "deadline but no world tick -> nil")
end)

describe("apply_filters: item filter keeps a shipment whose RETURN leg carries it", function()
  -- the forward leg carries iron; the item filter is copper, which only appears
  -- on the return leg. The shipment must still be kept (the return-leg branch of
  -- the item filter).
  local view = {
    roster = {},
    shipments = {
      { id = 1, ship_id = 2, from = "nauvis", to = "vulcanus",
        manifest = { ["iron-plate"] = 300 },
        return_manifest = { ["copper-plate"] = 150 } },
    },
    waiting = {},
    summary = {},
  }
  local bycopper = viewmodel.apply_filters(view, { item = "copper-plate" })
  assert_eq(#bycopper.shipments, 1, "shipment kept because the return leg carries copper")
  -- and an item on neither leg drops it.
  local bynone = viewmodel.apply_filters(view, { item = "stone" })
  assert_eq(#bynone.shipments, 0, "shipment dropped when the item is on neither leg")
end)

describe("committed_surplus_by_node + inbound_for accumulate across assignments", function()
  -- TWO in-flight assignments crediting/debiting the SAME node+item. The
  -- bookkeeping must SUM (additive), not overwrite -- overwriting would let a
  -- source be double-claimed, exactly what this bookkeeping prevents.
  local saved_storage = storage
  storage = { assignments = {
    [1] = { source = 7, dest = 9, inbound_commit = { ["iron-plate"] = 300 },
            surplus_commit = { ["iron-plate"] = 300 } },
    [2] = { source = 7, dest = 9, inbound_commit = { ["iron-plate"] = 200 },
            surplus_commit = { ["iron-plate"] = 200 } },
  } }

  local committed = dispatcher.committed_surplus_by_node()
  assert_eq(committed[7], { ["iron-plate"] = 500 }, "two surplus commits sum (300+200)")
  assert_eq(demand.inbound_for({ id = 9 }), { ["iron-plate"] = 500 },
    "two inbound credits sum (300+200)")

  storage = saved_storage
end)

describe("state.sorted_keys: deterministic order for mixed number/string keys", function()
  local state = require("scripts.state")
  -- The determinism backbone (CLAUDE.md): every decision loop iterates via this.
  -- Numbers sort before strings, each ascending; a naive number<string compare
  -- would raise in Lua, so the type guard must hold.
  local keys = state.sorted_keys({ [2] = true, ["b"] = true, [1] = true, ["a"] = true })
  assert_eq(keys, { 1, 2, "a", "b" }, "numbers before strings, each ascending")
end)

describe("state.sorted_pairs: key+value round-trip in sorted order", function()
  local state = require("scripts.state")
  -- sorted_pairs is the determinism backbone used by every decision loop; pin a
  -- full key AND value round-trip in the default (mixed-type) order, not just keys.
  local tbl = { [2] = "two", ["b"] = "bee", [1] = "one", ["a"] = "ay" }
  local seen_keys, seen_vals = {}, {}
  for k, v in state.sorted_pairs(tbl) do
    seen_keys[#seen_keys + 1] = k
    seen_vals[#seen_vals + 1] = v
  end
  assert_eq(seen_keys, { 1, 2, "a", "b" }, "keys yielded in default sorted order")
  assert_eq(seen_vals, { "one", "two", "ay", "bee" }, "each yielded value matches its key")

  -- empty table -> zero iterations (the loop body never runs)
  local count = 0
  for _ in state.sorted_pairs({}) do
    count = count + 1
  end
  assert_eq(count, 0, "empty table -> no iterations")
end)

describe("state.sorted_pairs: custom comparator path", function()
  local state = require("scripts.state")
  -- a comparator over the KEYS drives the order; here all-numeric keys descending.
  local tbl = { [1] = "a", [2] = "b", [3] = "c" }
  local desc = function(x, y) return x > y end
  local order = {}
  for k in state.sorted_pairs(tbl, desc) do
    order[#order + 1] = k
  end
  assert_eq(order, { 3, 2, 1 }, "custom comparator reverses the iteration order")
  -- sorted_keys honors the same comparator (the helper sorted_pairs delegates to)
  assert_eq(state.sorted_keys(tbl, desc), { 3, 2, 1 }, "sorted_keys honors the custom comparator")
end)

describe("watchdog.raise_alert caps the stored backlog (oldest evicted)", function()
  local watchdog = require("scripts.watchdog")
  local saved_storage = storage
  storage = { alerts = {} }
  for i = 1, watchdog.MAX_ALERTS + 5 do
    watchdog.raise_alert("timeout", i, i, nil)
  end
  assert_eq(#storage.alerts, watchdog.MAX_ALERTS, "backlog capped at MAX_ALERTS")
  assert_eq(storage.alerts[#storage.alerts].assignment, watchdog.MAX_ALERTS + 5,
    "newest alert retained")
  assert_eq(storage.alerts[1].assignment, 6, "oldest five evicted (1..5)")
  storage = saved_storage
end)

-- ---------------------------------------------------------------------------
-- Task 8: quality compound-key helper -- (item, quality) <-> "item@quality"
-- round-trip. Stable string keys keep the decision maps sortable for
-- state.sorted_pairs determinism. Pure module, no engine globals.
-- ---------------------------------------------------------------------------

local qkey = require("scripts.qkey")

describe("qkey.qkey -- encode (item, quality) -> string", function()
  assert_eq(qkey.qkey("iron-plate", "normal"), "iron-plate@normal", "explicit normal quality")
  assert_eq(qkey.qkey("iron-plate", "uncommon"), "iron-plate@uncommon", "non-normal quality")
  -- nil quality defaults to "normal" (matches the engine's default-quality item)
  assert_eq(qkey.qkey("iron-plate"), "iron-plate@normal", "nil quality -> normal default")
  assert_eq(qkey.qkey("iron-plate", nil), "iron-plate@normal", "explicit nil quality -> normal default")
end)

describe("qkey.qparse -- decode string -> (item, quality)", function()
  local item, quality = qkey.qparse("iron-plate@normal")
  assert_eq(item, "iron-plate", "parsed item name")
  assert_eq(quality, "normal", "parsed quality")

  local i2, q2 = qkey.qparse("iron-plate@legendary")
  assert_eq(i2, "iron-plate", "parsed item (non-normal)")
  assert_eq(q2, "legendary", "parsed non-normal quality")

  -- a bare item name (no separator -> legacy / quality-agnostic key) decodes as
  -- the default quality so old maps degrade safely.
  local i3, q3 = qkey.qparse("iron-plate")
  assert_eq(i3, "iron-plate", "bare key -> item name")
  assert_eq(q3, "normal", "bare key -> normal default")

  -- an empty quality segment also falls back to the default.
  local i4, q4 = qkey.qparse("iron-plate@")
  assert_eq(i4, "iron-plate", "empty-quality key -> item name")
  assert_eq(q4, "normal", "empty quality segment -> normal default")
end)

describe("qkey round-trip -- qparse(qkey(...)) == identity", function()
  -- normal/default-quality items, including unusual prototype names (digits,
  -- multiple hyphens, underscores -- all valid Factorio names, none contain @).
  local cases = {
    { "iron-plate", "normal" },
    { "uranium-235", "uncommon" },
    { "se-core-fragment-omni", "rare" },
    { "fish", "legendary" },
    { "raw_fish", "epic" },
    { "a", "normal" },
    { "item-with-many-dashes-here", "uncommon" },
  }
  for _, c in ipairs(cases) do
    local item, quality = qkey.qparse(qkey.qkey(c[1], c[2]))
    assert_eq(item, c[1], "round-trip item: " .. c[1])
    assert_eq(quality, c[2], "round-trip quality: " .. c[1] .. "@" .. c[2])
  end

  -- default-quality round-trip: encode with nil, decode back to "normal".
  local item, quality = qkey.qparse(qkey.qkey("copper-plate"))
  assert_eq(item, "copper-plate", "default-quality round-trip item")
  assert_eq(quality, "normal", "default-quality round-trip quality")
end)

describe("qkey keys sort stably (state.sorted_keys determinism)", function()
  -- The compound keys must be plain strings so the determinism backbone orders
  -- them stably across peers. Build a map keyed by qkey and confirm sorted order.
  local state = require("scripts.state")
  local map = {
    [qkey.qkey("iron-plate", "uncommon")] = true,
    [qkey.qkey("iron-plate", "normal")] = true,
    [qkey.qkey("copper-plate", "normal")] = true,
  }
  local keys = state.sorted_keys(map)
  assert_eq(keys, {
    "copper-plate@normal", "iron-plate@normal", "iron-plate@uncommon",
  }, "qkeys sort as stable strings (item then quality)")
end)

-- ---------------------------------------------------------------------------
-- Task 9: quality threaded through demand + stock reads (#4b). Demand and
-- surplus are now keyed by qkey(item, quality); the fleet-flag/priority overlay
-- AND the reserve floor stay keyed by bare item NAME (decoded via qparse), so a
-- config for an item applies to ALL of its qualities. compute_unmet/build_open
-- stay pure (qparse is plain string math).
-- ---------------------------------------------------------------------------

describe("demand.build_open -- quality-keyed rows, overlay decoded to item NAME", function()
  local q = qkey.qkey
  -- one item at two qualities = two DISTINCT demand rows; the name-keyed overlay
  -- (priority + opt-out) applies to BOTH qualities of that item.
  local node = {
    import_flags = { ["coal"] = false }, -- opts out BOTH coal qualities (by name)
    priorities = { ["iron-plate"] = 3 }, -- applies to BOTH iron qualities (by name)
  }
  local rows = {
    { item = q("iron-plate", "normal"),   requested = 100, on_hand = 0,  inbound = 0 }, -- unmet 100, pri 3
    { item = q("iron-plate", "uncommon"), requested = 80,  on_hand = 20, inbound = 0 }, -- unmet 60,  pri 3
    { item = q("coal", "normal"),         requested = 50,  on_hand = 0,  inbound = 0 }, -- opted out
    { item = q("coal", "rare"),           requested = 50,  on_hand = 0,  inbound = 0 }, -- opted out (by name)
  }
  local open = demand.build_open(node, rows)
  assert_eq(#open, 2, "both coal qualities opted out by item name; both iron qualities survive")
  -- output stays keyed by qkey; same priority -> largest shortfall first
  assert_eq(open[1], { item = "iron-plate@normal", unmet = 100, priority = 3 },
    "normal iron: full unmet, priority resolved from bare name")
  assert_eq(open[2], { item = "iron-plate@uncommon", unmet = 60, priority = 3 },
    "uncommon iron: smaller unmet, SAME name-keyed priority")
end)

describe("demand.build_open -- qkey tie-break stable across input order", function()
  local q = qkey.qkey
  -- equal priority AND equal unmet -> stable by qkey string asc (quality breaks
  -- the tie within one item name), independent of input row order.
  local rows_a = {
    { item = q("iron-plate", "uncommon"), requested = 10, on_hand = 0 },
    { item = q("iron-plate", "normal"),   requested = 10, on_hand = 0 },
  }
  local rows_b = {
    { item = q("iron-plate", "normal"),   requested = 10, on_hand = 0 },
    { item = q("iron-plate", "uncommon"), requested = 10, on_hand = 0 },
  }
  local oa = demand.build_open({}, rows_a)
  local ob = demand.build_open({}, rows_b)
  assert_eq(oa, ob, "qkey tie-break independent of input order")
  assert_eq(oa[1].item, "iron-plate@normal", "normal sorts before uncommon (string asc)")
  assert_eq(oa[2].item, "iron-plate@uncommon", "uncommon second")
end)

describe("stock.surplus -- per-quality stock pool, reserve floor shared by item NAME", function()
  local q = qkey.qkey
  -- stub reader keyed by qkey: normal and uncommon iron are INDEPENDENT pools.
  local saved_reader = stock.reader
  local saved_min_trip = stock.MIN_TRIP
  stock.reader = function(node, key)
    return node.values[key] or 0
  end
  stock.MIN_TRIP = 1
  local node = {
    cache_key = "nauvis",
    values = {
      ["iron-plate@normal"]   = 500,
      ["iron-plate@uncommon"] = 300,
    },
    -- reserve floor configured by bare item NAME -> shared by every quality
    reserves = { default = 0, items = { ["iron-plate"] = 100 } },
  }
  stock.begin_tick(fresh_tick())
  -- reserve-decode: both qualities subtract the SAME name-keyed floor (100) but
  -- draw from their own per-quality stock pool.
  assert_eq(stock.surplus(node, q("iron-plate", "normal")), 400,
    "normal: 500 stock - 100 name-keyed reserve")
  assert_eq(stock.surplus(node, q("iron-plate", "uncommon")), 200,
    "uncommon: 300 stock - the SAME 100 name-keyed reserve (decoded, not a qkey miss)")
  -- distinct cache entries: a stale-tick read of one quality never serves the other
  assert_eq(stock.stock_count(node, q("iron-plate", "normal")), 500, "normal pool cached independently")
  assert_eq(stock.stock_count(node, q("iron-plate", "uncommon")), 300, "uncommon pool cached independently")
  stock.reader = saved_reader
  stock.MIN_TRIP = saved_min_trip
end)

-- ---------------------------------------------------------------------------
-- Task 10: quality threaded through plan + manifest + bookkeeping (#4c). The
-- dispatcher's decision maps (surplus, unmet_by_item, the manifest, the commit
-- maps) are now keyed by qkey(item, quality). The keys are opaque strings, so
-- exportable/best_source/plan/return_manifest carry quality through unchanged;
-- these tests prove a single item at two qualities matches, sources, loads, and
-- nets out INDEPENDENTLY (no cross-contamination).
-- ---------------------------------------------------------------------------

describe("dispatcher.exportable -- thrash guard is per (item, quality)", function()
  local q = qkey.qkey
  -- the node imports ONLY normal-quality iron, but holds surplus of BOTH
  -- qualities. The guard suppresses the quality it imports and exports the other.
  local node = {
    surplus = { [q("iron-plate", "normal")] = 400, [q("iron-plate", "uncommon")] = 200 },
    unmet_by_item = { [q("iron-plate", "normal")] = 50 },
  }
  assert_eq(dispatcher.exportable(node, q("iron-plate", "normal")), 0,
    "open demand for normal iron -> normal NOT exportable (guard)")
  assert_eq(dispatcher.exportable(node, q("iron-plate", "uncommon")), 200,
    "uncommon iron has no open demand -> exportable (quality-independent guard)")
end)

describe("dispatcher.best_source -- coverage sums per (item, quality)", function()
  local q = qkey.qkey
  -- dest needs normal iron (100) + uncommon iron (100). One source covers BOTH
  -- qualities (200), the other only the normal pool (100) -> most-coverage picks
  -- the wider source. Distinct qualities are distinct cargo, summed separately.
  local snapshot = {
    nodes = {
      [1] = { id = 1, planet = "dest", demand = {
        { item = q("iron-plate", "normal"), unmet = 100, priority = 0 },
        { item = q("iron-plate", "uncommon"), unmet = 100, priority = 0 },
      } },
      [2] = { id = 2, planet = "both", unmet_by_item = {},
        surplus = { [q("iron-plate", "normal")] = 500, [q("iron-plate", "uncommon")] = 500 } },
      [3] = { id = 3, planet = "normal-only", unmet_by_item = {},
        surplus = { [q("iron-plate", "normal")] = 500 } },
    },
  }
  local best = dispatcher.best_source(snapshot, snapshot.nodes[1])
  assert_eq(best.id, 2, "the source covering both qualities is chosen")
  assert_eq(best.coverage, 200, "coverage sums min(exportable,unmet) across (item,quality) keys")
end)

describe("dispatcher.plan -- two qualities of one item dispatch as distinct cargo", function()
  local q = qkey.qkey
  -- a destination needs the SAME item at two qualities; the source holds both as
  -- independent pools. The manifest carries both qkeys, each clamped to its own
  -- unmet -- a normal-quality shortfall is never filled with uncommon stock.
  local snapshot = {
    nodes = {
      [1] = { id = 1, planet = "dest", demand = {
        { item = q("iron-plate", "normal"), unmet = 200, priority = 0 },
        { item = q("iron-plate", "uncommon"), unmet = 100, priority = 0 },
      }, surplus = {}, unmet_by_item = {} },
      [2] = { id = 2, planet = "src", unmet_by_item = {}, surplus = {
        [q("iron-plate", "normal")] = 500,
        [q("iron-plate", "uncommon")] = 300,
      } },
    },
    ships = { { id = 10, capacity = 1000, entry = { enrolled = true, state = fleet.IDLE } } },
  }
  local plans = dispatcher.plan(snapshot)
  assert_eq(#plans, 1, "one assignment planned")
  assert_eq(plans[1].manifest, {
    [q("iron-plate", "normal")] = 200,
    [q("iron-plate", "uncommon")] = 100,
  }, "both qualities loaded as distinct keys, each clamped to its own unmet")
  -- the source's working surplus is decremented per quality (no double-claim).
  assert_eq(snapshot.nodes[2].surplus[q("iron-plate", "normal")], 300, "normal pool drained 500-200")
  assert_eq(snapshot.nodes[2].surplus[q("iron-plate", "uncommon")], 200, "uncommon pool drained 300-100")
end)

describe("dispatcher.return_manifest -- quality-keyed reciprocal trade", function()
  local q = qkey.qkey
  -- the source needs UNCOMMON copper back; the dest holds both qualities but the
  -- return leg loads ONLY the quality the source actually requested.
  local snapshot = {
    nodes = {
      [1] = { id = 1, planet = "src", demand = {
        { item = q("copper-plate", "uncommon"), unmet = 150, priority = 0 },
      }, surplus = {}, unmet_by_item = { [q("copper-plate", "uncommon")] = 150 } },
      [2] = { id = 2, planet = "dest", demand = {}, unmet_by_item = {}, surplus = {
        [q("copper-plate", "uncommon")] = 500,
        [q("copper-plate", "normal")] = 500,
      } },
    },
  }
  assert_eq(dispatcher.return_manifest(snapshot, 1, 2, 1000),
    { [q("copper-plate", "uncommon")] = 150 },
    "return leg carries only the uncommon copper the source needs; normal is left")
end)

describe("plan bookkeeping -- commit maps are uniformly qkey-keyed (forward + return)", function()
  local q = qkey.qkey
  -- a single in-flight assignment with a quality-mixed forward leg and a
  -- quality-tagged return leg. inbound_for (demand side) and
  -- committed_surplus_by_node (supply side) must net per (item, quality).
  local saved_storage = storage
  storage = { assignments = {
    [1] = {
      source = 7, dest = 9,
      inbound_commit = { [q("iron-plate", "normal")] = 300, [q("iron-plate", "uncommon")] = 100 },
      surplus_commit = { [q("iron-plate", "normal")] = 300, [q("iron-plate", "uncommon")] = 100 },
      return_manifest = { [q("copper-plate", "rare")] = 50 },
    },
  } }

  -- demand side: dest sees the forward iron inbound per quality; source sees the
  -- return copper inbound (keyed by its own quality, so it isn't re-requested).
  assert_eq(demand.inbound_for({ id = 9 }),
    { [q("iron-plate", "normal")] = 300, [q("iron-plate", "uncommon")] = 100 },
    "forward inbound credited to the dest, keyed by (item, quality)")
  assert_eq(demand.inbound_for({ id = 7 }),
    { [q("copper-plate", "rare")] = 50 },
    "return inbound credited to the source, keyed by (item, quality)")

  -- supply side: source debited per forward quality; dest debited for the return.
  local committed = dispatcher.committed_surplus_by_node()
  assert_eq(committed[7],
    { [q("iron-plate", "normal")] = 300, [q("iron-plate", "uncommon")] = 100 },
    "forward surplus debited from the source per quality")
  assert_eq(committed[9], { [q("copper-plate", "rare")] = 50 },
    "return surplus debited from the dest per quality")

  storage = saved_storage
end)

-- ---------------------------------------------------------------------------
-- Task 11: quality threaded through the schedule WRITE seam (#4d). The manifest
-- stays keyed by the OPAQUE cargo qkey, but the engine-facing wait conditions
-- (item_count first_signal) DECODE the qkey to {name, quality} -- a different
-- quality variant of the same item gates on its own item_count. (The set_slot /
-- hub-request decode + the watchdog hub_counter decode are IO seams, playtested
-- per docs/api-notes.md; this covers the PURE wait-condition decode that
-- build_records emits. NOTE per the plan: do NOT assert quality in
-- schedule_signature tests -- the signature serializes only type/ticks/
-- compare_type, so it never captures first_signal.quality.)
-- ---------------------------------------------------------------------------

describe("schedule.build_records -- quality-tagged requests decode at the wait seam", function()
  local q = qkey.qkey
  local built = schedule.build_records({
    source = "nauvis",
    dest = "vulcanus",
    capacity = 1000,
    timeout = 3600,
    items = {
      { item = q("iron-plate", "uncommon"), surplus = 500, unmet = 800 },
    },
  })

  -- the manifest/request map stays keyed by the OPAQUE qkey (records carry it
  -- through for bookkeeping; only the engine write/wait decodes it).
  assert_eq(built.manifest, { [q("iron-plate", "uncommon")] = 500 },
    "manifest stays keyed by the compound qkey")
  assert_eq(built.records[1].requests, { [q("iron-plate", "uncommon")] = 500 },
    "source requests keyed by the qkey (decoded only at the hub-request seam)")

  -- the load + unload wait conditions DECODE the qkey -> {name, quality} so the
  -- item_count reads the exact quality variant.
  assert_eq(built.records[1].wait_conditions[1], {
    type = "item_count", compare_type = "and",
    condition = { comparator = ">=",
      first_signal = { type = "item", name = "iron-plate", quality = "uncommon" }, constant = 500 } },
    "load wait first_signal decodes the qkey to name + quality")
  assert_eq(built.records[2].wait_conditions[1], {
    type = "item_count", compare_type = "and",
    condition = { comparator = "=",
      first_signal = { type = "item", name = "iron-plate", quality = "uncommon" }, constant = 0 } },
    "unload wait first_signal decodes the qkey to name + quality")
end)

-- ---------------------------------------------------------------------------
-- Task 12: quality threaded through the monitor + Trade-tab view models,
-- overlays, and filters (#4e). The view-model cargo keys are qkey(item, quality);
-- the pure builders carry them OPAQUELY and DECODE at the display/filter
-- boundary, while the fleet-toggle/priority overlay stays keyed by bare item NAME
-- so a player edit round-trips across EVERY quality of an item.
-- ---------------------------------------------------------------------------

describe("viewmodel.build_node_readout -- decodes cargo qkeys to name + quality", function()
  local q = qkey.qkey
  local view = viewmodel.build_node_readout({
    demand = {
      { item = q("iron-plate", "uncommon"), unmet = 200, priority = 5 },
      { item = q("iron-plate", "normal"),   unmet = 200, priority = 5 },
      { item = q("copper-plate", "normal"), unmet = 50,  priority = 0 },
    },
    surplus = {
      { item = q("stone", "normal"), qty = 300 },
      { item = q("stone", "rare"),   qty = 100 },
    },
    inbound = {
      { item = q("coal", "normal"), qty = 7 },
    },
  })
  -- demand: equal priority+unmet -> name asc, then quality asc; the qkey is split
  -- into separate item NAME + quality fields so the dumb view shows real items.
  assert_eq(view.demand[1].item, "iron-plate", "demand[1] decoded to bare name")
  assert_eq(view.demand[1].quality, "normal", "normal sorts before uncommon")
  assert_eq(view.demand[2].item, "iron-plate", "demand[2] same name")
  assert_eq(view.demand[2].quality, "uncommon", "uncommon second")
  assert_eq(view.demand[3].item, "copper-plate", "lowest priority last")
  assert_eq(view.demand[3].quality, "normal", "copper normal quality")
  -- surplus: one item at two qualities sorts adjacent (name asc, quality asc).
  assert_eq(view.surplus[1].item, "stone", "surplus decoded name")
  assert_eq(view.surplus[1].quality, "normal", "stone normal first")
  assert_eq(view.surplus[2].quality, "rare", "stone rare second")
  assert_eq(view.surplus[1].qty, 300, "surplus qty carried through")
  -- inbound decoded too.
  assert_eq(view.inbound[1].item, "coal", "inbound decoded name")
  assert_eq(view.inbound[1].quality, "normal", "inbound quality decoded")
end)

describe("viewmodel.build -- waiting carries the cargo qkey through + classifies per quality", function()
  local q = qkey.qkey
  -- two qualities of one item waiting on the same planet stay DISTINCT rows; the
  -- qkey passes through opaquely (display/filter decode it downstream) and each
  -- quality is classified independently from its own candidate picture.
  local world = {
    fleet = {}, assignments = {}, alerts = {}, tick = 0,
    waiting = {
      { item = q("iron-plate", "uncommon"), dest_planet = "vulcanus", unmet = 60,
        candidates = { { surplus = 500, importing = false } }, min_trip = 50 },
      { item = q("iron-plate", "normal"), dest_planet = "vulcanus", unmet = 100,
        candidates = { { surplus = 500, importing = true } }, min_trip = 50 },
    },
  }
  local view = viewmodel.build(world)
  assert_eq(#view.waiting, 2, "both qualities are distinct waiting rows")
  -- sorted by planet then qkey string: normal before uncommon.
  assert_eq(view.waiting[1].item, q("iron-plate", "normal"), "normal qkey sorts first, carried opaquely")
  assert_eq(view.waiting[1].reason, viewmodel.REASON_SOURCE_BUSY, "normal iron: importing source -> busy")
  assert_eq(view.waiting[2].item, q("iron-plate", "uncommon"), "uncommon qkey second")
  assert_eq(view.waiting[2].reason, viewmodel.REASON_NO_SHIP, "uncommon iron: real source -> no_ship")
end)

describe("apply_filters -- a bare item-NAME filter matches EVERY quality (qkey decode)", function()
  local q = qkey.qkey
  local view = {
    roster = {
      { ship_id = 1, state = "enroute", from = "nauvis", to = "vulcanus",
        manifest = { [q("iron-plate", "uncommon")] = 300 } },
      { ship_id = 2, state = "enroute", from = "nauvis", to = "fulgora",
        manifest = { [q("copper-plate", "normal")] = 100 } },
    },
    shipments = {
      { id = 1, ship_id = 1, from = "nauvis", to = "vulcanus",
        manifest = { [q("steel-plate", "normal")] = 50 },
        return_manifest = { [q("iron-plate", "normal")] = 20 } },
    },
    waiting = {
      { item = q("iron-plate", "rare"), dest_planet = "gleba", unmet = 5, reason = "no_ship" },
      { item = q("copper-plate", "normal"), dest_planet = "gleba", unmet = 5, reason = "no_ship" },
    },
    summary = {},
  }
  -- "iron-plate" (free text, no quality) must match the uncommon manifest, the
  -- return-leg normal iron, and the rare waiting row -- decoding each qkey to its
  -- bare name in all three comparisons (not just the free-text path).
  local byiron = viewmodel.apply_filters(view, { item = "iron-plate" })
  assert_eq(#byiron.roster, 1, "roster: only the iron carrier (manifest qkey decoded to name)")
  assert_eq(byiron.roster[1].ship_id, 1, "the uncommon-iron ship matches a bare-name filter")
  assert_eq(#byiron.shipments, 1, "shipment kept: its RETURN leg carries iron (decoded)")
  assert_eq(#byiron.waiting, 1, "waiting: the rare-iron row matches a bare-name filter")
  assert_eq(byiron.waiting[1].dest_planet, "gleba", "iron waiter kept")
  -- a name on no leg / row drops everything.
  local bynone = viewmodel.apply_filters(view, { item = "stone" })
  assert_eq(#bynone.roster, 0, "no roster row carries stone")
  assert_eq(#bynone.shipments, 0, "no shipment carries stone on either leg")
  assert_eq(#bynone.waiting, 0, "no waiting row needs stone")
end)

describe("Trade-tab overlay round-trips by item NAME across qualities (Task 12)", function()
  local q = qkey.qkey
  -- render_imports reads qkey'd request rows but GROUPS them by bare item NAME and
  -- keys its fleet-toggle / priority widgets by that NAME (the overlay is
  -- per-name). So an override stored by the handler reads back by name and governs
  -- EVERY quality -- keying by qkey would store a value never read back.
  local node = { import_flags = {}, priorities = {} }
  -- the handler stores the player's edit by NAME:
  node.import_flags["iron-plate"] = false
  node.priorities["iron-plate"] = 5
  -- the widgets seed from the same name-keyed reads (a sanity pre-check that the
  -- overlay is name-keyed -- the load-bearing signal is the build_open consequence
  -- below: a single name override governing BOTH qualities of qkey'd request rows):
  assert_eq(demand.source_via_fleet(node, "iron-plate"), false, "fleet toggle round-trips by name")
  assert_eq(demand.priority(node, "iron-plate"), 5, "priority round-trips by name")
  -- and the single name-keyed override governs BOTH iron qualities when the
  -- qkey'd request rows run through build_open; copper (no override) survives.
  local rows = {
    { item = q("iron-plate", "normal"),   requested = 100, on_hand = 0 },
    { item = q("iron-plate", "uncommon"), requested = 50,  on_hand = 0 },
    { item = q("copper-plate", "normal"), requested = 30,  on_hand = 0 },
  }
  local open = demand.build_open(node, rows)
  assert_eq(#open, 1, "name-keyed opt-out suppresses BOTH iron qualities; copper survives")
  assert_eq(open[1].item, q("copper-plate", "normal"), "only copper remains, still fleet-sourced")
end)

describe("qkey.label / label_parts -- player-facing display decode", function()
  -- normal quality shows the bare name; any other quality is parenthesised. Used
  -- by the monitor manifests, the waiting rows, and the debug decision log.
  assert_eq(qkey.label(qkey.qkey("iron-plate", "normal")), "iron-plate", "normal -> bare name")
  assert_eq(qkey.label(qkey.qkey("iron-plate", "uncommon")), "iron-plate (uncommon)", "non-normal parenthesised")
  assert_eq(qkey.label("iron-plate"), "iron-plate", "bare item-name key -> bare name")
  assert_eq(qkey.label_parts("copper-plate", nil), "copper-plate", "nil quality -> bare name")
  assert_eq(qkey.label_parts("copper-plate", "rare"), "copper-plate (rare)", "parts: non-normal parenthesised")
end)

-- ---------------------------------------------------------------------------
-- (reserved for future tasks)
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- summary
-- ---------------------------------------------------------------------------

if failed == 0 then
  io.write(string.format("OK  %d assertions passed\n", total))
  os.exit(0)
else
  io.write(string.format("FAILED  %d/%d assertions failed\n", failed, total))
  os.exit(1)
end

return T
