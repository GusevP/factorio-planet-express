-- settings.lua -- Planet Express runtime-global settings (data stage).
--
-- All tunables are `runtime-global` so they are synced across multiplayer peers
-- (determinism) and can be changed mid-game. Each consumer reads its setting
-- through a guarded accessor with a module-level fallback, so the pure-calc test
-- runner (which has no `settings` global) still loads the modules cleanly.
--
-- Consumers:
--   planet-express-debug-log        -> scripts/state.lua   (debug_log gate)
--   planet-express-dispatch-interval-> scripts/dispatcher.lua + control.lua
--   planet-express-min-trip         -> scripts/stock.lua    (min-trip suppression)
--   planet-express-default-reserve  -> scripts/registry.lua (new-node default floor)
--   planet-express-max-ships-global -> scripts/dispatcher.lua (global concurrency cap)
--   planet-express-max-ships-route  -> scripts/dispatcher.lua (per-route concurrency cap)
--   planet-express-two-way-return   -> scripts/dispatcher.lua (return-leg gate)
--   planet-express-min-load         -> scripts/dispatcher.lua (two-pass min-load gate)
--
-- `0` means "unlimited" for both max-ships caps.
-- `planet-express-min-load` is a percent (0-100); `0` disables the gate (ship any load).

data:extend({
  {
    type = "bool-setting",
    name = "planet-express-debug-log",
    setting_type = "runtime-global",
    default_value = false,
    order = "z-debug",
  },
  {
    type = "int-setting",
    name = "planet-express-dispatch-interval",
    setting_type = "runtime-global",
    default_value = 300,
    minimum_value = 60,
    maximum_value = 36000,
    order = "a-interval",
  },
  {
    type = "int-setting",
    name = "planet-express-min-trip",
    setting_type = "runtime-global",
    default_value = 1,
    minimum_value = 1,
    maximum_value = 1000000,
    order = "b-min-trip",
  },
  {
    type = "int-setting",
    name = "planet-express-default-reserve",
    setting_type = "runtime-global",
    default_value = 0,
    minimum_value = 0,
    maximum_value = 1000000,
    order = "c-default-reserve",
  },
  {
    type = "int-setting",
    name = "planet-express-max-ships-global",
    setting_type = "runtime-global",
    default_value = 0,
    minimum_value = 0,
    maximum_value = 10000,
    order = "d-max-ships-global",
  },
  {
    type = "int-setting",
    name = "planet-express-max-ships-route",
    setting_type = "runtime-global",
    default_value = 5,
    minimum_value = 0,
    maximum_value = 10000,
    order = "e-max-ships-route",
  },
  {
    type = "bool-setting",
    name = "planet-express-two-way-return",
    setting_type = "runtime-global",
    default_value = true,
    order = "f-two-way-return",
  },
  {
    type = "int-setting",
    name = "planet-express-min-load",
    setting_type = "runtime-global",
    default_value = 80,
    minimum_value = 0,
    maximum_value = 100,
    order = "g-min-load",
  },
})
