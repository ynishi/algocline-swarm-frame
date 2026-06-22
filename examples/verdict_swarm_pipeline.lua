--- examples/verdict_swarm_pipeline.lua — reusable pipeline smoke
--- (mock alc.llm, no API key).
---
--- This smoke shows the **caller injection** pattern: the pkg owns
--- only the shape factory + run wrapper; **all** prompts, dispatch
--- logic, and reducers come from this file.
---
--- The 7-step 実務型 Swarm shape (linear + Gate + Retry + HIL/escalate +
--- fan-out aggregate + state persistence/resume) is exercised end-to-end:
--- prompt templates, role dispatch, and reducer are wired here in the
--- caller. To swap any of these out, edit this file (NOT the pkg).
---
--- Run from the repo root:
---     lua examples/verdict_swarm_pipeline.lua
---     just verdict-swarm-pipeline

package.path = "./packages/?/init.lua;./packages/?.lua;"
    .. "./tests/vendor/?.lua;"
    .. (os.getenv("HOME") or "")
    .. "/.algocline/packages/?/init.lua;"
    .. (os.getenv("HOME") or "")
    .. "/.algocline/packages/?.lua;"
    .. package.path

-- _G.alc bootstrap (flow.ir persistence requires _G.alc.json_*).
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

local pipeline = require("verdict_swarm_pipeline")

-- ── Caller-injected prompt templates (caller owns these) ────────────

local PROMPTS = {
    plan = "Plan a 3-axis breakdown for task: %s",
    plan_qgate = "QGate the plan for %q. Reply 'verdict: pass' (if 85+) "
              .. "or 'verdict: RETRY' with a one-line deny.%s",
    draft = "Draft 1 paragraph for task %q based on prior consensus.",
    draft_qgate = "QGate the draft. Reply 'verdict: pass' or "
               .. "'verdict: RETRY' with a one-line deny.%s",
    human_review = "Human review for task %q. Reply 'verdict: pass' or "
                .. "'verdict: halt' with concern.",
    finalize = "Finalize 1-paragraph summary for %q.",
}

-- ── Mock alc.llm: per-role state + retry-then-pass ─────────────────

local mock = { run_phase = 1, plan_qgate_n = 0, draft_qgate_n = 0 }
local call_log = {}
_G.alc.llm = function(prompt)
    table.insert(call_log, { phase = mock.run_phase, head = prompt:sub(1, 60) })
    if prompt:find("Plan a 3-axis", 1, true) then
        return "axis_1 / axis_2 / axis_3 outline"
    elseif prompt:find("QGate the plan", 1, true) then
        mock.plan_qgate_n = mock.plan_qgate_n + 1
        if mock.plan_qgate_n >= 2 then return "verdict: pass" end
        return "verdict: RETRY deny: missing cost detail"
    elseif prompt:find("Draft 1 paragraph", 1, true) then
        return "Paragraph synthesizing axes."
    elseif prompt:find("QGate the draft", 1, true) then
        mock.draft_qgate_n = mock.draft_qgate_n + 1
        if mock.draft_qgate_n >= 2 then return "verdict: pass" end
        return "verdict: RETRY deny: tighten conclusion"
    elseif prompt:find("Human review", 1, true) then
        if mock.run_phase == 1 then
            return "verdict: halt concern: needs CFO signoff"
        end
        return "verdict: pass"
    elseif prompt:find("Finalize", 1, true) then
        return "Final summary text."
    end
    return "(unknown prompt)"
end

-- ── Caller-injected dispatch (role routing + prompt assembly) ──────
--
-- The caller controls every per-role prompt and response shape. The
-- pkg never sees these — it only writes step.out to ctx via flow.ir.

local function make_dispatch(task, refs)
    local rev = {}
    for role, ref in pairs(refs) do rev[ref] = role end
    local calls = {}
    local function bump(role)
        calls[role] = (calls[role] or 0) + 1
    end
    local dispatch = function(ref, input)
        local role = rev[ref] or "unknown"
        bump(role)
        if role == "plan" then
            return { plan = _G.alc.llm(PROMPTS.plan:format(task)) }
        elseif role == "plan_qgate" then
            local carry = (type(input) == "table") and input or {}
            local hint = ""
            if #carry > 0 and carry[#carry].deny then
                hint = " Previous deny: '" .. tostring(carry[#carry].deny)
                    .. "'. Do not repeat."
            end
            local r = _G.alc.llm(PROMPTS.plan_qgate:format(task, hint))
            if type(r) == "string"
               and r:lower():find("verdict: pass", 1, true) then
                return { verdict = "pass", attempt = #carry + 1 }
            end
            local deny = "unknown"
            if type(r) == "string" then
                deny = r:match("deny[:%s]+(.+)$") or r
            end
            return { verdict = "RETRY", attempt = #carry + 1, deny = deny }
        elseif role == "panelist" then
            return { vote = input, said = "panelist votes " .. tostring(input) }
        elseif role == "draft" then
            return { body = _G.alc.llm(PROMPTS.draft:format(task)) }
        elseif role == "draft_qgate" then
            local carry = (type(input) == "table") and input or {}
            local hint = ""
            if #carry > 0 and carry[#carry].deny then
                hint = " Previous deny: '" .. tostring(carry[#carry].deny)
                    .. "'. Do not repeat."
            end
            local r = _G.alc.llm(PROMPTS.draft_qgate:format(hint))
            if type(r) == "string"
               and r:lower():find("verdict: pass", 1, true) then
                return { verdict = "pass", attempt = #carry + 1 }
            end
            local deny = "unknown"
            if type(r) == "string" then
                deny = r:match("deny[:%s]+(.+)$") or r
            end
            return { verdict = "RETRY", attempt = #carry + 1, deny = deny }
        elseif role == "human_review" then
            local r = _G.alc.llm(PROMPTS.human_review:format(task))
            if type(r) == "string"
               and r:lower():find("verdict: halt", 1, true) then
                return { verdict = "halt", concern = r }
            end
            return { verdict = "pass", note = r }
        elseif role == "finalize" then
            return { summary = _G.alc.llm(PROMPTS.finalize:format(task)) }
        end
        error("verdict_swarm_pipeline smoke: unknown ref " .. tostring(ref), 0)
    end
    return dispatch, calls
end

-- ── Caller-injected reducer (majority) ──────────────────────────────

local function majority(fan_results)
    local tally = {}
    for _, entry in ipairs(fan_results or {}) do
        local vote = entry and entry.r and entry.r.vote
        if vote then tally[vote] = (tally[vote] or 0) + 1 end
    end
    local winner, top = nil, 0
    for v, c in pairs(tally) do
        if c > top then winner, top = v, c end
    end
    return { winner = winner, tally = tally }
end

-- ── Run 1: fresh, expect halt ───────────────────────────────────────

local task    = "Launch the new pricing tier"
local task_id = "vsp-task-001"
local candidates = { "alpha", "beta", "alpha" }

print("─── Run 1 (fresh, expect halt at human_review) ─────────────")
local refs = pipeline.DEFAULT_REFS
local d1, calls1 = make_dispatch(task, refs)
local run1 = pipeline.run({
    task_id    = task_id,
    dispatch   = d1,
    externs    = { majority = majority },
    ctx        = { candidates = candidates },
    -- knobs: defaults are fine (plan_max=3, draft_max=3,
    --        qgate_pass_token="pass", escalate_blocked_token="halt")
})

print(string.format("completed=%s halted=%s",
    tostring(run1.completed), tostring(run1.halted)))
print(string.format("calls: plan=%d plan_qgate=%d panelist=%d "
    .. "draft=%d draft_qgate=%d human_review=%d finalize=%d",
    calls1.plan or 0, calls1.plan_qgate or 0, calls1.panelist or 0,
    calls1.draft or 0, calls1.draft_qgate or 0,
    calls1.human_review or 0, calls1.finalize or 0))
print(string.format("ctx.consensus.winner=%q",
    tostring(run1.ctx.consensus and run1.ctx.consensus.winner)))

assert(run1.halted == true)
assert(run1.completed == false)
assert(calls1.plan_qgate == 2,
    "plan_qgate should retry once via fix_carry, got "
    .. tostring(calls1.plan_qgate))
assert(calls1.draft_qgate == 2,
    "draft_qgate should retry once via fix_carry")
assert(calls1.panelist == 3, "3 panelists fan-out")
assert((calls1.finalize or 0) == 0, "finalize NOT yet")
assert(run1.ctx.consensus.winner == "alpha", "majority winner=alpha")
assert(#run1.ctx.plan_carry == 2, "plan_carry has 2 attempts")
assert(run1.ctx.plan_carry[1].deny, "carry[1] has deny field")
assert(run1.ctx.human_review.verdict == "halt", "halted on human review")

-- ── Run 2: resume with decision ─────────────────────────────────────

print("\n─── Run 2 (resume with decision, expect finalize) ──────────")
mock.run_phase = 2
local pre_log = #call_log
local d2, calls2 = make_dispatch(task, refs)
local run2 = pipeline.run({
    task_id       = task_id,
    dispatch      = d2,
    externs       = { majority = majority },
    state_backend = run1.state_backend,
    decision      = { approved = true, note = "CFO offline-signed" },
    ctx           = { candidates = candidates },
})

local resume_calls = #call_log - pre_log
print(string.format("completed=%s halted=%s",
    tostring(run2.completed), tostring(run2.halted)))
print(string.format("calls: plan=%d plan_qgate=%d panelist=%d "
    .. "draft=%d draft_qgate=%d human_review=%d finalize=%d",
    calls2.plan or 0, calls2.plan_qgate or 0, calls2.panelist or 0,
    calls2.draft or 0, calls2.draft_qgate or 0,
    calls2.human_review or 0, calls2.finalize or 0))
print(string.format(
    "alc.llm invocations during resume = %d (only @finalize)",
    resume_calls))

assert(run2.completed == true)
assert((calls2.plan or 0) == 0, "plan short-circuit")
assert((calls2.plan_qgate or 0) == 0, "plan_qgate short-circuit")
assert((calls2.draft or 0) == 0, "draft short-circuit")
assert((calls2.draft_qgate or 0) == 0, "draft_qgate short-circuit")
assert((calls2.human_review or 0) == 0, "human_review short-circuit")
assert(calls2.finalize == 1, "finalize fresh")
assert(resume_calls == 1, "only finalize calls alc.llm during resume")
assert(run2.ctx.human_decision.approved == true,
    "decision preserved in ctx")
assert(run2.ctx.final and run2.ctx.final.summary, "final summary written")

-- ── Run 3: same shape, alternative agent ref (A/B swap demonstration) ─

print("\n─── Run 3 (A/B swap: @plan → @plan_v2) ─────────────────────")
mock.plan_qgate_n = 0  -- reset mock per-role counters
mock.draft_qgate_n = 0
local task_id_v2 = "vsp-task-002"
local refs_v2 = { plan = "@plan_v2" } -- override only plan ref
local d3, calls3 = make_dispatch(task,
    -- merge for reverse-map lookup in caller dispatch
    setmetatable({ plan = "@plan_v2" }, {
        __index = pipeline.DEFAULT_REFS,
    }))
local run3 = pipeline.run({
    task_id    = task_id_v2,
    dispatch   = d3,
    externs    = { majority = majority },
    refs       = refs_v2,
    ctx        = { candidates = candidates },
})
print(string.format("Run 3: halted=%s, plan dispatched=%d (ref=@plan_v2)",
    tostring(run3.halted), calls3.plan or 0))
assert(calls3.plan == 1,
    "Run 3: @plan_v2 should be invoked (caller dispatch routed it)")

print("\nPASS: verdict_swarm_pipeline smoke "
    .. "(caller-injected prompts/dispatch/refs/externs, "
    .. "QGate carry + panel aggregate + escalate halt + resume + ref swap)")
