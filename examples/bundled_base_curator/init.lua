--- bundled_base_curator — swarm-frame example.
---
--- Reference implementation of a 6-step base-package curation
--- pipeline (window → themes → fingerprint → researcher → vetter →
--- report-writer), built on swarm_frame and swarm_frame_algocline.
--- Used as the worked example for the design-doc Roadmap §4
--- measurements.
---
--- Public surface:
---   - M.parse_verdict(response)   — verdict-form parsing (frame re-export)
---   - M.build_prompt(step, state) — instruction assembly (frame re-export)
---   - M.phases                    — { id, subagent } table
---   - M.run(ctx)                  — pipeline entry point
---
--- Both `parse_verdict` and `build_prompt` delegate into the frame so
--- that downstream consumers are one re-export, not a re-implementation.

local flow    = require("flow")
local frame   = require("swarm_frame")
local adapter = require("swarm_frame_algocline")

local M = {}

M.meta = {
    name        = "bundled_base_curator",
    version     = "0.1.0",
    description = "swarm-frame example: 6-step base package curation pipeline "
        .. "(window-inferrer → theme-inferrer → corpus-fingerprint → "
        .. "domain-researcher → bundled-base-vetter → report-writer).",
    category    = "example",
}

-- ─── Phase table (orch convention data, identical shape to v0.2.0) ───────────

M.phases = {
    { id = "step_1", subagent = "window-inferrer" },
    { id = "step_2", subagent = "theme-inferrer" },
    { id = "step_3", subagent = "corpus-fingerprint" },
    { id = "step_4", subagent = "domain-researcher" },
    { id = "step_5", subagent = "bundled-base-vetter" },
    { id = "step_6", subagent = "report-writer" },
}

-- ─── Agent Type Map ──────────────────────────────────────────────────────────

local AGENT_TYPE_MAP = {
    ["@window-inferrer"]     = "window-inferrer",
    ["@theme-inferrer"]      = "theme-inferrer",
    ["@corpus-fingerprint"]  = "corpus-fingerprint",
    ["@domain-researcher"]   = "domain-researcher",
    ["@bundled-base-vetter"] = "bundled-base-vetter",
    ["@report-writer"]       = "report-writer",
}

-- ─── Instruction Builder (10 prompt sections) ────────────────────────────────

local function build_instruction(phase_id, spec)
    local lines = {}
    lines[#lines + 1] = "=== STEP: " .. phase_id .. " ==="
    lines[#lines + 1] = ""

    local agent_type = spec.agent and AGENT_TYPE_MAP[spec.agent]
    if agent_type then
        lines[#lines + 1] = 'Spawn: Agent(subagent_type="' .. agent_type .. '")'
    else
        lines[#lines + 1] = "Direct (main thread, no subagent)"
    end
    lines[#lines + 1] = ""

    if spec.task_dir then
        lines[#lines + 1] = "Task Dir: " .. spec.task_dir
        lines[#lines + 1] = ""
    end

    lines[#lines + 1] = "Phase: " .. phase_id
    lines[#lines + 1] = ""

    if spec.prompt then
        lines[#lines + 1] = "Instructions:"
        lines[#lines + 1] = spec.prompt
        lines[#lines + 1] = ""
    end

    if spec.inputs and #spec.inputs > 0 then
        lines[#lines + 1] = "Inputs:"
        for _, f in ipairs(spec.inputs) do
            lines[#lines + 1] = "  - " .. f
        end
        lines[#lines + 1] = ""
    end

    if spec.outputs and #spec.outputs > 0 then
        lines[#lines + 1] = "Output:"
        for _, f in ipairs(spec.outputs) do
            lines[#lines + 1] = "  - " .. f
        end
        lines[#lines + 1] = ""
    end

    if spec.output_format then
        lines[#lines + 1] = "Output Format:"
        lines[#lines + 1] = spec.output_format
        lines[#lines + 1] = ""
    end

    if spec.gate then
        lines[#lines + 1] = "Quality Gate:"
        lines[#lines + 1] = spec.gate
        lines[#lines + 1] = ""
    end

    local report = spec.report_back
        or "DONE path=<output> or BLOCKED reason=<text> or NEEDS_INPUT missing=<path> (<=1 line)"
    lines[#lines + 1] = "Report: " .. report

    return table.concat(lines, "\n")
end

-- ─── Per-step spec builders (state-driven, lazy) ─────────────────────────────
--
-- Each builder receives the plain-state view (`state.task_dir`-style
-- access) and returns the spec table that the instruction-builder
-- and the algocline dispatcher consume. Registering builders rather
-- than pre-baked tables lets the frame resolve specs at dispatch
-- time, so a resumed pipeline sees the live task_dir.

local function spec_step_1(state)
    local out = state.task_dir .. "/window.json"
    return {
        agent    = "@window-inferrer",
        task_dir = state.task_dir,
        prompt   = "Read packages/ commit and publication metadata to infer the observation window. "
            .. "Write the result as JSON to " .. out .. ". "
            .. "See your Agent .md for the detailed procedure.",
        outputs  = { out },
        output_format = 'JSON object: { "start": "YYYY-MM", "end": "YYYY-MM" }.',
        gate     = "BLOCKED if window.start or window.end is absent. "
            .. "BLOCKED if start or end does not match ^\\d{4}-\\d{2}$. "
            .. "BLOCKED if start > end (lexicographic).",
        report_back = "DONE path=window.json | BLOCKED reason=<text>",
    }
end

local function spec_step_2(state)
    local out = state.task_dir .. "/themes.json"
    return {
        agent    = "@theme-inferrer",
        task_dir = state.task_dir,
        prompt   = "Read packages/ domain tags and README signals to infer dominant themes. "
            .. "Write the result as JSON to " .. out .. ". "
            .. "See your Agent .md for the detailed procedure.",
        inputs   = { state.task_dir .. "/window.json" },
        outputs  = { out },
        output_format = 'JSON object: { "tags": ["tag1", "tag2", ...] }.',
        gate     = "BLOCKED if tags array is absent or empty (must contain >= 1 tag). "
            .. "BLOCKED if any tag does not match ^[a-z][a-z0-9-]{1,48}$.",
        report_back = "DONE path=themes.json | BLOCKED reason=<text>",
    }
end

local function spec_step_3(state)
    local out = state.task_dir .. "/fingerprint.json"
    return {
        agent    = "@corpus-fingerprint",
        task_dir = state.task_dir,
        prompt   = "Enumerate packages/ by stable identifier (arXiv ID or canonical repo URL). "
            .. "Write the result as JSON to " .. out .. ". "
            .. "Do NOT skip this step even if the corpus appears empty. "
            .. "See your Agent .md for the detailed procedure.",
        outputs  = { out },
        output_format = 'JSON object: { "ids": [...], "count": N } where count == ids.length and ids contains no duplicates.',
        gate     = "BLOCKED if ids is absent or not a JSON array. "
            .. "BLOCKED if count != ids.length. "
            .. "BLOCKED if ids contains duplicate entries. "
            .. "BLOCKED if this step is skipped or fingerprint.json is not written (Crux 3: emit skip is forbidden).",
        report_back = "DONE path=fingerprint.json | BLOCKED reason=<text> | NEEDS_INPUT missing=<path>",
    }
end

local function spec_step_4(state)
    local out = state.task_dir .. "/candidates-raw.json"
    return {
        agent    = "@domain-researcher",
        task_dir = state.task_dir,
        prompt   = "Execute structured WebSearch/WebFetch queries using window.json, themes.json, "
            .. "and fingerprint.json as read-only config. "
            .. "Write raw candidate packages to " .. out .. ". "
            .. "Do not re-derive config from packages/; use the provided JSON files. "
            .. "See your Agent .md for the detailed procedure.",
        inputs   = {
            state.task_dir .. "/window.json",
            state.task_dir .. "/themes.json",
            state.task_dir .. "/fingerprint.json",
        },
        outputs  = { out },
        output_format = "JSON array of objects: each record must have id, date, domain, snippet (all non-empty). "
            .. "0 or more records are valid.",
        gate     = "BLOCKED if any record is missing id, date, domain, or snippet. "
            .. "BLOCKED if open-ended queries are used without window/themes constraints. "
            .. "BLOCKED if fingerprint.json is absent (report NEEDS_INPUT missing=fingerprint.json).",
        report_back = "DONE path=candidates-raw.json | BLOCKED reason=<text> | NEEDS_INPUT missing=<path>",
    }
end

local function spec_step_5(state)
    local out      = state.task_dir .. "/pass-bucket.json"
    local out_fail = state.task_dir .. "/fail-bucket.json"
    return {
        agent    = "@bundled-base-vetter",
        task_dir = state.task_dir,
        prompt   = "Apply G1 (recency), G2 (theme alignment), and G3 (corpus-diff) gates sequentially "
            .. "to each candidate in candidates-raw.json. "
            .. "Write passing candidates to " .. out .. " and failing candidates to " .. out_fail .. ". "
            .. "No WebSearch or WebFetch permitted. "
            .. "See your Agent .md for the detailed procedure.",
        inputs   = {
            state.task_dir .. "/candidates-raw.json",
            state.task_dir .. "/window.json",
            state.task_dir .. "/themes.json",
            state.task_dir .. "/fingerprint.json",
        },
        outputs  = { out, out_fail },
        output_format = "Two JSON arrays: pass-bucket.json (candidates passing all gates) and "
            .. "fail-bucket.json (candidates failing at least one gate, with gate label).",
        gate     = "BLOCKED if WebSearch or WebFetch was performed. "
            .. "BLOCKED if pass count + fail count != input candidate count (count reconciliation). "
            .. "BLOCKED if fingerprint.json is absent (report NEEDS_INPUT missing=fingerprint.json). "
            .. "G3 (corpus-diff) axis must consume fingerprint.json; skipping G3 or substituting a static list is forbidden.",
        report_back = "DONE path=pass-bucket.json | BLOCKED reason=<text> | NEEDS_INPUT missing=<path>",
    }
end

local function spec_step_6(state)
    local out = state.task_dir .. "/report.md"
    return {
        agent    = "@report-writer",
        task_dir = state.task_dir,
        prompt   = "Consume pass-bucket.json, fail-bucket.json, window.json, themes.json, and fingerprint.json "
            .. "to write the final curation report to " .. out .. ". "
            .. "See your Agent .md for the detailed procedure.",
        inputs   = {
            state.task_dir .. "/pass-bucket.json",
            state.task_dir .. "/fail-bucket.json",
            state.task_dir .. "/window.json",
            state.task_dir .. "/themes.json",
            state.task_dir .. "/fingerprint.json",
        },
        outputs  = { out },
        output_format = "Markdown with exactly 4 H2 sections in fixed order: "
            .. "## Curation Context, ## Candidates, ## Vetted Out, ## Corpus Gap Summary. "
            .. "Words 'recent' and 'latest' are forbidden. "
            .. "No Lua artifact references (init.lua, M.meta, M.spec, alc_shapes.T). "
            .. "No hypothesis.md output.",
        gate     = "BLOCKED if any of the 4 H2 sections is missing or out of order. "
            .. "BLOCKED if pass count in ## Candidates does not match pass-bucket.json entry count. "
            .. "BLOCKED if fail count in ## Vetted Out does not match fail-bucket.json entry count. "
            .. "BLOCKED if 'recent' or 'latest' appears in the report. "
            .. "BLOCKED if hypothesis.md is written as a side effect.",
        report_back = "DONE path=report.md | BLOCKED reason=<text>",
    }
end

-- ─── Path / step registration ────────────────────────────────────────────────

local PATHS = {
    "/bundled-base-curator/step_1/window-inferrer",
    "/bundled-base-curator/step_2/theme-inferrer",
    "/bundled-base-curator/step_3/corpus-fingerprint",
    "/bundled-base-curator/step_4/domain-researcher",
    "/bundled-base-curator/step_5/bundled-base-vetter",
    "/bundled-base-curator/step_6/report-writer",
}

local SPEC_BUILDERS = {
    step_1 = spec_step_1, step_2 = spec_step_2, step_3 = spec_step_3,
    step_4 = spec_step_4, step_5 = spec_step_5, step_6 = spec_step_6,
}

local STEP_TO_PATH = {}
for _, p in ipairs(PATHS) do
    STEP_TO_PATH[frame.step_id_of(p)] = p
end

local function register_steps()
    for _, p in ipairs(PATHS) do
        frame.register(p, SPEC_BUILDERS[frame.step_id_of(p)])
    end
end

M.register_steps = register_steps
M.PATHS          = PATHS
M.SPEC_BUILDERS  = SPEC_BUILDERS
M.STEP_TO_PATH   = STEP_TO_PATH

-- ─── Orch-convention public surface ──────────────────────────────────────────
--
-- Re-exports rather than re-implementations. Keeping these as thin
-- shims means every orch on swarm-frame inherits the same verdict /
-- prompt-assembly behaviour without copy-pasting the logic.

M.parse_verdict = frame.parse_verdict

function M.build_prompt(step, state)
    local path = STEP_TO_PATH[step]
    if not path then
        error("bundled_base_curator: unknown step=" .. tostring(step))
    end
    return frame.build_step_instruction(path, state, build_instruction)
end

-- ─── Pipeline entry point ────────────────────────────────────────────────────

function M.run(ctx)
    local task_dir = ctx.task_dir or error("ctx.task_dir is required")
    local task_id  = ctx.task_id  or "bundled-base-curator"

    -- algocline flow state for the Token & Prompt round-trip resume cue
    -- (consumed by flow.llm_bound inside the adapter).
    local st = flow.state_new(ctx, {
        key_prefix = "bundled_base_curator_example",
        id         = task_id,
        identity   = { task_id = task_id },
    })

    local fs = frame.state_new()
    fs:set("task_id", task_id)
    fs:set("task_dir", task_dir)

    register_steps()

    ctx.state = fs
    ctx.dispatcher = adapter.make_dispatcher({
        builder  = build_instruction,
        state    = st,
        llm_opts = {
            system     = "Curation orchestrator. Follow the Spawn directive exactly. "
                .. "Write only to paths listed under Output. Return a single verdict line.",
            max_tokens = 500,
        },
    })

    if alc and alc.log then
        alc.log("info", "bundled_base_curator: start task_dir=" .. task_dir)
    end

    frame.run_linear(PATHS, ctx)
    return ctx
end

return M
