--- examples/combinator_demo.lua — smoke for combinator_demo (mock alc.llm).
---
--- Drives combinator_demo.run() with a deterministic mock LLM that returns
--- an UNBOXED answer for the first two attempts and a `\boxed{42}`
--- response on the third. Proves the verdict_loop retries until parser
--- passes and short-circuits as soon as it does.
---
--- Run from the repo root (no API key needed):
---     lua examples/combinator_demo.lua
---     just combinator-demo

package.path = "./packages/?/init.lua;./packages/?.lua;"
    .. (os.getenv("HOME") or "")
    .. "/.algocline/packages/?/init.lua;"
    .. (os.getenv("HOME") or "")
    .. "/.algocline/packages/?.lua;"
    .. package.path

-- ── Mock alc.llm ────────────────────────────────────────────────────
-- First 2 calls: unboxed (verdict_loop should retry).
-- 3rd call: boxed (parser passes, loop exits).
local call_log = {}
local function mock_llm(prompt)
    table.insert(call_log, { len = #prompt, head = prompt:sub(1, 60) })
    if #call_log < 3 then return "I think the answer is 42, but forgot the wrap." end
    return "After consideration, the answer is \\boxed{42}."
end
_G.alc = _G.alc or {}
_G.alc.llm = mock_llm

-- ── Run ─────────────────────────────────────────────────────────────

local frame = require("swarm_frame")
frame.init({ check_mode = "non-check" })

local demo = require("combinator_demo")
local result = demo.run({
    task = "What is the answer to life, the universe, and everything?",
    max_retries = 3,
})

-- ── Report ──────────────────────────────────────────────────────────

print(
    string.format(
        "ok=%s attempts=%d boxed=%s total_calls=%d",
        tostring(result.ok),
        result.attempts,
        tostring(result.boxed),
        #call_log
    )
)
print("calls:")
for i, c in ipairs(call_log) do
    print(string.format("  [%d] len=%d head=%q", i, c.len, c.head))
end

-- ── Assertions ──────────────────────────────────────────────────────

assert(result.ok == true, "expected ok=true, got " .. tostring(result.ok))
assert(result.attempts == 3, "expected attempts=3, got " .. tostring(result.attempts))
assert(result.boxed == "42", "expected boxed='42', got " .. tostring(result.boxed))
assert(#call_log == 3, "expected 3 mock calls, got " .. tostring(#call_log))

print("PASS: combinator_demo smoke (verdict_loop with mock LLM, retry-on-missing-boxed)")
