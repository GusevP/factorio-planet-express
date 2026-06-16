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
local monitor = require("scripts.gui.monitor")
local trade_tab = require("scripts.gui.trade_tab")
local fleet_tab = require("scripts.gui.fleet_tab")

-- Initialize persistent state on new game, then seed the registry from the
-- world (a brand-new game has no pads/platforms yet, but this keeps init and
-- configuration-change on the same path).
script.on_init(function()
  state.init()
  registry.rebuild()
  dispatcher.build_distances()
end)

-- The inter-planet distance map (v1.1 ETA dispatch) is derived static prototype
-- data, NOT `storage` -- so it lives in a module cache that must be reconstructed
-- every time the control stage loads (a fresh load gets no `on_init`). `prototypes`
-- is readable in `on_load`, and the build is a pure read (no `storage` write,
-- determinism-safe).
script.on_load(function()
  dispatcher.build_distances()
end)

-- Keep schema current on mod add/update/remove (runs the real v2 fleet-key
-- migration via state.on_configuration_changed), then rebuild the registry so a
-- save created before the mod gets its existing pads and platforms indexed. The
-- migration MUST run before the rebuild (re-key first, re-add under the new key).
script.on_configuration_changed(function(event)
  state.on_configuration_changed(event)
  registry.rebuild()
  dispatcher.build_distances()
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

-- A space platform was created or changed state. The build events above do NOT
-- fire for the INITIAL hub of a freshly-created platform: on_space_platform_built_entity
-- covers entities a platform's own construction robots build, not the starter-pack
-- hub the engine spawns. So a brand-new platform stayed invisible to the registry
-- until the next registry.rebuild() (on_init / on_configuration_changed) -- which is
-- exactly why a player could only enroll a new platform after updating/reinstalling
-- the mod (that fires on_configuration_changed -> rebuild). on_space_platform_changed_state
-- carries `event.platform` and fires once the platform exists with its hub set, so
-- it is the reliable "a platform appeared" signal. registry.add_platform is idempotent
-- (guards valid/index and just refreshes an existing entry's live handle), so firing
-- it on every state change is safe and cheap.
script.on_event(defines.events.on_space_platform_changed_state, function(event)
  registry.add_platform(event.platform)
end)

-- Dispatch + watchdog + Monitor-ETA cadences (Task 11; ETA cadence is v1.3). Three
-- periods drive the on_nth_tick handlers:
--   * dispatch  -- `dispatcher.run` on its configurable interval (`dispatcher.interval()`)
--   * watchdog  -- `watchdog.run` on its own constant cadence (`watchdog.INTERVAL`, 5s)
--   * eta       -- the Monitor's 1s ETA-only refresh (`ETA_REFRESH_INTERVAL`)
-- `on_nth_tick` allows only ONE handler per period, so the registrar builds the SET
-- of distinct periods and gives each a single handler that runs every job that
-- period owns (e.g. when dispatch == watchdog one handler runs both; when the ETA
-- cadence divides a heavier one they still register as separate periods and both
-- fire on the shared tick, which is harmless).
--
-- Monitor refresh: a period that runs dispatcher or watchdog does a FULL
-- `monitor.refresh_all()` (it rebuilds the panel, which already repaints ETA);
-- a period that is ONLY the ETA cadence does the cheap in-place `monitor.refresh_eta()`
-- so the in-flight ETA counts down every second between full rebuilds.
--
-- Determinism: all three periods are peer-identical -- watchdog.INTERVAL and
-- ETA_REFRESH_INTERVAL are module constants and dispatcher.interval() reads a SYNCED
-- runtime-global setting -- so the registrar computes the same period set on every
-- client and registers identically. (The replicated game state never feeds the
-- registration; the Monitor refreshes are per-player GUI side effects, not game state.)
--
-- The registrar tracks the SET of periods it currently has registered. Before
-- registering the new set it clears every orphaned period (`on_nth_tick(p, nil)`),
-- so a dispatch-interval change that collapses or splits the period set never
-- leaves a stale period firing. Re-run on init/config-change/load and whenever the
-- dispatch-interval setting changes.
local registered_periods = {} -- set of period -> true currently registered

-- Monitor ETA-only refresh cadence: 1s at 60 UPS. A module constant (peer-identical,
-- like watchdog.INTERVAL) so the registrar's period set stays deterministic.
local ETA_REFRESH_INTERVAL = 60

-- The single on_nth_tick handler for `period`, given the current dispatch/watchdog
-- periods. It runs whichever heavy jobs this period owns, then refreshes the
-- Monitor: a full rebuild if anything heavy fired, otherwise the cheap ETA-only
-- pass when this is (solely) the ETA cadence.
local function handler_for(period, dispatch_period, watchdog_period)
  local runs_dispatch = (period == dispatch_period)
  local runs_watchdog = (period == watchdog_period)
  local runs_eta = (period == ETA_REFRESH_INTERVAL)
  return function(event)
    if runs_dispatch then
      dispatcher.run(event.tick)
    end
    if runs_watchdog then
      watchdog.run(event.tick)
    end
    if runs_dispatch or runs_watchdog then
      monitor.refresh_all()
    elseif runs_eta then
      monitor.refresh_eta()
    end
  end
end

local function register_ticks()
  local dispatch_period = dispatcher.interval()
  local watchdog_period = watchdog.INTERVAL

  -- The distinct periods we must fire on. Duplicates collapse (e.g. dispatch ==
  -- watchdog, or dispatch == ETA cadence) so each period gets exactly one handler.
  local desired = {}
  for _, period in ipairs({ dispatch_period, watchdog_period, ETA_REFRESH_INTERVAL }) do
    if desired[period] == nil then
      desired[period] = handler_for(period, dispatch_period, watchdog_period)
    end
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

-- The Monitor's top-left dock is always visible once a force has the trade tech.
-- refresh_all (the dispatcher cadence) builds/updates every player's dock, but
-- that leaves a one-interval gap for a fresh join or a just-finished research, so
-- nudge it immediately on both. on_research_finished is filtered to the gating
-- tech -- the dock appears the instant the player unlocks the feature, and
-- unrelated research never triggers a needless snapshot.
script.on_event(defines.events.on_player_created, function()
  monitor.refresh_all()
end)

script.on_event(defines.events.on_research_finished, function(event)
  if event.research and event.research.name == fleet.TECH then
    monitor.refresh_all()
  end
end)

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
