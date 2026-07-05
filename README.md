# algocline-swarm-frame

A thin runtime frame for ProgramableSwarm — a Lua-based agent orchestration
back-stage on algocline. The frame provides the parts user code should
never have to think about: state management, session-key path routing,
parallel agent spawn, and lshape-anchored handler contracts.

```lua
local frame = require("swarm_frame")
local T     = require("lshape").t

frame.register("/coding/phase_b/impl_lead", {
    input  = T.shape({ subtask = T.string, ctx = T.table }),
    result = T.shape({ status = T.string, diff = T.string:is_optional() }),
}, function(ctx)
    local task = ctx.state:get("current_task")
    -- agent dispatch is handled by the frame (spawn / state save / log)
    return "DONE path=/tmp/diff.json"
end)

function M.run(ctx)
    ctx.state = frame.state_new({ backend = frame.backend_file("...") })
    return frame.run_linear({
        "/coding/phase_b/impl_lead",
        -- ... other phases
    }, ctx)
end
```

## Package status

This repository ships two generations of packages side by side.

**Recommended for new work (flow.ir + mse stack)**

| Package | Role |
|---|---|
| `swarm_blueprint` | Pure Lua builder DSL that produces flow.ir + mlua-swarm-engine Blueprints (Node / Expr / AgentDef with exact serde-wire field names, including `call_extern` and `mod`). |
| `swarm_patterns` | Blueprint generators (`patterns.panel` / `patterns.reflect` / `patterns.sc` / `patterns.ucb`) that turn algocline-proven strategy patterns into ready-to-run Blueprints for [`mlua-swarm-engine`](https://github.com/ynishi/mlua-swarm-engine). Execution — state, parallel spawn, escalation, observers — lives in the Rust engine. |

**Deprecated (kept for existing consumers, notably algocline OrchV1)**

| Package | Note |
|---|---|
| `swarm_frame` | Lua-side thin runtime for the V3 pipeline shape. |
| `swarm_host_alc` | Host adapter for `swarm_frame` on algocline (state / prompt / dispatcher). |
| `verdict_swarm_pipeline` | 7-step verdict-driven pipeline built on `swarm_frame`. |

The deprecated packages continue to work and are not scheduled for
removal; the OrchV1 path stays productive on them. What changes for new
work is: authorship moves to declarative Blueprints (Lua data, no
execution) and runtime concerns move into the Rust engine (mse).

## Why

Agent-orchestration pipelines built on algocline share a
recurring class of state-related issues: phase-
transition state loss, missed BLOCKED checkpoints, and the per-step
boilerplate (`step_done` guard → spec dispatch → verdict parse →
state mark) duplicated at every step. Once that boilerplate is
copy-pasted, the same bug pattern keeps resurfacing.

A convention-only abstraction is bypassable — a pipeline can always
touch state directly. This repo takes the opposite stance: a thin
frame that **physically owns** state mutation, session-key path
routing, verdict parsing, and BLOCKED propagation. User code only
registers a spec (and optionally a handler) per session-key path;
the copy-paste sites disappear by construction, not by guideline.

## Design principles

- **Pure & thin.** The frame knows nothing about orchs, agents, or
  domain logic. One-way dependency. lshape contracts live as plain data.
- **State is fully dumpable.** Inherits lshape's persistable-by-
  construction invariant: any state snapshot survives a JSON round-trip.
- **Back-stage everything.** User code writes only the agent dispatch
  handler. State, session-key routing, async spawn are hidden.
- **Explicit methods first.** `ctx.state:set(k, v)` / `:commit()` to
  start. Metatable-based transparent access is deferred until specific
  save-only cases are identified.
- **Three-mode schema validation.** Dev (env-gated), Runtime
  WarnFallback (default), and Strict (immediate fail).

## Repo layout

```
algocline-swarm-frame/
├── packages/
│   ├── swarm_frame/
│   │   ├── init.lua              -- frame core
│   │   ├── normalize.lua         -- normalize_ctx primitive
│   │   ├── plain_state.lua       -- State container
│   │   ├── artifact_store.lua    -- artifact store + backends + summarize
│   │   └── spec/
│   │       ├── init_spec.lua
│   │       ├── plain_state_spec.lua
│   │       └── artifact_store_spec.lua
│   └── swarm_frame_algocline/
│       ├── init.lua              -- algocline adapter (Token, Prompt, resolve_task_dir)
│       └── spec/
│           └── resolve_task_dir_spec.lua
├── examples/
│   └── bundled_base_curator/ -- 6-step pipeline reference impl
├── tests/
│   └── run.lua               -- Lua test suite (236 cases)
├── justfile
├── LICENSE-MIT / LICENSE-APACHE
└── README.md
```

## Dependencies

- [lshape](https://github.com/ynishi/lshape) — Schema-as-Data +
  persistable validator, the SSoT schema lib of this repo.
- algocline core ≥ 0.26 — executed via `alc.run` / `alc.llm` /
  `alc_continue`.

## Setup

The Frame is consumed by algocline strategies through a **local
symlink** onto algocline's package search path
(`~/.algocline/packages/`).

```
git clone https://github.com/ynishi/algocline-swarm-frame.git
cd algocline-swarm-frame

# Run the test suite (236 cases, Pure Lua — no algocline required)
just test

# Link the two packages onto algocline's search path. The packages/
# directory itself is passed; alc_pkg_link descends into each
# sub-dir and links them all in one shot.
algocline pkg-link <abs-path-to-this-repo>/packages --force

# or, via the algocline MCP:
# alc_pkg_link(path: "<abs-path>/packages", force: true)
```

After linking, `require("swarm_frame")` and
`require("swarm_frame_algocline")` resolve at runtime inside any
algocline strategy. Edits to `packages/*/init.lua` are reflected on
the next `alc_run` without re-linking (symlink, not a copy).

## Distribution

**Current scope: local development via `alc_pkg_link` only.**

`alc_pkg_install <git-url>` (remote Git → collection install) is
intentionally **out of scope** for v0.1. Remote-install support may
be revisited later; if so, the `packages/<name>/init.lua` layout
and an optional `alc.toml` collection descriptor will be
reconsidered against algocline's collection-discovery rules at that
time. Until then, users consuming the frame should clone the repo
and `alc_pkg_link` the `packages/` directory as shown in "Setup".

## Status

v0.11.0. Frame core (`swarm_frame` v0.10.0) with control-flow
combinators (sequence / loop / branch / verdict_loop) on top of the
v0.8.0 artifact store, ctx-aware gate routing, and Rich Verdict
2-layer separation. Token, Prompt, task-dir resolver, and step
lifecycle hooks + `ctx.dispatch` primitive
(`swarm_frame_algocline` v0.3.0). Swarm aggregate plugin
(`swarm_aggregate_plugin` v0.1.0) bridging multi-agent debate (dmad /
Du 2023) onto the dispatcher. Verdict-loop step wrapper plugin
(`verdict_loop_plugin` v0.1.0) — gate-verdict-fix-retry on top of
`around_step` + `ctx.dispatch`. Domain-aware state update verbs
(`swarm_state_method` v0.1.0) composing algocline's namespace-generic
state primitive (Alc MCP layer in algocline >= v0.44.0) into
business actions callable via `alc_advice`. Lua tests (358 cases) +
mock smoke + real-LLM e2e (agent-block) all passing. Hub
`hub_index.json` for `alc init` / `alc_hub_search` consumption.

### Domain state update verbs (v0.10.0)

`swarm_state_method` v0.1.0 lands the Swarm package layer of the
algocline state primitive 2-layer split (`algocline/docs/state-management.md`
§Phase C). It exposes domain verbs that compose the namespace-generic
Alc MCP primitive (`alc.state.show` / `alc.state.set_dispatched`) into
single business actions, callable directly through:

```
mcp__algocline__alc_advice
  strategy=swarm_state_method
  opts={"action":"update_dispatch_record", "namespace":"...", "key":"...", "update":{...}}
```

Initial verb:
- `update_dispatch_record` — shallow-merges a patch into an existing
  record's `state.data` via show → merge → set_dispatched; preserves
  `identity` and non-overlapping data fields.

The package absorbs the bridge return-shape variance (production
`alc.state.show` returns a JSON string, the docstring described a
table) through an `ensure_state_table` seam that decodes via
`alc.json_decode` when needed and accepts table-direct returns from
test mocks. The `opts.alc` injection seam follows the convention of
picking up `_G.alc` in production while letting tests pass a mocked table.

### Step lifecycle hooks + ctx.dispatch (v0.10.0, same release)

`swarm_frame_algocline` v0.3.0 adds `before_step` / `around_step` /
`after_step` plugin hooks on `make_dispatcher`, plus a bounded
`ctx.dispatch(spec)` primitive for caller-triggered inner dispatches
from inside `around_step`. This unlocks retry / fallback / fix-loop
patterns without leaking dispatcher state. The companion
`verdict_loop_plugin` v0.1.0 wraps a pipeline step with
gate-verdict-fix-retry loop semantics (V1 coding_orch
`_verdict_loop` 14 call-sites is the reference pattern). Multiple
instances co-exist in `opts.plugins` because each declares a single
`step_id` and other steps pass through transparently.

### Control-flow combinators (v0.9.0)

`swarm_frame.sequence` / `swarm_frame.loop` / `swarm_frame.branch` /
`swarm_frame.verdict_loop` are mechanism-only Handler factories.
Each returns a Handler matching the existing `run_linear` contract
(`fun(ctx, spec?) -> response`), so combinators nest freely inside
each other and inside `frame.register`. The Engine owns iteration,
predicate evaluation, cp_state idempotent persistence, and verdict
short-circuit; the caller owns `parser` / `cond` / `fix` (Application
policy). See `design/design-doc.md` §9 for the boundary and
`packages/swarm_frame/spec/combinator_composability_spec.lua` for
nesting contracts.

New surface:
- `swarm_frame.sequence({handlers = {...}, cp_key?})` — ordered handler list, short-circuits on non-DONE.
- `swarm_frame.loop({body, until_, max, cp_key?})` — bounded iteration with predicate exit.
- `swarm_frame.branch({cond, then_, else_?})` — single-shot dispatch on `cond(ctx)`.
- `swarm_frame.verdict_loop({gate, fix?, parser, max_retries, cp_key?})` — retry-on-FAIL with optional fix between attempts.

### Artifact store (v0.8.0)

`swarm_frame.artifact_store` provides a backend-agnostic store for
offloading agent payloads (text or JSON) to disk or memory during a
run. The interface is a 4-method contract (write / read / exists /
delete) that backends implement without any knowledge of format or
encoding; all payload-to-bytes conversion is scoped to
`artifact_store:offload`.

New surface:
- `swarm_frame.artifact_store(backend)` — store factory.
  `:offload(payload, {name, task_dir, format})` converts payload to
  bytes (`format="text"` via `tostring`, `format="json"` via
  `alc.json.encode`) and delegates raw bytes to the backend.
  Returns `abs_path, nil` on success or `nil, err` on failure.
- `swarm_frame.backend_artifact_file([opts])` — filesystem backend;
  joins `task_dir .. "/" .. rel_path`. No format logic inside.
- `swarm_frame.backend_artifact_memory()` — in-memory backend for
  tests; same 4-method contract, zero filesystem I/O.
- `swarm_frame.summarize(payload, {format, max_chars})` — standalone
  pure helper. No dependency on artifact_store or any backend;
  callable without instantiating a store.
- `swarm_frame_algocline.resolve_task_dir({project_root, task_id,
  namespace?})` — resolves the task workspace directory with a
  3-step priority: `ctx.project_root` → `ALC_PROJECT_ROOT` →
  `PWD`. Accepts an optional `_env` injector for test isolation.

### Rich Verdict 2-layer separation (v0.5.0)

`gate_decide` enforces a hard split between two responsibilities:

- **Internal transition layer**: `verdict:is_halting()` is the sole
  function that decides state-machine transition. No string-matching
  on `next_action`, `label`, or any other field inside the primitive.
- **Host information layer**: the full verdict object is stored
  verbatim in `state.data.gates[name].verdict` — `next_action`,
  `detail`, `raw`, `label` are passed through untouched for consumers.

New surface:
- `swarm_frame.plain_state.verdict(fields)` — Verdict factory; injects
  `is_halting()` via metatable. Custom override: pass
  `fields.is_halting = function(self) ... end`.
- `swarm_frame.plain_state.gate_decide(gates, completed_steps, name,
  verdict, save_fn?)` — Rich Verdict primitive (free-function form).
- `swarm_frame.State:gate_decide(name, verdict, save_fn?)` — method
  form; delegates to `plain_state.gate_decide` after lazy-initialising
  `_data.gates` / `_data.completed_steps`.

### Context-aware gate routing (v0.6.0)

`gate_decide` now accepts an optional `ctx` argument, enabling
per-call routing decisions based on the execution context.

New signatures:
- `swarm_frame.plain_state.gate_decide(gates, completed_steps, name,
  verdict, save_fn?, ctx?)` — free-function form extended with `ctx`.
- `swarm_frame.State:gate_decide(name, verdict, save_fn?, ctx?)` —
  method form; thin delegate that passes `ctx` through to
  `plain_state.gate_decide`.

`Verdict:applicable_under()` method:
- Factory-produced Verdicts carry an `applicable_under` field whose
  value domain is `"*"` (all strategies) or `list<string>` (explicit
  allow-list).
- Default implementation returns `self.applicable_under or "*"`.
- Factory-external literal Verdict tables that lack an
  `applicable_under` method are treated as universally applicable
  (`"*"`) — they never cause an error or unconditional skip.

Routing behaviour when `ctx` is provided:
- If `ctx.strategy` is in the verdict's `applicable_under` list (or
  `applicable_under == "*"`): normal transition proceeds.
- If `ctx.strategy` is not in the list: the gate is **skipped** —
  `gates[name].skipped = true` and `gates[name].skip_reason` are
  recorded; `retries` is incremented; `completed_steps` is not
  appended; `marked_at` is not set.
- The full verdict object is still stored in `gates[name].verdict`
  on skip (Rich Verdict pass-through contract applies to all paths).

Backward compatibility:
- Omitting `ctx` (or passing `nil`) preserves v0.5.0 bit-identical
  behaviour for all existing call sites. No changes to consumers
  using the 3-arg or 5-arg form are required.

## License

Dual-licensed under MIT or Apache-2.0 at your option. See
`LICENSE-MIT` and `LICENSE-APACHE`.
