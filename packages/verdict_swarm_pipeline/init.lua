--- verdict_swarm_pipeline — reusable verdict-driven Swarm pipeline.
---
--- A 7-step verdict-driven pipeline scaffold suitable for "実務型"
--- (linear + Gate + Retry + HIL/escalate) swarms. Unlike a demo, this
--- pkg keeps **zero domain knowledge** — prompts, role dispatch logic,
--- reducer externs, and per-role agent refs are all caller-injected.
---
--- Pipeline shape (fixed 7 step, configurable knobs):
---
---   S1: @plan                                       (linear step)
---   S2: enhance_loop(@plan_qgate)                   (QGate + fix_carry)
---   S3: aggregate(@panelist, items, reducer)        (fan-out + reduce)
---   S4: @draft                                      (linear step)
---   S5: enhance_loop(@draft_qgate)                  (QGate + fix_carry)
---   S6: escalate_gate(@human_review)                (HIL halt → resume)
---   S7: @finalize                                   (linear step)
---
--- Caller responsibilities (inject in opts):
---
---   - `dispatch` (REQUIRED): `function(ref, input) -> response`. The
---     caller routes by ref (or by reverse-mapped role) and constructs
---     prompts however they like. The pkg never touches prompt strings.
---   - `externs` (REQUIRED iff S3 reducer is used): table mapping
---     reducer name to a pure function (e.g. {majority = fn}).
---   - `refs` (optional): per-role agent ref override map. Defaults to
---     DEFAULT_REFS. Lets callers A/B-test agents by string swap, version
---     prompts via separate ref ids (= T2 Versioning seam), or wire the
---     same role to different host adapters.
---   - `candidates` (REQUIRED iff aggregate is exercised): list of items
---     written to ctx.candidates before run.
---   - `task_id` (REQUIRED): identifies the run for state persistence
---     and resume.
---   - `state_backend` (optional): default = fresh in-memory backend.
---     Pass a persisted backend (e.g. swarm_host_alc.state_backend.file)
---     to enable resume across processes.
---   - `decision` (optional): when present, injected as
---     ctx.human_decision BEFORE the run — used on resume after an
---     escalate halt to let the gate skip the escalate branch.
---   - knobs (optional): `plan_max` / `draft_max` (default 3 each),
---     `qgate_pass_token` (default "pass"),
---     `escalate_blocked_token` (default "halt"),
---     `reducer` (S3 reducer name, default "majority").
---
--- M.build_shape(opts) returns the IR Node without invoking swarm.run —
--- useful for callers who want to compose this pipeline into a larger
--- shape, or who want to attach plugins / observers / safeguard options.
---
--- Status: v0.1.0 — minimal reusable form. Domain still fluid; expect
--- iteration on shape / opt names. composite re-use only; the pkg does
--- not introduce new IR nodes (V3 §5.8 規律).

local swarm = require("swarm_frame.v3")
local C     = swarm.composite

local M = {}
M.VERSION = "0.1.0"

M.meta = {
    name        = "verdict_swarm_pipeline",
    version     = "0.1.0",
    category    = "swarm_pipeline",
    description = "Reusable verdict-driven 7-step Swarm pipeline: "
        .. "plan → QGate (enhance_loop) → aggregate → draft → QGate → "
        .. "escalate_gate(HIL) → finalize. Caller injects dispatch, "
        .. "prompts, refs, externs.",
}

-- ─── per-role default agent refs (caller may override) ─────────────

M.DEFAULT_REFS = {
    plan         = "@plan",
    plan_qgate   = "@plan_qgate",
    panelist     = "@panelist",
    draft        = "@draft",
    draft_qgate  = "@draft_qgate",
    human_review = "@human_review",
    finalize     = "@finalize",
}

-- ─── default in-memory state_backend (caller may override) ─────────

local function default_backend()
    local store = {}
    return {
        store  = store,
        exists = function(id) return store[id] ~= nil end,
        read   = function(id) return store[id] end,
        write  = function(id, snap) store[id] = snap end,
        delete = function(id) store[id] = nil end,
    }
end

-- ─── validation helpers ────────────────────────────────────────────

local function require_string(v, name, fn)
    if type(v) ~= "string" or v == "" then
        error("verdict_swarm_pipeline." .. fn .. ": " .. name
            .. " (non-empty string) required, got " .. type(v), 3)
    end
end

local function merge_refs(overrides)
    local out = {}
    for k, v in pairs(M.DEFAULT_REFS) do out[k] = v end
    if type(overrides) == "table" then
        for k, v in pairs(overrides) do out[k] = v end
    end
    return out
end

-- ─── decision injection (resume helper, exposed for callers) ───────

function M.inject_decision(state_backend, task_id, decision)
    if not state_backend.exists(task_id) then
        error(string.format(
            "verdict_swarm_pipeline.inject_decision: state_backend "
            .. "has no entry for task_id=%q", task_id), 2)
    end
    local prev = state_backend.read(task_id)
    prev.ctx = prev.ctx or {}
    prev.ctx.human_decision = decision
    state_backend.write(task_id, prev)
end

--- M.build_shape(opts) -> IR Node
---
--- @param opts {
---   refs                   : table?,    -- per-role ref overrides
---   plan_max               : integer?,  -- enhance_loop S2 max (default 3)
---   draft_max              : integer?,  -- enhance_loop S5 max (default 3)
---   qgate_pass_token       : string?,   -- enhance_loop until_token (default "pass")
---   escalate_blocked_token : string?,   -- escalate_gate blocked_token (default "halt")
---   reducer                : string?,   -- aggregate reducer name (default "majority")
---   items_path             : string?,   -- aggregate items source (default "$.ctx.candidates")
--- }
--- @return IR Node (chain of 7)
function M.build_shape(opts)
    opts = opts or {}
    local refs = merge_refs(opts.refs)
    local plan_max      = opts.plan_max or 3
    local draft_max     = opts.draft_max or 3
    local pass_token    = opts.qgate_pass_token or "pass"
    local halt_token    = opts.escalate_blocked_token or "halt"
    local reducer       = opts.reducer or "majority"
    local items_path    = opts.items_path or "$.ctx.candidates"

    return swarm.chain({
        -- S1
        swarm.step(refs.plan, { out = "ctx.plan" }),
        -- S2
        C.enhance_loop({
            step          = refs.plan_qgate,
            until_token   = pass_token,
            max           = plan_max,
            out           = "ctx.plan_review",
            carry         = "ctx.plan_carry",
            counter       = "ctx.plan_iter",
        }),
        -- S3
        C.aggregate({
            step    = refs.panelist,
            items   = swarm.path(items_path),
            reducer = reducer,
            out     = "ctx.consensus",
        }),
        -- S4
        swarm.step(refs.draft, { out = "ctx.draft" }),
        -- S5
        C.enhance_loop({
            step          = refs.draft_qgate,
            until_token   = pass_token,
            max           = draft_max,
            out           = "ctx.draft_review",
            carry         = "ctx.draft_carry",
            counter       = "ctx.draft_iter",
        }),
        -- S6
        C.escalate_gate({
            step          = refs.human_review,
            out           = "ctx.human_review",
            verdict_field = "verdict",
            blocked_token = halt_token,
            resume_key    = "ctx.human_decision",
        }),
        -- S7
        swarm.step(refs.finalize, { out = "ctx.final" }),
    })
end

--- M.run(opts) — invoke the pipeline with caller-injected dispatch.
---
--- @param opts {
---   task_id       : string,    -- REQUIRED, identifies run for resume
---   dispatch      : function,  -- REQUIRED, fn(ref, input) -> response
---   externs       : table?,    -- reducer fns etc. (e.g. {majority=fn})
---   state_backend : table?,    -- default: fresh in-memory backend
---   decision      : any?,      -- if present, write to ctx.human_decision
---                              -- before run (resume convenience)
---   ctx           : table?,    -- initial ctx (fresh mode only); must
---                              -- contain `candidates` if S3 is exercised
---   <shape opts>  ...          -- forwarded to M.build_shape:
---                              --   refs / plan_max / draft_max /
---                              --   qgate_pass_token / escalate_blocked_token /
---                              --   reducer / items_path
--- }
--- @return {
---   completed     : boolean,
---   halted        : boolean,
---   task_id       : string,
---   ctx           : table,
---   result        : table,      -- raw swarm.run result
---   state_backend : table,
--- }
function M.run(opts)
    if type(opts) ~= "table" then
        error("verdict_swarm_pipeline.run: opts table required", 2)
    end
    require_string(opts.task_id, "task_id", "run")
    if type(opts.dispatch) ~= "function" then
        error("verdict_swarm_pipeline.run: opts.dispatch (function) "
            .. "required — caller provides role-aware dispatch", 2)
    end

    local state_backend = opts.state_backend or default_backend()

    if opts.decision ~= nil then
        M.inject_decision(state_backend, opts.task_id, opts.decision)
    end

    local result = swarm.run({
        shape         = M.build_shape(opts),
        dispatch      = opts.dispatch,
        externs       = opts.externs,
        state_backend = state_backend,
        state         = { task_id = opts.task_id },
        ctx           = opts.ctx,
    })

    local completed = result.status == "ok"
    local halted    = result.status == "error"
                      and type(result.error) == "table"
                      and result.error.kind == "escalate_required"

    return {
        completed     = completed,
        halted        = halted,
        task_id       = result.task_id,
        ctx           = result.ctx,
        result        = result,
        state_backend = state_backend,
    }
end

-- ─── artifact_store offload helper (opt-in) ────────────────────────
--
-- M.wrap_dispatch_with_offload(inner, backend, opts) wraps a caller's
-- dispatch function so that large string fields on the response are
-- offloaded to an artifact_backend (4-method iface — same shape as
-- swarm_host_alc.artifact_backend.{file_backend, memory_backend}).
--
-- Behavior:
--   * For each field in opts.fields (default {"body"}), if the
--     response[field] is a string >= opts.threshold bytes (default
--     1024), call `backend:write(artifact_id, value, {kind="binary"})`.
--   * Replace response[field] = nil and add response[field.."_ref"] =
--     { kind="artifact_ref", artifact_id=..., size=N }.
--   * On backend write failure, leave the field intact and add
--     response._offload_error = <reason>.
--
-- Caller usage:
--
--   local backend = require("swarm_host_alc.artifact_backend")
--                     .memory_backend()
--   local wrapped = pipeline.wrap_dispatch_with_offload(
--     my_dispatch, backend, { fields = {"body"}, threshold = 512 })
--   pipeline.run({ dispatch = wrapped, ... })
--
-- Downstream steps that need the full content read it back via
-- backend:read(artifact_ref.artifact_id). The pipeline never embeds
-- the full body in subsequent step prompts (T1 trace + T4 prompt size).
function M.wrap_dispatch_with_offload(inner, backend, opts)
    if type(inner) ~= "function" then
        error("wrap_dispatch_with_offload: inner dispatch (function) required", 2)
    end
    if type(backend) ~= "table"
       or type(backend.write) ~= "function" then
        error("wrap_dispatch_with_offload: backend with :write method required", 2)
    end
    opts = opts or {}
    local fields    = opts.fields    or { "body" }
    local threshold = opts.threshold or 1024
    local id_prefix = opts.id_prefix or "vsp"

    local counter = 0
    return function(ref, input)
        local r = inner(ref, input)
        if type(r) ~= "table" then return r end
        for _, field in ipairs(fields) do
            local v = r[field]
            if type(v) == "string" and #v >= threshold then
                counter = counter + 1
                local artifact_id = string.format("%s-%s-%s-%d",
                    id_prefix, tostring(ref):gsub("[^%w]", "_"),
                    field, counter)
                local ok, err = backend:write(artifact_id, v,
                    { kind = "binary" })
                if ok then
                    r[field] = nil
                    r[field .. "_ref"] = {
                        kind        = "artifact_ref",
                        artifact_id = artifact_id,
                        size        = #v,
                    }
                else
                    r._offload_error = err
                end
            end
        end
        return r
    end
end

-- Exposed helpers (testing / advanced composition).
M._for_test = {
    merge_refs       = merge_refs,
    default_backend  = default_backend,
}

return M
