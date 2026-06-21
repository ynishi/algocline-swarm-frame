---@module 'swarm_frame.v3.engine.runtime'
-- Driver — compose flow.ir compile + exec + plugin_chain + observer +
-- safeguard into the single swarm.run() entry point (V3 §5.6.1).
--
-- P3 minimal: plugin_chain + observer + safeguard wired. State
-- semantics built-in (step_mark / step_done / gate_decide thin wrappers
-- on flow.FlowState) is deferred to P5 (depends on state_backend impl
-- shipping with swarm_host_alc).

local flow_ir       = require("flow.ir")
local plugin_chain  = require("swarm_frame.v3.engine.plugin_chain")
local observer_mod  = require("swarm_frame.v3.engine.observer")
local safeguard_mod = require("swarm_frame.v3.engine.safeguard")

local M = {}
M.VERSION = "0.0.1-v3-p3"

--- run(opts) -> Result
--- opts: {
---   shape          = Node,
---   dispatch       = fn(ref, input) -> response,
---   externs?       = { [string] = fn },
---   flows?         = { [string] = Node },
---   max_call_depth? = integer,
---   plugins?       = { plugin, ... },     -- 4-stage chain (before/around/after/finalize)
---   observers?     = { fn, ... },         -- event emitters
---   safeguard?     = { max_dispatch_total?, max_recursion_depth? },
---   state?         = table,
--- }
--- Result: { status = "ok" | "error", ctx = table, error? = {kind, message} }
function M.run(opts)
    local shape = opts.shape
    if not shape then
        error("swarm.run: opts.shape required", 2)
    end
    local raw_dispatch = opts.dispatch
    if not raw_dispatch then
        error("swarm.run: opts.dispatch required", 2)
    end
    local state    = opts.state or {}
    local plugins  = opts.plugins or {}
    local emitter  = (opts.observers and #opts.observers > 0)
                       and observer_mod.new(opts.observers)
                       or observer_mod.noop
    local sg       = safeguard_mod.new(opts.safeguard)

    local compiled, reason = flow_ir.compile(shape)
    if not compiled then
        return {
            status = "error",
            error  = { kind = "compile_fail", message = reason },
            ctx    = state,
        }
    end

    -- Wrap raw dispatch with: safeguard counter + observer emit +
    -- plugin_chain. Safeguard sits at the innermost (counts every
    -- physical invocation) so plugins can short-circuit before it.
    local safeguarded = function(ref, input, ctx)
        safeguard_mod.check_dispatch(sg)
        emitter({ phase = "start", ref = ref })
        local response = raw_dispatch(ref, input, ctx)
        emitter({ phase = "end", ref = ref })
        return response
    end
    local wrapped = plugin_chain.wrap_dispatch(plugins, safeguarded)

    local exec_opts = {
        dispatch       = wrapped,
        externs        = opts.externs,
        flows          = opts.flows,
        max_call_depth = opts.max_call_depth,
    }

    local ok, exec_err = pcall(function()
        flow_ir.exec(compiled, state, exec_opts)
    end)

    if not ok then
        local msg = tostring(exec_err)
        local kind = "exec_fail"
        if msg:find("safeguard:") then kind = "safeguard_breach" end
        emitter({ phase = "error",
                  error = { kind = kind, message = msg } })
        local result = {
            status = "error",
            error  = { kind = kind, message = msg },
            ctx    = state,
        }
        return plugin_chain.run_finalize(plugins, result)
    end

    local result = { status = "ok", ctx = state }
    return plugin_chain.run_finalize(plugins, result)
end

return M
