-- dispatcher_core_dispatch_spec.lua — Boundary regression spec for
-- swarm_host_alc.dispatcher._for_test.build_core_dispatch (P5 step 6.2).
--
-- core_dispatch is a local function inside make_dispatcher's closure
-- (Step 6.3 carry). The _for_test.build_core_dispatch factory seam
-- exposes it so this spec can construct the closure with mock deps
-- and verify each phase (builder / overlay merge / route_llm /
-- format_postverify) in isolation — workspace-pipeline.md §Frame/orch
-- 改修後 checklist (1) target 直接 expose + (2) 実 production object
-- shape を mock で再現 規律準拠.

local lust = require("lust")
local describe, it, expect = lust.describe, lust.it, lust.expect

local dispatcher = require("swarm_host_alc.dispatcher")

local function contains(s, sub)
    return type(s) == "string" and string.find(s, sub, 1, true) ~= nil
end

-- Factory for mock closure_state (overrides merged per-test).
local function make_mock_state(overrides)
    local s = {
        builder = function(step, _spec) return "PROMPT for " .. step end,
        llm_opts_base = { temperature = 0.7 },
        frame_pkg = { check_mode = function() return "non-check" end },
        alc_pkg = {
            llm = function(prompt, _opts)
                return "RESPONSE for " .. prompt
            end,
            json_decode = function(_s) return { fake = true } end,
        },
        flow_pkg = {
            llm_bound = function()
                error("flow_pkg.llm_bound should not be called in "
                    .. "non-check mode")
            end,
        },
        flow_state = {},
    }
    if overrides then
        for k, v in pairs(overrides) do s[k] = v end
    end
    return s
end

-- ─── factory validation ───────────────────────────────────────────────

describe("dispatcher._for_test.build_core_dispatch — state validation",
    function()
    it("errors when state is not a table", function()
        local ok, err = pcall(
            dispatcher._for_test.build_core_dispatch, "bad")
        expect(ok).to.equal(false)
        expect(contains(err, "state must be a table")).to.equal(true)
    end)

    it("errors when state.builder is non-function", function()
        local ok, err = pcall(
            dispatcher._for_test.build_core_dispatch, {
                builder = "x",
                frame_pkg = { check_mode = function() return "non-check" end },
                flow_state = {},
            })
        expect(ok).to.equal(false)
        expect(contains(err, "state.builder must be a function"))
            .to.equal(true)
    end)

    it("errors when state.frame_pkg.check_mode is missing / non-function",
        function()
        local ok1, err1 = pcall(
            dispatcher._for_test.build_core_dispatch, {
                builder = function() return "p" end,
                frame_pkg = {},
                flow_state = {},
            })
        expect(ok1).to.equal(false)
        expect(contains(err1, "frame_pkg.check_mode")).to.equal(true)

        local ok2, err2 = pcall(
            dispatcher._for_test.build_core_dispatch, {
                builder = function() return "p" end,
                frame_pkg = { check_mode = "x" },
                flow_state = {},
            })
        expect(ok2).to.equal(false)
        expect(contains(err2, "frame_pkg.check_mode")).to.equal(true)
    end)

    it("errors when state.flow_state is non-table", function()
        local ok, err = pcall(
            dispatcher._for_test.build_core_dispatch, {
                builder = function() return "p" end,
                frame_pkg = { check_mode = function() return "non-check" end },
                flow_state = "x",
            })
        expect(ok).to.equal(false)
        expect(contains(err, "flow_state")).to.equal(true)
    end)
end)

-- ─── non-check mode orchestration ─────────────────────────────────────

describe("core_dispatch — non-check mode", function()
    it("orchestrates builder → route_llm (alc.llm) and returns the response",
        function()
        local cd = dispatcher._for_test.build_core_dispatch(make_mock_state())
        local response = cd({ x = 1 }, { step = "s1" })
        expect(response).to.equal("RESPONSE for PROMPT for s1")
    end)

    it("merges spec.llm_opts_overlay over llm_opts_base before routing",
        function()
        local captured_opts
        local state = make_mock_state({
            alc_pkg = {
                llm = function(_prompt, opts)
                    captured_opts = opts
                    return "ok"
                end,
                json_decode = function() end,
            },
        })
        local cd = dispatcher._for_test.build_core_dispatch(state)
        cd({ llm_opts_overlay = { temperature = 0.1, max_tokens = 100 } },
            { step = "s1" })
        expect(captured_opts.temperature).to.equal(0.1) -- overlay won
        expect(captured_opts.max_tokens).to.equal(100)
    end)

    it("does NOT invoke format_postverify in non-check mode (raw "
        .. "response passthrough)", function()
        -- json_decode raises if accidentally called; passing through
        -- non-check should NOT invoke format_postverify even when
        -- response is malformed.
        local state = make_mock_state({
            alc_pkg = {
                llm = function() return "{bad json" end,
                json_decode = function()
                    error("postverify should not run in non-check mode")
                end,
            },
        })
        local cd = dispatcher._for_test.build_core_dispatch(state)
        local response = cd({}, { step = "s1" })
        expect(response).to.equal("{bad json") -- passed through verbatim
    end)

    it("identity-preserves llm_opts_base when spec.llm_opts_overlay "
        .. "is nil", function()
        local captured
        local base = { temperature = 0.7, system = "S" }
        local state = make_mock_state({
            llm_opts_base = base,
            alc_pkg = {
                llm = function(_p, opts)
                    captured = opts
                    return "ok"
                end,
                json_decode = function() end,
            },
        })
        local cd = dispatcher._for_test.build_core_dispatch(state)
        cd({}, { step = "s1" })
        -- merge_llm_opts identity: same table reference when overlay is nil.
        expect(captured).to.equal(base)
    end)
end)

-- ─── strict mode orchestration ────────────────────────────────────────

describe("core_dispatch — strict mode", function()
    it("routes through flow.llm_bound when frame.check_mode returns strict",
        function()
        local captured
        local cd = dispatcher._for_test.build_core_dispatch({
            builder = function(step) return "P:" .. step end,
            llm_opts_base = nil,
            frame_pkg = { check_mode = function() return "strict" end },
            alc_pkg = {
                llm = function()
                    error("alc.llm should not be called in strict mode")
                end,
                json_decode = function() end,
            },
            flow_pkg = {
                llm_bound = function(state, opts)
                    captured = { state = state, opts = opts }
                    return "STRICT_RESPONSE"
                end,
            },
            flow_state = { id = "fs1" },
        })
        local response = cd({}, { step = "s2" })
        expect(response).to.equal("STRICT_RESPONSE")
        expect(captured.state.id).to.equal("fs1")
        expect(captured.opts.slot).to.equal("s2")
        expect(captured.opts.prompt).to.equal("P:s2")
    end)
end)

-- ─── format mode orchestration + post-verify ──────────────────────────

describe("core_dispatch — format mode + post-verify", function()
    it("invokes format_postverify after route_llm in format mode (PASS path)",
        function()
        local valid_json =
            '{"status":"ok","flow_token":"t1","flow_slot":"s3"}'
        local cd = dispatcher._for_test.build_core_dispatch({
            builder = function() return "P" end,
            llm_opts_base = nil,
            frame_pkg = { check_mode = function() return "format" end },
            alc_pkg = {
                llm = function()
                    error("format mode routes through flow.llm_bound")
                end,
                json_decode = function(_s)
                    return {
                        status = "ok",
                        flow_token = "t1",
                        flow_slot = "s3",
                    }
                end,
            },
            flow_pkg = {
                llm_bound = function() return valid_json end,
            },
            flow_state = {},
        })
        local response = cd({}, { step = "s3" })
        expect(response).to.equal(valid_json)
    end)

    it("returns BLOCKED string when format_postverify rejects "
        .. "(non-json response)", function()
        local cd = dispatcher._for_test.build_core_dispatch({
            builder = function() return "P" end,
            llm_opts_base = nil,
            frame_pkg = { check_mode = function() return "format" end },
            alc_pkg = {
                llm = function() error("nope") end,
                json_decode = function() return nil end,
            },
            flow_pkg = {
                llm_bound = function() return "no-json-here" end,
            },
            flow_state = {},
        })
        local response = cd({}, { step = "s4" })
        expect(contains(response, "BLOCKED")).to.equal(true)
        expect(contains(response, "format-non-json")).to.equal(true)
        expect(contains(response, "slot=s4")).to.equal(true)
    end)
end)

-- ─── ctx validation ───────────────────────────────────────────────────

describe("core_dispatch — ctx validation", function()
    it("errors when ctx.step is missing", function()
        local cd = dispatcher._for_test.build_core_dispatch(make_mock_state())
        local ok, err = pcall(cd, {}, {})
        expect(ok).to.equal(false)
        expect(contains(err, "ctx.step must be a string")).to.equal(true)
    end)

    it("errors when ctx is not a table", function()
        local cd = dispatcher._for_test.build_core_dispatch(make_mock_state())
        local ok, err = pcall(cd, {}, "not-a-table")
        expect(ok).to.equal(false)
        expect(contains(err, "ctx.step must be a string")).to.equal(true)
    end)
end)
