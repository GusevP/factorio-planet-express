-- scripts/gui/monitor.lua
--
-- The fleet-wide monitoring panel. Opened/closed from a top-bar
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
-- Refresh cadence: the dispatcher/watchdog ticks call `monitor.refresh_all()` (a
-- full rebuild, NOT every tick) so the panel updates roughly when trade decisions
-- are made. Between those, a 1s `monitor.refresh_eta()` repaints ONLY the in-flight
-- ETA label captions in place (no rebuild), so the ETA countdown stays smooth.

local state = require("scripts.state")
local viewmodel = require("scripts.viewmodel")
local fleet = require("scripts.fleet")
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
local STRATEGY = "planet-express-monitor-strategy"
-- dropdown index -> stored strategy value (parallel to STRATEGY_CAPTIONS below).
local STRATEGY_VALUES = { state.SOURCE_FASTEST, state.SOURCE_SURPLUS }
local STRATEGY_CAPTIONS = {
  { "planet-express.monitor-strategy-fastest" },
  { "planet-express.monitor-strategy-surplus" },
}
local CLOSE = "planet-express-monitor-close"
local SCROLL = "planet-express-monitor-scroll"
local BODY = "planet-express-monitor-body"
local SHIP_BTN_PREFIX = "planet-express-monitor-ship-"
-- Per-planet collapse toggle in the Waiting section (one per group). The planet
-- name is appended for a unique/greppable element name; the handler reads the raw
-- planet from the button's `tags`, not the name suffix.
local WAITING_TOGGLE_PREFIX = "planet-express-monitor-waiting-toggle-"

-- The always-visible top-left dock: a small `gui.top` panel with a single
-- status button. Folded view only -- its button shows "N working · N idle · N
-- stuck" and clicking it toggles the full centered Monitor (FRAME) above.
local DOCK = "planet-express-monitor-dock"
local DOCK_BTN = "planet-express-monitor-dock-btn"

-- Button caption colors: tinted red when something is stuck (blocked > 0), plain
-- white otherwise. Plain tables (not engine handles) so they cost nothing to hold.
local DOCK_COLOR_STUCK = { r = 1.0, g = 0.55, b = 0.55 }
local DOCK_COLOR_OK = { r = 1.0, g = 1.0, b = 1.0 }

-- The state-filter dropdown options. Index 1 is "any"; the rest map to fleet
-- lifecycle states. STATE_OPTIONS holds the internal VALUES (the filter handler maps
-- selected_index -> value); STATE_CAPTIONS is the parallel LOCALISED dropdown labels,
-- derived 1:1 so they never drift. The `state-<value>` keys are SHARED with the
-- per-ship status label below (idle/enroute/loading/unloading/withdrawn localise the
-- same way in both places).
local STATE_OPTIONS = { "any", fleet.IDLE, fleet.ENROUTE, fleet.LOADING, fleet.UNLOADING, fleet.WITHDRAWN }
local STATE_CAPTIONS = {}
for i = 1, #STATE_OPTIONS do
  STATE_CAPTIONS[i] = { "planet-express.state-" .. STATE_OPTIONS[i] }
end

-- Caption prefix for a live in-flight ETA label. Shared between the full render
-- (below) and the 1s ETA-only refresh (`refresh_eta`) so the in-place repaint
-- produces a byte-identical caption to the full rebuild. The label also carries a
-- `pe_eta_ships` tag (the ship ids behind the ETA) so refresh_eta can find and
-- recompute it without a full gather.
local ETA_CAPTION_PREFIX = "  ·  ETA "

-- ---------------------------------------------------------------------------
-- small render helpers
-- ---------------------------------------------------------------------------

local function reason_caption(reason)
  return { "planet-express.reason-" .. reason }
end

-- Status tint for the expanded Demand lines: delivering = green (on its way),
-- loading = amber (being picked up), waiting = red (nothing on it yet).
local DEMAND_COLOR = {
  delivering = { r = 0.6, g = 1.0, b = 0.6 },
  loading = { r = 1.0, g = 0.85, b = 0.45 },
  waiting = { r = 1.0, g = 0.6, b = 0.6 },
}

-- The collapsed Demand summary: "N delivering · N loading · N waiting", omitting
-- any zero bucket. Each part reuses the bare status word key, prefixed with the
-- count, joined into one LocalisedString.
local function demand_summary_caption(counts)
  local parts = {}
  local function add(n, word_key)
    if n and n > 0 then
      parts[#parts + 1] = { "", tostring(n), " ", { "planet-express." .. word_key } }
    end
  end
  add(counts.delivering, "monitor-demand-delivering")
  add(counts.loading, "monitor-demand-loading")
  add(counts.waiting, "monitor-demand-waiting")
  local cap = { "" }
  for i, p in ipairs(parts) do
    if i > 1 then
      cap[#cap + 1] = "  ·  "
    end
    cap[#cap + 1] = p
  end
  return cap
end

-- Per-player set of EXPANDED waiting planets (collapsed is the compact default).
-- Lives in `storage` because render_body does a full `body.clear()` every refresh,
-- so element-local state would be wiped; storage also survives save/load. Keyed by
-- player_index -> { [planet]=true }. Lazy-init (additive -- no migration). Written
-- only on a toggle click (a per-player, MP-synced input action -> deterministic);
-- read only to decide what THAT player sees, never a game decision.
local function expanded_set(player_index)
  storage.monitor_expanded = storage.monitor_expanded or {}
  local s = storage.monitor_expanded[player_index]
  if not s then
    s = {}
    storage.monitor_expanded[player_index] = s
  end
  return s
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

  -- (The one-line network summary that used to head the body is gone: the
  -- always-visible top-left dock now carries the working/idle/stuck ship counts,
  -- and the Shipments/Waiting/Alerts counts it also showed are just the lengths of
  -- the sections rendered immediately below.)

  -- roster
  add_section_header(body, { "planet-express.monitor-roster" })
  if #view.roster == 0 then
    body.add({ type = "label", caption = { "planet-express.monitor-empty" } })
  else
    -- Two columns: a wide name button (recenters on click) + one info flow reading
    -- "[from] -> [to] · <status> on [planet]". Cargo is intentionally NOT shown for
    -- now (the manifest still rides on the row for the item filter).
    local t = body.add({ type = "table", column_count = 2 })
    for _, r in ipairs(view.roster) do
      -- The fleet key is a force-qualified string ("<force>/<index>"); a "/" is
      -- awkward to round-trip through an element-name suffix, so carry the raw key
      -- in the button's `tags` instead and read it back from there in the click
      -- handler. The element name keeps a stable index-only suffix purely to make
      -- the button greppable/unique within the table; the CAPTION is the ship's
      -- platform name (falling back to "#<id>" when no live handle resolved one).
      local btn = t.add({
        type = "button",
        name = SHIP_BTN_PREFIX .. tostring(r.ship_id),
        caption = r.name or ("#" .. tostring(r.ship_id)),
        tooltip = { "planet-express.monitor-recenter" },
        tags = { pe_ship_key = r.ship_id },
      })
      -- No fixed width: let the button size to the name (min 120) so the name is
      -- always visible; the table column aligns every row to the widest.
      btn.style.minimal_width = 120
      btn.style.horizontal_align = "left"

      local info = t.add({ type = "flow", direction = "horizontal" })
      info.style.vertical_align = "center"
      -- Route boxes only when the ship has a job (idle/stuck ships have no from/to).
      if r.from and r.to then
        common.planet_box(info, r.from)
        info.add({ type = "label", caption = " → " })
        common.planet_box(info, r.to)
        info.add({ type = "label", caption = "  ·  " })
      end
      -- A stranded ship reads "idle"/"enroute" in `r.state` (the watchdog freed or
      -- re-dispatched it), but it is counted as STUCK in the summary -- show "stuck"
      -- here too so the expanded roster agrees with the dock's "N stuck". A "held"
      -- ship (idle + ready-signal gate reading 0) shows "held" so it isn't mistaken
      -- for a missing ship -- ROW-only label (it still counts as idle in the dock).
      local status_caption =
        (r.stranded and { "planet-express.state-stuck" })
        or (r.held and { "planet-express.state-held" })
        or (r.state and { "planet-express.state-" .. r.state })
        or { "planet-express.state-unknown" }
      info.add({ type = "label", caption = status_caption })
      -- "on <planet>" only when the ship is actually parked somewhere (in transit
      -- has no current planet). ONE localised label with the planet as a __1__ param
      -- (planet_caption carries the planet's own icon + localised name), so each
      -- language controls the word order around the planet -- a standalone "on" word
      -- can't (e.g. Japanese/Korean put the particle AFTER the planet).
      if r.location then
        info.add({ type = "label", caption = { "planet-express.state-located", common.planet_caption(r.location) } })
      end
      -- Live ETA for an in-flight ship (gather measured a usable progress-rate);
      -- absent for parked / just-departed ships (rate not yet trustworthy). Tagged
      -- with its ship so refresh_eta repaints the countdown every second.
      if r.eta_ticks then
        info.add({
          type = "label",
          caption = ETA_CAPTION_PREFIX .. viewmodel.format_eta(r.eta_ticks),
          tags = { pe_eta_ships = { r.ship_id } },
        })
      end
    end
  end

  -- (The "Active shipments" section is gone -- the roster shows every in-flight
  -- ship. `view.shipments` is reused below by group_demand to bucket each planet's
  -- inbound cargo by phase.)

  -- demand: per-planet collapsible groups. Collapsed (the compact default) is one
  -- row per planet -- planet box + "N delivering · N loading · N waiting"; expanding
  -- shows a line per item (status · icon+name · ×qty · reason-if-waiting). The
  -- expand state is per-player and persisted (expanded_set), so it survives this
  -- full-rebuild refresh.
  add_section_header(body, { "planet-express.monitor-waiting" })
  local groups = viewmodel.group_demand(view.shipments, view.waiting)
  if #groups == 0 then
    body.add({ type = "label", caption = { "planet-express.monitor-empty" } })
  else
    local expanded = expanded_set(body.player_index)
    for _, g in ipairs(groups) do
      local is_open = expanded[g.planet] == true

      -- header row: collapse toggle + planet box + the collapsed count summary.
      local header = body.add({ type = "flow", direction = "horizontal" })
      header.style.vertical_align = "center"
      local toggle = header.add({
        type = "button",
        name = WAITING_TOGGLE_PREFIX .. tostring(g.planet),
        caption = is_open and "▼" or "▶",
        tooltip = { "planet-express.monitor-waiting-toggle" },
        tags = { pe_waiting_planet = g.planet },
      })
      toggle.style.width = 26
      toggle.style.padding = 0
      common.planet_box(header, g.planet)
      header.add({ type = "label", caption = "  " })
      header.add({ type = "label", caption = demand_summary_caption(g.counts) })

      if is_open then
        -- expanded: one indented line per item -- status · icon+name · ×qty · reason.
        local detail = body.add({ type = "flow", direction = "vertical" })
        detail.style.left_padding = 28
        for _, it in ipairs(g.items) do
          local line = detail.add({ type = "flow", direction = "horizontal" })
          line.style.vertical_align = "center"
          local tag = line.add({ type = "label", caption = { "planet-express.monitor-demand-" .. it.status } })
          tag.style.font_color = DEMAND_COLOR[it.status]
          tag.style.minimal_width = 72
          common.item_box(line, it.item)
          line.add({ type = "label", caption = "  ×" .. tostring(it.qty) })
          -- Loading items: show the provider planet the cargo is picked up at and that
          -- planet's launchable holdings, so an under-supplying source (the bug-2
          -- situation) is visible in the Monitor without running /pe-status. Only
          -- loading rows carry `from`/`avail` (set by group_demand).
          if it.from then
            line.add({ type = "label", caption = "  " })
            line.add({ type = "label", caption = { "planet-express.monitor-demand-from" } })
            line.add({ type = "label", caption = " " })
            common.planet_box(line, it.from)
            if it.avail ~= nil then
              line.add({ type = "label", caption = " " })
              line.add({ type = "label", caption = { "planet-express.monitor-source-avail", it.avail } })
            end
          end
          -- Live ETA on a delivering item (soonest among the ships bringing it);
          -- only present once a ship reports a usable in-flight progress-rate. Tagged
          -- with those ships so refresh_eta recomputes the soonest ETA each second.
          if it.eta_ticks then
            line.add({
              type = "label",
              caption = ETA_CAPTION_PREFIX .. viewmodel.format_eta(it.eta_ticks),
              tags = { pe_eta_ships = it.eta_ships },
            })
          end
          if it.reason then
            line.add({ type = "label", caption = "  ·  " })
            line.add({ type = "label", caption = reason_caption(it.reason) })
          end
        end
      end
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
local function refresh_frame(frame, world)
  -- BODY lives inside the scroll pane; element name-indexing only finds direct
  -- children, so resolve it through the (named) scroll, not straight off frame.
  local scroll = frame[SCROLL]
  local body = scroll and scroll[BODY]
  if not body then
    return
  end
  -- `world` is the shared gather (refresh_all gathers ONCE per tick and threads it
  -- to every open frame + dock); the on-demand open() path passes none, so gather
  -- here. gather is force-independent (it stamps but never filters), so one world
  -- scopes correctly per viewer.
  world = world or viewmodel.gather(game and game.tick or 0)
  local force_key = viewing_force_key(frame)
  local scoped = viewmodel.apply_force_scope(world, force_key)
  local view = viewmodel.build(scoped)
  view = viewmodel.apply_filters(view, read_filters(frame))
  render_body(body, view)
end

-- ---------------------------------------------------------------------------
-- top-left dock (always-visible folded status)
-- ---------------------------------------------------------------------------

-- Build the dock frame (once) in the player's top-left panel stack. The single
-- status button carries the folded summary line; clicking it toggles the full
-- Monitor (handled in on_gui_click). Returns the frame.
local function build_dock(player)
  local frame = player.gui.top.add({ type = "frame", name = DOCK, direction = "horizontal" })
  frame.add({
    type = "button",
    name = DOCK_BTN,
    tooltip = { "planet-express.monitor-dock-tooltip" },
  })
  return frame
end

-- Build-or-update the dock for one player. Gated by the SAME tech as the Monitor:
-- a force without the research has no fleet to monitor, so the dock is torn down
-- (or never built). Otherwise the button caption is refreshed from the pure
-- summary, scoped to this player's force, and tinted when anything is stuck.
local function render_dock(player, world)
  local existing = player.gui.top[DOCK]
  if not fleet.tech_researched(player.force) then
    if existing then
      existing.destroy()
    end
    return
  end
  local frame = existing or build_dock(player)
  local btn = frame[DOCK_BTN]
  world = world or viewmodel.gather(game and game.tick or 0)
  local scoped = viewmodel.apply_force_scope(world, common.force_key(player.force))
  local s = viewmodel.build(scoped).summary
  btn.caption = { "planet-express.monitor-dock-summary", s.ships_active, s.ships_idle, s.ships_stuck }
  btn.style.font_color = (s.ships_stuck > 0) and DOCK_COLOR_STUCK or DOCK_COLOR_OK
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
    items = STATE_CAPTIONS,
    selected_index = 1,
  })
  -- Source-selection strategy for this player's force (persisted per force). Lives in
  -- the filter row but is NOT a filter -- changing it writes the force's dispatch
  -- policy (see on_filter_changed); it takes effect on the next dispatcher tick.
  filters.add({ type = "label", caption = { "planet-express.monitor-strategy-label" } })
  filters.add({
    type = "drop-down",
    name = STRATEGY,
    items = STRATEGY_CAPTIONS,
    selected_index = (state.source_strategy(common.force_key(player.force)) == state.SOURCE_SURPLUS) and 2 or 1,
    tooltip = { "planet-express.monitor-strategy-tip" },
  })

  -- scrollable body.
  local scroll = frame.add({ type = "scroll-pane", name = SCROLL, direction = "vertical" })
  scroll.style.maximal_height = 600
  scroll.style.minimal_width = 480
  scroll.add({ type = "flow", name = BODY, direction = "vertical" })

  refresh_frame(frame)
  player.set_shortcut_toggled(monitor.SHORTCUT, true)
  -- Route the close key (E / Esc) to this frame: with `player.opened` set, the engine
  -- fires on_gui_closed for it, so the Monitor can be dismissed without aiming for the
  -- X. Set LAST, once the frame is fully built. Opening any entity / other window
  -- reassigns player.opened and closes this -- standard single-opened-GUI behavior.
  player.opened = frame
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

-- Refresh the always-visible dock for every player, plus the full panel for every
-- player who has it open. Called on the dispatcher timer (not per tick). The
-- world is gathered ONCE here and threaded into both renders -- gather builds a
-- fresh dispatcher snapshot, so doing it per-player would multiply that work.
function monitor.refresh_all()
  if not game then
    return
  end
  local world = viewmodel.gather(game.tick or 0)
  for _, player in pairs(game.players) do
    render_dock(player, world)
    local frame = frame_of(player)
    if frame then
      refresh_frame(frame, world)
    end
  end
end

-- Recursively repaint every live-ETA label under `element` from its tagged ships'
-- CURRENT progress (the soonest among them), touching nothing else. Cheap: the body
-- holds at most a few dozen rows and each ship's ETA is a couple of live reads, so
-- this is safe to run every second. A label whose ships have all gone quiet
-- (parked / arrived since the last full rebuild) keeps its last caption -- the next
-- full refresh (<=5s) removes the stale row.
local function update_eta_labels(element)
  for _, child in pairs(element.children) do
    local tags = child.tags
    local ships = tags and tags.pe_eta_ships
    if ships then
      local best
      for _, sid in ipairs(ships) do
        local t = viewmodel.live_eta_ticks(sid)
        if t and (not best or t < best) then
          best = t
        end
      end
      if best then
        child.caption = ETA_CAPTION_PREFIX .. viewmodel.format_eta(best)
      end
    else
      update_eta_labels(child)
    end
  end
end

-- Lightweight ETA-only refresh (1s cadence): repaint just the in-flight ETA labels
-- in every open Monitor frame, leaving the rest of the panel (and the dock)
-- untouched. The full refresh_all rebuilds on the >=5s dispatch/watchdog cadence;
-- this fills the gaps so the ETA counts down every second. No gather, no
-- body.clear -- it reads each tagged ship's live progress directly.
function monitor.refresh_eta()
  if not game then
    return
  end
  for _, player in pairs(game.players) do
    local frame = frame_of(player)
    if frame then
      local scroll = frame[SCROLL]
      local body = scroll and scroll[BODY]
      if body then
        update_eta_labels(body)
      end
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

-- The close key (E / Esc) routed through `player.opened` (set in monitor.open). The
-- engine fires on_gui_closed for whatever GUI is open; act ONLY when it is OUR frame
-- (guarded by name + validity) so we never touch another mod's / the native GUI's
-- close. Mirrors monitor.close (destroy + untoggle the shortcut). `monitor.close`
-- destroys the frame, which clears player.opened without re-firing this -- no loop.
function monitor.on_gui_closed(event)
  local element = event.element
  if not (element and element.valid and element.name == FRAME) then
    return
  end
  local player = game.get_player(event.player_index)
  if player then
    monitor.close(player)
  end
end

-- Recenter the player on a ship's platform when its roster button is clicked.
-- Force-gated: only recenter on a ship belonging to the player's OWN force, so a
-- crafted/foreign ship key (or a foreign ship that slipped into a nil-force
-- roster row) can't drag the view onto another force's platform.
local function recenter_on_ship(player, ship_id)
  local entry = fleet.get(ship_id)
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
  -- Top-left dock button: toggles the centered Monitor. It lives in its OWN frame
  -- (gui.top), not the screen FRAME, so handle it BEFORE the FRAME ancestor guard
  -- below (which would otherwise return early and swallow the click). Same trust
  -- check, against the dock frame -- a foreign element copying DOCK_BTN's name in
  -- some other window never finds OUR dock as an ancestor.
  if el.name == DOCK_BTN then
    if common.ancestor_frame(el, DOCK) then
      monitor.toggle(player)
    end
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
    return
  end
  if el.name:sub(1, #WAITING_TOGGLE_PREFIX) == WAITING_TOGGLE_PREFIX then
    -- Flip this planet's collapse state (read the planet from tags, not the name
    -- suffix) and re-render the panel so the group expands/collapses.
    local planet = el.tags and el.tags.pe_waiting_planet
    if planet ~= nil then
      local set = expanded_set(player.index)
      set[planet] = (not set[planet]) or nil -- toggle; clear to keep the set small
      local frame = frame_of(player)
      if frame then
        refresh_frame(frame)
      end
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
  elseif el.name == STRATEGY then
    -- Persist the force's source strategy (the dropdown is a control, not a filter).
    -- Resolve the frame via the element's own ancestry so a same-named widget in
    -- another layout can't drive OUR force's policy (same trust glue as the filters).
    local frame = common.ancestor_frame(el, FRAME)
    if frame then
      state.set_source_strategy(viewing_force_key(frame), STRATEGY_VALUES[el.selected_index])
    end
  end
end

monitor.on_gui_text_changed = on_filter_changed
monitor.on_gui_selection_state_changed = on_filter_changed

return monitor
