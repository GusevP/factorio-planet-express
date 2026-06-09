-- tests/test_list.lua -- in-engine (factorio-test) spec list.
--
-- Loaded by control.lua ONLY when the `factorio-test` mod is present, so normal
-- production loads never touch this file. Empty at 0.0.1: the primary test layer
-- is the pure-Lua `tests/calc_test.lua` (run with plain `lua`). Integration
-- specs that genuinely need the running engine get added here as later tasks
-- introduce behavior that can't be exercised by the calc tests.
--
-- factorio-test expects a list (array) of module paths to require, e.g.:
--   return { "tests.engine.dispatcher_spec" }

return {}
