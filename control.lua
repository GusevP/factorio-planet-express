-- control.lua -- Planet Express control-stage entry point.
--
-- Wires the engine event seams to the mod's modules. At 0.0.1 this only stands
-- up the determinism/state core and registers a no-op dispatcher tick; later
-- tasks (dispatcher, watchdog, GUIs) hook in here.

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

-- Keep schema current on mod add/update/remove (migration stub at 0.0.1), then
-- rebuild the registry so a save created before the mod (or before Task 3) gets
-- its existing pads and platforms indexed.
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

-- Dispatcher heartbeat (Task 5/6/10): on each tick of the configurable interval,
-- match open demand to above-reserve supply, run the watchdog, and refresh the
-- Monitor. The dispatcher and watchdog share one handler (firing on the same tick
-- is harmless -- deterministic order -- and `on_nth_tick` allows only one handler
-- per period, so they MUST share when their periods coincide).
--
-- The interval is a runtime-global setting (Task 10). `on_nth_tick` is keyed by
-- period, so changing the interval means unregistering the old period and
-- registering the new one; `register_dispatch_tick` does exactly that and is
-- called on init/config-change/load and whenever the setting changes. The setting
-- is synced across peers, so every client registers the same period
-- (determinism).
local current_dispatch_interval = nil

local function dispatch_heartbeat(event)
  dispatcher.run(event.tick)
  watchdog.run(event.tick)
  monitor.refresh_all()
end

local function register_dispatch_tick()
  local iv = dispatcher.interval()
  if iv == current_dispatch_interval then
    return
  end
  if current_dispatch_interval ~= nil then
    script.on_nth_tick(current_dispatch_interval, nil)
  end
  current_dispatch_interval = iv
  script.on_nth_tick(iv, dispatch_heartbeat)
end

-- Register on every load so the handler exists before the first tick, and re-read
-- the interval whenever a runtime setting changes.
register_dispatch_tick()

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
  if event.setting == dispatcher.INTERVAL_SETTING then
    register_dispatch_tick()
  end
end)

-- ---------------------------------------------------------------------------
-- fleet Monitor GUI wiring (Task 8)
--
-- The panel opens from a top-bar shortcut and re-renders on filter changes and
-- the dispatcher tick. All shaping is in the pure viewmodel; this is just event
-- routing. Verified by manual playtest.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Entity-GUI overlays: Trade tab (Task 9) + Fleet tab
--
-- Two relative-GUI overlays anchored to vanilla entity windows, both gated behind
-- the technology and both verified by manual playtest:
--   * Trade tab  -- on the Cargo Landing Pad (one pad per planet => per-planet
--     trade node): persists reserve/import-flag/priority edits into storage.nodes;
--     the live readout reuses the pure view-model.
--   * Fleet tab  -- on the Space Platform Hub: the per-platform ENROLLMENT toggle
--     + reserve-for-manual-use, persisted into storage.fleet. This is the only
--     way to enroll a ship, so the dispatcher has a fleet to draw from.
--
-- The shared GUI events fan out to every interested handler (Monitor, Trade tab,
-- Fleet tab); each ignores elements/entities that aren't its own.
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

script.on_event(defines.events.on_gui_selection_state_changed, monitor.on_gui_selection_state_changed)

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

-- In-engine test hook (factorio-test). Dev-only: needs BOTH the framework mod
-- present AND tests/ available. Shipped builds strip tests/ (see the package.sh
-- allowlist), so the require fails there and the hook must no-op rather than
-- crash the load -- it can never assume tests/ is packaged. In a dev checkout
-- the folder has tests/, so the spec list (which grows as later tasks add
-- integration specs) loads and runs.
if script.active_mods["factorio-test"] then
  local ok, test_list = pcall(require, "tests.test_list")
  if ok then
    require("__factorio-test__/init")(test_list)
  end
end
