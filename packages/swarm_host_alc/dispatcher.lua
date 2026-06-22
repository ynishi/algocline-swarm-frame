---@module 'swarm_host_alc.dispatcher'
-- Token & Prompt round-trip dispatcher factory for swarm_frame V3.
--
-- V3 reframe (互換性なし、 clean restart): rebuilds the dispatcher
-- factory previously held in swarm_frame_algocline.make_dispatcher
-- (1084 lines) under a structured-IF discipline:
--
--   * opts.builder / opts.flow_state / opts.pkg_name (required)
--   * opts.deps = {flow, frame, alc, json_decode} (1-field DI seam, #1)
--   * opts.flow_state was opts.state — renamed to avoid clash with V3
--     §6 `state = {task_id, force_fresh, ...}` (#2)
--   * opts.pkg_name closure-fixed (was finalize(opts.pkg_name), #4)
--   * opts.llm_opts_base (was opts.llm_opts, #6 — overlay channel
--     contrast clarified)
--   * opts.safeguard via swarm_host_alc.safeguard.merge (#7)
--   * opts.plugins = list of structured plugins:
--       { name, hooks = { before_dispatch?, around_dispatch?,
--                         after_dispatch?, before_step?, around_step?,
--                         after_step?, finalize? },
--         writes = { spec?, state?, step? } }   (#10)
--   * dispatcher.writes = { spec, state, step } 1-field expose (#5)
--   * ctx fresh table per __call (#9), helpers sub-table (#3 撤去 ctx.frame)
--   * dispatch nil/false → explicit error (#11 silent ""化 撤廃)
--   * dispatcher_iface.check_call(callable_table) pass (#8b)
--
-- Step 6.1 lands skeleton + validation + writes registry.
-- Step 6.2 lands core_dispatch (4 helper orchestrate).
-- Step 6.3 lands dispatch_chain + ctx.llm_call factory + ctx fresh-table builder.
-- Step 6.4 lands finalize (Card primitive 2-phase staged commit).
-- Step 6.5 lands __call lifecycle (before/around/after_step + ctx.dispatch
--   recursive + safeguard counters + step-skip path + response #11 + cleanup #9 撤廃).
-- V3 clean restart COMPLETE at Step 6.5.

local M = {}
M.VERSION = "0.1.0-v3-p5"

M.meta = {
    name = "swarm_host_alc.dispatcher",
    version = M.VERSION,
    category = "frame",
    description = "Token & Prompt round-trip dispatcher factory for "
        .. "swarm_frame V3 (clean restart, structured IF, complete).",
}

local safeguard_mod  = require("swarm_host_alc.safeguard")
local prompt_builder = require("swarm_host_alc.prompt_builder")
local check_mode     = require("swarm_host_alc.check_mode")

local HOOK_NAMES = {
    "before_dispatch", "around_dispatch", "after_dispatch",
    "before_step",     "around_step",     "after_step",
    "finalize",
}

local WRITES_AXES = { "spec", "state", "step" }

local function _validate_plugin(p, i)
    if type(p) ~= "table" then
        error("swarm_host_alc.dispatcher: plugins[" .. i
            .. "] must be a table (got " .. type(p) .. ")")
    end
    if type(p.name) ~= "string" or p.name == "" then
        error("swarm_host_alc.dispatcher: plugins[" .. i
            .. "].name must be a non-empty string")
    end
    if p.hooks ~= nil then
        if type(p.hooks) ~= "table" then
            error("swarm_host_alc.dispatcher: plugins[" .. i
                .. "].hooks must be a table or nil (got "
                .. type(p.hooks) .. ")")
        end
        for _, hk in ipairs(HOOK_NAMES) do
            if p.hooks[hk] ~= nil and type(p.hooks[hk]) ~= "function" then
                error("swarm_host_alc.dispatcher: plugins[" .. i
                    .. "].hooks." .. hk .. " must be a function or nil "
                    .. "(got " .. type(p.hooks[hk]) .. ")")
            end
        end
    end
    if p.writes ~= nil then
        if type(p.writes) ~= "table" then
            error("swarm_host_alc.dispatcher: plugins[" .. i
                .. "].writes must be a table or nil (got "
                .. type(p.writes) .. ")")
        end
        for _, axis in ipairs(WRITES_AXES) do
            local list = p.writes[axis]
            if list ~= nil then
                if type(list) ~= "table" then
                    error("swarm_host_alc.dispatcher: plugins[" .. i
                        .. "].writes." .. axis
                        .. " must be a list of strings or nil (got "
                        .. type(list) .. ")")
                end
                for j, item in ipairs(list) do
                    if type(item) ~= "string" or item == "" then
                        error("swarm_host_alc.dispatcher: plugins[" .. i
                            .. "].writes." .. axis .. "[" .. j
                            .. "] must be a non-empty string")
                    end
                    if axis == "state" and not item:match("^_") then
                        error("swarm_host_alc.dispatcher: plugins[" .. i
                            .. "].writes.state[" .. j .. "]=" .. item
                            .. " must start with '_' (state.data._* "
                            .. "namespace convention)")
                    end
                end
            end
        end
    end
end

local function _build_writes_registry(plugins, deps)
    local registry = { spec = {}, state = {}, step = {} }
    for _, p in ipairs(plugins) do
        if p.writes then
            for _, axis in ipairs(WRITES_AXES) do
                local list = p.writes[axis]
                if list then
                    for _, field in ipairs(list) do
                        registry[axis][field] = registry[axis][field] or {}
                        table.insert(registry[axis][field], p.name)
                    end
                end
            end
        end
    end
    local alc = deps and deps.alc
    if alc and type(alc.log) == "function" then
        for _, axis in ipairs(WRITES_AXES) do
            for field, owners in pairs(registry[axis]) do
                if #owners > 1 then
                    alc.log("warn",
                        "swarm_host_alc.dispatcher: writes." .. axis
                        .. " collision on '" .. field
                        .. "' declared by " .. #owners
                        .. " plugins: " .. table.concat(owners, ", "))
                end
            end
        end
    end
    return registry
end

-- ─── core_dispatch (Step 6.2) ─────────────────────────────────────────

local function _validate_core_dispatch_state(state)
    if type(state) ~= "table" then
        error("swarm_host_alc.dispatcher._build_core_dispatch: state "
            .. "must be a table (got " .. type(state) .. ")")
    end
    if type(state.builder) ~= "function" then
        error("swarm_host_alc.dispatcher._build_core_dispatch: "
            .. "state.builder must be a function (got "
            .. type(state.builder) .. ")")
    end
    if type(state.frame_pkg) ~= "table"
        or type(state.frame_pkg.check_mode) ~= "function" then
        error("swarm_host_alc.dispatcher._build_core_dispatch: "
            .. "state.frame_pkg.check_mode must be a function")
    end
    if type(state.flow_state) ~= "table" then
        error("swarm_host_alc.dispatcher._build_core_dispatch: "
            .. "state.flow_state must be a table (got "
            .. type(state.flow_state) .. ")")
    end
end

local function _build_core_dispatch(state)
    _validate_core_dispatch_state(state)
    local builder       = state.builder
    local llm_opts_base = state.llm_opts_base
    local frame_pkg     = state.frame_pkg
    local alc_pkg       = state.alc_pkg
    local flow_pkg      = state.flow_pkg
    local flow_state    = state.flow_state

    return function(spec, ctx)
        if type(ctx) ~= "table" or type(ctx.step) ~= "string" then
            error("swarm_host_alc.dispatcher.core_dispatch: "
                .. "ctx.step must be a string")
        end
        local prompt = prompt_builder.invoke(builder, ctx.step, spec)
        local overlay = nil
        if type(spec) == "table" then overlay = spec.llm_opts_overlay end
        local effective = prompt_builder.merge_llm_opts(
            llm_opts_base, overlay, ctx.step)
        local mode = frame_pkg.check_mode()
        local response = check_mode.route_llm(
            prompt, effective, ctx.step,
            { mode = mode, alc = alc_pkg, flow = flow_pkg, state = flow_state })
        if mode == "format" then
            local json_decode = alc_pkg and alc_pkg.json_decode
            response = check_mode.format_postverify(
                response, ctx.step, { json_decode = json_decode })
        end
        return response
    end
end

M._for_test = M._for_test or {}
M._for_test.build_core_dispatch = _build_core_dispatch

-- ─── dispatch_chain (Step 6.3) ────────────────────────────────────────

local function _validate_dispatch_chain_state(state)
    if type(state) ~= "table" then
        error("swarm_host_alc.dispatcher._build_dispatch_chain: state "
            .. "must be a table (got " .. type(state) .. ")")
    end
    if type(state.core_dispatch) ~= "function" then
        error("swarm_host_alc.dispatcher._build_dispatch_chain: "
            .. "state.core_dispatch must be a function (got "
            .. type(state.core_dispatch) .. ")")
    end
    if type(state.plugins) ~= "table" then
        error("swarm_host_alc.dispatcher._build_dispatch_chain: "
            .. "state.plugins must be a list (got "
            .. type(state.plugins) .. ")")
    end
end

local function _build_dispatch_chain(state)
    _validate_dispatch_chain_state(state)
    local core_dispatch = state.core_dispatch
    local plugins = state.plugins

    local wrapped = core_dispatch
    for i = #plugins, 1, -1 do
        local p = plugins[i]
        local around = p.hooks and p.hooks.around_dispatch
        if around then
            local inner = wrapped
            wrapped = function(s, c) return around(inner, s, c) end
        end
    end
    local wrapped_ref = wrapped

    return function(spec, ctx)
        for _, p in ipairs(plugins) do
            local before = p.hooks and p.hooks.before_dispatch
            if before then before(spec, ctx) end
        end
        local response = wrapped_ref(spec, ctx)
        for _, p in ipairs(plugins) do
            local after = p.hooks and p.hooks.after_dispatch
            if after then after(response, spec, ctx) end
        end
        return response
    end
end

M._for_test.build_dispatch_chain = _build_dispatch_chain

-- ─── ctx.llm_call factory (Step 6.3) ──────────────────────────────────

local function _validate_llm_call_state(state)
    if type(state) ~= "table" then
        error("swarm_host_alc.dispatcher._build_llm_call: state must "
            .. "be a table (got " .. type(state) .. ")")
    end
    if type(state.frame_pkg) ~= "table"
        or type(state.frame_pkg.check_mode) ~= "function" then
        error("swarm_host_alc.dispatcher._build_llm_call: "
            .. "state.frame_pkg.check_mode must be a function")
    end
    if type(state.flow_state) ~= "table" then
        error("swarm_host_alc.dispatcher._build_llm_call: "
            .. "state.flow_state must be a table (got "
            .. type(state.flow_state) .. ")")
    end
end

local function _build_llm_call(state)
    _validate_llm_call_state(state)
    local llm_opts_base = state.llm_opts_base
    local frame_pkg     = state.frame_pkg
    local alc_pkg       = state.alc_pkg
    local flow_pkg      = state.flow_pkg
    local flow_state    = state.flow_state

    return function(call_opts, step_id)
        if type(call_opts) ~= "table" then
            error("swarm_host_alc.dispatcher.ctx.llm_call: opts must "
                .. "be a table (got " .. type(call_opts) .. ")")
        end
        local call_prompt = call_opts.prompt
        if type(call_prompt) ~= "string" or call_prompt == "" then
            error("swarm_host_alc.dispatcher.ctx.llm_call: "
                .. "opts.prompt (non-empty string) required")
        end
        if type(step_id) ~= "string" or step_id == "" then
            error("swarm_host_alc.dispatcher.ctx.llm_call: step_id "
                .. "(non-empty string) required — _make_ctx must bind "
                .. "this at ctx creation time")
        end
        local call_slot = call_opts.slot or (step_id .. ":aux")
        local overlay = call_opts.llm_opts_overlay
        local effective = prompt_builder.merge_llm_opts(
            llm_opts_base, overlay, call_slot)
        local mode = frame_pkg.check_mode()
        return check_mode.route_llm(
            call_prompt, effective, call_slot,
            { mode = mode, alc = alc_pkg, flow = flow_pkg, state = flow_state })
    end
end

M._for_test.build_llm_call = _build_llm_call

-- ─── ctx fresh-table builder (Step 6.3) ───────────────────────────────

local function _make_ctx(state, path_or_step, llm_call_raw, scratch_in)
    if type(state) ~= "table" then
        error("swarm_host_alc.dispatcher._make_ctx: state must be a table")
    end
    if type(state.frame_pkg) ~= "table"
        or type(state.frame_pkg.step_id_of) ~= "function" then
        error("swarm_host_alc.dispatcher._make_ctx: "
            .. "state.frame_pkg.step_id_of must be a function")
    end
    if type(llm_call_raw) ~= "function" then
        error("swarm_host_alc.dispatcher._make_ctx: llm_call_raw must "
            .. "be a function (got " .. type(llm_call_raw) .. ")")
    end
    local frame_pkg = state.frame_pkg
    local step_id = frame_pkg.step_id_of(path_or_step)
    local ctx = {
        path = path_or_step,
        step = step_id,
        flow_state = state.flow_state,
        extras = state.extras,
        scratch = scratch_in or {},
        helpers = {
            parse_verdict = frame_pkg.parse_verdict,
            step_id_of    = frame_pkg.step_id_of,
        },
    }
    ctx.llm_call = function(call_opts)
        return llm_call_raw(call_opts, step_id)
    end
    return ctx
end

M._for_test.make_ctx = _make_ctx

-- ─── finalize (Step 6.4) ──────────────────────────────────────────────

local function _validate_finalize_state(state)
    if type(state) ~= "table" then
        error("swarm_host_alc.dispatcher._build_finalize: state must "
            .. "be a table (got " .. type(state) .. ")")
    end
    if type(state.pkg_name) ~= "string" or state.pkg_name == "" then
        error("swarm_host_alc.dispatcher._build_finalize: "
            .. "state.pkg_name must be a non-empty string")
    end
    if type(state.plugins) ~= "table" then
        error("swarm_host_alc.dispatcher._build_finalize: "
            .. "state.plugins must be a list (got "
            .. type(state.plugins) .. ")")
    end
    if type(state.flow_state) ~= "table" then
        error("swarm_host_alc.dispatcher._build_finalize: "
            .. "state.flow_state must be a table (got "
            .. type(state.flow_state) .. ")")
    end
end

local function _build_finalize(state)
    _validate_finalize_state(state)
    local pkg_name = state.pkg_name
    local plugins = state.plugins
    local flow_state = state.flow_state
    local deps = state.deps or {}

    return function()
        local alc_pkg = deps.alc
        if type(alc_pkg) ~= "table"
            or type(alc_pkg.card) ~= "table"
            or type(alc_pkg.card.create) ~= "function" then
            error("swarm_host_alc.dispatcher.finalize: "
                .. "deps.alc.card.create primitive not available "
                .. "(finalize requires alc.card injection)")
        end
        local data = (type(flow_state) == "table" and flow_state.data) or {}
        local task_id = data.task_id or "unknown"
        local task_dir = data.task_dir
        local run_status = data._run_status or "done"

        local to_write = {}
        for _, p in ipairs(plugins) do
            local fin_fn = p.hooks and p.hooks.finalize
            if type(fin_fn) ~= "function" then
                -- skip
            else
                local ok_f, result = pcall(fin_fn, flow_state)
                if not ok_f then
                    if type(alc_pkg.log) == "function" then
                        alc_pkg.log("warn",
                            "swarm_host_alc.dispatcher.finalize: "
                            .. "plugin[" .. p.name
                            .. "].hooks.finalize raised: "
                            .. tostring(result))
                    end
                elseif type(result) == "table"
                    and type(result.groups) == "table" then
                    for group_name, samples in pairs(result.groups) do
                        if type(samples) == "table" and #samples > 0 then
                            local payload = {
                                pkg = { name = pkg_name },
                                model = { id = pkg_name },
                                params = { variant = group_name },
                                scenario = { name = task_id },
                                metadata = {
                                    trace_id = task_id,
                                    task_dir = task_dir,
                                    plugin = p.name,
                                    group = group_name,
                                    run_status = run_status,
                                },
                                extra = {},
                            }
                            if type(result.params) == "table" then
                                for k, v in pairs(result.params) do
                                    payload.params[k] = v
                                end
                            end
                            if type(result.metadata) == "table" then
                                for k, v in pairs(result.metadata) do
                                    payload.metadata[k] = v
                                end
                            end
                            if type(result.extra) == "table" then
                                for kind, value in pairs(result.extra) do
                                    if payload.extra[kind] ~= nil
                                        and type(alc_pkg.log) == "function" then
                                        alc_pkg.log("warn",
                                            "swarm_host_alc.dispatcher.finalize: "
                                            .. "plugin[" .. p.name
                                            .. "] overrides extra["
                                            .. tostring(kind)
                                            .. "] already set (last wins)")
                                    end
                                    payload.extra[kind] = value
                                end
                            end
                            to_write[#to_write + 1] = {
                                plugin = p, group_name = group_name,
                                payload = payload, samples = samples,
                            }
                        end
                    end
                end
            end
        end

        local written = {}
        for _, entry in ipairs(to_write) do
            local pname = entry.plugin.name
            local group_name = entry.group_name
            local payload = entry.payload
            local samples = entry.samples
            local ok_c, card_or_err = pcall(alc_pkg.card.create, payload)
            if ok_c and type(card_or_err) == "table" and card_or_err.card_id then
                local card = card_or_err
                if type(alc_pkg.card.write_samples) == "function" then
                    local ok_s, err_s = pcall(alc_pkg.card.write_samples,
                        card.card_id, samples)
                    if not ok_s and type(alc_pkg.log) == "function" then
                        alc_pkg.log("warn",
                            "swarm_host_alc.dispatcher.finalize: "
                            .. "card.write_samples[" .. pname
                            .. "/" .. group_name .. "] failed: "
                            .. tostring(err_s))
                    end
                end
                if type(alc_pkg.log) == "function" then
                    alc_pkg.log("info",
                        "swarm_host_alc.dispatcher.finalize: "
                        .. "card[" .. pname .. "/" .. group_name
                        .. "] finalized " .. tostring(card.card_id)
                        .. " (n=" .. #samples .. ")")
                end
                written[#written + 1] = card
            else
                if type(alc_pkg.log) == "function" then
                    alc_pkg.log("warn",
                        "swarm_host_alc.dispatcher.finalize: "
                        .. "card.create[" .. pname .. "/" .. group_name
                        .. "] failed: " .. tostring(card_or_err))
                end
            end
        end
        return written
    end
end

M._for_test.build_finalize = _build_finalize

-- ─── __call lifecycle (Step 6.5) ──────────────────────────────────────
--
-- The dispatcher's __call metamethod orchestrates step lifecycle hooks
-- around dispatch_chain:
--
--   normal path (is_outermost = true, ctx is freshly built):
--     before_step[] sequential (plugins[1] → [N])
--     around_step onion (plugins[1] = OUTERMOST, inner = dispatch_chain)
--     after_step[] sequential
--     response nil/false → error (#11)
--
--   step skip path (is_outermost = false, ctx passed in from ctx.dispatch):
--     dispatch_chain only — step hooks skip (double-firing prevention)
--
-- ctx.dispatch is the recursive primitive that lets plugins call back
-- into the dispatcher from inside around_dispatch (3-step protocol,
-- cascade sub-calls, reflexion critique). It threads the SAME ctx so
-- that step hooks don't re-fire on the recursive __call.
--
-- Safeguards (closure upvalues per dispatcher instance):
--   * dispatch_counters[plugin_name][step_id] = ctx.dispatch invocation
--     count per (plugin × step). Capped at max_dispatch_per_step.
--   * recursion_depth = current ctx.dispatch nesting depth. Capped at
--     max_recursion_depth.
-- Both are closure-scoped at the dispatcher instance level (= shared
-- across all __call invocations on the same dispatcher). Cap breaches
-- return a BLOCKED string (= caller orch reads response prefix).
--
-- ctx cleanup logic (旧 line 1010-1021 + 3 か所重複) is COMPLETELY
-- removed (#9): _make_ctx builds a fresh table per call, the table
-- becomes unreachable when the outermost __call returns, GC takes
-- care of it. No manual nil-out.

local function _format_blocked(reason, suffix)
    if suffix and suffix ~= "" then
        return string.format("BLOCKED reason=%s %s", reason, suffix)
    end
    return string.format("BLOCKED reason=%s", reason)
end

local function _blocked_panic(plugin_name, hook_name, err)
    return string.format(
        "BLOCKED reason=swarm_host_alc.dispatcher.plugin_panic "
        .. "plugin=%s hook=%s err=%s",
        plugin_name, hook_name, tostring(err))
end

local function _validate_call_state(state)
    if type(state) ~= "table" then
        error("swarm_host_alc.dispatcher._build_call: state must be a table")
    end
    if type(state.plugins) ~= "table" then
        error("swarm_host_alc.dispatcher._build_call: state.plugins must be a list")
    end
    if type(state.dispatch_chain) ~= "function" then
        error("swarm_host_alc.dispatcher._build_call: state.dispatch_chain must be a function")
    end
    if type(state.llm_call_raw) ~= "function" then
        error("swarm_host_alc.dispatcher._build_call: state.llm_call_raw must be a function")
    end
    if type(state.make_ctx_state) ~= "table" then
        error("swarm_host_alc.dispatcher._build_call: state.make_ctx_state must be a table")
    end
    if type(state.safeguard) ~= "table" then
        error("swarm_host_alc.dispatcher._build_call: state.safeguard must be a table")
    end
end

local function _build_call(state)
    _validate_call_state(state)
    local plugins        = state.plugins
    local dispatch_chain = state.dispatch_chain
    local llm_call_raw   = state.llm_call_raw
    local make_ctx_state = state.make_ctx_state
    local max_dispatch_per_step = state.safeguard.max_dispatch_per_step
    local max_recursion_depth   = state.safeguard.max_recursion_depth

    -- Closure upvalues per dispatcher instance.
    local dispatch_counters = {}
    local recursion_depth = 0

    local function check_dispatch_limit(plugin_name, step_id)
        dispatch_counters[plugin_name] = dispatch_counters[plugin_name] or {}
        local cnt = (dispatch_counters[plugin_name][step_id] or 0) + 1
        dispatch_counters[plugin_name][step_id] = cnt
        if cnt > max_dispatch_per_step then
            return _format_blocked(
                "swarm_host_alc.dispatcher.max_dispatch_per_step",
                string.format("plugin=%s step=%s count=%d",
                    plugin_name, step_id, cnt))
        end
        return nil
    end

    -- The actual __call body. `self` is the callable table (passed by
    -- the setmetatable __call mechanism). `_ctx`, if present, signals
    -- a recursive invocation from ctx.dispatch — step hooks skip.
    return function(self, path_or_step, spec, _ctx)
        local is_outermost = (_ctx == nil)
        local ctx
        if is_outermost then
            ctx = _make_ctx(make_ctx_state, path_or_step, llm_call_raw)
            -- Attach ctx.dispatch: recursive _self call with same ctx.
            ctx.dispatch = function(spec2)
                recursion_depth = recursion_depth + 1
                if recursion_depth > max_recursion_depth then
                    local d = recursion_depth
                    recursion_depth = recursion_depth - 1
                    return _format_blocked(
                        "swarm_host_alc.dispatcher.max_recursion_depth",
                        string.format("depth=%d", d))
                end
                local limit_err = check_dispatch_limit(
                    "ctx.dispatch", ctx.step)
                if limit_err then
                    recursion_depth = recursion_depth - 1
                    return limit_err
                end
                local result = self(ctx.path, spec2, ctx)
                recursion_depth = recursion_depth - 1
                return result
            end
        else
            ctx = _ctx
        end

        -- Step skip path: recursive __call (ctx was supplied), skip
        -- step lifecycle, dispatch_chain only.
        if not is_outermost then
            return dispatch_chain(spec, ctx)
        end

        -- Normal path: full step lifecycle.
        local step_id = ctx.step

        -- before_step[] sequential plugins[1] → [N].
        for _, p in ipairs(plugins) do
            local fn = p.hooks and p.hooks.before_step
            if fn then
                local ok, err = pcall(fn, step_id, spec, ctx)
                if not ok then
                    return _blocked_panic(p.name, "before_step", err)
                end
            end
        end

        -- around_step onion (plugins[1] = OUTERMOST).
        local step_wrapped = dispatch_chain
        for i = #plugins, 1, -1 do
            local p = plugins[i]
            local around = p.hooks and p.hooks.around_step
            if around then
                local inner = step_wrapped
                step_wrapped = function(s, c)
                    return around(inner, step_id, s, c)
                end
            end
        end

        local ok_sw, response = pcall(step_wrapped, spec, ctx)
        if not ok_sw then
            local panic_plugin = "unknown"
            for _, p in ipairs(plugins) do
                if p.hooks and p.hooks.around_step then
                    panic_plugin = p.name
                    break
                end
            end
            return _blocked_panic(panic_plugin, "around_step", response)
        end

        -- #11 (response 明示 error): nil/false で error throw.
        -- 旧 swarm_frame_algocline line 1023 `return response or ""`
        -- は silent string cast の事故源、 V3 で撤廃。 BLOCKED string
        -- 経路は string return なので #11 error には引っかからない。
        if response == nil or response == false then
            error("swarm_host_alc.dispatcher: dispatch returned "
                .. tostring(response) .. " for step=" .. tostring(step_id)
                .. " (nil/false silent string-cast 撤廃、 V3 #11 reframe)")
        end

        -- after_step[] sequential plugins[1] → [N].
        for _, p in ipairs(plugins) do
            local fn = p.hooks and p.hooks.after_step
            if fn then
                local ok, err = pcall(fn, response, step_id, spec, ctx)
                if not ok then
                    return _blocked_panic(p.name, "after_step", err)
                end
            end
        end

        -- ctx cleanup: NOT performed (#9 撤廃). _make_ctx generates
        -- a fresh table per call; the table is unreachable after this
        -- function returns, GC reclaims. No manual nil-out.
        return response
    end
end

M._for_test.build_call = _build_call

-- ─── make_dispatcher ──────────────────────────────────────────────────

--- make_dispatcher(opts) → callable table.
---
--- V3 clean restart COMPLETE: all 6 sub-step factories wired together
--- (validation + writes registry + core_dispatch + dispatch_chain +
--- llm_call + finalize + __call lifecycle). The returned callable
--- table satisfies dispatcher_iface.check_call (#8b) and exposes the
--- structured-IF surface {extras, plugins, writes, finalize}.
---
--- @param opts table see module docstring
--- @return table dispatcher (callable, exposes extras/plugins/writes/finalize)
function M.make_dispatcher(opts)
    if type(opts) ~= "table" then
        error("swarm_host_alc.dispatcher.make_dispatcher: opts must be "
            .. "a table (got " .. type(opts) .. ")")
    end
    if type(opts.builder) ~= "function" then
        error("swarm_host_alc.dispatcher.make_dispatcher: opts.builder "
            .. "must be a function (got " .. type(opts.builder) .. ")")
    end
    if type(opts.flow_state) ~= "table" then
        error("swarm_host_alc.dispatcher.make_dispatcher: opts.flow_state "
            .. "must be a table (got " .. type(opts.flow_state) .. ")")
    end
    if type(opts.pkg_name) ~= "string" or opts.pkg_name == "" then
        error("swarm_host_alc.dispatcher.make_dispatcher: opts.pkg_name "
            .. "must be a non-empty string (got "
            .. type(opts.pkg_name) .. ")")
    end
    if opts.deps ~= nil and type(opts.deps) ~= "table" then
        error("swarm_host_alc.dispatcher.make_dispatcher: opts.deps "
            .. "must be a table or nil (got " .. type(opts.deps) .. ")")
    end
    if opts.llm_opts_base ~= nil and type(opts.llm_opts_base) ~= "table" then
        error("swarm_host_alc.dispatcher.make_dispatcher: opts.llm_opts_base "
            .. "must be a table or nil (got "
            .. type(opts.llm_opts_base) .. ")")
    end
    if opts.extras ~= nil and type(opts.extras) ~= "table" then
        error("swarm_host_alc.dispatcher.make_dispatcher: opts.extras "
            .. "must be a table or nil (got " .. type(opts.extras) .. ")")
    end
    if opts.plugins ~= nil and type(opts.plugins) ~= "table" then
        error("swarm_host_alc.dispatcher.make_dispatcher: opts.plugins "
            .. "must be a list or nil (got " .. type(opts.plugins) .. ")")
    end

    local effective_safeguard = safeguard_mod.merge(opts.safeguard)
    local plugins = opts.plugins or {}
    for i, p in ipairs(plugins) do
        _validate_plugin(p, i)
    end
    local deps = opts.deps or {}
    local writes_registry = _build_writes_registry(plugins, deps)
    local flow_state = opts.flow_state
    local extras = opts.extras or {}
    local llm_opts_base = opts.llm_opts_base

    -- Lazy build (cache on first call): make_dispatcher only validates
    -- + assembles the writes registry eagerly. core_dispatch /
    -- dispatch_chain / llm_call / __call / finalize closures are built
    -- on first __call() / finalize() invocation, so dispatchers that
    -- never invoke them work without deps.frame / deps.alc injected
    -- (= minimal opts in test contexts pass make_dispatcher cleanly).
    -- This matches the lazy-validation discipline used by _build_finalize
    -- (alc.card lazy) and extends it across the entire __call chain.
    local cached_call_fn = nil
    local cached_finalize_fn = nil

    local function get_call_fn()
        if cached_call_fn then return cached_call_fn end
        local frame_pkg = deps.frame
        local alc_pkg = deps.alc
        local flow_pkg = deps.flow
        local core_dispatch = _build_core_dispatch({
            builder = opts.builder,
            llm_opts_base = llm_opts_base,
            frame_pkg = frame_pkg,
            alc_pkg = alc_pkg,
            flow_pkg = flow_pkg,
            flow_state = flow_state,
        })
        local dispatch_chain_fn = _build_dispatch_chain({
            core_dispatch = core_dispatch,
            plugins = plugins,
        })
        local llm_call_raw = _build_llm_call({
            llm_opts_base = llm_opts_base,
            frame_pkg = frame_pkg,
            alc_pkg = alc_pkg,
            flow_pkg = flow_pkg,
            flow_state = flow_state,
        })
        local make_ctx_state = {
            frame_pkg = frame_pkg,
            flow_state = flow_state,
            extras = extras,
        }
        cached_call_fn = _build_call({
            plugins = plugins,
            dispatch_chain = dispatch_chain_fn,
            llm_call_raw = llm_call_raw,
            make_ctx_state = make_ctx_state,
            safeguard = effective_safeguard,
        })
        return cached_call_fn
    end

    local function get_finalize_fn()
        if cached_finalize_fn then return cached_finalize_fn end
        cached_finalize_fn = _build_finalize({
            pkg_name = opts.pkg_name,
            plugins = plugins,
            flow_state = flow_state,
            deps = deps,
        })
        return cached_finalize_fn
    end

    return setmetatable({
        extras = extras,
        plugins = plugins,
        writes = writes_registry,
        finalize = function() return get_finalize_fn()() end,
    }, {
        __call = function(self, path, spec, ctx)
            return get_call_fn()(self, path, spec, ctx)
        end,
    })
end

return M
