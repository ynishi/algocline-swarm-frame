--- coding_pipeline — reusable Coding-domain Swarm pipeline.
---
--- A 6-step Coding-flavored verdict-driven pipeline scaffold. Built on
--- the same V3 composites as verdict_swarm_pipeline (its generic
--- sibling), but the shape is Coding-shaped:
---
---   S1: @plan            (linear step — design / strategy)
---   S2: enhance_loop(@plan_qgate)     (= spec_check, fix_carry)
---   S3: @write_code      (linear step — actual code emission)
---   S4: enhance_loop(@compile_qgate)  (= compile / type-check / lint,
---                                       fix_carry with prev compile
---                                       errors to address)
---   S5: enhance_loop(@test_qgate)     (= test execution + review,
---                                       fix_carry with prev test
---                                       failures to address)
---   S6: escalate_gate(@human_review)  (= HIL halt on judgment-required
---                                       cases; resume via ctx.human_decision)
---
--- Differences from verdict_swarm_pipeline (vsp):
---   * No S3 fan-out aggregate (vsp's panel) — Coding tasks usually
---     don't benefit from N-candidate fan-out at write time (= caller
---     can always layer aggregate on top by composing shapes).
---   * Two sequential enhance_loops (compile + test) instead of one,
---     because Coding has multiple verifiable axes — letting each
---     fix_carry stay scoped to its axis improves prompt focus.
---   * No S7 finalize — commit handling is OUT of scope at the pipeline
---     layer (it's a side-effect on the host file system / VCS, not a
---     pure pipeline step). Caller handles commit after the pipeline
---     returns.
---
--- Same caller-injection contract as vsp: all prompts, dispatch logic,
--- per-role refs, and externs come from the caller. The pkg owns only
--- the shape factory + run wrapper + decision injection helper.
---
--- Status: v0.1.0 — first cut, Coding domain still fluid; expect
--- iteration on shape (= the 6 steps) and role names. composite re-use
--- only; the pkg does not introduce new IR nodes (V3 §5.8 規律).

local swarm = require("swarm_frame.v3")
local C     = swarm.composite

local M = {}
M.VERSION = "0.1.0"

M.meta = {
    name        = "coding_pipeline",
    version     = "0.1.0",
    category    = "swarm_pipeline",
    description = "Reusable Coding-domain 6-step pipeline: "
        .. "plan → spec_qgate (enhance_loop) → write_code → "
        .. "compile_qgate → test_qgate → escalate_gate(HIL). "
        .. "Caller injects dispatch, prompts, refs, externs.",
}

-- ─── per-role default agent refs (caller may override) ─────────────

M.DEFAULT_REFS = {
    plan          = "@coding_plan",
    plan_qgate    = "@coding_spec_qgate",
    write_code    = "@coding_write",
    compile_qgate = "@coding_compile_qgate",
    test_qgate    = "@coding_test_qgate",
    human_review  = "@coding_human_review",
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
        error("coding_pipeline." .. fn .. ": " .. name
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
            "coding_pipeline.inject_decision: state_backend "
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
---   plan_max               : integer?,  -- S2 max (default 3)
---   compile_max            : integer?,  -- S4 max (default 5; compile loops
---                                          tend to need more retries than
---                                          plan/test layers — error trail
---                                          shrinks per iter)
---   test_max               : integer?,  -- S5 max (default 5)
---   qgate_pass_token       : string?,   -- enhance_loop until_token (default "pass")
---   escalate_blocked_token : string?,   -- escalate_gate blocked_token (default "halt")
--- }
--- @return IR Node (chain of 6)
function M.build_shape(opts)
    opts = opts or {}
    local refs = merge_refs(opts.refs)
    local plan_max    = opts.plan_max    or 3
    local compile_max = opts.compile_max or 5
    local test_max    = opts.test_max    or 5
    local pass_token  = opts.qgate_pass_token       or "pass"
    local halt_token  = opts.escalate_blocked_token or "halt"

    return swarm.chain({
        -- S1: plan
        swarm.step(refs.plan, { out = "ctx.plan" }),

        -- S2: spec_qgate (enhance_loop with fix_carry on prev deny)
        C.enhance_loop({
            step          = refs.plan_qgate,
            until_token   = pass_token,
            max           = plan_max,
            out           = "ctx.plan_review",
            carry         = "ctx.plan_carry",
            counter       = "ctx.plan_iter",
        }),

        -- S3: write_code
        swarm.step(refs.write_code, { out = "ctx.code" }),

        -- S4: compile_qgate (enhance_loop with fix_carry on prev compile errs)
        C.enhance_loop({
            step          = refs.compile_qgate,
            until_token   = pass_token,
            max           = compile_max,
            out           = "ctx.compile_review",
            carry         = "ctx.compile_carry",
            counter       = "ctx.compile_iter",
        }),

        -- S5: test_qgate (enhance_loop with fix_carry on prev test failures)
        C.enhance_loop({
            step          = refs.test_qgate,
            until_token   = pass_token,
            max           = test_max,
            out           = "ctx.test_review",
            carry         = "ctx.test_carry",
            counter       = "ctx.test_iter",
        }),

        -- S6: escalate_gate (HIL halt on remaining judgment cases)
        C.escalate_gate({
            step          = refs.human_review,
            out           = "ctx.human_review",
            verdict_field = "verdict",
            blocked_token = halt_token,
            resume_key    = "ctx.human_decision",
        }),
    })
end

--- M.run(opts) — invoke the pipeline with caller-injected dispatch.
---
--- @param opts {
---   task_id       : string,    -- REQUIRED, identifies run for resume
---   dispatch      : function,  -- REQUIRED, fn(ref, input) -> response
---   externs       : table?,    -- caller externs (optional for Coding)
---   state_backend : table?,    -- default: fresh in-memory backend
---   decision      : any?,      -- if present, write to ctx.human_decision
---   ctx           : table?,    -- initial ctx (fresh mode only)
---   <shape opts>  ...          -- forwarded to M.build_shape:
---                              --   refs / plan_max / compile_max /
---                              --   test_max / qgate_pass_token /
---                              --   escalate_blocked_token
--- }
--- @return {
---   completed     : boolean,
---   halted        : boolean,
---   task_id       : string,
---   ctx           : table,
---   result        : table,
---   state_backend : table,
--- }
function M.run(opts)
    if type(opts) ~= "table" then
        error("coding_pipeline.run: opts table required", 2)
    end
    require_string(opts.task_id, "task_id", "run")
    if type(opts.dispatch) ~= "function" then
        error("coding_pipeline.run: opts.dispatch (function) "
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

-- Exposed helpers (testing / advanced composition).
M._for_test = {
    merge_refs      = merge_refs,
    default_backend = default_backend,
}

return M
