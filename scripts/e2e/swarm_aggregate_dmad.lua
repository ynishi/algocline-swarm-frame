--- E2E: swarm_aggregate_plugin.run (variant=dmad).
---
--- Drives the swarm_aggregate_plugin through alc_advice → alc_run →
--- agent ReAct loop. Each alc.llm pause inside dmad's N×(R+1) loop is
--- answered by the agent via alc_continue, so the agent is the LLM
--- for every dmad agent at every round (N=3 × R=2 → 9 alc.llm calls
--- → ~9-12 ReAct turns including the initial alc_advice turn).
---
--- Run:
---     just e2e swarm_aggregate_dmad
--- or directly:
---     agent-block -s scripts/e2e/swarm_aggregate_dmad.lua -p .
---
--- Prereqs:
---     - alc.toml at repo root (project marker)
---     - alc.local.toml linking swarm_frame / swarm_frame_algocline /
---       swarm_aggregate_plugin (created by `alc_pkg_link
---       path=./packages scope=variant`)
---     - dmad globally installed (~/.algocline/packages/dmad), typically
---       via algocline-bundled-packages
---     - ANTHROPIC_API_KEY exported
---
--- Graders:
---     * agent_ok                   — agent block terminated normally
---     * content_contains("42")     — pkg report mentions the canonical
---                                    "answer to life, the universe,
---                                    and everything" answer
---     * llm_calls_match            — raw pkg result reports
---                                    total_llm_calls = N·(R+1) = 9
---     * tally_present              — raw pkg result emits the tally
---                                    structure (majority vote
---                                    transcript)
---     * max_turns                  — bounded ReAct iterations

package.path = "scripts/e2e/?.lua;" .. package.path
local common = require("common")

local params = {
    task = "What is the answer to life, the universe, and everything? Reply with the canonical Hitchhiker's Guide value.",
    variant = "dmad",
    n_agents = 3,
    n_rounds = 2,
}

local prompt = string.format(
    [[
Run swarm_aggregate_plugin via alc_advice:
- package: "swarm_aggregate_plugin"
- task: %q
- opts: { variant=%q, n_agents=%d, n_rounds=%d }

The package issues 9 alc.llm() calls (3 agents × 3 rounds). Each
returns status "needs_response" — answer via alc_continue. Always
wrap your numeric answer in \boxed{...} (e.g. \boxed{42}) — the
package extracts answers via this pattern. The canonical answer is
42.

When done, output one short report containing:
  answer, n_agents, n_rounds, total_llm_calls, tally.

Use those exact keys (snake_case) so post-hoc graders can locate
them. Keep the report under 200 words.
]],
    params.task,
    params.variant,
    params.n_agents,
    params.n_rounds
)

common.run({
    name = "swarm_aggregate_dmad",
    prompt = prompt,
    params = params,
    max_iterations = 50, -- 9 dmad turns × variable ReAct exploration
    -- per turn; 30 was tight, 50 gives headroom
    -- without 100× cost blow-up (see common.lua
    -- DEFAULTS for the cost-side discussion).
    graders = {
        common.grader_agent_ok(),
        common.grader_content_contains("42"),
        common.grader_max_turns(50),
        -- Note: agent-block's on_turn callback does NOT expose
        -- tool_responses (only tool_calls / turn_number / usage), so
        -- common.find_raw_tool_response always returns nil for e2e
        -- runs under the current agent-block API. The graders below
        -- rely on the agent's `content` text as the authoritative
        -- post-hoc signal, with case-insensitive snake_case OR
        -- Title-Case-with-spaces matching to absorb the agent's
        -- natural paraphrase of pkg result keys.
        {
            name = "llm_calls_match",
            check = function(result)
                if not result.ok then return false, "agent failed" end
                local c = (result.content or ""):lower()
                local mentions_key = c:find("total_llm_calls", 1, true) or c:find("total llm calls", 1, true)
                if not mentions_key then return false, "total_llm_calls / 'Total LLM Calls' not mentioned" end
                if c:find("9", 1, true) or c:find("nine", 1, true) then return true, nil end
                return false, "total_llm_calls != 9 (or '9' not adjacent)"
            end,
        },
        {
            name = "tally_present",
            check = function(result)
                if not result.ok then return false, "agent failed" end
                local c = (result.content or ""):lower()
                if not c:find("tally", 1, true) then return false, "tally not mentioned" end
                if c:find("count", 1, true) or c:find("vote", 1, true) or c:find("answer", 1, true) then
                    return true, nil
                end
                return false, "tally mentioned but no 'count'/'vote'/'answer' nearby"
            end,
        },
    },
})
