---@module 'swarm_frame.v3.composites.aggregate'
-- Composite: aggregate — thin wrapper over 7 primitives that
-- reproduces the historical swarm_aggregate_plugin (229 行) caller IF
-- (V3 §5.8, builder-spec-v1 §8).
--
-- Compiles to a chain of [fan, let(ext)]:
--   swarm.chain({
--     swarm.fan(
--       swarm.step(opts.step, {in_=swarm.path("$."..opts.bind), out=opts.body_out}),
--       opts.items,
--       {bind=opts.bind, out=opts.fan_out, join=opts.join}),
--     swarm.let(opts.out, swarm.ext(opts.reducer, {swarm.path("$."..opts.fan_out)})),
--   })

local shape = require("swarm_frame.v3.frame.shape")
local M = {}
M.VERSION = "0.0.1-v3-p6"

--- build(opts) -> Node
--- opts: {
---   step      = string,             -- per-item agent / pkg ref
---   items     = Expr,               -- Expr evaluating to a list
---   reducer   = string,             -- pure fn key registered in externs
---   out       = string,             -- aggregated result write path (e.g. "ctx.consensus")
---   bind      = string?,            -- per-branch item ctx path (default "ctx.item")
---   body_out  = string?,            -- per-branch step.out path (default "ctx.r")
---   fan_out   = string?,            -- fan join result path (default "ctx.fan_result")
---   join      = string?,            -- "all" | "any" | "race" | "all_settled" (default "all")
--- }
function M.build(opts)
    if type(opts) ~= "table" then
        error("aggregate: opts table required", 2)
    end
    local step_ref = opts.step
    if type(step_ref) ~= "string" or step_ref == "" then
        error("aggregate: opts.step (string) required", 2)
    end
    if opts.items == nil then
        error("aggregate: opts.items (Expr) required", 2)
    end
    local reducer = opts.reducer
    if type(reducer) ~= "string" or reducer == "" then
        error("aggregate: opts.reducer (string, registered in externs) required", 2)
    end
    local out = opts.out
    if type(out) ~= "string" or out == "" then
        error("aggregate: opts.out (string) required", 2)
    end
    local bind     = opts.bind     or "ctx.item"
    local body_out = opts.body_out or "ctx.r"
    local fan_out  = opts.fan_out  or "ctx.fan_result"
    local join     = opts.join     or "all"

    return shape.chain({
        shape.fan(
            shape.step(step_ref, {
                in_ = shape.path("$." .. bind),
                out = body_out,
            }),
            opts.items,
            { bind = bind, out = fan_out, join = join }),
        shape.let(out,
            shape.ext(reducer, { shape.path("$." .. fan_out) })),
    })
end

return M
