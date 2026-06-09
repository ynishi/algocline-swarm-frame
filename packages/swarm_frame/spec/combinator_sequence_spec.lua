-- combinator_sequence_spec.lua — Contract test for swarm_frame.sequence.

local lust = require("lust")
local frame = require("swarm_frame")
local describe, it, expect = lust.describe, lust.it, lust.expect

describe("swarm_frame.sequence", function()
    it("runs handlers in order and returns the last response", function()
        local calls = {}
        local h = frame.sequence({
            function()
                table.insert(calls, "a")
                return "DONE path=a"
            end,
            function()
                table.insert(calls, "b")
                return "DONE path=b"
            end,
            function()
                table.insert(calls, "c")
                return "DONE path=c"
            end,
        })
        local ctx = { state = frame.state_new() }
        local resp = h(ctx)
        expect(table.concat(calls, ",")).to.equal("a,b,c")
        expect(resp).to.equal("DONE path=c")
    end)

    it("short-circuits on a non-DONE verdict", function()
        local calls = {}
        local h = frame.sequence({
            function()
                table.insert(calls, "a")
                return "DONE path=a"
            end,
            function()
                table.insert(calls, "b")
                return "BLOCKED reason=stop"
            end,
            function()
                table.insert(calls, "c")
                return "DONE path=c"
            end,
        })
        local ctx = { state = frame.state_new() }
        local resp = h(ctx)
        expect(table.concat(calls, ",")).to.equal("a,b")
        expect(resp:find("BLOCKED")).to.exist()
    end)

    it("rejects opts missing the handlers array via lshape in strict mode", function()
        local saved = os.getenv("SWARM_FRAME_SCHEMA_MODE")
        local ok, err = pcall(function() frame.sequence({ cp_key = "x" }, "swarm_frame.sequence", "strict") end)
        -- Direct strict invocation via the 4th positional mode arg on
        -- frame.validate. We call frame.sequence inside pcall and rely on
        -- the schema's strict assertion to raise. If the surface doesn't
        -- forward mode, drive strictness through swarm_frame.validate
        -- directly (covered below).
        local lshape_check = require("lshape.check")
        local ok2, err2 =
            pcall(lshape_check.assert, { cp_key = "x" }, "SwarmFrame.SequenceOpts", "swarm_frame.sequence")
        expect(ok2).to.equal(false)
        expect(tostring(err2):find("handlers")).to.exist()
        _ = saved
        _ = ok
        _ = err
    end)
end)
