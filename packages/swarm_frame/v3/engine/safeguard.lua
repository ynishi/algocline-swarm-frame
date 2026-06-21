---@module 'swarm_frame.v3.engine.safeguard'
-- Runtime safeguard counters — enforce hard caps so a runaway flow
-- (mis-configured loop, recursive call, dispatcher quirk) is bounded.
--
-- P3 minimal:
--   max_dispatch_total      — total dispatcher invocations per run()
--   max_recursion_depth     — Engine call-depth for sub-flow calls
--                             (flow.ir already enforces max_call_depth,
--                             this is the Engine-side surface for
--                             swarm-level wrappers)
--
-- The safeguard is consulted on every dispatch. Exceeding a cap
-- raises with a structured message — runtime.run() catches it and
-- returns a `safeguard_breach` Result.error.kind.

local M = {}
M.VERSION = "0.0.1-v3-p3"

--- new(opts) -> safeguard state
--- opts: {
---   max_dispatch_total?  = integer (default = 1000),
---   max_recursion_depth? = integer (default = 64),
--- }
function M.new(opts)
    opts = opts or {}
    return {
        dispatch_count    = 0,
        recursion_depth   = 0,
        max_dispatch_total  = opts.max_dispatch_total  or 1000,
        max_recursion_depth = opts.max_recursion_depth or 64,
    }
end

--- check_dispatch(sg) — call before each dispatch invocation.
--- Returns ok or raises with a structured message.
function M.check_dispatch(sg)
    sg.dispatch_count = sg.dispatch_count + 1
    if sg.dispatch_count > sg.max_dispatch_total then
        error("safeguard: max_dispatch_total ("
            .. sg.max_dispatch_total .. ") exceeded", 2)
    end
end

--- enter_recursion(sg) / leave_recursion(sg) — bookend swarm.call
--- crossings so depth is tracked.
function M.enter_recursion(sg)
    sg.recursion_depth = sg.recursion_depth + 1
    if sg.recursion_depth > sg.max_recursion_depth then
        error("safeguard: max_recursion_depth ("
            .. sg.max_recursion_depth .. ") exceeded", 2)
    end
end

function M.leave_recursion(sg)
    sg.recursion_depth = sg.recursion_depth - 1
end

return M
