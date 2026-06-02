--- swarm_frame.combinator_shapes — lshape schemas for the four control-flow
--- combinators (sequence / loop / branch / verdict_loop).
---
--- Each schema is registered into `lshape.check.default_registry` under a
--- "SwarmFrame.*" name so validation error messages cite the schema by name
--- rather than dumping the entire shape inline.
---
--- Loaded lazily: `require("swarm_frame.combinator_shapes")` returns a table
--- of named schemas AND, as a side-effect, populates the lshape registry.
--- Re-requiring is idempotent (the registry insert is keyed by string name).
---
--- Handler contract (shared by all combinators):
---   A handler is `fun(ctx: table, spec: table?): string|table`.
---   We allow `T.fn` for plain Lua functions AND `T.table` for callable
---   tables (combinator factories return tables wrapping closures so
---   handlers can carry metadata for introspection).

local M = {}

local ok_lshape, lshape = pcall(require, "lshape")
if not ok_lshape then
    error("swarm_frame.combinator_shapes: lshape not available (install via alc_pkg_link)")
end
local T = lshape.t

-- Handler = function OR callable table (combinator nesting passes tables).
local Handler = T.any_of({ T.fn, T.table }):describe("Handler: fun(ctx, spec?) -> response | callable table")

M.Handler = Handler

-- ─── SequenceOpts ───────────────────────────────────────────────────────────
--
-- A sequence is a non-empty list of handlers run in order. Each handler's
-- verdict is parsed by the Engine; non-DONE short-circuits and propagates
-- ctx.result upward (same contract as run_linear).
M.SequenceOpts = T.shape({
    handlers = T.array_of(Handler):describe("handlers: ordered list of Handler"),
    cp_key   = T.string:is_optional():describe("cp_state idempotent resume key (optional)"),
}, { open = false })

-- ─── LoopOpts ───────────────────────────────────────────────────────────────
--
-- A loop runs `body` repeatedly until either `until_(ctx, response)` returns
-- truthy OR the iteration count reaches `max`. The Engine enforces `max` as
-- a hard safety net (no infinite loops, even with a buggy predicate).
M.LoopOpts = T.shape({
    body   = Handler:describe("body: Handler invoked each iteration"),
    until_ = T.fn:describe("until_(ctx, response) -> bool predicate; true exits"),
    max    = T.number:describe("max iteration count (safety net, required)"),
    cp_key = T.string:is_optional():describe("cp_state idempotent resume key (optional)"),
}, { open = false })

-- ─── BranchOpts ─────────────────────────────────────────────────────────────
--
-- A branch evaluates `cond(ctx)` once and dispatches to `then_` (truthy)
-- or `else_` (falsy). When `else_` is omitted and cond is falsy, the
-- branch returns a synthetic DONE verdict so run_linear treats it as a
-- no-op success.
M.BranchOpts = T.shape({
    cond  = T.fn:describe("cond(ctx) -> bool selector"),
    then_ = Handler:describe("then_: Handler on truthy cond"),
    ["else_"] = Handler:is_optional():describe("else_: Handler on falsy cond (optional)"),
}, { open = false })

-- ─── VerdictLoopOpts ────────────────────────────────────────────────────────
--
-- The verdict_loop runs `gate` up to `max_retries + 1` times. After each
-- failed attempt (parser returns falsy) the optional `fix` handler runs
-- to remediate. Engine records the attempt count via cp_key for resume
-- continuity.
--
-- Engine boundary: `parser` is the only domain-aware piece here — it
-- decides what a gate response means. The Engine never inspects the
-- response itself. Application owns the parser, Engine owns the loop.
M.VerdictLoopOpts = T.shape({
    gate        = Handler:describe("gate: Handler producing a quality verdict"),
    fix         = Handler:is_optional():describe("fix: Handler invoked when gate fails (optional)"),
    parser      = T.fn:describe("parser(response) -> bool; true = pass"),
    max_retries = T.number:describe("max_retries: retry budget after first attempt"),
    cp_key      = T.string:is_optional():describe("cp_state idempotent resume key (optional)"),
}, { open = false })

-- ─── Registry binding ───────────────────────────────────────────────────────
--
-- Bind schemas into lshape.check.default_registry so error messages can
-- cite "SwarmFrame.VerdictLoopOpts" instead of dumping the entire shape.
-- Idempotent: rebinding an existing key with the same schema is a no-op
-- in semantics (subsequent require() calls overwrite with the same value).

local check_ok, check = pcall(require, "lshape.check")
if check_ok then
    check.default_registry = check.default_registry or {}
    check.default_registry["SwarmFrame.Handler"]         = M.Handler
    check.default_registry["SwarmFrame.SequenceOpts"]    = M.SequenceOpts
    check.default_registry["SwarmFrame.LoopOpts"]        = M.LoopOpts
    check.default_registry["SwarmFrame.BranchOpts"]      = M.BranchOpts
    check.default_registry["SwarmFrame.VerdictLoopOpts"] = M.VerdictLoopOpts
end

return M
