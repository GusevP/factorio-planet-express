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

-- Per-tick cache of each (surface, force)'s deduped rocket-silo logistic networks.
-- Cargo launches from rocket SILOS (they pull goods from their own logistic network
-- and fire them up), so the silos' networks -- NOT the cargo landing pad's -- are
-- what a planet can actually export. A planet demanding many items would otherwise
-- re-scan the surface for silos once per item; cache the network list per tick
-- instead. Holds live engine handles, rebuilt every tick alongside the stock-value
-- cache (see `begin_tick`), never serialized -- same read-through contract as `cache`.
local silo_networks_cache = { tick = nil, by_key = {} }

-- The deduped list of rocket-silo logistic networks for `force` on `surface`
-- (cached per dispatcher tick). Scoped to the node's force so one force never reads
-- another's launchable stock. Networks are de-duped by `network_id` so several silos
-- sharing one network don't multiply the count. [provisional -- confirm
-- `find_entities_filtered{type="rocket-silo"}`, `LuaEntity.logistic_network`, and
-- `LuaLogisticNetwork.network_id` in-engine before flipping §2 to [confirmed].]
local function silo_networks(surface, force)
  local key = tostring(surface.index or surface.name)
    .. "@" .. tostring(force and (force.index or force.name) or "?")
  local cached = silo_networks_cache.by_key[key]
  if cached then
    return cached
  end
  local nets = {}
  local seen = {}
  local filter = { type = "rocket-silo" }
  if force then
    filter.force = force
  end
  -- Build-then-dedup over the silo set is order-independent (a set-build, not a
  -- decision loop), so plain `pairs` is fine.
  for _, silo in pairs(surface.find_entities_filtered(filter)) do
    if silo.valid then
      local network = silo.logistic_network
      if network then
        local nid = network.network_id
        if nid == nil then
          nets[#nets + 1] = network
        elseif not seen[nid] then
          seen[nid] = true
          nets[#nets + 1] = network
        end
      end
    end
  end
  silo_networks_cache.by_key[key] = nets
  return nets
end

-- [provisional] Launchable item count = what the planet's rocket SILOS can launch.
-- Cargo is fired up by rocket silos pulling from THEIR logistic network; the cargo
-- landing pad only RECEIVES. The pre-2026-06 reader scoped surplus to the PAD's own
-- `logistic_network`, which UNDER-COUNTED whenever the pad was not wired into the
-- same network as the stock/silos: a planet visibly holding 100k exported only the
-- trickle near its pad, clamping every manifest to a fraction of demand (the
-- silo-vs-pad-network caveat, docs/api-notes.md §2 -- the reported "only loads a
-- fraction" bug). Now scope to the UNION of every rocket-silo logistic network on the
-- node's surface (deduped, force-scoped), summed per (item, quality). This counts
-- exactly what a silo can pull and launch -- stock the pad sees but no silo can reach
-- was never launchable, so excluding it is the correction, not a regression. Summing
-- is a commutative reduction (order-independent), so plain `pairs` is fine
-- (determinism: summation, not a decision loop). Degrades safely to 0 when there are
-- no networked silos (a planet that can't launch has no export surplus) or the engine
-- accessor is absent (the pure-Lua test runner, which replaces `stock.reader` wholesale).
--
-- QUALITY (Task 9, #4b): the cargo key is a `qkey(item, quality)`, read PER QUALITY
-- via a SINGLE `ItemWithQualityID` table (`network.get_item_count{name, quality}`) --
-- normal- and uncommon-quality iron are independent pools. The old two-arg
-- `(name, quality)` form crashed in-engine (2.0 `get_item_count` takes 0 or 1 args).
-- A bare item-name key decodes to "normal" so legacy reads still resolve.
local function read_launchable_stock(node, key)
  local name, quality = qkey.qparse(key)
  local surface = node.surface
  -- Guard `surface.valid` (Task 6): a node whose surface was deleted has an invalid
  -- `LuaSurface`. Plain test tables have no `.valid` field (absent => nil), so
  -- `== false` only fires on a real dead engine handle.
  if surface and surface.valid == false then
    return 0
  end
  -- No engine surface (pure-Lua test runner / partial mock) -> nothing to read.
  -- Tests replace `stock.reader` wholesale, so this only guards a partial mock.
  if not (surface and surface.find_entities_filtered) then
    return 0
  end
  local total = 0
  for _, network in pairs(silo_networks(surface, node.force)) do
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
  -- Drop the per-tick silo-network cache in lockstep so a network handle (or a
  -- silo that was built/mined) never leaks across ticks.
  if silo_networks_cache.tick ~= tick then
    silo_networks_cache.tick = tick
    silo_networks_cache.by_key = {}
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
