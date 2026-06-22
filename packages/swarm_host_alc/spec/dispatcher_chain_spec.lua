-- dispatcher_chain_spec.lua — Boundary regression spec for the 3
-- factory seams added in Step 6.3:
--   * `_for_test.build_dispatch_chain(state)`
--       — before/around/after_dispatch onion + sequential wrap
--   * `_for_test.build_llm_call(state)`
--       — ctx.llm_call raw factory (slot default + overlay merge,
--         format_postverify skipped for protocol sub-calls)
--   * `_for_test.make_ctx(state, path_or_step, llm_call_raw, scratch?)`
--       — fresh ctx table per __call (#9), helpers sub-table (#3),
--         ctx.llm_call closure-binds ctx.step
--
-- ctx.dispatch (recursive + safeguard counters) is Step 6.5 carry —
-- closure-scoped _self accessor requires __call timing.

local lust = require("lust")
local describe, it, expect = lust.describe, lust.it, lust.expect

local dispatcher = require("swarm_host_alc.dispatcher")

local function contains(s, sub)
    return type(s) == "string" and string.find(s, sub, 1, true) ~= nil
end

-- ─── dispatch_chain ────────────────────────────────────────────────────

describe("dispatcher._for_test.build_dispatch_chain — state validation",
    function()
    it("errors on invalid state shape", function()
        local ok1, err1 = pcall(
            dispatcher._for_test.build_dispatch_chain, "bad")
        expect(ok1).to.equal(false)
        expect(contains(err1, "state must be a table")).to.equal(true)

        local ok2, err2 = pcall(
            dispatcher._for_test.build_dispatch_chain,
            { core_dispatch = "x", plugins = {} })
        expect(ok2).to.equal(false)
        expect(contains(err2, "core_dispatch must be a function"))
            .to.equal(true)

        local ok3, err3 = pcall(
            dispatcher._for_test.build_dispatch_chain,
            { core_dispatch = function() end, plugins = "x" })
        expect(ok3).to.equal(false)
        expect(contains(err3, "plugins must be a list")).to.equal(true)
    end)
end)

describe("dispatch_chain — empty plugins", function()
    it("reduces to core_dispatch direct call when plugins list is empty",
        function()
        local chain = dispatcher._for_test.build_dispatch_chain({
            core_dispatch = function(_s, _c) return "CORE" end,
            plugins = {},
        })
        local response = chain({ x = 1 }, { step = "s1" })
        expect(response).to.equal("CORE")
    end)
end)

describe("dispatch_chain — before_dispatch sequential", function()
    it("invokes plugins[1] → [N] sequentially with spec + ctx", function()
        local order = {}
        local chain = dispatcher._for_test.build_dispatch_chain({
            core_dispatch = function() return "CORE" end,
            plugins = {
                { name = "p1", hooks = {
                    before_dispatch = function(s, c)
                        table.insert(order, "p1:" .. s.x .. ":" .. c.step)
                    end,
                }},
                { name = "p2", hooks = {
                    before_dispatch = function(s, c)
                        table.insert(order, "p2:" .. s.x .. ":" .. c.step)
                    end,
                }},
                { name = "p3", hooks = {
                    before_dispatch = function(s, c)
                        table.insert(order, "p3:" .. s.x .. ":" .. c.step)
                    end,
                }},
            },
        })
        chain({ x = "X" }, { step = "s1" })
        expect(#order).to.equal(3)
        expect(order[1]).to.equal("p1:X:s1")
        expect(order[2]).to.equal("p2:X:s1")
        expect(order[3]).to.equal("p3:X:s1")
    end)
end)

describe("dispatch_chain — around_dispatch onion (plugins[1] = OUTERMOST)",
    function()
    it("wraps in reverse iteration so plugins[1] sees spec first / response last",
        function()
        local trace = {}
        local chain = dispatcher._for_test.build_dispatch_chain({
            core_dispatch = function(_s, _c)
                table.insert(trace, "core")
                return "core-response"
            end,
            plugins = {
                { name = "p1", hooks = {
                    around_dispatch = function(inner, s, c)
                        table.insert(trace, "p1:before")
                        local resp = inner(s, c)
                        table.insert(trace, "p1:after:" .. resp)
                        return resp .. ":p1"
                    end,
                }},
                { name = "p2", hooks = {
                    around_dispatch = function(inner, s, c)
                        table.insert(trace, "p2:before")
                        local resp = inner(s, c)
                        table.insert(trace, "p2:after:" .. resp)
                        return resp .. ":p2"
                    end,
                }},
            },
        })
        local response = chain({}, { step = "s1" })
        -- p1 = OUTERMOST so its before runs first, after runs last.
        expect(trace[1]).to.equal("p1:before")
        expect(trace[2]).to.equal("p2:before")
        expect(trace[3]).to.equal("core")
        expect(trace[4]).to.equal("p2:after:core-response")
        expect(trace[5]).to.equal("p1:after:core-response:p2")
        expect(response).to.equal("core-response:p2:p1")
    end)
end)

describe("dispatch_chain — after_dispatch sequential", function()
    it("invokes plugins[1] → [N] sequentially with response + spec + ctx",
        function()
        local seen = {}
        local chain = dispatcher._for_test.build_dispatch_chain({
            core_dispatch = function() return "R" end,
            plugins = {
                { name = "p1", hooks = {
                    after_dispatch = function(r, _s, c)
                        table.insert(seen, "p1:" .. r .. ":" .. c.step)
                    end,
                }},
                { name = "p2", hooks = {
                    after_dispatch = function(r, _s, c)
                        table.insert(seen, "p2:" .. r .. ":" .. c.step)
                    end,
                }},
            },
        })
        chain({}, { step = "s2" })
        expect(#seen).to.equal(2)
        expect(seen[1]).to.equal("p1:R:s2")
        expect(seen[2]).to.equal("p2:R:s2")
    end)
end)

describe("dispatch_chain — full flow (before + around + after)", function()
    it("runs before[1..N] → around onion → core → after[1..N] in one chain",
        function()
        local trace = {}
        local chain = dispatcher._for_test.build_dispatch_chain({
            core_dispatch = function()
                table.insert(trace, "core")
                return "CR"
            end,
            plugins = {
                { name = "p1", hooks = {
                    before_dispatch = function() table.insert(trace, "b1") end,
                    around_dispatch = function(inner, s, c)
                        table.insert(trace, "a1:start")
                        local r = inner(s, c)
                        table.insert(trace, "a1:end")
                        return r
                    end,
                    after_dispatch = function() table.insert(trace, "f1") end,
                }},
            },
        })
        chain({}, { step = "s1" })
        expect(trace[1]).to.equal("b1")
        expect(trace[2]).to.equal("a1:start")
        expect(trace[3]).to.equal("core")
        expect(trace[4]).to.equal("a1:end")
        expect(trace[5]).to.equal("f1")
    end)
end)

-- ─── ctx.llm_call factory ──────────────────────────────────────────────

describe("dispatcher._for_test.build_llm_call — state validation", function()
    it("errors on invalid state shape", function()
        local ok1, err1 = pcall(dispatcher._for_test.build_llm_call, "bad")
        expect(ok1).to.equal(false)
        expect(contains(err1, "state must be a table")).to.equal(true)

        local ok2, err2 = pcall(dispatcher._for_test.build_llm_call,
            { frame_pkg = {}, flow_state = {} })
        expect(ok2).to.equal(false)
        expect(contains(err2, "frame_pkg.check_mode")).to.equal(true)

        local ok3, err3 = pcall(dispatcher._for_test.build_llm_call, {
            frame_pkg = { check_mode = function() return "non-check" end },
            flow_state = "x",
        })
        expect(ok3).to.equal(false)
        expect(contains(err3, "flow_state")).to.equal(true)
    end)
end)

describe("ctx.llm_call — opts validation", function()
    local function make_state()
        return {
            frame_pkg = { check_mode = function() return "non-check" end },
            alc_pkg = { llm = function() return "ok" end },
            flow_pkg = {},
            flow_state = {},
        }
    end

    it("errors when opts is non-table / opts.prompt missing-or-empty / "
        .. "step_id missing-or-empty", function()
        local llm = dispatcher._for_test.build_llm_call(make_state())

        local ok1, err1 = pcall(llm, "bad", "step")
        expect(ok1).to.equal(false)
        expect(contains(err1, "opts must be a table")).to.equal(true)

        local ok2, err2 = pcall(llm, {}, "step")
        expect(ok2).to.equal(false)
        expect(contains(err2, "opts.prompt")).to.equal(true)

        local ok3, err3 = pcall(llm, { prompt = "" }, "step")
        expect(ok3).to.equal(false)
        expect(contains(err3, "opts.prompt")).to.equal(true)

        local ok4, err4 = pcall(llm, { prompt = "P" }, nil)
        expect(ok4).to.equal(false)
        expect(contains(err4, "step_id")).to.equal(true)

        local ok5, err5 = pcall(llm, { prompt = "P" }, "")
        expect(ok5).to.equal(false)
        expect(contains(err5, "step_id")).to.equal(true)
    end)
end)

describe("ctx.llm_call — non-check happy path", function()
    it("routes through alc.llm with default slot = step_id .. ':aux'",
        function()
        local captured
        local llm = dispatcher._for_test.build_llm_call({
            frame_pkg = { check_mode = function() return "non-check" end },
            alc_pkg = {
                llm = function(prompt, opts)
                    captured = { prompt = prompt, opts = opts }
                    return "AUX_RESPONSE"
                end,
            },
            flow_pkg = {},
            flow_state = {},
            llm_opts_base = { temperature = 0.5 },
        })
        local response = llm({ prompt = "QUERY" }, "s_outer")
        expect(response).to.equal("AUX_RESPONSE")
        expect(captured.prompt).to.equal("QUERY")
        expect(captured.opts.temperature).to.equal(0.5) -- base preserved
    end)

    it("respects explicit opts.slot and merges llm_opts_overlay over base",
        function()
        local captured_route
        local llm = dispatcher._for_test.build_llm_call({
            frame_pkg = { check_mode = function() return "strict" end },
            alc_pkg = { llm = function() error("nope") end },
            flow_pkg = {
                llm_bound = function(_state, opts)
                    captured_route = opts
                    return "STRICT_RESPONSE"
                end,
            },
            flow_state = {},
            llm_opts_base = { temperature = 0.5, system = "S" },
        })
        local response = llm({
            prompt = "Q",
            slot = "custom_slot",
            llm_opts_overlay = { temperature = 0.0 },
        }, "s_outer")
        expect(response).to.equal("STRICT_RESPONSE")
        expect(captured_route.slot).to.equal("custom_slot")
        expect(captured_route.prompt).to.equal("Q")
        expect(captured_route.llm_opts.temperature).to.equal(0.0) -- overlay
        expect(captured_route.llm_opts.system).to.equal("S") -- base preserved
    end)
end)

describe("ctx.llm_call — format mode skips format_postverify", function()
    it("does NOT invoke format_postverify even when mode=format "
        .. "(protocol sub-call semantics)", function()
        local llm = dispatcher._for_test.build_llm_call({
            frame_pkg = { check_mode = function() return "format" end },
            alc_pkg = {
                llm = function() error("format uses flow.llm_bound") end,
                json_decode = function()
                    error("format_postverify should NOT run on aux calls")
                end,
            },
            flow_pkg = {
                llm_bound = function() return "{not-a-valid-verdict}" end,
            },
            flow_state = {},
        })
        local response = llm({ prompt = "P" }, "s1")
        -- Passed through verbatim — no BLOCKED post-verify.
        expect(response).to.equal("{not-a-valid-verdict}")
    end)
end)

-- ─── ctx fresh-table builder ───────────────────────────────────────────

describe("dispatcher._for_test.make_ctx — input validation", function()
    it("errors on invalid state / frame_pkg / llm_call_raw shape", function()
        local ok1, err1 = pcall(dispatcher._for_test.make_ctx, "bad", "p")
        expect(ok1).to.equal(false)
        expect(contains(err1, "state must be a table")).to.equal(true)

        local ok2, err2 = pcall(dispatcher._for_test.make_ctx,
            { frame_pkg = {} }, "p")
        expect(ok2).to.equal(false)
        expect(contains(err2, "frame_pkg.step_id_of")).to.equal(true)

        local ok3, err3 = pcall(dispatcher._for_test.make_ctx,
            { frame_pkg = { step_id_of = function() return "s1" end } }, "p")
        expect(ok3).to.equal(false)
        expect(contains(err3, "llm_call_raw must be a function")).to.equal(true)
    end)
end)

describe("make_ctx — fresh table per call", function()
    it("returns a fresh table on each invocation (no shared mutable state)",
        function()
        local state = {
            frame_pkg = {
                step_id_of = function(p) return p end,
                parse_verdict = function() end,
            },
            flow_state = { id = "fs1" },
            extras = { x = 1 },
        }
        local llm_call = function() return "ok" end
        local c1 = dispatcher._for_test.make_ctx(state, "step_a", llm_call)
        local c2 = dispatcher._for_test.make_ctx(state, "step_b", llm_call)
        -- mutate-isolation = different references. lust's equal() is
        -- deep value compare, so identity-check via mutation is the
        -- reliable discriminator (mutating c1 must not affect c2).
        c1.scratch.probe = "c1_only"
        expect(c2.scratch.probe).to.equal(nil)
        c1.helpers.probe = "c1_only"
        expect(c2.helpers.probe).to.equal(nil)
    end)
end)

describe("make_ctx — field population (#3 helpers / #9 fresh)", function()
    it("exposes path/step/flow_state/extras/scratch/helpers/llm_call",
        function()
        local frame_pkg = {
            step_id_of = function(_p) return "step_x" end,
            parse_verdict = function() return "verdict_fn" end,
        }
        local llm_call = function() return "ok" end
        local ctx = dispatcher._for_test.make_ctx({
            frame_pkg = frame_pkg,
            flow_state = { id = "fs1" },
            extras = { e = 2 },
        }, "path_input", llm_call)

        expect(ctx.path).to.equal("path_input")
        expect(ctx.step).to.equal("step_x")
        expect(ctx.flow_state.id).to.equal("fs1")
        expect(ctx.extras.e).to.equal(2)
        expect(type(ctx.scratch)).to.equal("table")
        -- helpers sub-table (#3): references frame_pkg fns by reference.
        expect(ctx.helpers.parse_verdict).to.equal(frame_pkg.parse_verdict)
        expect(ctx.helpers.step_id_of).to.equal(frame_pkg.step_id_of)
        -- ctx.frame is NOT exposed (#3 撤去).
        expect(ctx.frame).to.equal(nil)
        -- llm_call attached as a closure.
        expect(type(ctx.llm_call)).to.equal("function")
        -- ctx.dispatch is NOT attached yet (Step 6.5 carry).
        expect(ctx.dispatch).to.equal(nil)
    end)

    it("accepts scratch_in to pre-populate ctx.scratch, defaults to fresh {}",
        function()
        local state = {
            frame_pkg = {
                step_id_of = function() return "s" end,
                parse_verdict = function() end,
            },
            flow_state = {},
        }
        local llm_call = function() end

        local provided = { memo = "carry" }
        local ctx1 = dispatcher._for_test.make_ctx(
            state, "p", llm_call, provided)
        expect(ctx1.scratch).to.equal(provided)
        expect(ctx1.scratch.memo).to.equal("carry")

        local ctx2 = dispatcher._for_test.make_ctx(state, "p", llm_call)
        expect(type(ctx2.scratch)).to.equal("table")
        expect(next(ctx2.scratch)).to.equal(nil) -- empty fresh table
    end)
end)

describe("make_ctx — ctx.llm_call closure-binds step_id", function()
    it("ctx.llm_call(opts) forwards (opts, ctx.step) to llm_call_raw",
        function()
        local captured_step
        local llm_call_raw = function(opts, step_id)
            captured_step = step_id
            return "OK:" .. opts.prompt
        end
        local ctx = dispatcher._for_test.make_ctx({
            frame_pkg = {
                step_id_of = function(_p) return "step_bound" end,
                parse_verdict = function() end,
            },
            flow_state = {},
        }, "path", llm_call_raw)

        local response = ctx.llm_call({ prompt = "Q" })
        expect(response).to.equal("OK:Q")
        expect(captured_step).to.equal("step_bound")
    end)
end)
