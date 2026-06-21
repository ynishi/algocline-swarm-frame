-- v3_smoke_spec.lua — Vertical slice for V3 architecture (P1).
--
-- Validates the minimal Pattern A path:
--   Layer S4 (DSL builder)
--     -> Layer S3 (flow.ir Def fragment)
--       -> flow.ir.compile (S2)
--         -> flow.ir.exec (S1: ctx mutation)
--
-- P1 coverage: step + chain primitives, path / lit Expr DSL, swarm.run()
-- Driver. Subsequent phases extend Builder primitives, /engine sub-modules,
-- and /contract sub-modules.

local lust    = require("lust")
local swarm   = require("swarm_frame.v3")
local describe, it, expect = lust.describe, lust.it, lust.expect

describe("swarm_frame.v3 (P1 vertical slice)", function()
    it("step + chain: dispatches refs in order, mutates ctx", function()
        local calls = {}
        local shape = swarm.chain({
            swarm.step("@a", { out = "ctx.a" }),
            swarm.step("@b", { out = "ctx.b" }),
        })
        local result = swarm.run({
            shape    = shape,
            dispatch = function(ref, input)
                table.insert(calls, ref)
                return { who = ref, input = input }
            end,
        })
        expect(result.status).to.equal("ok")
        expect(table.concat(calls, ",")).to.equal("@a,@b")
        expect(result.ctx.a.who).to.equal("@a")
        expect(result.ctx.b.who).to.equal("@b")
    end)

    it("step.in_ via path: threads producer.out into consumer.in_", function()
        local shape = swarm.chain({
            swarm.step("@producer", { out = "ctx.payload" }),
            swarm.step("@consumer",
                       { in_ = swarm.path("$.ctx.payload"), out = "ctx.result" }),
        })
        local result = swarm.run({
            shape    = shape,
            dispatch = function(ref, input)
                if ref == "@producer" then return { value = 42 } end
                if ref == "@consumer" then return { echoed = input } end
                error("unknown ref: " .. tostring(ref))
            end,
        })
        expect(result.status).to.equal("ok")
        expect(result.ctx.payload.value).to.equal(42)
        expect(result.ctx.result.echoed.value).to.equal(42)
    end)

    it("step.in_ omitted: dispatch receives nil input (R8 land, V3 §5.3.1)", function()
        local seen_input = "<unset>"
        local shape = swarm.chain({
            swarm.step("@a", { out = "ctx.a" }),
        })
        local result = swarm.run({
            shape    = shape,
            dispatch = function(ref, input)
                seen_input = input
                return { ok = true }
            end,
        })
        expect(result.status).to.equal("ok")
        expect(seen_input).to.equal(nil)
    end)

    it("compile_fail: bad shape returns structured error", function()
        local result = swarm.run({
            shape    = { kind = "step" }, -- missing ref
            dispatch = function() return nil end,
        })
        expect(result.status).to.equal("error")
        expect(result.error.kind).to.equal("compile_fail")
    end)

    it("exec_fail: dispatch raises -> structured error", function()
        local shape = swarm.chain({
            swarm.step("@boom", { out = "ctx.x" }),
        })
        local result = swarm.run({
            shape    = shape,
            dispatch = function() error("dispatcher exploded") end,
        })
        expect(result.status).to.equal("error")
        expect(result.error.kind).to.equal("exec_fail")
        expect(tostring(result.error.message):find("dispatcher exploded")).to_not.equal(nil)
    end)

    it("driver guards: shape / dispatch required", function()
        local ok1 = pcall(function() swarm.run({ dispatch = function() end }) end)
        expect(ok1).to.equal(false)
        local ok2 = pcall(function() swarm.run({ shape = {} }) end)
        expect(ok2).to.equal(false)
    end)

    it("Expr lit: builds {op='lit', value=v}", function()
        local e = swarm.lit(7)
        expect(e.op).to.equal("lit")
        expect(e.value).to.equal(7)
    end)

    it("Expr path: builds {op='path', at=...}", function()
        local e = swarm.path("$.ctx.foo")
        expect(e.op).to.equal("path")
        expect(e.at).to.equal("$.ctx.foo")
    end)

    it("VERSION is exposed (P1 marker)", function()
        expect(type(swarm.VERSION)).to.equal("string")
    end)
end)
