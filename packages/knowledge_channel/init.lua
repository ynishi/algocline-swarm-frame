--- knowledge_channel — P5 Primitive (W4 Arena spike).
---
--- Predecessor -> successor rich payload transform. Pure & thin:
---   - new                                       : empty channel
---   - set_transform(fn)                         : register transform_fn
---   - transfer(predecessor, successor, payload, ctx?)
---                                                : invoke transform_fn,
---                                                  log the transfer,
---                                                  return transformed
---                                                  payload
---   - history() / size()                        : append-only log
---
--- transform_fn signature: `fn(payload table, ctx table?) -> table`
---
--- Distinct from P4 lineage's Q1 mutation_op:
---   - Q1 mutation_op (lineage subordinate) is for stateless numeric /
---     vector / categorical single-op variation (e.g. ±0.1 jitter).
---     Always co-occurs with lineage edges (graph structure).
---   - P5 knowledge_channel is for STRUCTURAL payload transform that
---     can include schema reshape, LLM calls, hash projection, etc.
---     Independent of lineage graph: can flow peer->peer, broadcast,
---     or aggregate predecessors (single transfer is the primitive;
---     multi-source aggregation is the caller's composition).
---
--- Domain examples (primitives-draft.md §1 v1 P5):
---   - Arena: strategy_record (wins/losses/top_styles) reshape on
---            inheritance
---   - Creative Farm: tech_notes synthesis (LLM transform)
---   - Cultural meme: genome -> phenotype projection
---
--- Status: v0.1.0-spike — same provenance as slot_table.

local M = {}

M.VERSION = "0.1.0-spike"
M.meta = {
    name = "knowledge_channel",
    version = M.VERSION,
    description = "P5 predecessor->successor rich payload transform.",
}

local Channel = {}
Channel.__index = Channel

local function is_pos_int(v)
    return type(v) == "number" and v >= 1 and math.floor(v) == v
end

--- Build an empty channel.
function M.new()
    return setmetatable({ _transform = nil, _history = {} }, Channel)
end

--- Register the transform_fn. Signature: `fn(payload, ctx?) -> table`.
function Channel:set_transform(fn)
    if type(fn) ~= "function" then
        error("knowledge_channel.set_transform: fn must be function (got " .. type(fn) .. ")")
    end
    self._transform = fn
end

--- Apply transform_fn to payload, record the transfer, return the
--- transformed payload. `ctx` is an optional table forwarded to
--- transform_fn for run-time context (e.g. generation index).
function Channel:transfer(predecessor, successor, payload, ctx)
    if type(self._transform) ~= "function" then
        error("knowledge_channel.transfer: transform_fn not set (call set_transform first)")
    end
    if not is_pos_int(predecessor) then
        error("knowledge_channel.transfer: predecessor must be positive integer (got " .. tostring(predecessor) .. ")")
    end
    if not is_pos_int(successor) then
        error("knowledge_channel.transfer: successor must be positive integer (got " .. tostring(successor) .. ")")
    end
    if type(payload) ~= "table" then
        error("knowledge_channel.transfer: payload must be table (got " .. type(payload) .. ")")
    end
    if ctx ~= nil and type(ctx) ~= "table" then
        error("knowledge_channel.transfer: ctx must be table or nil (got " .. type(ctx) .. ")")
    end
    local transformed = self._transform(payload, ctx)
    if type(transformed) ~= "table" then
        error("knowledge_channel.transfer: transform_fn must return table (got " .. type(transformed) .. ")")
    end
    table.insert(self._history, { predecessor = predecessor, successor = successor })
    return transformed
end

function Channel:history()
    local copy = {}
    for i, h in ipairs(self._history) do
        copy[i] = { predecessor = h.predecessor, successor = h.successor }
    end
    return copy
end

function Channel:size() return #self._history end

M.Channel = Channel
return M
