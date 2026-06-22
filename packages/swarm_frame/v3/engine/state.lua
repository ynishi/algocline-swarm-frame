---@module 'swarm_frame.v3.engine.state'
-- State semantics built-in (V3 §4.1.3 + §5.6.2 R5 land 5 軸).
--
-- Thin wrappers on flow.FlowState-equivalent ctx mutation. The five
-- axes captured here (status 5 値 / exists-based resume 判定 / status
-- × opts 分岐 / ctx._progress 構造 / wrapped_dispatch logic) are
-- engine-internal — host adapters supply only persistence backends
-- via /contract/state_backend_iface.

local path_mod = require("flow.ir.path")

local M = {}
M.VERSION = "0.0.2-v3-p9"

-- ─── status 5 値 (R5 land 軸 1) ─────────────────────────────────────

M.STATUS = {
    NOT_STARTED = "not_started",
    IN_PROGRESS = "in_progress",
    COMPLETED   = "completed",
    FAILED      = "failed",
    INTERRUPTED = "interrupted",
}

-- ─── task_id auto-gen ───────────────────────────────────────────────

local function gen_task_id()
    -- "task-" + 8 hex chars derived from os.time + math.random
    local seed = (os.time() * 1000 + math.random(0, 999999)) % 0xFFFFFFFF
    return string.format("task-%08x", seed)
end

-- ─── resolve(state_backend, state_opts) -> Resolution ───────────────
--
-- Resolution: { task_id, mode, ctx, prev_result?, error? }
--   mode ∈ "fresh" | "cached_return" | "resume" | "error"
--
-- Implements R5 land 軸 2 (exists-based resume 判定) + 軸 3 (status ×
-- opts による start path 分岐表、 V3 §6.2.2).

function M.resolve(state_backend, state_opts)
    state_opts = state_opts or {}
    local task_id        = state_opts.task_id or gen_task_id()
    local force_fresh    = state_opts.force_fresh
    local force_continue = state_opts.force_continue

    local function has_backend()
        return state_backend ~= nil
               and type(state_backend.exists) == "function"
    end

    -- force_fresh: delete existing + fresh start
    if force_fresh then
        if has_backend() and state_backend.exists(task_id)
           and type(state_backend.delete) == "function" then
            state_backend.delete(task_id)
        end
        return {
            task_id = task_id,
            mode    = "fresh",
            ctx     = { _progress = {} },
        }
    end

    if not has_backend() or not state_backend.exists(task_id) then
        return {
            task_id = task_id,
            mode    = "fresh",
            ctx     = { _progress = {} },
        }
    end

    if type(state_backend.read) ~= "function" then
        return {
            task_id = task_id,
            mode    = "fresh",
            ctx     = { _progress = {} },
        }
    end

    local prev = state_backend.read(task_id)
    if type(prev) ~= "table" then
        return {
            task_id = task_id,
            mode    = "fresh",
            ctx     = { _progress = {} },
        }
    end

    local status = prev.status or M.STATUS.NOT_STARTED
    local ctx    = prev.ctx or {}
    if type(ctx._progress) ~= "table" then ctx._progress = {} end

    -- §6.2.2 status × opts 分岐表
    if status == M.STATUS.COMPLETED then
        return {
            task_id     = task_id,
            mode        = "cached_return",
            ctx         = ctx,
            prev_result = prev.result,
        }
    end
    if status == M.STATUS.INTERRUPTED then
        return { task_id = task_id, mode = "resume", ctx = ctx }
    end
    if status == M.STATUS.FAILED then
        if force_continue then
            return { task_id = task_id, mode = "resume", ctx = ctx }
        end
        return {
            task_id = task_id,
            mode    = "error",
            error   = {
                kind    = "failed_resume_unsupported",
                message = "failed task requires force_continue=true",
            },
        }
    end
    -- IN_PROGRESS = leftover from a previous crashed run, treat as resume
    if status == M.STATUS.IN_PROGRESS then
        return { task_id = task_id, mode = "resume", ctx = ctx }
    end
    return { task_id = task_id, mode = "fresh", ctx = ctx }
end

-- ─── ctx._progress thin wrappers (R5 land 軸 4) ─────────────────────

local function ensure_progress(ctx)
    if type(ctx._progress) ~= "table" then ctx._progress = {} end
end

--- step_mark(ctx, step_id) — record step start.
function M.step_mark(ctx, step_id)
    ensure_progress(ctx)
    ctx._progress[step_id] = { status = "in_progress" }
end

--- step_done(ctx, step_id, at_path?) — record step completion + output ref.
function M.step_done(ctx, step_id, at_path)
    ensure_progress(ctx)
    ctx._progress[step_id] = { status = "done", at = at_path }
end

--- gate_decide(ctx, gate_id, verdict) — record gate verdict.
function M.gate_decide(ctx, gate_id, verdict)
    ensure_progress(ctx)
    ctx._progress[gate_id] = { status = "gate", verdict = verdict }
end

-- ─── wrapped_dispatch logic (R5 land 軸 5) ──────────────────────────
--
-- Wrap a dispatcher so that step_ids already marked status="done" in
-- ctx._progress short-circuit to a cached lookup at the recorded
-- output path. Fresh dispatches mark the step in-progress and let the
-- downstream layers update progress on completion (handled by the
-- checkpoint plugin).

-- lookup_at_path: resolve an at-path against `ctx`.
--
-- Accepts BOTH conventions:
--   • flow.ir.path form: "ctx.last" / "ctx.items[3]" — first segment "ctx"
--     is the write_path root token and is stripped before walking.
--   • ctx-relative form (legacy): "last" / "scout" — walked literally
--     from `ctx`. Preserves existing callers that wrote at-paths without
--     the "ctx." prefix.
--
-- Integer bracket indices ([N]) are supported via path_mod.parse.
local function lookup_at_path(ctx, at_path)
    if type(at_path) ~= "string" or at_path == "" then return nil end
    local parts = path_mod.parse(at_path)
    if type(parts) ~= "table" or #parts == 0 then return nil end
    local start_idx = 1
    if parts[1] == "ctx" then start_idx = 2 end
    local node = ctx
    for i = start_idx, #parts do
        if type(node) ~= "table" then return nil end
        node = node[parts[i]]
    end
    return node
end

-- wrap_dispatch_with_progress(dispatch, ctx, step_out_map?, resumed_done?)
--
-- Bi-directional wrapper:
--   1. PRE  short-circuit:
--      • If `resumed_done` is provided (recommended path), short-circuit
--        only on entries snapshotted from a PRIOR run's _progress at the
--        start of this run. The lookup is one-shot: a successful
--        short-circuit clears the entry, so a loop or repeated step
--        re-dispatches on subsequent invocations. This isolates resume
--        semantics from in-run loop iterations.
--      • If `resumed_done` is nil (legacy path, kept for direct callers),
--        fall back to checking ctx._progress[step_id] directly with no
--        one-shot consume. Loops with the same step ref will short-circuit
--        on iter 2+ if iter 1 wrote _progress — caller's responsibility.
--   2. POST auto-write:
--      • After a fresh dispatch, if step_out_map contains an entry for
--        step_id, auto-write ctx._progress[step_id] = {status="done",
--        at=<out_path>}. This makes future-run resume idempotent — the
--        next runtime.run() will populate its own resumed_done from this
--        snapshot. Loops are safe because the snapshot is captured at run
--        start, not consulted live.
--
-- step_out_map / resumed_done are both optional (backward compat).
function M.wrap_dispatch_with_progress(dispatch, ctx, step_out_map, resumed_done)
    if type(dispatch) ~= "function" then
        error("state.wrap_dispatch_with_progress: dispatch must be a function", 2)
    end
    return function(ref, input, dispatch_ctx)
        local step_id = (type(dispatch_ctx) == "table" and dispatch_ctx.step_id)
                        or ref
        local at_path = nil
        if type(resumed_done) == "table" then
            -- new strict mode: prior-run entry, one-shot consume
            at_path = resumed_done[step_id]
            if at_path then resumed_done[step_id] = nil end
        else
            -- legacy mode: live ctx._progress lookup
            local prog = ctx._progress and ctx._progress[step_id]
            if prog and prog.status == "done" then at_path = prog.at end
        end
        if at_path then
            local cached = lookup_at_path(ctx, at_path)
            if cached ~= nil then return cached end
            -- fall through to fresh dispatch if cached value missing
        end
        local result = dispatch(ref, input, dispatch_ctx)
        if type(step_out_map) == "table" then
            local out_path = step_out_map[step_id]
            if type(out_path) == "string" and out_path ~= "" then
                ensure_progress(ctx)
                ctx._progress[step_id] = { status = "done", at = out_path }
            end
        end
        return result
    end
end

-- ─── checkpoint plugin factory (V3 §6.2.5) ──────────────────────────
--
-- swarm_frame core 同梱の強制注入 plugin。 every dispatch 後に
-- state_backend.write(task_id, snapshot) を 1 回叩く (granularity=step
-- default)。 finalize 時に最終 status を write して終端。
--
-- granularity ∈ "step" (default) | "phase" | "manual"
--   "step"   = after each step
--   "phase"  = (V1 carry: not yet wired, treated as step)
--   "manual" = no auto-write, caller responsibility

function M.make_checkpoint_plugin(state_backend, task_id, granularity)
    granularity = granularity or "step"
    local has_write = type(state_backend) == "table"
                      and type(state_backend.write) == "function"

    return {
        name = "checkpoint",
        after = function(_ref, _input, ctx, _response)
            if not has_write then return end
            if granularity == "manual" then return end
            state_backend.write(task_id, {
                status = M.STATUS.IN_PROGRESS,
                ctx    = ctx,
                ts     = os.time(),
            })
        end,
        finalize = function(result)
            if not has_write then return end
            local final_status
            local err_kind = result.error and result.error.kind
            if result.status == "ok" then
                final_status = M.STATUS.COMPLETED
            elseif err_kind == "safeguard_breach"
                   or err_kind == "escalate_required" then
                final_status = M.STATUS.INTERRUPTED
            else
                final_status = M.STATUS.FAILED
            end
            state_backend.write(task_id, {
                status = final_status,
                ctx    = result.ctx,
                result = result,
                ts     = os.time(),
            })
        end,
    }
end

return M
