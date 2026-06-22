-- v3_state_spec.lua — State semantics built-in (R5 land 5 軸) and
-- checkpoint plugin behavior. Per workspace-pipeline.md §Frame/orch
-- 改修後 checklist: boundary regression spec for state_mod.* and
-- runtime.run() integration with state_backend.

local lust  = require("lust")
local swarm = require("swarm_frame.v3")
local state = swarm.engine.state
local describe, it, expect = lust.describe, lust.it, lust.expect

-- ─── mock state_backend (in-memory) ─────────────────────────────────

local function make_backend()
    local store = {}
    local calls = { exists = 0, read = 0, write = 0, delete = 0 }
    return {
        store  = store,
        calls  = calls,
        exists = function(id) calls.exists = calls.exists + 1; return store[id] ~= nil end,
        read   = function(id) calls.read   = calls.read   + 1; return store[id] end,
        write  = function(id, snap) calls.write = calls.write + 1; store[id] = snap end,
        delete = function(id) calls.delete = calls.delete + 1; store[id] = nil end,
    }
end

-- ─── 軸 1: status 5 値 ──────────────────────────────────────────────

describe("swarm.v3.engine.state STATUS (R5 land 軸 1)", function()
    it("exposes 5 status constants", function()
        expect(state.STATUS.NOT_STARTED).to.equal("not_started")
        expect(state.STATUS.IN_PROGRESS).to.equal("in_progress")
        expect(state.STATUS.COMPLETED).to.equal("completed")
        expect(state.STATUS.FAILED).to.equal("failed")
        expect(state.STATUS.INTERRUPTED).to.equal("interrupted")
    end)

    it("re-exports STATUS through swarm.v3 surface", function()
        expect(swarm.STATUS.COMPLETED).to.equal("completed")
    end)
end)

-- ─── 軸 2: resume 判定 (exists-based) ───────────────────────────────

describe("swarm.v3.engine.state.resolve (R5 land 軸 2)", function()
    it("auto-generates task_id when omitted", function()
        local r = state.resolve(nil, nil)
        expect(r.task_id).to.exist()
        expect(type(r.task_id)).to.equal("string")
        expect(r.mode).to.equal("fresh")
    end)

    it("uses caller-provided task_id verbatim", function()
        local r = state.resolve(nil, { task_id = "t-fixed" })
        expect(r.task_id).to.equal("t-fixed")
    end)

    it("returns fresh mode when state_backend is nil", function()
        local r = state.resolve(nil, { task_id = "t-1" })
        expect(r.mode).to.equal("fresh")
        expect(r.ctx._progress).to.exist()
    end)

    it("returns fresh mode when task_id does not exist in backend", function()
        local b = make_backend()
        local r = state.resolve(b, { task_id = "t-new" })
        expect(r.mode).to.equal("fresh")
        expect(b.calls.exists).to.equal(1)
    end)

    it("returns resume mode for interrupted task", function()
        local b = make_backend()
        b.store["t-int"] = { status = "interrupted", ctx = { foo = 1, _progress = { s1 = { status = "done", at = "ctx.x" } } } }
        local r = state.resolve(b, { task_id = "t-int" })
        expect(r.mode).to.equal("resume")
        expect(r.ctx.foo).to.equal(1)
        expect(r.ctx._progress.s1.status).to.equal("done")
    end)

    it("returns resume mode for in_progress task (crashed leftover)", function()
        local b = make_backend()
        b.store["t-ip"] = { status = "in_progress", ctx = {} }
        local r = state.resolve(b, { task_id = "t-ip" })
        expect(r.mode).to.equal("resume")
    end)
end)

-- ─── 軸 3: status × opts による start path 分岐 ─────────────────────

describe("swarm.v3.engine.state.resolve start path 分岐 (R5 land 軸 3)", function()
    it("returns cached_return for completed task", function()
        local b = make_backend()
        b.store["t-done"] = {
            status = "completed",
            ctx = { _progress = {} },
            result = { status = "ok", task_id = "t-done" },
        }
        local r = state.resolve(b, { task_id = "t-done" })
        expect(r.mode).to.equal("cached_return")
        expect(r.prev_result.status).to.equal("ok")
    end)

    it("returns error for failed task without force_continue", function()
        local b = make_backend()
        b.store["t-fail"] = { status = "failed", ctx = {} }
        local r = state.resolve(b, { task_id = "t-fail" })
        expect(r.mode).to.equal("error")
        expect(r.error.kind).to.equal("failed_resume_unsupported")
    end)

    it("returns resume for failed task when force_continue=true", function()
        local b = make_backend()
        b.store["t-fail"] = { status = "failed", ctx = {} }
        local r = state.resolve(b, { task_id = "t-fail", force_continue = true })
        expect(r.mode).to.equal("resume")
    end)

    it("returns fresh + deletes existing when force_fresh=true", function()
        local b = make_backend()
        b.store["t-old"] = { status = "completed", ctx = { foo = 1 } }
        local r = state.resolve(b, { task_id = "t-old", force_fresh = true })
        expect(r.mode).to.equal("fresh")
        expect(b.calls.delete).to.equal(1)
        expect(b.store["t-old"]).to.equal(nil)
        expect(r.ctx._progress).to.exist()
    end)

    it("force_fresh on non-existing task does not call delete", function()
        local b = make_backend()
        local r = state.resolve(b, { task_id = "t-new", force_fresh = true })
        expect(r.mode).to.equal("fresh")
        expect(b.calls.delete).to.equal(0)
    end)
end)

-- ─── 軸 4: ctx._progress 構造 + thin wrappers ───────────────────────

describe("swarm.v3.engine.state ctx._progress thin wrappers (R5 land 軸 4)", function()
    it("step_mark sets in_progress status", function()
        local ctx = {}
        state.step_mark(ctx, "s_1")
        expect(ctx._progress.s_1.status).to.equal("in_progress")
    end)

    it("step_done sets done status with at path", function()
        local ctx = {}
        state.step_done(ctx, "s_1", "ctx.scout")
        expect(ctx._progress.s_1.status).to.equal("done")
        expect(ctx._progress.s_1.at).to.equal("ctx.scout")
    end)

    it("gate_decide records verdict", function()
        local ctx = {}
        state.gate_decide(ctx, "g_review", "GO")
        expect(ctx._progress.g_review.status).to.equal("gate")
        expect(ctx._progress.g_review.verdict).to.equal("GO")
    end)

    it("auto-initializes ctx._progress when absent", function()
        local ctx = {}
        state.step_mark(ctx, "s_1")
        expect(type(ctx._progress)).to.equal("table")
    end)
end)

-- ─── 軸 5: wrap_dispatch_with_progress ──────────────────────────────

describe("swarm.v3.engine.state.wrap_dispatch_with_progress (R5 land 軸 5)", function()
    it("calls real dispatch when no prior progress for step_id", function()
        local hits = 0
        local d = function(ref) hits = hits + 1; return { ref = ref } end
        local ctx = { _progress = {} }
        local w = state.wrap_dispatch_with_progress(d, ctx)
        local r = w("@a", nil, { step_id = "s_1" })
        expect(hits).to.equal(1)
        expect(r.ref).to.equal("@a")
    end)

    it("short-circuits to cached value when step is done", function()
        local hits = 0
        local d = function() hits = hits + 1; return "real" end
        local ctx = {
            scout = "cached_value",
            _progress = { s_scout = { status = "done", at = "scout" } },
        }
        local w = state.wrap_dispatch_with_progress(d, ctx)
        local r = w("@scout", nil, { step_id = "s_scout" })
        expect(hits).to.equal(0)
        expect(r).to.equal("cached_value")
    end)

    it("falls through to dispatch when cached value missing", function()
        local hits = 0
        local d = function() hits = hits + 1; return "real" end
        local ctx = {
            _progress = { s_x = { status = "done", at = "missing.path" } },
        }
        local w = state.wrap_dispatch_with_progress(d, ctx)
        local r = w("@x", nil, { step_id = "s_x" })
        expect(hits).to.equal(1)
        expect(r).to.equal("real")
    end)

    it("uses ref as step_id when dispatch_ctx is absent", function()
        local ctx = {
            cached_ref = "v",
            _progress  = { ["@x"] = { status = "done", at = "cached_ref" } },
        }
        local d = function() return "fresh" end
        local w = state.wrap_dispatch_with_progress(d, ctx)
        expect(w("@x")).to.equal("v")
    end)

    it("raises on non-function dispatch", function()
        local ok = pcall(state.wrap_dispatch_with_progress, nil, {})
        expect(ok).to.equal(false)
    end)

    -- ─── β land: flow.ir.path 互換 at-path ──────────────────────────
    it("resolves at-path with 'ctx.' prefix (flow.ir.path form)", function()
        local hits = 0
        local d = function() hits = hits + 1; return "fresh" end
        local ctx = {
            last = "cached_via_ctx_prefix",
            _progress = { ["@gate"] = { status = "done", at = "ctx.last" } },
        }
        local w = state.wrap_dispatch_with_progress(d, ctx)
        local r = w("@gate")
        expect(hits).to.equal(0)
        expect(r).to.equal("cached_via_ctx_prefix")
    end)

    it("resolves at-path with bracket index segments", function()
        local ctx = {
            items = { "first", "second", "third" },
            _progress = { ["@idx"] = { status = "done", at = "ctx.items[2]" } },
        }
        local d = function() return "fresh" end
        local w = state.wrap_dispatch_with_progress(d, ctx)
        expect(w("@idx")).to.equal("second")
    end)

    -- ─── β land: auto step_done POST hook ───────────────────────────
    it("auto-writes _progress on dispatch when step_out_map provided", function()
        local d = function() return { verdict = "pass" } end
        local ctx = { _progress = {} }
        local step_out_map = { ["@gate"] = "ctx.last" }
        local w = state.wrap_dispatch_with_progress(d, ctx, step_out_map)
        w("@gate", nil)
        expect(ctx._progress["@gate"]).to.exist()
        expect(ctx._progress["@gate"].status).to.equal("done")
        expect(ctx._progress["@gate"].at).to.equal("ctx.last")
    end)

    it("does not auto-write _progress when step_out_map omitted (backward compat)", function()
        local d = function() return { verdict = "pass" } end
        local ctx = { _progress = {} }
        local w = state.wrap_dispatch_with_progress(d, ctx)
        w("@gate", nil)
        expect(ctx._progress["@gate"]).to.equal(nil)
    end)

    it("does not auto-write when step_out_map has no entry for step_id", function()
        local d = function() return "x" end
        local ctx = { _progress = {} }
        local w = state.wrap_dispatch_with_progress(d, ctx, { ["@other"] = "ctx.other" })
        w("@gate")
        expect(ctx._progress["@gate"]).to.equal(nil)
    end)
end)

-- ─── checkpoint plugin (V3 §6.2.5 強制注入) ─────────────────────────

describe("swarm.v3.engine.state.make_checkpoint_plugin", function()
    it("writes IN_PROGRESS snapshot on each after-step", function()
        local b = make_backend()
        local cp = state.make_checkpoint_plugin(b, "t-cp", "step")
        cp.after("@a", nil, { foo = 1 }, "resp")
        expect(b.calls.write).to.equal(1)
        expect(b.store["t-cp"].status).to.equal("in_progress")
        expect(b.store["t-cp"].ctx.foo).to.equal(1)
    end)

    it("skips after-write when granularity=manual", function()
        local b = make_backend()
        local cp = state.make_checkpoint_plugin(b, "t-m", "manual")
        cp.after("@a", nil, {}, "resp")
        expect(b.calls.write).to.equal(0)
    end)

    it("writes COMPLETED on finalize when result.status=ok", function()
        local b = make_backend()
        local cp = state.make_checkpoint_plugin(b, "t-ok", "step")
        local out = cp.finalize({ status = "ok", ctx = { y = 9 } })
        expect(out).to.equal(nil)
        expect(b.store["t-ok"].status).to.equal("completed")
        expect(b.store["t-ok"].ctx.y).to.equal(9)
    end)

    it("writes INTERRUPTED on finalize when error.kind=safeguard_breach", function()
        local b = make_backend()
        local cp = state.make_checkpoint_plugin(b, "t-i", "step")
        cp.finalize({
            status = "error",
            error  = { kind = "safeguard_breach", message = "..." },
            ctx    = {},
        })
        expect(b.store["t-i"].status).to.equal("interrupted")
    end)

    it("writes FAILED on finalize for generic exec_fail", function()
        local b = make_backend()
        local cp = state.make_checkpoint_plugin(b, "t-f", "step")
        cp.finalize({
            status = "error",
            error  = { kind = "exec_fail", message = "boom" },
            ctx    = {},
        })
        expect(b.store["t-f"].status).to.equal("failed")
    end)

    it("noop when state_backend is nil", function()
        local cp = state.make_checkpoint_plugin(nil, "t-x", "step")
        local ok1 = pcall(cp.after, "@a", nil, {}, nil)
        local ok2 = pcall(cp.finalize, { status = "ok", ctx = {} })
        expect(ok1).to.equal(true)
        expect(ok2).to.equal(true)
    end)
end)

-- ─── runtime.run() integration with state_backend ───────────────────

describe("swarm.v3 runtime.run with state_backend", function()
    it("emits task_id in result and writes COMPLETED on success", function()
        local b = make_backend()
        local shape = swarm.let("ctx.x", swarm.lit(42))
        local r = swarm.run({
            shape         = shape,
            dispatch      = function() return nil end,
            state_backend = b,
            state         = { task_id = "t-int-1" },
        })
        expect(r.status).to.equal("ok")
        expect(r.task_id).to.equal("t-int-1")
        expect(b.store["t-int-1"].status).to.equal("completed")
    end)

    it("returns cached_return when prior task is completed", function()
        local b = make_backend()
        b.store["t-cached"] = {
            status = "completed",
            ctx    = { existing = "prev_ctx" },
            result = { status = "ok" },
        }
        local shape = swarm.let("ctx.never_runs", swarm.lit(1))
        local r = swarm.run({
            shape         = shape,
            dispatch      = function() return nil end,
            state_backend = b,
            state         = { task_id = "t-cached" },
        })
        expect(r.status).to.equal("ok")
        expect(r.task_id).to.equal("t-cached")
        expect(r.ctx.existing).to.equal("prev_ctx")
        expect(r.ctx.never_runs).to.equal(nil)
    end)

    it("returns error for failed task without force_continue", function()
        local b = make_backend()
        b.store["t-failed"] = { status = "failed", ctx = {} }
        local shape = swarm.let("ctx.x", swarm.lit(1))
        local r = swarm.run({
            shape         = shape,
            dispatch      = function() return nil end,
            state_backend = b,
            state         = { task_id = "t-failed" },
        })
        expect(r.status).to.equal("error")
        expect(r.error.kind).to.equal("failed_resume_unsupported")
    end)

    it("force_fresh deletes existing state before exec", function()
        local b = make_backend()
        b.store["t-fresh"] = {
            status = "completed",
            ctx    = { stale = true },
            result = { status = "ok" },
        }
        local shape = swarm.let("ctx.fresh_value", swarm.lit("new"))
        local r = swarm.run({
            shape         = shape,
            dispatch      = function() return nil end,
            state_backend = b,
            state         = { task_id = "t-fresh", force_fresh = true },
        })
        expect(r.status).to.equal("ok")
        expect(r.ctx.fresh_value).to.equal("new")
        expect(r.ctx.stale).to.equal(nil)
        expect(b.store["t-fresh"].status).to.equal("completed")
    end)

    it("writes FAILED on compile error", function()
        local b = make_backend()
        -- malformed shape: nil node into chain
        local bad_shape = { kind = "unknown_kind" }
        local r = swarm.run({
            shape         = bad_shape,
            dispatch      = function() return nil end,
            state_backend = b,
            state         = { task_id = "t-bad" },
        })
        expect(r.status).to.equal("error")
        expect(b.store["t-bad"].status).to.equal("failed")
    end)

    it("auto-generates task_id when omitted", function()
        local b = make_backend()
        local shape = swarm.let("ctx.y", swarm.lit(1))
        local r = swarm.run({
            shape         = shape,
            dispatch      = function() return nil end,
            state_backend = b,
        })
        expect(r.task_id).to.exist()
        expect(b.store[r.task_id]).to.exist()
    end)

    it("works without state_backend (backward compat)", function()
        local shape = swarm.let("ctx.z", swarm.lit(7))
        local r = swarm.run({
            shape    = shape,
            dispatch = function() return nil end,
        })
        expect(r.status).to.equal("ok")
        expect(r.ctx.z).to.equal(7)
        expect(r.task_id).to.exist()
    end)
end)

-- ─── escalate_required → INTERRUPTED (P9 escalate_gate land) ─────────

describe("swarm.v3 runtime.run escalate path (P9 land)", function()
    it("maps __escalate__ raise to error.kind=escalate_required", function()
        local shape = swarm.let("ctx._void",
            swarm.ext("__escalate__", { swarm.lit({}) }))
        local r = swarm.run({
            shape    = shape,
            dispatch = function() return nil end,
        })
        expect(r.status).to.equal("error")
        expect(r.error.kind).to.equal("escalate_required")
        expect(r.error.message:find("escalate:")).to.exist()
    end)

    it("writes STATUS.INTERRUPTED on escalate_required", function()
        local b = make_backend()
        local shape = swarm.let("ctx._void",
            swarm.ext("__escalate__", { swarm.lit({}) }))
        local r = swarm.run({
            shape         = shape,
            dispatch      = function() return nil end,
            state_backend = b,
            state         = { task_id = "t-esc" },
        })
        expect(r.status).to.equal("error")
        expect(r.error.kind).to.equal("escalate_required")
        expect(b.store["t-esc"].status).to.equal("interrupted")
    end)

    it("resolves INTERRUPTED state to resume mode (escalate carry)", function()
        local b = make_backend()
        b.store["t-esc-resume"] = {
            status = "interrupted",
            ctx    = {
                last = { verdict = "blocked", body = "halted output" },
                _progress = { ["@gate"] = { status = "done", at = "ctx.last" } },
            },
        }
        local r = state.resolve(b, { task_id = "t-esc-resume" })
        expect(r.mode).to.equal("resume")
        expect(r.ctx.last.verdict).to.equal("blocked")
    end)

    it("caller-supplied __escalate__ overrides the built-in", function()
        local seen
        local shape = swarm.let("ctx._void",
            swarm.ext("__escalate__", { swarm.lit("payload") }))
        local r = swarm.run({
            shape    = shape,
            dispatch = function() return nil end,
            externs  = {
                __escalate__ = function(p) seen = p; return "noop" end,
            },
        })
        expect(r.status).to.equal("ok")
        expect(seen).to.equal("payload")
    end)
end)
