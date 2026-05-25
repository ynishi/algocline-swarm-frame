--- slot_table — P1 Primitive (Conway GoL spike).
---
--- Indexed slot container with mechanical 5-op surface:
---   new / size / get / set / iter
---
--- Pure & thin: NO domain semantics (no birth/death, no payload schema,
--- no allocation policy). Each slot holds an arbitrary payload table.
---
--- Distinct from swarm_population in two points:
---   - payload is provided by an init_fn(idx) callback (per-slot init)
---     so the caller can vary initial payloads without post-hoc replace.
---   - set() replaces the slot payload (state-write semantic) rather
---     than swarm_population.replace (succession semantic).
---
--- Status: v0.1.0-spike — Domain 抽象度 verify probe for umbrella
--- 1779690943-76260 (primitives-draft.md §9 (iv)). API surface
--- provisional, bundled relocation pending Conway spike pass.

local M = {}

M.VERSION = "0.1.0-spike"
M.meta = {
    name = "slot_table",
    version = M.VERSION,
    description = "P1 indexed slot container; mechanical 5-op surface.",
}

local SlotTable = {}
SlotTable.__index = SlotTable

--- Build a SlotTable of `n` slots, payload of slot i = init_fn(i).
--- @param n integer positive integer
--- @param init_fn function (idx) -> payload table
--- @return SlotTable
function M.new(n, init_fn)
    if type(n) ~= "number" or n < 1 or math.floor(n) ~= n then
        error("slot_table.new: n must be positive integer (got " .. tostring(n) .. ")")
    end
    if type(init_fn) ~= "function" then
        error("slot_table.new: init_fn must be function (got " .. type(init_fn) .. ")")
    end
    local slots = {}
    for i = 1, n do
        local p = init_fn(i)
        if type(p) ~= "table" then
            error("slot_table.new: init_fn(" .. i .. ") must return table (got " .. type(p) .. ")")
        end
        slots[i] = p
    end
    return setmetatable({ _slots = slots, _n = n }, SlotTable)
end

function SlotTable:size() return self._n end

function SlotTable:get(idx)
    if idx < 1 or idx > self._n then
        error("slot_table.get: idx out of range (got " .. tostring(idx) .. ", size=" .. self._n .. ")")
    end
    return self._slots[idx]
end

--- Write a payload to slot `idx` (state-write semantic).
function SlotTable:set(idx, payload)
    if idx < 1 or idx > self._n then
        error("slot_table.set: idx out of range (got " .. tostring(idx) .. ", size=" .. self._n .. ")")
    end
    if type(payload) ~= "table" then
        error("slot_table.set: payload must be table (got " .. type(payload) .. ")")
    end
    self._slots[idx] = payload
end

--- Stateless iterator over (idx, payload).
function SlotTable:iter()
    local i = 0
    local n = self._n
    return function()
        i = i + 1
        if i > n then return nil end
        return i, self._slots[i]
    end
end

M.SlotTable = SlotTable
return M
