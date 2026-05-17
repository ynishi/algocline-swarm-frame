-- dispatcher_spec.lua — make_dispatcher の check_mode ルーティング・extras・エラー case spec
--
-- DSL 規約: lust global は alc_pkg_test runner が auto-inject する。
-- package.path 手動設定禁止 (§8-7-36)。

local lust = require("lust")
local sfa = require("swarm_frame_algocline")
local frame = require("swarm_frame")
local describe, it, expect = lust.describe, lust.it, lust.expect

-- ─── helpers ────────────────────────────────────────────────────────

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
            expect(err).to.contain("opts table required")
        end)

        it("errors when builder is missing", function()
            frame._reset_for_testing()
            local ok, err = pcall(sfa.make_dispatcher, {
                state = frame.state_new(),
            })
            expect(ok).to.equal(false)
            expect(err).to.contain("opts.builder must be a function")
        end)

        it("errors when state is missing", function()
            frame._reset_for_testing()
            local ok, err = pcall(sfa.make_dispatcher, {
                builder = function(_step, _spec)
                    return "P"
                end,
            })
            expect(ok).to.equal(false)
            expect(err).to.contain("opts.state")
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
                builder = function(step, _spec)
                    return "PROMPT:" .. step
                end,
                state = frame.state_new(),
                alc = mock_alc,
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
                builder = function(step, _spec)
                    return "BARE:" .. step
                end,
                state = frame.state_new(),
                alc = mock_alc,
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
                builder = function(_step, _spec)
                    return "PROMPT"
                end,
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
                llm_bound = function(_state, _slot_opts)
                    return "plain text no braces"
                end,
            }

            local d = sfa.make_dispatcher({
                builder = function(_step, _spec)
                    return "P"
                end,
                state = frame.state_new(),
                flow = mock_flow,
            })

            local resp = d("/pkg/step_1/agent")
            expect(resp).to.contain("BLOCKED")
            expect(resp).to.contain("format-non-json")
        end)

        it("returns BLOCKED when JSON is missing required fields", function()
            frame._reset_for_testing()
            frame.init({ check_mode = "format" })

            local mock_flow = {
                llm_bound = function(_state, _slot_opts)
                    return '{"foo": "bar"}'
                end,
            }

            local d = sfa.make_dispatcher({
                builder = function(_step, _spec)
                    return "P"
                end,
                state = frame.state_new(),
                flow = mock_flow,
            })

            local resp = d("/pkg/step_1/agent")
            expect(resp).to.contain("BLOCKED")
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
                builder = function(_step, _spec)
                    return "P"
                end,
                state = frame.state_new(),
                flow = mock_flow,
            })

            local resp = d("/pkg/step_1/agent")
            expect(resp).to.contain("BLOCKED")
            expect(resp).to.contain("format-flow-slot-mismatch")
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
                builder = function(_step, _spec)
                    return "P"
                end,
                state = frame.state_new(),
                alc = minimal_mock_alc(called),
                extras = { my_key = "my_val", count = 42 },
            })

            expect(d.extras.my_key).to.equal("my_val")
            expect(d.extras.count).to.equal(42)
        end)

        it("errors when opts.extras is not a table", function()
            frame._reset_for_testing()
            local ok, err = pcall(sfa.make_dispatcher, {
                builder = function(_step, _spec)
                    return "P"
                end,
                state = frame.state_new(),
                extras = "bad",
            })
            expect(ok).to.equal(false)
            expect(err).to.contain("opts.extras must be a table or nil")
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
                after_dispatch = function(response, _spec, _ctx)
                    table.insert(hook_responses, response)
                end,
            }

            local called = {}
            local d = sfa.make_dispatcher({
                builder = function(_step, _spec)
                    return "P"
                end,
                state = frame.state_new(),
                alc = minimal_mock_alc(called),
                plugins = { recorder },
            })

            d("/pkg/step_1/agent")
            expect(#hook_responses).to.equal(1)
            expect(hook_responses[1]).to.equal("MOCK_LLM_RESPONSE")
        end)
    end)
end)
