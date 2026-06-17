-- scripts/gui/common.lua
--
-- Tiny shared helpers for the three GUI modules (Trade tab, Fleet tab, Monitor).
-- Both helpers are about TRUST: an event element's name is attacker-controlled
-- (any mod / script can `add` an element with our exact name into its own GUI),
-- so before an event handler writes to OUR storage off the element it must prove
-- the element really descends from one of OUR frames -- not a foreign element
-- that merely COPIES our element name.
--
-- Besides that trust glue it also hosts the shared `planet_box` RENDER component
-- (so every GUI labels a planet identically). That reads `game.planets` -- but
-- only when CALLED, never at module load -- so the module still `require`s cleanly
-- under plain `lua`. It holds no DECISION/shaping logic (that stays in the pure
-- viewmodel); the planet box is pure view.

local qkey = require("scripts.qkey")

local common = {}

-- ---------------------------------------------------------------------------
-- shared render component: the "planet box"
-- ---------------------------------------------------------------------------

-- A planet's icon + localised name as a LocalisedString: `<icon> <Name>` (falling
-- back to the raw internal name, then a dash). `name` is the internal
-- planet/space-location name (the dispatcher's route key).
-- `game.planets[name].prototype.localised_name` is the display name (api-notes §5,
-- confirmed); `[planet=<name>]` is the icon (rich text, provisional). Local so the
-- caption shaping stays in one place.
local function planet_caption(name)
  if name == nil then
    return "—"
  end
  local planet = game and game.planets and game.planets[name]
  local nice = planet and planet.prototype and planet.prototype.localised_name
  return { "", "[planet=" .. name .. "] ", nice or name }
end

-- Reusable "planet box" component: one element showing a planet's icon + name, so
-- every GUI that references a planet (Monitor roster / shipments / waiting, the
-- Trade & Fleet tabs, ...) renders it the SAME way -- change it here, change it
-- everywhere. Adds the box to `parent` and returns the element. A nil / unknown
-- `name` degrades to a plain dash, so callers never special-case a missing planet.
function common.planet_box(parent, name)
  return parent.add({ type = "label", caption = planet_caption(name) })
end

-- ---------------------------------------------------------------------------
-- shared render component: items (icon + name)
-- ---------------------------------------------------------------------------

-- The rich-text item icon tag for a cargo `key` (a compound `qkey(item, quality)`):
-- "[item=iron-plate]" (normal) or "[item=iron-plate,quality=uncommon]". Local, so
-- both item renderers below build the tag the same way. [provisional rich-text tag]
local function item_tag(name, quality)
  if quality == nil or quality == qkey.DEFAULT_QUALITY then
    return "[item=" .. name .. "]"
  end
  return "[item=" .. name .. ",quality=" .. quality .. "]"
end

-- A planet's item-box sibling: one element showing an item's icon + localised name
-- (with the quality parenthesised when not normal), for the line-per-item views
-- (Monitor waiting detail, future cargo views). `key` is the compound qkey;
-- `prototypes.item[name].localised_name` is the display name (2.0 `prototypes`),
-- falling back to the raw name. Adds the box to `parent` and returns it.
function common.item_box(parent, key)
  local name, quality = qkey.qparse(key)
  local proto = prototypes and prototypes.item and prototypes.item[name]
  local nice = proto and proto.localised_name or name
  local caption
  if quality ~= qkey.DEFAULT_QUALITY then
    caption = { "", item_tag(name, quality) .. " ", nice, " (", quality, ")" }
  else
    caption = { "", item_tag(name, quality) .. " ", nice }
  end
  return parent.add({ type = "label", caption = caption })
end

-- Walk `el`'s ancestry upward and return the first ancestor (or `el` itself)
-- whose `.name` equals `frame_name`, else nil. Defeats a foreign element that
-- merely copies one of our element names: the engine ties an element's parent
-- chain to the GUI tree it actually lives in, so a copied-name button sitting in
-- some other mod's window never finds OUR frame as an ancestor. Callers use the
-- returned frame (not a `gui.screen[NAME]` / `gui.relative[NAME]` by-name fetch)
-- as the source of truth for which node/ship the event edits.
function common.ancestor_frame(el, frame_name)
  local cur = el
  while cur and cur.valid do
    if cur.name == frame_name then
      return cur
    end
    cur = cur.parent
  end
  return nil
end

-- The stable identifier for a force, matching dispatcher.force_key by
-- construction (index when present, else name). Used for the GUI force-match
-- gates: comparing forces by this KEY rather than userdata equality means a
-- researched force can't edit a friendly FOREIGN force's reserves / enroll its
-- platforms (userdata equality would also be safe, but the key keeps the GUI
-- compare identical to the dispatcher's scoping key the Monitor filters on).
function common.force_key(force)
  return force and (force.index or force.name) or nil
end

return common
