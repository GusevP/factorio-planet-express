-- scripts/reserves.lua
--
-- Reserve configuration for a trade node (cargo landing pad).
--
-- A node keeps a "keep N before exporting" floor so the dispatcher never
-- strip-mines a planet: surplus = max(0, stock - reserve). The config is a
-- global default floor plus optional per-item overrides, persisted in
-- `storage.nodes[pad].reserves = { default = N, items = { [item] = N } }`.
--
-- This module is PURE over a plain node table -- it never touches the engine,
-- so it loads and runs under plain `lua` for the calc tests. The dispatcher and
-- GUI pass it the live `storage.nodes[...]` entries; the tests pass plain
-- tables. Either way the math is identical.

local reserves = {}

-- ---------------------------------------------------------------------------
-- read
-- ---------------------------------------------------------------------------

-- Resolve the reserve floor for `item` on `node`:
--   * a per-item override wins if present (even if 0),
--   * else the node's global default,
--   * else 0 when the node has no reserve config at all.
-- A NEGATIVE value (-1, set from the Trade tab) is the export-off sentinel: it is
-- returned verbatim and interpreted downstream by `stock.compute_surplus` as "never
-- export this item here" (a flag, not a floor). So a -1 per-item override blocks that
-- item, and a -1 default makes the planet export nothing unless an item overrides it
-- back to a non-negative floor.
-- Pure: depends only on the node table handed in.
function reserves.reserve(node, item)
  local cfg = node and node.reserves
  if not cfg then
    return 0
  end
  local items = cfg.items
  if items ~= nil then
    local override = items[item]
    if override ~= nil then
      return override
    end
  end
  return cfg.default or 0
end

-- ---------------------------------------------------------------------------
-- write
-- ---------------------------------------------------------------------------

-- Ensure `node.reserves` exists and is well-formed; returns it. A freshly created
-- config starts with a default floor of 0; the registry seeds the real default
-- inline at node creation (`add_node` -> `default_reserve()`), so this never needs
-- to take a seed value.
function reserves.ensure(node)
  local cfg = node.reserves
  if not cfg then
    cfg = { default = 0, items = {} }
    node.reserves = cfg
  end
  cfg.items = cfg.items or {}
  return cfg
end

-- Set the global default floor for the node.
function reserves.set_default(node, amount)
  reserves.ensure(node).default = amount or 0
end

-- Set (or clear) a per-item override. Passing nil removes the override so the
-- item falls back to the default floor.
function reserves.set_item(node, item, amount)
  local cfg = reserves.ensure(node)
  cfg.items[item] = amount
end

return reserves
