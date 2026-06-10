-- control.lua -- Planet Express control-stage entry point.
--
-- Wires the engine event seams to the mod's modules: it stands up the
-- determinism/state core, registers the registry's build/mine/surface events,
-- registers the dispatcher + watchdog tick cadences, and routes the GUI events to
-- the Monitor, Trade tab, and Fleet tab.

local state = require("scripts.state")
local registry = require("scripts.registry")
local dispatcher = require("scripts.dispatcher")
local watchdog = require("scripts.watchdog")
local fleet = require("scripts.fleet")
local schedule = require("scripts.schedule")
local monitor = require("scripts.gui.monitor")
local trade_tab = require("scripts.gui.trade_tab")
local fleet_tab = require("scripts.gui.fleet_tab")

-- Initialize persistent state on new game, then seed the registry from the
-- world (a brand-new game has no pads/platforms yet, but this keeps init and
-- configuration-change on the same path).
script.on_init(function()
  state.init()
  registry.rebuild()
end)

-- Keep schema current on mod add/update/remove (runs the real v2 fleet-key
-- migration via state.on_configuration_changed), then rebuild the registry so a
-- save created before the mod gets its existing pads and platforms indexed. The
-- migration MUST run before the rebuild (re-key first, re-add under the new key).
script.on_configuration_changed(function(event)
  state.on_configuration_changed(event)
  registry.rebuild()
end)

-- ---------------------------------------------------------------------------
-- registry event wiring (Task 3)
--
-- The registry is maintained incrementally so the dispatcher never scans all
-- entities. Build/revive events add pads + platform hubs; mine/death events
-- remove them. Filtered to the two prototype names so unrelated entity churn
-- costs nothing. (Verified by manual playtest -- build/scrap a pad and a
-- platform, confirm the index tracks them across save/load.)
-- ---------------------------------------------------------------------------

local registry_entity_filter = {
  { filter = "name", name = registry.PAD_NAME },
  { filter = "name", name = registry.HUB_NAME },
}

local function on_registry_built(event)
  registry.on_entity_built(event.entity)
end

local function on_registry_removed(event)
  registry.on_entity_removed(event.entity)
end

for _, built_event in ipairs({
  defines.events.on_built_entity,
  defines.events.on_robot_built_entity,
  defines.events.on_space_platform_built_entity,
  defines.events.script_raised_built,
  defines.events.script_raised_revive,
}) do
  script.on_event(built_event, on_registry_built, registry_entity_filter)
end

for _, removed_event in ipairs({
  defines.events.on_player_mined_entity,
  defines.events.on_robot_mined_entity,
  defines.events.on_space_platform_mined_entity,
  defines.events.on_entity_died,
  defines.events.script_raised_destroy,
}) do
  script.on_event(removed_event, on_registry_removed, registry_entity_filter)
end

-- A surface (planet) is about to be deleted (Task 6). We hook the PRE event, not
-- on_surface_deleted: by the time the post event fires the stored node.surface
-- handle is already invalid and can't be matched against event.surface_index. In
-- the pre-event the surface is still valid, so the registry can prune every node
-- (and resolvable fleet entry) on it before its pad goes away with the surface.
-- The build_snapshot / stock validity guards remain the primary defense; this
-- just prevents ghosts lingering until the next rebuild.
script.on_event(defines.events.on_pre_surface_deleted, function(event)
  registry.on_pre_surface_deleted(event.surface_index)
end)

-- Dispatch + watchdog cadences (Task 11). The dispatcher runs on its configurable
-- interval (`dispatcher.interval()`); the watchdog runs on its own constant cadence
-- (`watchdog.INTERVAL`). `on_nth_tick` allows only ONE handler per period, so:
--   * when the two periods are EQUAL we register a single shared handler that runs
--     both (dispatcher.run before watchdog.run -- preserve order, co-firing is
--     harmless and deterministic);
--   * when they DIFFER we register two independent handlers -- a dispatch handler
--     and a watchdog handler.
-- `monitor.refresh_all()` runs in EVERY handler: the Monitor must refresh on both
-- dispatch decisions and watchdog state changes, and either cadence can be the
-- faster one (the dispatch-interval setting can be set below watchdog.INTERVAL).
--
-- Determinism: both periods are peer-identical -- watchdog.INTERVAL is a module
-- constant and dispatcher.interval() reads a SYNCED runtime-global setting -- so
-- the registrar computes the same period set on every client and registers
-- identically. (The replicated game state never feeds the registration.)
--
-- The registrar tracks the SET of periods it currently has registered. Before
-- registering the new set it clears every orphaned period (`on_nth_tick(p, nil)`),
-- so the 2->1 transition (dispatch interval changed to equal watchdog.INTERVAL --
-- the old separate dispatch period must stop firing) and the 1->2 transition (they
-- diverge again) never leave a stale period firing. Re-run on
-- init/config-change/load and whenever the dispatch-interval setting changes.
local registered_periods = {} -- set of period -> true currently registered

local function dispatch_only_handler(event)
  dispatcher.run(event.tick)
  monitor.refresh_all()
end

local function watchdog_only_handler(event)
  watchdog.run(event.tick)
  monitor.refresh_all()
end

local function shared_handler(event)
  dispatcher.run(event.tick)
  watchdog.run(event.tick)
  monitor.refresh_all()
end

local function register_ticks()
  local dispatch_period = dispatcher.interval()
  local watchdog_period = watchdog.INTERVAL

  -- Desired period -> handler. When the two periods coincide the set has ONE
  -- period whose handler runs both runs.
  local desired = {}
  if dispatch_period == watchdog_period then
    desired[dispatch_period] = shared_handler
  else
    desired[dispatch_period] = dispatch_only_handler
    desired[watchdog_period] = watchdog_only_handler
  end

  -- Clear orphaned periods (registered last time but not wanted now).
  for period in pairs(registered_periods) do
    if desired[period] == nil then
      script.on_nth_tick(period, nil)
    end
  end

  -- Register the desired set.
  local new_registered = {}
  for period, handler in pairs(desired) do
    script.on_nth_tick(period, handler)
    new_registered[period] = true
  end
  registered_periods = new_registered
end

-- Register on every load so the handlers exist before the first tick, and re-read
-- the dispatch interval whenever its runtime setting changes.
register_ticks()

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
  if event.setting == dispatcher.INTERVAL_SETTING then
    register_ticks()
  end
end)

-- ---------------------------------------------------------------------------
-- GUI wiring (Task 8/9): fleet Monitor + entity-GUI overlays
--
-- The fleet Monitor is a `gui.screen` panel opened from a top-bar shortcut; it
-- re-renders on filter changes and the dispatcher tick. All shaping is in the pure
-- viewmodel; this is just event routing.
--
-- The two entity-GUI overlays are relative-GUI panels anchored to vanilla entity
-- windows, both gated behind the technology:
--   * Trade tab  -- on the Cargo Landing Pad (one pad per planet => per-planet
--     trade node): persists reserve/import-flag/priority/pin edits into
--     storage.nodes; the live readout reuses the pure view-model.
--   * Fleet tab  -- on the Space Platform Hub: the per-platform ENROLLMENT toggle
--     + reserve-for-manual-use, persisted into storage.fleet. This is the only
--     way to enroll a ship, so the dispatcher has a fleet to draw from.
--
-- The shared GUI events fan out to every interested handler (Monitor, Trade tab,
-- Fleet tab); each ignores elements/entities that aren't its own. All verified by
-- manual playtest.
-- ---------------------------------------------------------------------------

script.on_event(defines.events.on_lua_shortcut, monitor.on_shortcut)

script.on_event(defines.events.on_gui_opened, function(event)
  trade_tab.on_gui_opened(event)
  fleet_tab.on_gui_opened(event)
end)

script.on_event(defines.events.on_gui_closed, function(event)
  trade_tab.on_gui_closed(event)
  fleet_tab.on_gui_closed(event)
end)

script.on_event(defines.events.on_gui_checked_state_changed, function(event)
  trade_tab.on_gui_checked_state_changed(event)
  fleet_tab.on_gui_checked_state_changed(event)
end)

script.on_event(defines.events.on_gui_click, function(event)
  monitor.on_gui_click(event)
  trade_tab.on_gui_click(event)
  fleet_tab.on_gui_click(event)
end)

script.on_event(defines.events.on_gui_text_changed, function(event)
  monitor.on_gui_text_changed(event)
  trade_tab.on_gui_text_changed(event)
end)

script.on_event(defines.events.on_gui_selection_state_changed, function(event)
  monitor.on_gui_selection_state_changed(event)
  trade_tab.on_gui_selection_state_changed(event)
end)

-- On-demand diagnostics: `/pe-status` prints the dispatcher's view of the world
-- (settings, trade nodes + open demand, the fleet, in-flight assignments, and why
-- each waiting demand didn't dispatch) straight to the player's console. Works
-- regardless of the debug-log setting -- the reliable way to see mod state when
-- the live decision log appears silent.
commands.add_command("pe-status", "Planet Express: print dispatcher diagnostics", function(cmd)
  local player = cmd.player_index and game.get_player(cmd.player_index)
  local function out(line)
    if player then
      player.print(line)
    else
      game.print(line)
    end
    -- Also write to factorio-current.log so the report can be copied out of the
    -- log file (the in-game console has no text selection / copy).
    if log then
      log(line)
    end
  end
  out("[planet-express] === status ===")
  for _, line in ipairs(dispatcher.diagnose()) do
    out("[planet-express] " .. line)
  end
end)

-- Dev convenience: `/pe-reset` clears every assignment, every ENROLLED ship's mod
-- schedule + hub request, and the alert log, returning the fleet to idle so the
-- next dispatcher tick re-plans every route from a clean slate. Handy while
-- iterating on the mod, where schedules written by an earlier (buggy) build
-- linger across reloads. Only the mod's own state is touched -- un-enrolled
-- (player) ships are left alone. Iteration order is irrelevant (the end state is
-- "all freed + all enrolled ships idle"), so plain `pairs` is fine here.
commands.add_command("pe-reset", "Planet Express: clear all assignments + fleet schedules and re-dispatch fresh (dev)", function(cmd)
  local player = cmd.player_index and game.get_player(cmd.player_index)
  local function out(line)
    if player then player.print(line) else game.print(line) end
  end

  local freed = 0
  if storage.assignments then
    local ids = {}
    for id in pairs(storage.assignments) do
      ids[#ids + 1] = id
    end
    for _, id in ipairs(ids) do
      -- silent free -> clears the hub request + schedule and idles the ship
      watchdog.free_assignment(id, nil, fleet.IDLE, game.tick)
      freed = freed + 1
    end
  end

  local reset = 0
  for _, entry in pairs(storage.fleet or {}) do
    if entry.enrolled == true then
      local platform = entry.platform
      if platform and platform.valid then
        schedule.apply_hub_request(platform, {}, nil) -- clear any stale mod request
        schedule.clear_route(platform)                -- drop the mod route, KEEP interrupts
      end
      entry.assignment = nil
      entry.state = fleet.IDLE
      reset = reset + 1
    end
  end

  storage.alerts = {}
  out(string.format(
    "[planet-express] reset: freed %d assignment(s), idled %d enrolled ship(s). Routes re-plan next dispatch tick.",
    freed, reset))
end)

-- In-engine test hook (factorio-test) -- a PERMANENT STUB SEAM, not a live
-- harness. Dev-only: needs BOTH the framework mod present AND tests/ available.
-- The mod ships no in-engine specs (tests/test_list.lua is an empty stub), and
-- shipped builds strip tests/ (see the package.sh allowlist), so the require
-- fails there and the hook must no-op rather than crash the load -- it can never
-- assume tests/ is packaged. In a dev checkout the (empty) spec list loads only
-- when the optional factorio-test mod is also installed, so it never runs in
-- normal play.
if script.active_mods["factorio-test"] then
  local ok, test_list = pcall(require, "tests.test_list")
  if ok then
    require("__factorio-test__/init")(test_list)
  end
end
