--- scripts/e2e/swarm_demo.lua — real-LLM E2E for swarm_demo.
---
--- Drives swarm_demo.run() via alc_run. The pkg's 3-Agent linear
--- pipeline calls alc.llm() exactly 3 times (Researcher → Drafter →
--- Reviewer). The agent answers each pause via alc_continue playing
--- the role indicated by the prompt.
---
--- Run:
---     just e2e swarm_demo
--- or directly:
---     agent-block -s scripts/e2e/swarm_demo.lua -p .
---
--- Prereqs:
---     - alc.toml at repo root
---     - alc.local.toml linking swarm_demo + swarm_frame + swarm_host_alc
---       (created via `mcp__algocline__alc_pkg_link path=./packages
---       scope=variant project_root=.`)
---     - ANTHROPIC_API_KEY set in the repo-root environment that
---       agent-block auto-loads (no manual `source` needed)
---
--- Graders:
---     * agent_ok               — agent block terminated normally
---     * max_turns(15)          — bounded ReAct iterations
---     * report_ok_true         — pkg report announces ok=true
---     * report_verdict_ok      — pkg report announces verdict=OK
---     * three_roles_present    — report mentions all 3 role outputs

package.path = "scripts/e2e/?.lua;" .. package.path
local common = require("common")

local params = {
    task = "Briefly explain what photosynthesis is.",
}

-- Use alc_run (not alc_advice) so the host resolves swarm_demo via
-- alc.local.toml (variant scope). alc_advice's strategy lookup does
-- not currently consult variant scope, so we drive the pkg through
-- alc_run with a tiny inline trampoline.
local trampoline = [[
local demo = require("swarm_demo")
local result = demo.run(ctx)
return result
]]

local prompt = string.format(
    [[
Run swarm_demo via alc_run. Call the alc_run MCP tool with:
- code: %q
- ctx: { task = %q }

The inline code does `require("swarm_demo").run(ctx)`. The package
chains 3 Agents in order:
  1. Researcher — asks you to list 3 short bullet points (key angles
     or facts a writer would need)
  2. Drafter    — asks you to write a 2-3 sentence draft using the
     research, ending with the literal sentinel "SWARM_DEMO_END" on
     its own line
  3. Reviewer   — asks you to reply with exactly one line, either
     "OK: <reason>" if the draft looks reasonable, or
     "NG: <reason>" otherwise

Each Agent pauses via alc_run / alc_continue. Answer each pause as
the genuine LLM playing that role — match the prompt's format
(bullets / sentinel / one-line verdict) exactly. Don't paraphrase
the format requirements.

When alc_run returns the final result, output one short report
(under 100 words) containing exactly these snake_case keys:
  ok, verdict, research_present, draft_present, review_present
For example:
  ok=true, verdict=OK, research_present=true, draft_present=true, review_present=true
]],
    trampoline,
    params.task
)

common.run({
    name = "swarm_demo",
    prompt = prompt,
    params = params,
    max_iterations = 15,
    graders = {
        common.grader_agent_ok(),
        common.grader_max_turns(15),
        {
            name = "report_ok_true",
            check = function(result)
                if not result.ok then return false, "agent failed" end
                local c = (result.content or ""):lower()
                if c:find("ok", 1, true)
                    and (c:find("true", 1, true) or c:find("=true", 1, true))
                then
                    return true, nil
                end
                return false, "ok=true not clearly stated in content"
            end,
        },
        {
            name = "report_verdict_ok",
            check = function(result)
                if not result.ok then return false, "agent failed" end
                local c = (result.content or ""):lower()
                if c:find("verdict", 1, true) and c:find("ok", 1, true) then
                    return true, nil
                end
                return false, "verdict=OK not clearly stated in content"
            end,
        },
        {
            name = "three_roles_present",
            check = function(result)
                if not result.ok then return false, "agent failed" end
                local c = (result.content or ""):lower()
                local has_research = c:find("research", 1, true) ~= nil
                local has_draft = c:find("draft", 1, true) ~= nil
                local has_review = c:find("review", 1, true) ~= nil
                if has_research and has_draft and has_review then
                    return true, nil
                end
                return false, string.format(
                    "missing role mention(s): research=%s draft=%s review=%s",
                    tostring(has_research),
                    tostring(has_draft),
                    tostring(has_review)
                )
            end,
        },
    },
})
