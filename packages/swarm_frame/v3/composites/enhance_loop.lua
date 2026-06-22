---@module 'swarm_frame.v3.composites.enhance_loop'
-- Composite: enhance_loop — verdict_loop + fix-carry (Quality Gate +
-- Fix + Retry with "do not repeat previous denies" memory).
--
-- The 衛生要因 (preventable failure) variant of verdict_loop. While
-- verdict_loop just retries until a token matches, enhance_loop also
-- accumulates each attempt's response into a `carry` array on ctx, so
-- the dispatch function can build the next attempt's prompt with
-- explicit "do not repeat X" / "address concern Y" instructions
-- derived from prior denies. The carry is one-way (append-only across
-- iterations); it survives the loop and is available to downstream
-- steps for trace / audit (T1 traceability + T4 prompt-modify path).
--
-- Compiles to (logical, pre-compile):
--
--   chain([
--       let(carry_path, lit({})),                -- init carry to empty array
--       loop(
--           chain([
--               step(opts.step, {
--                   in_  = path("$." .. carry_path),
--                   out  = opts.out,
--                   out_schema = opts.out_schema,
--               }),
--               let(carry_path,
--                   ext("__append_carry__",
--                       { path("$." .. carry_path), path("$." .. opts.out) })),
--           ]),
--           nil,
--           {
--               max     = opts.max,
--               counter = opts.counter,
--               until_  = eq(path("$." .. opts.out .. "." .. opts.verdict_field),
--                            lit(opts.until_token)),
--           })
--   ])
--
-- Init-to-empty rationale: flow.ir.call_extern evaluates args via
-- `table.unpack(args)`. Lua's `#` on a table with a leading nil hole
-- ({nil, x}) is implementation-defined (often 0), which would drop
-- arguments. By eagerly seeding `ctx.<carry> = {}` before the loop,
-- the path("$." .. carry) eval always returns a table — no nil hole
-- in args, no truncation.
--
-- The `__append_carry__` extern is auto-injected by runtime.run() so
-- callers do not need to wire it. It is a pure (prev_array, last) →
-- new_array function.
--
-- Composites build IR fragments only — they do not introduce new IR
-- nodes or alter semantics (V3 §5.8 規律).

local shape = require("swarm_frame.v3.frame.shape")
local M = {}
M.VERSION = "0.0.1-v3-p9"

--- build(opts) -> Node
--- opts: {
---   step           = string,            -- step.ref dispatched per iter
---   until_token    = string?,           -- verdict value ending the loop (default "pass")
---   max            = integer,           -- hard iter cap (required by flow.ir)
---   counter        = string?,           -- ctx counter path (default "ctx.iter")
---   out            = string?,           -- step.out path (default "ctx.last")
---   verdict_field  = string?,           -- verdict key on response (default "verdict")
---   carry          = string?,           -- ctx path for fix-carry array (default "ctx.fix_carry")
---   out_schema     = AlcShape?,         -- optional alc_shapes for step.out
--- }
function M.build(opts)
    if type(opts) ~= "table" then
        error("enhance_loop: opts table required", 2)
    end
    local step_ref = opts.step
    if type(step_ref) ~= "string" or step_ref == "" then
        error("enhance_loop: opts.step (string) required", 2)
    end
    local max = opts.max
    if type(max) ~= "number" or max < 1 or max ~= math.floor(max) then
        error("enhance_loop: opts.max (integer >= 1) required", 2)
    end

    local until_token   = opts.until_token   or "pass"
    local out           = opts.out           or "ctx.last"
    local counter       = opts.counter       or "ctx.iter"
    local verdict_field = opts.verdict_field or "verdict"
    local carry         = opts.carry         or "ctx.fix_carry"

    local read_verdict = "$." .. out .. "." .. verdict_field
    local read_carry   = "$." .. carry
    local read_out     = "$." .. out

    return shape.chain({
        shape.let(carry, shape.lit({})),
        shape.loop(
            shape.chain({
                shape.step(step_ref, {
                    in_        = shape.path(read_carry),
                    out        = out,
                    out_schema = opts.out_schema,
                }),
                shape.let(carry,
                    shape.ext("__append_carry__", {
                        shape.path(read_carry),
                        shape.path(read_out),
                    })),
            }),
            nil,
            {
                max     = max,
                counter = counter,
                until_  = shape.eq(shape.path(read_verdict),
                                   shape.lit(until_token)),
            }),
    })
end

return M
