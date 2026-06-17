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

local state = require("scripts.state")
local reserves = require("scripts.reserves")
local qkey = require("scripts.qkey")

local stock = {}

-- Minimum-trip threshold fallback when `settings` is absent (the pure-Lua test
-- runner); `stock.min_trip()` reads the real value from this setting. Surplus
-- below this many items reports as zero.
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

-- [provisional] Launchable item count for a planet = the SUM over EVERY logistic
-- network on the node's surface (for the node's force) of that network's count of
-- the (item, quality). What a planet can launch is whatever its rocket silos can
-- pull, and silos pull from the surface's logistic networks -- so read the NETWORKS
-- directly rather than via the silos.
--
-- History of this seam (two failed scopings before this one):
--   * PAD's own network (`pad.logistic_network`) -- UNDER-counted when the bulk stock
--     sat on a different network than the cargo landing pad (the pad only receives),
--     so a planet holding 100k exported a trickle (the reported "only loads 100-200").
--   * ROCKET-SILO networks (`silo.logistic_network`, union) -- returned ZERO on every
--     planet of a real Krastorio megabase (playtest 2026-06): silos there are
--     belt/train-fed and NOT on a logistic network, so `silo.logistic_network` is nil
--     and the union was empty -> total dispatch starvation.
-- The surface-wide sum sees the stock wherever it is bot-networked, regardless of how
-- the silos are fed. Its only downside -- over-counting a planet split into DISCONNECTED
-- networks -- is the SAFE direction (an over-promise self-corrects via the re-clamp /
-- load_impossible paths), far better than starving every dispatch. `force.logistic_networks`
-- is a `dictionary[surface name -> array[LuaLogisticNetwork]]` (confirmed, 2.0). Summing
-- is a commutative reduction, so plain `pairs` is fine. Degrades to 0 when the
-- surface/force/networks are absent (the pure-Lua test runner, or a padless ghost).
--
-- KNOWN LIMIT: stock that is NOT in any logistic network (pure belt/train buffers with
-- no roboport coverage) is invisible to this read, as it was to both earlier scopings --
-- the mod's whole surplus model is logistic-network-based. If a base reports zero
-- surplus here, its export stock isn't bot-networked and a deeper inventory read would
-- be needed.
--
-- QUALITY: read PER QUALITY via a SINGLE `ItemWithQualityID` table
-- (`network.get_item_count{name, quality}`). The old two-arg `(name, quality)` form
-- crashed in-engine (2.0 `get_item_count` takes 0 or 1 args). A bare item-name key
-- decodes to "normal" so legacy/quality-agnostic reads still resolve.
local function read_launchable_stock(node, key)
  local name, quality = qkey.qparse(key)
  local surface, force = node.surface, node.force
  -- Guard `surface.valid`: a deleted surface's handle errors on `.name`.
  -- Plain test tables have no `.valid` field (absent => nil), so `== false` only
  -- fires on a real dead engine handle and the pure-Lua test runner is unaffected.
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
    total = total + network.get_item_count({ name = name, quality = quality })
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
  -- Guard `surface.valid`: a deleted surface's handle errors on `.index`
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
  return state.setting(stock.MIN_TRIP_SETTING, stock.MIN_TRIP)
end

-- Exportable surplus of the cargo `key` (a `qkey(item, quality)`) on `node`:
-- cached launchable stock minus the node's reserve floor, min-trip suppressed.
-- This is pure STOCK math -- demand-awareness (the re-export thrash guard) lives
-- in the dispatcher's `exportable()`, not here.
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
