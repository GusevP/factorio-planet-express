-- scripts/gui/fleet_tab.lua
--
-- The Planet Express Fleet overlay on the vanilla Space Platform Hub GUI. This
-- is where the player ENROLLS a platform into the merchant fleet and sets its
-- per-ship limits. It is the supply-side mirror of the Trade tab (which steers a
-- planet via the Cargo Landing Pad GUI): a RELATIVE GUI anchored beside the
-- hub's own window, shown when the player opens a space platform hub AND the
-- "Interplanetary Trade Logistics" technology is researched, and torn down when
-- the window closes.
--
-- Without this panel there is no way to flip a platform's `enrolled` flag, so the
-- dispatcher (which only ever touches enrolled, idle ships) can never pick one --
-- i.e. the whole fleet is the reason the rest of the mod exists. Controls:
--   * Enroll -- opt this platform into auto-dispatch (fleet.set_enrolled).
--     Strictly opt-in; the mod never commandeers a ship the player didn't enroll.
--   * Reserve for manual use -- keep the ship OUT of auto-dispatch even while
--     enrolled (fleet.set_reserve_for_manual_use), so the player can fly it by
--     hand without un-enrolling it.
--
-- Like the Trade tab and the Monitor, this module is INTENTIONALLY dumb: it
-- renders and routes events; the state lives in `storage.fleet` and the
-- writers/eligibility math are in the (unit-tested) pure `scripts/fleet.lua`. The
-- engine-touching render/event wiring here is verified by MANUAL PLAYTEST (open a
-- platform hub, toggle enrollment, confirm it persists across save/load and the
-- ship starts/stops being dispatched).

local fleet = require("scripts.fleet")
local registry = require("scripts.registry")
local common = require("scripts.gui.common")

local fleet_tab = {}

-- [provisional] The space platform hub prototype name. Mirrors registry.HUB_NAME
-- (the registry indexes platforms off the same name); confirm the exact 2.0 /
-- Space Age name in-engine before publishing.
fleet_tab.HUB_NAME = "space-platform-hub"

-- Element names (greppable, collision-proof under the mod namespace).
local FRAME = "planet-express-fleet-frame"
local BODY = "planet-express-fleet-body"
local TOGGLE = "planet-express-fleet-toggle"
local ENROLL = "planet-express-fleet-enroll"
local RESERVE_MANUAL = "planet-express-fleet-reserve-manual"
local REQUIRE_READY = "planet-express-fleet-require-ready"
-- Container for the per-planet allow-list checkboxes, plus the name prefix each
-- planet checkbox carries (the planet name is the suffix, recovered on toggle).
local PLANETS = "planet-express-fleet-planets"
local PLANETS_SCROLL = "planet-express-fleet-planets-scroll"
local PLANET_PREFIX = "planet-express-fleet-planet/"

-- [confirmed] The universe of planets the per-ship allow-list can restrict.
-- `game.planets` is a LuaCustomTable[name -> LuaPlanet]; `planet.name` matches the
-- surface name the dispatcher compares against (dispatcher.planet_name), and
-- `planet.prototype.localised_name` is the display caption. Sorted by name so the
-- checkbox order (and the universe the toggle handler rebuilds) is deterministic.
local function known_planets()
  local out = {}
  for name, planet in pairs(game.planets or {}) do
    out[#out + 1] = {
      name = name,
      caption = (planet.prototype and planet.prototype.localised_name) or name,
    }
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

-- ---------------------------------------------------------------------------
-- platform / entry lookup
-- ---------------------------------------------------------------------------

-- The LuaSpacePlatform for a hub entity (nil unless it really is a platform hub).
-- The registry keys storage.fleet by the force-qualified `registry.fleet_key`
-- (see registry.add_platform), so that string key is the fleet id used everywhere
-- below -- `open` derives it via registry.fleet_key(platform) and stores it in the
-- frame tag, never the bare platform.index.
local function platform_of(entity)
  if not (entity and entity.valid and entity.name == fleet_tab.HUB_NAME) then
    return nil
  end
  return entity.surface and entity.surface.platform
end

-- The fleet id a Fleet frame is editing, recovered from its stored fleet key (the
-- force-qualified registry.fleet_key string, set by `open`).
local function id_of_frame(frame)
  return frame and frame.tags and frame.tags.platform or nil
end

-- The fleet entry a Fleet frame is editing (nil if the platform deregistered).
local function entry_of_frame(frame)
  local id = id_of_frame(frame)
  return id and fleet.get(id) or nil
end

-- ---------------------------------------------------------------------------
-- body render
-- ---------------------------------------------------------------------------

-- Rebuild the frame body from the live fleet entry. Re-reading the entry (rather
-- than trusting the click) keeps the checkboxes honest -- e.g. if enrollment was
-- refused by the tech gate, the box snaps back to the stored state.
local function render_body(body, entry)
  body.clear()
  body.add({
    type = "checkbox",
    name = ENROLL,
    caption = { "planet-express.fleet-enroll" },
    state = entry.enrolled == true,
  })
  body.add({
    type = "checkbox",
    name = RESERVE_MANUAL,
    caption = { "planet-express.fleet-reserve-manual" },
    state = entry.reserve_for_manual_use == true,
  })

  -- "Hold until ready signal": gate dispatch on the player's own readiness logic.
  -- The checkbox writes entry.require_ready; the hint tells the player EXACTLY which
  -- signal to wire to the hub (icon via rich text + the localised signal name).
  body.add({
    type = "checkbox",
    name = REQUIRE_READY,
    caption = { "planet-express.fleet-require-ready" },
    state = entry.require_ready == true,
  })
  body.add({
    type = "label",
    caption = {
      "planet-express.fleet-ready-hint",
      { "virtual-signal-name." .. fleet.READY_SIGNAL },
    },
  })
  -- Setup-time SNAPSHOT of the live hub value (the Fleet tab has no recurring
  -- refresh -- it renders only on open / on toggle). Reads via the ONE shared
  -- wrapper; the Monitor's "held" state is the live view (pointed to in the
  -- tooltip). Only read when gated, mirroring the dispatch gate.
  if entry.require_ready == true then
    local value = fleet.read_ready_value(entry.platform)
    local key = fleet.ready_from_signal(true, value)
      and "planet-express.fleet-ready-readout-ready"
      or "planet-express.fleet-ready-readout-held"
    body.add({
      type = "label",
      caption = { key, tostring(value) },
      tooltip = { "planet-express.fleet-ready-readout-tooltip" },
    })
  end

  body.add({
    type = "label",
    caption = { "planet-express.fleet-status", tostring(entry.state or "-") },
  })

  -- Per-ship allow-list: one checkbox per known planet, ticked = this ship may
  -- fly there. All ticked is the unrestricted default (stored as nil); untick a
  -- planet a ship can't reach (e.g. no Aquilo-grade thrusters). The toggle handler
  -- rebuilds the list from these checkboxes via the pure fleet.allowed_from_selection.
  body.add({ type = "line" })
  body.add({
    type = "label",
    caption = { "planet-express.fleet-allowed-planets" },
    tooltip = { "planet-express.fleet-allowed-planets-tip" },
  })
  -- Bound the per-planet list in a scroll-pane: with many mod planets the flat flow
  -- grew taller than the hub window and pushed the whole panel off-screen (the
  -- checkboxes stayed clickable but invisible). A fixed-height scroll keeps it on screen.
  local scroll = body.add({ type = "scroll-pane", name = PLANETS_SCROLL, direction = "vertical" })
  scroll.style.maximal_height = 400
  scroll.style.minimal_width = 180
  local planets = scroll.add({ type = "flow", name = PLANETS, direction = "vertical" })
  for _, p in ipairs(known_planets()) do
    planets.add({
      type = "checkbox",
      name = PLANET_PREFIX .. p.name,
      caption = p.caption,
      state = fleet.allows_planet(entry, p.name),
    })
  end
end

local function refresh_frame(frame)
  local entry = entry_of_frame(frame)
  local body = frame[BODY]
  if entry and body then
    render_body(body, entry)
  end
end

-- ---------------------------------------------------------------------------
-- open / close (driven by on_gui_opened / on_gui_closed)
-- ---------------------------------------------------------------------------

-- [provisional] The relative-GUI anchor for the space platform hub window.
-- Confirm the exact `defines.relative_gui_type` for the hub in-engine before
-- flipping the api-notes GUI seam to [confirmed]; the rest of the module is
-- independent of which anchor is used.
local function relative_anchor()
  return {
    gui = defines.relative_gui_type.space_platform_hub_gui,
    position = defines.relative_gui_position.right,
  }
end

-- Open the Fleet overlay for the platform the player just opened. No-op unless
-- the entity is a platform hub, the platform is registered, and the tech is
-- researched.
function fleet_tab.open(player, entity)
  local platform = platform_of(entity)
  if not platform then
    return
  end
  if not fleet.tech_researched(player.force) then
    return
  end
  -- Force isolation: only the OWNING force may enroll / restrict a platform.
  -- Compare by the force KEY (index/name), not userdata equality, so a researched
  -- force can't enroll a friendly FOREIGN force's platform just by opening its hub.
  if common.force_key(entity.force) ~= common.force_key(player.force) then
    return
  end
  -- The fleet id is the force-qualified registry key (registry.fleet_key reads
  -- platform.force internally), NOT the bare platform.index -- that is the key the
  -- registry/dispatcher/storage.fleet use post-migration.
  local id = registry.fleet_key(platform)
  local entry = id and fleet.get(id)
  if not entry then
    return -- platform not indexed yet (the registry adds it on build/rebuild)
  end

  -- Destroy any stale frame first so re-opens always reflect the current ship.
  local existing = player.gui.relative[FRAME]
  if existing then
    existing.destroy()
  end

  local frame = player.gui.relative.add({
    type = "frame",
    name = FRAME,
    direction = "vertical",
    caption = { "planet-express.fleet-title" },
    anchor = relative_anchor(),
    tags = { platform = id },
  })
  -- Collapsible: the frame caption is always shown (a slim title bar); the toggle
  -- button shows/hides the controls so the panel doesn't clutter the hub window
  -- when not in use. Starts COLLAPSED (body hidden) -- click to expand.
  frame.add({ type = "button", name = TOGGLE, caption = { "planet-express.fleet-show" } })
  local body = frame.add({ type = "flow", name = BODY, direction = "vertical" })
  body.visible = false
  refresh_frame(frame)
end

function fleet_tab.close(player)
  local frame = player.gui.relative[FRAME]
  if frame then
    frame.destroy()
  end
end

-- ---------------------------------------------------------------------------
-- event routing (registered from control.lua)
-- ---------------------------------------------------------------------------

function fleet_tab.on_gui_opened(event)
  if event.gui_type ~= defines.gui_type.entity then
    return
  end
  local player = game.get_player(event.player_index)
  if player then
    fleet_tab.open(player, event.entity)
  end
end

function fleet_tab.on_gui_closed(event)
  if event.gui_type ~= defines.gui_type.entity then
    return
  end
  local player = game.get_player(event.player_index)
  if player then
    fleet_tab.close(player)
  end
end

-- The open Fleet frame for an event element, or nil when the element isn't ours.
-- Resolved by walking the element's OWN ancestry (common.ancestor_frame), not a
-- `gui.relative[FRAME]` by-name fetch: that proves the event element really
-- descends from our frame, so a foreign element merely COPYING our element name
-- can't drive a write (enroll / allow-list) into the platform our frame edits.
local function frame_of(el)
  if not (el and el.valid) then
    return nil
  end
  return common.ancestor_frame(el, FRAME)
end

-- Checkboxes: enroll + reserve-for-manual-use, both persisted to storage.fleet
-- via the pure writers. set_enrolled is tech-gated (already satisfied here, since
-- `open` checks it), so we refresh from the live entry afterward to reflect the
-- actual stored state rather than the raw click.
function fleet_tab.on_gui_checked_state_changed(event)
  local el = event.element
  local frame = frame_of(el)
  if not frame then
    return
  end
  local id = id_of_frame(frame)
  if not id then
    return
  end
  if el.name == ENROLL then
    fleet.set_enrolled(id, el.state)
    refresh_frame(frame)
  elseif el.name == RESERVE_MANUAL then
    fleet.set_reserve_for_manual_use(id, el.state)
  elseif el.name == REQUIRE_READY then
    -- Persist the toggle, then rebuild the body so the snapshot readout appears
    -- (on) or disappears (off) to match the new state.
    fleet.set_require_ready(id, el.state)
    refresh_frame(frame)
  elseif el.name:sub(1, #PLANET_PREFIX) == PLANET_PREFIX then
    -- Rebuild the whole allow-list from the live checkboxes (not just this one),
    -- so the pure helper can collapse "all ticked" back to the unrestricted nil.
    local sc = frame[BODY] and frame[BODY][PLANETS_SCROLL]
    local container = sc and sc[PLANETS]
    if container then
      local universe, allowed = {}, {}
      for _, child in ipairs(container.children) do
        if child.name:sub(1, #PLANET_PREFIX) == PLANET_PREFIX then
          local pname = child.name:sub(#PLANET_PREFIX + 1)
          universe[#universe + 1] = pname
          if child.state then
            allowed[pname] = true
          end
        end
      end
      fleet.set_allowed_planets(id, fleet.allowed_from_selection(universe, allowed))
    end
  end
end

-- Collapse/expand toggle: show or hide the controls body. Pure GUI state (the
-- body's visibility), so it lives only on the element -- a re-open starts
-- collapsed again, which keeps the panel slim by default.
function fleet_tab.on_gui_click(event)
  local el = event.element
  local frame = frame_of(el)
  if not (frame and el.name == TOGGLE) then
    return
  end
  local body = frame[BODY]
  if body then
    body.visible = not body.visible
    el.caption = body.visible and { "planet-express.fleet-hide" }
      or { "planet-express.fleet-show" }
  end
end

return fleet_tab
