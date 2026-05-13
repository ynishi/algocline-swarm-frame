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

M.VERSION = "0.1.0"

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
        name = name, status = status, detail = detail,
    }
end

return M
