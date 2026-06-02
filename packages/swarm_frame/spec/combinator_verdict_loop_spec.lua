-- combinator_verdict_loop_spec.lua — Contract test for swarm_frame.verdict_loop.

local lust = require("lust")
local frame = require("swarm_frame")
local describe, it, expect = lust.describe, lust.it, lust.expect

describe("swarm_frame.verdict_loop", function()
    it("returns the gate response when parser passes on first try", function()
        local gate_calls, fix_calls = 0, 0
        local h = frame.verdict_loop({
            gate = function() gate_calls = gate_calls + 1 return "PASS" end,
            fix = function() fix_calls = fix_calls + 1 return "" end,
            parser = function(r) return r == "PASS" end,
            max_retries = 3,
        })
        local ctx = { state = frame.state_new() }
        local resp = h(ctx)
        expect(gate_calls).to.equal(1)
        expect(fix_calls).to.equal(0)
        expect(resp).to.equal("PASS")
    end)

    it("invokes fix between gate failures and retries up to max_retries", function()
        local gate_calls, fix_calls = 0, 0
        local responses = { "FAIL", "FAIL", "PASS" }
        local h = frame.verdict_loop({
            gate = function()
                gate_calls = gate_calls + 1
                return responses[gate_calls]
            end,
            fix = function() fix_calls = fix_calls + 1 return "" end,
            parser = function(r) return r == "PASS" end,
            max_retries = 3,
        })
        local ctx = { state = frame.state_new() }
        local resp = h(ctx)
        expect(gate_calls).to.equal(3) -- two FAIL + one PASS
        expect(fix_calls).to.equal(2) -- ran after each FAIL
        expect(resp).to.equal("PASS")
    end)

    it("returns the last response and exhausts when parser never passes", function()
        local gate_calls = 0
        local h = frame.verdict_loop({
            gate = function()
                gate_calls = gate_calls + 1
                return "FAIL attempt=" .. tostring(gate_calls)
            end,
            parser = function() return false end,
            max_retries = 2,
        })
        local ctx = { state = frame.state_new() }
        local resp = h(ctx)
        expect(gate_calls).to.equal(3) -- 1 initial + 2 retries
        expect(resp:find("attempt=3")).to.exist()
    end)
end)
