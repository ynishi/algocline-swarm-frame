---@module 'swarm_frame.v3.frame.shape'
-- Pure constructors that return flow.ir Node / Expr Def fragments.
-- No compile / exec — those are flow.ir's responsibility. This module
-- only builds plain Lua tables and is host-neutral.
--
-- Surface (V3 §5.2):
--   Builder primitives (7): step / chain / fan / loop / route / let / call
--   Expr DSL (9):           path / lit / eq / and_ / or_ / not_ / lt / len / ext
--
-- Design purity (V3 §5.3.1 R8 land): builder is a flow.ir compile-only
-- layer. Each constructor returns a plain Lua table; no semantic
-- enrichment is added on top of flow.ir. flow.ir.compile is the gate
-- for required-field validation. Builder-side raises only for
-- mutually-exclusive opts (e.g. swarm.loop cond/until_).

local M = {}
M.VERSION = "0.0.1-v3-p2"

-- ── Builder primitives (7) ──────────────────────────────────────────

--- step(ref, opts?) -> Node
--- opts: { in_? = Expr, out? = string, out_schema? = AlcShape }
--- in_ omitted -> dispatch receives nil input (R8 land, V3 §5.3.1).
function M.step(ref, opts)
    opts = opts or {}
    return {
        kind       = "step",
        ref        = ref,
        in_        = opts.in_,
        out        = opts.out,
        out_schema = opts.out_schema,
    }
end

--- chain(children) -> Node (seq)
function M.chain(children)
    return { kind = "seq", children = children }
end

--- fan(body, items, opts?) -> Node (fanout)
--- opts: { bind? = string, out? = string, join? = "all"|"any"|"race"|"all_settled" }
function M.fan(body, items, opts)
    opts = opts or {}
    return {
        kind  = "fanout",
        items = items,
        bind  = opts.bind,
        body  = body,
        join  = opts.join,
        out   = opts.out,
    }
end

--- loop(body, cond, opts?) -> Node
--- opts: { max? = integer, counter? = string, until_? = Expr }
--- cond and opts.until_ are mutually exclusive (V3 §5.3.2). When until_
--- is provided, cond is synthesized as not_(until_) — flow.ir loops are
--- while-style, so until-semantics is sugar.
function M.loop(body, cond, opts)
    opts = opts or {}
    local has_cond  = cond ~= nil
    local has_until = opts.until_ ~= nil
    if has_cond and has_until then
        error("swarm.loop: cond and until_ are mutually exclusive (V3 §5.3.2)", 2)
    end
    if not has_cond and not has_until then
        error("swarm.loop: one of cond or until_ is required", 2)
    end
    local actual_cond = cond
    if has_until then
        actual_cond = { op = "not", arg = opts.until_ }
    end
    return {
        kind    = "loop",
        cond    = actual_cond,
        body    = body,
        max     = opts.max,
        counter = opts.counter,
    }
end

--- route(cond, then_, else_?) -> Node (branch)
function M.route(cond, then_, else_)
    return {
        kind  = "branch",
        cond  = cond,
        then_ = then_,
        else_ = else_,
    }
end

--- let(at, value) -> Node
function M.let(at, value)
    return {
        kind  = "let",
        at    = at,
        value = value,
    }
end

--- call(flow_name, args, opts?) -> Node
--- opts: { out? = string }
function M.call(flow_name, args, opts)
    opts = opts or {}
    return {
        kind = "call",
        flow = flow_name,
        args = args,
        out  = opts.out,
    }
end

-- ── Expr DSL (9) ────────────────────────────────────────────────────

--- path(at) -> Expr
function M.path(at)
    return { op = "path", at = at }
end

--- lit(value) -> Expr
function M.lit(value)
    return { op = "lit", value = value }
end

--- eq(lhs, rhs) -> Expr
function M.eq(lhs, rhs)
    return { op = "eq", lhs = lhs, rhs = rhs }
end

--- and_(args) -> Expr (length >= 2 per flow.ir schema)
function M.and_(args)
    if type(args) ~= "table" or #args < 2 then
        error("swarm.and_: requires array of >= 2 Exprs (V3 §5.2.2)", 2)
    end
    return { op = "and", args = args }
end

--- or_(args) -> Expr (length >= 2 per flow.ir schema)
function M.or_(args)
    if type(args) ~= "table" or #args < 2 then
        error("swarm.or_: requires array of >= 2 Exprs (V3 §5.2.2)", 2)
    end
    return { op = "or", args = args }
end

--- not_(arg) -> Expr
function M.not_(arg)
    return { op = "not", arg = arg }
end

--- lt(lhs, rhs) -> Expr
function M.lt(lhs, rhs)
    return { op = "lt", lhs = lhs, rhs = rhs }
end

--- len(arg) -> Expr
function M.len(arg)
    return { op = "len", arg = arg }
end

--- ext(ref, args) -> Expr (call_extern, pure function whitelist)
--- args MUST be an array (possibly empty for nullary). caller code:
---   swarm.let("ctx.normalized",
---             swarm.ext("normalize_panel", { swarm.path("$.ctx.candidates") }))
function M.ext(ref, args)
    if type(ref) ~= "string" or ref == "" then
        error("swarm.ext: ref must be a non-empty string", 2)
    end
    args = args or {}
    return { op = "call_extern", ref = ref, args = args }
end

return M
