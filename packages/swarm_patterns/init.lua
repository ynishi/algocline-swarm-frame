--- swarm_patterns — Blueprint generators for algocline-proven strategy patterns.
---
--- Architecture: this package is a pattern generator collection, not a single
--- strategy. Each exported function (`panel`, `reflect`, and future additions
--- such as `ucb`) takes a small options table and returns a fully built
--- mlua-swarm-engine (mse) Blueprint, constructed exclusively through the
--- `swarm_blueprint` builder DSL (`bp.step` / `bp.seq` / `bp.path` / `bp.agent`
--- / `bp.blueprint` / `bp.origin_*`). This module never calls `alc.llm` and
--- never reads `ctx` — it is pure data construction, mirroring
--- `swarm_blueprint`'s own "pure data" design. Prompt assembly, previously
--- done in Lua for the algocline `panel` / `reflect` packages, is pushed down
--- into each generated agent's `profile.system_prompt`; the flow wired here is
--- pure data routing.
---
--- Design: `panel` is the first pattern (multi-perspective deliberation).
--- `reflect` is the second pattern (self-critique refinement loop, after
--- Madaan et al. 2023 "Self-Refine"): generator -> {critic -> reviser}* until
--- the critic signals convergence. Additional patterns (e.g. `ucb` for
--- bandit-style exploration) are expected to land in this same package as
--- sibling top-level functions, each following the same "opts in, Blueprint
--- table out" contract.

local bp = require("swarm_blueprint")

local M = {}

M.meta = {
    name = "swarm_patterns",
    version = "0.1.0",
    type = "library",
    category = "frame",
    description = "Blueprint generators that translate algocline-proven strategy patterns "
        .. "(panel, and future additions) into mlua-swarm-engine Blueprints, built "
        .. "exclusively through the swarm_blueprint builder DSL.",
}

local DEFAULT_ROLES = { "advocate", "critic", "pragmatist" }
local DEFAULT_ID = "panel-deliberation-v1"
local DEFAULT_AGENT_KIND = "agent_block"
local RESERVED_ROLE = "moderator"

local IDENTIFIER_PATTERN = "^[%a_][%w_]*$"

local PANELIST_SYSTEM_PROMPT_TEMPLATE = "You are a %s. Stay in character. Be specific. Input is a "
    .. "JSON context: read 'task' as the topic and 'arguments' (if present) as prior speakers' "
    .. "positions keyed by role. Respond to specific points when prior arguments exist, otherwise "
    .. "present your initial position. Reply in 2-3 sentences with plain text only."

local MODERATOR_SYSTEM_PROMPT = "You are a wise moderator. Be balanced and decisive. Input is a "
    .. "JSON context: read 'task' as the topic and 'arguments' as the panelists' positions keyed "
    .. "by role. Synthesize: identify agreements, key disagreements, and a balanced actionable "
    .. "conclusion in 3-4 sentences, plain text only."

--- Validate the `roles` option: must be a non-empty array of unique,
--- identifier-shaped strings, none of which is the reserved "moderator" name.
local function validate_roles(roles)
    if type(roles) ~= "table" or #roles == 0 then
        error("swarm_patterns.panel: 'roles' must be a non-empty array of strings", 3)
    end
    local seen = {}
    for i, role in ipairs(roles) do
        if type(role) ~= "string" then
            error("swarm_patterns.panel: role #" .. i .. " must be a string (got " .. type(role) .. ")", 3)
        end
        if role == RESERVED_ROLE then
            error("swarm_patterns.panel: role name 'moderator' is reserved", 3)
        end
        if not role:match(IDENTIFIER_PATTERN) then
            error(
                "swarm_patterns.panel: role name '"
                    .. role
                    .. "' must be an identifier (letters/digits/underscore, not starting with a digit)",
                3
            )
        end
        if seen[role] then
            error("swarm_patterns.panel: duplicate role '" .. role .. "'", 3)
        end
        seen[role] = true
    end
end

--- panel — multi-perspective deliberation pattern.
---
--- Builds a Blueprint where each role in `opts.roles` speaks in sequence
--- (each seeing the full running context, including prior roles' positions
--- under `$.arguments.<role>`), followed by a moderator step that
--- synthesizes agreements/disagreements/conclusion into `$.synthesis`.
---
--- Runtime contract (for callers driving the resulting Blueprint):
--- `init_ctx` must provide `{task = "<topic>"}`. Each panelist agent reads
--- `task` and `arguments` (prior roles' outputs, absent for the first
--- speaker) from its input JSON and returns a 2-3 sentence position. The
--- moderator reads `task` and `arguments` and returns a synthesis.
---
--- @param opts table|nil {
---   roles: string[] (default {"advocate", "critic", "pragmatist"}),
---   id: string (default "panel-deliberation-v1"),
---   agent_kind: string (default "agent_block"),
---   model: string|nil (applied to every agent's profile.model when set),
---   session_id: string|nil (origin=algo when set, else origin=inline),
---   spec: table|nil (shared AgentDef.spec applied to every agent),
--- }
--- @return table Blueprint (JSON-able, built via swarm_blueprint)
function M.panel(opts)
    opts = opts or {}
    local roles = opts.roles or DEFAULT_ROLES
    validate_roles(roles)

    local agent_kind = opts.agent_kind or DEFAULT_AGENT_KIND

    local agents = {}
    local steps = {}

    for _, role in ipairs(roles) do
        local profile = { system_prompt = PANELIST_SYSTEM_PROMPT_TEMPLATE:format(role) }
        if opts.model ~= nil then profile.model = opts.model end

        agents[#agents + 1] = bp.agent({
            name = "panelist_" .. role,
            kind = agent_kind,
            profile = profile,
            spec = opts.spec,
        })

        steps[#steps + 1] = bp.step({
            ref = "panelist_" .. role,
            in_ = bp.path("$"),
            out = bp.path("$.arguments." .. role),
        })
    end

    local moderator_profile = { system_prompt = MODERATOR_SYSTEM_PROMPT }
    if opts.model ~= nil then moderator_profile.model = opts.model end

    agents[#agents + 1] = bp.agent({
        name = "moderator",
        kind = agent_kind,
        profile = moderator_profile,
        spec = opts.spec,
    })

    steps[#steps + 1] = bp.step({
        ref = "moderator",
        in_ = bp.path("$"),
        out = bp.path("$.synthesis"),
    })

    local origin
    if opts.session_id ~= nil then
        origin = bp.origin_algo(opts.session_id)
    else
        origin = bp.origin_inline()
    end

    return bp.blueprint({
        id = opts.id or DEFAULT_ID,
        flow = bp.seq(steps),
        agents = agents,
        origin = origin,
        description = "Multi-perspective deliberation with moderator synthesis (panel pattern)",
        tags = { "pattern:panel" },
    })
end

-- ─── reflect ─────────────────────────────────────────────────────────────────

local REFLECT_DEFAULT_ID = "reflect-refine-v1"
local REFLECT_DEFAULT_MAX_ROUNDS = 3

local GENERATOR_SYSTEM_PROMPT = "You are an expert. Input is a JSON context: read 'task' as the "
    .. "assignment. Produce a high-quality, thorough response as plain text only."

local CRITIC_SYSTEM_PROMPT = "You are a rigorous critic. Do not be lenient. Input is a JSON "
    .. "context: read 'task' and 'draft'. Identify errors, missing information, unclear "
    .. "reasoning, and needed improvements. Reply with a single JSON object and nothing else: "
    .. '{"critique": "<specific problems and required fixes>", "converged": <true if there are '
    .. "no major issues, else false>}."

local REVISER_SYSTEM_PROMPT = "You are an expert reviser. Input is a JSON context: read 'task', "
    .. "'draft', and 'critique.critique' (the critic's feedback). Rewrite the draft to address "
    .. "every critique point while preserving its strengths. Reply with the revised draft as "
    .. "plain text only."

--- Validate the `max_rounds` option: must be a positive integer.
local function validate_max_rounds(max_rounds)
    if type(max_rounds) ~= "number" or max_rounds ~= math.floor(max_rounds) or max_rounds < 1 then
        error("swarm_patterns.reflect: 'max_rounds' must be a positive integer", 3)
    end
end

--- reflect — self-critique refinement loop pattern (Self-Refine, Madaan et al. 2023).
---
--- Builds a Blueprint that generates an initial draft (or skips generation
--- when `initial_draft` is already supplied), then repeatedly critiques and
--- revises the draft until the critic signals convergence or `max_rounds` is
--- reached.
---
--- Runtime contract (for callers driving the resulting Blueprint):
--- `init_ctx` must provide `{task = "<assignment>"}`; `initial_draft =
--- "<text>"` is optional and, when present, skips the generator step. The
--- `critic` agent's output is a JSON object contract — it must reply with
--- exactly `{"critique": "<text>", "converged": true|false}` — since the loop
--- guard is a structured Expr (`flow.ir` has no string-matching primitive
--- equivalent to the original "NO_MAJOR_ISSUES" sentinel) and relies on
--- `$.critique.converged` resolving to a boolean. The final result lands in
--- `$.draft`, with `$.converged = true` set on early convergence; round-by-
--- round history is NOT accumulated in ctx (flow.ir has no array-append
--- primitive) — observe iteration history via mse run events instead.
---
--- @param opts table|nil {
---   max_rounds: integer (default 3, must be a positive integer),
---   id: string (default "reflect-refine-v1"),
---   agent_kind: string (default "agent_block"),
---   model: string|nil (applied to every agent's profile.model when set),
---   session_id: string|nil (origin=algo when set, else origin=inline),
---   spec: table|nil (shared AgentDef.spec applied to every agent),
--- }
--- @return table Blueprint (JSON-able, built via swarm_blueprint)
function M.reflect(opts)
    opts = opts or {}
    local max_rounds = opts.max_rounds or REFLECT_DEFAULT_MAX_ROUNDS
    validate_max_rounds(max_rounds)

    local agent_kind = opts.agent_kind or DEFAULT_AGENT_KIND

    local function make_profile(system_prompt)
        local profile = { system_prompt = system_prompt }
        if opts.model ~= nil then profile.model = opts.model end
        return profile
    end

    local generator = bp.agent({
        name = "generator",
        kind = agent_kind,
        profile = make_profile(GENERATOR_SYSTEM_PROMPT),
        spec = opts.spec,
    })
    local critic = bp.agent({
        name = "critic",
        kind = agent_kind,
        profile = make_profile(CRITIC_SYSTEM_PROMPT),
        spec = opts.spec,
    })
    local reviser = bp.agent({
        name = "reviser",
        kind = agent_kind,
        profile = make_profile(REVISER_SYSTEM_PROMPT),
        spec = opts.spec,
    })

    local init_node = bp.branch({
        cond = bp.exists("$.initial_draft"),
        then_ = bp.assign({ at = bp.path("$.draft"), value = bp.path("$.initial_draft") }),
        else_ = bp.step({ ref = "generator", in_ = bp.path("$"), out = bp.path("$.draft") }),
    })

    local loop_node = bp.loop({
        counter = bp.path("$.round"),
        cond = bp.or_({
            bp.not_(bp.exists("$.critique")),
            bp.eq(bp.path("$.critique.converged"), bp.lit(false)),
        }),
        max = max_rounds,
        body = bp.seq({
            bp.step({ ref = "critic", in_ = bp.path("$"), out = bp.path("$.critique") }),
            bp.branch({
                cond = bp.eq(bp.path("$.critique.converged"), bp.lit(false)),
                then_ = bp.step({ ref = "reviser", in_ = bp.path("$"), out = bp.path("$.draft") }),
                else_ = bp.assign({ at = bp.path("$.converged"), value = bp.lit(true) }),
            }),
        }),
    })

    local origin
    if opts.session_id ~= nil then
        origin = bp.origin_algo(opts.session_id)
    else
        origin = bp.origin_inline()
    end

    return bp.blueprint({
        id = opts.id or REFLECT_DEFAULT_ID,
        flow = bp.seq({ init_node, loop_node }),
        agents = { generator, critic, reviser },
        origin = origin,
        description = "Self-critique refinement loop: generate, critique, revise until "
            .. "convergence (reflect pattern)",
        tags = { "pattern:reflect" },
    })
end

return M
