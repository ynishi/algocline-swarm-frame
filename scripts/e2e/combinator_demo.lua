--- scripts/e2e/combinator_demo.lua — real-LLM E2E for combinator_demo.
---
--- Drives combinator_demo.run() via alc_advice. The pkg's verdict_loop
--- calls alc.llm() up to max_retries+1 times; the agent answers each
--- pause via alc_continue and is asked to wrap a numeric answer in
--- `\boxed{...}` so the verdict_loop's parser passes.
---
--- Run:
---     just e2e combinator_demo
--- or directly:
---     agent-block -s scripts/e2e/combinator_demo.lua -p .
---
--- Prereqs (same as swarm_aggregate_dmad):
---     - alc.toml at repo root
---     - alc.local.toml linking combinator_demo + swarm_frame
---       (created via `mcp__algocline__alc_pkg_link path=./packages
---       scope=variant project_root=.`)
---     - ANTHROPIC_API_KEY exported via repo-root .env (agent-block
---       auto-loads .env; no manual `source` needed)
---
--- Graders:
---     * agent_ok                 — agent block terminated normally
---     * content_contains("42")   — pkg report mentions the answer
---     * report_ok_true           — pkg report announces ok=true
---     * max_turns                — bounded ReAct iterations

package.path = "scripts/e2e/?.lua;" .. package.path
local common = require("common")

local params = {
    task = "What is 21 + 21? Answer with a single integer wrapped in \\boxed{...}.",
    max_retries = 2,
}

-- Use alc_run (not alc_advice) so the host resolves combinator_demo via
-- alc.local.toml (variant scope). alc_advice's strategy lookup currently
-- does not consult variant scope, so we drive the pkg through alc_run
-- with a tiny inline trampoline instead.
local trampoline = [[
local demo = require("combinator_demo")
local result = demo.run(ctx)
return result
]]

local prompt = string.format(
    [[
Run combinator_demo via alc_run. Call the alc_run MCP tool with:
- code: %q
- ctx: { task = %q, max_retries = %d }

The inline code does `require("combinator_demo").run(ctx)`. The
package's verdict_loop will call alc.llm at most max_retries+1 = 3
times. Each call returns status "needs_response" — answer via
alc_continue with your genuine answer to the task, wrapping the
numeric value in \boxed{...} (e.g. \boxed{42}). The package's
parser scans for `\boxed{` and short-circuits the retry loop as
soon as it sees it, so wrapping on the first attempt ends the loop
after 1 call. The canonical answer is 42.

When done, output one short report (under 100 words) containing
exactly these snake_case keys:
  ok, attempts, boxed
For example:
  ok=true, attempts=1, boxed=42
]],
    trampoline,
    params.task,
    params.max_retries
)

common.run({
    name = "combinator_demo",
    prompt = prompt,
    params = params,
    max_iterations = 15,
    graders = {
        common.grader_agent_ok(),
        common.grader_content_contains("42"),
        common.grader_max_turns(15),
        {
            name = "report_ok_true",
            check = function(result)
                if not result.ok then return false, "agent failed" end
                local c = (result.content or ""):lower()
                -- Accept either "ok=true" / "ok: true" / "ok true" framing.
                if c:find("ok", 1, true) and (c:find("true", 1, true) or c:find("=true", 1, true)) then
                    return true, nil
                end
                return false, "ok=true not clearly stated in content"
            end,
        },
        {
            name = "boxed_42",
            check = function(result)
                if not result.ok then return false, "agent failed" end
                local c = (result.content or ""):lower()
                -- Either "boxed=42" / "boxed: 42" / "boxed 42" in the report.
                if c:find("boxed", 1, true) and c:find("42", 1, true) then return true, nil end
                return false, "report did not include 'boxed' + '42'"
            end,
        },
    },
})
