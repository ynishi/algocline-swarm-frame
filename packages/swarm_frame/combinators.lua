--- swarm_frame.combinators — control-flow Handler factories.
---
--- Each factory takes an opts table, validates it against an lshape schema
--- registered under "SwarmFrame.*" in lshape.check.default_registry, and
--- returns a Handler: `fun(ctx, spec?) -> response`.
---
--- Returned handlers satisfy the existing run_linear handler contract, so
--- they can be passed directly to `frame.register(path, spec, handler)` or
--- composed inside other combinators (sequence inside verdict_loop, etc.).
---
--- Engine boundary:
---   * Mechanism (this file): iteration, predicate evaluation, cp_state
---     idempotent persistence, verdict short-circuit.
---   * Policy (caller): which handler to invoke, what verdict shape means
---     (parser predicate), what fix logic to run.
---
--- cp_state idempotent contract:
---   When `cp_key` is supplied, the combinator persists progress via
---   `ctx.state:set(cp_key, value)` + `ctx.state:commit()` so a resumed
---   session can pick up where it left off. The Engine never reads
---   ctx.cp_state directly — it goes through the State abstraction.

local M = {}

local shapes -- lazy require to avoid a load-order cycle with init.lua

local function _shapes()
    if not shapes then shapes = require("swarm_frame.combinator_shapes") end
    return shapes
end

-- Validate combinator opts. Uses the swarm_frame.validate 3-mode wrapper
-- when the parent module is available, otherwise falls back to lshape's
-- assert directly. The fallback keeps this module loadable in isolation
-- (e.g. spec files that require combinators before init.lua finishes).
local function _validate(value, schema, ctx_hint)
    local ok_frame, frame = pcall(require, "swarm_frame")
    if ok_frame and type(frame.validate) == "function" then
        return frame.validate(value, schema, ctx_hint)
    end
    local check = require("lshape.check")
    return check.assert(value, schema, ctx_hint)
end

-- Invoke a handler with consistent (ctx, spec) shape. Callable tables are
-- supported (lshape Handler = T.any_of({fn, table})).
local function _call(handler, ctx, spec)
    if type(handler) == "function" then return handler(ctx, spec) end
    if type(handler) == "table" then
        local mt = getmetatable(handler)
        if mt and type(mt.__call) == "function" then return handler(ctx, spec) end
    end
    error("swarm_frame.combinators: handler is not callable (got " .. type(handler) .. ")")
end

-- cp_state helpers go through state:get/:set/:commit so the Engine never
-- touches ctx.cp_state directly (mechanism stays decoupled from flow's
-- persistence shape).
local function _cp_get(ctx, cp_key, default)
    if not cp_key or not ctx or not ctx.state then return default end
    local v = ctx.state:get(cp_key)
    if v == nil then return default end
    return v
end

local function _cp_set(ctx, cp_key, value)
    if not cp_key or not ctx or not ctx.state then return end
    ctx.state:set(cp_key, value)
    ctx.state:commit()
end

-- Short-circuit detector. We parse the response with the existing
-- parse_verdict and return its status. A non-DONE status from any sub-
-- handler causes the surrounding combinator to short-circuit and return
-- that raw response so run_linear's caller can apply its next_action
-- mapping (BLOCKED -> halt, NEEDS_INPUT -> escalate).
local function _is_done(response)
    local ok_frame, frame = pcall(require, "swarm_frame")
    if not ok_frame then return true end -- conservative fallback
    local v = frame.parse_verdict(response)
    return v.status == "DONE"
end

-- ─── sequence ───────────────────────────────────────────────────────────────

function M.sequence(opts)
    -- Allow either `frame.sequence({h1, h2, h3})` (plain array) or the
    -- explicit `{handlers = {...}, cp_key = ...}` shape. We canonicalize
    -- to the explicit form before validating so the schema is single-form.
    if type(opts) == "table" and opts.handlers == nil then
        local has_array = false
        for i = 1, #opts do
            has_array = true
            break
        end
        if has_array then opts = { handlers = opts } end
    end
    opts = _validate(opts, _shapes().SequenceOpts, "swarm_frame.sequence")
    local handlers = opts.handlers
    local cp_key = opts.cp_key

    return function(ctx, spec)
        local start_index = _cp_get(ctx, cp_key, 0) + 1
        local last_response
        for i = start_index, #handlers do
            local response = _call(handlers[i], ctx, spec)
            last_response = response
            if not _is_done(response) then
                -- Short-circuit: propagate the non-DONE response without
                -- marking i as completed (so a future resume retries it).
                return response
            end
            _cp_set(ctx, cp_key, i)
        end
        -- Reset cp_state on full completion so a subsequent re-entry
        -- starts fresh from index 1.
        if cp_key then _cp_set(ctx, cp_key, 0) end
        return last_response or "DONE path=sequence"
    end
end

-- ─── loop ───────────────────────────────────────────────────────────────────

function M.loop(opts)
    opts = _validate(opts, _shapes().LoopOpts, "swarm_frame.loop")
    local body = opts.body
    local until_ = opts.until_
    local max = opts.max
    local cp_key = opts.cp_key

    return function(ctx, spec)
        local start_iter = _cp_get(ctx, cp_key, 0) + 1
        local last_response
        for iter = start_iter, max do
            local response = _call(body, ctx, spec)
            last_response = response
            _cp_set(ctx, cp_key, iter)
            if until_(ctx, response) then
                if cp_key then _cp_set(ctx, cp_key, 0) end
                return response
            end
        end
        -- Hit the safety cap without satisfying until_. Returning the last
        -- response lets the caller's verdict parser decide whether the
        -- final attempt counts as DONE / BLOCKED.
        return last_response or "BLOCKED reason=swarm_frame.loop max iterations reached"
    end
end

-- ─── branch ─────────────────────────────────────────────────────────────────

function M.branch(opts)
    opts = _validate(opts, _shapes().BranchOpts, "swarm_frame.branch")
    local cond = opts.cond
    local then_ = opts.then_
    local else_ = opts.else_

    return function(ctx, spec)
        if cond(ctx) then return _call(then_, ctx, spec) end
        if else_ then return _call(else_, ctx, spec) end
        -- No else_ supplied and cond was falsy: synthesize a no-op DONE
        -- so run_linear treats the branch as a successful step.
        return "DONE path=branch_noop"
    end
end

-- ─── verdict_loop ───────────────────────────────────────────────────────────

function M.verdict_loop(opts)
    opts = _validate(opts, _shapes().VerdictLoopOpts, "swarm_frame.verdict_loop")
    local gate = opts.gate
    local fix = opts.fix
    local parser = opts.parser
    local max_retries = opts.max_retries
    local cp_key = opts.cp_key

    return function(ctx, spec)
        local start_attempt = _cp_get(ctx, cp_key, 0) + 1
        local max_attempts = max_retries + 1
        local last_response
        for attempt = start_attempt, max_attempts do
            local response = _call(gate, ctx, spec)
            last_response = response
            if parser(response) then
                if cp_key then _cp_set(ctx, cp_key, 0) end
                return response
            end
            _cp_set(ctx, cp_key, attempt)
            if attempt < max_attempts and fix then _call(fix, ctx, spec) end
        end
        return last_response or "BLOCKED reason=swarm_frame.verdict_loop exhausted"
    end
end

return M
