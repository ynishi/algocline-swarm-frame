--- combinator_demo — minimal verdict_loop demo for swarm_frame.
---
--- A 1-pkg illustration of `swarm_frame.verdict_loop`: ask the LLM to
--- answer a task, retry when the response does not contain a
--- `\boxed{...}` marker. The parser is the only domain-aware piece
--- (Application policy); iteration and short-circuit live in the
--- Engine (mechanism).
---
--- Why a separate pkg: combinators are mechanism primitives, so the
--- usage shape is best demonstrated by a tiny consumer rather than
--- baked into a heavier algorithm pkg. Run paths:
---
---     just combinator-demo                # smoke (mock alc.llm)
---     just e2e combinator_demo            # real LLM via agent-block
---
--- Both drive `M.run({ task = ..., max_retries = N })`.

local M = {}

M.VERSION = "0.1.0"

M.meta = {
    name = "combinator_demo",
    version = "0.1.0",
    category = "frame_example",
    description = "Minimal verdict_loop demo: ask LLM for \\boxed{N}, retry on missing marker.",
}

local function require_string(v, name, fn)
    if type(v) ~= "string" or v == "" then
        error("combinator_demo." .. fn .. ": " .. name .. " (non-empty string) required, got " .. type(v), 3)
    end
end

local function require_pos_int(v, name, fn, default)
    if v == nil then return default end
    if type(v) ~= "number" or v < 1 or v ~= math.floor(v) then
        error("combinator_demo." .. fn .. ": " .. name .. " must be a positive integer, got " .. tostring(v), 3)
    end
    return v
end

--- Run a verdict_loop wrapping a single LLM gate.
---
--- @param opts {
---     task         : string,              -- REQUIRED
---     max_retries  : integer? (default 2),
---     alc          : table?  -- defaults to _G.alc; requires .llm,
---     frame        : table?  -- defaults to require("swarm_frame")
--- }
--- @return {
---     ok       : boolean,   -- final response contained \boxed{...}
---     attempts : integer,   -- number of gate invocations
---     response : string,    -- final raw LLM response
---     boxed    : string?    -- extracted value when ok
--- }
function M.run(opts)
    if type(opts) ~= "table" then error("combinator_demo.run: opts table required", 2) end
    require_string(opts.task, "task", "run")
    local max_retries = require_pos_int(opts.max_retries, "max_retries", "run", 2)

    local frame = opts.frame or require("swarm_frame")
    local alc = opts.alc or _G.alc
    if type(alc) ~= "table" or type(alc.llm) ~= "function" then
        error("combinator_demo.run: alc.llm function required (set _G.alc or pass opts.alc)", 2)
    end

    local attempts = 0

    local gate = function()
        attempts = attempts + 1
        local hint
        if attempts == 1 then
            hint = "Wrap your final numeric answer in \\boxed{...}."
        else
            hint = string.format(
                "Attempt %d: your previous answer did not contain \\boxed{...}. "
                    .. "Please wrap the number in \\boxed{...} this time.",
                attempts
            )
        end
        local prompt = string.format("Task: %s\n\n%s", opts.task, hint)
        return alc.llm(prompt)
    end

    local parser = function(response) return type(response) == "string" and response:find("\\boxed{", 1, true) ~= nil end

    local h = frame.verdict_loop({
        gate = gate,
        parser = parser,
        max_retries = max_retries,
    })

    local ctx = { state = frame.state_new() }
    local response = h(ctx)

    local boxed
    if type(response) == "string" then boxed = response:match("\\boxed{([^}]*)}") end

    return {
        ok = parser(response),
        attempts = attempts,
        response = response,
        boxed = boxed,
    }
end

return M
