# Factorio GUI capabilities — what a mod can and cannot draw

A reference for anyone proposing UI changes to Planet Express (or any Factorio mod)
without having to read the Lua API first. Sibling to `api-notes.md`: that one gates
engine *seams*, this one gates *interface* proposals.

**Verified against the runtime API for 2.0.77**, the series both Planet Express
release lines share (the 2.1 upload and the 2.0-compatible 1.10.x upload are the same
code). Anything below marked **[2.1+]** must not be used while the 2.0 line ships.

Factorio's GUI is a **retained widget tree**, not a canvas and not a document. You
build a tree of typed elements, set properties on them, and the engine draws it. There
is no drawing surface, no stylesheet language, and no layout engine beyond nesting.
Almost every limitation below follows from that one fact.

---

## The widget set (all 26 types — this list is closed)

You cannot invent a widget. If an idea needs a control that is not here, it has to be
built by composing these, or dropped.

**Containers and layout**
| Type | What it is |
| --- | --- |
| `frame` | A solid titled box. The only element that can be a draggable window. |
| `flow` | Invisible container, lays children horizontally or vertically. The workhorse. |
| `table` | Grid with a fixed column count and per-column alignment. |
| `scroll-pane` | A clipping, scrolling region. |
| `tabbed-pane` + `tab` | Real tabs. |
| `line` | A horizontal or vertical separator rule. |
| `empty-widget` | A blank spacer — the idiomatic way to push things apart or fill space. |

**Text and display**
| Type | What it is |
| --- | --- |
| `label` | Text. Supports inline rich-text icons. |
| `sprite` | A static image. |
| `progressbar` | A filled bar, 0..1. |
| `entity-preview` | A live 3D view of an entity. |
| `minimap` | A live map view. |
| `camera` | A live view of any world position. |

**Input**
| Type | What it is |
| --- | --- |
| `button` | Text button. |
| `sprite-button` | Icon button. The basis for most compact toolbars. |
| `checkbox` / `radiobutton` | Boolean / exclusive choice. |
| `switch` | Two- or three-position toggle with left/right labels. |
| `textfield` / `text-box` | Single-line / multi-line text entry. |
| `slider` | Numeric drag, with min/max/step. |
| `drop-down` / `list-box` | Closed list of choices. |
| `choose-elem-button` | **A real item/fluid/signal/entity picker**, with the game's own filtered chooser UI. Free to use — do not hand-roll an item selector. |
| `inventory` | An actual inventory grid. |

## Styling — what is settable, and from where

Two levels, and the distinction decides how expensive a proposal is:

**Runtime, free** (`element.style.<prop> = …`, any tick, no shipped assets):
- Colour: `font_color`, and the state variants `hovered_font_color`,
  `clicked_font_color`, `disabled_font_color`, `selected_font_color`,
  `selected_hovered_font_color`. **State-dependent colour needs no custom asset.**
- Box model: `padding` / `margin` per side, `cell_padding` for tables,
  `horizontal_spacing` / `vertical_spacing`.
- Sizing: `width`, `height`, `minimal_*`, `maximal_*`, `natural_*`,
  `horizontally_stretchable` / `squashable` (and vertical equivalents).
- Alignment: `horizontal_align`, `vertical_align`, and per-column
  `column_alignments` on a table.
- Text: `font` (from a fixed set of prototyped fonts), `single_line`.
- `rich_text_setting` — whether inline icons render in this element at all.

**Load time, real work** (data-stage prototypes, shipped in the mod):
- New named styles, and any custom graphics/sprites they use.
- New fonts.

So: **recolouring, respacing, regrouping and resizing are cheap. New visual
components are not.**

## Interaction — the full event set

`on_gui_click`, `on_gui_checked_state_changed`, `on_gui_confirmed`,
`on_gui_elem_changed`, `on_gui_hover`, `on_gui_leave`, `on_gui_location_changed`,
`on_gui_opened`, `on_gui_closed`, `on_gui_selected_tab_changed`,
`on_gui_selection_state_changed`, `on_gui_switch_state_changed`,
`on_gui_text_changed`, `on_gui_value_changed`, `on_gui_inventory_action`.

Notable consequences:
- **Hover-driven behaviour is possible.** Set `raise_hover_events = true` on an element
  and you get enter/leave events — so hover can reveal detail, highlight a related row,
  or swap content. It is not limited to tooltips.
- **Tooltips are free and unlimited in length**, and `elem_tooltip` shows the game's own
  item tooltip above yours. Detail-on-demand is the cheapest good pattern available.
- **Windows can be dragged** by setting `drag_target` on a header element — but only a
  top-level element in `gui.screen` can be a drag target.
- There is **no** drag-and-drop between elements, no reorder-by-dragging, no gesture
  support, and no keyboard focus control beyond the engine's own.

## Hard limits — do not design around these

- **No custom-drawn widgets.** No canvas, no arbitrary shapes, no charts. A graph must
  be faked out of `progressbar`s, coloured `empty-widget`s, or a pre-rendered sprite.
- **No animation or transitions.** Nothing tweens. A value either is or is not.
  Apparent motion means redrawing on a timer, which costs UPS.
- **No free positioning inside a window.** Layout is nesting, alignment and spacing
  only. There is no absolute positioning, no grid areas, no z-ordering of siblings, no
  overlap. `location` exists only for top-level `gui.screen` frames.
- **No sticky headers inside a `scroll-pane`.** A header must live outside the scrolling
  region to stay visible.
- **No arbitrary type.** Fonts are prototypes; you pick from a set.
- **Tables have a fixed column count.** No spanning, no auto-fit, no reflow. A wide row
  widens the whole column for every row.
- **No responsive breakpoints.** You can read the player's `display_resolution` and
  `display_scale` and branch, but nothing reflows on its own.

## The refresh constraint

Planet Express rebuilds a panel body wholesale (`body.clear()` then re-add) on a timer,
because element state does not survive that and the mod holds no per-element state. Two
consequences for any proposal:

- **Per-second updates are fine. Per-frame updates are not.** Anything that needs to
  move smoothly is out.
- **A full rebuild loses transient UI state** — scroll position, text being typed,
  which row was hovered. Any state that must persist across a refresh has to be stored
  deliberately (this mod keeps expanded/collapsed sections in `storage`, per player).
  The more per-element state a design implies, the more it costs.

The in-place exception: individual labels can be repainted without a rebuild if they are
tagged and looked up (this mod does that for live ETA countdowns each second).

## Practical guidance for proposals

Cheap, high-leverage, no engine risk:
- Regrouping, reordering, and spacing changes
- Colour and emphasis, including hover colour
- Collapsible sections and tabs
- Inline item/planet/signal icons — very cheap and already used heavily
- Moving detail into tooltips instead of onto the row
- `choose-elem-button` anywhere an item is picked

Worth proposing, costs real work:
- Custom sprites or a new named style
- A new window with its own drag/close lifecycle
- Anything needing per-element state to survive refresh

Do not propose:
- Charts, sparklines, or anything drawn
- Animation, transitions, easing
- Drag-to-reorder
- Overlapping or absolutely positioned elements
