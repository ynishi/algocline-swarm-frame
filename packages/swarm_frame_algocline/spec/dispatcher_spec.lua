-- dispatcher_spec.lua — make_dispatcher の check_mode ルーティング・extras・エラー case spec
--
-- DSL 規約: lust global は alc_pkg_test runner が auto-inject する。
-- package.path 手動設定禁止 (§8-7-36)。

local sfa = require("swarm_frame_algocline")
local frame = require("swarm_frame")
local describe, it, expect = lust.describe, lust.it, lust.expect

-- ─── helpers ────────────────────────────────────────────────────────

-- Plain-substring assertion helper (lust API has no `.contain`, only `.match`
-- which uses Lua patterns — `.` etc become wildcards).
local function contains(s, sub) return type(s) == "string" and string.find(s, sub, 1, true) ~= nil end

-- Stub flow for tests that don't exercise flow.llm_bound. make_dispatcher
-- evaluates `opts.flow or require("flow")` unconditionally; we inject a
-- non-nil stub to short-circuit the require lookup (flow pkg lives in
-- ~/.algocline/packages and is outside the alc_pkg_test VM's package.path).
local stub_flow = {
    llm_bound = function(_state, _slot_opts) error("stub_flow.llm_bound should not be invoked in non-flow tests") end,
}

local function minimal_mock_alc(called)
    called = called or {}
    return {
        llm = function(prompt, _opts)
            called.prompt = prompt
            called.count = (called.count or 0) + 1
            return "MOCK_LLM_RESPONSE"
        end,
        log = function(_level, _msg) end,
    }
end

local function minimal_mock_flow(calls)
    calls = calls or {}
    return {
        llm_bound = function(_state, slot_opts)
            table.insert(calls, slot_opts.slot)
            return "STRICT_RESPONSE"
        end,
    }
end

-- ─── specs ──────────────────────────────────────────────────────────

describe("make_dispatcher", function()
    -- ----------------------------------------------------------------
    -- validation errors
    -- ----------------------------------------------------------------

    describe("validation", function()
        it("errors when opts is not a table", function()
            frame._reset_for_testing()
            local ok, err = pcall(sfa.make_dispatcher, "bad")
            expect(ok).to.equal(false)
            expect(contains(err, "opts table required")).to.equal(true)
        end)

        it("errors when builder is missing", function()
            frame._reset_for_testing()
            local ok, err = pcall(sfa.make_dispatcher, {
                state = frame.state_new(),
            })
            expect(ok).to.equal(false)
            expect(contains(err, "opts.builder must be a function")).to.equal(true)
        end)

        it("errors when state is missing", function()
            frame._reset_for_testing()
            local ok, err = pcall(sfa.make_dispatcher, {
                builder = function(_step, _spec) return "P" end,
            })
            expect(ok).to.equal(false)
            expect(contains(err, "opts.state")).to.equal(true)
        end)
    end)

    -- ----------------------------------------------------------------
    -- non-check mode: routes to alc.llm
    -- ----------------------------------------------------------------

    describe("non-check mode", function()
        it("routes prompt to alc.llm and returns its response", function()
            frame._reset_for_testing()
            frame.init({ check_mode = "non-check" })

            local called = {}
            local mock_alc = minimal_mock_alc(called)

            local d = sfa.make_dispatcher({
                builder = function(step, _spec) return "PROMPT:" .. step end,
                state = frame.state_new(),
                alc = mock_alc,
                flow = stub_flow,
            })

            local resp = d("/pkg/step_1/agent")
            expect(resp).to.equal("MOCK_LLM_RESPONSE")
            expect(called.prompt).to.equal("PROMPT:step_1")
        end)

        it("resolves bare step_id (no path prefix)", function()
            frame._reset_for_testing()
            frame.init({ check_mode = "non-check" })

            local called = {}
            local mock_alc = minimal_mock_alc(called)

            local d = sfa.make_dispatcher({
                builder = function(step, _spec) return "BARE:" .. step end,
                state = frame.state_new(),
                alc = mock_alc,
                flow = stub_flow,
            })

            local resp = d("step_bare")
            expect(resp).to.equal("MOCK_LLM_RESPONSE")
            expect(called.prompt).to.equal("BARE:step_bare")
        end)
    end)

    -- ----------------------------------------------------------------
    -- strict mode: routes to flow.llm_bound
    -- ----------------------------------------------------------------

    describe("strict mode", function()
        it("routes prompt through flow.llm_bound", function()
            frame._reset_for_testing()
            -- default check_mode after _reset_for_testing() is "strict"

            local flow_calls = {}
            local mock_flow = minimal_mock_flow(flow_calls)

            local d = sfa.make_dispatcher({
                builder = function(_step, _spec) return "PROMPT" end,
                state = frame.state_new(),
                flow = mock_flow,
            })

            local resp = d("/pkg/step_1/agent")
            expect(resp).to.equal("STRICT_RESPONSE")
            expect(#flow_calls).to.equal(1)
            expect(flow_calls[1]).to.equal("step_1")
        end)
    end)

    -- ----------------------------------------------------------------
    -- format mode: flow.llm_bound + JSON shape verify
    -- ----------------------------------------------------------------

    describe("format mode", function()
        it("returns BLOCKED when response has no JSON object", function()
            frame._reset_for_testing()
            frame.init({ check_mode = "format" })

            local mock_flow = {
                llm_bound = function(_state, _slot_opts) return "plain text no braces" end,
            }

            local d = sfa.make_dispatcher({
                builder = function(_step, _spec) return "P" end,
                state = frame.state_new(),
                flow = mock_flow,
            })

            local resp = d("/pkg/step_1/agent")
            expect(contains(resp, "BLOCKED")).to.equal(true)
            expect(contains(resp, "format-non-json")).to.equal(true)
        end)

        it("returns BLOCKED when JSON is missing required fields", function()
            frame._reset_for_testing()
            frame.init({ check_mode = "format" })

            local mock_flow = {
                llm_bound = function(_state, _slot_opts) return '{"foo": "bar"}' end,
            }

            local d = sfa.make_dispatcher({
                builder = function(_step, _spec) return "P" end,
                state = frame.state_new(),
                flow = mock_flow,
            })

            local resp = d("/pkg/step_1/agent")
            expect(contains(resp, "BLOCKED")).to.equal(true)
        end)

        it("returns BLOCKED when flow_slot mismatches step", function()
            frame._reset_for_testing()
            frame.init({ check_mode = "format" })

            local mock_flow = {
                llm_bound = function(_state, _slot_opts)
                    return '{"status":"ok","flow_token":"tok","flow_slot":"wrong_step"}'
                end,
            }

            local d = sfa.make_dispatcher({
                builder = function(_step, _spec) return "P" end,
                state = frame.state_new(),
                flow = mock_flow,
            })

            local resp = d("/pkg/step_1/agent")
            expect(contains(resp, "BLOCKED")).to.equal(true)
            expect(contains(resp, "format-flow-slot-mismatch")).to.equal(true)
        end)
    end)

    -- ----------------------------------------------------------------
    -- extras pass-through
    -- ----------------------------------------------------------------

    describe("extras", function()
        it("exposes opts.extras at dispatcher.extras", function()
            frame._reset_for_testing()
            frame.init({ check_mode = "non-check" })

            local called = {}
            local d = sfa.make_dispatcher({
                builder = function(_step, _spec) return "P" end,
                state = frame.state_new(),
                alc = minimal_mock_alc(called),
                flow = stub_flow,
                extras = { my_key = "my_val", count = 42 },
            })

            expect(d.extras.my_key).to.equal("my_val")
            expect(d.extras.count).to.equal(42)
        end)

        it("errors when opts.extras is not a table", function()
            frame._reset_for_testing()
            local ok, err = pcall(sfa.make_dispatcher, {
                builder = function(_step, _spec) return "P" end,
                state = frame.state_new(),
                flow = stub_flow,
                extras = "bad",
            })
            expect(ok).to.equal(false)
            expect(contains(err, "opts.extras must be a table or nil")).to.equal(true)
        end)
    end)

    -- ----------------------------------------------------------------
    -- after_dispatch plugin hook
    -- ----------------------------------------------------------------

    describe("plugins", function()
        it("calls after_dispatch with the response", function()
            frame._reset_for_testing()
            frame.init({ check_mode = "non-check" })

            local hook_responses = {}
            local recorder = {
                name = "test_recorder",
                after_dispatch = function(response, _spec, _ctx) table.insert(hook_responses, response) end,
            }

            local called = {}
            local d = sfa.make_dispatcher({
                builder = function(_step, _spec) return "P" end,
                state = frame.state_new(),
                alc = minimal_mock_alc(called),
                flow = stub_flow,
                plugins = { recorder },
            })

            d("/pkg/step_1/agent")
            expect(#hook_responses).to.equal(1)
            expect(hook_responses[1]).to.equal("MOCK_LLM_RESPONSE")
        end)
    end)
end)

-- ─── step hook specs (Phase B) ───────────────────────────────────────

describe("step hooks", function()
    -- ----------------------------------------------------------------
    -- validation: new hook fields must be function or nil
    -- ----------------------------------------------------------------

    describe("validation", function()
        it("errors when before_step is not a function", function()
            frame._reset_for_testing()
            local ok, err = pcall(sfa.make_dispatcher, {
                builder = function(_step, _spec) return "P" end,
                state = frame.state_new(),
                flow = stub_flow,
                plugins = { { name = "bad", before_step = "not_a_function" } },
            })
            expect(ok).to.equal(false)
            expect(contains(err, "before_step")).to.equal(true)
            expect(contains(err, "must be a function or nil")).to.equal(true)
        end)

        it("errors when around_step is not a function", function()
            frame._reset_for_testing()
            local ok, err = pcall(sfa.make_dispatcher, {
                builder = function(_step, _spec) return "P" end,
                state = frame.state_new(),
                flow = stub_flow,
                plugins = { { name = "bad", around_step = 42 } },
            })
            expect(ok).to.equal(false)
            expect(contains(err, "around_step")).to.equal(true)
            expect(contains(err, "must be a function or nil")).to.equal(true)
        end)

        it("errors when after_step is not a function", function()
            frame._reset_for_testing()
            local ok, err = pcall(sfa.make_dispatcher, {
                builder = function(_step, _spec) return "P" end,
                state = frame.state_new(),
                flow = stub_flow,
                plugins = { { name = "bad", after_step = true } },
            })
            expect(ok).to.equal(false)
            expect(contains(err, "after_step")).to.equal(true)
            expect(contains(err, "must be a function or nil")).to.equal(true)
        end)

        it("errors when step_writes is not a table", function()
            frame._reset_for_testing()
            local ok, err = pcall(sfa.make_dispatcher, {
                builder = function(_step, _spec) return "P" end,
                state = frame.state_new(),
                flow = stub_flow,
                plugins = { { name = "bad", step_writes = "not_a_list" } },
            })
            expect(ok).to.equal(false)
            expect(contains(err, "step_writes")).to.equal(true)
            expect(contains(err, "must be a list of strings or nil")).to.equal(true)
        end)

        it("errors when step_writes contains a non-string entry", function()
            frame._reset_for_testing()
            local ok, err = pcall(sfa.make_dispatcher, {
                builder = function(_step, _spec) return "P" end,
                state = frame.state_new(),
                flow = stub_flow,
                plugins = { { name = "bad", step_writes = { 123 } } },
            })
            expect(ok).to.equal(false)
            expect(contains(err, "step_writes")).to.equal(true)
            expect(contains(err, "must be a non-empty string")).to.equal(true)
        end)

        it("allows all new fields to be nil (backward compat)", function()
            frame._reset_for_testing()
            frame.init({ check_mode = "non-check" })
            local ok = pcall(sfa.make_dispatcher, {
                builder = function(_step, _spec) return "P" end,
                state = frame.state_new(),
                alc = minimal_mock_alc(),
                flow = stub_flow,
                plugins = {
                    { name = "compat", before_step = nil, around_step = nil, after_step = nil, step_writes = nil },
                },
            })
            expect(ok).to.equal(true)
        end)
    end)

    -- ----------------------------------------------------------------
    -- before_step: sequential, plugins[1] -> [N]
    -- ----------------------------------------------------------------

    describe("before_step", function()
        it("fires before_step for each plugin in order before dispatch", function()
            frame._reset_for_testing()
            frame.init({ check_mode = "non-check" })

            local fire_order = {}
            local dispatch_fired = {}

            local p1 = {
                name = "p1",
                before_step = function(_step_id, _spec, _ctx) table.insert(fire_order, "p1_before_step") end,
            }
            local p2 = {
                name = "p2",
                before_step = function(_step_id, _spec, _ctx) table.insert(fire_order, "p2_before_step") end,
            }

            local d = sfa.make_dispatcher({
                builder = function(step, _spec)
                    table.insert(dispatch_fired, step)
                    return "P"
                end,
                state = frame.state_new(),
                alc = minimal_mock_alc(),
                flow = stub_flow,
                plugins = { p1, p2 },
            })

            d("/pkg/step_1/agent")
            expect(fire_order[1]).to.equal("p1_before_step")
            expect(fire_order[2]).to.equal("p2_before_step")
            expect(#dispatch_fired).to.equal(1)
        end)

        it("before_step receives step_id, spec, and ctx", function()
            frame._reset_for_testing()
            frame.init({ check_mode = "non-check" })

            local captured = {}
            local p = {
                name = "cap",
                before_step = function(step_id, _spec, ctx)
                    captured.step_id = step_id
                    captured.ctx_step = ctx.step
                end,
            }

            local d = sfa.make_dispatcher({
                builder = function(_step, _spec) return "P" end,
                state = frame.state_new(),
                alc = minimal_mock_alc(),
                flow = stub_flow,
                plugins = { p },
            })

            d("/pkg/my_step/agent", { task = "x" })
            expect(captured.step_id).to.equal("my_step")
            expect(captured.ctx_step).to.equal("my_step")
        end)

        it("returns BLOCKED when before_step raises", function()
            frame._reset_for_testing()
            frame.init({ check_mode = "non-check" })

            local p = {
                name = "panic_plugin",
                before_step = function(_step_id, _spec, _ctx) error("before_step boom") end,
            }

            local d = sfa.make_dispatcher({
                builder = function(_step, _spec) return "P" end,
                state = frame.state_new(),
                alc = minimal_mock_alc(),
                flow = stub_flow,
                plugins = { p },
            })

            local resp = d("/pkg/step_1/agent")
            expect(contains(resp, "BLOCKED")).to.equal(true)
            expect(contains(resp, "plugin_panic")).to.equal(true)
            expect(contains(resp, "panic_plugin")).to.equal(true)
            expect(contains(resp, "before_step")).to.equal(true)
        end)
    end)

    -- ----------------------------------------------------------------
    -- after_step: sequential, plugins[1] -> [N], fires after dispatch
    -- ----------------------------------------------------------------

    describe("after_step", function()
        it("fires after_step after the dispatch response is ready", function()
            frame._reset_for_testing()
            frame.init({ check_mode = "non-check" })

            local events = {}
            local p = {
                name = "recorder",
                after_dispatch = function(_resp, _spec, _ctx) table.insert(events, "after_dispatch") end,
                after_step = function(resp, step_id, _spec, _ctx)
                    table.insert(events, "after_step:" .. step_id .. ":" .. resp)
                end,
            }

            local d = sfa.make_dispatcher({
                builder = function(_step, _spec) return "P" end,
                state = frame.state_new(),
                alc = minimal_mock_alc(),
                flow = stub_flow,
                plugins = { p },
            })

            local resp = d("/pkg/step_x/agent")
            expect(resp).to.equal("MOCK_LLM_RESPONSE")
            expect(events[1]).to.equal("after_dispatch")
            expect(events[2]).to.equal("after_step:step_x:MOCK_LLM_RESPONSE")
        end)

        it("returns BLOCKED when after_step raises", function()
            frame._reset_for_testing()
            frame.init({ check_mode = "non-check" })

            local p = {
                name = "boom_plugin",
                after_step = function(_resp, _step_id, _spec, _ctx) error("after_step explode") end,
            }

            local d = sfa.make_dispatcher({
                builder = function(_step, _spec) return "P" end,
                state = frame.state_new(),
                alc = minimal_mock_alc(),
                flow = stub_flow,
                plugins = { p },
            })

            local resp = d("/pkg/step_1/agent")
            expect(contains(resp, "BLOCKED")).to.equal(true)
            expect(contains(resp, "plugin_panic")).to.equal(true)
            expect(contains(resp, "boom_plugin")).to.equal(true)
            expect(contains(resp, "after_step")).to.equal(true)
        end)
    end)

    -- ----------------------------------------------------------------
    -- around_step: reverse onion, inner = dispatch chain (Crux 2)
    -- ----------------------------------------------------------------

    describe("around_step (Crux 2)", function()
        it("around_step inner() invokes before/around/after_dispatch chain (Crux 2 assertion)", function()
            frame._reset_for_testing()
            frame.init({ check_mode = "non-check" })

            local around_dispatch_count = 0
            local p = {
                name = "crux2_verifier",
                around_dispatch = function(inner, spec, ctx)
                    around_dispatch_count = around_dispatch_count + 1
                    return inner(spec, ctx)
                end,
                around_step = function(inner, _step_id, spec, ctx) return inner(spec, ctx) end,
            }

            local d = sfa.make_dispatcher({
                builder = function(_step, _spec) return "P" end,
                state = frame.state_new(),
                alc = minimal_mock_alc(),
                flow = stub_flow,
                plugins = { p },
            })

            d("/pkg/step_1/agent")
            -- around_dispatch must have fired when inner() was called in around_step
            expect(around_dispatch_count).to.equal(1)
        end)

        it("around_step wraps in reverse onion (plugins[1] = OUTERMOST)", function()
            frame._reset_for_testing()
            frame.init({ check_mode = "non-check" })

            local order = {}
            local p1 = {
                name = "p1",
                around_step = function(inner, _step_id, spec, ctx)
                    table.insert(order, "p1_before")
                    local r = inner(spec, ctx)
                    table.insert(order, "p1_after")
                    return r
                end,
            }
            local p2 = {
                name = "p2",
                around_step = function(inner, _step_id, spec, ctx)
                    table.insert(order, "p2_before")
                    local r = inner(spec, ctx)
                    table.insert(order, "p2_after")
                    return r
                end,
            }

            local d = sfa.make_dispatcher({
                builder = function(_step, _spec) return "P" end,
                state = frame.state_new(),
                alc = minimal_mock_alc(),
                flow = stub_flow,
                plugins = { p1, p2 },
            })

            d("/pkg/step_1/agent")
            expect(order[1]).to.equal("p1_before")
            expect(order[2]).to.equal("p2_before")
            expect(order[3]).to.equal("p2_after")
            expect(order[4]).to.equal("p1_after")
        end)

        it("BLOCKED when around_step raises", function()
            frame._reset_for_testing()
            frame.init({ check_mode = "non-check" })

            local p = {
                name = "explode_step",
                around_step = function(_inner, _step_id, _spec, _ctx) error("around_step kaboom") end,
            }

            local d = sfa.make_dispatcher({
                builder = function(_step, _spec) return "P" end,
                state = frame.state_new(),
                alc = minimal_mock_alc(),
                flow = stub_flow,
                plugins = { p },
            })

            local resp = d("/pkg/step_1/agent")
            expect(contains(resp, "BLOCKED")).to.equal(true)
            expect(contains(resp, "plugin_panic")).to.equal(true)
            expect(contains(resp, "around_step")).to.equal(true)
        end)
    end)

    -- ----------------------------------------------------------------
    -- ctx.dispatch chain passthrough (Crux 1)
    -- ----------------------------------------------------------------

    describe("ctx.dispatch (Crux 1)", function()
        it("ctx.dispatch passes through before/around/after_dispatch chain (Crux 1 assertion)", function()
            frame._reset_for_testing()
            frame.init({ check_mode = "non-check" })

            local counters = { before = 0, around = 0, after = 0 }
            local dispatch_called_from_hook = false

            local p = {
                name = "chain_verifier",
                before_dispatch = function(_spec, _ctx) counters.before = counters.before + 1 end,
                around_dispatch = function(inner, spec, ctx)
                    counters.around = counters.around + 1
                    return inner(spec, ctx)
                end,
                after_dispatch = function(_resp, _spec, _ctx) counters.after = counters.after + 1 end,
                around_step = function(inner, _step_id, spec, ctx)
                    local resp = inner(spec, ctx)
                    if not dispatch_called_from_hook then
                        dispatch_called_from_hook = true
                        ctx.dispatch({ extra = true })
                    end
                    return resp
                end,
            }

            local d = sfa.make_dispatcher({
                builder = function(_step, _spec) return "P" end,
                state = frame.state_new(),
                alc = minimal_mock_alc(),
                flow = stub_flow,
                plugins = { p },
            })

            d("/pkg/step_1/agent")
            -- First dispatch: before=1, around=1, after=1
            -- ctx.dispatch call: before=2, around=2, after=2
            expect(counters.before).to.equal(2)
            expect(counters.around).to.equal(2)
            expect(counters.after).to.equal(2)
        end)

        it("ctx.dispatch inside step hook does NOT re-fire step hooks", function()
            frame._reset_for_testing()
            frame.init({ check_mode = "non-check" })

            local before_step_count = 0
            local after_step_count = 0
            local dispatch_called = false

            local p = {
                name = "step_counter",
                before_step = function(_step_id, _spec, _ctx) before_step_count = before_step_count + 1 end,
                after_step = function(_resp, _step_id, _spec, _ctx) after_step_count = after_step_count + 1 end,
                around_step = function(inner, _step_id, spec, ctx)
                    local resp = inner(spec, ctx)
                    if not dispatch_called then
                        dispatch_called = true
                        ctx.dispatch({ sub_call = true })
                    end
                    return resp
                end,
            }

            local d = sfa.make_dispatcher({
                builder = function(_step, _spec) return "P" end,
                state = frame.state_new(),
                alc = minimal_mock_alc(),
                flow = stub_flow,
                plugins = { p },
            })

            d("/pkg/step_1/agent")
            expect(before_step_count).to.equal(1)
            expect(after_step_count).to.equal(1)
        end)
    end)

    -- ----------------------------------------------------------------
    -- safeguard: max_dispatch_per_step
    -- ----------------------------------------------------------------

    describe("safeguard: max_dispatch_per_step", function()
        it("returns BLOCKED when ctx.dispatch exceeds default limit", function()
            frame._reset_for_testing()
            frame.init({ check_mode = "non-check" })

            local results = {}
            local p = {
                name = "spammer",
                around_step = function(inner, _step_id, spec, ctx)
                    local resp = inner(spec, ctx)
                    for _ = 1, 18 do
                        local r = ctx.dispatch({})
                        table.insert(results, r)
                    end
                    return resp
                end,
            }

            local d = sfa.make_dispatcher({
                builder = function(_step, _spec) return "P" end,
                state = frame.state_new(),
                alc = minimal_mock_alc(),
                flow = stub_flow,
                plugins = { p },
            })

            d("/pkg/step_1/agent")
            local found_blocked = false
            for _, r in ipairs(results) do
                if contains(r, "BLOCKED") and contains(r, "max_dispatch_per_step") then
                    found_blocked = true
                    break
                end
            end
            expect(found_blocked).to.equal(true)
        end)

        it("custom max_dispatch_per_step is respected", function()
            frame._reset_for_testing()
            frame.init({ check_mode = "non-check" })

            local results = {}
            local p = {
                name = "caller",
                around_step = function(inner, _step_id, spec, ctx)
                    local resp = inner(spec, ctx)
                    for _ = 1, 4 do
                        table.insert(results, ctx.dispatch({}))
                    end
                    return resp
                end,
            }

            local d = sfa.make_dispatcher({
                builder = function(_step, _spec) return "P" end,
                state = frame.state_new(),
                alc = minimal_mock_alc(),
                flow = stub_flow,
                plugins = { p },
                safeguard = { max_dispatch_per_step = 2 },
            })

            d("/pkg/step_1/agent")
            expect(contains(results[3], "BLOCKED")).to.equal(true)
            expect(contains(results[3], "max_dispatch_per_step")).to.equal(true)
        end)
    end)

    -- ----------------------------------------------------------------
    -- safeguard: max_recursion_depth
    -- ----------------------------------------------------------------

    describe("safeguard: max_recursion_depth", function()
        it("returns BLOCKED when recursion depth exceeds max", function()
            frame._reset_for_testing()
            frame.init({ check_mode = "non-check" })

            local call_count = 0
            local blocked_result = nil

            local p = {
                name = "recursive_caller",
                around_step = function(inner, _step_id, spec, ctx)
                    call_count = call_count + 1
                    local resp = inner(spec, ctx)
                    if call_count <= 3 then
                        local r = ctx.dispatch({})
                        if contains(r, "BLOCKED") then blocked_result = r end
                    end
                    return resp
                end,
            }

            local d = sfa.make_dispatcher({
                builder = function(_step, _spec) return "P" end,
                state = frame.state_new(),
                alc = minimal_mock_alc(),
                flow = stub_flow,
                plugins = { p },
                safeguard = { max_recursion_depth = 2 },
            })

            d("/pkg/step_1/agent")
            expect(blocked_result ~= nil).to.equal(true)
            expect(contains(blocked_result, "BLOCKED")).to.equal(true)
            expect(contains(blocked_result, "max_recursion_depth")).to.equal(true)
        end)
    end)

    -- ----------------------------------------------------------------
    -- safeguard: opts.safeguard validation
    -- ----------------------------------------------------------------

    describe("safeguard validation", function()
        it("errors when opts.safeguard is not a table", function()
            frame._reset_for_testing()
            local ok, err = pcall(sfa.make_dispatcher, {
                builder = function(_step, _spec) return "P" end,
                state = frame.state_new(),
                flow = stub_flow,
                safeguard = "bad",
            })
            expect(ok).to.equal(false)
            expect(contains(err, "opts.safeguard must be a table or nil")).to.equal(true)
        end)
    end)

    -- ----------------------------------------------------------------
    -- _outermost_call cleanup guard: ctx fields available in after_step
    -- ----------------------------------------------------------------

    describe("ctx cleanup guard (_outermost_call)", function()
        it("ctx.frame and ctx.step are accessible in after_step", function()
            frame._reset_for_testing()
            frame.init({ check_mode = "non-check" })

            local captured = {}
            local p = {
                name = "ctx_checker",
                after_step = function(_resp, step_id, _spec, ctx)
                    captured.frame = ctx.frame
                    captured.step = ctx.step
                    captured.step_id_arg = step_id
                end,
            }

            local d = sfa.make_dispatcher({
                builder = function(_step, _spec) return "P" end,
                state = frame.state_new(),
                alc = minimal_mock_alc(),
                flow = stub_flow,
                plugins = { p },
            })

            d("/pkg/check_step/agent")
            expect(captured.frame ~= nil).to.equal(true)
            expect(captured.step).to.equal("check_step")
            expect(captured.step_id_arg).to.equal("check_step")
        end)

        it("ctx.dispatch sub-call does not clear ctx for outer after_step", function()
            frame._reset_for_testing()
            frame.init({ check_mode = "non-check" })

            local after_step_ctx_step = nil
            local dispatch_called = false

            local p = {
                name = "ctx_guard_test",
                around_step = function(inner, _step_id, spec, ctx)
                    local resp = inner(spec, ctx)
                    if not dispatch_called then
                        dispatch_called = true
                        ctx.dispatch({})
                    end
                    return resp
                end,
                after_step = function(_resp, step_id, _spec, _ctx) after_step_ctx_step = step_id end,
            }

            local d = sfa.make_dispatcher({
                builder = function(_step, _spec) return "P" end,
                state = frame.state_new(),
                alc = minimal_mock_alc(),
                flow = stub_flow,
                plugins = { p },
            })

            d("/pkg/guard_step/agent")
            expect(after_step_ctx_step).to.equal("guard_step")
        end)
    end)

    -- ----------------------------------------------------------------
    -- step_writes: advisory registry + collision warn
    -- ----------------------------------------------------------------

    describe("step_writes", function()
        it("exposes step_writes registry at dispatcher.step_writes", function()
            frame._reset_for_testing()
            frame.init({ check_mode = "non-check" })

            local p1 = { name = "p1", step_writes = { "3_GATE", "4_IMPL" } }
            local p2 = { name = "p2", step_writes = { "3_GATE" } }

            local d = sfa.make_dispatcher({
                builder = function(_step, _spec) return "P" end,
                state = frame.state_new(),
                alc = minimal_mock_alc(),
                flow = stub_flow,
                plugins = { p1, p2 },
            })

            expect(#d.step_writes["3_GATE"]).to.equal(2)
            expect(d.step_writes["3_GATE"][1]).to.equal("p1")
            expect(d.step_writes["3_GATE"][2]).to.equal("p2")
            expect(#d.step_writes["4_IMPL"]).to.equal(1)
            expect(d.step_writes["4_IMPL"][1]).to.equal("p1")
        end)

        it("logs warn when multiple plugins declare the same step_id", function()
            frame._reset_for_testing()
            frame.init({ check_mode = "non-check" })

            local warn_msgs = {}
            local mock_alc_warn = {
                llm = function(_p, _opts) return "R" end,
                log = function(level, msg)
                    if level == "warn" then table.insert(warn_msgs, msg) end
                end,
            }

            local p1 = { name = "p1", step_writes = { "collision_step" } }
            local p2 = { name = "p2", step_writes = { "collision_step" } }

            sfa.make_dispatcher({
                builder = function(_step, _spec) return "P" end,
                state = frame.state_new(),
                alc = mock_alc_warn,
                flow = stub_flow,
                plugins = { p1, p2 },
            })

            local found_collision_warn = false
            for _, msg in ipairs(warn_msgs) do
                if contains(msg, "step_writes") and contains(msg, "collision_step") then
                    found_collision_warn = true
                    break
                end
            end
            expect(found_collision_warn).to.equal(true)
        end)
    end)

    -- ----------------------------------------------------------------
    -- regression: existing plugin with no step hooks works unchanged
    -- ----------------------------------------------------------------

    describe("regression: no step hooks", function()
        it("plugin with only dispatch hooks still works (backward compat)", function()
            frame._reset_for_testing()
            frame.init({ check_mode = "non-check" })

            local after_dispatch_fired = false
            local existing_plugin = {
                name = "legacy",
                before_dispatch = function(_spec, _ctx) end,
                around_dispatch = function(inner, spec, ctx) return inner(spec, ctx) end,
                after_dispatch = function(_resp, _spec, _ctx) after_dispatch_fired = true end,
            }

            local called = {}
            local d = sfa.make_dispatcher({
                builder = function(_step, _spec) return "P" end,
                state = frame.state_new(),
                alc = minimal_mock_alc(called),
                flow = stub_flow,
                plugins = { existing_plugin },
            })

            local resp = d("/pkg/step_1/agent")
            expect(resp).to.equal("MOCK_LLM_RESPONSE")
            expect(after_dispatch_fired).to.equal(true)
        end)
    end)
end)
