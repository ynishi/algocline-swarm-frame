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

describe("swarm_patterns.reflect", function()
    it("builds default 3-agent generate/critique/revise loop", function()
        local blueprint = patterns.reflect({})

        expect(#blueprint.agents).to.equal(3)
        local names = {}
        for _, a in ipairs(blueprint.agents) do
            names[#names + 1] = a.name
        end
        expect(names[1]).to.equal("generator")
        expect(names[2]).to.equal("critic")
        expect(names[3]).to.equal("reviser")

        expect(blueprint.flow.kind).to.equal("seq")
        expect(#blueprint.flow.children).to.equal(2)

        local init_node, loop_node = blueprint.flow.children[1], blueprint.flow.children[2]

        expect(init_node.kind).to.equal("branch")
        expect(init_node.cond.op).to.equal("exists")
        expect(init_node.cond.at).to.equal("$.initial_draft")

        expect(loop_node.kind).to.equal("loop")
        expect(loop_node.max).to.equal(3)
        expect(loop_node.counter.at).to.equal("$.round")
    end)

    it("wires the loop body literal shape: critic step, then branch(reviser/converged)", function()
        local blueprint = patterns.reflect({})
        local loop_node = blueprint.flow.children[2]

        expect(loop_node.body.kind).to.equal("seq")
        local critic_step, branch = loop_node.body.children[1], loop_node.body.children[2]

        expect(critic_step.kind).to.equal("step")
        expect(critic_step.ref).to.equal("critic")
        expect(critic_step.out.at).to.equal("$.critique")

        expect(branch.kind).to.equal("branch")
        expect(branch["then"].kind).to.equal("step")
        expect(branch["then"].ref).to.equal("reviser")
        expect(branch["then"].out.at).to.equal("$.draft")

        expect(branch["else"].kind).to.equal("assign")
        expect(branch["else"].at.at).to.equal("$.converged")
    end)

    it("wires the loop cond as or(not(exists critique), eq(critique.converged, false))", function()
        local blueprint = patterns.reflect({})
        local loop_node = blueprint.flow.children[2]

        expect(loop_node.cond.op).to.equal("or")
        local first, second = loop_node.cond.operands[1], loop_node.cond.operands[2]

        expect(first.op).to.equal("not")
        expect(second.op).to.equal("eq")
        expect(second.lhs.at).to.equal("$.critique.converged")
    end)

    it("builds a well-formed envelope with default id, tags, and inline origin", function()
        local blueprint = patterns.reflect({})

        expect(blueprint.schema_version).to.equal("0.1.0")
        expect(blueprint.id).to.equal("reflect-refine-v1")
        expect(blueprint.metadata.origin.kind).to.equal("inline")
        local has_tag = false
        for _, t in ipairs(blueprint.metadata.tags) do
            if t == "pattern:reflect" then has_tag = true end
        end
        expect(has_tag).to.equal(true)
    end)

    it("uses origin=algo with session_id when provided", function()
        local blueprint = patterns.reflect({ session_id = "sess-1" })

        expect(blueprint.metadata.origin.kind).to.equal("algo")
        expect(blueprint.metadata.origin.session_id).to.equal("sess-1")
    end)

    it("respects custom max_rounds, id, and model opts", function()
        local blueprint = patterns.reflect({
            max_rounds = 5,
            id = "custom-reflect-v1",
            model = "haiku",
        })

        expect(blueprint.id).to.equal("custom-reflect-v1")
        expect(blueprint.flow.children[2].max).to.equal(5)
        for _, a in ipairs(blueprint.agents) do
            expect(a.profile.model).to.equal("haiku")
        end
    end)

    it("rejects a zero max_rounds", function()
        local ok, err = pcall(patterns.reflect, { max_rounds = 0 })
        expect(ok).to.equal(false)
        expect(tostring(err):find("max_rounds") ~= nil).to.equal(true)
    end)

    it("rejects a negative max_rounds", function()
        local ok = pcall(patterns.reflect, { max_rounds = -1 })
        expect(ok).to.equal(false)
    end)

    it("rejects a non-integer max_rounds", function()
        local ok = pcall(patterns.reflect, { max_rounds = "3" })
        expect(ok).to.equal(false)
    end)
end)

describe("swarm_patterns.sc", function()
    it("builds default 5-reasoner + judge fanout/vote", function()
        local blueprint = patterns.sc({})

        expect(#blueprint.agents).to.equal(6)
        local names = {}
        for _, a in ipairs(blueprint.agents) do
            names[#names + 1] = a.name
        end
        expect(names[1]).to.equal("reasoner_1")
        expect(names[2]).to.equal("reasoner_2")
        expect(names[3]).to.equal("reasoner_3")
        expect(names[4]).to.equal("reasoner_4")
        expect(names[5]).to.equal("reasoner_5")
        expect(names[6]).to.equal("judge")

        expect(blueprint.flow.kind).to.equal("seq")
        expect(#blueprint.flow.children).to.equal(2)

        local fanout_node, judge_step = blueprint.flow.children[1], blueprint.flow.children[2]

        expect(fanout_node.kind).to.equal("fanout")
        expect(fanout_node.join).to.equal("all")
        expect(fanout_node.items.op).to.equal("lit")
        expect(fanout_node.bind.at).to.equal("$.i")
        expect(fanout_node.out.at).to.equal("$.paths")

        expect(judge_step.kind).to.equal("step")
        expect(judge_step.ref).to.equal("judge")
        expect(judge_step.out.at).to.equal("$.result")
    end)

    it("embeds cycling diversity hints into each reasoner's system_prompt", function()
        local blueprint = patterns.sc({})

        local by_name = {}
        for _, a in ipairs(blueprint.agents) do
            by_name[a.name] = a
        end

        expect(by_name.reasoner_1.profile.system_prompt:find("Think step by step carefully.", 1, true) ~= nil)
            .to.equal(true)
        expect(
            by_name.reasoner_2.profile.system_prompt:find("Approach this from first principles.", 1, true)
                ~= nil
        ).to.equal(true)

        local blueprint8 = patterns.sc({ n = 8 })
        local by_name8 = {}
        for _, a in ipairs(blueprint8.agents) do
            by_name8[a.name] = a
        end
        -- i=8: hints[((8-1) % 7) + 1] == hints[1] (cycles back to the first hint)
        expect(
            by_name8.reasoner_8.profile.system_prompt:find("Think step by step carefully.", 1, true) ~= nil
        ).to.equal(true)
    end)

    it("builds the fanout items literal as {1, 2, 3, 4, 5} for the n=5 default", function()
        local blueprint = patterns.sc({})
        local fanout_node = blueprint.flow.children[1]

        expect(#fanout_node.items.value).to.equal(5)
        for i = 1, 5 do
            expect(fanout_node.items.value[i]).to.equal(i)
        end
    end)

    it("wires the fanout body as a branch(eq($.i, k), reasoner_k, ...) chain for n=3", function()
        local blueprint = patterns.sc({ n = 3 })
        local body = blueprint.flow.children[1].body

        expect(body.kind).to.equal("branch")
        expect(body.cond.op).to.equal("eq")
        expect(body.cond.lhs.at).to.equal("$.i")
        expect(body.cond.rhs.value).to.equal(1)
        expect(body["then"].kind).to.equal("step")
        expect(body["then"].ref).to.equal("reasoner_1")
        expect(body["then"].out.at).to.equal("$.path")

        local inner = body["else"]
        expect(inner.kind).to.equal("branch")
        expect(inner.cond.rhs.value).to.equal(2)
        expect(inner["then"].ref).to.equal("reasoner_2")

        expect(inner["else"].kind).to.equal("step")
        expect(inner["else"].ref).to.equal("reasoner_3")
    end)

    it("degenerates the fanout body to a single unconditional step when n=1", function()
        local blueprint = patterns.sc({ n = 1 })
        local body = blueprint.flow.children[1].body

        expect(body.kind).to.equal("step")
        expect(body.ref).to.equal("reasoner_1")
        expect(body.out.at).to.equal("$.path")
    end)

    it("builds a well-formed envelope with default id and 'pattern:sc' tag", function()
        local blueprint = patterns.sc({})

        expect(blueprint.schema_version).to.equal("0.1.0")
        expect(blueprint.id).to.equal("sc-vote-v1")
        expect(blueprint.metadata.origin.kind).to.equal("inline")
        local has_tag = false
        for _, t in ipairs(blueprint.metadata.tags) do
            if t == "pattern:sc" then has_tag = true end
        end
        expect(has_tag).to.equal(true)
    end)

    it("respects custom n and model opts", function()
        local blueprint = patterns.sc({ n = 8, model = "haiku" })

        expect(#blueprint.agents).to.equal(9)
        for _, a in ipairs(blueprint.agents) do
            expect(a.profile.model).to.equal("haiku")
        end
    end)

    it("rejects n=0, n=-1, n=21, n=1.5, and n='3'", function()
        local ok1 = pcall(patterns.sc, { n = 0 })
        expect(ok1).to.equal(false)

        local ok2 = pcall(patterns.sc, { n = -1 })
        expect(ok2).to.equal(false)

        local ok3 = pcall(patterns.sc, { n = 21 })
        expect(ok3).to.equal(false)

        local ok4 = pcall(patterns.sc, { n = 1.5 })
        expect(ok4).to.equal(false)

        local ok5 = pcall(patterns.sc, { n = "3" })
        expect(ok5).to.equal(false)
    end)
end)

describe("swarm_patterns.ucb", function()
    it("builds default n=3/rounds=2: 7 agents, seq shape (3+1+6+1+1=12 children)", function()
        local blueprint = patterns.ucb({})

        expect(#blueprint.agents).to.equal(7)
        local names = {}
        for _, a in ipairs(blueprint.agents) do
            names[#names + 1] = a.name
        end
        expect(names[1]).to.equal("generator_1")
        expect(names[2]).to.equal("generator_2")
        expect(names[3]).to.equal("generator_3")
        expect(names[4]).to.equal("scorer")
        expect(names[5]).to.equal("refiner_1")
        expect(names[6]).to.equal("refiner_2")
        expect(names[7]).to.equal("refiner_3")

        expect(blueprint.flow.kind).to.equal("seq")
        -- generator(3) + pulls-init(1) + stats-init(2*3) + loop(1) + finalize(1) = 12
        expect(#blueprint.flow.children).to.equal(12)
    end)

    it("wires the init section: pulls=0 then per-arm stats.<i>.total=0/n=0 in order", function()
        local blueprint = patterns.ucb({})
        local children = blueprint.flow.children

        -- children[1..3] = generator steps, children[4] = pulls init
        local pulls_init = children[4]
        expect(pulls_init.kind).to.equal("assign")
        expect(pulls_init.at.at).to.equal("$.pulls")
        expect(pulls_init.value.value).to.equal(0)

        local total_1, n_1 = children[5], children[6]
        expect(total_1.at.at).to.equal("$.stats.1.total")
        expect(total_1.value.value).to.equal(0)
        expect(n_1.at.at).to.equal("$.stats.1.n")
        expect(n_1.value.value).to.equal(0)

        local total_2, n_2 = children[7], children[8]
        expect(total_2.at.at).to.equal("$.stats.2.total")
        expect(n_2.at.at).to.equal("$.stats.2.n")

        local total_3, n_3 = children[9], children[10]
        expect(total_3.at.at).to.equal("$.stats.3.total")
        expect(n_3.at.at).to.equal("$.stats.3.n")
    end)

    it("wires the loop node shape (kind/counter/cond/max)", function()
        local blueprint = patterns.ucb({})
        local loop_node = blueprint.flow.children[11]

        expect(loop_node.kind).to.equal("loop")
        expect(loop_node.counter.at).to.equal("$.round")
        expect(loop_node.cond.op).to.equal("lt")
        expect(loop_node.cond.lhs.at).to.equal("$.round")
        expect(loop_node.cond.rhs.value).to.equal(2)
        expect(loop_node.max).to.equal(2)
        expect(loop_node.body.kind).to.equal("seq")
    end)

    it("wires the loop body score section: $.i assign, scorer step, then 3 stat assigns per arm", function()
        local blueprint = patterns.ucb({})
        local body = blueprint.flow.children[11].body.children

        -- arm 1: body[1..5]
        expect(body[1].kind).to.equal("assign")
        expect(body[1].at.at).to.equal("$.i")
        expect(body[1].value.value).to.equal(1)

        expect(body[2].kind).to.equal("step")
        expect(body[2].ref).to.equal("scorer")
        expect(body[2].out.at).to.equal("$.stats.1.last")

        expect(body[3].kind).to.equal("assign")
        expect(body[3].at.at).to.equal("$.stats.1.total")
        expect(body[3].value.op).to.equal("add")
        expect(body[3].value.lhs.at).to.equal("$.stats.1.total")
        expect(body[3].value.rhs.at).to.equal("$.stats.1.last")

        expect(body[4].at.at).to.equal("$.stats.1.n")
        expect(body[4].value.op).to.equal("add")
        expect(body[4].value.rhs.value).to.equal(1)

        expect(body[5].at.at).to.equal("$.pulls")
        expect(body[5].value.op).to.equal("add")

        -- arm 2: body[6..10], arm 3: body[11..15]
        expect(body[6].at.at).to.equal("$.i")
        expect(body[6].value.value).to.equal(2)
        expect(body[7].out.at).to.equal("$.stats.2.last")

        expect(body[11].at.at).to.equal("$.i")
        expect(body[11].value.value).to.equal(3)
        expect(body[12].out.at).to.equal("$.stats.3.last")
    end)

    it("wires the loop body UCB1 assign section: call_extern('ucb1', total, n, pulls) per arm", function()
        local blueprint = patterns.ucb({})
        local body = blueprint.flow.children[11].body.children

        -- score section occupies body[1..15] (3 arms * 5 nodes), ucb assigns follow at 16/17/18
        local ucb_1, ucb_2, ucb_3 = body[16], body[17], body[18]

        expect(ucb_1.kind).to.equal("assign")
        expect(ucb_1.at.at).to.equal("$.stats.1.ucb")
        expect(ucb_1.value.op).to.equal("call_extern")
        expect(ucb_1.value["ref"]).to.equal("ucb1")
        expect(#ucb_1.value.args).to.equal(3)
        expect(ucb_1.value.args[1].at).to.equal("$.stats.1.total")
        expect(ucb_1.value.args[2].at).to.equal("$.stats.1.n")
        expect(ucb_1.value.args[3].at).to.equal("$.pulls")

        expect(ucb_2.at.at).to.equal("$.stats.2.ucb")
        expect(ucb_3.at.at).to.equal("$.stats.3.ucb")
    end)

    it("wires the argmax assign: call_extern('argmax_ucb', ucb_1, ..., ucb_N)", function()
        local blueprint = patterns.ucb({})
        local body = blueprint.flow.children[11].body.children
        local argmax = body[19]

        expect(argmax.kind).to.equal("assign")
        expect(argmax.at.at).to.equal("$.best_idx")
        expect(argmax.value.op).to.equal("call_extern")
        expect(argmax.value["ref"]).to.equal("argmax_ucb")
        expect(#argmax.value.args).to.equal(3)
        expect(argmax.value.args[1].at).to.equal("$.stats.1.ucb")
        expect(argmax.value.args[2].at).to.equal("$.stats.2.ucb")
        expect(argmax.value.args[3].at).to.equal("$.stats.3.ucb")
    end)

    it("wires the refine branch chain by $.best_idx, leaves dispatch to refiner_<k>", function()
        local blueprint = patterns.ucb({})
        local body = blueprint.flow.children[11].body.children
        local refine_chain = body[20]

        expect(refine_chain.kind).to.equal("branch")
        expect(refine_chain.cond.op).to.equal("eq")
        expect(refine_chain.cond.lhs.at).to.equal("$.best_idx")
        expect(refine_chain.cond.rhs.value).to.equal(1)
        expect(refine_chain["then"].kind).to.equal("step")
        expect(refine_chain["then"].ref).to.equal("refiner_1")
        expect(refine_chain["then"].out.at).to.equal("$.hypotheses.1")

        local inner = refine_chain["else"]
        expect(inner.kind).to.equal("branch")
        expect(inner.cond.rhs.value).to.equal(2)
        expect(inner["then"].ref).to.equal("refiner_2")

        expect(inner["else"].kind).to.equal("step")
        expect(inner["else"].ref).to.equal("refiner_3")
        expect(inner["else"].out.at).to.equal("$.hypotheses.3")
    end)

    it("degenerates the refine chain to a single unconditional step when n=1", function()
        local blueprint = patterns.ucb({ n = 1, rounds = 1 })
        -- flow.children layout: generator(n) + init(1+2n) + loop + finalize;
        -- loop is the second-to-last child (finalize is last).
        local loop_node = blueprint.flow.children[#blueprint.flow.children - 1]
        local body = loop_node.body.children
        local refine_node = body[#body]

        expect(refine_node.kind).to.equal("step")
        expect(refine_node.ref).to.equal("refiner_1")
        expect(refine_node.out.at).to.equal("$.hypotheses.1")
    end)

    it("wires the finalize assign: call_extern('finalize_ranking', total/n/hyp per arm)", function()
        local blueprint = patterns.ucb({})
        local finalize_node = blueprint.flow.children[12]

        expect(finalize_node.kind).to.equal("assign")
        expect(finalize_node.at.at).to.equal("$.result")
        expect(finalize_node.value.op).to.equal("call_extern")
        expect(finalize_node.value["ref"]).to.equal("finalize_ranking")
        expect(#finalize_node.value.args).to.equal(9)
        expect(finalize_node.value.args[1].at).to.equal("$.stats.1.total")
        expect(finalize_node.value.args[2].at).to.equal("$.stats.1.n")
        expect(finalize_node.value.args[3].at).to.equal("$.hypotheses.1")
        expect(finalize_node.value.args[7].at).to.equal("$.stats.3.total")
        expect(finalize_node.value.args[8].at).to.equal("$.stats.3.n")
        expect(finalize_node.value.args[9].at).to.equal("$.hypotheses.3")
    end)

    it("builds a well-formed envelope with default id and 'pattern:ucb' tag", function()
        local blueprint = patterns.ucb({})

        expect(blueprint.schema_version).to.equal("0.1.0")
        expect(blueprint.id).to.equal("ucb-explore-v1")
        expect(blueprint.metadata.origin.kind).to.equal("inline")
        local has_tag = false
        for _, t in ipairs(blueprint.metadata.tags) do
            if t == "pattern:ucb" then has_tag = true end
        end
        expect(has_tag).to.equal(true)
    end)

    it("uses origin=algo with session_id when provided", function()
        local blueprint = patterns.ucb({ session_id = "sess-1" })

        expect(blueprint.metadata.origin.kind).to.equal("algo")
        expect(blueprint.metadata.origin.session_id).to.equal("sess-1")
    end)

    it("shrinks correctly for n=2, rounds=1: 5 agents, loop.max==1", function()
        local blueprint = patterns.ucb({ n = 2, rounds = 1 })

        expect(#blueprint.agents).to.equal(5)
        -- generator(2) + pulls-init(1) + stats-init(2*2) + loop(1) + finalize(1) = 9
        expect(#blueprint.flow.children).to.equal(9)

        local loop_node = blueprint.flow.children[8]
        expect(loop_node.kind).to.equal("loop")
        expect(loop_node.max).to.equal(1)

        -- score section is 2 arms * 5 nodes = 10, then 2 ucb assigns, 1 argmax, 1 refine chain = 14
        expect(#loop_node.body.children).to.equal(14)

        local finalize_node = blueprint.flow.children[9]
        expect(#finalize_node.value.args).to.equal(6)
    end)

    it("embeds cycling diversity hints into each generator's system_prompt", function()
        local blueprint = patterns.ucb({})

        local by_name = {}
        for _, a in ipairs(blueprint.agents) do
            by_name[a.name] = a
        end

        expect(by_name.generator_1.profile.system_prompt:find("Think step by step carefully.", 1, true) ~= nil)
            .to.equal(true)

        local blueprint8 = patterns.ucb({ n = 8, rounds = 1 })
        local by_name8 = {}
        for _, a in ipairs(blueprint8.agents) do
            by_name8[a.name] = a
        end
        -- i=8: hints[((8-1) % 7) + 1] == hints[1] (cycles back to the first hint)
        expect(
            by_name8.generator_8.profile.system_prompt:find("Think step by step carefully.", 1, true) ~= nil
        ).to.equal(true)
    end)

    it("rejects n=0, n=9, n=1.5, rounds=0, and rounds=6", function()
        local ok1 = pcall(patterns.ucb, { n = 0 })
        expect(ok1).to.equal(false)

        local ok2 = pcall(patterns.ucb, { n = 9 })
        expect(ok2).to.equal(false)

        local ok3 = pcall(patterns.ucb, { n = 1.5 })
        expect(ok3).to.equal(false)

        local ok4 = pcall(patterns.ucb, { rounds = 0 })
        expect(ok4).to.equal(false)

        local ok5 = pcall(patterns.ucb, { rounds = 6 })
        expect(ok5).to.equal(false)
    end)
end)
