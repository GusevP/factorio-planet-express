-- scripts/gui/common.lua
--
-- Tiny shared helpers for the three GUI modules (Trade tab, Fleet tab, Monitor).
-- Both helpers are about TRUST: an event element's name is attacker-controlled
-- (any mod / script can `add` an element with our exact name into its own GUI),
-- so before an event handler writes to OUR storage off the element it must prove
-- the element really descends from one of OUR frames -- not a foreign element
-- that merely COPIES our element name.
--
-- This module is engine-touching only in the trivial sense that it walks
-- `el.parent` (a LuaGuiElement chain) -- there is no `storage`/`game`/`settings`
-- access, so it still loads under plain `lua`. It deliberately holds NO shaping
-- logic (that lives in the pure viewmodel); it is pure routing/trust glue.

local common = {}

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
