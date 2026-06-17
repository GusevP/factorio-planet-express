-- data.lua -- Planet Express prototypes (data stage).
--
-- The "Interplanetary Trade Logistics" technology is the single gate for the
-- whole mod: the Trade tab on the landing pad GUI and per-platform fleet
-- enrollment both check `force.technologies[...].researched`. It also adds the
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
  -- Top-bar shortcut that opens/closes the fleet Monitor. `small_icon`
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
  -- The single dedicated readiness signal. Players build whatever readiness logic
  -- they like in their own combinators (fuel > N, ammo, asteroid stock, ...) and
  -- emit this signal to the platform hub; the control stage reads it to gate
  -- dispatch when a ship's "Hold until ready signal" toggle is on. `icon_size`
  -- MUST be 32 to match the placeholder png (defaults to 64 -> reads a 64x64 rect
  -- out of the 32x32 asset and fails load; same gotcha as the shortcut above).
  -- Swap to 64x64 art later and bump `icon_size` to 64.
  {
    type = "virtual-signal",
    name = "planet-express-ready",
    icon = "__planet-express__/graphics/signal-icon.png",
    icon_size = 32,
    subgroup = "virtual-signal",
    order = "z[planet-express]",
  },
})

-- Tips and Tricks entries (data stage): a small in-game guide to the mod, shown in
-- the vanilla Tips and Tricks window. Text-only (no simulation); every entry starts
-- "unlocked" so the whole guide is browsable at any time without firing popups. The
-- control stage never touches these -- they are static data. Names/descriptions live
-- under the [tips-and-tricks-item-*] locale sections.
local TIP_ICON = "__planet-express__/graphics/tech.png"

local function tip(name, order, indent, is_title)
  return {
    type = "tips-and-tricks-item",
    name = name,
    category = "planet-express",
    order = order,
    indent = indent,
    is_title = is_title or nil, -- false -> omit (default)
    starting_status = "unlocked",
    icon = TIP_ICON,
    icon_size = 256,
  }
end

data:extend({
  { type = "tips-and-tricks-item-category", name = "planet-express", order = "z[planet-express]" },
  tip("planet-express", "a", 0, true), -- category title (overview)
  tip("planet-express-research", "b", 1),
  tip("planet-express-enroll", "c", 1),
  tip("planet-express-trade", "d", 1),
  tip("planet-express-monitor", "e", 1),
  tip("planet-express-stuck", "f", 1),
  tip("planet-express-ready-signal", "g", 1),
})
