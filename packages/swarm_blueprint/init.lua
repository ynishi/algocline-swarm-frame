--- swarm_blueprint — Pure Lua builder DSL for mlua-swarm-engine Blueprint JSON.
---
--- mse's Rust schema uses `#[serde(deny_unknown_fields)]` plus field renames
--- (`ref` / `in` / `then` / `else`) that collide with Lua reserved words, so
--- hand-written Lua tables are error-prone. This module is the single
--- construction path: every builder returns a plain Lua table shaped exactly
--- like the wire format mse expects, with reserved-word keys written via
--- bracket syntax (`["in"]`, `["then"]`, `["else"]`).
---
--- Architecture: two builder families (Node / Expr) mirror mse's tagged-union
--- types (`kind` tag for Node, `op` tag for Expr), plus envelope builders
--- (agent / operator / origin / blueprint). Expr-position arguments accept
--- either an already-built Expr table or a raw Lua value, auto-wrapping the
--- latter via `lit()`. This module never calls `alc.llm` and does not read
--- `ctx` — it is a pure data-construction library, `require`d by callers
--- that assemble a Blueprint before handing it to mse.

local M = {}

M.SCHEMA_VERSION = "0.1.0"

M.meta = {
    name = "swarm_blueprint",
    version = "0.1.0",
    type = "library",
    category = "frame",
    description = "Pure Lua builder DSL that constructs mlua-swarm-engine "
        .. "Blueprint JSON with exact serde field names (ref/in/then/else "
        .. "renames, deny_unknown_fields safety).",
}

-- ─── shape predicates ───────────────────────────────────────────────────────

local function is_expr(v) return type(v) == "table" and type(v.op) == "string" end

local function is_node(v) return type(v) == "table" and type(v.kind) == "string" end

local function lit(value) return { op = "lit", value = value } end

--- Coerce an Expr-position argument: pass Expr tables through unchanged,
--- reject Node tables (clear type-confusion error), and auto-wrap any other
--- raw Lua value via lit().
local function to_expr(v)
    if is_expr(v) then return v end
    if is_node(v) then
        error("swarm_blueprint: expected an Expr but received a Node (kind='" .. tostring(v.kind) .. "')", 3)
    end
    return lit(v)
end

local function require_node(v, ctx)
    if is_node(v) then return end
    if is_expr(v) then
        error("swarm_blueprint: " .. ctx .. " expected a Node but received an Expr (op='" .. tostring(v.op) .. "')", 3)
    end
    error("swarm_blueprint: " .. ctx .. " expected a Node table with a 'kind' field", 3)
end

local function require_path_string(at, fn_name)
    if type(at) ~= "string" then
        error("swarm_blueprint: " .. fn_name .. " requires a string 'at'", 3)
    end
    if at:sub(1, 1) ~= "$" then
        error("swarm_blueprint: " .. fn_name .. " 'at' must start with '$' (got '" .. at .. "')", 3)
    end
end

-- ─── Expr builders (tag field = "op") ───────────────────────────────────────

function M.path(at)
    require_path_string(at, "path")
    return { op = "path", at = at }
end

M.lit = lit

function M.exists(at)
    require_path_string(at, "exists")
    return { op = "exists", at = at }
end

function M.len(e) return { op = "len", of = to_expr(e) } end

function M.in_(needle, haystack) return { op = "in", needle = to_expr(needle), haystack = to_expr(haystack) } end

function M.not_(e) return { op = "not", operand = to_expr(e) } end

local function binary_expr(op_name)
    return function(lhs, rhs) return { op = op_name, lhs = to_expr(lhs), rhs = to_expr(rhs) } end
end

M.eq = binary_expr("eq")
M.ne = binary_expr("ne")
M.lt = binary_expr("lt")
M.le = binary_expr("le")
M.gt = binary_expr("gt")
M.ge = binary_expr("ge")
M.add = binary_expr("add")
M.sub = binary_expr("sub")
M.mul = binary_expr("mul")
M.div = binary_expr("div")

--- `bp.mod_(a, b)` — numeric modulo (Lua `%` semantics). Named with a
--- trailing underscore because `mod` collides with the `math.mod`-style
--- convention and reads awkwardly bare; unlike the shared `binary_expr`
--- helper above, this validates that both operands are present (the
--- Rust-side `Mod` variant has no meaningful single-arg reading).
function M.mod_(lhs, rhs)
    if lhs == nil or rhs == nil then
        error("swarm_blueprint: mod_ requires 'lhs' and 'rhs'", 2)
    end
    return { op = "mod", lhs = to_expr(lhs), rhs = to_expr(rhs) }
end

local function variadic_expr(op_name)
    return function(list)
        if type(list) ~= "table" then
            error("swarm_blueprint: " .. op_name .. " requires an array of Expr", 2)
        end
        local operands = {}
        for i, v in ipairs(list) do
            operands[i] = to_expr(v)
        end
        return { op = op_name, operands = operands }
    end
end

M.and_ = variadic_expr("and")
M.or_ = variadic_expr("or")

--- `bp.call_extern(ref, ...)` — canonical Hatch: invoke a host-registered
--- pure extern function by opaque key, applying it to the evaluated
--- variadic args. Raw (non-Expr) args are auto-wrapped via lit(), same as
--- every other Expr-position argument in this module. `ref` is written
--- under the bracket key `["ref"]` because `ref` collides with nothing in
--- Lua but the Rust side renames the field via `#[serde(rename = "ref")]`
--- (the struct field is `ref_`) — bracket syntax keeps the wire key exact.
function M.call_extern(ref, ...)
    if type(ref) ~= "string" or ref == "" then
        error("swarm_blueprint: call_extern requires a non-empty 'ref' (string)", 2)
    end
    local raw_args = { ... }
    local args = {}
    for i = 1, select("#", ...) do
        args[i] = to_expr(raw_args[i])
    end
    return { op = "call_extern", ["ref"] = ref, args = args }
end

-- ─── Node builders (tag field = "kind") ─────────────────────────────────────

function M.step(opts)
    opts = opts or {}
    if type(opts.ref) ~= "string" or opts.ref == "" then
        error("swarm_blueprint: step requires 'ref' (string)", 2)
    end
    if opts.in_ == nil then error("swarm_blueprint: step requires 'in_'", 2) end
    if opts.out == nil then error("swarm_blueprint: step requires 'out'", 2) end
    return { kind = "step", ref = opts.ref, ["in"] = to_expr(opts.in_), out = to_expr(opts.out) }
end

function M.seq(children)
    if type(children) ~= "table" then error("swarm_blueprint: seq requires an array of Node", 2) end
    local out = {}
    for i, child in ipairs(children) do
        require_node(child, "seq child #" .. i)
        out[i] = child
    end
    return { kind = "seq", children = out }
end

function M.branch(opts)
    opts = opts or {}
    if opts.cond == nil then error("swarm_blueprint: branch requires 'cond'", 2) end
    if opts.then_ == nil then error("swarm_blueprint: branch requires 'then_'", 2) end
    require_node(opts.then_, "branch 'then_'")
    local result = { kind = "branch", cond = to_expr(opts.cond), ["then"] = opts.then_ }
    if opts.else_ ~= nil then
        require_node(opts.else_, "branch 'else_'")
        result["else"] = opts.else_
    end
    return result
end

local VALID_JOINS = { all = true, any = true, race = true, all_settled = true }

function M.fanout(opts)
    opts = opts or {}
    if opts.items == nil then error("swarm_blueprint: fanout requires 'items'", 2) end
    if opts.bind == nil then error("swarm_blueprint: fanout requires 'bind'", 2) end
    if opts.body == nil then error("swarm_blueprint: fanout requires 'body'", 2) end
    require_node(opts.body, "fanout 'body'")
    if opts.out == nil then error("swarm_blueprint: fanout requires 'out'", 2) end
    local join = opts.join or "all"
    if not VALID_JOINS[join] then
        error(
            "swarm_blueprint: fanout 'join' must be one of "
                .. "'all'|'any'|'race'|'all_settled' (got '"
                .. tostring(join)
                .. "')",
            2
        )
    end
    return {
        kind = "fanout",
        items = to_expr(opts.items),
        bind = to_expr(opts.bind),
        body = opts.body,
        join = join,
        out = to_expr(opts.out),
    }
end

function M.loop(opts)
    opts = opts or {}
    if opts.counter == nil then error("swarm_blueprint: loop requires 'counter'", 2) end
    if opts.cond == nil then error("swarm_blueprint: loop requires 'cond'", 2) end
    if opts.body == nil then error("swarm_blueprint: loop requires 'body'", 2) end
    require_node(opts.body, "loop 'body'")
    if type(opts.max) ~= "number" or opts.max ~= math.floor(opts.max) then
        error("swarm_blueprint: loop requires 'max' (integer)", 2)
    end
    return {
        kind = "loop",
        counter = to_expr(opts.counter),
        cond = to_expr(opts.cond),
        body = opts.body,
        max = opts.max,
    }
end

function M.try_(opts)
    opts = opts or {}
    if opts.body == nil then error("swarm_blueprint: try_ requires 'body'", 2) end
    require_node(opts.body, "try_ 'body'")
    if opts.catch == nil then error("swarm_blueprint: try_ requires 'catch'", 2) end
    require_node(opts.catch, "try_ 'catch'")
    local result = { kind = "try", body = opts.body, catch = opts.catch }
    if opts.err_at ~= nil then result.err_at = to_expr(opts.err_at) end
    return result
end

function M.assign(opts)
    opts = opts or {}
    if opts.at == nil then error("swarm_blueprint: assign requires 'at'", 2) end
    if opts.value == nil then error("swarm_blueprint: assign requires 'value'", 2) end
    return { kind = "assign", at = to_expr(opts.at), value = to_expr(opts.value) }
end

-- ─── Agent / Operator builders ──────────────────────────────────────────────

local VALID_AGENT_KINDS = { lua = true, rust_fn = true, agent_block = true, subprocess = true, operator = true }
local VALID_OPERATOR_KINDS = { main_ai = true, automate = true, composite = true }

local function build_agent_profile(p)
    local profile = { system_prompt = p.system_prompt or "" }
    if p.model ~= nil then profile.model = p.model end
    if p.effort ~= nil then profile.effort = p.effort end
    if p.tools ~= nil and next(p.tools) ~= nil then profile.tools = p.tools end
    if p.description ~= nil then profile.description = p.description end
    return profile
end

function M.agent(opts)
    opts = opts or {}
    if type(opts.name) ~= "string" or opts.name == "" then
        error("swarm_blueprint: agent requires 'name' (string)", 2)
    end
    if type(opts.kind) ~= "string" or not VALID_AGENT_KINDS[opts.kind] then
        error(
            "swarm_blueprint: agent 'kind' must be one of "
                .. "'lua'|'rust_fn'|'agent_block'|'subprocess'|'operator' (got '"
                .. tostring(opts.kind)
                .. "')",
            2
        )
    end
    local result = { name = opts.name, kind = opts.kind, spec = opts.spec or {} }
    if opts.profile ~= nil then result.profile = build_agent_profile(opts.profile) end
    if opts.meta ~= nil then result.meta = opts.meta end
    return result
end

function M.operator(opts)
    opts = opts or {}
    if type(opts.name) ~= "string" or opts.name == "" then
        error("swarm_blueprint: operator requires 'name' (string)", 2)
    end
    local result = { name = opts.name }
    if opts.kind ~= nil then
        if not VALID_OPERATOR_KINDS[opts.kind] then
            error(
                "swarm_blueprint: operator 'kind' must be one of "
                    .. "'main_ai'|'automate'|'composite' (got '"
                    .. tostring(opts.kind)
                    .. "')",
                2
            )
        end
        result.kind = opts.kind
    end
    if opts.spec ~= nil and next(opts.spec) ~= nil then result.spec = opts.spec end
    if opts.display_name ~= nil then result.display_name = opts.display_name end
    return result
end

-- ─── origin helpers (metadata.origin) ───────────────────────────────────────

function M.origin_algo(session_id)
    if type(session_id) ~= "string" or session_id == "" then
        error("swarm_blueprint: origin_algo requires 'session_id' (string)", 2)
    end
    return { kind = "algo", session_id = session_id }
end

function M.origin_inline() return { kind = "inline" } end

function M.origin_file(path)
    if type(path) ~= "string" or path == "" then
        error("swarm_blueprint: origin_file requires 'path' (string)", 2)
    end
    return { kind = "file", path = path }
end

-- ─── Blueprint envelope ──────────────────────────────────────────────────────

--- Assemble the top-level Blueprint envelope. `origin` / `description` /
--- `tags` are folded into `metadata`; any keys under `opts` are shallow-
--- merged onto the envelope top level (pass-through for hints / strategy /
--- spawner_hints / default_agent_kind / default_operator_kind — fields that
--- carry serde defaults and are otherwise omitted).
function M.blueprint(opts)
    opts = opts or {}
    if type(opts.id) ~= "string" or opts.id == "" then
        error("swarm_blueprint: blueprint requires 'id' (string)", 2)
    end
    if opts.flow == nil then error("swarm_blueprint: blueprint requires 'flow'", 2) end
    require_node(opts.flow, "blueprint 'flow'")

    local result = {
        schema_version = M.SCHEMA_VERSION,
        id = opts.id,
        flow = opts.flow,
    }

    if opts.agents ~= nil and next(opts.agents) ~= nil then result.agents = opts.agents end
    if opts.operators ~= nil and next(opts.operators) ~= nil then result.operators = opts.operators end

    local metadata = {}
    local has_metadata = false
    if opts.description ~= nil then
        metadata.description = opts.description
        has_metadata = true
    end
    if opts.origin ~= nil then
        metadata.origin = opts.origin
        has_metadata = true
    end
    if opts.tags ~= nil and next(opts.tags) ~= nil then
        metadata.tags = opts.tags
        has_metadata = true
    end
    if has_metadata then result.metadata = metadata end

    if opts.opts ~= nil then
        for k, v in pairs(opts.opts) do
            result[k] = v
        end
    end

    return result
end

return M
