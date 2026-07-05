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
--- the critic signals convergence. `sc` is the third pattern (self-
--- consistency voting, after Wang et al. 2022): N independent reasoning
--- paths run in parallel via a Fanout, then a single judge agent clusters
--- and majority-votes the answers. `ucb` is the fourth pattern (UCB1
--- bandit-style hypothesis exploration): generate, score, refine the
--- highest-potential arm each round. `moa` is the fifth pattern
--- (Mixture-of-Agents, after Wang et al. 2024): L layers of n parallel
--- proposers, each layer synthesized by an Aggregate-and-Synthesize
--- aggregator agent. Additional patterns are expected to land in this same
--- package as sibling top-level functions, each following the same "opts
--- in, Blueprint table out" contract.

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

-- ─── sc ──────────────────────────────────────────────────────────────────────

local SC_DEFAULT_ID = "sc-vote-v1"
local SC_DEFAULT_N = 5
local SC_MAX_N = 20

local SC_DIVERSITY_HINTS = {
    "Think step by step carefully.",
    "Approach this from first principles.",
    "Consider an alternative perspective.",
    "Work backwards from the expected outcome.",
    "Break this into smaller sub-problems.",
    "Use an analogy to reason about this.",
    "Consider edge cases and exceptions first.",
}

local SC_REASONER_SYSTEM_PROMPT_BASE = "You are a careful reasoner. Input is a JSON context: read "
    .. "'task' as the problem. Think through the problem thoroughly. Reply with a JSON object and "
    .. 'nothing else: {"reasoning": "<your step-by-step reasoning>", "answer": "<one-sentence final '
    .. 'answer>"}.'

local SC_JUDGE_SYSTEM_PROMPT = "You are a precise vote counter. Input is a JSON context: read 'task' "
    .. "and 'paths' (an array of {\"reasoning\", \"answer\"} objects). Group similar answers, count "
    .. 'votes, identify the majority. Reply with a single JSON object and nothing else: {"answer": '
    .. '"<majority answer>", "vote_counts": {"<normalized answer>": <count>, ...}, "n_sampled": <int>, '
    .. '"consensus": "<human-readable summary sentence>"}. Each element of paths is an object whose '
    .. "'path' field is a {reasoning, answer} record."

--- Validate the `n` option: must be a positive integer within [1, SC_MAX_N].
local function validate_sc_n(n)
    if type(n) ~= "number" or n ~= math.floor(n) or n < 1 then
        error("swarm_patterns.sc: 'n' must be a positive integer", 3)
    end
    if n > SC_MAX_N then error("swarm_patterns.sc: 'n' must not exceed " .. SC_MAX_N, 3) end
end

--- Recursively build the Fanout body: a chain of `branch(eq($.i, k), reasoner_k,
--- ...)` nodes that dispatches to the reasoner matching the bound loop index
--- `$.i`. `n == 1` degenerates to a single unconditional step (no branch
--- needed, since there is only one reasoner to dispatch to).
local function build_sc_reasoner_chain(n)
    if n == 1 then
        return bp.step({ ref = "reasoner_1", in_ = bp.path("$"), out = bp.path("$.path") })
    end
    local function build(i)
        local reasoner_step =
            bp.step({ ref = "reasoner_" .. i, in_ = bp.path("$"), out = bp.path("$.path") })
        if i == n then return reasoner_step end
        return bp.branch({
            cond = bp.eq(bp.path("$.i"), bp.lit(i)),
            then_ = reasoner_step,
            else_ = build(i + 1),
        })
    end
    return build(1)
end

--- sc — self-consistency voting pattern (Wang et al. 2022).
---
--- Builds a Blueprint that fans out `opts.n` independent reasoning paths in
--- parallel (each path driven by a distinct reasoner agent whose
--- `profile.system_prompt` embeds one of 7 diversity hints, cycled by
--- index), then hands all paths to a single `judge` agent that clusters
--- answers, counts votes, and reports the majority-vote consensus.
---
--- Runtime contract (for callers driving the resulting Blueprint):
--- `init_ctx` must provide `{task = "<problem>"}`. Each `reasoner_<i>` agent
--- reads `task` and replies with a JSON object `{"reasoning": "<text>",
--- "answer": "<one sentence>"}`. The `judge` agent reads `task` and `paths`
--- (the array of per-branch contexts produced by the Fanout join, each
--- element's `path` field holding a reasoner's `{reasoning, answer}`
--- output) and replies with `{"answer", "vote_counts", "n_sampled",
--- "consensus"}`. The final result lands in `$.result`. Vote aggregation is
--- delegated entirely to the judge's LLM judgment — flow.ir has no
--- `call_extern` primitive yet for a deterministic Lua-side count, so a
--- switch to deterministic counting is deferred to a future revision once
--- that primitive lands in mse.
---
--- @param opts table|nil {
---   n: integer (default 5, must be a positive integer, max 20),
---   id: string (default "sc-vote-v1"),
---   agent_kind: string (default "agent_block"),
---   model: string|nil (applied to every agent's profile.model when set),
---   session_id: string|nil (origin=algo when set, else origin=inline),
---   spec: table|nil (shared AgentDef.spec applied to every agent),
--- }
--- @return table Blueprint (JSON-able, built via swarm_blueprint)
function M.sc(opts)
    opts = opts or {}
    local n = opts.n or SC_DEFAULT_N
    validate_sc_n(n)

    local agent_kind = opts.agent_kind or DEFAULT_AGENT_KIND

    local function make_profile(system_prompt)
        local profile = { system_prompt = system_prompt }
        if opts.model ~= nil then profile.model = opts.model end
        return profile
    end

    local agents = {}
    for i = 1, n do
        local hint = SC_DIVERSITY_HINTS[((i - 1) % #SC_DIVERSITY_HINTS) + 1]
        agents[#agents + 1] = bp.agent({
            name = "reasoner_" .. i,
            kind = agent_kind,
            profile = make_profile(SC_REASONER_SYSTEM_PROMPT_BASE .. " " .. hint),
            spec = opts.spec,
        })
    end

    agents[#agents + 1] = bp.agent({
        name = "judge",
        kind = agent_kind,
        profile = make_profile(SC_JUDGE_SYSTEM_PROMPT),
        spec = opts.spec,
    })

    local items = {}
    for i = 1, n do
        items[i] = i
    end

    local fanout_node = bp.fanout({
        items = bp.lit(items),
        bind = bp.path("$.i"),
        body = build_sc_reasoner_chain(n),
        join = "all",
        out = bp.path("$.paths"),
    })

    local judge_step = bp.step({ ref = "judge", in_ = bp.path("$"), out = bp.path("$.result") })

    local origin
    if opts.session_id ~= nil then
        origin = bp.origin_algo(opts.session_id)
    else
        origin = bp.origin_inline()
    end

    return bp.blueprint({
        id = opts.id or SC_DEFAULT_ID,
        flow = bp.seq({ fanout_node, judge_step }),
        agents = agents,
        origin = origin,
        description = "Self-consistency: parallel independent reasoning paths aggregated by LLM judge "
            .. "(sc pattern)",
        tags = { "pattern:sc" },
    })
end

-- ─── ucb ─────────────────────────────────────────────────────────────────────

local UCB_DEFAULT_ID = "ucb-explore-v1"
local UCB_DEFAULT_N = 3
local UCB_MAX_N = 8
local UCB_DEFAULT_ROUNDS = 2
local UCB_MAX_ROUNDS = 5

local UCB_GENERATOR_SYSTEM_PROMPT_BASE = "You are a creative problem solver. Input is a JSON "
    .. "context: read 'task' as the topic. Propose a distinct, specific hypothesis for solving "
    .. "it. Reply with plain text only, 2-3 sentences."

local UCB_SCORER_SYSTEM_PROMPT = "You are a critical evaluator. Input is a JSON context: read "
    .. "'task' and 'hypotheses' (a map keyed by index) and 'i' (the arm index being scored). "
    .. "Rate hypotheses[i] on a 1-10 scale for quality, feasibility, and originality. Reply with "
    .. "a single JSON number and nothing else."

local UCB_REFINER_SYSTEM_PROMPT_TEMPLATE = "You are an expert refiner. Input is a JSON context: "
    .. "read 'task' and 'hypotheses.%d' (the current best hypothesis). Rewrite it to be sharper "
    .. "and more actionable. Reply with plain text only, 2-3 sentences."

--- Validate the `n` option: must be a positive integer within [1, UCB_MAX_N].
local function validate_ucb_n(n)
    if type(n) ~= "number" or n ~= math.floor(n) or n < 1 then
        error("swarm_patterns.ucb: 'n' must be a positive integer", 3)
    end
    if n > UCB_MAX_N then error("swarm_patterns.ucb: 'n' must not exceed " .. UCB_MAX_N, 3) end
end

--- Validate the `rounds` option: must be a positive integer within [1, UCB_MAX_ROUNDS].
local function validate_ucb_rounds(rounds)
    if type(rounds) ~= "number" or rounds ~= math.floor(rounds) or rounds < 1 then
        error("swarm_patterns.ucb: 'rounds' must be a positive integer", 3)
    end
    if rounds > UCB_MAX_ROUNDS then
        error("swarm_patterns.ucb: 'rounds' must not exceed " .. UCB_MAX_ROUNDS, 3)
    end
end

--- Recursively build the refine-branch chain: a chain of `branch(eq($.best_idx,
--- k), refiner_k, ...)` nodes that dispatches to the refiner matching the arm
--- selected by the UCB1 argmax. `n == 1` degenerates to a single
--- unconditional step (no branch needed, since there is only one refiner to
--- dispatch to).
local function build_ucb_refine_chain(n)
    if n == 1 then
        return bp.step({ ref = "refiner_1", in_ = bp.path("$"), out = bp.path("$.hypotheses.1") })
    end
    local function build(i)
        local refiner_step = bp.step({
            ref = "refiner_" .. i,
            in_ = bp.path("$"),
            out = bp.path("$.hypotheses." .. i),
        })
        if i == n then return refiner_step end
        return bp.branch({
            cond = bp.eq(bp.path("$.best_idx"), bp.lit(i)),
            then_ = refiner_step,
            else_ = build(i + 1),
        })
    end
    return build(1)
end

--- ucb — UCB1 bandit-style hypothesis exploration pattern.
---
--- Builds a Blueprint that generates `opts.n` initial hypotheses, then over
--- `opts.rounds` rounds: scores every hypothesis (a single scorer agent
--- invoked once per arm, per round), computes each arm's UCB1 score and the
--- argmax via host externs, and refines only the arm selected by the
--- argmax. The whole flow is statically unrolled at Blueprint-build time —
--- no runtime array/map-iteration primitive is used, mirroring `sc`'s
--- static branch-chain dispatch.
---
--- Consumer setup: this pattern relies on three host-registered pure
--- externs, invoked via `call_extern`. The caller MUST register them on the
--- `TaskLaunchService` that will run the resulting Blueprint, e.g.:
--- `TaskLaunchService::new(...).with_externs(ExternMap::new()
--- .register("ucb1", ucb1_fn).register("argmax_ucb", argmax_ucb_fn)
--- .register("finalize_ranking", finalize_ranking_fn))`. Without these
--- three externs registered, the `call_extern` steps below will fail at
--- run time.
---
--- - `ucb1(total, n, total_pulls)` -> number: the UCB1 score for one arm.
---   Returns `math.huge` when `total_pulls == 0` or `n == 0` (an unpulled
---   arm is always favored first), otherwise
---   `total/n + sqrt(2 * ln(total_pulls + 1) / n)`.
--- - `argmax_ucb(u1, u2, ..., uN)` -> integer: the 1-based index of the
---   maximum among the given UCB1 scores (ties broken by the smallest
---   index).
--- - `finalize_ranking(total_1, n_1, hyp_1, ..., total_N, n_N, hyp_N)` ->
---   object: given N `(total, n, hypothesis)` triples, computes each arm's
---   average score (`total/n`) and returns `{best = "<top hypothesis>",
---   ranking = [{rank, hypothesis, avg_score, pulls}, ...]}` sorted by
---   `avg_score` descending (rank 1 = best).
---
--- Runtime contract (for callers driving the resulting Blueprint):
--- `init_ctx` must provide `{task = "<topic>"}`. Each `generator_<i>` agent
--- reads `task` and returns a 2-3 sentence hypothesis into
--- `$.hypotheses.<i>`. The single `scorer` agent reads `task`, `hypotheses`
--- (the full index-keyed map), and `i` (assigned immediately before each
--- scorer step inside the round loop) and returns a bare 1-10 JSON number.
--- Each `refiner_<k>` agent reads `task` and `hypotheses.<k>` and returns a
--- rewritten hypothesis. The final result lands in `$.result` (see
--- `finalize_ranking` above); per-arm running stats live under
--- `$.stats.<i>.{total,n,ucb,last}` and the shared pull count under
--- `$.pulls`.
---
--- @param opts table|nil {
---   n: integer (default 3, must be a positive integer, max 8),
---   rounds: integer (default 2, must be a positive integer, max 5),
---   id: string (default "ucb-explore-v1"),
---   agent_kind: string (default "agent_block"),
---   model: string|nil (applied to every agent's profile.model when set),
---   session_id: string|nil (origin=algo when set, else origin=inline),
---   spec: table|nil (shared AgentDef.spec applied to every agent),
--- }
--- @return table Blueprint (JSON-able, built via swarm_blueprint)
function M.ucb(opts)
    opts = opts or {}
    local n = opts.n or UCB_DEFAULT_N
    validate_ucb_n(n)
    local rounds = opts.rounds or UCB_DEFAULT_ROUNDS
    validate_ucb_rounds(rounds)

    local agent_kind = opts.agent_kind or DEFAULT_AGENT_KIND

    local function make_profile(system_prompt)
        local profile = { system_prompt = system_prompt }
        if opts.model ~= nil then profile.model = opts.model end
        return profile
    end

    local agents = {}
    local generator_steps = {}
    for i = 1, n do
        local hint = SC_DIVERSITY_HINTS[((i - 1) % #SC_DIVERSITY_HINTS) + 1]
        agents[#agents + 1] = bp.agent({
            name = "generator_" .. i,
            kind = agent_kind,
            profile = make_profile(UCB_GENERATOR_SYSTEM_PROMPT_BASE .. " " .. hint),
            spec = opts.spec,
        })
        generator_steps[#generator_steps + 1] = bp.step({
            ref = "generator_" .. i,
            in_ = bp.path("$"),
            out = bp.path("$.hypotheses." .. i),
        })
    end

    agents[#agents + 1] = bp.agent({
        name = "scorer",
        kind = agent_kind,
        profile = make_profile(UCB_SCORER_SYSTEM_PROMPT),
        spec = opts.spec,
    })

    for i = 1, n do
        agents[#agents + 1] = bp.agent({
            name = "refiner_" .. i,
            kind = agent_kind,
            profile = make_profile(UCB_REFINER_SYSTEM_PROMPT_TEMPLATE:format(i)),
            spec = opts.spec,
        })
    end

    -- init: $.pulls = 0, then per-arm $.stats.<i>.total = 0 / $.stats.<i>.n = 0
    local init_nodes = { bp.assign({ at = bp.path("$.pulls"), value = bp.lit(0) }) }
    for i = 1, n do
        init_nodes[#init_nodes + 1] =
            bp.assign({ at = bp.path("$.stats." .. i .. ".total"), value = bp.lit(0) })
        init_nodes[#init_nodes + 1] = bp.assign({ at = bp.path("$.stats." .. i .. ".n"), value = bp.lit(0) })
    end

    -- round body: score every arm, compute UCB1 + argmax, refine the chosen arm
    local body_nodes = {}
    for i = 1, n do
        body_nodes[#body_nodes + 1] = bp.assign({ at = bp.path("$.i"), value = bp.lit(i) })
        body_nodes[#body_nodes + 1] = bp.step({
            ref = "scorer",
            in_ = bp.path("$"),
            out = bp.path("$.stats." .. i .. ".last"),
        })
        body_nodes[#body_nodes + 1] = bp.assign({
            at = bp.path("$.stats." .. i .. ".total"),
            value = bp.add(bp.path("$.stats." .. i .. ".total"), bp.path("$.stats." .. i .. ".last")),
        })
        body_nodes[#body_nodes + 1] = bp.assign({
            at = bp.path("$.stats." .. i .. ".n"),
            value = bp.add(bp.path("$.stats." .. i .. ".n"), bp.lit(1)),
        })
        body_nodes[#body_nodes + 1] =
            bp.assign({ at = bp.path("$.pulls"), value = bp.add(bp.path("$.pulls"), bp.lit(1)) })
    end
    for i = 1, n do
        body_nodes[#body_nodes + 1] = bp.assign({
            at = bp.path("$.stats." .. i .. ".ucb"),
            value = bp.call_extern(
                "ucb1",
                bp.path("$.stats." .. i .. ".total"),
                bp.path("$.stats." .. i .. ".n"),
                bp.path("$.pulls")
            ),
        })
    end
    local argmax_args = {}
    for i = 1, n do
        argmax_args[#argmax_args + 1] = bp.path("$.stats." .. i .. ".ucb")
    end
    body_nodes[#body_nodes + 1] = bp.assign({
        at = bp.path("$.best_idx"),
        value = bp.call_extern("argmax_ucb", table.unpack(argmax_args)),
    })
    body_nodes[#body_nodes + 1] = build_ucb_refine_chain(n)

    local loop_node = bp.loop({
        counter = bp.path("$.round"),
        cond = bp.lt(bp.path("$.round"), bp.lit(rounds)),
        max = rounds,
        body = bp.seq(body_nodes),
    })

    local finalize_args = {}
    for i = 1, n do
        finalize_args[#finalize_args + 1] = bp.path("$.stats." .. i .. ".total")
        finalize_args[#finalize_args + 1] = bp.path("$.stats." .. i .. ".n")
        finalize_args[#finalize_args + 1] = bp.path("$.hypotheses." .. i)
    end
    local finalize_node = bp.assign({
        at = bp.path("$.result"),
        value = bp.call_extern("finalize_ranking", table.unpack(finalize_args)),
    })

    local flow_children = {}
    for _, step_node in ipairs(generator_steps) do
        flow_children[#flow_children + 1] = step_node
    end
    for _, init_node in ipairs(init_nodes) do
        flow_children[#flow_children + 1] = init_node
    end
    flow_children[#flow_children + 1] = loop_node
    flow_children[#flow_children + 1] = finalize_node

    local origin
    if opts.session_id ~= nil then
        origin = bp.origin_algo(opts.session_id)
    else
        origin = bp.origin_inline()
    end

    return bp.blueprint({
        id = opts.id or UCB_DEFAULT_ID,
        flow = bp.seq(flow_children),
        agents = agents,
        origin = origin,
        description = "UCB1 bandit-style hypothesis exploration: generate, score, refine the "
            .. "highest-potential arm each round (ucb pattern)",
        tags = { "pattern:ucb" },
    })
end

-- ─── moa ─────────────────────────────────────────────────────────────────────
--
-- Primary citation: Wang, J., Wang, J., Athiwaratkun, B., Zhang, C., & Zou,
-- J. (2024). "Mixture-of-Agents Enhances Large Language Model Capabilities".
-- arXiv:2406.04692. https://arxiv.org/abs/2406.04692
--
-- Algorithm (Wang 2024 §2.2): layered aggregation. For each layer i, n
-- proposer agents A_{i,1..n} generate responses to the current input x_i,
-- and an aggregator synthesizes them into y_i, which becomes the next
-- layer's input:
--
--   y_i     = ⊕_{j=1}^{n}[A_{i,j}(x_i)] + x_1
--   x_{i+1} = y_i
--
-- Defaults (Wang 2024 §3): n_layers = 3 ("We use 3 MoA layers"), n_proposers
-- = 6 (main experiment uses 6 open-source proposers). Both are anchored (L)
-- to the paper's main configuration; this pkg does not hard-code proposer
-- model identities — the caller MUST supply `proposers` or `personas`
-- (REQUIRED extension point).
--
-- Proposer models (paper main experiment, reference only, NOT hard-coded):
--   Qwen1.5-110B-Chat, Qwen1.5-72B-Chat, WizardLM-8x22B,
--   LLaMA-3-70B-Instruct, Mixtral-8x22B-v0.1, dbrx-instruct
--
-- Stability tier: `n_layers`, `proposers`, `personas` are stable knobs.
-- `personas` (single-model rotation, outside Wang §3's main config) is
-- experimental in the sense that the paper's distinct-model diversity
-- property is not held; it is documented as a convenience path for callers
-- without access to 6 distinct models.

local MOA_DEFAULT_ID = "moa-aggregation-v1"
local MOA_DEFAULT_N_LAYERS = 3
local MOA_MAX_N_LAYERS = 8
local MOA_MAX_N_PROPOSERS = 12
local MOA_MAX_TOTAL_ARMS = 32

-- (X) Default proposer system prompt (paper does not specify one; each
-- proposer is conceptually a distinct model with its own house style).
local MOA_DEFAULT_PROPOSER_SYSTEM =
    "You are a helpful, accurate assistant. Respond to the user's query thoroughly."

-- Appended to every proposer's system_prompt: the JSON-context reading
-- contract (this generator's data-routing layer, not from the paper).
local MOA_PROPOSER_CONTRACT = "Input is a JSON context: read 'task' as the user query; at layers "
    .. "2+ also read 'aggregated_prev' (the previous layer's aggregated output) as prior context "
    .. "to build on. Produce your best answer as plain text only."

-- (L) Aggregate-and-Synthesize prompt prefix — string literal identical to
-- Wang 2024 Table 1's English text up to "...highest standards of accuracy
-- and reliability." (punctuation / capitalization match exactly). The
-- paper's trailing "\n\nResponses from models:\n%s" placeholder is replaced
-- below with this generator's JSON-context reading contract, since the
-- generated aggregator agent reads its input from ctx rather than a
-- pre-formatted prompt string.
local MOA_AS_PROMPT_PREFIX = "You have been provided with a set of responses from various "
    .. "open-source models to the latest user query. Your task is to synthesize these responses "
    .. "into a single, high-quality response. It is crucial to critically evaluate the information "
    .. "provided in these responses, recognizing that some of it may be biased or incorrect. Your "
    .. "response should not simply replicate the given answers but should offer a refined, "
    .. "accurate, and comprehensive reply to the instruction. Ensure your response is "
    .. "well-structured, coherent, and adheres to the highest standards of accuracy and reliability."

--- Resolve the proposer list: exactly one of `opts.proposers` (multi-model
--- PATH, Wang §3 main config) or `opts.personas` (single-model rotation
--- PATH, outside Wang §3) is REQUIRED. Returns an array of
--- `{model?, system?}` specs.
local function resolve_moa_proposers(opts)
    if opts.proposers ~= nil and opts.personas ~= nil then
        error("swarm_patterns.moa: pass exactly one of proposers or personas, not both", 3)
    end
    if opts.proposers ~= nil then
        if type(opts.proposers) ~= "table" or #opts.proposers == 0 then
            error("swarm_patterns.moa: 'proposers' must be a non-empty array", 3)
        end
        return opts.proposers
    end
    if opts.personas ~= nil then
        if type(opts.personas) ~= "table" or #opts.personas == 0 then
            error("swarm_patterns.moa: 'personas' must be a non-empty array", 3)
        end
        local specs = {}
        for i, persona in ipairs(opts.personas) do
            if type(persona) ~= "string" or persona == "" then
                error("swarm_patterns.moa: personas[" .. i .. "] must be a non-empty string", 3)
            end
            specs[i] = { system = persona }
        end
        return specs
    end
    error(
        "swarm_patterns.moa: one of 'proposers' (multi-model PATH; Wang §3 main config) or "
            .. "'personas' (single-model rotation PATH) is REQUIRED",
        3
    )
end

--- Validate the `n_layers` option: must be a positive integer within
--- [1, MOA_MAX_N_LAYERS].
local function validate_moa_n_layers(n_layers)
    if type(n_layers) ~= "number" or n_layers ~= math.floor(n_layers) or n_layers < 1 then
        error("swarm_patterns.moa: 'n_layers' must be a positive integer", 3)
    end
    if n_layers > MOA_MAX_N_LAYERS then
        error("swarm_patterns.moa: 'n_layers' must not exceed " .. MOA_MAX_N_LAYERS, 3)
    end
end

--- Recursively build the Fanout body for layer `layer_i`: a chain of
--- `branch(eq($.j, k), proposer_<layer_i>_k, ...)` nodes dispatching to the
--- proposer matching the bound loop index `$.j`. `n == 1` degenerates to a
--- single unconditional step (mirrors `sc`'s `build_sc_reasoner_chain`).
local function build_moa_proposer_chain(layer_i, n)
    local function ref(k) return "proposer_" .. layer_i .. "_" .. k end
    if n == 1 then
        return bp.step({ ref = ref(1), in_ = bp.path("$"), out = bp.path("$.proposer_out") })
    end
    local function build(k)
        local proposer_step = bp.step({ ref = ref(k), in_ = bp.path("$"), out = bp.path("$.proposer_out") })
        if k == n then return proposer_step end
        return bp.branch({
            cond = bp.eq(bp.path("$.j"), bp.lit(k)),
            then_ = proposer_step,
            else_ = build(k + 1),
        })
    end
    return build(1)
end

--- moa — Mixture-of-Agents pattern (Wang et al. 2024).
---
--- Builds a Blueprint with `opts.n_layers` layers; each layer fans out n
--- proposers in parallel (a static per-layer branch chain dispatching on
--- `$.j`), then applies a single aggregator agent whose system_prompt is
--- Wang 2024 Table 1's Aggregate-and-Synthesize instruction. The
--- aggregator's output feeds `$.aggregated_prev` for the next layer's
--- proposers; the final layer's aggregated output lands in `$.answer`.
---
--- Runtime contract (for callers driving the resulting Blueprint):
--- `init_ctx` must provide `{task = "<query>"}`. Each `proposer_<i>_<j>`
--- agent reads `task` (and, from layer 2 on, `aggregated_prev`) and returns
--- plain text. Each `aggregator_<i>` agent reads `task` and
--- `layers.<i>.proposers_raw` (the array of per-proposer branch-local
--- contexts produced by that layer's Fanout join; each element's
--- `proposer_out` field holds one proposer's text) and returns a
--- synthesized plain-text response.
---
--- @param opts table|nil {
---   n_layers: integer (default 3 per Wang §3 "We use 3 MoA layers", 1..8),
---   proposers: table[]|nil (multi-model PATH, Wang §3 main config; each
---     entry {model?: string, system?: string}; REQUIRED unless personas is
---     given),
---   personas: string[]|nil (single-model rotation PATH, outside Wang §3;
---     REQUIRED unless proposers is given),
---   n_proposers: integer|nil (must match the resolved proposers/personas
---     length when given; otherwise inferred from that length),
---   id: string (default "moa-aggregation-v1"),
---   agent_kind: string (default "agent_block"),
---   model: string|nil (applied to every agent's profile.model when set;
---     overridden per-proposer by proposers[j].model when present),
---   session_id: string|nil (origin=algo when set, else origin=inline),
---   spec: table|nil (shared AgentDef.spec applied to every agent),
--- }
--- @return table Blueprint (JSON-able, built via swarm_blueprint)
function M.moa(opts)
    opts = opts or {}

    local proposer_specs = resolve_moa_proposers(opts)
    local n = #proposer_specs

    if opts.n_proposers ~= nil and opts.n_proposers ~= n then
        error(
            "swarm_patterns.moa: n_proposers="
                .. tostring(opts.n_proposers)
                .. " does not match length of proposers/personas (="
                .. n
                .. ")",
            3
        )
    end
    if n > MOA_MAX_N_PROPOSERS then
        error("swarm_patterns.moa: number of proposers must not exceed " .. MOA_MAX_N_PROPOSERS, 3)
    end

    local n_layers = opts.n_layers or MOA_DEFAULT_N_LAYERS
    validate_moa_n_layers(n_layers)

    if n_layers * n > MOA_MAX_TOTAL_ARMS then
        error(
            "swarm_patterns.moa: L * n exceeds "
                .. MOA_MAX_TOTAL_ARMS
                .. " (got L="
                .. n_layers
                .. ", n="
                .. n
                .. ")",
            3
        )
    end

    local agent_kind = opts.agent_kind or DEFAULT_AGENT_KIND

    local agents = {}
    local flow_children = {}

    flow_children[#flow_children + 1] =
        bp.assign({ at = bp.path("$.aggregated_prev"), value = bp.lit("") })

    for layer_i = 1, n_layers do
        for j = 1, n do
            local spec = proposer_specs[j]
            local system_prompt = (spec.system or MOA_DEFAULT_PROPOSER_SYSTEM) .. " " .. MOA_PROPOSER_CONTRACT
            local profile = { system_prompt = system_prompt }
            if spec.model ~= nil then
                profile.model = spec.model
            elseif opts.model ~= nil then
                profile.model = opts.model
            end
            agents[#agents + 1] = bp.agent({
                name = "proposer_" .. layer_i .. "_" .. j,
                kind = agent_kind,
                profile = profile,
                spec = opts.spec,
            })
        end

        local fanout_items = {}
        for j = 1, n do
            fanout_items[j] = j
        end
        flow_children[#flow_children + 1] = bp.fanout({
            items = bp.lit(fanout_items),
            bind = bp.path("$.j"),
            body = build_moa_proposer_chain(layer_i, n),
            join = "all",
            out = bp.path("$.layers." .. layer_i .. ".proposers_raw"),
        })

        local aggregator_profile = {
            system_prompt = MOA_AS_PROMPT_PREFIX
                .. "\n\nInput is a JSON context: read 'task' as the original user query, and read "
                .. "'layers."
                .. layer_i
                .. ".proposers_raw' as an array of per-proposer branch-local contexts (each element "
                .. "has a 'proposer_out' field carrying that proposer's text). Extract the "
                .. n
                .. " proposer outputs from the 'proposer_out' fields and synthesize them into a "
                .. "single high-quality response following the instructions above. Reply with "
                .. "plain text only.",
        }
        if opts.model ~= nil then aggregator_profile.model = opts.model end

        agents[#agents + 1] = bp.agent({
            name = "aggregator_" .. layer_i,
            kind = agent_kind,
            profile = aggregator_profile,
            spec = opts.spec,
        })

        flow_children[#flow_children + 1] = bp.step({
            ref = "aggregator_" .. layer_i,
            in_ = bp.path("$"),
            out = bp.path("$.layers." .. layer_i .. ".aggregated"),
        })

        flow_children[#flow_children + 1] = bp.assign({
            at = bp.path("$.aggregated_prev"),
            value = bp.path("$.layers." .. layer_i .. ".aggregated"),
        })
    end

    flow_children[#flow_children + 1] = bp.assign({
        at = bp.path("$.answer"),
        value = bp.path("$.layers." .. n_layers .. ".aggregated"),
    })

    local origin
    if opts.session_id ~= nil then
        origin = bp.origin_algo(opts.session_id)
    else
        origin = bp.origin_inline()
    end

    return bp.blueprint({
        id = opts.id or MOA_DEFAULT_ID,
        flow = bp.seq(flow_children),
        agents = agents,
        origin = origin,
        description = "Mixture-of-Agents (Wang 2024): L layers of n parallel proposers aggregated "
            .. "by an Aggregate-and-Synthesize step per layer (moa pattern)",
        tags = { "pattern:moa" },
    })
end

return M
