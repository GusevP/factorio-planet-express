-- scripts/gui/trade_tab.lua
--
-- The Planet Express Trade overlay on the vanilla Cargo Landing Pad GUI (Task 9).
-- In Space Age there is exactly one pad per planet, so the pad == the per-planet
-- trade node; this panel is where the player steers that node's trade.
--
-- It is a RELATIVE GUI anchored beside the pad's own window: it appears whenever
-- the player opens a cargo landing pad (and the "Interplanetary Trade Logistics"
-- technology is researched), and is torn down when the window closes. Three
-- sections:
--   * Imports  -- overlay on the pad's NATIVE request slots: a `source via fleet`
--                 toggle (default on) + an optional priority per requested item.
--   * Reserves -- the "keep N before exporting" floor: a global default + a
--                 per-item override table.
--   * This planet now -- a live readout (open demand / surplus offered / inbound
--                 shipments) built from the pure view-model.
--
-- Like the Monitor, this module is INTENTIONALLY dumb: it renders and routes
-- events; ALL shaping logic lives in pure modules (reserves.lua, demand.lua,
-- viewmodel.lua) that are unit-tested under plain `lua`. The engine-touching
-- render/event wiring here is verified by MANUAL PLAYTEST (open the pad, edit a
-- toggle/priority/reserve, confirm it persists across save/load and the readout
-- reflects live demand/surplus/inbound).

local state = require("scripts.state")
local reserves = require("scripts.reserves")
local demand = require("scripts.demand")
local viewmodel = require("scripts.viewmodel")
local qkey = require("scripts.qkey")
local fleet = require("scripts.fleet")
local common = require("scripts.gui.common")

local trade_tab = {}

-- [provisional] The cargo landing pad prototype name. Mirrors registry.PAD_NAME
-- (the registry indexes pads off the same name); confirm the exact 2.0 / Space
-- Age name in-engine before publishing.
trade_tab.PAD_NAME = "cargo-landing-pad"

-- Element names (greppable, collision-proof under the mod namespace). Per-item
-- rows append the item name so each widget round-trips to the item it edits.
local FRAME = "planet-express-trade-frame"
local SCROLL = "planet-express-trade-scroll"
local BODY = "planet-express-trade-body"
local FLEET_TOGGLE_PREFIX = "planet-express-trade-fleet-"
local PRIORITY_PREFIX = "planet-express-trade-priority-"
local RESERVE_DEFAULT = "planet-express-trade-reserve-default"
local RESERVE_ITEM_PREFIX = "planet-express-trade-reserve-item-"
local RESERVE_CLEAR_PREFIX = "planet-express-trade-reserve-clear-"
local RESERVE_ADD_ITEM = "planet-express-trade-reserve-add-item"
local RESERVE_ADD_AMOUNT = "planet-express-trade-reserve-add-amount"
local RESERVE_ADD_BTN = "planet-express-trade-reserve-add-btn"
local PIN_DROPDOWN = "planet-express-trade-pin-ship"

-- ---------------------------------------------------------------------------
-- tech gate
-- ---------------------------------------------------------------------------

-- The Trade tab gates on the SAME technology as the fleet (the Fleet tab gates on
-- it too), so alias `fleet.TECH` / `fleet.tech_researched` rather than keep a
-- duplicate copy -- a single source of truth keeps the two GUIs gating identically.
trade_tab.TECH = fleet.TECH
trade_tab.tech_researched = fleet.tech_researched

-- ---------------------------------------------------------------------------
-- node lookup
-- ---------------------------------------------------------------------------

-- The trade node for a pad entity (created by the registry on build). Nil if the
-- pad isn't indexed yet (e.g. a save predating the mod, before the next rebuild).
local function node_of(entity)
  if not (entity and entity.valid and entity.unit_number) then
    return nil
  end
  return storage.nodes and storage.nodes[entity.unit_number]
end

-- The node a Trade frame is editing, recovered from the frame's stored pad id.
local function node_of_frame(frame)
  local pad = frame and frame.tags and frame.tags.pad
  return pad and storage.nodes and storage.nodes[pad] or nil
end

-- ---------------------------------------------------------------------------
-- small render helpers
-- ---------------------------------------------------------------------------

local function section_header(parent, caption)
  local lbl = parent.add({ type = "label", caption = caption })
  lbl.style.font = "default-bold"
  lbl.style.top_padding = 6
end

-- A numeric textfield seeded with `value` (blank when nil). Clamped to integers,
-- never negative; the caller wires the actual persistence on text change.
local function numeric_field(parent, name, value, width)
  local tf = parent.add({
    type = "textfield",
    name = name,
    numeric = true,
    allow_decimal = false,
    allow_negative = false,
    text = value ~= nil and tostring(value) or "",
  })
  tf.style.width = width or 70
  return tf
end

-- The reserve/priority ceiling: matches the settings-stage maximum for the
-- mod's numeric settings. A `textfield` with `numeric=true` still accepts a
-- pasted 30-digit string, which `tonumber` happily turns into ~1e29 -- clamping
-- here stops that from persisting an absurd reserve that would never be exported.
local MAX_AMOUNT = 1000000

-- Parse a textfield's content as a non-negative integer, or nil when blank.
-- Clamped to [0, MAX_AMOUNT] so a pasted oversized string can't persist.
local function parse_amount(text)
  if text == nil then
    return nil
  end
  local trimmed = text:match("^%s*(.-)%s*$")
  if trimmed == "" then
    return nil
  end
  local n = tonumber(trimmed)
  if not n then
    return nil
  end
  n = math.floor(n)
  if n < 0 then
    n = 0
  elseif n > MAX_AMOUNT then
    n = MAX_AMOUNT
  end
  return n
end

-- ---------------------------------------------------------------------------
-- body render
-- ---------------------------------------------------------------------------

local function render_imports(body, node)
  section_header(body, { "planet-express.trade-imports" })
  local rows = demand.reader(node) or {}
  -- The pad's request rows are keyed by qkey(item, quality): the SAME item at two
  -- qualities is two rows. But the fleet-toggle + priority overlay is keyed by
  -- bare item NAME -- it applies to ALL qualities of the item (per the plan's
  -- Decisions, and matching demand.source_via_fleet / demand.priority, which take
  -- a name). So collapse the rows to their unique item NAMES and render one
  -- control per name; keying a widget by the qkey would store an override
  -- `source_via_fleet` / `priority` never read back (a silent no-op).
  local seen = {}
  local names = {}
  for _, row in ipairs(rows) do
    local name = qkey.qparse(row.item)
    if not seen[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end
  -- Stable order so the panel renders identically on every client.
  table.sort(names)
  if #names == 0 then
    body.add({ type = "label", caption = { "planet-express.trade-no-requests" } })
    return
  end
  local t = body.add({ type = "table", column_count = 3 })
  t.add({ type = "label", caption = { "planet-express.trade-col-item" } })
  t.add({ type = "label", caption = { "planet-express.trade-col-fleet" } })
  t.add({ type = "label", caption = { "planet-express.trade-col-priority" } })
  for _, name in ipairs(names) do
    t.add({ type = "label", caption = name })
    t.add({
      type = "checkbox",
      name = FLEET_TOGGLE_PREFIX .. name,
      state = demand.source_via_fleet(node, name),
    })
    numeric_field(t, PRIORITY_PREFIX .. name, demand.priority(node, name), 50)
  end
end

-- The enrolled, same-force ships offered as Preferred-ship pins for this node, in
-- the SAME sorted order render and the selection handler both use. Built from the
-- pure `fleet.enrolled_for_force` over the live `storage.fleet`, filtered to the
-- node's force. Returning the list (not just rendering it) lets the selection
-- handler map `selected_index` back to a fleet key deterministically (it rebuilds
-- this exact list and offsets by 1 for the "(auto)" row at index 1).
local function pin_options(node)
  return fleet.enrolled_for_force(storage.fleet, common.force_key(node.force))
end

-- "Preferred ship" drop-down: index 1 is always "(auto)" (no pin); the rest are
-- the enrolled same-force ships in sorted order. The currently-pinned ship (if
-- still enrolled) is pre-selected; a pin to a ship that no longer qualifies falls
-- back to "(auto)" (the registry also clears such a dangling pin on removal).
local function render_pin(body, node)
  section_header(body, { "planet-express.trade-pin-ship" })
  local options = pin_options(node)
  local items = { { "planet-express.trade-pin-auto" } }
  local selected = 1
  for i, opt in ipairs(options) do
    items[#items + 1] = opt.caption
    if node.pin_ship == opt.id then
      selected = i + 1  -- +1: "(auto)" occupies index 1
    end
  end
  body.add({
    type = "drop-down",
    name = PIN_DROPDOWN,
    items = items,
    selected_index = selected,
  })
end

local function render_reserves(body, node)
  section_header(body, { "planet-express.trade-reserves" })

  local cfg = node.reserves or {}
  local default_row = body.add({ type = "flow", direction = "horizontal" })
  default_row.add({ type = "label", caption = { "planet-express.trade-reserve-default" } })
  numeric_field(default_row, RESERVE_DEFAULT, cfg.default or 0, 70)

  -- existing per-item overrides
  local items = cfg.items or {}
  local names = state.sorted_keys(items)
  if #names > 0 then
    local t = body.add({ type = "table", column_count = 3 })
    for _, item in ipairs(names) do
      t.add({ type = "label", caption = item })
      numeric_field(t, RESERVE_ITEM_PREFIX .. item, items[item], 70)
      t.add({
        type = "sprite-button",
        name = RESERVE_CLEAR_PREFIX .. item,
        sprite = "utility/trash",
        style = "tool_button",
        tooltip = { "planet-express.trade-reserve-clear" },
      })
    end
  end

  -- add-override row: pick an item + amount, then "Add".
  local add_row = body.add({ type = "flow", direction = "horizontal" })
  add_row.add({
    type = "choose-elem-button",
    name = RESERVE_ADD_ITEM,
    elem_type = "item",
  })
  numeric_field(add_row, RESERVE_ADD_AMOUNT, nil, 70)
  add_row.add({
    type = "button",
    name = RESERVE_ADD_BTN,
    caption = { "planet-express.trade-reserve-add" },
  })
end

local function render_readout(body, node)
  section_header(body, { "planet-express.trade-now" })
  local view = viewmodel.build_node_readout(viewmodel.gather_node(node, game and game.tick or 0))

  -- build_node_readout decodes each cargo qkey into a bare item NAME + quality;
  -- qkey.label_parts renders that as "iron-plate" (or "iron-plate (uncommon)").
  body.add({ type = "label", caption = { "planet-express.trade-now-demand" } })
  if #view.demand == 0 then
    body.add({ type = "label", caption = { "planet-express.trade-none" } })
  else
    for _, d in ipairs(view.demand) do
      body.add({
        type = "label",
        caption = string.format("  %s x%d (p%d)", qkey.label_parts(d.item, d.quality), d.unmet, d.priority),
      })
    end
  end

  body.add({ type = "label", caption = { "planet-express.trade-now-surplus" } })
  if #view.surplus == 0 then
    body.add({ type = "label", caption = { "planet-express.trade-none" } })
  else
    for _, s in ipairs(view.surplus) do
      body.add({ type = "label", caption = string.format("  %s x%d", qkey.label_parts(s.item, s.quality), s.qty) })
    end
  end

  body.add({ type = "label", caption = { "planet-express.trade-now-inbound" } })
  if #view.inbound == 0 then
    body.add({ type = "label", caption = { "planet-express.trade-none" } })
  else
    for _, i in ipairs(view.inbound) do
      body.add({ type = "label", caption = string.format("  %s x%d", qkey.label_parts(i.item, i.quality), i.qty) })
    end
  end
end

local function render_body(body, node)
  body.clear()
  render_imports(body, node)
  render_pin(body, node)
  render_reserves(body, node)
  render_readout(body, node)
end

-- ---------------------------------------------------------------------------
-- open / close (driven by on_gui_opened / on_gui_closed)
-- ---------------------------------------------------------------------------

-- [provisional] The relative-GUI anchor for the cargo landing pad window.
-- Confirm the exact `defines.relative_gui_type` for the cargo landing pad
-- in-engine before flipping the api-notes GUI seam to [confirmed]; the rest of
-- the module is independent of which anchor is used.
local function relative_anchor()
  return {
    gui = defines.relative_gui_type.cargo_landing_pad_gui,
    position = defines.relative_gui_position.right,
  }
end

-- Rebuild the frame body from live state (after an edit or on open).
local function refresh_frame(frame)
  local node = node_of_frame(frame)
  -- BODY lives inside the scroll pane; element name-indexing only finds direct
  -- children, so resolve it through the (named) scroll, not straight off frame.
  local scroll = frame[SCROLL]
  local body = scroll and scroll[BODY]
  if node and body then
    render_body(body, node)
  end
end

-- Open the Trade overlay for the pad the player just opened. No-op unless the
-- entity is a cargo landing pad, the node is indexed, and the tech is researched.
function trade_tab.open(player, entity)
  if not (entity and entity.valid and entity.name == trade_tab.PAD_NAME) then
    return
  end
  if not trade_tab.tech_researched(player.force) then
    return
  end
  -- Force isolation: only the OWNING force may steer a pad's trade. Compare by
  -- the force KEY (index/name), not userdata equality, so a researched force can't
  -- edit a friendly FOREIGN force's reserves/imports just because it opened the pad.
  if common.force_key(entity.force) ~= common.force_key(player.force) then
    return
  end
  local node = node_of(entity)
  if not node then
    return
  end

  -- Destroy any stale frame first so re-opens always reflect the current pad.
  local existing = player.gui.relative[FRAME]
  if existing then
    existing.destroy()
  end

  local frame = player.gui.relative.add({
    type = "frame",
    name = FRAME,
    direction = "vertical",
    caption = { "planet-express.trade-title" },
    anchor = relative_anchor(),
    tags = { pad = entity.unit_number },
  })

  local scroll = frame.add({ type = "scroll-pane", name = SCROLL, direction = "vertical" })
  scroll.style.maximal_height = 600
  scroll.style.minimal_width = 300
  scroll.add({ type = "flow", name = BODY, direction = "vertical" })

  refresh_frame(frame)
end

function trade_tab.close(player)
  local frame = player.gui.relative[FRAME]
  if frame then
    frame.destroy()
  end
end

-- ---------------------------------------------------------------------------
-- event routing (registered from control.lua)
-- ---------------------------------------------------------------------------

function trade_tab.on_gui_opened(event)
  if event.gui_type ~= defines.gui_type.entity then
    return
  end
  local player = game.get_player(event.player_index)
  if player then
    trade_tab.open(player, event.entity)
  end
end

function trade_tab.on_gui_closed(event)
  if event.gui_type ~= defines.gui_type.entity then
    return
  end
  local player = game.get_player(event.player_index)
  if player then
    trade_tab.close(player)
  end
end

-- Find the editing node + the open frame for any event element under the Trade
-- frame. Returns (node, frame) or nil when the element isn't ours.
--
-- The frame is resolved by walking the element's OWN ancestry (common.ancestor_frame),
-- not by fetching `gui.relative[FRAME]` by name: the relative lookup alone would
-- let a foreign element that merely COPIES our element name drive a write into
-- whatever node OUR open frame happens to be editing. The ancestry walk proves
-- the event element actually descends from our frame before we touch storage.
local function context(el)
  if not (el and el.valid) then
    return nil
  end
  local frame = common.ancestor_frame(el, FRAME)
  if not frame then
    return nil
  end
  return node_of_frame(frame), frame
end

local function has_prefix(name, prefix)
  return name:sub(1, #prefix) == prefix
end

-- Checkbox: the per-item `source via fleet` toggle. Default-on semantics live in
-- demand.source_via_fleet, so we only store an explicit `false` (and clear the
-- override back to nil when re-enabled) to keep the overlay minimal.
function trade_tab.on_gui_checked_state_changed(event)
  local el = event.element
  if not (el and el.valid and has_prefix(el.name, FLEET_TOGGLE_PREFIX)) then
    return
  end
  local node = context(el)
  if not node then
    return
  end
  local item = el.name:sub(#FLEET_TOGGLE_PREFIX + 1)
  node.import_flags = node.import_flags or {}
  if el.state then
    node.import_flags[item] = nil
  else
    node.import_flags[item] = false
  end
end

-- Textfields: priority, default reserve, and per-item reserve overrides all
-- persist live as the player edits.
function trade_tab.on_gui_text_changed(event)
  local el = event.element
  if not (el and el.valid) then
    return
  end
  local node = context(el)
  if not node then
    return
  end
  local name = el.name
  if has_prefix(name, PRIORITY_PREFIX) then
    local item = name:sub(#PRIORITY_PREFIX + 1)
    node.priorities = node.priorities or {}
    node.priorities[item] = parse_amount(el.text) or 0
  elseif name == RESERVE_DEFAULT then
    reserves.set_default(node, parse_amount(el.text) or 0)
  elseif has_prefix(name, RESERVE_ITEM_PREFIX) then
    local item = name:sub(#RESERVE_ITEM_PREFIX + 1)
    -- Blank clears the override (falls back to default); a number sets it.
    reserves.set_item(node, item, parse_amount(el.text))
  end
end

-- Buttons: clear a per-item reserve override, or add a new one.
function trade_tab.on_gui_click(event)
  local el = event.element
  if not (el and el.valid) then
    return
  end
  local node, frame = context(el)
  if not node then
    return
  end
  local name = el.name
  if has_prefix(name, RESERVE_CLEAR_PREFIX) then
    local item = name:sub(#RESERVE_CLEAR_PREFIX + 1)
    reserves.set_item(node, item, nil)
    refresh_frame(frame)
  elseif name == RESERVE_ADD_BTN then
    -- the picker/amount live in the same add-row flow as the button.
    local add_item = el.parent[RESERVE_ADD_ITEM]
    local add_amount = el.parent[RESERVE_ADD_AMOUNT]
    local item = add_item and add_item.elem_value
    local amount = parse_amount(add_amount and add_amount.text)
    if item and amount ~= nil then
      reserves.set_item(node, item, amount)
      refresh_frame(frame)
    end
  end
end

-- Drop-down: the "Preferred ship" pin. Index 1 is "(auto)" (clears the pin);
-- every later index maps to an enrolled same-force ship in the SAME sorted order
-- render used, so we rebuild that list and read `selected_index - 1` back to its
-- fleet key. A stale selection (the ship un-enrolled or left the force between
-- render and pick) is treated as "(auto)" -- the pin is only set to a key that is
-- still in the live option list.
function trade_tab.on_gui_selection_state_changed(event)
  local el = event.element
  if not (el and el.valid and el.name == PIN_DROPDOWN) then
    return
  end
  local node = context(el)
  if not node then
    return
  end
  local idx = el.selected_index or 1
  if idx <= 1 then
    node.pin_ship = nil
    return
  end
  local options = pin_options(node)
  local opt = options[idx - 1]  -- -1: "(auto)" occupies dropdown index 1
  node.pin_ship = opt and opt.id or nil
end

return trade_tab
