--- transition_rules — P7 Primitive (Conway GoL spike).
---
--- Slot state-machine policy. Pure & thin:
---   - new                           : empty rule set
---   - add(from, to, predicate)      : append a transition rule
---   - apply(payload, ctx)           : evaluate rules in registration
---                                     order; first match wins; return
---                                     new payload (same payload table
---                                     ref, with state field rewritten;
---                                     other fields untouched).
---
--- payload contract: { state = <string>, ... domain fields ... }
--- predicate signature: predicate(payload, ctx) -> boolean
---
--- "退場 (departure)" is a degenerate case of transition_rules — a rule
--- with to_state="departed" is just one transition among many. Conway
--- B3/S23, Boids wrap, market bankrupt+reentry are all encoded the same
--- way.
---
--- Status: v0.1.0-spike — same provenance as slot_table.

local M = {}

M.VERSION = "0.1.0-spike"
M.meta = {
    name = "transition_rules",
    version = M.VERSION,
    description = "P7 slot state-machine policy (transition table).",
}

local Rules = {}
Rules.__index = Rules

--- Build an empty rule set.
function M.new()
    return setmetatable({ _rules = {} }, Rules)
end

--- Append a transition rule. Rules are evaluated in registration order
--- inside :apply; first match wins.
--- @param from string source state (payload.state must equal this to match)
--- @param to string destination state (payload.state will be set to this)
--- @param predicate function (payload, ctx) -> boolean
function Rules:add(from, to, predicate)
    if type(from) ~= "string" or from == "" then
        error("transition_rules.add: from must be non-empty string (got " .. type(from) .. ")")
    end
    if type(to) ~= "string" or to == "" then
        error("transition_rules.add: to must be non-empty string (got " .. type(to) .. ")")
    end
    if type(predicate) ~= "function" then
        error("transition_rules.add: predicate must be function (got " .. type(predicate) .. ")")
    end
    table.insert(self._rules, { from = from, to = to, predicate = predicate })
end

--- Apply rules to payload; returns a new payload table with state
--- possibly rewritten. Other fields are shallow-copied from payload.
--- If no rule matches, returns a shallow copy with unchanged state.
function Rules:apply(payload, ctx)
    if type(payload) ~= "table" then
        error("transition_rules.apply: payload must be table (got " .. type(payload) .. ")")
    end
    if type(payload.state) ~= "string" then
        error("transition_rules.apply: payload.state must be string (got " .. type(payload.state) .. ")")
    end
    local out = {}
    for k, v in pairs(payload) do out[k] = v end
    for _, rule in ipairs(self._rules) do
        if rule.from == payload.state and rule.predicate(payload, ctx) then
            out.state = rule.to
            return out
        end
    end
    return out
end

--- Inspection helper (testing / debug).
function Rules:size() return #self._rules end

M.Rules = Rules
return M
