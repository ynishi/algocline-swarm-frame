-- v3_primitive_spec.lua — Builder primitive 7 + Expr DSL 9 (P2 coverage).
--
-- Validates each constructor's compile target shape + end-to-end exec
-- through flow.ir for non-trivial combinations.

local lust  = require("lust")
local swarm = require("swarm_frame.v3")
local describe, it, expect = lust.describe, lust.it, lust.expect

-- ── Pure constructor shape tests ────────────────────────────────────

describe("swarm.v3 Builder primitive shapes", function()
    it("step: {kind, ref, in_, out, out_schema}", function()
        local n = swarm.step("@a", { in_ = swarm.path("$.ctx.x"), out = "ctx.y" })
        expect(n.kind).to.equal("step")
        expect(n.ref).to.equal("@a")
        expect(n.in_.op).to.equal("path")
        expect(n.out).to.equal("ctx.y")
    end)

    it("chain: {kind='seq', children}", function()
        local n = swarm.chain({ swarm.step("@a", { out = "ctx.a" }) })
        expect(n.kind).to.equal("seq")
        expect(#n.children).to.equal(1)
    end)

    it("fan: {kind='fanout', items, bind, body, join, out}", function()
        local n = swarm.fan(
            swarm.step("@panelist", { in_ = swarm.path("$.ctx.item"), out = "ctx.r" }),
            swarm.path("$.ctx.items"),
            { bind = "ctx.item", out = "ctx.results", join = "all" })
        expect(n.kind).to.equal("fanout")
        expect(n.bind).to.equal("ctx.item")
        expect(n.join).to.equal("all")
        expect(n.out).to.equal("ctx.results")
        expect(n.items.op).to.equal("path")
        expect(n.body.kind).to.equal("step")
    end)

    it("loop with cond positional", function()
        local n = swarm.loop(
            swarm.step("@x", { out = "ctx.x" }),
            swarm.lt(swarm.path("$.ctx.i"), swarm.lit(3)),
            { max = 5, counter = "ctx.i" })
        expect(n.kind).to.equal("loop")
        expect(n.cond.op).to.equal("lt")
        expect(n.max).to.equal(5)
        expect(n.counter).to.equal("ctx.i")
    end)

    it("loop with until_ sugar: cond synthesized as not_(until_)", function()
        local until_expr = swarm.eq(swarm.path("$.ctx.v"), swarm.lit("DONE"))
        local n = swarm.loop(
            swarm.step("@x", { out = "ctx.v" }),
            nil,
            { until_ = until_expr, max = 3, counter = "ctx.i" })
        expect(n.kind).to.equal("loop")
        expect(n.cond.op).to.equal("not")
        expect(n.cond.arg).to.equal(until_expr)
    end)

    it("loop: cond + until_ both -> raise (V3 §5.3.2)", function()
        local ok = pcall(function()
            swarm.loop(
                swarm.step("@x", { out = "ctx.x" }),
                swarm.lit(true),
                { until_ = swarm.lit(false), max = 1, counter = "ctx.i" })
        end)
        expect(ok).to.equal(false)
    end)

    it("loop: neither cond nor until_ -> raise", function()
        local ok = pcall(function()
            swarm.loop(swarm.step("@x", { out = "ctx.x" }), nil, { max = 1, counter = "ctx.i" })
        end)
        expect(ok).to.equal(false)
    end)

    it("route: {kind='branch', cond, then_, else_}", function()
        local n = swarm.route(
            swarm.eq(swarm.path("$.ctx.kind"), swarm.lit("a")),
            swarm.step("@a_handler", { out = "ctx.r" }),
            swarm.step("@b_handler", { out = "ctx.r" }))
        expect(n.kind).to.equal("branch")
        expect(n.cond.op).to.equal("eq")
        expect(n.then_.kind).to.equal("step")
        expect(n.else_.kind).to.equal("step")
    end)

    it("let: {kind='let', at, value}", function()
        local n = swarm.let("ctx.x", swarm.lit(42))
        expect(n.kind).to.equal("let")
        expect(n.at).to.equal("ctx.x")
        expect(n.value.value).to.equal(42)
    end)

    it("call: {kind='call', flow, args, out}", function()
        local n = swarm.call("sub_flow",
            { input = swarm.path("$.ctx.payload") },
            { out = "ctx.sub_result" })
        expect(n.kind).to.equal("call")
        expect(n.flow).to.equal("sub_flow")
        expect(n.args.input.op).to.equal("path")
        expect(n.out).to.equal("ctx.sub_result")
    end)
end)

describe("swarm.v3 Expr DSL shapes", function()
    it("path", function()
        expect(swarm.path("$.ctx.x").op).to.equal("path")
    end)
    it("lit", function()
        expect(swarm.lit(7).op).to.equal("lit")
        expect(swarm.lit(7).value).to.equal(7)
    end)
    it("eq", function()
        local e = swarm.eq(swarm.lit(1), swarm.lit(1))
        expect(e.op).to.equal("eq")
        expect(e.lhs.value).to.equal(1)
        expect(e.rhs.value).to.equal(1)
    end)
    it("and_ with >=2 args", function()
        local e = swarm.and_({ swarm.lit(true), swarm.lit(true) })
        expect(e.op).to.equal("and")
        expect(#e.args).to.equal(2)
    end)
    it("and_ with <2 args raises (V3 §5.2.2)", function()
        expect(pcall(function() swarm.and_({ swarm.lit(true) }) end)).to.equal(false)
        expect(pcall(function() swarm.and_({}) end)).to.equal(false)
    end)
    it("or_ with >=2 args", function()
        local e = swarm.or_({ swarm.lit(false), swarm.lit(true) })
        expect(e.op).to.equal("or")
    end)
    it("or_ with <2 args raises", function()
        expect(pcall(function() swarm.or_({ swarm.lit(true) }) end)).to.equal(false)
    end)
    it("not_", function()
        local e = swarm.not_(swarm.lit(true))
        expect(e.op).to.equal("not")
        expect(e.arg.value).to.equal(true)
    end)
    it("lt", function()
        local e = swarm.lt(swarm.lit(1), swarm.lit(2))
        expect(e.op).to.equal("lt")
    end)
    it("len", function()
        local e = swarm.len(swarm.path("$.ctx.items"))
        expect(e.op).to.equal("len")
        expect(e.arg.op).to.equal("path")
    end)
    it("ext: {op='call_extern', ref, args}", function()
        local e = swarm.ext("kemeny.aggregate", { swarm.path("$.ctx.cands") })
        expect(e.op).to.equal("call_extern")
        expect(e.ref).to.equal("kemeny.aggregate")
        expect(#e.args).to.equal(1)
    end)
    it("ext: empty args (nullary fn)", function()
        local e = swarm.ext("now", {})
        expect(e.op).to.equal("call_extern")
        expect(#e.args).to.equal(0)
    end)
    it("ext: missing/empty ref raises", function()
        expect(pcall(function() swarm.ext("", {}) end)).to.equal(false)
        expect(pcall(function() swarm.ext(nil, {}) end)).to.equal(false)
    end)
end)

-- ── End-to-end exec through flow.ir ─────────────────────────────────

describe("swarm.v3 e2e exec via flow.ir", function()
    it("route: then branch executes", function()
        local shape = swarm.chain({
            swarm.let("ctx.kind", swarm.lit("a")),
            swarm.route(
                swarm.eq(swarm.path("$.ctx.kind"), swarm.lit("a")),
                swarm.step("@a_handler", { out = "ctx.r" }),
                swarm.step("@b_handler", { out = "ctx.r" })),
        })
        local result = swarm.run({
            shape    = shape,
            dispatch = function(ref) return { took = ref } end,
        })
        expect(result.status).to.equal("ok")
        expect(result.ctx.r.took).to.equal("@a_handler")
    end)

    it("route: else branch executes", function()
        local shape = swarm.chain({
            swarm.let("ctx.kind", swarm.lit("b")),
            swarm.route(
                swarm.eq(swarm.path("$.ctx.kind"), swarm.lit("a")),
                swarm.step("@a_handler", { out = "ctx.r" }),
                swarm.step("@b_handler", { out = "ctx.r" })),
        })
        local result = swarm.run({
            shape    = shape,
            dispatch = function(ref) return { took = ref } end,
        })
        expect(result.status).to.equal("ok")
        expect(result.ctx.r.took).to.equal("@b_handler")
    end)

    it("let: writes Expr eval to ctx path", function()
        local shape = swarm.let("ctx.answer", swarm.lit(42))
        local result = swarm.run({
            shape    = shape,
            dispatch = function() return nil end,
        })
        expect(result.status).to.equal("ok")
        expect(result.ctx.answer).to.equal(42)
    end)

    it("ext: pure fn whitelist via externs", function()
        local shape = swarm.let("ctx.doubled",
            swarm.ext("double", { swarm.path("$.ctx.n") }))
        local result = swarm.run({
            shape    = shape,
            dispatch = function() return nil end,
            externs  = { double = function(x) return x * 2 end },
            ctx      = { n = 21 },  -- ctx.* paths are syntactic; n lives at ctx root
        })
        expect(result.status).to.equal("ok")
        expect(result.ctx.doubled).to.equal(42)
    end)

    it("loop with until_ + counter: short-circuits when verdict matches", function()
        local attempts = 0
        local shape = swarm.loop(
            swarm.step("@gate", { out = "ctx.last" }),
            nil,
            { until_   = swarm.eq(swarm.path("$.ctx.last.verdict"), swarm.lit("DONE")),
              max     = 5,
              counter = "ctx.iter" })
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

    it("call: sub-flow registry threads args + writes out", function()
        local sub = swarm.chain({
            swarm.let("ctx.echo", swarm.path("$.ctx.input")),
        })
        local shape = swarm.call("sub", { input = swarm.lit("hi") }, { out = "ctx.sub_ctx" })
        local result = swarm.run({
            shape    = shape,
            dispatch = function() return nil end,
            flows    = { sub = sub },
        })
        expect(result.status).to.equal("ok")
        expect(result.ctx.sub_ctx.echo).to.equal("hi")
    end)

    it("fan: 'all' join collects every branch ctx", function()
        local body = swarm.step("@worker",
            { in_ = swarm.path("$.ctx.item"), out = "ctx.r" })
        local shape = swarm.fan(body, swarm.path("$.ctx.items"),
            { bind = "ctx.item", out = "ctx.results", join = "all" })
        local result = swarm.run({
            shape    = shape,
            dispatch = function(_, input) return { got = input } end,
            ctx      = { items = { "x", "y", "z" } },
        })
        expect(result.status).to.equal("ok")
        expect(type(result.ctx.results)).to.equal("table")
        expect(#result.ctx.results).to.equal(3)
    end)
end)
