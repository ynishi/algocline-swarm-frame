--- scripts/e2e/common.lua — agent-block E2E harness.
---
--- Drives agent-block's `agent.run()` ReAct loop against a spawned
--- `alc` MCP server, applies graders to the result, and persists the
--- full turn_history to `workspace/e2e-results/<run_id>/<name>.json`
--- for post-hoc inspection.
---
--- Each E2E script under scripts/e2e/ has the shape:
---     package.path = "scripts/e2e/?.lua;" .. package.path
---     local common = require("common")
---     common.run({
---         name    = "swarm_aggregate_dmad",
---         prompt  = "...",
---         graders = { ... },
---     })
---
--- Run via the justfile recipe:
---     just e2e swarm_aggregate_dmad
--- or directly:
---     agent-block -s scripts/e2e/swarm_aggregate_dmad.lua -p .
---
--- Patterned after algocline-bundled-packages/scripts/e2e/common.lua —
--- kept structurally identical so e2e scripts can be moved between
--- repos without rewriting the harness.

local M = {}

--- Default system prompt for ReAct-driven algocline E2E.
--- Tells the agent how to handle `alc_run` / `alc_advice` pause/resume.
M.DEFAULT_SYSTEM = [[You are an agent that orchestrates algocline package executions.
When alc_advice or alc_run returns status "needs_response", call alc_continue with:
- session_id: from the response
- query_id: from the response (if present)
- response: your genuine answer to the prompt

You ARE the LLM. Answer prompts thoughtfully and correctly.
For factual questions: give the correct answer concisely.
For extraction: return just the extracted value.
For JSON prompts: return valid JSON.
Be concise in the final report.]]

--- Default agent.run parameters.
M.DEFAULTS = {
    model = "claude-haiku-4-5-20251001",
    max_tokens = 4096,
    max_iterations = 20,
    max_tokens_budget = nil,
    mcp_servers = {
        { name = "algocline", command = "alc", args = {} },
    },
}

--- Directory where E2E results are persisted (relative to project root).
M.RESULTS_DIR = "workspace/e2e-results"

-- ─── Internal helpers ───────────────────────────────────────────────

local function timestamp()
    local t = os.date("*t")
    return string.format("%04d-%02d-%02d_%02d%02d%02d", t.year, t.month, t.day, t.hour, t.min, t.sec)
end

local function ensure_result_dir(run_id)
    local root = std.env.project_root and std.env.project_root() or "."
    local base = std.path.join(root, M.RESULTS_DIR)
    if not std.fs.exists(base) then std.fs.mkdir(base, { recursive = true }) end
    local run_dir = std.path.join(base, run_id)
    if not std.fs.exists(run_dir) then std.fs.mkdir(run_dir, { recursive = true }) end
    return run_dir
end

local function run_graders(result, graders)
    local report = {}
    for _, g in ipairs(graders or {}) do
        local ok, passed, msg = pcall(g.check, result)
        if not ok then
            report[#report + 1] = {
                name = g.name,
                passed = false,
                message = "grader error: " .. tostring(passed),
            }
        else
            report[#report + 1] = {
                name = g.name,
                passed = passed == true,
                message = msg,
            }
        end
    end
    return report
end

local function write_result(run_dir, name, result, grader_report, meta)
    local path = std.path.join(run_dir, name .. ".json")
    local payload = {
        name = name,
        timestamp = meta.timestamp,
        ok = result.ok,
        content = result.content,
        error = result.error,
        num_turns = result.num_turns,
        usage = result.usage,
        turn_history = result.turn_history,
        graders = grader_report,
        params = meta.params,
    }
    std.fs.write(path, std.json.encode(payload, { pretty = true }))
    return path
end

-- ─── Main entry ─────────────────────────────────────────────────────

---@class E2EOpts
---@field name string — unique id for this E2E (used for file naming)
---@field prompt string — user prompt driving the ReAct agent
---@field graders table[] — list of { name, check = function(result) -> passed, msg }
---@field system? string — override default system prompt
---@field model? string — override default model
---@field max_tokens? integer — per-request output cap (default 4096)
---@field max_tokens_budget? integer — cumulative budget across all turns (default nil = unlimited)
---@field max_iterations? integer
---@field mcp_servers? table[]
---@field params? table — arbitrary params to record alongside the result

---@param opts E2EOpts
---@return { ok: boolean, result: table, graders: table[], result_path: string }
function M.run(opts)
    assert(type(opts.name) == "string", "E2E: opts.name required")
    assert(type(opts.prompt) == "string", "E2E: opts.prompt required")

    local agent = require("agent")

    local ts = timestamp()
    local run_dir = ensure_result_dir(ts)

    log.info(string.format("=== E2E: %s (run_id=%s) ===", opts.name, ts))

    -- Per-turn capture: ground-truth MCP tool_calls / tool_responses.
    local turn_history = {}

    local agent_opts = {
        prompt = opts.prompt,
        system = opts.system or M.DEFAULT_SYSTEM,
        model = opts.model or M.DEFAULTS.model,
        max_tokens = opts.max_tokens or M.DEFAULTS.max_tokens,
        max_tokens_budget = opts.max_tokens_budget or M.DEFAULTS.max_tokens_budget,
        max_iterations = opts.max_iterations or M.DEFAULTS.max_iterations,
        mcp_servers = opts.mcp_servers or M.DEFAULTS.mcp_servers,
        on_turn = function(info)
            log.info(
                string.format(
                    "Turn %d: %d tool calls, tokens: %d in / %d out",
                    info.turn_number,
                    #info.tool_calls,
                    info.usage and info.usage.input_tokens or 0,
                    info.usage and info.usage.output_tokens or 0
                )
            )
            turn_history[#turn_history + 1] = {
                turn_number = info.turn_number,
                tool_calls = info.tool_calls,
                tool_responses = info.tool_responses,
                usage = info.usage,
            }
        end,
    }

    local start_ms = std.time.now()
    local result = agent.run(agent_opts)
    local elapsed_ms = std.time.now() - start_ms

    log.info(
        string.format(
            "Agent finished: ok=%s, turns=%d, tokens=%d, elapsed=%.1fs",
            tostring(result.ok),
            result.num_turns or 0,
            result.usage and result.usage.total_tokens or 0,
            elapsed_ms / 1000
        )
    )

    result.turn_history = turn_history

    local grader_report = run_graders(result, opts.graders)

    local all_passed = true
    for _, gr in ipairs(grader_report) do
        if not gr.passed then all_passed = false end
    end

    log.info(string.format("=== E2E %s: %s ===", opts.name, all_passed and "PASS" or "FAIL"))
    for _, gr in ipairs(grader_report) do
        log.info(
            string.format(
                "  [%s] %s%s",
                gr.passed and "PASS" or "FAIL",
                gr.name,
                gr.message and (" — " .. gr.message) or ""
            )
        )
    end

    local result_path = write_result(run_dir, opts.name, result, grader_report, {
        timestamp = ts,
        params = opts.params,
    })
    log.info("Result saved: " .. result_path)

    return {
        ok = all_passed,
        result = result,
        graders = grader_report,
        result_path = result_path,
    }
end

-- ─── Grader helpers ─────────────────────────────────────────────────

function M.grader_agent_ok()
    return {
        name = "agent_ok",
        check = function(result)
            if result.ok then return true, nil end
            return false, "agent failed: " .. (result.error or "unknown")
        end,
    }
end

function M.grader_content_contains(needle, name)
    return {
        name = name or ("content_contains:" .. needle),
        check = function(result)
            if not result.ok then return false, "agent did not complete" end
            local content = result.content or ""
            if content:find(needle, 1, true) then return true, nil end
            return false, string.format("content did not contain %q", needle)
        end,
    }
end

function M.grader_max_turns(limit)
    return {
        name = "max_turns:" .. tostring(limit),
        check = function(result)
            local t = result.num_turns or 0
            if t <= limit then return true, nil end
            return false, string.format("turns=%d > %d", t, limit)
        end,
    }
end

function M.grader_max_tokens(limit)
    return {
        name = "max_tokens:" .. tostring(limit),
        check = function(result)
            local total = result.usage and result.usage.total_tokens or 0
            if total <= limit then return true, nil end
            return false, string.format("tokens=%d > %d", total, limit)
        end,
    }
end

--- Search the agent's turn_history for a raw MCP tool_response that
--- contains all of the given required substrings (typically pkg result
--- field names). Returns the matched response text or nil.
---
--- Why: in principle the raw tool_response from `alc_run` / `alc_advice`
--- carries the pkg result verbatim, which would be the strict path for
--- structural graders.
---
--- !!! Current agent-block limitation (observed 2026-05-16) !!!
--- agent-block's `on_turn` callback exposes only `turn_number` /
--- `tool_calls` / `usage` — `tool_responses` is **never populated**.
--- So this helper currently **always returns nil** for e2e runs under
--- agent-block. Graders must rely on the agent's `content` text as the
--- authoritative post-hoc signal (case-insensitive matching on both
--- snake_case pkg keys AND Title-Case English paraphrases). The
--- function is kept in shape so it works the moment upstream
--- agent-block fixes the on_turn payload — no caller migration needed.
function M.find_raw_tool_response(result, required_keys)
    local hist = result and result.turn_history
    if type(hist) ~= "table" then return nil end
    for _, turn in ipairs(hist) do
        local resps = turn.tool_responses
        if type(resps) == "table" then
            for _, r in ipairs(resps) do
                local text
                if type(r) == "string" then
                    text = r
                elseif type(r) == "table" then
                    text = r.content or r.text or r.body
                    if type(text) == "table" then
                        local parts = {}
                        for _, sub in ipairs(text) do
                            if type(sub) == "table" and type(sub.text) == "string" then
                                parts[#parts + 1] = sub.text
                            elseif type(sub) == "string" then
                                parts[#parts + 1] = sub
                            end
                        end
                        text = table.concat(parts, "\n")
                    end
                end
                if type(text) == "string" then
                    local all = true
                    for _, key in ipairs(required_keys) do
                        if not text:find(key, 1, true) then
                            all = false
                            break
                        end
                    end
                    if all then return text end
                end
            end
        end
    end
    return nil
end

return M
