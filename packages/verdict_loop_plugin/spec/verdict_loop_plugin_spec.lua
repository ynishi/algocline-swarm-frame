-- verdict_loop_plugin_spec.lua — unit spec for verdict_loop_plugin
--
-- DSL 規約: lust global は alc_pkg_test runner が auto-inject する。
-- package.path 手動設定禁止 (anti-pattern §8-7-36 / worktree-absolute-path-leak)。
-- search_paths=["<project_root>/packages"] を alc_pkg_test の引数で注入すること。

local vlp = require("verdict_loop_plugin")
local describe, it, expect = lust.describe, lust.it, lust.expect

-- ─── helpers ────────────────────────────────────────────────────────

-- Plain-substring assertion (lust `.match` uses Lua patterns; use this for literals).
local function contains(s, sub) return type(s) == "string" and string.find(s, sub, 1, true) ~= nil end

-- Build a minimal mock ctx with a controllable ctx.dispatch stub.
-- dispatch_responses: list of return values for successive ctx.dispatch calls.
local function make_mock_ctx(dispatch_responses, extra_fields)
    local calls = {}
    local idx = 0
    local ctx = {
        _dispatch_calls = calls,
    }
    ctx.dispatch = function(spec)
        idx = idx + 1
        table.insert(calls, spec)
        if dispatch_responses and dispatch_responses[idx] then return dispatch_responses[idx] end
        return "FIX_RESPONSE"
    end
    if extra_fields then
        for k, v in pairs(extra_fields) do
            ctx[k] = v
        end
    end
    return ctx
end

-- Build a simple parser that always returns "pass".
local function parser_pass()
    return function(_resp, _ctx) return "pass" end
end

-- Build a parser that always returns "blocked".
local function parser_blocked()
    return function(_resp, _ctx) return "blocked" end
end

-- Build a parser that returns "pass" on the N-th call (1-indexed), blocked before.
local function parser_pass_on(n)
    local count = 0
    return function(_resp, _ctx)
        count = count + 1
        if count >= n then return "pass" end
        return "blocked"
    end
end

-- Build a mock inner() that records calls and returns a fixed response.
-- Each entry in calls_out is { spec=spec, ctx=ctx }.
local function make_inner(response, calls_out)
    calls_out = calls_out or {}
    return function(spec, ctx)
        table.insert(calls_out, { spec = spec, ctx = ctx })
        return response or "GATE_RESPONSE"
    end,
        calls_out
end

-- ─── specs ──────────────────────────────────────────────────────────

describe("verdict_loop_plugin", function()
    -- ──────────────────────────────────────────────────────────────────
    -- M.meta
    -- ──────────────────────────────────────────────────────────────────

    describe("M.meta", function()
        it("has name verdict_loop_plugin", function() expect(vlp.meta.name).to.equal("verdict_loop_plugin") end)

        it("has version 0.1.0", function() expect(vlp.meta.version).to.equal("0.1.0") end)

        it("has category frame_plugin", function() expect(vlp.meta.category).to.equal("frame_plugin") end)
    end)

    -- ──────────────────────────────────────────────────────────────────
    -- M.create validation
    -- ──────────────────────────────────────────────────────────────────

    describe("M.create validation", function()
        it("errors when step_id is missing", function()
            local ok, err = pcall(vlp.create, {
                gate_spec = { agent = "@gate" },
                parser = parser_pass(),
            })
            expect(ok).to.equal(false)
            expect(contains(err, "opts.step_id must be a non-empty string")).to.equal(true)
        end)

        it("errors when step_id is empty string", function()
            local ok, err = pcall(vlp.create, {
                step_id = "",
                gate_spec = { agent = "@gate" },
                parser = parser_pass(),
            })
            expect(ok).to.equal(false)
            expect(contains(err, "opts.step_id must be a non-empty string")).to.equal(true)
        end)

        it("errors when step_id is not a string", function()
            local ok, err = pcall(vlp.create, {
                step_id = 42,
                gate_spec = { agent = "@gate" },
                parser = parser_pass(),
            })
            expect(ok).to.equal(false)
            expect(contains(err, "opts.step_id must be a non-empty string")).to.equal(true)
        end)

        it("errors when gate_spec is missing", function()
            local ok, err = pcall(vlp.create, {
                step_id = "GATE",
                parser = parser_pass(),
            })
            expect(ok).to.equal(false)
            expect(contains(err, "opts.gate_spec must be a table")).to.equal(true)
        end)

        it("errors when gate_spec.agent is missing", function()
            local ok, err = pcall(vlp.create, {
                step_id = "GATE",
                gate_spec = {},
                parser = parser_pass(),
            })
            expect(ok).to.equal(false)
            expect(contains(err, "opts.gate_spec.agent must be a non-empty string")).to.equal(true)
        end)

        it("errors when gate_spec.agent is empty string", function()
            local ok, err = pcall(vlp.create, {
                step_id = "GATE",
                gate_spec = { agent = "" },
                parser = parser_pass(),
            })
            expect(ok).to.equal(false)
            expect(contains(err, "opts.gate_spec.agent must be a non-empty string")).to.equal(true)
        end)

        it("errors when parser is missing", function()
            local ok, err = pcall(vlp.create, {
                step_id = "GATE",
                gate_spec = { agent = "@gate" },
            })
            expect(ok).to.equal(false)
            expect(contains(err, "opts.parser must be a function")).to.equal(true)
        end)

        it("errors when parser is not a function", function()
            local ok, err = pcall(vlp.create, {
                step_id = "GATE",
                gate_spec = { agent = "@gate" },
                parser = "not_a_function",
            })
            expect(ok).to.equal(false)
            expect(contains(err, "opts.parser must be a function")).to.equal(true)
        end)

        it("succeeds with required fields only", function()
            local ok, plugin = pcall(vlp.create, {
                step_id = "GATE",
                gate_spec = { agent = "@gate" },
                parser = parser_pass(),
            })
            expect(ok).to.equal(true)
            expect(type(plugin)).to.equal("table")
        end)
    end)

    -- ──────────────────────────────────────────────────────────────────
    -- Plugin instance shape (AC-3)
    -- ──────────────────────────────────────────────────────────────────

    describe("plugin instance shape", function()
        it("has name verdict_loop_plugin:<step_id>", function()
            local plugin = vlp.create({
                step_id = "MY_STEP",
                gate_spec = { agent = "@gate" },
                parser = parser_pass(),
            })
            expect(plugin.name).to.equal("verdict_loop_plugin:MY_STEP")
        end)

        it("has around_step function", function()
            local plugin = vlp.create({
                step_id = "MY_STEP",
                gate_spec = { agent = "@gate" },
                parser = parser_pass(),
            })
            expect(type(plugin.around_step)).to.equal("function")
        end)

        it("has step_writes = { step_id }", function()
            local plugin = vlp.create({
                step_id = "MY_STEP",
                gate_spec = { agent = "@gate" },
                parser = parser_pass(),
            })
            expect(type(plugin.step_writes)).to.equal("table")
            expect(plugin.step_writes[1]).to.equal("MY_STEP")
            expect(#plugin.step_writes).to.equal(1)
        end)
    end)

    -- ──────────────────────────────────────────────────────────────────
    -- around_step: transparent passthrough for different step_id (AC-4)
    -- ──────────────────────────────────────────────────────────────────

    describe("around_step passthrough", function()
        it("calls inner directly for a different step_id", function()
            local plugin = vlp.create({
                step_id = "TARGET_STEP",
                gate_spec = { agent = "@gate" },
                parser = parser_pass(),
            })
            local inner, inner_calls = make_inner("OTHER_RESPONSE")
            local ctx = make_mock_ctx()

            local result = plugin.around_step(inner, "OTHER_STEP", { agent = "@other" }, ctx)

            expect(result).to.equal("OTHER_RESPONSE")
            expect(#inner_calls).to.equal(1)
            -- ctx.dispatch should NOT be called for passthrough step
            expect(#ctx._dispatch_calls).to.equal(0)
        end)

        it("does NOT call inner with gate_spec for a different step_id", function()
            local plugin = vlp.create({
                step_id = "TARGET_STEP",
                gate_spec = { agent = "@gate" },
                parser = parser_pass(),
            })
            local passthrough_spec = { agent = "@other-agent" }
            local inner, inner_calls = make_inner("PASS_RESP")
            local ctx = make_mock_ctx()

            plugin.around_step(inner, "OTHER_STEP", passthrough_spec, ctx)

            -- inner should be called with the original step_spec, not gate_spec
            expect(inner_calls[1].spec).to.equal(passthrough_spec)
        end)
    end)

    -- ──────────────────────────────────────────────────────────────────
    -- around_step: single-attempt pass (AC-5)
    -- ──────────────────────────────────────────────────────────────────

    describe("around_step single pass", function()
        it("returns gate response on first attempt pass", function()
            local plugin = vlp.create({
                step_id = "GATE",
                gate_spec = { agent = "@gate" },
                parser = parser_pass(),
            })
            local inner, inner_calls = make_inner("GATE_PASS_RESP")
            local ctx = make_mock_ctx()

            local result = plugin.around_step(inner, "GATE", {}, ctx)

            expect(result).to.equal("GATE_PASS_RESP")
            expect(#inner_calls).to.equal(1)
            -- inner called with gate_spec
            expect(inner_calls[1].spec.agent).to.equal("@gate")
            -- no fix dispatch
            expect(#ctx._dispatch_calls).to.equal(0)
        end)
    end)

    -- ──────────────────────────────────────────────────────────────────
    -- around_step: fix_spec=nil → 1 attempt only, then exhausted (AC-7)
    -- ──────────────────────────────────────────────────────────────────

    describe("around_step fix_spec=nil", function()
        it("executes only 1 attempt even when max_retries=3", function()
            local plugin = vlp.create({
                step_id = "GATE",
                gate_spec = { agent = "@gate" },
                parser = parser_blocked(),
                fix_spec = nil,
                max_retries = 3,
            })
            local inner, inner_calls = make_inner("BLOCKED_RESP")
            local ctx = make_mock_ctx()

            local result = plugin.around_step(inner, "GATE", {}, ctx)

            -- Only 1 gate dispatch regardless of max_retries
            expect(#inner_calls).to.equal(1)
            -- No fix dispatch
            expect(#ctx._dispatch_calls).to.equal(0)
            -- Returns exhausted BLOCKED
            expect(contains(result, "verdict_loop_plugin.exhausted")).to.equal(true)
            expect(contains(result, "attempts=1")).to.equal(true)
        end)
    end)

    -- ──────────────────────────────────────────────────────────────────
    -- around_step: fix dispatch on blocked (AC-8)
    -- ──────────────────────────────────────────────────────────────────

    describe("around_step with fix_spec", function()
        it("calls ctx.dispatch(fix_spec) when blocked before last attempt", function()
            local plugin = vlp.create({
                step_id = "GATE",
                gate_spec = { agent = "@gate" },
                fix_spec = { agent = "@fix" },
                parser = parser_blocked(),
                max_retries = 2,
            })
            local inner, _ = make_inner("BLOCKED_RESP")
            local ctx = make_mock_ctx()

            plugin.around_step(inner, "GATE", {}, ctx)

            -- fix dispatch should be called on each blocked attempt before last
            -- (max_retries=2 + parser blocked all → 3 attempts, 2 fix dispatches)
            expect(#ctx._dispatch_calls).to.equal(2)
            expect(ctx._dispatch_calls[1].agent).to.equal("@fix")
            expect(ctx._dispatch_calls[2].agent).to.equal("@fix")
        end)

        it("passes on second attempt after fix", function()
            local plugin = vlp.create({
                step_id = "GATE",
                gate_spec = { agent = "@gate" },
                fix_spec = { agent = "@fix" },
                parser = parser_pass_on(2),
                max_retries = 2,
            })
            local inner, inner_calls = make_inner("GATE_RESP")
            local ctx = make_mock_ctx()

            local result = plugin.around_step(inner, "GATE", {}, ctx)

            -- Should pass on second attempt
            expect(result).to.equal("GATE_RESP")
            expect(#inner_calls).to.equal(2)
            -- fix dispatched once
            expect(#ctx._dispatch_calls).to.equal(1)
        end)

        it("returns exhausted after max_retries+1 attempts all blocked", function()
            local plugin = vlp.create({
                step_id = "GATE",
                gate_spec = { agent = "@gate" },
                fix_spec = { agent = "@fix" },
                parser = parser_blocked(),
                max_retries = 2,
            })
            local inner, inner_calls = make_inner("BLOCKED_RESP")
            local ctx = make_mock_ctx()

            local result = plugin.around_step(inner, "GATE", {}, ctx)

            -- max_retries+1 = 3 attempts
            expect(#inner_calls).to.equal(3)
            expect(contains(result, "verdict_loop_plugin.exhausted")).to.equal(true)
            expect(contains(result, "plugin=verdict_loop_plugin:GATE")).to.equal(true)
            expect(contains(result, "attempts=3")).to.equal(true)
        end)

        it("exhausted response starts with BLOCKED", function()
            local plugin = vlp.create({
                step_id = "GATE",
                gate_spec = { agent = "@gate" },
                fix_spec = { agent = "@fix" },
                parser = parser_blocked(),
                max_retries = 1,
            })
            local inner, _ = make_inner("BLOCKED_RESP")
            local ctx = make_mock_ctx()

            local result = plugin.around_step(inner, "GATE", {}, ctx)

            expect(string.sub(result, 1, 7)).to.equal("BLOCKED")
        end)
    end)

    -- ──────────────────────────────────────────────────────────────────
    -- around_step: ctx.dispatch BLOCKED propagation (AC-10)
    -- ──────────────────────────────────────────────────────────────────

    describe("around_step ctx.dispatch BLOCKED propagation", function()
        it("returns exhausted immediately when fix dispatch returns BLOCKED", function()
            local plugin = vlp.create({
                step_id = "GATE",
                gate_spec = { agent = "@gate" },
                fix_spec = { agent = "@fix" },
                parser = parser_blocked(),
                max_retries = 3,
            })
            local inner, inner_calls = make_inner("BLOCKED_RESP")
            -- ctx.dispatch returns a BLOCKED string (Middle safeguard)
            local ctx = make_mock_ctx({ "BLOCKED reason=swarm_frame_algocline.max_dispatch_per_step" })

            local result = plugin.around_step(inner, "GATE", {}, ctx)

            -- Should stop after 1 gate attempt + 1 failed fix dispatch
            expect(#inner_calls).to.equal(1)
            expect(#ctx._dispatch_calls).to.equal(1)
            expect(contains(result, "verdict_loop_plugin.exhausted")).to.equal(true)
            -- fix_blocked info should be present
            expect(contains(result, "fix_blocked=BLOCKED")).to.equal(true)
        end)
    end)

    -- ──────────────────────────────────────────────────────────────────
    -- around_step: verdict_key shared-ref (AC-11)
    -- ──────────────────────────────────────────────────────────────────

    describe("around_step verdict_key", function()
        it("passes ctx[verdict_key] as third arg to parser when verdict_key is set", function()
            local received_verdict_ref = {}
            local parser_with_key = function(resp, ctx, verdict_ref)
                table.insert(received_verdict_ref, verdict_ref)
                return "pass"
            end

            local ctx = make_mock_ctx(nil, { _gate_verdict = "some_verdict_value" })

            local plugin = vlp.create({
                step_id = "GATE",
                gate_spec = { agent = "@gate" },
                parser = parser_with_key,
                verdict_key = "_gate_verdict",
            })
            local inner, _ = make_inner("GATE_RESP")

            plugin.around_step(inner, "GATE", {}, ctx)

            expect(received_verdict_ref[1]).to.equal("some_verdict_value")
        end)

        it("does not pass verdict_ref when verdict_key is nil", function()
            local arg_count = {}
            local counting_parser = function(...)
                local args = { ... }
                table.insert(arg_count, #args)
                return "pass"
            end

            local plugin = vlp.create({
                step_id = "GATE",
                gate_spec = { agent = "@gate" },
                parser = counting_parser,
            })
            local inner, _ = make_inner("GATE_RESP")
            local ctx = make_mock_ctx()

            plugin.around_step(inner, "GATE", {}, ctx)

            -- parser called with (resp, ctx) = 2 args when no verdict_key
            expect(arg_count[1]).to.equal(2)
        end)
    end)

    -- ──────────────────────────────────────────────────────────────────
    -- max_retries default (AC-2)
    -- ──────────────────────────────────────────────────────────────────

    describe("max_retries default", function()
        it("defaults to 2 (3 total attempts) when not specified", function()
            local plugin = vlp.create({
                step_id = "GATE",
                gate_spec = { agent = "@gate" },
                fix_spec = { agent = "@fix" },
                parser = parser_blocked(),
            })
            local inner, inner_calls = make_inner("BLOCKED_RESP")
            local ctx = make_mock_ctx()

            plugin.around_step(inner, "GATE", {}, ctx)

            -- default max_retries=2 → 3 total attempts
            expect(#inner_calls).to.equal(3)
        end)
    end)

    -- ──────────────────────────────────────────────────────────────────
    -- inner() is called with gate_spec (Crux 2 related: inner receives spec)
    -- ──────────────────────────────────────────────────────────────────

    describe("inner called with gate_spec", function()
        it("calls inner with opts.gate_spec on each attempt", function()
            local gate_spec = { agent = "@quality-gate", extra = "data" }
            local plugin = vlp.create({
                step_id = "GATE",
                gate_spec = gate_spec,
                fix_spec = { agent = "@fix" },
                parser = parser_pass_on(2),
                max_retries = 2,
            })
            local inner, inner_calls = make_inner("RESP")
            local ctx = make_mock_ctx()

            plugin.around_step(inner, "GATE", {}, ctx)

            -- Both calls should use gate_spec
            expect(inner_calls[1].spec).to.equal(gate_spec)
            expect(inner_calls[2].spec).to.equal(gate_spec)
        end)
    end)

    -- ──────────────────────────────────────────────────────────────────
    -- inner receives ctx as second argument (inner-ctx-missing fix)
    -- ──────────────────────────────────────────────────────────────────

    describe("inner receives ctx", function()
        it("passes ctx as second argument to inner on gate dispatch", function()
            local gate_spec = { agent = "@gate" }
            local plugin = vlp.create({
                step_id = "GATE",
                gate_spec = gate_spec,
                parser = parser_pass(),
            })
            local inner, inner_calls = make_inner("GATE_RESP")
            local ctx = make_mock_ctx()

            plugin.around_step(inner, "GATE", {}, ctx)

            -- inner must receive ctx as its second argument
            expect(inner_calls[1].ctx).to.equal(ctx)
        end)

        it("passes ctx as second argument to inner on passthrough", function()
            local plugin = vlp.create({
                step_id = "TARGET_STEP",
                gate_spec = { agent = "@gate" },
                parser = parser_pass(),
            })
            local passthrough_spec = { agent = "@other" }
            local inner, inner_calls = make_inner("OTHER_RESP")
            local ctx = make_mock_ctx()

            plugin.around_step(inner, "OTHER_STEP", passthrough_spec, ctx)

            -- passthrough also forwards ctx
            expect(inner_calls[1].ctx).to.equal(ctx)
        end)
    end)

    -- ──────────────────────────────────────────────────────────────────
    -- alc.toml version assertion (AC-12)
    -- ──────────────────────────────────────────────────────────────────

    describe("version", function()
        it("M.VERSION is 0.1.0", function() expect(vlp.VERSION).to.equal("0.1.0") end)
    end)
end)
