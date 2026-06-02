-- combinator_loop_spec.lua — Contract test for swarm_frame.loop.

local lust = require("lust")
local frame = require("swarm_frame")
local describe, it, expect = lust.describe, lust.it, lust.expect

describe("swarm_frame.loop", function()
    it("iterates until the until_ predicate returns truthy", function()
        local n = 0
        local h = frame.loop({
            body = function()
                n = n + 1
                return "DONE iter=" .. tostring(n)
            end,
            until_ = function(_ctx, response) return response:find("iter=3") ~= nil end,
            max = 10,
        })
        local ctx = { state = frame.state_new() }
        local resp = h(ctx)
        expect(n).to.equal(3)
        expect(resp).to.equal("DONE iter=3")
    end)

    it("caps iterations at max as a safety net", function()
        local n = 0
        local h = frame.loop({
            body = function()
                n = n + 1
                return "DONE iter=" .. tostring(n)
            end,
            until_ = function() return false end, -- never satisfied
            max = 5,
        })
        local ctx = { state = frame.state_new() }
        h(ctx)
        expect(n).to.equal(5)
    end)

    it("persists iter count via cp_key for resume", function()
        local ctx = { state = frame.state_new() }
        ctx.state:set("loop_attempt", 2) -- simulate prior progress
        ctx.state:commit()
        local n = 0
        local h = frame.loop({
            body = function()
                n = n + 1
                return "DONE"
            end,
            until_ = function() return true end,
            max = 10,
            cp_key = "loop_attempt",
        })
        h(ctx)
        expect(n).to.equal(1) -- resumed at iter 3, until_ truthy after first body call
    end)
end)
