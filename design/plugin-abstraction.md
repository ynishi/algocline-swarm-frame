# swarm_frame_algocline Plugin Abstraction (Phase 2, draft)

Status: draft (2026-05-12)
Related: design/delegate-extraction.md / design/token-strict-mode.md

Draft / WIP — feedback welcome; discard if off.

## 1. Problem

Phase 1 added an opaque `extras` slot to `make_dispatcher`, putting
the frame in a state where "a consumer can pass arbitrary opts through
to the Frame". But `extras` is **only held** — there is no path for
the dispatch process to consume it in a plugin-like way. Two concrete
unresolved issues:

- **A/B variant** is typically locked inside a downstream consumer's
  delegate (a variant-pick hook + a per-step dispatch stash +
  finalize routines). The feature itself is real and used; the
  problem is that it has not been brought onto the Frame stack, so
  it cannot be composed alongside other dispatch-time logic.
- There is no path to compose **Swarm-style logic** (cascade / vote /
  reflexion / ab_mcts / coevolve / future additions) into the Frame's
  dispatch unit. As the set of Swarm-style primitives grows, wiring
  each one into each consumer individually repeats the same "fixed
  implementation, zero extensibility" pattern that the convention-
  based delegate already exhibits.

**The real point**: A/B variant is just one application. The core
intent of this design is to make Swarm-style logic injectable into
the dispatch process as plugins. Consumer-side middleware systems are
demoted to **one plugin implementation among many** (i.e. the fixed
implementation is dismantled).

## 2. Goals

1. **Inject arbitrary dispatch hooks as plugins**: with three hook
   kinds — before / around / after — consumers or plugin modules from
   other packages line up in the pipe from the outside.
2. **Existing middleware-style features are re-implementable as
   plugins** (variant_ab / retry / observability / inject_deps /
   template_resolve can all be rewritten as plugins — i.e. a
   migration path is secured).
3. **Swarm-style logic (cascade / vote / reflexion / ab_mcts /
   coevolve) is writable as plugins**: a self-contained module can
   call primitives like `alc.parallel` / `alc.vote` / `alc.fork` from
   inside the plugin to drive Swarm control.
4. **Coexists with Phase 1 extras**: `extras` serves as the slot
   through which a plugin reads its config; the Frame core preserves
   the invariant that it never interprets `extras`.
5. **Backward compat**: with no plugins specified, behavior is
   completely identical to Phase 1 (existing consumers run
   unchanged).

## 3. Architecture (ASCII, single diagram)

```
consumer (a downstream orchestration package)
    │
    │  dispatcher = adapter.make_dispatcher({
    │      builder = ...,
    │      state   = ...,
    │      llm_opts = { ... },
    │      extras  = { abtest_agents = {...}, ... },  -- Phase 1
    │      plugins = {                                 -- Phase 2 (new)
    │          require("plugin_variant_ab")({ ... }),
    │          require("plugin_cascade")({ stages = {...} }),
    │          require("plugin_vote")({ n = 3 }),
    │          require("plugin_observability")({ ... }),
    │      },
    │  })
    │  dispatcher("/pkg/step/agent", spec, ctx)
    ▼
swarm_frame_algocline.make_dispatcher
    │
    │  ┌─── Plugin Pipeline (configured order) ───┐
    │  │  before_dispatch (sequential)             │  spec mutate
    │  │    variant_ab.before  → blue/green pick   │  (spec.agent rewrite)
    │  │    observability.before  → trace_id       │  (ctx.scratch set)
    │  │                                            │
    │  │  around_dispatch (onion wrap)             │  control flow
    │  │    cascade.around  → cheap→expensive loop │  (multi-call)
    │  │    vote.around     → N samples + majority │  (multi-call)
    │  │    reflexion.around → critique + retry    │  (multi-call)
    │  │                                            │
    │  │       ┌── core dispatch ──┐               │
    │  │       │  builder(step,spec)│               │
    │  │       │  → flow.llm_bound /│               │  primitive call
    │  │       │    alc.llm direct  │               │
    │  │       │  → post-verify     │               │
    │  │       │    (format mode)   │               │
    │  │       └────────────────────┘               │
    │  │                                            │
    │  │  after_dispatch (sequential)              │  response observe
    │  │    variant_ab.after  → stash _variant_*   │  (state side-effect)
    │  │    observability.after  → log/metrics     │  (alc.log etc.)
    │  └────────────────────────────────────────────┘
    │
    ▼
core return → consumer
```

Hook vocabulary:

- **before_dispatch(spec, ctx)**: mutates spec (variant pick rewrites
  the agent, trace_id injection, etc.). Order follows the plugins
  list.
- **around_dispatch(inner, spec, ctx)**: wraps the core dispatch.
  `inner` is the next plugin (or core). An onion structure that lets
  you write **multi-call control** such as iterate / retry / vote.
- **after_dispatch(response, spec, ctx)**: observes the response.
  Stash / log / metrics. spec and response are immutable (side-effect
  only).

## 4. Plugin Contract

```lua
plugin = {
    -- required
    name = "variant_ab",          -- string id (debug, ordering)

    -- optional factory (recommended for opts injection):
    create = function(plugin_opts) ... end,
    -- if .create exists, caller writes:
    --   require("plugin_variant_ab").create({ abtest_agents = {...} })
    -- factory returns the instance; calling create is the caller's choice.

    -- optional lifecycle hooks (each may be nil):
    before_dispatch = function(spec, ctx) ... end,
    around_dispatch = function(inner, spec, ctx) ... end,
    after_dispatch  = function(response, spec, ctx) ... end,
}
```

`ctx` shape (assembled by the Frame and handed to plugins):

```lua
ctx = {
    path     = "/pkg/step/agent",   -- original path or bare step
    step     = "step",              -- step_id_of(path)
    state    = <flow state table>,  -- opts.state, as-is
    extras   = <dispatcher.extras>, -- Phase 1 opaque dict (read)
    scratch  = {},                  -- per-dispatch scratchpad shared across plugins
    -- (any consumer-supplied ctx fields)
}
```

## 5. Core dispatch loop (pseudo-Lua)

```lua
function M.make_dispatcher(opts)
    -- (Phase 1 validation)
    local builder   = opts.builder
    local state     = opts.state
    local llm_opts  = opts.llm_opts
    local extras    = opts.extras or {}
    local flow_pkg  = opts.flow  or require("flow")
    local frame_pkg = opts.frame or require("swarm_frame")
    local alc_pkg   = opts.alc   or _G.alc

    -- Phase 2: plugins
    local plugins = opts.plugins or {}
    for _, p in ipairs(plugins) do
        assert(type(p) == "table" and type(p.name) == "string",
            "plugin must be { name=string, ... }")
    end

    local function core_dispatch(spec, ctx)
        local prompt = builder(ctx.step, spec)
        local mode   = frame_pkg.check_mode()
        local response
        if mode == "non-check" then
            response = alc_pkg.llm(prompt, llm_opts)
        else
            response = flow_pkg.llm_bound(state, {
                slot     = ctx.step,
                prompt   = prompt,
                llm_opts = llm_opts,
            })
        end
        if mode == "format" then
            -- (existing format-mode post-verify, BLOCKED string on
            --  format-non-json / missing fields / slot mismatch)
            response = format_post_verify(response, ctx.step, frame_pkg)
        end
        return response
    end

    return setmetatable({
        extras  = extras,
        plugins = plugins,
    }, {
        __call = function(_self, path_or_step, spec, _ctx)
            local ctx = _ctx or {}
            ctx.path    = path_or_step
            ctx.step    = step_id_of(path_or_step)
            ctx.state   = state
            ctx.extras  = extras
            ctx.scratch = {}

            -- before_dispatch (sequential)
            for _, p in ipairs(plugins) do
                if p.before_dispatch then p.before_dispatch(spec, ctx) end
            end

            -- around_dispatch (onion wrap)
            local wrapped = core_dispatch
            for i = #plugins, 1, -1 do
                local p = plugins[i]
                if p.around_dispatch then
                    local inner = wrapped
                    wrapped = function(s, c) return p.around_dispatch(inner, s, c) end
                end
            end
            local response = wrapped(spec, ctx)

            -- after_dispatch (sequential)
            for _, p in ipairs(plugins) do
                if p.after_dispatch then p.after_dispatch(response, spec, ctx) end
            end

            return response or ""
        end,
    })
end
```

## 6. Plugin examples

### 6.1 variant_ab (A/B variant — an application)

A plugin version of a variant-pick hook + per-step dispatch stash
pattern:

```lua
-- packages/plugin_variant_ab/init.lua
local M = {}

function M.create(opts)
    local abtest_agents = opts.abtest_agents or {}
    local agent_type_map = opts.agent_type_map or {}

    return {
        name = "variant_ab",
        before_dispatch = function(spec, ctx)
            if not (spec.agent and abtest_agents[spec.agent]) then return end
            local variant = pick_variant(spec.agent, ctx.step, ctx.state)
            if variant == "green" and agent_type_map[spec.agent .. "/green"] then
                spec.variant_id = "green"
                spec.admission  = "pass"
                spec.agent      = spec.agent .. "/green"
            else
                spec.variant_id = "blue"
                spec.admission  = "pass"
            end
        end,
        after_dispatch = function(response, spec, ctx)
            if not spec.variant_id then return end
            -- Choose your own state-namespace field name. The plugin
            -- owns its stash key; the Frame does not interpret it.
            ctx.state.data.variant_dispatches =
                ctx.state.data.variant_dispatches or {}
            ctx.state.data.variant_dispatches[ctx.step] = {
                agent         = (spec.agent or ""):gsub("/green$", ""),
                agent_key     = spec.agent,
                variant_id    = spec.variant_id,
                admission     = spec.admission,
                dispatched_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                response      = response,
            }
        end,
    }
end

return M
```

Use from a consumer:

```lua
local variant_ab = require("plugin_variant_ab")
ctx.dispatcher = adapter.make_dispatcher({
    builder = ...,
    state   = st,
    plugins = {
        variant_ab.create({
            abtest_agents  = { ["@domain-modeler"] = true },
            agent_type_map = AGENT_TYPE_MAP,
        }),
    },
})
-- Finalizing variant cards at the end of M.run lives elsewhere in
-- consumer code (a separate module, not in the Frame).
```

### 6.2 cascade (cheap → expensive escalation — core example 1)

```lua
-- packages/plugin_cascade/init.lua
function M.create(opts)
    local stages = opts.stages or { "haiku", "sonnet", "opus" }
    return {
        name = "cascade",
        around_dispatch = function(inner, spec, ctx)
            local last_response
            for _, model in ipairs(stages) do
                local stage_spec = util.shallow_copy(spec)
                stage_spec.llm_opts_override = { model = model }
                last_response = inner(stage_spec, ctx)
                local v = ctx.frame.parse_verdict(last_response)
                if v.status == "DONE" then return last_response end
            end
            return last_response
        end,
    }
end
```

### 6.3 vote (N-of-M majority — core example 2)

```lua
function M.create(opts)
    local n = opts.n or 3
    local aggregator = opts.aggregator or majority_by_status
    return {
        name = "vote",
        around_dispatch = function(inner, spec, ctx)
            local responses = alc.parallel(n, function() return inner(spec, ctx) end)
            return aggregator(responses)
        end,
    }
end
```

(`alc.parallel` is an algocline primitive; the Frame does not get
involved in its internals.)

### 6.4 reflexion (critique + retry — core example 3)

```lua
function M.create(opts)
    local max_iter = opts.max_iter or 3
    return {
        name = "reflexion",
        around_dispatch = function(inner, spec, ctx)
            local response = inner(spec, ctx)
            for i = 1, max_iter do
                local v = ctx.frame.parse_verdict(response)
                if v.status == "DONE" then return response end
                local critique = critique_fn(response, spec, ctx)
                local retry_spec = util.shallow_copy(spec)
                retry_spec.prompt = spec.prompt .. "\n\n[Critique]\n" .. critique
                response = inner(retry_spec, ctx)
            end
            return response
        end,
    }
end
```

Each plugin is an **independent Lua package** and can ship from a
separate repo. Compose it via `require("plugin_cascade")` and so on.

## 7. Migration path

| Convention-based middleware | Frame plugin |
|---|---|
| `variant_ab` middleware (before_dispatch: variant-pick hook) + finalize routine | `plugin_variant_ab` (before + after); finalize lives in consumer code or a separate module |
| `retry` middleware (around_dispatch) | `plugin_retry` (around_dispatch) — as-is |
| `observability` middleware (before + after) | `plugin_observability` (before + after) |
| `inject_deps` middleware (before_dispatch) | `plugin_inject_deps` (before) |
| `template_resolve` middleware (before) | `plugin_template_resolve` (before) |

The convention-based path **coexists** for now. Whether to rewrite a
given middleware as a Frame plugin is decided per consumer:

- Consumers whose dispatcher is already on the Frame can compose a
  plugin (`plugin_variant_ab` etc.) directly.
- **TODO**: consumers still on the convention-based delegate migrate
  in turn once the Phase 2 plugins are in place.

## 8. Test plan

### Frame side (swarm_frame_algocline)

~10 cases (current `tests/run.lua` covers the equivalent through the
193-case suite):

- Without plugins, behavior matches Phase 1 (regression).
- A plugin's before_dispatch mutates spec.
- A plugin's after_dispatch observes response (immutable).
- A plugin's around_dispatch wraps core (onion order).
- Multiple plugins run in ipairs order.
- A malformed plugin shape throws.
- Mixed before / around / after execution.
- `ctx.scratch` / `ctx.extras` / `ctx.state` are readable from plugins.
- A multi-call (3 inner calls) inside around_dispatch works.
- Errors inside a plugin propagate through the dispatcher.

### Plugin side (each `plugin_*/init.lua` + test)

Unit tests per plugin module.

### Consumer side

**TODO**: activate `plugin_variant_ab` in a consumer and demonstrate
parity with the existing variant behavior (first integration test
after the Phase 2 plugin pipeline lands).

## 9. Phased plan

1. **Done** — Review this design and fix the scope (plugin contract /
   hook kinds / ctx shape).
2. **Done** — Implement the plugin pipeline in
   `swarm_frame_algocline.make_dispatcher`.
3. **Done** — Add plugin tests to `tests/run.lua`.
4. **Done** — Commit 1 (swarm-frame repo): plugin pipeline + tests.
5. **TODO** — Implement `plugin_variant_ab` as a standalone package
   (~30 LOC) + tests.
6. **TODO** — Commit 2 (swarm-frame or consumer repo):
   `plugin_variant_ab`.
7. **TODO** — Activate `plugin_variant_ab` in a real consumer
   (migrate from `extras` to the `plugins` path) + clean up
   variant-card finalization.
8. **TODO** — Provide `plugin_cascade` / `plugin_vote` /
   `plugin_reflexion` and other Swarm-style logic as plugins
   (separate task group).

## 10. Risks / Notes

- Plugin order sensitivity: behavior changes with ordering (e.g.
  `variant_ab.before` → `cascade.around` vs. `cascade.around` →
  `variant_ab.before`). Explicit ordering plus a discipline that each
  plugin documents its "expected position" is required.
- `ctx.scratch` collisions: writing the same key from multiple
  plugins overwrites. A namespace-prefix discipline
  (`ctx.scratch.variant_ab.trace_id`) is recommended.
- Multi-wrapping `around_dispatch`: combinations like vote inside
  cascade multiply dispatch cost by N × M → the consumer is
  responsible for the combination.
- Async / yield inside plugins: today `around_dispatch` is
  synchronous (`alc.parallel` manages yield internally). The Frame
  itself does not add an async mechanism.
- Direction of dependency: plugins use algocline primitives
  (`alc.parallel`, etc.) **inside their own implementation**. The
  Frame itself does not know about those primitives. API changes on
  the algocline side are the plugin maintainer's responsibility to
  follow.

Draft / WIP — feedback welcome; discard if off.
