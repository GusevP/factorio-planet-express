-- scripts/stock.lua
--
-- Launchable-stock reads + surplus computation for a trade node.
--
-- "Surplus" is what a planet can offer for export: its launchable stock (scoped
-- to the trade node's OWN logistic network, not the whole surface) minus the
-- reserve floor, suppressed to zero below the minimum-trip threshold so the
-- dispatcher never schedules a pointless dribble.
--
--   surplus(node, item) = max(0, stock - reserve)   [then min-trip suppressed]
--
-- Design split (per the plan's pure-function seam):
--   * `compute_surplus` is PURE arithmetic -- unit-tested under plain `lua`.
--   * the launchable-stock READ is a thin IO wrapper (`stock.reader`) around the
--     provisional accessor recorded in docs/api-notes.md §2. It is swappable so
--     the cache behavior can be exercised in tests without a running engine.
--
-- Per-tick caching (cache-invalidation contract): every read is tagged with the
-- dispatcher's current tick. `stock.begin_tick(tick)` is called once at the top
-- of each dispatcher loop; the first read of a (surface,item) pair this tick
-- hits the engine, subsequent reads hit the cache, and the WHOLE cache is
-- dropped the moment the tick advances -- so a stale value can never leak into
-- the next tick. The cache is plain in-memory (a read-through of engine state),
-- NOT in `storage`: it is rebuilt freely and holds no authoritative data.

local reserves = require("scripts.reserves")
local qkey = require("scripts.qkey")

local stock = {}

-- Minimum-trip threshold fallback. Task 10 wires the real value via this
-- setting; until then surplus below this many items reports as zero.
stock.MIN_TRIP = 1
stock.MIN_TRIP_SETTING = "planet-express-min-trip"

-- ---------------------------------------------------------------------------
-- pure surplus math
-- ---------------------------------------------------------------------------

-- Pure: launchable stock minus reserve, clamped at zero, then min-trip
-- suppressed (a positive-but-tiny surplus below `min_trip` reports as 0).
function stock.compute_surplus(stock_count, reserve_amount, min_trip)
  local s = (stock_count or 0) - (reserve_amount or 0)
  if s < 0 then
    s = 0
  end
  if min_trip and s < min_trip then
    return 0
  end
  return s
end

-- ---------------------------------------------------------------------------
-- launchable-stock IO wrapper (provisional -- docs/api-notes.md §2)
-- ---------------------------------------------------------------------------

-- [provisional] Launchable item count scoped to the trade node's OWN logistic
-- network -- the network the pad entity belongs to (`pad.logistic_network`).
-- This is what a rocket silo on the pad's network can actually launch; summing
-- ALL networks on the surface over-counts on planets with two or more
-- DISCONNECTED logistic networks, making the mod promise surplus a silo can't
-- launch (see docs/api-notes.md §2 and its silo-vs-pad caveat). When the
-- per-node accessor is unavailable (no/invalid pad entity, or the pad isn't on
-- a network) we DEGRADE SAFELY to the old surface-sum rather than erroring; an
-- under-count is recovered by the re-clamp / load_impossible paths, never a
-- crash. Confirm `LuaEntity.logistic_network` (+ `get_item_count`) in-engine
-- before flipping §2 to [confirmed].
--
-- QUALITY (Task 9, #4b): the cargo key is a `qkey(item, quality)`, so the
-- launchable stock is read PER QUALITY (`network.get_item_count(name, quality)`)
-- -- normal-quality iron and uncommon-quality iron are independent stock pools.
-- A bare item-name key decodes to "normal" so legacy/quality-agnostic reads
-- still resolve.
local function read_launchable_stock(node, key)
  local name, quality = qkey.qparse(key)
  local pad = node.entity
  if pad and pad.valid then
    local network = pad.logistic_network
    if network then
      return network.get_item_count(name, quality)
    end
  end

  -- Fallback: aggregate every logistic network on the node's surface. Summing
  -- is order-independent (a commutative reduction, NOT a game-affecting decision
  -- iteration), so plain `pairs` is fine here.
  local surface, force = node.surface, node.force
  -- Guard `surface.valid` (Task 6): a node whose surface was deleted has an
  -- invalid `LuaSurface`, so reading `.name` off it below would error. Plain test
  -- tables have no `.valid` field (absent => nil), so `== false` only short-circuits
  -- on a real dead engine handle and the pure-Lua test runner is unaffected.
  if surface and surface.valid == false then
    return 0
  end
  if not (surface and force and force.logistic_networks) then
    return 0
  end
  local networks = force.logistic_networks[surface.name]
  if not networks then
    return 0
  end
  local total = 0
  for _, network in pairs(networks) do
    total = total + network.get_item_count(name, quality)
  end
  return total
end

-- The active reader. Tests replace this with a plain-Lua stub to drive the
-- cache without an engine.
stock.reader = read_launchable_stock

-- ---------------------------------------------------------------------------
-- per-tick cache
-- ---------------------------------------------------------------------------

-- In-memory read-through cache. `tick` is the tick all `values` belong to.
local cache = { tick = nil, values = {} }

-- Cache key: launchable stock is per-surface AND per-force (forces don't share
-- logistic networks), so key on a stable surface identifier, the force identity,
-- and the cargo `qkey` (item@quality -- so normal- and uncommon-quality stock of
-- one item cache independently). Without the force term, two forces on one surface
-- would read each other's cached stock. Falls back to a node-supplied key (tests)
-- or "?".
local function cache_key(node, item)
  local sid = node.cache_key
  -- Guard `surface.valid` (Task 6): a deleted surface's handle errors on `.index`
  -- / `.name`. `== false` only fires on a real dead engine handle (plain test
  -- tables have no `.valid` field), so the test runner keeps using node.surface.
  local surface = node.surface
  if sid == nil and surface and surface.valid ~= false then
    sid = surface.index or surface.name
    local fid = node.force and (node.force.index or node.force.name)
    sid = tostring(sid) .. "@" .. tostring(fid or "?")
  end
  return tostring(sid or "?") .. "/" .. tostring(item)
end

-- Open a dispatcher tick. Drops the entire cache when the tick advances so no
-- value survives past the tick it was read in.
function stock.begin_tick(tick)
  if cache.tick ~= tick then
    cache.tick = tick
    cache.values = {}
  end
end

-- Launchable stock for an item, served from the per-tick cache (first read this
-- tick hits `stock.reader`; later reads are cached).
function stock.stock_count(node, item)
  local key = cache_key(node, item)
  local v = cache.values[key]
  if v == nil then
    v = stock.reader(node, item) or 0
    cache.values[key] = v
  end
  return v
end

-- ---------------------------------------------------------------------------
-- surplus (IO read + reserve + min-trip)
-- ---------------------------------------------------------------------------

-- Read the effective minimum-trip threshold (mod setting if present, else the
-- module fallback). Guarded so it works under the pure-Lua test runner. Exposed
-- as a module function so the view-model reuses this single source of truth
-- (it classifies `below_min_trip` waiting demand against the same value).
function stock.min_trip()
  if settings and settings.global then
    local s = settings.global[stock.MIN_TRIP_SETTING]
    if s and type(s.value) == "number" then
      return s.value
    end
  end
  return stock.MIN_TRIP
end

-- Exportable surplus of the cargo `key` (a `qkey(item, quality)`) on `node`:
-- cached launchable stock minus the node's reserve floor, min-trip suppressed.
-- This is pure STOCK math -- demand-awareness (the re-export thrash guard) lives
-- in the dispatcher's `exportable()` (Task 5), not here.
--
-- The reserve floor is keyed by bare item NAME (a reserve applies to ALL
-- qualities of an item -- per the plan's Decisions), so the qkey is `qparse`d
-- back to its name before `reserves.reserve`; the stock read stays per quality.
function stock.surplus(node, key)
  local name = qkey.qparse(key)
  local s = stock.stock_count(node, key)
  return stock.compute_surplus(s, reserves.reserve(node, name), stock.min_trip())
end

return stock
