local describe, it, expect = lust.describe, lust.it, lust.expect

local bp = require("swarm_blueprint")

local function deep_equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do
        if not deep_equal(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

describe("swarm_blueprint Node builders", function()
    it("step() uses literal ref/in/out keys with Expr-wrapped in/out", function()
        local node = bp.step({ ref = "grader", in_ = bp.path("$.task"), out = bp.path("$.verdict") })
        expect(node.kind).to.equal("step")
        expect(node.ref).to.equal("grader")
        expect(deep_equal(node["in"], { op = "path", at = "$.task" })).to.equal(true)
        expect(deep_equal(node.out, { op = "path", at = "$.verdict" })).to.equal(true)
    end)

    it("step() auto-wraps raw values passed as in_/out via lit()", function()
        local node = bp.step({ ref = "r", in_ = 42, out = "done" })
        expect(deep_equal(node["in"], { op = "lit", value = 42 })).to.equal(true)
        expect(deep_equal(node.out, { op = "lit", value = "done" })).to.equal(true)
    end)

    it("seq() builds a children array of Node", function()
        local a = bp.step({ ref = "a", in_ = bp.lit(1), out = bp.path("$.a") })
        local b = bp.step({ ref = "b", in_ = bp.lit(2), out = bp.path("$.b") })
        local node = bp.seq({ a, b })
        expect(node.kind).to.equal("seq")
        expect(#node.children).to.equal(2)
        expect(deep_equal(node.children[1], a)).to.equal(true)
        expect(deep_equal(node.children[2], b)).to.equal(true)
    end)

    it("branch() uses literal then/else keys, else_ is optional", function()
        local then_node = bp.step({ ref = "t", in_ = bp.lit(1), out = bp.path("$.t") })
        local else_node = bp.step({ ref = "e", in_ = bp.lit(2), out = bp.path("$.e") })
        local node = bp.branch({ cond = bp.eq(bp.path("$.x"), bp.lit(1)), then_ = then_node, else_ = else_node })
        expect(node.kind).to.equal("branch")
        expect(deep_equal(node["then"], then_node)).to.equal(true)
        expect(deep_equal(node["else"], else_node)).to.equal(true)

        local node_no_else = bp.branch({ cond = bp.exists("$.x"), then_ = then_node })
        expect(node_no_else["else"]).to.equal(nil)
    end)

    it("fanout() defaults join to 'all' and wraps items/bind/out as Expr", function()
        local body = bp.step({ ref = "worker", in_ = bp.path("$.item"), out = bp.path("$.result") })
        local node = bp.fanout({ items = bp.path("$.list"), bind = bp.path("$.item"), body = body, out = bp.path("$.results") })
        expect(node.kind).to.equal("fanout")
        expect(node.join).to.equal("all")
        expect(deep_equal(node.items, { op = "path", at = "$.list" })).to.equal(true)
        expect(deep_equal(node.bind, { op = "path", at = "$.item" })).to.equal(true)
        expect(deep_equal(node.body, body)).to.equal(true)
    end)

    it("fanout() accepts explicit join and rejects invalid join", function()
        local body = bp.step({ ref = "w", in_ = bp.lit(1), out = bp.path("$.r") })
        local node = bp.fanout({ items = bp.path("$.l"), bind = bp.path("$.i"), body = body, out = bp.path("$.o"), join = "race" })
        expect(node.join).to.equal("race")

        local ok = pcall(bp.fanout, { items = bp.path("$.l"), bind = bp.path("$.i"), body = body, out = bp.path("$.o"), join = "bogus" })
        expect(ok).to.equal(false)
    end)

    it("loop() carries counter/cond/body/max", function()
        local body = bp.step({ ref = "w", in_ = bp.lit(1), out = bp.path("$.r") })
        local node = bp.loop({ counter = bp.path("$.n"), cond = bp.lt(bp.path("$.n"), bp.lit(3)), body = body, max = 3 })
        expect(node.kind).to.equal("loop")
        expect(node.max).to.equal(3)
        expect(deep_equal(node.body, body)).to.equal(true)
    end)

    it("try_() supports optional err_at", function()
        local body = bp.step({ ref = "w", in_ = bp.lit(1), out = bp.path("$.r") })
        local catch = bp.assign({ at = bp.path("$.err"), value = bp.lit("failed") })
        local node = bp.try_({ body = body, catch = catch })
        expect(node.kind).to.equal("try")
        expect(node.err_at).to.equal(nil)

        local node2 = bp.try_({ body = body, catch = catch, err_at = bp.path("$.e") })
        expect(deep_equal(node2.err_at, { op = "path", at = "$.e" })).to.equal(true)
    end)

    it("assign() wraps at/value as Expr", function()
        local node = bp.assign({ at = bp.path("$.x"), value = 7 })
        expect(node.kind).to.equal("assign")
        expect(deep_equal(node.at, { op = "path", at = "$.x" })).to.equal(true)
        expect(deep_equal(node.value, { op = "lit", value = 7 })).to.equal(true)
    end)
end)

describe("swarm_blueprint Expr builders", function()
    it("path() requires a '$'-prefixed string", function()
        expect(deep_equal(bp.path("$.x.y"), { op = "path", at = "$.x.y" })).to.equal(true)
        local ok = pcall(bp.path, "x.y")
        expect(ok).to.equal(false)
    end)

    it("lit() wraps any raw value", function()
        expect(deep_equal(bp.lit(1), { op = "lit", value = 1 })).to.equal(true)
        expect(deep_equal(bp.lit("s"), { op = "lit", value = "s" })).to.equal(true)
        expect(deep_equal(bp.lit(true), { op = "lit", value = true })).to.equal(true)
    end)

    it("comparison ops (eq/ne/lt/le/gt/ge) share shape and auto-wrap raw args", function()
        local ops = { "eq", "ne", "lt", "le", "gt", "ge" }
        for _, op_name in ipairs(ops) do
            local node = bp[op_name](bp.path("$.a"), 1)
            expect(node.op).to.equal(op_name)
            expect(deep_equal(node.lhs, { op = "path", at = "$.a" })).to.equal(true)
            expect(deep_equal(node.rhs, { op = "lit", value = 1 })).to.equal(true)
        end
    end)

    it("not_() wraps a single operand", function()
        local node = bp.not_(bp.exists("$.x"))
        expect(deep_equal(node, { op = "not", operand = { op = "exists", at = "$.x" } })).to.equal(true)
    end)

    it("and_()/or_() take an array and auto-wrap raw values", function()
        local node = bp.and_({ bp.exists("$.a"), true })
        expect(node.op).to.equal("and")
        expect(#node.operands).to.equal(2)
        expect(deep_equal(node.operands[2], { op = "lit", value = true })).to.equal(true)

        local node2 = bp.or_({ bp.exists("$.a"), bp.exists("$.b") })
        expect(node2.op).to.equal("or")
    end)

    it("exists() requires a '$'-prefixed string", function()
        expect(deep_equal(bp.exists("$.x"), { op = "exists", at = "$.x" })).to.equal(true)
        local ok = pcall(bp.exists, "nope")
        expect(ok).to.equal(false)
    end)

    it("arithmetic ops (add/sub/mul/div) share shape", function()
        local ops = { "add", "sub", "mul", "div" }
        for _, op_name in ipairs(ops) do
            local node = bp[op_name](1, 2)
            expect(node.op).to.equal(op_name)
            expect(deep_equal(node.lhs, { op = "lit", value = 1 })).to.equal(true)
            expect(deep_equal(node.rhs, { op = "lit", value = 2 })).to.equal(true)
        end
    end)

    it("len() wraps its operand under 'of'", function()
        local node = bp.len(bp.path("$.list"))
        expect(deep_equal(node, { op = "len", of = { op = "path", at = "$.list" } })).to.equal(true)
    end)

    it("in_() wraps needle/haystack", function()
        local node = bp.in_("x", bp.path("$.list"))
        expect(node.op).to.equal("in")
        expect(deep_equal(node.needle, { op = "lit", value = "x" })).to.equal(true)
        expect(deep_equal(node.haystack, { op = "path", at = "$.list" })).to.equal(true)
    end)

    it("mod_() wraps lhs/rhs with literal numbers", function()
        local node = bp.mod_(7, 3)
        expect(deep_equal(node, { op = "mod", lhs = { op = "lit", value = 7 }, rhs = { op = "lit", value = 3 } }))
            .to.equal(true)
    end)

    it("mod_() accepts Expr arguments", function()
        local node = bp.mod_(bp.path("$.i"), bp.lit(2))
        expect(deep_equal(node.lhs, { op = "path", at = "$.i" })).to.equal(true)
        expect(deep_equal(node.rhs, { op = "lit", value = 2 })).to.equal(true)
    end)

    it("mod_() errors on missing lhs/rhs", function()
        expect(pcall(bp.mod_, 7)).to.equal(false)
        expect(pcall(bp.mod_)).to.equal(false)
    end)

    it("call_extern() wraps a single literal arg with the literal 'ref' key", function()
        local node = bp.call_extern("math.sqrt", 9)
        expect(deep_equal(node, { op = "call_extern", ["ref"] = "math.sqrt", args = { { op = "lit", value = 9 } } }))
            .to.equal(true)
    end)

    it("call_extern() accepts a mix of Expr and raw args", function()
        local node = bp.call_extern("f", bp.path("$.x"), 2, bp.lit("s"))
        expect(#node.args).to.equal(3)
        expect(deep_equal(node.args[1], { op = "path", at = "$.x" })).to.equal(true)
        expect(deep_equal(node.args[2], { op = "lit", value = 2 })).to.equal(true)
        expect(deep_equal(node.args[3], { op = "lit", value = "s" })).to.equal(true)
    end)

    it("call_extern() allows zero args", function()
        local node = bp.call_extern("noop")
        expect(node.op).to.equal("call_extern")
        expect(deep_equal(node.args, {})).to.equal(true)
    end)

    it("call_extern() errors on missing or invalid ref", function()
        expect(pcall(bp.call_extern, nil)).to.equal(false)
        expect(pcall(bp.call_extern, 123)).to.equal(false)
        expect(pcall(bp.call_extern, "")).to.equal(false)
    end)

    it("call_extern() composes correctly inside assign()", function()
        local node = bp.assign({ at = bp.path("$.y"), value = bp.call_extern("math.sqrt", bp.path("$.x")) })
        local expected = {
            kind = "assign",
            at = { op = "path", at = "$.y" },
            value = {
                op = "call_extern",
                ["ref"] = "math.sqrt",
                args = { { op = "path", at = "$.x" } },
            },
        }
        expect(deep_equal(node, expected)).to.equal(true)
    end)
end)

describe("swarm_blueprint envelope builders", function()
    it("blueprint() sets schema_version, stores origin/description/tags under metadata", function()
        local flow = bp.step({ ref = "r", in_ = bp.lit(1), out = bp.path("$.o") })
        local envelope = bp.blueprint({
            id = "coding-review-v1",
            flow = flow,
            origin = bp.origin_algo("sess-1"),
            description = "example",
            tags = { "a", "b" },
        })
        expect(envelope.schema_version).to.equal("0.1.0")
        expect(envelope.id).to.equal("coding-review-v1")
        expect(deep_equal(envelope.flow, flow)).to.equal(true)
        expect(deep_equal(envelope.metadata.origin, { kind = "algo", session_id = "sess-1" })).to.equal(true)
        expect(envelope.metadata.description).to.equal("example")
        expect(deep_equal(envelope.metadata.tags, { "a", "b" })).to.equal(true)
    end)

    it("blueprint() omits agents/operators/metadata when not provided", function()
        local flow = bp.step({ ref = "r", in_ = bp.lit(1), out = bp.path("$.o") })
        local envelope = bp.blueprint({ id = "minimal", flow = flow })
        expect(envelope.agents).to.equal(nil)
        expect(envelope.operators).to.equal(nil)
        expect(envelope.metadata).to.equal(nil)
    end)

    it("blueprint() shallow-merges opts pass-through onto the top level", function()
        local flow = bp.step({ ref = "r", in_ = bp.lit(1), out = bp.path("$.o") })
        local envelope = bp.blueprint({ id = "with-hints", flow = flow, opts = { hints = { retry = 2 } } })
        expect(deep_equal(envelope.hints, { retry = 2 })).to.equal(true)
    end)

    it("agent() defaults spec to {} and includes profile when given", function()
        local agent = bp.agent({
            name = "worker",
            kind = "lua",
            profile = { system_prompt = "be helpful", model = "claude-haiku" },
        })
        expect(agent.name).to.equal("worker")
        expect(agent.kind).to.equal("lua")
        expect(deep_equal(agent.spec, {})).to.equal(true)
        expect(agent.profile.system_prompt).to.equal("be helpful")
        expect(agent.profile.model).to.equal("claude-haiku")
        expect(agent.profile.tools).to.equal(nil)
    end)

    it("operator() omits kind/spec/display_name when not provided", function()
        local op = bp.operator({ name = "gate" })
        expect(op.name).to.equal("gate")
        expect(op.kind).to.equal(nil)
        expect(op.spec).to.equal(nil)
    end)

    it("origin_algo/origin_inline/origin_file produce the correct tagged shape", function()
        expect(deep_equal(bp.origin_algo("s1"), { kind = "algo", session_id = "s1" })).to.equal(true)
        expect(deep_equal(bp.origin_inline(), { kind = "inline" })).to.equal(true)
        expect(deep_equal(bp.origin_file("/tmp/x.json"), { kind = "file", path = "/tmp/x.json" })).to.equal(true)
    end)
end)

describe("swarm_blueprint validation", function()
    it("step() errors on missing ref/in_/out", function()
        expect(pcall(bp.step, { in_ = bp.lit(1), out = bp.lit(2) })).to.equal(false)
        expect(pcall(bp.step, { ref = "r", out = bp.lit(2) })).to.equal(false)
        expect(pcall(bp.step, { ref = "r", in_ = bp.lit(1) })).to.equal(false)
    end)

    it("blueprint() errors on missing id/flow", function()
        expect(pcall(bp.blueprint, { flow = bp.step({ ref = "r", in_ = bp.lit(1), out = bp.lit(1) }) })).to.equal(false)
        expect(pcall(bp.blueprint, { id = "x" })).to.equal(false)
    end)

    it("agent()/operator() error on invalid kind enum", function()
        expect(pcall(bp.agent, { name = "a", kind = "bogus" })).to.equal(false)
        expect(pcall(bp.operator, { name = "o", kind = "bogus" })).to.equal(false)
    end)

    it("path()/exists() error on non-'$' string", function()
        expect(pcall(bp.path, "no-dollar")).to.equal(false)
        expect(pcall(bp.exists, "no-dollar")).to.equal(false)
    end)

    it("Node builders reject Expr passed where Node is expected", function()
        local expr = bp.lit(1)
        expect(pcall(bp.seq, { expr })).to.equal(false)
        expect(
            pcall(bp.branch, { cond = bp.lit(true), then_ = expr })
        ).to.equal(false)
    end)
end)

describe("swarm_blueprint verdict-loop style combination", function()
    it("builds a grader step wrapped in a loop bounded to 3 iterations", function()
        local grader_step = bp.step({
            ref = "grader",
            in_ = bp.path("$.task"),
            out = bp.path("$.verdict"),
        })

        local flow = bp.loop({
            counter = bp.path("$.attempt"),
            cond = bp.and_({
                bp.lt(bp.path("$.attempt"), bp.lit(3)),
                bp.ne(bp.path("$.verdict"), bp.lit("ok")),
            }),
            body = grader_step,
            max = 3,
        })

        local envelope = bp.blueprint({
            id = "verdict-loop-v1",
            flow = flow,
            agents = { bp.agent({ name = "grader", kind = "lua" }) },
            origin = bp.origin_inline(),
        })

        local expected = {
            schema_version = "0.1.0",
            id = "verdict-loop-v1",
            flow = {
                kind = "loop",
                counter = { op = "path", at = "$.attempt" },
                cond = {
                    op = "and",
                    operands = {
                        { op = "lt", lhs = { op = "path", at = "$.attempt" }, rhs = { op = "lit", value = 3 } },
                        { op = "ne", lhs = { op = "path", at = "$.verdict" }, rhs = { op = "lit", value = "ok" } },
                    },
                },
                body = {
                    kind = "step",
                    ref = "grader",
                    ["in"] = { op = "path", at = "$.task" },
                    out = { op = "path", at = "$.verdict" },
                },
                max = 3,
            },
            agents = { { name = "grader", kind = "lua", spec = {} } },
            metadata = { origin = { kind = "inline" } },
        }

        expect(deep_equal(envelope, expected)).to.equal(true)
    end)
end)
