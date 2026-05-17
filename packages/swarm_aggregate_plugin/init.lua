--- swarm_aggregate_plugin — Swarm aggregate plugin for swarm_frame.
---
--- Bridges Swarm-style multi-agent aggregation packages
--- (algocline-bundled-packages: dmad / moa / reconcile, ...) onto
--- `swarm_frame_algocline.make_dispatcher`.
---
--- The bundled pkgs each export their algorithm as `M.run(ctx)` plus a
--- handful of LLM-independent pure helpers
--- (`build_*_prompt` / `extract_*` / `aggregate_*`). This plugin reuses
--- those helpers but **routes every LLM call through the dispatcher**
--- so the Frame's plugin chain (before / around / after / finalize)
--- and its check_mode-aware routing primitive (route_llm) own the
--- round-trip discipline.
---
--- Initial release (v0.1.0): dmad only. moa / reconcile / hegelian
--- extension is anticipated under the same `M.run_<pkg>(opts)`
--- convention but not yet implemented — the survey
--- (workspace/tasks/swarm-plugin-survey/pkg-survey.md) covers the shape.

local M = {}

M.VERSION = "0.1.0"

M.meta = {
    name = "swarm_aggregate_plugin",
    version = "0.1.0",
    category = "frame_plugin",
    description = "Swarm aggregate plugin bridging dmad / moa / reconcile "
        .. "to swarm_frame_algocline.make_dispatcher (initial: dmad only).",
}

-- ─── helpers ────────────────────────────────────────────────────────

local function require_string(v, name, fn)
    if type(v) ~= "string" or v == "" then
        error("swarm_aggregate_plugin." .. fn .. ": " .. name .. " (non-empty string) required, got " .. type(v), 3)
    end
end

local function require_pos_int(v, name, fn, default)
    if v == nil then return default end
    if type(v) ~= "number" or v < 1 or v ~= math.floor(v) then
        error("swarm_aggregate_plugin." .. fn .. ": " .. name .. " must be a positive integer, got " .. tostring(v), 3)
    end
    return v
end

-- ─── dmad runner ────────────────────────────────────────────────────

--- Run dmad (Du 2023 Multi-Agent Debate) through the dispatcher.
---
--- @param opts table {
---     task          : string,                              -- REQUIRED
---     n_agents      : integer? (default 3)                 -- (L)
---     n_rounds      : integer? (default 2)                 -- (L)
---     gen_tokens    : integer? (default 500)               -- (X)
---     temperature   : number?                              -- (X)
---     init_prompt   : string?  -- override dmad init template (X)
---     debate_prompt : string?  -- override dmad debate template (X)
---     system_prompt : string?  -- override dmad system prompt (X)
---     extract_fn    : function? -- override extract_boxed (X)
---     -- Frame wiring:
---     frame         : table?   -- defaults to require("swarm_frame")
---     sfa           : table?   -- defaults to require("swarm_frame_algocline")
---     dmad          : table?   -- defaults to require("dmad")
---     state         : table?   -- defaults to a fresh frame.state_new()
---     alc           : table?   -- defaults to _G.alc; required at LLM time
---     extra_plugins : table[]? -- additional dispatcher plugins (prepended)
--- }
--- @return table {
---     answer          : string,
---     n_agents, n_rounds, total_llm_calls,
---     responses       : string[][],          -- responses[r+1][i]
---     last_answers    : string[],
---     tally           : table,               -- dmad.aggregate_majority tally
---     transcript      : { agent, round, text, prompt, step }[],
--- }
function M.run_dmad(opts)
    if type(opts) ~= "table" then error("swarm_aggregate_plugin.run_dmad: opts table required", 2) end
    require_string(opts.task, "task", "run_dmad")

    local frame = opts.frame or require("swarm_frame")
    local sfa = opts.sfa or require("swarm_frame_algocline")
    local dmad = opts.dmad or require("dmad")

    local n_agents = require_pos_int(opts.n_agents, "n_agents", "run_dmad", 3)
    local n_rounds = require_pos_int(opts.n_rounds, "n_rounds", "run_dmad", 2)
    local extract_fn = opts.extract_fn or function(text) return dmad.extract_boxed({ text = text }) end

    local state = opts.state or frame.state_new()

    -- Recorder plugin: capture (agent, round, prompt, response) per dispatch.
    -- spec is set by us (the orch) before calling dispatcher; dispatcher
    -- delivers the response to after_dispatch where we accumulate it.
    local transcript = {}
    local total_calls = 0
    local recorder = {
        name = "dmad_recorder",
        after_dispatch = function(response, spec, ctx)
            total_calls = total_calls + 1
            table.insert(transcript, {
                agent = spec.agent_idx,
                round = spec.round_idx,
                step = ctx.step,
                prompt = spec.prompt,
                text = response,
            })
        end,
    }

    local plugins = { recorder }
    if type(opts.extra_plugins) == "table" then
        for _, p in ipairs(opts.extra_plugins) do
            table.insert(plugins, p)
        end
    end

    local llm_opts = {}
    if opts.system_prompt then llm_opts.system = opts.system_prompt end
    if opts.gen_tokens then llm_opts.max_tokens = opts.gen_tokens end
    if opts.temperature then llm_opts.temperature = opts.temperature end

    local dispatcher = sfa.make_dispatcher({
        builder = function(_step, spec)
            -- We pre-build the prompt (using dmad's pure helpers) and
            -- attach it on spec.prompt; the builder only forwards it.
            -- Keeps prompt construction visible at the orch site rather
            -- than buried in a closure here.
            return spec.prompt
        end,
        state = state,
        llm_opts = llm_opts,
        alc = opts.alc,
        flow = opts.flow,
        plugins = plugins,
    })

    -- responses[r+1][i] mirrors dmad.run's output shape so callers
    -- expecting that format can read the transcript directly.
    local responses = {}

    -- Round 0: each agent answers from scratch.
    responses[1] = {}
    for i = 1, n_agents do
        local pb = dmad.build_init_prompt({
            task = opts.task,
            init_prompt = opts.init_prompt,
            system_prompt = opts.system_prompt,
        })
        local spec = {
            prompt = pb.prompt,
            agent_idx = i,
            round_idx = 0,
            -- pb.system is honored via llm_opts.system globally; if a
            -- per-agent system override is needed, plugins can set
            -- spec.llm_opts_overlay = { system = pb.system } in
            -- before_dispatch. The dmad default system is constant, so
            -- the global llm_opts route is sufficient at trial scope.
        }
        local text = dispatcher("/dmad/round_0/agent_" .. i, spec)
        responses[1][i] = text
    end

    -- Rounds 1..R: each agent debates, seeing the OTHERS' previous-round
    -- responses (paper §3 wording: "discuss with each other").
    for r = 1, n_rounds do
        responses[r + 1] = {}
        for i = 1, n_agents do
            local others = {}
            for j = 1, n_agents do
                if j ~= i then table.insert(others, responses[r][j]) end
            end
            local pb = dmad.build_debate_prompt({
                task = opts.task,
                other_responses = others,
                debate_prompt = opts.debate_prompt,
                system_prompt = opts.system_prompt,
            })
            local spec = {
                prompt = pb.prompt,
                agent_idx = i,
                round_idx = r,
            }
            local text = dispatcher("/dmad/round_" .. r .. "/agent_" .. i, spec)
            responses[r + 1][i] = text
        end
    end

    -- Extract final answers + majority vote (dmad's pure aggregator).
    local last_answers = {}
    for i = 1, n_agents do
        last_answers[i] = extract_fn(responses[n_rounds + 1][i]) or ""
    end
    local agg = dmad.aggregate_majority({ answers = last_answers })

    return {
        answer = agg.answer,
        n_agents = n_agents,
        n_rounds = n_rounds,
        total_llm_calls = total_calls,
        responses = responses,
        last_answers = last_answers,
        tally = agg.tally,
        transcript = transcript,
    }
end

-- ─── alc_advice-compatible entry ────────────────────────────────────
--
-- algocline's `alc_advice(package, task, opts)` invokes `pkg.run(ctx)`
-- with `ctx = { task = task, ... opts merged }`. This is the canonical
-- algocline pkg shape — providing it here lets `swarm_aggregate_plugin`
-- be addressed exactly like dmad / moa / reconcile from `alc_advice`,
-- agent-block e2e harness, etc.
--
-- Variant dispatch (`ctx.variant`):
--   "dmad"  (default) — Multi-Agent Debate (this trial)
--   "moa"             — anticipated (not yet implemented)
--   "reconcile"       — anticipated (not yet implemented)
--
-- A missing or unknown variant currently maps to "dmad". When moa /
-- reconcile land we will fail loudly on unknown variants instead.
function M.run(ctx)
    if type(ctx) ~= "table" then error("swarm_aggregate_plugin.run: ctx table required", 2) end
    local variant = ctx.variant or "dmad"
    if variant == "dmad" then return M.run_dmad(ctx) end
    error("swarm_aggregate_plugin.run: unknown variant '" .. tostring(variant) .. "' (supported: dmad)", 2)
end

return M
