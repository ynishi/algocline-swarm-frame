-- verdict_swarm_pipeline_spec.lua — Boundary + integration spec.
--
-- Coverage:
--   * opts validation (table / task_id / dispatch)
--   * build_shape returns 7-child chain with proper composite kinds
--   * refs override is merged onto DEFAULT_REFS
--   * Run 1 fresh: halts on caller-defined halt verdict
--   * Run 2 resume: top-level steps short-circuit via β fix
--   * decision injection helper writes ctx.human_decision
--   * caller-supplied dispatch + externs are honored

local lust = require("lust")
local describe, it, expect = lust.describe, lust.it, lust.expect

local pipeline = require("verdict_swarm_pipeline")

local function contains(s, sub)
    return type(s) == "string" and string.find(s, sub, 1, true) ~= nil
end

-- ─── opts validation ────────────────────────────────────────────────

describe("verdict_swarm_pipeline.run — opts validation", function()
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

    it("errors when opts.dispatch is missing", function()
        local ok, err = pcall(pipeline.run, { task_id = "t" })
        expect(ok).to.equal(false)
        expect(contains(err, "dispatch")).to.equal(true)
    end)

    it("errors when opts.dispatch is not a function", function()
        local ok, err = pcall(pipeline.run,
            { task_id = "t", dispatch = "not-a-function" })
        expect(ok).to.equal(false)
        expect(contains(err, "function")).to.equal(true)
    end)
end)

-- ─── build_shape ────────────────────────────────────────────────────

describe("verdict_swarm_pipeline.build_shape", function()
    it("returns a 7-child chain", function()
        local shape = pipeline.build_shape({})
        expect(shape.kind).to.equal("seq")
        expect(#shape.children).to.equal(7)
        expect(shape.children[1].kind).to.equal("step") -- @plan
        expect(shape.children[1].ref).to.equal("@plan")
        expect(shape.children[2].kind).to.equal("seq") -- enhance_loop composite
        expect(shape.children[3].kind).to.equal("seq") -- aggregate composite
        expect(shape.children[4].kind).to.equal("step") -- @draft
        expect(shape.children[4].ref).to.equal("@draft")
        expect(shape.children[5].kind).to.equal("seq") -- enhance_loop composite
        expect(shape.children[6].kind).to.equal("seq") -- escalate_gate composite
        expect(shape.children[7].kind).to.equal("step") -- @finalize
        expect(shape.children[7].ref).to.equal("@finalize")
    end)

    it("honors refs override (caller swaps @plan for @plan_v2)", function()
        local shape = pipeline.build_shape({ refs = { plan = "@plan_v2" } })
        expect(shape.children[1].ref).to.equal("@plan_v2")
        -- Other roles fall back to DEFAULT_REFS
        expect(shape.children[7].ref).to.equal("@finalize")
    end)

    it("honors knobs (plan_max / qgate_pass_token / escalate_blocked_token)", function()
        local shape = pipeline.build_shape({
            plan_max               = 7,
            qgate_pass_token       = "ACCEPT",
            escalate_blocked_token = "STOP",
        })
        -- enhance_loop S2 emits chain([let init, loop])
        local s2 = shape.children[2]
        expect(s2.children[2].max).to.equal(7)
        -- until_token shows up in the loop's not(eq(path, lit)) cond
        expect(s2.children[2].cond.arg.rhs.value).to.equal("ACCEPT")
        -- escalate_gate S6 emits chain([step, route])
        local s6 = shape.children[6]
        local route = s6.children[2]
        expect(route.cond.args[1].rhs.value).to.equal("STOP")
    end)

    it("merge_refs preserves DEFAULT_REFS when no overrides", function()
        local refs = pipeline._for_test.merge_refs(nil)
        for role, default_ref in pairs(pipeline.DEFAULT_REFS) do
            expect(refs[role]).to.equal(default_ref)
        end
    end)
end)

-- ─── inject_decision helper ─────────────────────────────────────────

describe("verdict_swarm_pipeline.inject_decision", function()
    it("writes ctx.human_decision to existing backend entry", function()
        local b = pipeline._for_test.default_backend()
        b.write("t-1", { status = "interrupted", ctx = { x = 1 } })
        pipeline.inject_decision(b, "t-1", { approved = true })
        expect(b.read("t-1").ctx.human_decision.approved).to.equal(true)
        expect(b.read("t-1").ctx.x).to.equal(1)
    end)

    it("errors when task_id has no entry", function()
        local b = pipeline._for_test.default_backend()
        local ok, err = pcall(pipeline.inject_decision, b, "absent", {})
        expect(ok).to.equal(false)
        expect(contains(err, "no entry for task_id")).to.equal(true)
    end)
end)

-- ─── Run 1 fresh halts + Run 2 resume completes ─────────────────────

local function make_dispatch(refs, controller)
    local rev = {}
    for role, ref in pairs(refs) do rev[ref] = role end
    local calls = {}
    local d = function(ref, input)
        local role = rev[ref] or "unknown"
        calls[role] = (calls[role] or 0) + 1
        if role == "plan" then
            return { plan = "plan-body" }
        elseif role == "plan_qgate" then
            local carry = (type(input) == "table") and input or {}
            local n = #carry + 1
            if n >= 2 then return { verdict = "pass", attempt = n } end
            return { verdict = "RETRY", attempt = n, deny = "need detail" }
        elseif role == "panelist" then
            return { vote = input }
        elseif role == "draft" then
            return { body = "draft body" }
        elseif role == "draft_qgate" then
            local carry = (type(input) == "table") and input or {}
            local n = #carry + 1
            if n >= 2 then return { verdict = "pass", attempt = n } end
            return { verdict = "RETRY", attempt = n, deny = "tighten" }
        elseif role == "human_review" then
            if controller.phase == 1 then
                return { verdict = "halt", concern = "needs signoff" }
            end
            return { verdict = "pass", note = "ok" }
        elseif role == "finalize" then
            return { summary = "final summary" }
        end
    end
    return d, calls
end

local function majority_reducer(fan)
    local tally = {}
    for _, e in ipairs(fan or {}) do
        local v = e and e.r and e.r.vote
        if v then tally[v] = (tally[v] or 0) + 1 end
    end
    local winner, top = nil, 0
    for v, c in pairs(tally) do
        if c > top then winner, top = v, c end
    end
    return { winner = winner, tally = tally }
end

describe("verdict_swarm_pipeline.run — Run 1 fresh halts", function()
    it("retries QGates via carry, aggregates panel, halts on human_review", function()
        local controller = { phase = 1 }
        local refs = pipeline.DEFAULT_REFS
        local d, calls = make_dispatch(refs, controller)
        local r = pipeline.run({
            task_id  = "vsp-spec-1",
            dispatch = d,
            externs  = { majority = majority_reducer },
            ctx      = { candidates = { "a", "b", "a" } },
        })
        expect(r.halted).to.equal(true)
        expect(r.completed).to.equal(false)
        expect(calls.plan).to.equal(1)
        expect(calls.plan_qgate).to.equal(2) -- retry-then-pass via carry
        expect(calls.panelist).to.equal(3)
        expect(calls.draft).to.equal(1)
        expect(calls.draft_qgate).to.equal(2)
        expect(calls.human_review).to.equal(1)
        expect(calls.finalize or 0).to.equal(0)
        expect(#r.ctx.plan_carry).to.equal(2)
        expect(r.ctx.plan_carry[1].verdict).to.equal("RETRY")
        expect(r.ctx.consensus.winner).to.equal("a")
        expect(r.ctx.human_review.verdict).to.equal("halt")
        expect(r.result.error.kind).to.equal("escalate_required")
    end)
end)

describe("verdict_swarm_pipeline.run — Run 2 resume completes", function()
    it("short-circuits top-level steps, runs finalize fresh", function()
        local controller = { phase = 1 }
        local refs = pipeline.DEFAULT_REFS
        local d1, _ = make_dispatch(refs, controller)
        local r1 = pipeline.run({
            task_id  = "vsp-spec-2",
            dispatch = d1,
            externs  = { majority = majority_reducer },
            ctx      = { candidates = { "a", "b", "a" } },
        })
        expect(r1.halted).to.equal(true)

        controller.phase = 2
        local d2, calls2 = make_dispatch(refs, controller)
        local r2 = pipeline.run({
            task_id       = "vsp-spec-2",
            dispatch      = d2,
            externs       = { majority = majority_reducer },
            state_backend = r1.state_backend,
            ctx           = { candidates = { "a", "b", "a" } },
            decision      = { approved = true },
        })
        expect(r2.completed).to.equal(true)
        expect(r2.halted).to.equal(false)
        expect(calls2.plan or 0).to.equal(0)
        expect(calls2.plan_qgate or 0).to.equal(0)
        expect(calls2.draft or 0).to.equal(0)
        expect(calls2.draft_qgate or 0).to.equal(0)
        expect(calls2.human_review or 0).to.equal(0)
        -- panelist fan branches re-dispatch (β fix limit)
        expect(calls2.panelist).to.equal(3)
        expect(calls2.finalize).to.equal(1)
        expect(r2.ctx.human_decision.approved).to.equal(true)
        expect(r2.ctx.final.summary).to.equal("final summary")
    end)
end)

-- ─── wrap_dispatch_with_offload ─────────────────────────────────────

describe("verdict_swarm_pipeline.wrap_dispatch_with_offload", function()
    -- minimal in-memory artifact backend (4-method iface).
    local function memory_backend()
        local store = {}
        local b = {}
        function b:write(id, payload, _opts) store[id] = payload; return true end
        function b:read(id) return store[id] end
        function b:exists(id) return store[id] ~= nil end
        function b:delete(id) store[id] = nil; return true end
        b.store = store
        return b
    end

    it("offloads body when length >= threshold, replaces with ref", function()
        local backend = memory_backend()
        local inner = function() return { body = string.rep("x", 200) } end
        local wrapped = pipeline.wrap_dispatch_with_offload(inner, backend,
            { fields = { "body" }, threshold = 100 })
        local r = wrapped("@draft", nil)
        expect(r.body).to.equal(nil)
        expect(r.body_ref.kind).to.equal("artifact_ref")
        expect(r.body_ref.size).to.equal(200)
        -- backend has the offloaded value
        expect(backend:read(r.body_ref.artifact_id)).to.equal(string.rep("x", 200))
    end)

    it("leaves body intact when length < threshold", function()
        local backend = memory_backend()
        local inner = function() return { body = "short" } end
        local wrapped = pipeline.wrap_dispatch_with_offload(inner, backend,
            { fields = { "body" }, threshold = 100 })
        local r = wrapped("@draft", nil)
        expect(r.body).to.equal("short")
        expect(r.body_ref).to.equal(nil)
    end)

    it("honors multiple fields", function()
        local backend = memory_backend()
        local inner = function()
            return {
                body   = string.rep("a", 200),
                report = string.rep("b", 200),
                tag    = "small",
            }
        end
        local wrapped = pipeline.wrap_dispatch_with_offload(inner, backend,
            { fields = { "body", "report" }, threshold = 100 })
        local r = wrapped("@draft", nil)
        expect(r.body).to.equal(nil)
        expect(r.report).to.equal(nil)
        expect(r.body_ref.size).to.equal(200)
        expect(r.report_ref.size).to.equal(200)
        expect(r.tag).to.equal("small") -- non-offload field preserved
    end)

    it("preserves non-table inner result (e.g. nil)", function()
        local backend = memory_backend()
        local inner = function() return nil end
        local wrapped = pipeline.wrap_dispatch_with_offload(inner, backend, {})
        expect(wrapped("@x", nil)).to.equal(nil)
    end)

    it("rejects non-function inner / invalid backend", function()
        expect(pcall(pipeline.wrap_dispatch_with_offload, "not-fn", {})).to.equal(false)
        expect(pcall(pipeline.wrap_dispatch_with_offload, function() end, {})).to.equal(false)
        expect(pcall(pipeline.wrap_dispatch_with_offload, function() end, "not-backend")).to.equal(false)
    end)
end)

-- ─── ref override is honored during run ─────────────────────────────

describe("verdict_swarm_pipeline.run — refs override during run", function()
    it("dispatches @plan_v2 when refs={plan='@plan_v2'}", function()
        local controller = { phase = 1 }
        -- caller dispatch needs the OVERRIDE refs (merged) to route
        local merged = { plan = "@plan_v2" }
        for k, v in pairs(pipeline.DEFAULT_REFS) do
            if merged[k] == nil then merged[k] = v end
        end
        local d, calls = make_dispatch(merged, controller)
        local r = pipeline.run({
            task_id  = "vsp-spec-3",
            dispatch = d,
            externs  = { majority = majority_reducer },
            refs     = { plan = "@plan_v2" },
            ctx      = { candidates = { "a" } },
        })
        expect(calls.plan).to.equal(1) -- routed via reverse-map of @plan_v2
        expect(r.halted).to.equal(true)
    end)
end)
