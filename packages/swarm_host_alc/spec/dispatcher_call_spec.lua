-- dispatcher_call_spec.lua — Boundary regression spec for the __call
-- lifecycle land in Step 6.5 (V3 clean restart 最終 step).
--
-- Exposed via `_for_test.build_call(state)` factory. The factory wires
-- step lifecycle hooks (before/around/after_step) around dispatch_chain,
-- threads ctx.dispatch as the recursive primitive (with safeguard
-- counters), and implements the step-skip path for recursive calls.
--
-- Coverage:
--   * state validation
--   * empty plugins → dispatch_chain direct
--   * before_step / after_step sequential
--   * around_step onion (plugins[1] = OUTERMOST)
--   * step skip path (ctx supplied = recursive)
--   * ctx.dispatch recursive call (re-enter via _self)
--   * max_recursion_depth safeguard
--   * max_dispatch_per_step safeguard
--   * BLOCKED_panic on before_step / around_step / after_step raise
--   * response nil/false → error (#11)

local lust = require("lust")
local describe, it, expect = lust.describe, lust.it, lust.expect

local dispatcher = require("swarm_host_alc.dispatcher")

local function contains(s, sub)
    return type(s) == "string" and string.find(s, sub, 1, true) ~= nil
end

local function default_make_ctx_state()
    return {
        frame_pkg = {
            step_id_of = function(p) return tostring(p) end,
            parse_verdict = function() end,
        },
        flow_state = {},
        extras = {},
    }
end

local function build_call(overrides)
    overrides = overrides or {}
    local state = {
        plugins = overrides.plugins or {},
        dispatch_chain = overrides.dispatch_chain
            or function(_s, _c) return "CHAIN" end,
        llm_call_raw = overrides.llm_call_raw or function() return "AUX" end,
        make_ctx_state = overrides.make_ctx_state
            or default_make_ctx_state(),
        safeguard = overrides.safeguard
            or { max_dispatch_per_step = 16, max_recursion_depth = 4 },
    }
    return dispatcher._for_test.build_call(state)
end

-- Build a minimal callable table mock: invoking `mock(path, spec, ctx)`
-- forwards to the call_fn (= __call body) with the table itself as `self`.
local function make_callable(call_fn)
    return setmetatable({}, {
        __call = function(self, path, spec, ctx)
            return call_fn(self, path, spec, ctx)
        end,
    })
end

-- ─── state validation ────────────────────────────────────────────────

describe("dispatcher._for_test.build_call — state validation", function()
    it("errors on invalid state shape", function()
        local ok1, err1 = pcall(dispatcher._for_test.build_call, "bad")
        expect(ok1).to.equal(false)
        expect(contains(err1, "state must be a table")).to.equal(true)

        local mks = default_make_ctx_state()

        local ok2, err2 = pcall(dispatcher._for_test.build_call, {
            plugins = "x",
            dispatch_chain = function() end,
            llm_call_raw = function() end,
            make_ctx_state = mks,
            safeguard = {},
        })
        expect(ok2).to.equal(false)
        expect(contains(err2, "plugins must be a list")).to.equal(true)

        local ok3, err3 = pcall(dispatcher._for_test.build_call, {
            plugins = {},
            dispatch_chain = "x",
            llm_call_raw = function() end,
            make_ctx_state = mks,
            safeguard = {},
        })
        expect(ok3).to.equal(false)
        expect(contains(err3, "dispatch_chain must be a function")).to.equal(true)

        local ok4, err4 = pcall(dispatcher._for_test.build_call, {
            plugins = {},
            dispatch_chain = function() end,
            llm_call_raw = "x",
            make_ctx_state = mks,
            safeguard = {},
        })
        expect(ok4).to.equal(false)
        expect(contains(err4, "llm_call_raw must be a function")).to.equal(true)
    end)
end)

-- ─── normal path: empty plugins ──────────────────────────────────────

describe("__call — empty plugins (no step lifecycle hooks)", function()
    it("invokes dispatch_chain directly and returns its response", function()
        local call_fn = build_call({
            dispatch_chain = function(_s, _c) return "DC_RESPONSE" end,
        })
        local mock = make_callable(call_fn)
        local response = mock("step_a", { x = 1 })
        expect(response).to.equal("DC_RESPONSE")
    end)
end)

-- ─── before_step / after_step sequential ─────────────────────────────

describe("__call — before_step / after_step sequential", function()
    it("invokes plugins[1] → [N] sequentially around dispatch_chain",
        function()
        local trace = {}
        local plugins = {
            { name = "p1", hooks = {
                before_step = function(step_id, _spec, _ctx)
                    table.insert(trace, "p1:before_step:" .. step_id)
                end,
                after_step = function(resp, step_id, _spec, _ctx)
                    table.insert(trace, "p1:after_step:" .. step_id .. ":" .. resp)
                end,
            }},
            { name = "p2", hooks = {
                before_step = function(step_id)
                    table.insert(trace, "p2:before_step:" .. step_id)
                end,
                after_step = function(resp, step_id)
                    table.insert(trace, "p2:after_step:" .. step_id .. ":" .. resp)
                end,
            }},
        }
        local call_fn = build_call({
            plugins = plugins,
            dispatch_chain = function()
                table.insert(trace, "dc")
                return "R"
            end,
        })
        local mock = make_callable(call_fn)
        mock("s1", {})
        expect(trace[1]).to.equal("p1:before_step:s1")
        expect(trace[2]).to.equal("p2:before_step:s1")
        expect(trace[3]).to.equal("dc")
        expect(trace[4]).to.equal("p1:after_step:s1:R")
        expect(trace[5]).to.equal("p2:after_step:s1:R")
    end)
end)

-- ─── around_step onion (plugins[1] = OUTERMOST) ──────────────────────

describe("__call — around_step onion wrap (plugins[1] = OUTERMOST)",
    function()
    it("wraps in reverse iteration so plugins[1] sees step first / "
        .. "response last", function()
        local trace = {}
        local plugins = {
            { name = "p1", hooks = {
                around_step = function(inner, step_id, s, c)
                    table.insert(trace, "p1:around_start:" .. step_id)
                    local r = inner(s, c)
                    table.insert(trace, "p1:around_end:" .. r)
                    return r .. ":p1"
                end,
            }},
            { name = "p2", hooks = {
                around_step = function(inner, step_id, s, c)
                    table.insert(trace, "p2:around_start:" .. step_id)
                    local r = inner(s, c)
                    table.insert(trace, "p2:around_end:" .. r)
                    return r .. ":p2"
                end,
            }},
        }
        local call_fn = build_call({
            plugins = plugins,
            dispatch_chain = function()
                table.insert(trace, "dc")
                return "R"
            end,
        })
        local mock = make_callable(call_fn)
        local response = mock("s2", {})
        expect(trace[1]).to.equal("p1:around_start:s2")
        expect(trace[2]).to.equal("p2:around_start:s2")
        expect(trace[3]).to.equal("dc")
        expect(trace[4]).to.equal("p2:around_end:R")
        expect(trace[5]).to.equal("p1:around_end:R:p2")
        expect(response).to.equal("R:p2:p1")
    end)
end)

-- ─── step skip path (recursive ctx.dispatch) ─────────────────────────

describe("__call — step skip path (recursive ctx.dispatch)", function()
    it("skips step lifecycle when ctx is supplied externally", function()
        local trace = {}
        local plugins = {
            { name = "p1", hooks = {
                before_step = function() table.insert(trace, "before_step") end,
                after_step = function() table.insert(trace, "after_step") end,
            }},
        }
        local call_fn = build_call({
            plugins = plugins,
            dispatch_chain = function()
                table.insert(trace, "dc")
                return "R"
            end,
        })
        local mock = make_callable(call_fn)
        -- Inject a fake ctx to simulate ctx.dispatch recursive call.
        mock("s1", {}, { step = "s1", scratch = {} })
        -- Expected: only "dc" (step hooks skipped).
        expect(#trace).to.equal(1)
        expect(trace[1]).to.equal("dc")
    end)
end)

-- ─── ctx.dispatch recursive ──────────────────────────────────────────

describe("__call — ctx.dispatch threads same ctx through recursive _self",
    function()
    it("ctx.dispatch re-enters dispatcher with same ctx, step hooks "
        .. "fire ONCE", function()
        local trace = {}
        local plugins = {
            { name = "p1", hooks = {
                before_step = function(_step, _spec, ctx)
                    table.insert(trace, "before_step")
                    -- Recursively re-enter dispatcher via ctx.dispatch.
                    -- Step hooks must NOT re-fire (double-firing 防止).
                    ctx.scratch.recursive_result =
                        ctx.dispatch({ recursive = true })
                end,
                after_step = function()
                    table.insert(trace, "after_step")
                end,
            }},
        }
        local call_fn = build_call({
            plugins = plugins,
            dispatch_chain = function(_s, _c)
                table.insert(trace, "dc")
                return "DC"
            end,
        })
        local mock = make_callable(call_fn)
        mock("s1", {})
        -- before_step fires ONCE (recursive __call skips step hooks),
        -- dc fires TWICE (once for initial chain after before_step,
        -- once for recursive ctx.dispatch via step-skip path),
        -- after_step fires ONCE.
        local before_count, after_count, dc_count = 0, 0, 0
        for _, e in ipairs(trace) do
            if e == "before_step" then before_count = before_count + 1 end
            if e == "after_step" then after_count = after_count + 1 end
            if e == "dc" then dc_count = dc_count + 1 end
        end
        expect(before_count).to.equal(1)
        expect(after_count).to.equal(1)
        expect(dc_count).to.equal(2)
    end)
end)

-- ─── safeguard: max_recursion_depth ──────────────────────────────────

describe("__call — max_recursion_depth safeguard", function()
    it("returns BLOCKED when ctx.dispatch nesting exceeds max_recursion_depth",
        function()
        -- dispatch_chain self-recursive via ctx.dispatch: each chain
        -- invocation calls ctx.dispatch (= recursive __call with step
        -- skip = dispatch_chain re-enters). recursion_depth increments
        -- each ctx.dispatch call, safeguard cuts at depth > max.
        local invoke_count = 0
        local saw_blocked = false
        local call_fn = build_call({
            plugins = {},
            dispatch_chain = function(_s, ctx)
                invoke_count = invoke_count + 1
                if invoke_count > 20 then return "RUNAWAY_GUARD" end
                local r = ctx.dispatch({ iter = invoke_count })
                if type(r) == "string" and r:sub(1, 7) == "BLOCKED" then
                    saw_blocked = true
                end
                return r
            end,
            safeguard = { max_dispatch_per_step = 100,
                          max_recursion_depth = 3 },
        })
        local mock = make_callable(call_fn)
        mock("s1", {})
        -- max_recursion_depth=3, so depth=4 ctx.dispatch returns BLOCKED.
        expect(saw_blocked).to.equal(true)
        -- invoke_count bounded by safeguard (= didn't hit RUNAWAY_GUARD).
        expect(invoke_count <= 10).to.equal(true)
    end)
end)

-- ─── safeguard: max_dispatch_per_step ────────────────────────────────

describe("__call — max_dispatch_per_step safeguard", function()
    it("returns BLOCKED when a plugin invokes ctx.dispatch > max times",
        function()
        local results = {}
        local plugins = {
            { name = "p_burst", hooks = {
                before_step = function(_step, _spec, ctx)
                    -- Invoke ctx.dispatch 5 times; cap = 3.
                    for i = 1, 5 do
                        results[i] = ctx.dispatch({ iter = i })
                    end
                end,
            }},
        }
        local call_fn = build_call({
            plugins = plugins,
            dispatch_chain = function(_s, _c) return "OK" end,
            safeguard = { max_dispatch_per_step = 3,
                          max_recursion_depth = 10 },
        })
        local mock = make_callable(call_fn)
        mock("s1", {})
        -- First 3 calls return "OK", 4th returns BLOCKED max_dispatch_per_step.
        expect(results[1]).to.equal("OK")
        expect(results[2]).to.equal("OK")
        expect(results[3]).to.equal("OK")
        expect(contains(results[4], "BLOCKED")).to.equal(true)
        expect(contains(results[4], "max_dispatch_per_step")).to.equal(true)
    end)
end)

-- ─── BLOCKED_panic on hook raise ─────────────────────────────────────

describe("__call — BLOCKED_panic on step hook raise", function()
    it("returns BLOCKED string when before_step raises", function()
        local call_fn = build_call({
            plugins = {
                { name = "p_panic", hooks = {
                    before_step = function() error("kaboom") end,
                }},
            },
        })
        local mock = make_callable(call_fn)
        local response = mock("s1", {})
        expect(contains(response, "BLOCKED")).to.equal(true)
        expect(contains(response, "plugin_panic")).to.equal(true)
        expect(contains(response, "plugin=p_panic")).to.equal(true)
        expect(contains(response, "hook=before_step")).to.equal(true)
        expect(contains(response, "kaboom")).to.equal(true)
    end)

    it("returns BLOCKED string when around_step raises", function()
        local call_fn = build_call({
            plugins = {
                { name = "p_around_panic", hooks = {
                    around_step = function() error("around_boom") end,
                }},
            },
        })
        local mock = make_callable(call_fn)
        local response = mock("s2", {})
        expect(contains(response, "BLOCKED")).to.equal(true)
        expect(contains(response, "plugin_panic")).to.equal(true)
        expect(contains(response, "hook=around_step")).to.equal(true)
    end)

    it("returns BLOCKED string when after_step raises", function()
        local call_fn = build_call({
            plugins = {
                { name = "p_after_panic", hooks = {
                    after_step = function() error("after_boom") end,
                }},
            },
        })
        local mock = make_callable(call_fn)
        local response = mock("s3", {})
        expect(contains(response, "BLOCKED")).to.equal(true)
        expect(contains(response, "hook=after_step")).to.equal(true)
    end)
end)

-- ─── response nil/false → error (#11) ────────────────────────────────

describe("__call — response nil/false → error (#11)", function()
    it("throws when dispatch_chain returns nil", function()
        local call_fn = build_call({
            dispatch_chain = function() return nil end,
        })
        local mock = make_callable(call_fn)
        local ok, err = pcall(mock, "s1", {})
        expect(ok).to.equal(false)
        expect(contains(err, "dispatch returned nil")).to.equal(true)
        expect(contains(err, "V3 #11 reframe")).to.equal(true)
    end)

    it("throws when dispatch_chain returns false", function()
        local call_fn = build_call({
            dispatch_chain = function() return false end,
        })
        local mock = make_callable(call_fn)
        local ok, err = pcall(mock, "s1", {})
        expect(ok).to.equal(false)
        expect(contains(err, "dispatch returned false")).to.equal(true)
    end)
end)

-- ─── make_dispatcher integration: __call replaces placeholder ────────

describe("make_dispatcher — __call lifecycle replaces NotYetImplemented",
    function()
    it("dispatcher(path, spec) routes through dispatch_chain via __call",
        function()
        local trace = {}
        local d = dispatcher.make_dispatcher({
            builder = function(step, _spec)
                table.insert(trace, "builder:" .. step)
                return "P:" .. step
            end,
            flow_state = { data = { task_id = "t1" } },
            pkg_name = "integration_pkg",
            deps = {
                frame = {
                    check_mode = function() return "non-check" end,
                    step_id_of = function(p) return tostring(p) end,
                    parse_verdict = function() end,
                },
                alc = {
                    llm = function(prompt)
                        table.insert(trace, "llm:" .. prompt)
                        return "RESPONSE_" .. prompt
                    end,
                },
                flow = {},
            },
        })
        -- dispatcher_iface.check_call must still pass (#8b).
        local iface = require("swarm_frame.v3.contract.dispatcher_iface")
        local ok, err = iface.check_call(d)
        expect(ok).to.equal(true)
        expect(err).to.equal(nil)

        -- Actual __call works (no NotYetImplemented error).
        local response = d("step_x", {})
        expect(response).to.equal("RESPONSE_P:step_x")
        expect(trace[1]).to.equal("builder:step_x")
        expect(trace[2]).to.equal("llm:P:step_x")
    end)
end)
