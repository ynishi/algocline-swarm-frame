---@module 'swarm_frame.v3.composites.verdict_loop'
-- Composite: verdict_loop — thin wrapper over 7 primitives that
-- reproduces the historical verdict_loop_plugin (137 行) caller IF
-- (V3 §5.8, builder-spec-v1 §8).
--
-- Compiles to:
--   swarm.loop(
--     swarm.step(opts.step, {out=opts.out, out_schema=opts.out_schema}),
--     nil,
--     {
--       max     = opts.max,
--       counter = opts.counter,
--       until_  = swarm.eq(swarm.path("$."..opts.out.."."..opts.verdict_field),
--                          swarm.lit(opts.until_token)),
--     }
--   )
--
-- Composites build IR fragments only — they do not introduce new IR
-- nodes or alter semantics (V3 §5.8 規律).

local shape = require("swarm_frame.v3.frame.shape")
local M = {}
M.VERSION = "0.0.1-v3-p6"

--- build(opts) -> Node
--- opts: {
---   step           = string,            -- agent / pkg ref dispatched per iter
---   until_token    = string,            -- verdict value that ends the loop
---   max            = integer,           -- hard iter cap (required by flow.ir)
---   counter        = string?,           -- ctx counter path (default "ctx.iter")
---   out            = string?,           -- step.out path (default "ctx.last")
---   verdict_field  = string?,           -- verdict key on response (default "verdict")
---   out_schema     = AlcShape?,         -- alc_shapes schema for step.out
--- }
function M.build(opts)
    if type(opts) ~= "table" then
        error("verdict_loop: opts table required", 2)
    end
    local step_ref = opts.step
    if type(step_ref) ~= "string" or step_ref == "" then
        error("verdict_loop: opts.step (string) required", 2)
    end
    local until_token = opts.until_token
    if type(until_token) ~= "string" then
        error("verdict_loop: opts.until_token (string) required", 2)
    end
    local max = opts.max
    if type(max) ~= "number" or max < 1 then
        error("verdict_loop: opts.max (integer >= 1) required", 2)
    end
    local out           = opts.out or "ctx.last"
    local counter       = opts.counter or "ctx.iter"
    local verdict_field = opts.verdict_field or "verdict"
    local read_path     = "$." .. out .. "." .. verdict_field

    return shape.loop(
        shape.step(step_ref, { out = out, out_schema = opts.out_schema }),
        nil,
        {
            max     = max,
            counter = counter,
            until_  = shape.eq(shape.path(read_path), shape.lit(until_token)),
        })
end

return M
