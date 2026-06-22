--- examples/coding_pipeline.lua — Coding-domain pipeline smoke
--- (mock alc.llm, no API key).
---
--- Drives coding_pipeline.run() through 2 invocations:
---
---   Run 1 (fresh): @coding_plan → @coding_spec_qgate (retry+carry once)
---     → @coding_write → @coding_compile_qgate (retry+carry once) →
---     @coding_test_qgate (retry+carry twice) → @coding_human_review
---     returns verdict=halt → STATUS.INTERRUPTED.
---
---   Inject ctx.human_decision (caller-supplied approval).
---
---   Run 2 (resume): all top-level steps short-circuit via β fix;
---     escalate_gate sees decision → completes.
---
--- Demonstrates:
---   * caller-injected dispatch + per-role prompts + per-role refs
---   * 2 sequential enhance_loops (compile + test) with INDEPENDENT
---     fix_carry arrays (= each axis's deny trail stays scoped)
---   * artifact_store offload wrap (= long code body persisted to
---     memory backend, response shrunk to ref before downstream qgates)
---
--- Run:
---     lua examples/coding_pipeline.lua
---     just coding-pipeline

package.path = "./packages/?/init.lua;./packages/?.lua;"
    .. "./tests/vendor/?.lua;"
    .. (os.getenv("HOME") or "")
    .. "/.algocline/packages/?/init.lua;"
    .. (os.getenv("HOME") or "")
    .. "/.algocline/packages/?.lua;"
    .. package.path

do
    local ok_dkjson, dkjson = pcall(require, "dkjson")
    local encode, decode
    if ok_dkjson then
        encode = dkjson.encode
        decode = dkjson.decode
    else
        encode = function(t) return tostring(t) end
        decode = function(s) return s end
    end
    _G.alc = _G.alc or {}
    _G.alc.json_encode = _G.alc.json_encode or encode
    _G.alc.json_decode = _G.alc.json_decode or decode
    _G.alc.log         = _G.alc.log or function() end
end

local pipeline = require("coding_pipeline")
local vsp      = require("verdict_swarm_pipeline") -- for offload wrap helper

-- ── Caller-injected prompts ────────────────────────────────────────

local PROMPTS = {
    plan          = "Design code for task: %s. Output {design, axes}.",
    plan_qgate    = "Spec-check the plan. Reply 'verdict: pass' or "
                 .. "'verdict: RETRY' with deny.%s",
    write_code    = "Write code for the plan. Output one paragraph body.",
    compile_qgate = "Compile-check. Reply 'verdict: pass' or "
                 .. "'verdict: RETRY' with compile-error deny.%s",
    test_qgate    = "Test-check. Reply 'verdict: pass' or "
                 .. "'verdict: RETRY' with failing-case deny.%s",
    human_review  = "Human review for %q. Reply 'verdict: pass' or "
                 .. "'verdict: halt' with concern.",
}

-- ── Mock alc.llm with per-role state ───────────────────────────────

local mock = {
    run_phase   = 1,
    spec_n      = 0,
    compile_n   = 0,
    test_n      = 0,
}
local call_log = {}
_G.alc.llm = function(prompt)
    table.insert(call_log, { phase = mock.run_phase, head = prompt:sub(1, 50) })
    if prompt:find("Design code", 1, true) then
        return "design v1"
    elseif prompt:find("Spec%-check") then
        mock.spec_n = mock.spec_n + 1
        if mock.spec_n >= 2 then return "verdict: pass" end
        return "verdict: RETRY deny: missing risk analysis"
    elseif prompt:find("Write code", 1, true) then
        -- intentionally long body to exercise artifact_store offload
        return "function impl() return " .. string.rep("body ", 100) .. " end"
    elseif prompt:find("Compile%-check") then
        mock.compile_n = mock.compile_n + 1
        if mock.compile_n >= 2 then return "verdict: pass" end
        return "verdict: RETRY deny: undefined symbol baz"
    elseif prompt:find("Test%-check") then
        mock.test_n = mock.test_n + 1
        if mock.test_n >= 3 then return "verdict: pass" end
        return "verdict: RETRY deny: case_" .. tostring(mock.test_n)
            .. " fails"
    elseif prompt:find("Human review", 1, true) then
        if mock.run_phase == 1 then
            return "verdict: halt concern: API public change needs CTO signoff"
        end
        return "verdict: pass"
    end
    return "(unknown prompt)"
end

-- ── Caller-injected dispatch (role routing) ────────────────────────

local function parse_verdict(r, n)
    if type(r) == "string"
       and r:lower():find("verdict: pass", 1, true) then
        return { verdict = "pass", attempt = n }
    end
    local deny = "unknown"
    if type(r) == "string" then deny = r:match("deny[:%s]+(.+)$") or r end
    return { verdict = "RETRY", attempt = n, deny = deny }
end

local function make_inner_dispatch(refs, task)
    local rev = {}
    for role, ref in pairs(refs) do rev[ref] = role end
    local calls = {}
    return function(ref, input)
        local role = rev[ref] or "unknown"
        calls[role] = (calls[role] or 0) + 1
        if role == "plan" then
            return { design = _G.alc.llm(PROMPTS.plan:format(task)) }
        elseif role == "plan_qgate" then
            local carry = (type(input) == "table") and input or {}
            local hint = ""
            if #carry > 0 and carry[#carry].deny then
                hint = " Prev deny: " .. carry[#carry].deny
            end
            return parse_verdict(_G.alc.llm(
                PROMPTS.plan_qgate:format(hint)), #carry + 1)
        elseif role == "write_code" then
            -- long body emitted; offload wrapper will rewrite to ref
            return { body = _G.alc.llm(PROMPTS.write_code) }
        elseif role == "compile_qgate" then
            local carry = (type(input) == "table") and input or {}
            local hint = ""
            if #carry > 0 and carry[#carry].deny then
                hint = " Prev compile err: " .. carry[#carry].deny
            end
            return parse_verdict(_G.alc.llm(
                PROMPTS.compile_qgate:format(hint)), #carry + 1)
        elseif role == "test_qgate" then
            local carry = (type(input) == "table") and input or {}
            local hint = ""
            if #carry > 0 and carry[#carry].deny then
                hint = " Prev test fail: " .. carry[#carry].deny
            end
            return parse_verdict(_G.alc.llm(
                PROMPTS.test_qgate:format(hint)), #carry + 1)
        elseif role == "human_review" then
            local r = _G.alc.llm(PROMPTS.human_review:format(task))
            if type(r) == "string"
               and r:lower():find("verdict: halt", 1, true) then
                return { verdict = "halt", concern = r }
            end
            return { verdict = "pass", note = r }
        end
        error("coding_pipeline smoke: unknown ref " .. tostring(ref), 0)
    end, calls
end

-- ── In-memory artifact_backend (minimal 4-method) ──────────────────

local function memory_backend()
    local store = {}
    local b = { store = store }
    function b:write(id, payload, _opts) store[id] = payload; return true end
    function b:read(id) return store[id] end
    function b:exists(id) return store[id] ~= nil end
    function b:delete(id) store[id] = nil; return true end
    return b
end

-- ── Run 1: fresh + artifact offload wrap ───────────────────────────

local task    = "Implement pricing tier upgrade endpoint"
local task_id = "cp-task-001"
local refs    = pipeline.DEFAULT_REFS
local backend = memory_backend()

print("─── Run 1 (fresh + offload wrap, expect halt at human_review) ─")
local d1_inner, calls1 = make_inner_dispatch(refs, task)
-- offload wrap: any response.body >= 100 bytes is offloaded to backend
local d1 = vsp.wrap_dispatch_with_offload(d1_inner, backend, {
    fields    = { "body" },
    threshold = 100,
    id_prefix = "cp-r1",
})
local run1 = pipeline.run({
    task_id  = task_id,
    dispatch = d1,
})

print(string.format("completed=%s halted=%s",
    tostring(run1.completed), tostring(run1.halted)))
print(string.format("calls: plan=%d plan_qgate=%d write_code=%d "
    .. "compile_qgate=%d test_qgate=%d human_review=%d",
    calls1.plan or 0, calls1.plan_qgate or 0,
    calls1.write_code or 0, calls1.compile_qgate or 0,
    calls1.test_qgate or 0, calls1.human_review or 0))
print(string.format("plan_carry=%d compile_carry=%d test_carry=%d",
    #(run1.ctx.plan_carry or {}),
    #(run1.ctx.compile_carry or {}),
    #(run1.ctx.test_carry or {})))

-- artifact offload evidence
local body_ref = run1.ctx.code and run1.ctx.code.body_ref
if body_ref then
    print(string.format(
        "ctx.code.body offloaded: artifact_id=%q size=%d (ctx.code.body=%s)",
        tostring(body_ref.artifact_id), body_ref.size,
        tostring(run1.ctx.code.body)))
    print(string.format("backend has the body: %d bytes",
        #(backend:read(body_ref.artifact_id) or "")))
end

assert(run1.halted == true)
assert(calls1.plan_qgate == 2, "plan_qgate retry+carry")
assert(calls1.compile_qgate == 2, "compile_qgate retry+carry")
assert(calls1.test_qgate == 3, "test_qgate retry+carry twice")
assert(calls1.human_review == 1, "human_review halted")
-- offload assertions
assert(run1.ctx.code.body == nil, "body offloaded → nil in ctx")
assert(run1.ctx.code.body_ref, "body_ref present")
assert(run1.ctx.code.body_ref.size > 100, "offloaded size > threshold")
assert(backend:read(run1.ctx.code.body_ref.artifact_id),
    "backend has the body content")
-- per-axis fix_carry independence
assert(run1.ctx.plan_carry[1].deny:find("risk"), "plan carry deny ok")
assert(run1.ctx.compile_carry[1].deny:find("symbol"), "compile carry deny ok")
assert(run1.ctx.test_carry[2].deny:find("case_2"), "test carry deny ok")

-- ── Run 2: resume ──────────────────────────────────────────────────

print("\n─── Run 2 (resume + decision) ──────────────────────────────")
mock.run_phase = 2
local pre_log = #call_log
local d2_inner, calls2 = make_inner_dispatch(refs, task)
local d2 = vsp.wrap_dispatch_with_offload(d2_inner, backend, {
    fields = { "body" }, threshold = 100, id_prefix = "cp-r2",
})
local run2 = pipeline.run({
    task_id       = task_id,
    dispatch      = d2,
    state_backend = run1.state_backend,
    decision      = { approved = true, note = "CTO signed off" },
})
local resume_calls = #call_log - pre_log
print(string.format("completed=%s halted=%s",
    tostring(run2.completed), tostring(run2.halted)))
print(string.format("calls: plan=%d plan_qgate=%d write_code=%d "
    .. "compile_qgate=%d test_qgate=%d human_review=%d",
    calls2.plan or 0, calls2.plan_qgate or 0,
    calls2.write_code or 0, calls2.compile_qgate or 0,
    calls2.test_qgate or 0, calls2.human_review or 0))
print(string.format("alc.llm invocations during resume = %d (0 expected)",
    resume_calls))

assert(run2.completed == true)
assert((calls2.plan or 0) == 0, "all top-level short-circuit on resume")
assert((calls2.plan_qgate or 0) == 0)
assert((calls2.write_code or 0) == 0)
assert((calls2.compile_qgate or 0) == 0)
assert((calls2.test_qgate or 0) == 0)
assert((calls2.human_review or 0) == 0)
assert(resume_calls == 0, "no LLM calls during resume")
assert(run2.ctx.human_decision.approved == true)

print("\nPASS: coding_pipeline smoke (6 step Coding-domain + caller "
    .. "injection + 3 enhance_loop with independent fix_carry + "
    .. "artifact offload + escalate halt + resume short-circuit)")
