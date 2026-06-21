-- v3_composite_spec.lua — Composite library (P6 coverage).
--
-- Validates verdict_loop / aggregate compile to 7 primitive equivalents
-- AND run end-to-end through flow.ir for representative cases.
-- builder-spec-v1 §10.4 evidence: this is where the 2/2 plugin
-- replacement is implemented (verdict_loop_plugin 137 行 +
-- swarm_aggregate_plugin 229 行 → composites).

local lust  = require("lust")
local swarm = require("swarm_frame.v3")
local C     = swarm.composite
local describe, it, expect = lust.describe, lust.it, lust.expect

-- ── verdict_loop ────────────────────────────────────────────────────

describe("swarm.composite.verdict_loop (shape)", function()
    it("compiles to loop({step, until_=eq(path, lit), max, counter})", function()
        local n = C.verdict_loop({
            step        = "@planner",
            until_token = "DONE",
            max         = 3,
        })
        expect(n.kind).to.equal("loop")
        expect(n.body.kind).to.equal("step")
        expect(n.body.ref).to.equal("@planner")
        expect(n.body.out).to.equal("ctx.last")
        expect(n.max).to.equal(3)
        expect(n.counter).to.equal("ctx.iter")
        -- cond is synthesized as not_(eq(path, lit))
        expect(n.cond.op).to.equal("not")
        expect(n.cond.arg.op).to.equal("eq")
        expect(n.cond.arg.lhs.op).to.equal("path")
        expect(n.cond.arg.lhs.at).to.equal("$.ctx.last.verdict")
        expect(n.cond.arg.rhs.op).to.equal("lit")
        expect(n.cond.arg.rhs.value).to.equal("DONE")
    end)

    it("respects custom out / verdict_field / counter", function()
        local n = C.verdict_loop({
            step          = "@gate",
            until_token   = "ACCEPT",
            max           = 5,
            out           = "ctx.gate",
            verdict_field = "decision",
            counter       = "ctx.attempts",
        })
        expect(n.body.out).to.equal("ctx.gate")
        expect(n.counter).to.equal("ctx.attempts")
        expect(n.cond.arg.lhs.at).to.equal("$.ctx.gate.decision")
        expect(n.cond.arg.rhs.value).to.equal("ACCEPT")
    end)

    it("raises on missing required opts", function()
        expect(pcall(function() C.verdict_loop({}) end)).to.equal(false)
        expect(pcall(function()
            C.verdict_loop({ step = "@x", until_token = "X" })
        end)).to.equal(false)
        expect(pcall(function()
            C.verdict_loop({ step = "@x", max = 3 })
        end)).to.equal(false)
    end)
end)

describe("swarm.composite.verdict_loop (e2e exec)", function()
    it("retries until verdict_token matches", function()
        local attempts = 0
        local shape = C.verdict_loop({
            step        = "@gate",
            until_token = "DONE",
            max         = 5,
        })
        local result = swarm.run({
            shape    = shape,
            dispatch = function()
                attempts = attempts + 1
                if attempts < 3 then return { verdict = "RETRY" } end
                return { verdict = "DONE" }
            end,
        })
        expect(result.status).to.equal("ok")
        expect(attempts).to.equal(3)
        expect(result.ctx.last.verdict).to.equal("DONE")
    end)

    it("custom verdict_field is honored", function()
        local shape = C.verdict_loop({
            step          = "@gate",
            until_token   = "ACCEPT",
            max           = 3,
            out           = "ctx.gate",
            verdict_field = "decision",
        })
        local result = swarm.run({
            shape    = shape,
            dispatch = function() return { decision = "ACCEPT" } end,
        })
        expect(result.status).to.equal("ok")
        expect(result.ctx.gate.decision).to.equal("ACCEPT")
    end)
end)

-- ── aggregate ───────────────────────────────────────────────────────

describe("swarm.composite.aggregate (shape)", function()
    it("compiles to chain({fan(step, items), let(out, ext(reducer, [path(fan_out)]))})", function()
        local n = C.aggregate({
            step    = "@panelist",
            items   = swarm.lit({ 1, 2, 3 }),
            reducer = "kemeny",
            out     = "ctx.consensus",
        })
        expect(n.kind).to.equal("seq")
        expect(#n.children).to.equal(2)
        -- fan node
        local fan = n.children[1]
        expect(fan.kind).to.equal("fanout")
        expect(fan.body.kind).to.equal("step")
        expect(fan.body.ref).to.equal("@panelist")
        expect(fan.bind).to.equal("ctx.item")
        expect(fan.out).to.equal("ctx.fan_result")
        expect(fan.join).to.equal("all")
        -- let node
        local let_node = n.children[2]
        expect(let_node.kind).to.equal("let")
        expect(let_node.at).to.equal("ctx.consensus")
        expect(let_node.value.op).to.equal("call_extern")
        expect(let_node.value.ref).to.equal("kemeny")
    end)

    it("respects custom bind / body_out / fan_out / join", function()
        local n = C.aggregate({
            step     = "@worker",
            items    = swarm.path("$.ctx.candidates"),
            reducer  = "majority",
            out      = "ctx.winner",
            bind     = "ctx.cur",
            body_out = "ctx.work",
            fan_out  = "ctx.gathered",
            join     = "all_settled",
        })
        local fan = n.children[1]
        expect(fan.bind).to.equal("ctx.cur")
        expect(fan.body.in_.at).to.equal("$.ctx.cur")
        expect(fan.body.out).to.equal("ctx.work")
        expect(fan.out).to.equal("ctx.gathered")
        expect(fan.join).to.equal("all_settled")
    end)

    it("raises on missing required opts", function()
        expect(pcall(function() C.aggregate({}) end)).to.equal(false)
        expect(pcall(function()
            C.aggregate({ step = "@x" })
        end)).to.equal(false)
        expect(pcall(function()
            C.aggregate({ step = "@x", items = swarm.lit({}), reducer = "r" })
        end)).to.equal(false)
    end)
end)

describe("swarm.composite.aggregate (e2e exec)", function()
    it("fans 3 items, reduces via extern", function()
        local shape = C.aggregate({
            step    = "@panelist",
            items   = swarm.path("$.ctx.candidates"),
            reducer = "first",
            out     = "ctx.consensus",
        })
        local result = swarm.run({
            shape    = shape,
            dispatch = function(_, input) return { said = input } end,
            externs  = {
                first = function(results)
                    -- results is the fan join: a list of per-branch ctx tables.
                    -- The body wrote step.out to ctx.r per branch, so each
                    -- entry has {r = {said = ...}, item = ...}.
                    return results[1] and results[1].r
                end,
            },
            ctx      = { candidates = { "alpha", "beta", "gamma" } },
        })
        expect(result.status).to.equal("ok")
        expect(result.ctx.consensus.said).to.equal("alpha")
        expect(#result.ctx.fan_result).to.equal(3)
    end)
end)
