-- scripts/gui/monitor.lua
--
-- The fleet-wide monitoring panel (Task 8). Opened/closed from a top-bar
-- shortcut; shows the roster, active shipments, waiting demand (with the reason
-- it is stuck), alerts, and a one-line network summary. Lightweight filters
-- (planet / item / state) narrow the lists; clicking a ship recenters the view
-- on its platform.
--
-- This module is INTENTIONALLY dumb: it renders a view model and routes events.
-- ALL shaping logic lives in the pure `scripts/viewmodel.lua` (unit-tested). The
-- rendering / event wiring here is engine-touching and is verified by MANUAL
-- PLAYTEST (open it populated + empty, exercise the filters, click a ship).
--
-- Refresh cadence: the dispatcher tick calls `monitor.refresh_all()` (NOT every
-- tick) so the panel updates roughly when trade decisions are made.

local viewmodel = require("scripts.viewmodel")
local fleet = require("scripts.fleet")
local registry = require("scripts.registry")
local qkey = require("scripts.qkey")
local common = require("scripts.gui.common")

local monitor = {}

-- Element + shortcut names. Kept greppable and collision-proof under the mod
-- namespace.
monitor.SHORTCUT = "planet-express-monitor"
local FRAME = "planet-express-monitor-frame"
local FILTERS = "planet-express-monitor-filters"
local FILTER_PLANET = "planet-express-monitor-filter-planet"
local FILTER_ITEM = "planet-express-monitor-filter-item"
local FILTER_STATE = "planet-express-monitor-filter-state"
local CLOSE = "planet-express-monitor-close"
local SCROLL = "planet-express-monitor-scroll"
local BODY = "planet-express-monitor-body"
local SHIP_BTN_PREFIX = "planet-express-monitor-ship-"

-- The state-filter dropdown options. Index 1 is "any"; the rest map to fleet
-- lifecycle states. Kept in one place so the dropdown and the lookup agree.
local STATE_OPTIONS = { "any", fleet.IDLE, fleet.ENROUTE, fleet.LOADING, fleet.UNLOADING, fleet.WITHDRAWN }

-- ---------------------------------------------------------------------------
-- small render helpers
-- ---------------------------------------------------------------------------

-- Render a manifest table { [qkey]=qty } as a short stable string. Each cargo
-- key is a compound `qkey(item, quality)`; `qkey.label` decodes it for display so
-- the panel shows "iron-plate x50" (or "iron-plate (uncommon) x50"), never the
-- raw "iron-plate@normal x50". Sorted by qkey for a stable, deterministic order.
local function manifest_caption(manifest)
  if not manifest then
    return "-"
  end
  local parts = {}
  -- Stable order: sort the keys.
  local keys = {}
  for k in pairs(manifest) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  for _, k in ipairs(keys) do
    parts[#parts + 1] = qkey.label(k) .. " x" .. tostring(manifest[k])
  end
  if #parts == 0 then
    return "-"
  end
  return table.concat(parts, ", ")
end

local function reason_caption(reason)
  return { "planet-express.reason-" .. reason }
end

-- ---------------------------------------------------------------------------
-- filter reading
-- ---------------------------------------------------------------------------

-- Read the current filter values straight off the frame's filter widgets, so no
-- separate per-player state needs persisting.
local function read_filters(frame)
  -- The filter widgets live inside the (named) filters flow; element
  -- name-indexing only finds direct children, so resolve them through the flow,
  -- not straight off the frame (same limitation handled for BODY via SCROLL).
  local filters = frame[FILTERS]
  local planet_el = filters and filters[FILTER_PLANET]
  local item_el = filters and filters[FILTER_ITEM]
  local state_el = filters and filters[FILTER_STATE]
  local fstate = nil
  if state_el and state_el.selected_index and state_el.selected_index > 1 then
    fstate = STATE_OPTIONS[state_el.selected_index]
  end
  return {
    planet = planet_el and planet_el.text or nil,
    item = item_el and item_el.text or nil,
    state = fstate,
  }
end

-- ---------------------------------------------------------------------------
-- body rendering
-- ---------------------------------------------------------------------------

local function add_section_header(parent, caption)
  local lbl = parent.add({ type = "label", caption = caption })
  lbl.style.font = "default-bold"
  lbl.style.top_padding = 6
end

local function render_body(body, view)
  body.clear()

  -- one-line network summary
  local s = view.summary
  body.add({
    type = "label",
    caption = {
      "planet-express.monitor-summary",
      s.ships_total, s.ships_idle, s.ships_active, s.shipments, s.waiting, s.alerts,
    },
  })

  -- roster
  add_section_header(body, { "planet-express.monitor-roster" })
  if #view.roster == 0 then
    body.add({ type = "label", caption = { "planet-express.monitor-empty" } })
  else
    local t = body.add({ type = "table", column_count = 4 })
    for _, r in ipairs(view.roster) do
      -- The fleet key is a force-qualified string ("<force>/<index>"); a "/" is
      -- awkward to round-trip through an element-name suffix, so carry the raw key
      -- in the button's `tags` instead and read it back from there in the click
      -- handler. The name keeps a stable index-only suffix purely to make the
      -- button greppable/unique within the table.
      local btn = t.add({
        type = "button",
        name = SHIP_BTN_PREFIX .. tostring(r.ship_id),
        caption = "#" .. tostring(r.ship_id),
        tooltip = { "planet-express.monitor-recenter" },
        tags = { pe_ship_key = r.ship_id },
      })
      btn.style.width = 60
      t.add({ type = "label", caption = r.state or "-" })
      t.add({
        type = "label",
        caption = (r.from and r.to) and (tostring(r.from) .. " -> " .. tostring(r.to)) or "-",
      })
      t.add({ type = "label", caption = manifest_caption(r.manifest) })
    end
  end

  -- active shipments
  add_section_header(body, { "planet-express.monitor-shipments" })
  if #view.shipments == 0 then
    body.add({ type = "label", caption = { "planet-express.monitor-empty" } })
  else
    -- ship / route / phase / manifest. The phase column renders the assignment's
    -- live lifecycle state (enroute / loading / unloading), derived by the watchdog
    -- and threaded through viewmodel.gather/build. No header row on this table, so
    -- the raw state string is rendered inline (no locale key needed).
    local t = body.add({ type = "table", column_count = 4 })
    for _, sh in ipairs(view.shipments) do
      t.add({ type = "label", caption = "#" .. tostring(sh.ship_id) })
      t.add({
        type = "label",
        caption = tostring(sh.from) .. " -> " .. tostring(sh.to),
      })
      t.add({ type = "label", caption = sh.phase or "-" })
      local m = manifest_caption(sh.manifest)
      if sh.return_manifest and next(sh.return_manifest) then
        m = m .. "  (return: " .. manifest_caption(sh.return_manifest) .. ")"
      end
      t.add({ type = "label", caption = m })
    end
  end

  -- waiting demand (+ reason)
  add_section_header(body, { "planet-express.monitor-waiting" })
  if #view.waiting == 0 then
    body.add({ type = "label", caption = { "planet-express.monitor-empty" } })
  else
    local t = body.add({ type = "table", column_count = 4 })
    for _, w in ipairs(view.waiting) do
      t.add({ type = "label", caption = tostring(w.dest_planet) })
      -- `w.item` is a cargo qkey; decode it for display (see manifest_caption).
      t.add({ type = "label", caption = qkey.label(w.item) })
      t.add({ type = "label", caption = "x" .. tostring(w.unmet) })
      t.add({ type = "label", caption = reason_caption(w.reason) })
    end
  end

  -- alerts (newest first)
  add_section_header(body, { "planet-express.monitor-alerts" })
  if #view.alerts == 0 then
    body.add({ type = "label", caption = { "planet-express.monitor-empty" } })
  else
    for _, al in ipairs(view.alerts) do
      local detail = al.detail or {}
      body.add({
        type = "label",
        caption = string.format(
          "[%s] a#%s %s -> %s",
          tostring(al.kind), tostring(al.assignment),
          tostring(detail.source or "?"), tostring(detail.dest or "?")),
      })
    end
  end
end

-- The force key of the player a (gui.screen) Monitor frame belongs to. Every
-- screen frame carries the `player_index` that created it, so the viewing force
-- is resolvable without per-player state -- it scopes the panel to that force.
local function viewing_force_key(frame)
  local player = frame.player_index and game and game.get_player(frame.player_index)
  return player and common.force_key(player.force) or nil
end

-- Rebuild the body of an already-open frame from the live world, honoring the
-- frame's current filters. The world is gathered, then SCOPED to the viewing
-- player's force (gather stamps a `force` on every row; apply_force_scope keeps
-- only this force's rows plus pre-existing nil-force rows) BEFORE the pure build,
-- so the panel only ever shows this force's ships / shipments / waiting / alerts.
local function refresh_frame(frame)
  -- BODY lives inside the scroll pane; element name-indexing only finds direct
  -- children, so resolve it through the (named) scroll, not straight off frame.
  local scroll = frame[SCROLL]
  local body = scroll and scroll[BODY]
  if not body then
    return
  end
  local tick = game and game.tick or 0
  local force_key = viewing_force_key(frame)
  local world = viewmodel.apply_force_scope(viewmodel.gather(tick, force_key), force_key)
  local view = viewmodel.build(world)
  view = viewmodel.apply_filters(view, read_filters(frame))
  render_body(body, view)
end

-- ---------------------------------------------------------------------------
-- open / close / toggle
-- ---------------------------------------------------------------------------

local function frame_of(player)
  return player.gui.screen[FRAME]
end

function monitor.open(player)
  -- Same tech gate as both tabs: the Monitor is part of the interplanetary-trade
  -- feature, so it only opens once the force has researched it. (A player whose
  -- force lacks the tech sees nothing useful -- no enrolled fleet, no nodes.)
  if not fleet.tech_researched(player.force) then
    return
  end
  if frame_of(player) then
    refresh_frame(frame_of(player))
    return
  end

  local frame = player.gui.screen.add({
    type = "frame",
    name = FRAME,
    direction = "vertical",
  })
  frame.auto_center = true

  -- title bar with a draggable handle and a close button.
  local titlebar = frame.add({ type = "flow", direction = "horizontal" })
  titlebar.drag_target = frame
  local title = titlebar.add({
    type = "label",
    caption = { "planet-express.monitor-title" },
    style = "frame_title",
  })
  title.drag_target = frame
  local filler = titlebar.add({ type = "empty-widget", style = "draggable_space_header" })
  filler.style.horizontally_stretchable = true
  filler.style.height = 24
  filler.drag_target = frame
  titlebar.add({
    type = "sprite-button",
    name = CLOSE,
    sprite = "utility/close",
    style = "frame_action_button",
    tooltip = { "gui.close" },
  })

  -- filter row.
  local filters = frame.add({ type = "flow", name = FILTERS, direction = "horizontal" })
  filters.add({ type = "label", caption = { "planet-express.monitor-filter-planet" } })
  filters.add({ type = "textfield", name = FILTER_PLANET })
  filters.add({ type = "label", caption = { "planet-express.monitor-filter-item" } })
  filters.add({ type = "textfield", name = FILTER_ITEM })
  filters.add({ type = "label", caption = { "planet-express.monitor-filter-state" } })
  filters.add({
    type = "drop-down",
    name = FILTER_STATE,
    items = { "any", fleet.IDLE, fleet.ENROUTE, fleet.LOADING, fleet.UNLOADING, fleet.WITHDRAWN },
    selected_index = 1,
  })

  -- scrollable body.
  local scroll = frame.add({ type = "scroll-pane", name = SCROLL, direction = "vertical" })
  scroll.style.maximal_height = 600
  scroll.style.minimal_width = 480
  scroll.add({ type = "flow", name = BODY, direction = "vertical" })

  refresh_frame(frame)
  player.set_shortcut_toggled(monitor.SHORTCUT, true)
end

function monitor.close(player)
  local frame = frame_of(player)
  if frame then
    frame.destroy()
  end
  player.set_shortcut_toggled(monitor.SHORTCUT, false)
end

function monitor.toggle(player)
  if frame_of(player) then
    monitor.close(player)
  else
    monitor.open(player)
  end
end

-- Refresh the panel for every player who has it open. Called on the dispatcher
-- timer (not per tick).
function monitor.refresh_all()
  if not game then
    return
  end
  for _, player in pairs(game.players) do
    local frame = frame_of(player)
    if frame then
      refresh_frame(frame)
    end
  end
end

-- ---------------------------------------------------------------------------
-- event handlers (registered from control.lua)
-- ---------------------------------------------------------------------------

function monitor.on_shortcut(event)
  if event.prototype_name ~= monitor.SHORTCUT then
    return
  end
  local player = game.get_player(event.player_index)
  if player then
    monitor.toggle(player)
  end
end

-- Recenter the player on a ship's platform when its roster button is clicked.
-- Force-gated: only recenter on a ship belonging to the player's OWN force, so a
-- crafted/foreign ship key (or a foreign ship that slipped into a nil-force
-- roster row) can't drag the view onto another force's platform.
local function recenter_on_ship(player, ship_id)
  local entry = registry and fleet.get(ship_id)
  if not entry then
    return
  end
  if common.force_key(player.force) ~= entry.force then
    return
  end
  local platform = entry.platform
  local hub = platform and platform.valid and platform.hub
  if hub and hub.valid then
    -- Remote View centered on the hub entity (2.0 replaced LuaPlayer.zoom_to_world
    -- with this). Centering on the entity rather than a static position keeps the
    -- view tracking the platform as it travels between planets.
    player.centered_on = hub
  elseif platform and platform.valid and platform.surface then
    player.set_controller({ type = defines.controllers.remote, surface = platform.surface })
  end
end

function monitor.on_gui_click(event)
  local el = event.element
  if not (el and el.valid) then
    return
  end
  local player = game.get_player(event.player_index)
  if not player then
    return
  end
  -- The Monitor is a `gui.screen` frame fetched BY NAME elsewhere; an event
  -- element's name is attacker-controlled, so before acting on a click verify the
  -- element actually descends from OUR frame (a foreign element merely COPYING
  -- our CLOSE / ship-button name otherwise drives our handler).
  if not common.ancestor_frame(el, FRAME) then
    return
  end
  if el.name == CLOSE then
    monitor.close(player)
    return
  end
  if el.name:sub(1, #SHIP_BTN_PREFIX) == SHIP_BTN_PREFIX then
    -- Fleet keys are force-qualified strings now (not numeric), so read the raw
    -- key from the button's tags rather than parsing it out of the name suffix.
    local ship_key = el.tags and el.tags.pe_ship_key
    if ship_key ~= nil then
      recenter_on_ship(player, ship_key)
    end
  end
end

-- Re-render on any filter change (text or dropdown). Resolve the frame by walking
-- the element's OWN ancestry (not a fixed `el.parent.parent` hop, which a foreign
-- element of the same name in a different layout could spoof): a copied-name
-- filter widget elsewhere never finds OUR frame as an ancestor, so it can't drive
-- a refresh of our panel.
local function on_filter_changed(event)
  local el = event.element
  if not (el and el.valid) then
    return
  end
  if el.name == FILTER_PLANET or el.name == FILTER_ITEM or el.name == FILTER_STATE then
    local frame = common.ancestor_frame(el, FRAME)
    if frame then
      refresh_frame(frame)
    end
  end
end

monitor.on_gui_text_changed = on_filter_changed
monitor.on_gui_selection_state_changed = on_filter_changed

return monitor
