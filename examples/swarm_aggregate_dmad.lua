--- examples/swarm_aggregate_dmad.lua
---
--- Smoke run for swarm_aggregate_plugin.run_dmad with a mock alc.llm.
--- Drives the dispatcher through the dmad N×(R+1) loop using the pure
--- helpers (build_init_prompt / build_debate_prompt / extract_boxed /
--- aggregate_majority) imported from the dmad pkg.
---
--- Run from the repo root:
---     lua examples/swarm_aggregate_dmad.lua
---
--- Requires that algocline-bundled-packages is reachable on the Lua
--- path (the script auto-adds the sibling repo directory if it exists).

-- ── Path setup ──────────────────────────────────────────────────────
-- Assumes invocation from the algocline-swarm-frame repo root with
-- algocline-bundled-packages as a sibling directory:
--     ~/projects/algocline-swarm-frame/    ← cwd
--     ~/projects/algocline-bundled-packages/

package.path = "./packages/?/init.lua;./packages/?.lua;" ..
               "../algocline-bundled-packages/?/init.lua;" ..
               "../algocline-bundled-packages/?.lua;" ..
               package.path

-- ── Mock alc.llm ────────────────────────────────────────────────────
-- Deterministic responder: returns "\boxed{42}" for round 0 agents 1
-- and 3, "\boxed{43}" for agent 2, then has every agent converge on
-- "\boxed{42}" by the final round so the majority vote is unambiguous.
-- This is enough to prove the dispatcher → builder → mock alc.llm →
-- recorder plugin → aggregator chain end-to-end.

local call_log = {}
local function mock_llm(prompt, llm_opts)
    table.insert(call_log, { prompt = prompt, opts = llm_opts })
    -- Pull (agent, round) hints out of the prompt prefix the orch
    -- doesn't pass them directly to alc.llm; sniff from prompt body.
    -- We don't actually need them for routing here, just emit a
    -- plausible boxed answer.
    local n = #call_log
    -- First-round divergence, later-round convergence.
    if n <= 3 then
        if n == 2 then return "let's try \\boxed{43}" end
        return "trying \\boxed{42}"
    end
    return "after debate, \\boxed{42}"
end

_G.alc = _G.alc or {}
_G.alc.llm = mock_llm

-- ── Run ─────────────────────────────────────────────────────────────

local frame  = require("swarm_frame")
frame.init({ check_mode = "non-check" })

local plugin = require("swarm_aggregate_plugin")

local result = plugin.run_dmad({
    task     = "What is the answer to life, the universe, and everything?",
    n_agents = 3,
    n_rounds = 2,
})

-- ── Report ──────────────────────────────────────────────────────────

print(string.format(
    "answer=%s  n_agents=%d  n_rounds=%d  total_llm_calls=%d",
    tostring(result.answer),
    result.n_agents,
    result.n_rounds,
    result.total_llm_calls
))

print("last_answers:")
for i, a in ipairs(result.last_answers) do
    print(string.format("  agent %d: %s", i, tostring(a)))
end

print("tally:")
for _, row in ipairs(result.tally) do
    print(string.format("  %-6s -> count=%d", tostring(row.answer), row.count))
end

print(string.format(
    "transcript: %d entries  (mock LLM was called %d times)",
    #result.transcript, #call_log
))
print("first transcript entry:  agent="
    .. tostring(result.transcript[1].agent)
    .. " round=" .. tostring(result.transcript[1].round)
    .. " step=" .. tostring(result.transcript[1].step))
print("last  transcript entry:  agent="
    .. tostring(result.transcript[#result.transcript].agent)
    .. " round=" .. tostring(result.transcript[#result.transcript].round)
    .. " step=" .. tostring(result.transcript[#result.transcript].step))

-- ── Assertion ───────────────────────────────────────────────────────
-- N + N*R = 3 + 3*2 = 9 calls expected.
assert(result.total_llm_calls == 9,
    "expected 9 LLM calls (N=3, R=2 -> N*(R+1)), got "
    .. tostring(result.total_llm_calls))
assert(result.answer == "42",
    "expected majority '42', got " .. tostring(result.answer))

print("PASS: swarm_aggregate_plugin.run_dmad smoke")
