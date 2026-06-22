--- combinator_demo — minimal verdict_loop pattern demo.
---
--- A 1-pkg illustration of the verdict_loop pattern: ask the LLM to
--- answer a task, retry when the response does not contain a
--- `\boxed{...}` marker. The parser is the only domain-aware piece
--- (Application policy); iteration and short-circuit are illustrated
--- via an inline `for` loop (Engine mechanism).
---
--- V3 P8 Phase 4 reframe (2026-06-22): 旧 swarm_frame.verdict_loop
--- (combinators.lua re-export、 handler form `h(ctx) -> response`) は
--- V3 で撤去済。 V3 では composites/verdict_loop.lua が IR Node form
--- (`build(opts) -> Node`、 swarm.run 経由実行) で同等機能を提供する
--- が、 educational demo として IR + dispatcher setup boilerplate を
--- 避け、 inline for loop で「verdict_loop pattern」 を直接 illustrate
--- する path に書直し済。 swarm_frame dependency 完全 drop。
---
--- Run paths:
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

--- Run a verdict_loop wrapping a single LLM gate (inline for-loop form).
---
--- @param opts {
---     task         : string,              -- REQUIRED
---     max_retries  : integer? (default 2),
---     alc          : table?  -- defaults to _G.alc; requires .llm
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

    local alc = opts.alc or _G.alc
    if type(alc) ~= "table" or type(alc.llm) ~= "function" then
        error("combinator_demo.run: alc.llm function required (set _G.alc or pass opts.alc)", 2)
    end

    local parser = function(response)
        return type(response) == "string" and response:find("\\boxed{", 1, true) ~= nil
    end

    -- Inline verdict_loop pattern: retry up to max_retries+1 times until
    -- parser returns true. V3 P8 Phase 4 reframe (旧 frame.verdict_loop
    -- handler form 撤去、 V3 IR-based composite は dispatcher setup 重く
    -- educational demo に不適、 inline for loop が cleanest)。
    local attempts = 0
    local response
    local ok = false
    for attempt = 1, max_retries + 1 do
        attempts = attempt
        local hint
        if attempt == 1 then
            hint = "Wrap your final numeric answer in \\boxed{...}."
        else
            hint = string.format(
                "Attempt %d: your previous answer did not contain \\boxed{...}. "
                    .. "Please wrap the number in \\boxed{...} this time.",
                attempt
            )
        end
        local prompt = string.format("Task: %s\n\n%s", opts.task, hint)
        response = alc.llm(prompt)
        if parser(response) then
            ok = true
            break
        end
    end

    local boxed
    if type(response) == "string" then boxed = response:match("\\boxed{([^}]*)}") end

    return {
        ok = ok,
        attempts = attempts,
        response = response,
        boxed = boxed,
    }
end

return M
