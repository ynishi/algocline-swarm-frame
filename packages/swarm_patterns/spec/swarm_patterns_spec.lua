local describe, it, expect = lust.describe, lust.it, lust.expect

local patterns = require("swarm_patterns")

describe("swarm_patterns.panel", function()
    it("builds default 3-role panel + moderator", function()
        local blueprint = patterns.panel({})

        expect(#blueprint.agents).to.equal(4)
        local names = {}
        for _, a in ipairs(blueprint.agents) do
            names[#names + 1] = a.name
        end
        expect(names[1]).to.equal("panelist_advocate")
        expect(names[2]).to.equal("panelist_critic")
        expect(names[3]).to.equal("panelist_pragmatist")
        expect(names[4]).to.equal("moderator")

        expect(blueprint.flow.kind).to.equal("seq")
        expect(#blueprint.flow.children).to.equal(4)

        local c1, c2, c3, c4 = blueprint.flow.children[1], blueprint.flow.children[2],
            blueprint.flow.children[3], blueprint.flow.children[4]

        expect(c1.kind).to.equal("step")
        expect(c1.ref).to.equal("panelist_advocate")
        expect(c1["in"].op).to.equal("path")
        expect(c1["in"].at).to.equal("$")
        expect(c1.out.at).to.equal("$.arguments.advocate")

        expect(c2.ref).to.equal("panelist_critic")
        expect(c2.out.at).to.equal("$.arguments.critic")

        expect(c3.ref).to.equal("panelist_pragmatist")
        expect(c3.out.at).to.equal("$.arguments.pragmatist")

        expect(c4.kind).to.equal("step")
        expect(c4.ref).to.equal("moderator")
        expect(c4["in"].at).to.equal("$")
        expect(c4.out.at).to.equal("$.synthesis")
    end)

    it("builds a well-formed envelope with default id and inline origin", function()
        local blueprint = patterns.panel({})

        expect(blueprint.schema_version).to.equal("0.1.0")
        expect(blueprint.id).to.equal("panel-deliberation-v1")
        expect(blueprint.metadata.origin.kind).to.equal("inline")
        local has_tag = false
        for _, t in ipairs(blueprint.metadata.tags) do
            if t == "pattern:panel" then has_tag = true end
        end
        expect(has_tag).to.equal(true)
    end)

    it("uses origin=algo with session_id when provided", function()
        local blueprint = patterns.panel({ session_id = "sess-1" })

        expect(blueprint.metadata.origin.kind).to.equal("algo")
        expect(blueprint.metadata.origin.session_id).to.equal("sess-1")
    end)

    it("respects custom roles, id, model, and spec opts", function()
        local shared_spec = { budget = 10 }
        local blueprint = patterns.panel({
            roles = { "optimist", "skeptic" },
            id = "custom-panel-v1",
            model = "haiku",
            spec = shared_spec,
        })

        expect(blueprint.id).to.equal("custom-panel-v1")
        expect(#blueprint.agents).to.equal(3)
        expect(#blueprint.flow.children).to.equal(3)

        local names = {}
        for _, a in ipairs(blueprint.agents) do
            names[#names + 1] = a.name
        end
        expect(names[1]).to.equal("panelist_optimist")
        expect(names[2]).to.equal("panelist_skeptic")
        expect(names[3]).to.equal("moderator")

        for _, a in ipairs(blueprint.agents) do
            expect(a.profile.model).to.equal("haiku")
            expect(a.spec.budget).to.equal(10)
        end

        expect(blueprint.flow.children[1].out.at).to.equal("$.arguments.optimist")
        expect(blueprint.flow.children[2].out.at).to.equal("$.arguments.skeptic")
    end)

    it("rejects an empty roles array", function()
        local ok, err = pcall(patterns.panel, { roles = {} })
        expect(ok).to.equal(false)
        expect(tostring(err):find("roles") ~= nil).to.equal(true)
    end)

    it("rejects a non-string role", function()
        local ok = pcall(patterns.panel, { roles = { "advocate", 42 } })
        expect(ok).to.equal(false)
    end)

    it("rejects a duplicate role", function()
        local ok, err = pcall(patterns.panel, { roles = { "advocate", "advocate" } })
        expect(ok).to.equal(false)
        expect(tostring(err):find("duplicate") ~= nil).to.equal(true)
    end)

    it("rejects a non-identifier role name", function()
        local ok = pcall(patterns.panel, { roles = { "bad-role" } })
        expect(ok).to.equal(false)
    end)

    it("rejects the reserved 'moderator' role name", function()
        local ok, err = pcall(patterns.panel, { roles = { "advocate", "moderator" } })
        expect(ok).to.equal(false)
        expect(tostring(err):find("reserved") ~= nil).to.equal(true)
    end)

    it("uses literal 'in' key on generated steps (builder round-trip check)", function()
        local blueprint = patterns.panel({})
        for _, child in ipairs(blueprint.flow.children) do
            expect(child["in"] ~= nil).to.equal(true)
        end
    end)
end)
