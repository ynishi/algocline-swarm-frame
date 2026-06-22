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

-- ── enhance_loop (P9 land) ──────────────────────────────────────────

describe("swarm.composite.enhance_loop (shape)", function()
    it("compiles to chain([let init, loop(chain([step(in_=carry), let(carry, ext append)]), until=eq(verdict, token))])", function()
        local outer = C.enhance_loop({
            step = "@gate",
            max  = 3,
        })
        expect(outer.kind).to.equal("seq")
        expect(#outer.children).to.equal(2)
        -- child[1] = init let (carry to empty array)
        local init_let = outer.children[1]
        expect(init_let.kind).to.equal("let")
        expect(init_let.at).to.equal("ctx.fix_carry")
        expect(init_let.value.op).to.equal("lit")
        expect(type(init_let.value.value)).to.equal("table")
        expect(#init_let.value.value).to.equal(0)
        -- child[2] = the loop
        local n = outer.children[2]
        expect(n.kind).to.equal("loop")
        expect(n.max).to.equal(3)
        expect(n.counter).to.equal("ctx.iter")
        -- body is chain of [step, let]
        expect(n.body.kind).to.equal("seq")
        expect(#n.body.children).to.equal(2)
        local step_node = n.body.children[1]
        expect(step_node.kind).to.equal("step")
        expect(step_node.ref).to.equal("@gate")
        expect(step_node.in_.op).to.equal("path")
        expect(step_node.in_.at).to.equal("$.ctx.fix_carry")
        expect(step_node.out).to.equal("ctx.last")
        local let_node = n.body.children[2]
        expect(let_node.kind).to.equal("let")
        expect(let_node.at).to.equal("ctx.fix_carry")
        expect(let_node.value.op).to.equal("call_extern")
        expect(let_node.value.ref).to.equal("__append_carry__")
        expect(let_node.value.args[1].at).to.equal("$.ctx.fix_carry")
        expect(let_node.value.args[2].at).to.equal("$.ctx.last")
        -- cond is synthesized as not_(eq(path(verdict), lit(until_token)))
        expect(n.cond.op).to.equal("not")
        expect(n.cond.arg.op).to.equal("eq")
        expect(n.cond.arg.lhs.at).to.equal("$.ctx.last.verdict")
        expect(n.cond.arg.rhs.value).to.equal("pass")
    end)

    it("respects custom carry / out / verdict_field / until_token", function()
        local outer = C.enhance_loop({
            step          = "@review",
            until_token   = "ACCEPT",
            max           = 5,
            out           = "ctx.review",
            verdict_field = "decision",
            carry         = "ctx.review_carry",
        })
        local init_let = outer.children[1]
        expect(init_let.at).to.equal("ctx.review_carry")
        local n = outer.children[2]
        local step_node = n.body.children[1]
        expect(step_node.in_.at).to.equal("$.ctx.review_carry")
        expect(step_node.out).to.equal("ctx.review")
        local let_node = n.body.children[2]
        expect(let_node.at).to.equal("ctx.review_carry")
        expect(let_node.value.args[1].at).to.equal("$.ctx.review_carry")
        expect(let_node.value.args[2].at).to.equal("$.ctx.review")
        expect(n.cond.arg.lhs.at).to.equal("$.ctx.review.decision")
        expect(n.cond.arg.rhs.value).to.equal("ACCEPT")
    end)

    it("raises on missing required opts", function()
        expect(pcall(function() C.enhance_loop({}) end)).to.equal(false)
        expect(pcall(function() C.enhance_loop({ step = "@x" }) end)).to.equal(false)
        expect(pcall(function() C.enhance_loop({ max = 3 }) end)).to.equal(false)
        expect(pcall(function() C.enhance_loop("not-table") end)).to.equal(false)
    end)
end)

describe("swarm.composite.enhance_loop (e2e exec)", function()
    it("accumulates carry across iterations, exits on verdict pass", function()
        local attempts = 0
        local received_carries = {}
        local shape = C.enhance_loop({
            step = "@gate",
            max  = 5,
        })
        local result = swarm.run({
            shape    = shape,
            dispatch = function(_ref, input)
                attempts = attempts + 1
                -- Capture what the dispatcher saw as input on each iter
                received_carries[attempts] = input
                if attempts < 3 then
                    return { verdict = "RETRY", deny = "concern_" .. attempts }
                end
                return { verdict = "pass", body = "final" }
            end,
        })
        expect(result.status).to.equal("ok")
        expect(attempts).to.equal(3)
        -- Iter 1 input is the init-empty carry array {} (not nil)
        expect(type(received_carries[1])).to.equal("table")
        expect(#received_carries[1]).to.equal(0)
        -- Iter 2 input is array of 1 prev response
        expect(type(received_carries[2])).to.equal("table")
        expect(#received_carries[2]).to.equal(1)
        expect(received_carries[2][1].verdict).to.equal("RETRY")
        expect(received_carries[2][1].deny).to.equal("concern_1")
        -- Iter 3 input is array of 2 prev responses
        expect(#received_carries[3]).to.equal(2)
        expect(received_carries[3][2].deny).to.equal("concern_2")
        -- After loop exit, ctx.fix_carry has all 3 attempts
        expect(#result.ctx.fix_carry).to.equal(3)
        expect(result.ctx.fix_carry[3].verdict).to.equal("pass")
    end)

    it("hits max without pass — loop exits, full carry preserved", function()
        local shape = C.enhance_loop({
            step = "@gate",
            max  = 2,
        })
        local result = swarm.run({
            shape    = shape,
            dispatch = function() return { verdict = "RETRY", deny = "never_pass" } end,
        })
        expect(result.status).to.equal("ok")
        -- carry has 2 attempts (max iterations reached)
        expect(#result.ctx.fix_carry).to.equal(2)
        expect(result.ctx.last.verdict).to.equal("RETRY")
    end)

    it("custom carry path isolates multiple enhance_loops in one pipeline", function()
        local hits = { a = 0, b = 0 }
        local shape = swarm.chain({
            C.enhance_loop({
                step  = "@gate_a",
                carry = "ctx.carry_a",
                out   = "ctx.last_a",
                max   = 2,
            }),
            C.enhance_loop({
                step  = "@gate_b",
                carry = "ctx.carry_b",
                out   = "ctx.last_b",
                max   = 2,
            }),
        })
        local result = swarm.run({
            shape    = shape,
            dispatch = function(ref, input)
                if ref == "@gate_a" then
                    hits.a = hits.a + 1
                    if hits.a < 2 then return { verdict = "RETRY", note = "A1" } end
                    return { verdict = "pass", note = "A_ok" }
                elseif ref == "@gate_b" then
                    hits.b = hits.b + 1
                    return { verdict = "pass", note = "B_ok",
                             saw_b_carry = input }
                end
            end,
        })
        expect(result.status).to.equal("ok")
        expect(hits.a).to.equal(2)
        expect(hits.b).to.equal(1)
        -- carry_a accumulated A attempts; carry_b is independent (only 1)
        expect(#result.ctx.carry_a).to.equal(2)
        expect(#result.ctx.carry_b).to.equal(1)
        -- @gate_b on iter 1 saw its OWN init-empty carry (own scope), not gate_a's carry
        expect(type(result.ctx.last_b.saw_b_carry)).to.equal("table")
        expect(#result.ctx.last_b.saw_b_carry).to.equal(0)
    end)
end)

-- ── escalate_gate (P9 land) ─────────────────────────────────────────

describe("swarm.composite.escalate_gate (shape)", function()
    it("compiles to chain([step, route(and(eq verdict, not decision), ext escalate, nil)])", function()
        local n = C.escalate_gate({ step = "@gate" })
        expect(n.kind).to.equal("seq")
        expect(#n.children).to.equal(2)
        -- step node
        local step_node = n.children[1]
        expect(step_node.kind).to.equal("step")
        expect(step_node.ref).to.equal("@gate")
        expect(step_node.out).to.equal("ctx.last")
        -- route node
        local route_node = n.children[2]
        expect(route_node.kind).to.equal("branch")
        expect(route_node.cond.op).to.equal("and")
        expect(#route_node.cond.args).to.equal(2)
        -- verdict==blocked
        local verdict_eq = route_node.cond.args[1]
        expect(verdict_eq.op).to.equal("eq")
        expect(verdict_eq.lhs.at).to.equal("$.ctx.last.verdict")
        expect(verdict_eq.rhs.value).to.equal("blocked")
        -- not(decision)
        local not_decision = route_node.cond.args[2]
        expect(not_decision.op).to.equal("not")
        expect(not_decision.arg.op).to.equal("path")
        expect(not_decision.arg.at).to.equal("$.ctx.escalation_decision")
        -- then = let(_escalate_void, ext("__escalate__", [path(ctx.last)]))
        local then_node = route_node.then_
        expect(then_node.kind).to.equal("let")
        expect(then_node.value.op).to.equal("call_extern")
        expect(then_node.value.ref).to.equal("__escalate__")
        expect(then_node.value.args[1].at).to.equal("$.ctx.last")
        -- else nil
        expect(route_node.else_).to.equal(nil)
    end)

    it("respects custom out / verdict_field / blocked_token / resume_key", function()
        local n = C.escalate_gate({
            step          = "@review",
            out           = "ctx.review",
            verdict_field = "decision",
            blocked_token = "STOP",
            resume_key    = "ctx.human_input.review",
        })
        local route_node = n.children[2]
        local verdict_eq = route_node.cond.args[1]
        expect(verdict_eq.lhs.at).to.equal("$.ctx.review.decision")
        expect(verdict_eq.rhs.value).to.equal("STOP")
        local not_decision = route_node.cond.args[2]
        expect(not_decision.arg.at).to.equal("$.ctx.human_input.review")
    end)

    it("raises on missing required opts", function()
        expect(pcall(function() C.escalate_gate({}) end)).to.equal(false)
        expect(pcall(function() C.escalate_gate({ step = "" }) end)).to.equal(false)
        expect(pcall(function() C.escalate_gate("not-a-table") end)).to.equal(false)
    end)
end)

describe("swarm.composite.escalate_gate (e2e exec)", function()
    -- ── mock state_backend (in-memory) ──────────────────────────────
    local function make_backend()
        local store = {}
        return {
            store  = store,
            exists = function(id) return store[id] ~= nil end,
            read   = function(id) return store[id] end,
            write  = function(id, snap) store[id] = snap end,
            delete = function(id) store[id] = nil end,
        }
    end

    it("PASS verdict completes ok with no escalate raise", function()
        local b = make_backend()
        local shape = C.escalate_gate({ step = "@gate" })
        local r = swarm.run({
            shape         = shape,
            dispatch      = function() return { verdict = "pass", body = "ok" } end,
            state_backend = b,
            state         = { task_id = "t-pass" },
        })
        expect(r.status).to.equal("ok")
        expect(r.ctx.last.verdict).to.equal("pass")
        expect(b.store["t-pass"].status).to.equal("completed")
    end)

    it("BLOCKED verdict halts with INTERRUPTED + preserves ctx.last", function()
        local b = make_backend()
        local shape = C.escalate_gate({ step = "@gate" })
        local r = swarm.run({
            shape         = shape,
            dispatch      = function()
                return { verdict = "blocked", body = "needs human" }
            end,
            state_backend = b,
            state         = { task_id = "t-block" },
        })
        expect(r.status).to.equal("error")
        expect(r.error.kind).to.equal("escalate_required")
        expect(b.store["t-block"].status).to.equal("interrupted")
        -- ctx.last is preserved so the caller can read what was blocked
        expect(b.store["t-block"].ctx.last.verdict).to.equal("blocked")
        expect(b.store["t-block"].ctx.last.body).to.equal("needs human")
    end)

    it("resume after decision injected completes ok (route skips escalate)", function()
        local b = make_backend()
        -- prior INTERRUPTED state from a halted run, with decision now injected.
        -- The step itself will be re-dispatched on resume (flow.ir does not
        -- auto-fill _progress for steps); the gate's route condition checks
        -- `not_(path(resume_key))` and skips the escalate branch because
        -- escalation_decision is now truthy.
        b.store["t-resume"] = {
            status = "interrupted",
            ctx    = {
                last = { verdict = "blocked", body = "needs human" },
                escalation_decision = { approved = true, note = "Main AI override" },
                _progress = {},
            },
        }
        local shape = C.escalate_gate({ step = "@gate" })
        local r = swarm.run({
            shape         = shape,
            dispatch      = function()
                -- idempotent: gate still reports blocked verdict on re-run.
                return { verdict = "blocked", body = "still blocked" }
            end,
            state_backend = b,
            state         = { task_id = "t-resume" },
        })
        expect(r.status).to.equal("ok")
        expect(r.ctx.escalation_decision.approved).to.equal(true)
        expect(b.store["t-resume"].status).to.equal("completed")
    end)

    it("step short-circuit via _progress at-path (cached resume)", function()
        -- Prior INTERRUPTED state with _progress at-path in flow.ir.path
        -- form (β land: "ctx.last" is now resolved). The step is
        -- short-circuited to the cached value via wrap_dispatch_with_progress;
        -- dispatch is NOT called. The gate then evaluates against the cached
        -- value + injected decision and skips the escalate branch.
        local b = make_backend()
        local dispatch_hits = 0
        b.store["t-cached"] = {
            status = "interrupted",
            ctx    = {
                last = { verdict = "blocked", body = "halted output" },
                escalation_decision = { approved = true },
                _progress = { ["@gate"] = { status = "done", at = "ctx.last" } },
            },
        }
        local shape = C.escalate_gate({ step = "@gate" })
        local r = swarm.run({
            shape         = shape,
            dispatch      = function() dispatch_hits = dispatch_hits + 1; return nil end,
            state_backend = b,
            state         = { task_id = "t-cached" },
        })
        expect(r.status).to.equal("ok")
        expect(dispatch_hits).to.equal(0)
        expect(b.store["t-cached"].status).to.equal("completed")
    end)

    it("auto step_done: BLOCKED first run leaves _progress[@gate].at = step.out", function()
        -- After the first run halts on BLOCKED, ctx._progress[@gate] is
        -- auto-written by runtime (β land: step_out_map → wrap_dispatch_with_progress
        -- POST hook). On resume with decision injected, the cached lookup
        -- short-circuits the step and dispatch is not called again.
        local b = make_backend()
        local first_hits = 0
        local shape = C.escalate_gate({ step = "@gate" })

        -- Run 1: BLOCKED → INTERRUPTED, _progress should be auto-written
        local r1 = swarm.run({
            shape         = shape,
            dispatch      = function()
                first_hits = first_hits + 1
                return { verdict = "blocked", body = "halted" }
            end,
            state_backend = b,
            state         = { task_id = "t-auto" },
        })
        expect(r1.status).to.equal("error")
        expect(r1.error.kind).to.equal("escalate_required")
        expect(b.store["t-auto"].status).to.equal("interrupted")
        expect(b.store["t-auto"].ctx._progress["@gate"]).to.exist()
        expect(b.store["t-auto"].ctx._progress["@gate"].status).to.equal("done")
        expect(b.store["t-auto"].ctx._progress["@gate"].at).to.equal("ctx.last")
        expect(first_hits).to.equal(1)

        -- External injection: caller (Human / Main AI) decides + writes
        b.store["t-auto"].ctx.escalation_decision = { approved = true }

        -- Run 2: resume. Step short-circuits via auto-written _progress;
        -- gate sees decision → skips escalate → completes.
        local second_hits = 0
        local r2 = swarm.run({
            shape         = shape,
            dispatch      = function()
                second_hits = second_hits + 1
                return { verdict = "blocked", body = "should not be re-dispatched" }
            end,
            state_backend = b,
            state         = { task_id = "t-auto" },
        })
        expect(r2.status).to.equal("ok")
        expect(second_hits).to.equal(0)
        expect(b.store["t-auto"].status).to.equal("completed")
    end)

    it("custom resume_key isolates multiple gates", function()
        local b = make_backend()
        -- decision for gate A is set; gate A should NOT escalate even
        -- though verdict=STOP, because resume_key (ctx.approvals.a) is truthy.
        b.store["t-multi"] = {
            status = "interrupted",
            ctx    = {
                review_a  = { decision = "STOP" },
                approvals = { a = { ok = true } },
                _progress = {},
            },
        }
        local shape = C.escalate_gate({
            step          = "@review_a",
            out           = "ctx.review_a",
            verdict_field = "decision",
            blocked_token = "STOP",
            resume_key    = "ctx.approvals.a",
        })
        local r = swarm.run({
            shape         = shape,
            dispatch      = function() return { decision = "STOP" } end,
            state_backend = b,
            state         = { task_id = "t-multi" },
        })
        expect(r.status).to.equal("ok")
        expect(b.store["t-multi"].status).to.equal("completed")
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
