-- data.lua -- Planet Express prototypes (data stage).
--
-- The "Interplanetary Trade Logistics" technology is the single gate for the
-- whole mod: the Trade tab on the landing pad GUI and per-platform fleet
-- enrollment both check `force.technologies[...].researched`. Task 8 adds the
-- top-bar shortcut that opens the fleet Monitor.

data:extend({
  {
    type = "technology",
    name = "interplanetary-trade-logistics",
    icon = "__planet-express__/graphics/tech.png",
    icon_size = 256,
    -- Marker technology: no recipe/entity unlocks (the mod adds none). The
    -- control stage reads `force.technologies[...].researched` to gate its GUI.
    effects = {},
    -- [provisional] `space-platform` is the canonical Space Age prerequisite
    -- that gates platforms + the cargo landing pad. Confirm the exact internal
    -- name in-engine before publishing. The mid-game "reached a 2nd planet"
    -- requirement is enforced ECONOMICALLY rather than by a brittle planet-
    -- discovery prereq: the cost includes `space-science-pack`, which can only
    -- be produced once the player is operating a space platform in orbit.
    prerequisites = { "space-platform" },
    unit = {
      count = 300,
      ingredients = {
        { "automation-science-pack", 1 },
        { "logistic-science-pack", 1 },
        { "chemical-science-pack", 1 },
        { "space-science-pack", 1 },
      },
      time = 60,
    },
    order = "e-k-z[planet-express]",
  },
  -- Top-bar shortcut that opens/closes the fleet Monitor (Task 8). `small_icon`
  -- is mandatory for shortcuts in 2.0, so we reuse the single 32x32 asset for
  -- both slots. Both *_size fields must be set to 32: they default to 64, which
  -- would make the engine read a 64x64 rect out of the 32x32 png and fail load.
  {
    type = "shortcut",
    name = "planet-express-monitor",
    action = "lua",
    toggleable = true,
    icon = "__planet-express__/graphics/top-bar-icon.png",
    icon_size = 32,
    small_icon = "__planet-express__/graphics/top-bar-icon.png",
    small_icon_size = 32,
    order = "z[planet-express]",
  },
})
