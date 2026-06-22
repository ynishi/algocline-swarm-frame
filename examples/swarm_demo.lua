--- examples/swarm_demo.lua — smoke for swarm_demo (mock alc.llm).
---
--- Drives swarm_demo.run() with a deterministic mock LLM that returns
--- canned responses for the 3 roles (Researcher / Drafter / Reviewer)
--- in order. Proves the 3-Agent linear pipeline + prompt threading
--- without any external dependency.
---
--- Run from the repo root (no API key needed):
---     lua examples/swarm_demo.lua
---     just swarm-demo

package.path = "./packages/?/init.lua;./packages/?.lua;"
    .. (os.getenv("HOME") or "")
    .. "/.algocline/packages/?/init.lua;"
    .. (os.getenv("HOME") or "")
    .. "/.algocline/packages/?.lua;"
    .. package.path

-- ── Mock alc.llm ────────────────────────────────────────────────────
-- 1st call (Researcher): 3 bullets
-- 2nd call (Drafter):    2-3 sentence draft + sentinel
-- 3rd call (Reviewer):   one-line OK/NG verdict
local call_log = {}
local function mock_llm(prompt, _opts)
    table.insert(call_log, { len = #prompt, head = prompt:sub(1, 80) })
    if #call_log == 1 then
        return "- Photosynthesis converts light to chemical energy.\n"
            .. "- It happens in chloroplasts.\n"
            .. "- It releases oxygen as a byproduct."
    elseif #call_log == 2 then
        return "Photosynthesis is the process plants use to convert sunlight "
            .. "into chemical energy stored as glucose, taking place in "
            .. "chloroplasts and releasing oxygen as a byproduct.\n"
            .. "SWARM_DEMO_END"
    else
        return "OK: covers the conversion, location, and oxygen byproduct."
    end
end
_G.alc = _G.alc or {}
_G.alc.llm = mock_llm
_G.alc.log = _G.alc.log or function() end
_G.alc.json_decode = _G.alc.json_decode or function() return {} end

-- ── Run ─────────────────────────────────────────────────────────────

local demo = require("swarm_demo")
local result = demo.run({
    task = "Briefly explain photosynthesis.",
})

-- ── Report ──────────────────────────────────────────────────────────

print(string.format("ok=%s verdict=%s total_calls=%d",
    tostring(result.ok), result.verdict, #call_log))
print("--- Researcher output ---")
print(result.research)
print("--- Drafter output ---")
print(result.draft)
print("--- Reviewer output ---")
print(result.review)
print("--- prompt calls ---")
for i, c in ipairs(call_log) do
    print(string.format("  [%d] len=%d head=%q", i, c.len, c.head))
end

-- ── Assertions ──────────────────────────────────────────────────────

assert(result.ok == true, "expected ok=true, got " .. tostring(result.ok))
assert(result.verdict == "OK", "expected verdict=OK, got " .. result.verdict)
assert(#call_log == 3, "expected 3 mock calls, got " .. #call_log)
assert(result.research:find("chloroplasts", 1, true),
    "expected research to mention chloroplasts")
assert(result.draft:find("SWARM_DEMO_END", 1, true),
    "expected draft to end with SWARM_DEMO_END")
assert(result.review:find("OK:", 1, true),
    "expected review to start with OK:")

print("PASS: swarm_demo smoke (3-Agent linear: Researcher → Drafter → Reviewer, mock LLM)")
