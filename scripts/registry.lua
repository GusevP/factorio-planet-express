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
-- the mod setting when the engine is present (Task 10 wires the real value),
-- else 0.
local function default_reserve()
  if settings and settings.global then
    local s = settings.global[registry.DEFAULT_RESERVE_SETTING]
    if s and type(s.value) == "number" then
      return s.value
    end
  end
  return 0
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
    import_flags = {}, -- per-item `source via fleet` overlay (Task 2/9)
    priorities = {},   -- per-item request priority overlay (Task 2/9)
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

-- Add (or refresh) a fleet platform entry. Idempotent: an existing platform
-- keeps its enrollment/limits/state (player opt-in persists), only its live
-- platform handle is refreshed. New platforms start un-enrolled and idle -- the
-- fleet is strictly opt-in (the mod never commandeers a ship the player didn't
-- enroll).
function registry.add_platform(platform)
  if not (platform and platform.valid) then
    return nil
  end
  local id = platform.index
  if id == nil then
    return nil
  end
  local entry = storage.fleet[id]
  if entry then
    entry.platform = platform
    return entry
  end
  entry = {
    platform = platform,
    enrolled = false,
    allowed_planets = nil, -- nil/"all" => serves every planet (see fleet.lua)
    state = "idle",
    assignment = nil,
  }
  storage.fleet[id] = entry
  state.debug_log("registry: platform added id#" .. id)
  return entry
end

-- Drop a fleet platform entry by its platform index.
function registry.remove_platform(platform_id)
  if platform_id and storage.fleet[platform_id] then
    storage.fleet[platform_id] = nil
    state.debug_log("registry: platform removed id#" .. platform_id)
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
-- watchdog's job in Task 6 -- the registry only maintains the index.)
function registry.on_entity_removed(entity)
  if not (entity and entity.valid) then
    return
  end
  if entity.name == registry.PAD_NAME then
    registry.remove_node(entity.unit_number)
  elseif entity.name == registry.HUB_NAME then
    local platform = entity.surface and entity.surface.platform
    if platform then
      registry.remove_platform(platform.index)
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
