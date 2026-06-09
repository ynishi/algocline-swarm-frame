-- combinator_composability_spec.lua — Boundary test: combinators nest.
--
-- Combinators return Handlers, and the Handler contract is closed under
-- composition: any combinator may be passed as a sub-handler to any other
-- combinator. This is the Engine's core value proposition (mechanism /
-- policy separation lets us build verdict_loop(sequence(...)) etc.) so we
-- pin it with a contract test that exercises real nesting depth, not just
-- the leaf-handler happy path of the per-primitive specs.

local lust = require("lust")
local frame = require("swarm_frame")
local describe, it, expect = lust.describe, lust.it, lust.expect

describe("swarm_frame combinator composability", function()
    it("verdict_loop wrapping a sequence: parser sees the final response", function()
        local prep_calls, check_calls, fix_calls = 0, 0, 0
        local attempts = 0
        local gate = frame.sequence({
            function()
                prep_calls = prep_calls + 1
                return "DONE path=prep"
            end,
            function()
                check_calls = check_calls + 1
                attempts = attempts + 1
                if attempts >= 2 then return "PASS attempt=" .. tostring(attempts) end
                return "FAIL attempt=" .. tostring(attempts)
            end,
        })
        local h = frame.verdict_loop({
            gate = gate,
            fix = function()
                fix_calls = fix_calls + 1
                return ""
            end,
            parser = function(r) return r:find("PASS") ~= nil end,
            max_retries = 3,
        })
        local ctx = { state = frame.state_new() }
        local resp = h(ctx)
        expect(prep_calls).to.equal(2) -- sequence re-runs from start each attempt
        expect(check_calls).to.equal(2)
        expect(fix_calls).to.equal(1) -- one fix between two gate attempts
        expect(resp:find("PASS")).to.exist()
    end)

    it("sequence containing a verdict_loop: short-circuits remaining steps when loop blocks", function()
        local pre_calls, post_calls, gate_calls = 0, 0, 0
        local inner = frame.verdict_loop({
            gate = function()
                gate_calls = gate_calls + 1
                return "FAIL"
            end,
            parser = function() return false end,
            max_retries = 1, -- 1 initial + 1 retry = 2 calls
        })
        local h = frame.sequence({
            function()
                pre_calls = pre_calls + 1
                return "DONE path=pre"
            end,
            inner,
            function()
                post_calls = post_calls + 1
                return "DONE path=post"
            end,
        })
        local ctx = { state = frame.state_new() }
        local resp = h(ctx)
        expect(pre_calls).to.equal(1)
        expect(gate_calls).to.equal(2) -- exhausted retries
        expect(post_calls).to.equal(0) -- sequence short-circuited on non-DONE
        expect(resp).to.equal("FAIL")
    end)

    it("branch with loop inside then_ and sequence inside else_", function()
        local loop_iters, seq_calls = 0, 0
        local then_loop = frame.loop({
            body = function()
                loop_iters = loop_iters + 1
                return "DONE iter=" .. tostring(loop_iters)
            end,
            until_ = function(_ctx, response) return response:find("iter=3") ~= nil end,
            max = 10,
        })
        local else_seq = frame.sequence({
            function()
                seq_calls = seq_calls + 1
                return "DONE path=alt_a"
            end,
            function()
                seq_calls = seq_calls + 1
                return "DONE path=alt_b"
            end,
        })

        -- Truthy branch: loop should run, sequence untouched.
        local h_true = frame.branch({
            cond = function() return true end,
            then_ = then_loop,
            else_ = else_seq,
        })
        local resp_true = h_true({ state = frame.state_new() })
        expect(loop_iters).to.equal(3)
        expect(seq_calls).to.equal(0)
        expect(resp_true).to.equal("DONE iter=3")

        -- Falsy branch: sequence should run, no further loop iterations.
        local loop_before = loop_iters
        local h_false = frame.branch({
            cond = function() return false end,
            then_ = then_loop,
            else_ = else_seq,
        })
        local resp_false = h_false({ state = frame.state_new() })
        expect(loop_iters).to.equal(loop_before) -- no change
        expect(seq_calls).to.equal(2)
        expect(resp_false).to.equal("DONE path=alt_b")
    end)

    it("accepts a callable table as a handler (Handler = fn OR callable table)", function()
        local calls = 0
        local callable = setmetatable({ tag = "callable_marker" }, {
            __call = function(self, _ctx, _spec)
                calls = calls + 1
                return "DONE marker=" .. self.tag
            end,
        })
        local h = frame.sequence({
            function() return "DONE path=plain" end,
            callable,
        })
        local resp = h({ state = frame.state_new() })
        expect(calls).to.equal(1)
        expect(resp).to.equal("DONE marker=callable_marker")
    end)
end)
