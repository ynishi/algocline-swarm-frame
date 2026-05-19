--- swarm_frame.plain_state — function-based mirror of
--- `swarm_frame.State` methods, operating on plain Lua tables.
---
--- Frame native path: `swarm_frame.State` exposes `:step_done` /
--- `:step_mark` / `:log_phase` as methods (init.lua:191-203) on an
--- opaque container. Orchs that adopt `swarm_frame.state_new` get
--- those for free.
---
--- Plain-state path (this module): the 13 orchs in
--- `agent-profiles/packages/*` (coding_orch, saas_*, flow_*,
--- olympian_weekly, distillation_orch, ...) are built on algocline's
--- `flow.state_new`, whose result is a plain table (`state.data.
--- completed_steps` is a string list, `pipeline_log` is a separate
--- record list). Each such orch otherwise hand-rolls its own 3-line
--- closures over those lists. This module consolidates them into the
--- same three primitives as `State:*`, shaped as free functions over
--- the plain lists.
---
--- `plain_state` is a first-class peer of `State`, not a util drawer:
--- the two surfaces expose the same conceptual primitives
--- (step_done / step_mark / log_phase) on two valid container shapes.
--- Orchs that adopt frame.state_new use the method form; orchs that
--- stay on flow.state_new use the function form. Neither is
--- deprecated.
---
--- ## Migration pattern (for a non-frame orch)
---
--- Before:
---
---     local function step_done(name)
---         for _, s in ipairs(state.completed_steps) do
---             if s == name then return true end
---         end
---         return false
---     end
---     local function step_mark(name)
---         state.completed_steps[#state.completed_steps + 1] = name
---         flow.state_save(st)
---     end
---     local function log_phase(name, status, detail)
---         pipeline_log[#pipeline_log + 1] = {
---             name = name, status = status, detail = detail,
---         }
---     end
---
--- After:
---
---     local plain_state = require("swarm_frame.plain_state")
---     -- inside M.run:
---     if plain_state.step_done(state.completed_steps, name) then ... end
---     plain_state.step_mark(state.completed_steps, name,
---         function() flow.state_save(st) end)
---     plain_state.log_phase(pipeline_log, name, status, detail)
---
--- ## Contract
---
--- All three functions are pure in their primary arguments (read or
--- append-only on a list passed by reference). `step_mark` accepts an
--- optional `save_fn` callback to express the prevailing "append +
--- immediate persist" pattern in a single call — callers that don't
--- want persistence simply omit it.

local M = {}

M.VERSION = "0.5.0"

--- Return true iff `name` appears anywhere in `completed_steps`.
--- Linear scan; O(n) on the list length. The list is left untouched.
---
--- @param completed_steps string[]  prior step ids appended in order
--- @param name string  the step id to test
--- @return boolean
function M.step_done(completed_steps, name)
    for _, s in ipairs(completed_steps) do
        if s == name then return true end
    end
    return false
end

--- Append `name` to `completed_steps` and optionally trigger a save.
--- `save_fn` is invoked AFTER the append, so the persisted snapshot
--- already includes the new step id — matching the pre-existing orch
--- semantics ("append + immediate persist").
---
--- @param completed_steps string[]  list to append to (mutated)
--- @param name string  the step id to record
--- @param save_fn fun()?  optional persistence callback
function M.step_mark(completed_steps, name, save_fn)
    completed_steps[#completed_steps + 1] = name
    if save_fn then save_fn() end
end

--- Append a structured log record to `pipeline_log`.
--- The record shape is `{ name = name, status = status, detail = detail }`,
--- matching the prevailing convention across the 13 non-frame orchs
--- (and the `swarm_frame.State:log_phase` method, modulo the field
--- name `step` vs `name` — kept distinct here to avoid silently
--- breaking the existing orch consumers).
---
--- @param pipeline_log table[]  list of log records (mutated)
--- @param name string  phase / step identifier
--- @param status string  free-form status tag (e.g. "done" / "blocked")
--- @param detail any  free-form detail payload
function M.log_phase(pipeline_log, name, status, detail)
    pipeline_log[#pipeline_log + 1] = {
        name = name,
        status = status,
        detail = detail,
    }
end

-- ─── Rich Verdict 2-layer separation ────────────────────────────────────────
--
-- Two layers are kept strictly isolated:
--
--   [Internal transition layer (hard)]
--     verdict:is_halting() -> bool
--       The sole function that drives state-machine transitions.
--       gate_decide reads ONLY this — string matching on next_action or
--       label inside the primitive is forbidden.
--     default: returns true iff next_action == "halt"
--
--   [Host information layer (Rich)]
--     verdict.next_action   string  -- "halt"/"escalate"/"retry"/Custom
--     verdict.detail        string?
--     verdict.raw           any
--     verdict.label         string
--     -> stored verbatim in state.data.gates[name].verdict
--     -> gate_decide performs pass-through only; it never interprets,
--        transforms, or removes any field.

local Verdict = {}
Verdict.__index = Verdict

--- Default is_halting implementation.
--- Returns true iff next_action == "halt".  This is the internal
--- transition layer's sole decision gate; callers that need custom
--- halt semantics pass `is_halting = function(self) ... end` in
--- `fields` to override via metatable __index precedence.
function Verdict:is_halting() return self.next_action == "halt" end

--- Build a Rich Verdict object.
--- `fields` must be a table; recommended keys:
---   label       string   -- e.g. "BLOCKED" / "PASS"
---   next_action string?  -- "halt" / "escalate" / "retry" / Custom
---   detail      string?
---   raw         any
---   is_halting  fun(self)?  -- Custom override (wins over default)
---
--- @param fields table
--- @return table  verdict with :is_halting() method
function M.verdict(fields)
    if type(fields) ~= "table" then error("swarm_frame.plain_state.verdict: fields must be a table") end
    return setmetatable(fields, Verdict)
end

--- Apply a gate verdict to the shared gate registry and completed-steps list.
---
--- Two strict invariants (Crux):
---   1. The ONLY condition that appends `name` to `completed_steps` is
---      `verdict:is_halting()` returning true.  No string match on
---      next_action, label, or any other field is allowed here.
---   2. The entire `verdict` object is stored verbatim at
---      `gates[name].verdict`.  No field is read, transformed, or
---      removed by this primitive.
---
--- `retries` is incremented on every call (including PASS verdicts) —
--- it counts gate_decide invocations, not halt events.
---
--- @param gates table               gate-name → gate-record dict
--- @param completed_steps table     string list (mutated on halt)
--- @param name string               gate identifier
--- @param verdict table             Rich Verdict (from M.verdict or literal)
--- @param save_fn fun()?            optional persistence callback
function M.gate_decide(gates, completed_steps, name, verdict, save_fn)
    if type(gates) ~= "table" then error("swarm_frame.plain_state.gate_decide: gates must be a table") end
    if type(completed_steps) ~= "table" then
        error("swarm_frame.plain_state.gate_decide: completed_steps must be a table")
    end
    if type(name) ~= "string" then error("swarm_frame.plain_state.gate_decide: name must be a string") end
    if type(verdict) ~= "table" then error("swarm_frame.plain_state.gate_decide: verdict must be a table") end

    -- Fallback for literal-table verdicts not created via M.verdict():
    -- attach the default Verdict metatable so :is_halting() is available.
    -- Only applied when the table has no metatable at all (no-op for
    -- factory-created verdicts that already carry Verdict as their mt).
    if type(verdict.is_halting) ~= "function" and getmetatable(verdict) == nil then setmetatable(verdict, Verdict) end

    local g = gates[name] or { retries = 0 }
    g.verdict = verdict -- Rich pass-through: all fields preserved verbatim
    g.retries = (g.retries or 0) + 1 -- counts calls, not halt events
    if verdict:is_halting() then -- sole transition gate (Crux)
        completed_steps[#completed_steps + 1] = name
        g.marked_at = os.time()
    end
    gates[name] = g
    if save_fn then save_fn() end
end

return M
