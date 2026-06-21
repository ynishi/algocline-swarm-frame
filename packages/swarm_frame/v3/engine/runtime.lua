---@module 'swarm_frame.v3.engine.runtime'
-- Driver — compose flow.ir compile + exec + plugin_chain + observer +
-- safeguard + state semantics built-in into the single swarm.run()
-- entry point (V3 §5.6.1 + §5.6.2 R5 land).

local flow_ir       = require("flow.ir")
local plugin_chain  = require("swarm_frame.v3.engine.plugin_chain")
local observer_mod  = require("swarm_frame.v3.engine.observer")
local safeguard_mod = require("swarm_frame.v3.engine.safeguard")
local state_mod     = require("swarm_frame.v3.engine.state")

local M = {}
M.VERSION = "0.0.2-v3-p5"

-- Re-export state semantics so callers can use swarm.<fn> without
-- requiring the sub-module directly (§4.1.3 built-in).
M.STATUS                       = state_mod.STATUS
M.step_mark                    = state_mod.step_mark
M.step_done                    = state_mod.step_done
M.gate_decide                  = state_mod.gate_decide
M.resolve_state                = state_mod.resolve
M.wrap_dispatch_with_progress  = state_mod.wrap_dispatch_with_progress
M.make_checkpoint_plugin       = state_mod.make_checkpoint_plugin

--- run(opts) -> Result
--- opts: {
---   shape           = Node,
---   dispatch        = fn(ref, input, ctx?) -> response,
---   externs?        = { [string] = fn },
---   flows?          = { [string] = Node },
---   max_call_depth? = integer,
---   plugins?        = { plugin, ... },     -- 4-stage chain
---   observers?      = { fn, ... },         -- event emitters
---   safeguard?      = { max_dispatch_total?, max_recursion_depth? },
---   ctx?            = table,               -- initial ctx contents (fresh mode only)
---   state?          = {                    -- §6.2 State/Resume Protocol
---     task_id?        = string,            --   auto-gen if omitted
---     force_fresh?    = boolean,
---     force_continue? = boolean,
---     checkpoint?     = "step"|"phase"|"manual",
---   },
---   state_backend?  = iface,               -- §4.1.4 default file backend
--- }
--- Result: { status, ctx, task_id, error? }
function M.run(opts)
    local shape = opts.shape
    if not shape then
        error("swarm.run: opts.shape required", 2)
    end
    local raw_dispatch = opts.dispatch
    if not raw_dispatch then
        error("swarm.run: opts.dispatch required", 2)
    end
    local state_backend  = opts.state_backend
    local user_plugins   = opts.plugins or {}
    local emitter        = (opts.observers and #opts.observers > 0)
                             and observer_mod.new(opts.observers)
                             or observer_mod.noop
    local sg             = safeguard_mod.new(opts.safeguard)

    -- ─── State / Resume resolve (R5 land 軸 2 / 軸 3) ────────────────
    local resolution = state_mod.resolve(state_backend, opts.state)
    local task_id    = resolution.task_id
    local ctx        = resolution.ctx

    -- Merge caller-supplied initial ctx contents (fresh mode only — do
    -- not trample resumed state). Preserves _progress regardless.
    if resolution.mode == "fresh" and type(opts.ctx) == "table" then
        local preserved_progress = ctx._progress
        for k, v in pairs(opts.ctx) do
            if k ~= "_progress" then ctx[k] = v end
        end
        ctx._progress = preserved_progress or {}
    end

    if resolution.mode == "error" then
        return {
            status  = "error",
            error   = resolution.error,
            ctx     = ctx,
            task_id = task_id,
        }
    end
    if resolution.mode == "cached_return" then
        local prev = resolution.prev_result or {}
        return {
            status  = prev.status or "ok",
            ctx     = ctx,
            task_id = task_id,
            error   = prev.error,
        }
    end

    -- ─── checkpoint plugin (V3 §6.2.5 強制注入) ─────────────────────
    --
    -- Built before compile so a compile-fail also writes FAILED via
    -- run_finalize.
    local checkpoint_granularity = (opts.state and opts.state.checkpoint)
                                   or "step"
    local checkpoint_plugin      = state_mod.make_checkpoint_plugin(
        state_backend, task_id, checkpoint_granularity)
    local plugins = { checkpoint_plugin }
    for _, p in ipairs(user_plugins) do
        plugins[#plugins + 1] = p
    end

    -- ─── compile shape ─────────────────────────────────────────────
    local compiled, reason = flow_ir.compile(shape)
    if not compiled then
        local result = {
            status  = "error",
            error   = { kind = "compile_fail", message = reason },
            ctx     = ctx,
            task_id = task_id,
        }
        return plugin_chain.run_finalize(plugins, result)
    end

    -- ─── build dispatch stack (innermost outward) ───────────────────
    --
    -- safeguarded  ← raw_dispatch with safeguard counter + observer
    -- progressed   ← skip-on-progress wrapper (R5 land 軸 5)
    -- chained      ← user plugins (before / around / after)
    --
    -- checkpoint plugin is core-injected as the outermost plugin so
    -- it sees every dispatch and writes ctx snapshot after each step.

    local safeguarded = function(ref, input, dispatch_ctx)
        safeguard_mod.check_dispatch(sg)
        emitter({ phase = "start", ref = ref })
        local response = raw_dispatch(ref, input, dispatch_ctx)
        emitter({ phase = "end", ref = ref })
        return response
    end
    local progressed  = state_mod.wrap_dispatch_with_progress(safeguarded, ctx)
    local wrapped = plugin_chain.wrap_dispatch(plugins, progressed)

    local exec_opts = {
        dispatch       = wrapped,
        externs        = opts.externs,
        flows          = opts.flows,
        max_call_depth = opts.max_call_depth,
    }

    local ok, exec_err = pcall(function()
        flow_ir.exec(compiled, ctx, exec_opts)
    end)

    if not ok then
        local msg  = tostring(exec_err)
        local kind = "exec_fail"
        if msg:find("safeguard:") then kind = "safeguard_breach" end
        emitter({ phase = "error",
                  error = { kind = kind, message = msg } })
        local result = {
            status  = "error",
            error   = { kind = kind, message = msg },
            ctx     = ctx,
            task_id = task_id,
        }
        return plugin_chain.run_finalize(plugins, result)
    end

    local result = { status = "ok", ctx = ctx, task_id = task_id }
    return plugin_chain.run_finalize(plugins, result)
end

return M
