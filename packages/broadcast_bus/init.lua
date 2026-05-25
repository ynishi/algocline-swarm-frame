--- broadcast_bus — P6 Primitive (Conway GoL spike).
---
--- 1-to-N publish + aggregation hook. Pure & thin:
---   - new           : empty bus
---   - reset         : clear all published msgs
---   - publish(src, msg)        : src slot publishes a msg
---   - aggregate_for(target,
---                   selector_fn,
---                   agg_fn)    : target slot view; collect msgs from
---                                src slots that pass selector_fn, then
---                                apply agg_fn to the msg list.
---
--- selector_fn + agg_fn are the two injection points that determine
--- Domain 抽象度 quality (§2 of primitives-draft.md). Examples:
---   - Conway: selector = "is in 8-neighborhood", agg = sum
---   - Voting: selector = "is alive voter",       agg = condorcet
---   - Pheromone field: selector = "within range", agg = weighted_sum
---
--- Status: v0.1.0-spike — same provenance as slot_table.

local M = {}

M.VERSION = "0.1.0-spike"
M.meta = {
    name = "broadcast_bus",
    version = M.VERSION,
    description = "P6 1-to-N publish + selector/aggregation hook.",
}

local Bus = {}
Bus.__index = Bus

--- Build an empty bus.
function M.new()
    return setmetatable({ _msgs = {} }, Bus)
end

--- Clear all published msgs (round boundary).
function Bus:reset()
    self._msgs = {}
end

--- Publish `msg` from `src` slot. msg may be any value.
function Bus:publish(src, msg)
    if type(src) ~= "number" or src < 1 or math.floor(src) ~= src then
        error("broadcast_bus.publish: src must be positive integer (got " .. tostring(src) .. ")")
    end
    table.insert(self._msgs, { src = src, msg = msg })
end

--- target view: collect msgs from src slots where selector_fn(src) is
--- truthy, then apply agg_fn(msg_list) and return the result.
---
--- selector_fn(src_idx) -> boolean
--- agg_fn(msg_list table) -> any
function Bus:aggregate_for(target, selector_fn, agg_fn)
    if type(target) ~= "number" or target < 1 or math.floor(target) ~= target then
        error("broadcast_bus.aggregate_for: target must be positive integer (got " .. tostring(target) .. ")")
    end
    if type(selector_fn) ~= "function" then
        error("broadcast_bus.aggregate_for: selector_fn must be function (got " .. type(selector_fn) .. ")")
    end
    if type(agg_fn) ~= "function" then
        error("broadcast_bus.aggregate_for: agg_fn must be function (got " .. type(agg_fn) .. ")")
    end
    local picked = {}
    for _, entry in ipairs(self._msgs) do
        if selector_fn(entry.src) then
            table.insert(picked, entry.msg)
        end
    end
    return agg_fn(picked)
end

M.Bus = Bus
return M
