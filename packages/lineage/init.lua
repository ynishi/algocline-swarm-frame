--- lineage — P4 Primitive (W11 GA spike).
---
--- parent_slot -> child_slot edge graph + generation tag. Pure & thin:
---   - new                                : empty graph
---   - set_mutation_op(fn)                : register Q1 subordinate
---   - beget(parent, child, gen, payload) : invoke mutation_op on
---                                          parent_payload to produce
---                                          child_payload, record edge,
---                                          return the child payload.
---   - parent(child) / children(parent)   : graph accessors
---   - generation(slot)                   : slot's generation number
---   - edges() / size()                   : debug / verify
---
--- Q1 mutation_op subordinate position (primitives-draft.md §1 v1):
--- mutation_op is NOT a standalone primitive — it lives here as the
--- payload-transform hook of edge creation. Lineage and mutation always
--- co-occur (15-domain co-occurrence rate 100% in §2), so wrapping
--- mutation_op into lineage avoids primitive proliferation.
---
--- Semantics for slot reuse (GA / agent slot recycling):
---   - `edges()` is APPEND-ONLY history (every beget appends an entry)
---   - `parent(child_slot)` / `children(parent_slot)` / `generation(slot)`
---     reflect the LATEST beget on that slot (overwrite on reuse).
--- Callers that need the original parent of a slot at gen N must walk
--- `edges()` themselves; the indexed accessors are state, not history.
---
--- Status: v0.1.0-spike — same provenance as slot_table.

local M = {}

M.VERSION = "0.1.0-spike"
M.meta = {
    name = "lineage",
    version = M.VERSION,
    description = "P4 parent->child edge graph + Q1 mutation_op subordinate.",
}

local Lineage = {}
Lineage.__index = Lineage

--- Build an empty lineage graph.
function M.new()
    return setmetatable({
        _mutation_op = nil,
        _edges = {},
        _parent_of = {},
        _children_of = {},
        _gen_of = {},
    }, Lineage)
end

--- Register the mutation_op (Q1 subordinate). Signature:
--- `fn(parent_payload table) -> child_payload table`.
function Lineage:set_mutation_op(fn)
    if type(fn) ~= "function" then
        error("lineage.set_mutation_op: fn must be function (got " .. type(fn) .. ")")
    end
    self._mutation_op = fn
end

--- Create a child payload from parent_payload via mutation_op, record
--- the edge, return the child payload.
function Lineage:beget(parent_slot, child_slot, gen, parent_payload)
    if type(self._mutation_op) ~= "function" then
        error("lineage.beget: mutation_op not set (call set_mutation_op first)")
    end
    if type(parent_slot) ~= "number" or parent_slot < 1 or math.floor(parent_slot) ~= parent_slot then
        error("lineage.beget: parent_slot must be positive integer (got " .. tostring(parent_slot) .. ")")
    end
    if type(child_slot) ~= "number" or child_slot < 1 or math.floor(child_slot) ~= child_slot then
        error("lineage.beget: child_slot must be positive integer (got " .. tostring(child_slot) .. ")")
    end
    if type(gen) ~= "number" or gen < 0 or math.floor(gen) ~= gen then
        error("lineage.beget: gen must be non-negative integer (got " .. tostring(gen) .. ")")
    end
    if type(parent_payload) ~= "table" then
        error("lineage.beget: parent_payload must be table (got " .. type(parent_payload) .. ")")
    end
    local child_payload = self._mutation_op(parent_payload)
    if type(child_payload) ~= "table" then
        error("lineage.beget: mutation_op must return table (got " .. type(child_payload) .. ")")
    end
    table.insert(self._edges, { parent = parent_slot, child = child_slot, gen = gen })
    self._parent_of[child_slot] = parent_slot
    if not self._children_of[parent_slot] then
        self._children_of[parent_slot] = {}
    end
    table.insert(self._children_of[parent_slot], child_slot)
    self._gen_of[child_slot] = gen
    return child_payload
end

function Lineage:parent(child_slot)
    return self._parent_of[child_slot]
end

function Lineage:children(parent_slot)
    local list = self._children_of[parent_slot]
    if not list then return {} end
    local copy = {}
    for i, v in ipairs(list) do copy[i] = v end
    return copy
end

function Lineage:generation(slot)
    return self._gen_of[slot] or 0
end

function Lineage:edges()
    local copy = {}
    for i, e in ipairs(self._edges) do
        copy[i] = { parent = e.parent, child = e.child, gen = e.gen }
    end
    return copy
end

function Lineage:size() return #self._edges end

M.Lineage = Lineage
return M
