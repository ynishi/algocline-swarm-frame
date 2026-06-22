---@module 'swarm_frame.v3.composites.escalate_gate'
-- Composite: escalate_gate — gate-with-halt-on-block primitive.
--
-- Runs a step, then short-circuits to an "escalate" raise when the
-- response verdict matches the blocked_token AND no decision has been
-- injected at resume_key yet. The raise propagates "escalate:" through
-- the runtime exec_err handler, which maps it to kind="escalate_required"
-- → state.lua finalize maps that kind to STATUS.INTERRUPTED.
--
-- Resume contract: the caller (Human / Main AI / SubAgent / other
-- strategy) injects a value at resume_key (default "ctx.escalation_decision")
-- before re-running with the same task_id. On re-run, the step is
-- short-circuited via wrap_dispatch_with_progress (cached at_path), and
-- the route condition sees the decision value (truthy) so the escalate
-- branch is skipped.
--
-- Compiles to:
--   chain([
--     step(opts.step, {out=opts.out, out_schema=opts.out_schema}),
--     route(
--       and_(
--         eq(path("$."..out.."."..verdict_field), lit(blocked_token)),
--         not_(path("$."..resume_key))
--       ),
--       let("ctx._escalate_void",
--           ext("__escalate__", { path("$."..out) })),
--       nil
--     )
--   ])
--
-- Composites build IR fragments only — they do not introduce new IR
-- nodes or alter semantics (V3 §5.8 規律). The __escalate__ extern is
-- auto-injected by runtime.run() so callers do not need to wire it.

local shape = require("swarm_frame.v3.frame.shape")
local M = {}
M.VERSION = "0.0.1-v3-p9"

--- build(opts) -> Node
--- opts: {
---   step           = string,            -- agent / pkg ref dispatched once per run
---   max?           = integer,            -- (carry, currently unused — escalate is one-shot)
---   out            = string?,            -- step.out path (default "ctx.last")
---   verdict_field  = string?,            -- verdict key on response (default "verdict")
---   blocked_token  = string?,            -- verdict value that triggers escalate (default "blocked")
---   resume_key     = string?,            -- ctx path where caller injects decision
---                                        --   (default "ctx.escalation_decision")
---   out_schema     = AlcShape?,          -- alc_shapes schema for step.out
--- }
function M.build(opts)
    if type(opts) ~= "table" then
        error("escalate_gate: opts table required", 2)
    end
    local step_ref = opts.step
    if type(step_ref) ~= "string" or step_ref == "" then
        error("escalate_gate: opts.step (string) required", 2)
    end
    local out           = opts.out or "ctx.last"
    local verdict_field = opts.verdict_field or "verdict"
    local blocked_token = opts.blocked_token or "blocked"
    local resume_key    = opts.resume_key or "ctx.escalation_decision"

    local verdict_path = "$." .. out .. "." .. verdict_field
    local decision_path = "$." .. resume_key
    local payload_path  = "$." .. out

    return shape.chain({
        shape.step(step_ref, { out = out, out_schema = opts.out_schema }),
        shape.route(
            shape.and_({
                shape.eq(shape.path(verdict_path), shape.lit(blocked_token)),
                shape.not_(shape.path(decision_path)),
            }),
            shape.let("ctx._escalate_void",
                shape.ext("__escalate__", { shape.path(payload_path) })),
            nil
        ),
    })
end

return M
