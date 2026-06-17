-- scripts/registry.lua
--
-- Event-maintained index of the two things the dispatcher iterates: trade nodes
-- (cargo landing pads -- one per planet) and fleet platforms (space platforms).
--
-- The registry is the ONLY place that learns about pads/platforms appearing and
-- disappearing; everything else reads `storage.nodes` / `storage.fleet`. This is
-- the performance contract from the plan: never scan all entities on the
-- dispatcher tick -- maintain the index incrementally on build/mine/destroy
-- events, and rebuild once on init / configuration change for existing saves.
--
-- This module is ENGINE-TOUCHING (it resolves real entities/platforms), so it is
-- NOT exercised by the pure calc tests -- its wiring is verified by manual
-- playtest (build/scrap a pad and a platform, confirm the index tracks them
-- across save/load). The pure eligibility math lives in `scripts/fleet.lua`.
--
-- Determinism: this module only WRITES the index; every game-affecting READ of
-- it (dispatcher, watchdog, GUIs) goes through `state.sorted_pairs`. The two
-- iterator helpers below enforce that for callers.

local state = require("scripts.state")
local reserves = require("scripts.reserves")

local registry = {}

-- Prototype names we track. [provisional -- confirm exact 2.0 / Space Age
-- prototype names in-engine: the cargo landing pad and the space platform hub.]
registry.PAD_NAME = "cargo-landing-pad"
registry.HUB_NAME = "space-platform-hub"

-- ---------------------------------------------------------------------------
-- default reserve floor (guarded -- pure-Lua test runner has no `settings`)
-- ---------------------------------------------------------------------------

registry.DEFAULT_RESERVE_SETTING = "planet-express-default-reserve"

-- The global default reserve floor a freshly-registered node starts with. Reads
-- the mod setting via `state.setting` (0 when `settings` is absent, e.g. the
-- pure-Lua test runner).
local function default_reserve()
  return state.setting(registry.DEFAULT_RESERVE_SETTING, 0)
end

-- ---------------------------------------------------------------------------
-- trade nodes (cargo landing pads)
-- ---------------------------------------------------------------------------

-- Add (or refresh) a trade node for a landing pad entity. Idempotent: an
-- already-registered pad just has its live entity/surface/force references
-- refreshed (entity handles can change identity across save/load), so the
-- player's reserve/import overlay is never clobbered.
function registry.add_node(entity)
  if not (entity and entity.valid and entity.unit_number) then
    return nil
  end
  local id = entity.unit_number
  local node = storage.nodes[id]
  if node then
    node.entity = entity
    node.surface = entity.surface
    node.force = entity.force
    return node
  end
  node = {
    id = id,
    entity = entity,
    surface = entity.surface,
    force = entity.force,
    reserves = { default = default_reserve(), items = {} },
    import_flags = {}, -- per-item `source via fleet` overlay
    priorities = {},   -- per-item request priority overlay
  }
  storage.nodes[id] = node
  state.debug_log("registry: node added pad#" .. id)
  return node
end

-- Drop a trade node by its pad unit_number.
function registry.remove_node(unit_number)
  if unit_number and storage.nodes[unit_number] then
    storage.nodes[unit_number] = nil
    state.debug_log("registry: node removed pad#" .. unit_number)
  end
end

-- ---------------------------------------------------------------------------
-- fleet platforms (space platforms)
-- ---------------------------------------------------------------------------

-- The bare per-force identifier stamped on a fleet entry (consumed by the
-- Monitor's force scoping). Equals `dispatcher.force_key(force)` by construction;
-- duplicated inline here (a one-liner) rather than requiring `dispatcher`, which
-- would close a require cycle (dispatcher -> registry -> dispatcher). KISS: the
-- coupling is not worth a shared module for a single `index or name`.
local function force_key_of(force)
  if not force then
    return nil
  end
  return force.index or force.name
end

-- Force-qualified fleet key. `platform.index` is per-force on a multi-force map
-- (not proven globally unique in 2.0), so two forces' platforms could otherwise
-- collide on the same numeric key. Qualifying by force makes the key total and
-- stable: a string "<force key>/<platform index>". `state.sorted_keys` already
-- orders mixed/string keys deterministically, so iteration stays total.
function registry.fleet_key(platform)
  local force = platform and platform.valid and platform.force
  return tostring(force_key_of(force)) .. "/" .. tostring(platform.index)
end

-- Add (or refresh) a fleet platform entry. Idempotent: an existing platform
-- keeps its enrollment/limits/state (player opt-in persists), only its live
-- platform handle is refreshed. New platforms start un-enrolled and idle -- the
-- fleet is strictly opt-in (the mod never commandeers a ship the player didn't
-- enroll).
function registry.add_platform(platform)
  if not (platform and platform.valid) then
    return nil
  end
  if platform.index == nil then
    return nil
  end
  local key = registry.fleet_key(platform)
  local entry = storage.fleet[key]
  if entry then
    entry.platform = platform
    entry.force = force_key_of(platform.force)
    return entry
  end
  entry = {
    platform = platform,
    force = force_key_of(platform.force), -- bare force key (Monitor scoping)
    enrolled = false,
    allowed_planets = nil, -- nil/"all" => serves every planet (see fleet.lua)
    state = "idle",
    assignment = nil,
  }
  storage.fleet[key] = entry
  state.debug_log("registry: platform added " .. key)
  return entry
end

-- Clear any node's "Preferred ship" pin that referenced a now-gone fleet
-- key, so a dangling pin can never persist and silently steer dispatch toward a
-- ship that no longer exists. `dispatcher.pick_ship` already falls back to
-- auto-pick when a pinned ship isn't free + eligible, but a stale pin would
-- mislead the Trade-tab readout and could match a re-used key, so we null it out
-- at the source. Build-then-write by node key is order-independent (a keyed
-- write, not a decision over the set), so plain `pairs` is fine.
function registry.clear_pin(fleet_key)
  if fleet_key == nil then
    return
  end
  for _, node in pairs(storage.nodes or {}) do
    if node.pin_ship == fleet_key then
      node.pin_ship = nil
    end
  end
end

-- Drop a fleet platform entry by its (force-qualified) fleet key.
function registry.remove_platform(fleet_key)
  if fleet_key and storage.fleet[fleet_key] then
    storage.fleet[fleet_key] = nil
    registry.clear_pin(fleet_key)
    state.debug_log("registry: platform removed " .. tostring(fleet_key))
  end
end

-- ---------------------------------------------------------------------------
-- surface deletion (called from control.lua on on_pre_surface_deleted)
-- ---------------------------------------------------------------------------

-- A surface is about to be deleted. We hook the PRE event because by
-- the time `on_surface_deleted` fires the stored `node.surface` handle is
-- already invalid and can't be matched against `event.surface_index`; in the
-- pre-event the surface is still valid, so each node's surface index is
-- readable. Prune every node still on that surface (its pad is going away with
-- it) plus any fleet entry resolvable to that surface. The validity guards in
-- `build_snapshot` / `stock.lua` remain the primary defense -- this handler just
-- stops the ghost lingering until the next rebuild. Build-then-delete by key is
-- order-independent (a per-entry validity test, not a decision over the set), so
-- plain `pairs` is fine.
function registry.on_pre_surface_deleted(surface_index)
  if surface_index == nil then
    return
  end

  local dead_nodes = {}
  for id, node in pairs(storage.nodes or {}) do
    local s = node.surface
    if s and s.valid and s.index == surface_index then
      dead_nodes[#dead_nodes + 1] = id
    end
  end
  for _, id in ipairs(dead_nodes) do
    registry.remove_node(id)
  end

  local dead_ships = {}
  for key, entry in pairs(storage.fleet or {}) do
    local platform = entry.platform
    local s = platform and platform.valid and platform.surface
    if s and s.valid and s.index == surface_index and entry.assignment == nil then
      dead_ships[#dead_ships + 1] = key
    end
  end
  for _, key in ipairs(dead_ships) do
    registry.remove_platform(key)
  end
end

-- ---------------------------------------------------------------------------
-- event entry points (called from control.lua)
-- ---------------------------------------------------------------------------

-- A pad or platform-hub was built/revived. Dispatch by prototype name.
function registry.on_entity_built(entity)
  if not (entity and entity.valid) then
    return
  end
  if entity.name == registry.PAD_NAME then
    registry.add_node(entity)
  elseif entity.name == registry.HUB_NAME then
    local platform = entity.surface and entity.surface.platform
    if platform then
      registry.add_platform(platform)
    end
  end
end

-- A pad or platform-hub was mined/destroyed. Dispatch by prototype name. The
-- entity is still valid at the moment these events fire, so its name/identity is
-- readable. (Freeing any in-flight assignment that referenced it is the
-- watchdog's job -- the registry only maintains the index.)
function registry.on_entity_removed(entity)
  if not (entity and entity.valid) then
    return
  end
  if entity.name == registry.PAD_NAME then
    registry.remove_node(entity.unit_number)
  elseif entity.name == registry.HUB_NAME then
    local platform = entity.surface and entity.surface.platform
    if platform then
      registry.remove_platform(registry.fleet_key(platform))
    end
  end
end

-- ---------------------------------------------------------------------------
-- rebuild-on-init (existing saves / configuration change)
-- ---------------------------------------------------------------------------

-- Full re-scan of the world to seed the index. Run on init and on configuration
-- change so a save created before the mod (or before this task) gets its pads
-- and platforms indexed. Incremental events keep it current thereafter, so this
-- whole-world scan never runs on the dispatcher tick.
function registry.rebuild()
  storage.nodes = storage.nodes or {}
  storage.fleet = storage.fleet or {}

  -- Prune stale ghosts before re-scanning. An entry whose live handle
  -- went invalid (surface deleted, platform/pad gone without a clean
  -- mine/destroy event) would otherwise linger and get picked as an export
  -- source or dereferenced on the dispatcher tick. Build-then-delete by key is
  -- order-independent (validity is per-entry, not a decision over the set), so
  -- plain `pairs` is fine. A fleet entry that still holds a live assignment is
  -- LEFT for the watchdog to free first -- prune only unassigned ghosts, so the
  -- watchdog's destroyed-ship path still re-opens that assignment's demand.
  local dead_nodes = {}
  for id, node in pairs(storage.nodes) do
    if not (node.entity and node.entity.valid) then
      dead_nodes[#dead_nodes + 1] = id
    end
  end
  for _, id in ipairs(dead_nodes) do
    storage.nodes[id] = nil
  end

  local dead_ships = {}
  for key, entry in pairs(storage.fleet) do
    if not (entry.platform and entry.platform.valid) and entry.assignment == nil then
      dead_ships[#dead_ships + 1] = key
    end
  end
  for _, key in ipairs(dead_ships) do
    storage.fleet[key] = nil
    -- a pruned ghost can still be referenced by a node's pin -- clear it
    -- so the dangling pin doesn't outlive the ship it pointed at.
    registry.clear_pin(key)
  end

  -- Heal fleet-key DRIFT (v2 self-heal). storage.fleet must be keyed by the
  -- force-qualified registry.fleet_key; an entry still keyed by the legacy bare
  -- platform.index (a pre-v2 save whose schema-gated migration never ran -- a
  -- same-version mod repackage does NOT fire on_configuration_changed, so the
  -- one-shot migrate_fleet_keys is skipped) makes EVERY fleet_key lookup miss:
  -- the Fleet tab then can't find the ship to enroll and the dispatcher can't
  -- match it. Re-key any entry whose stored key != fleet_key(its live platform),
  -- preserving its enrollment/allow-list, and re-point assignments + pins that
  -- referenced the old key. Idempotent (a correct key maps to itself), so this is
  -- a no-op on a healthy index. Build-then-apply by key (order-independent, not a
  -- decision loop), so plain `pairs` is fine.
  local rekey = {}
  for key, entry in pairs(storage.fleet) do
    local platform = entry.platform
    if platform and platform.valid then
      local want = registry.fleet_key(platform)
      if want ~= key then
        rekey[#rekey + 1] = { old = key, new = want }
      end
    end
  end
  for _, r in ipairs(rekey) do
    local entry = storage.fleet[r.old]
    storage.fleet[r.old] = nil
    entry.force = force_key_of(entry.platform.force) -- backfill (pre-v2 entries lacked it)
    storage.fleet[r.new] = entry
    for _, a in pairs(storage.assignments or {}) do
      if a.ship == r.old then
        a.ship = r.new
      end
    end
    for _, node in pairs(storage.nodes or {}) do
      if node.pin_ship == r.old then
        node.pin_ship = r.new
      end
    end
    state.debug_log("registry: re-keyed fleet " .. tostring(r.old) .. " -> " .. r.new)
  end

  -- pads live on planet surfaces
  for _, surface in pairs(game.surfaces) do
    local pads = surface.find_entities_filtered({ name = registry.PAD_NAME })
    for _, pad in pairs(pads) do
      registry.add_node(pad)
    end
  end

  -- platforms hang off forces. [provisional -- confirm `force.platforms` is the
  -- 2.0 accessor for a force's space platforms.]
  for _, force in pairs(game.forces) do
    local platforms = force.platforms
    if platforms then
      for _, platform in pairs(platforms) do
        registry.add_platform(platform)
      end
    end
  end

  state.debug_log("registry: rebuild complete")
end

-- ---------------------------------------------------------------------------
-- deterministic iteration helpers (callers MUST use these)
-- ---------------------------------------------------------------------------

-- Iterate trade nodes in stable key (pad unit_number) order.
function registry.nodes()
  return state.sorted_pairs(storage.nodes)
end

-- Iterate fleet platforms in stable key (platform id) order.
function registry.platforms()
  return state.sorted_pairs(storage.fleet)
end

return registry
