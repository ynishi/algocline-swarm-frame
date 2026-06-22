-- coding_pipeline_spec.lua — Boundary + integration spec.

local lust = require("lust")
local describe, it, expect = lust.describe, lust.it, lust.expect

local pipeline = require("coding_pipeline")

local function contains(s, sub)
    return type(s) == "string" and string.find(s, sub, 1, true) ~= nil
end

-- ─── opts validation ────────────────────────────────────────────────

describe("coding_pipeline.run — opts validation", function()
    it("errors when opts is not a table", function()
        local ok, err = pcall(pipeline.run, "bad")
        expect(ok).to.equal(false)
        expect(contains(err, "opts table required")).to.equal(true)
    end)

    it("errors when opts.task_id is missing", function()
        local ok, err = pcall(pipeline.run, { dispatch = function() end })
        expect(ok).to.equal(false)
        expect(contains(err, "task_id")).to.equal(true)
    end)

    it("errors when opts.dispatch is missing or non-function", function()
        local ok1 = pcall(pipeline.run, { task_id = "t" })
        local ok2 = pcall(pipeline.run, { task_id = "t", dispatch = "no" })
        expect(ok1).to.equal(false)
        expect(ok2).to.equal(false)
    end)
end)

-- ─── build_shape ────────────────────────────────────────────────────

describe("coding_pipeline.build_shape", function()
    it("returns a 6-child chain (plan, spec_qgate, write, compile_qgate, test_qgate, escalate)", function()
        local shape = pipeline.build_shape({})
        expect(shape.kind).to.equal("seq")
        expect(#shape.children).to.equal(6)
        expect(shape.children[1].kind).to.equal("step")
        expect(shape.children[1].ref).to.equal("@coding_plan")
        expect(shape.children[2].kind).to.equal("seq") -- enhance_loop
        expect(shape.children[3].kind).to.equal("step")
        expect(shape.children[3].ref).to.equal("@coding_write")
        expect(shape.children[4].kind).to.equal("seq") -- enhance_loop
        expect(shape.children[5].kind).to.equal("seq") -- enhance_loop
        expect(shape.children[6].kind).to.equal("seq") -- escalate_gate
    end)

    it("honors max knobs per phase", function()
        local shape = pipeline.build_shape({
            plan_max = 2, compile_max = 7, test_max = 4,
        })
        -- enhance_loop emits chain([let init, loop]) — loop is children[2]
        expect(shape.children[2].children[2].max).to.equal(2)
        expect(shape.children[4].children[2].max).to.equal(7)
        expect(shape.children[5].children[2].max).to.equal(4)
    end)

    it("honors refs override (single role swap)", function()
        local shape = pipeline.build_shape({
            refs = { compile_qgate = "@my_compile_v2" },
        })
        -- compile_qgate is inside enhance_loop body of children[4]
        local enhance_loop_seq = shape.children[4]
        local loop_node = enhance_loop_seq.children[2]
        local step_node = loop_node.body.children[1]
        expect(step_node.ref).to.equal("@my_compile_v2")
    end)
end)

-- ─── inject_decision ────────────────────────────────────────────────

describe("coding_pipeline.inject_decision", function()
    it("writes ctx.human_decision to backend entry", function()
        local b = pipeline._for_test.default_backend()
        b.write("t", { status = "interrupted", ctx = {} })
        pipeline.inject_decision(b, "t", { approved = true })
        expect(b.read("t").ctx.human_decision.approved).to.equal(true)
    end)
end)

-- ─── Run 1 + Run 2 (resume) integration ─────────────────────────────

local function make_dispatch(refs, controller)
    local rev = {}
    for role, ref in pairs(refs) do rev[ref] = role end
    local calls = {}
    local d = function(ref, input)
        local role = rev[ref] or "unknown"
        calls[role] = (calls[role] or 0) + 1
        if role == "plan" then
            return { design = "spec_v1", axes = { "A", "B" } }
        elseif role == "plan_qgate" then
            local carry = (type(input) == "table") and input or {}
            local n = #carry + 1
            if n >= 2 then return { verdict = "pass", attempt = n } end
            return { verdict = "RETRY", attempt = n,
                     deny = "missing risk analysis" }
        elseif role == "write_code" then
            return { code = "function f() ... end" }
        elseif role == "compile_qgate" then
            local carry = (type(input) == "table") and input or {}
            local n = #carry + 1
            if n >= 2 then return { verdict = "pass", attempt = n } end
            return { verdict = "RETRY", attempt = n,
                     deny = "undefined symbol baz" }
        elseif role == "test_qgate" then
            local carry = (type(input) == "table") and input or {}
            local n = #carry + 1
            if n >= 3 then return { verdict = "pass", attempt = n } end
            return { verdict = "RETRY", attempt = n,
                     deny = "case_" .. tostring(n) .. " fails" }
        elseif role == "human_review" then
            if controller.phase == 1 then
                return { verdict = "halt", concern = "API public change" }
            end
            return { verdict = "pass", note = "ok" }
        end
    end
    return d, calls
end

describe("coding_pipeline.run — Run 1 halts on human_review", function()
    it("plans, spec-checks, writes, compiles, tests, halts at human review", function()
        local controller = { phase = 1 }
        local refs = pipeline.DEFAULT_REFS
        local d, calls = make_dispatch(refs, controller)
        local r = pipeline.run({
            task_id  = "cp-spec-1",
            dispatch = d,
        })
        expect(r.halted).to.equal(true)
        expect(r.completed).to.equal(false)
        expect(calls.plan).to.equal(1)
        expect(calls.plan_qgate).to.equal(2)         -- 1 retry via carry
        expect(calls.write_code).to.equal(1)
        expect(calls.compile_qgate).to.equal(2)      -- 1 retry via carry
        expect(calls.test_qgate).to.equal(3)         -- 2 retries via carry
        expect(calls.human_review).to.equal(1)
        -- carry shapes
        expect(#r.ctx.plan_carry).to.equal(2)
        expect(#r.ctx.compile_carry).to.equal(2)
        expect(#r.ctx.test_carry).to.equal(3)
        expect(r.ctx.compile_carry[1].deny).to.equal("undefined symbol baz")
        expect(r.ctx.test_carry[2].deny).to.equal("case_2 fails")
        -- escalate halt evidence
        expect(r.ctx.human_review.verdict).to.equal("halt")
        expect(r.result.error.kind).to.equal("escalate_required")
    end)
end)

describe("coding_pipeline.run — Run 2 resume completes", function()
    it("short-circuits top-level steps after decision injection", function()
        local controller = { phase = 1 }
        local refs = pipeline.DEFAULT_REFS
        local d1, _ = make_dispatch(refs, controller)
        local r1 = pipeline.run({
            task_id  = "cp-spec-2",
            dispatch = d1,
        })
        expect(r1.halted).to.equal(true)

        controller.phase = 2
        local d2, calls2 = make_dispatch(refs, controller)
        local r2 = pipeline.run({
            task_id       = "cp-spec-2",
            dispatch      = d2,
            state_backend = r1.state_backend,
            decision      = { approved = true, note = "OK" },
        })
        expect(r2.completed).to.equal(true)
        expect(r2.halted).to.equal(false)
        -- All top-level steps short-circuit via β-fix auto step_done
        expect(calls2.plan or 0).to.equal(0)
        expect(calls2.write_code or 0).to.equal(0)
        expect(calls2.plan_qgate or 0).to.equal(0)
        expect(calls2.compile_qgate or 0).to.equal(0)
        expect(calls2.test_qgate or 0).to.equal(0)
        expect(calls2.human_review or 0).to.equal(0)
        expect(r2.ctx.human_decision.approved).to.equal(true)
    end)
end)
