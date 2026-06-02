-- combinator_branch_spec.lua — Contract test for swarm_frame.branch.

local lust = require("lust")
local frame = require("swarm_frame")
local describe, it, expect = lust.describe, lust.it, lust.expect

describe("swarm_frame.branch", function()
    it("dispatches to then_ when cond is truthy", function()
        local taken
        local h = frame.branch({
            cond = function() return true end,
            then_ = function() taken = "then" return "DONE path=then" end,
            else_ = function() taken = "else" return "DONE path=else" end,
        })
        local ctx = { state = frame.state_new() }
        local resp = h(ctx)
        expect(taken).to.equal("then")
        expect(resp).to.equal("DONE path=then")
    end)

    it("dispatches to else_ when cond is falsy", function()
        local taken
        local h = frame.branch({
            cond = function() return false end,
            then_ = function() taken = "then" return "DONE path=then" end,
            else_ = function() taken = "else" return "DONE path=else" end,
        })
        local ctx = { state = frame.state_new() }
        local resp = h(ctx)
        expect(taken).to.equal("else")
        expect(resp).to.equal("DONE path=else")
    end)

    it("synthesizes DONE when else_ is omitted and cond is falsy", function()
        local h = frame.branch({
            cond = function() return false end,
            then_ = function() return "DONE path=then" end,
        })
        local ctx = { state = frame.state_new() }
        local resp = h(ctx)
        expect(resp:find("DONE")).to.exist()
    end)
end)
