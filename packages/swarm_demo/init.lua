--- swarm_demo — Minimal 3-Agent linear Swarm demo.
---
--- A 1-pkg illustration of the "Agent Swarm" pattern: register 3
--- Agents (Researcher → Drafter → Reviewer) as separate
--- `swarm_host_alc.dispatcher` instances and run them linearly,
--- threading each Agent's response into the next Agent's spec.
---
--- Each Agent is one dispatcher. The Engine mechanism (token & prompt
--- round-trip through `flow.llm_bound` → `alc.llm`) is the swarm
--- substrate; Application policy (the 3 role prompts + the linear
--- threading) is the demo's domain content.
---
--- Scope (Demo, intentionally minimal):
---   * 3 Agents, linear (no fan-out, no retry, no verdict loop)
---   * Error handling = inline assertions only (validation at the
---     boundary; runtime errors propagate)
---   * No plugins, no artifact_backend, no state persistence — just
---     prove the swarm_host_alc dispatcher round-trip via real LLM
---
--- Run paths:
---
---     just swarm-demo               # smoke (mock alc.llm)
---     just e2e swarm_demo           # real LLM via agent-block
---
--- Both drive `M.run({ task = ... })`.

local M = {}

M.VERSION = "0.1.0"

M.meta = {
    name = "swarm_demo",
    version = "0.1.0",
    category = "frame_example",
    description = "Minimal 3-Agent linear Swarm: Researcher → Drafter → Reviewer via swarm_host_alc.dispatcher.",
}

local host = require("swarm_host_alc")
local frame = require("swarm_frame")

-- ─── validation helpers ─────────────────────────────────────────────

local function require_string(v, name, fn)
    if type(v) ~= "string" or v == "" then
        error("swarm_demo." .. fn .. ": " .. name .. " (non-empty string) required, got " .. type(v), 3)
    end
end

-- ─── role prompt templates ──────────────────────────────────────────
--
-- Each role prompt is a pure function (spec) -> string. They are the
-- only domain-aware pieces; the dispatcher infrastructure is generic.

local function researcher_prompt(spec)
    return string.format(
        [[Task: %s

You are the Researcher. List 3 short bullet points covering the key
angles or facts a writer would need to answer this task. Output the
3 bullets only — no preamble, no closing remark.]],
        spec.task
    )
end

local function drafter_prompt(spec)
    return string.format(
        [[Task: %s

Research notes:
%s

You are the Drafter. Write a 2-3 sentence short draft answer to the
task, using the research notes. No preamble. End your response with
the literal sentinel marker on its own line:
SWARM_DEMO_END]],
        spec.task,
        spec.research
    )
end

local function reviewer_prompt(spec)
    return string.format(
        [[Task: %s

Draft:
%s

You are the Reviewer. Reply with exactly one line, either:
  OK: <one-sentence reason>
  NG: <one-sentence reason>
Nothing else.]],
        spec.task,
        spec.draft
    )
end

-- ─── dispatcher factory ─────────────────────────────────────────────
--
-- Each Agent = one swarm_host_alc.dispatcher instance with its own
-- builder closure. The 3 Agents share the same `flow_state` and `deps`
-- so the underlying frame/alc/flow surface stays consistent.

local function make_agent(name, prompt_template, flow_state, deps)
    return host.dispatcher.make_dispatcher({
        builder = function(_step, spec) return prompt_template(spec) end,
        flow_state = flow_state,
        pkg_name = "swarm_demo." .. name,
        deps = deps,
    })
end

-- ─── verdict parser ─────────────────────────────────────────────────

local function parse_verdict(review)
    if type(review) ~= "string" then return "UNKNOWN" end
    if review:match("^%s*OK[:%s]") then return "OK" end
    if review:match("^%s*NG[:%s]") then return "NG" end
    return "UNKNOWN"
end

-- ─── main entry ─────────────────────────────────────────────────────

--- Run the 3-Agent linear Swarm demo.
---
--- @param opts {
---     task : string,            -- REQUIRED, the topic to research/answer
---     alc  : table?,            -- defaults to _G.alc; requires .llm function
---     flow : table?,            -- defaults to _G.flow; minimal shim auto-injected
--- }                             --   if absent (educational fallback)
--- @return {
---     ok        : boolean,      -- Reviewer responded "OK: ..."
---     task      : string,
---     research  : string,
---     draft     : string,
---     review    : string,
---     verdict   : "OK" | "NG" | "UNKNOWN",
--- }
function M.run(opts)
    if type(opts) ~= "table" then
        error("swarm_demo.run: opts table required", 2)
    end
    require_string(opts.task, "task", "run")

    local alc = opts.alc or _G.alc
    if type(alc) ~= "table" or type(alc.llm) ~= "function" then
        error("swarm_demo.run: alc.llm function required (set _G.alc or pass opts.alc)", 2)
    end

    -- Provide a minimal flow shim when caller doesn't supply one
    -- (educational examples / mock-LLM smoke). The shim just routes
    -- llm_bound(state, {prompt=...}) straight to alc.llm(prompt).
    -- Production env (algocline alc_run) sets _G.flow with a richer
    -- llm_bound that handles flow_state persistence.
    local flow = opts.flow or _G.flow
    if type(flow) ~= "table" or type(flow.llm_bound) ~= "function" then
        flow = {
            llm_bound = function(_flow_state, llm_opts)
                return alc.llm(llm_opts.prompt, llm_opts)
            end,
        }
    end

    -- swarm_frame must be initialized once before any dispatcher
    -- creation (sets check_mode resolution). Idempotent.
    frame.init({ check_mode = "non-check" })

    -- Minimal `deps` surface — kept inline so the demo is
    -- self-contained without pulling additional fixtures.
    local deps = {
        frame = {
            check_mode = function() return "non-check" end,
            step_id_of = function(p) return tostring(p) end,
            parse_verdict = function() return nil end,
        },
        alc = alc,
        flow = flow,
    }

    -- One flow_state shared across the 3 Agents (V3 IF #2).
    local flow_state = { data = { task_id = "swarm_demo" } }

    -- Register 3 Agents (= 3 dispatcher instances).
    local researcher = make_agent("researcher", researcher_prompt, flow_state, deps)
    local drafter    = make_agent("drafter",    drafter_prompt,    flow_state, deps)
    local reviewer   = make_agent("reviewer",   reviewer_prompt,   flow_state, deps)

    -- Run the 3 Agents linearly. Each call returns the raw LLM
    -- response string for that Agent's prompt. Outputs are threaded
    -- explicitly into the next Agent's spec.
    local research = researcher("research", { task = opts.task })
    local draft    = drafter("draft", { task = opts.task, research = research })
    local review   = reviewer("review", { task = opts.task, draft = draft })

    local verdict = parse_verdict(review)

    return {
        ok = (verdict == "OK"),
        task = opts.task,
        research = research,
        draft = draft,
        review = review,
        verdict = verdict,
    }
end

-- Test-only seam so spec can poke the role prompt templates without
-- going through the full dispatcher round-trip.
M._for_test = {
    researcher_prompt = researcher_prompt,
    drafter_prompt = drafter_prompt,
    reviewer_prompt = reviewer_prompt,
    parse_verdict = parse_verdict,
}

return M
