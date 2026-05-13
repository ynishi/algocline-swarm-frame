# algocline-swarm-frame — Design Doc

Version: 0.1.0
Status: initial

## 1. Problem

Agent-orchestration pipelines built on algocline share a recurring
class of state-related issues:

- phase-transition state loss,
- missed BLOCKED checkpoints,
- the per-step boilerplate (`step_done` guard → spec dispatch →
  verdict parse → state mark) duplicated at every step.

The structural root cause is that **state mutation is touchable from
anywhere**. A convention-only abstraction can always be bypassed — a
pipeline can call `state_save` or assign into `state.data` directly,
so the same bug pattern keeps resurfacing as new pipelines are added.

This repo takes the opposite stance: a thin frame that **physically
owns** state mutation, session-key path routing, verdict parsing, and
BLOCKED propagation. User code only registers a spec (and optionally
a handler) per session-key path; the copy-paste sites disappear by
construction, not by guideline.

## 2. Output spec — what user code looks like

User code should only declare specs and handlers. State, session-key
routing, verdict parsing, step bookkeeping, and dispatcher boilerplate
are all handled by the frame.

```lua
local frame = require("swarm_frame")
local T     = require("lshape").t

frame.register("/bundled-base-curator/step_1/window-inferrer", {
    input  = T.shape({ task_dir = T.string }),
    result = T.shape({ start = T.string, ["end"] = T.string }),
    prompt = "Infer the observation window...",
})

-- ... register the remaining steps

function M.run(ctx)
    ctx.state = frame.state_new({ backend = frame.backend_file(path) })
    ctx.dispatcher = make_algocline_dispatcher(...)  -- adapter
    return frame.run_linear({
        "/bundled-base-curator/step_1/window-inferrer",
        "/bundled-base-curator/step_2/theme-inferrer",
        "/bundled-base-curator/step_3/corpus-fingerprint",
        "/bundled-base-curator/step_4/domain-researcher",
        "/bundled-base-curator/step_5/bundled-base-vetter",
        "/bundled-base-curator/step_6/report-writer",
    }, ctx)
end
```

## 3. Core split (Pure & Thin)

```
packages/swarm_frame/
├── contract        -- lshape-based handler I/O contract (direct dependency)
├── state           -- container + backend interface (file / sqlite / memory)
│                      explicit methods first: get/set/commit/dump/restore
│                      fully dumpable (inherits lshape Persistable invariant)
├── session_key     -- path resolution: "/pkg/step/agent"
│                      URL-like *appearance* only; no HTTP / server concepts
├── parallel        -- thin wrapper over algocline's existing parallel API
└── handler         -- frame.register(path, spec, handler?) entry IF
                       no decorator sugar; metatable used only for state access
```

Out of core (deferred to middleware or user code):

- gate / phase-boundary invariant enforcement
- blocked_return / guarded_delegate
- `verdict_loop` / `log_phase` / `step_mark` — kept available as
  primitives on the State surface, but their composition into the
  step-loop is provided by `frame.run_linear` so consumers no longer
  hand-write them.

## 4. Schema validation — 3 modes

| Mode      | Implementation                                                    | Default        |
|-----------|-------------------------------------------------------------------|----------------|
| **Dev**   | `lshape.check.assert_dev` + `LSHAPE_CHECK=1` env                  | No-op if unset |
| **Warn**  | `swarm_frame.validate` wrapper: `check.check` → warn sink         | Runtime default|
| **Strict**| `lshape.check.assert` (throws on failure)                         | Opt-in (CI)    |

Mode precedence: `opts.mode` > `SWARM_FRAME_SCHEMA_MODE` env > `"warn"`.

The warn sink is a candidate for upstreaming into lshape itself (the
doctrine lives there); the wrapper is the local entry point for now.

## 5. State backend interface

```lua
-- abstract backend contract
local Backend = {}
function Backend:save(snapshot_table) end
function Backend:load()                 end
```

Initial implementation: file-backed JSON snapshot. Future backends
(SQLite, event-sourcing, in-memory + snapshot) plug in via the same
interface.

State is plain data only: no functions, userdata, or coroutines. This
guarantees lshape's persistable invariant — `:dump()` produces a
lossless JSON string and `:restore(json)` rebuilds an identical
container.

### 5.1 Two surfaces: `State` and `plain_state`

Two valid container shapes coexist for step bookkeeping. They expose
the same three primitives (`step_done` / `step_mark` / `log_phase`)
through different surfaces, neither deprecated:

| Surface | Container | Form | Used by |
|---|---|---|---|
| `swarm_frame.State` | opaque object | methods (`st:step_done(id)` …) | pipelines adopting `swarm_frame.state_new` |
| `swarm_frame.plain_state` | plain Lua lists | free functions (`plain_state.step_done(list, name)` …) | pipelines on algocline's `flow.state_new` |

The `State` surface stores `_step_done` as a hash and `_log` as a
record list. The `plain_state` surface operates on the plain-list
convention used by pipelines that integrate with algocline's
`flow.state_new` directly (`state.completed_steps` as a string list,
`pipeline_log` as a record list). The two are not interchangeable
data-shape-wise; they are interchangeable *primitive-wise*. Each
pipeline picks whichever container matches its flow integration. See
`packages/swarm_frame/plain_state.lua` for the migration-from-closures
pattern intended for pipelines that previously rolled the same
bookkeeping by hand.

## 6. Session-key path format

Example path: `/coding/phase_b/impl_lead/subtask_3`

- Segments are hierarchical (pipeline / phase / agent / subtask).
- Dispatch is plain Lua table lookup (no HTTP server semantics).
- Registry lives inside the frame; user code touches it only via
  `frame.register(path, ...)`.

Flask / FastAPI implementations are intentionally **ignored**. Only
the concept (a human-readable hierarchical dispatch key) is adopted.
Pulling in server-side details would make an agent runtime look like
a web server.

## 7. Proof-of-concept target

A 6-step linear pipeline of moderate size (well-shaped consumer of an
existing convention-based delegate, no accumulated patch noise) is the
proof-of-concept target. The PoC lives under `examples/bundled_base_curator/`
and exercises the frame end-to-end via the same DONE / BLOCKED /
NEEDS_INPUT semantics that production pipelines depend on.

## 8. Roadmap

1. **Done** — Initial design + frame core skeleton + a passing Lua test
   suite (`just test`).
2. **Done** — `swarm_frame_algocline.make_dispatcher` adapts the
   builder → flow.llm_bound boundary into a `ctx.dispatcher`
   interface, verified by mocked test cases.
3. **Done** — `examples/bundled_base_curator/init.lua` rewrites a
   6-step curation pipeline on swarm-frame; mock-runtime integration
   confirms end-to-end DONE / BLOCKED / NEEDS_INPUT semantics match
   the equivalent convention-based delegate contract (see
   `examples/README.md`).
4. **Done** — Measured deltas on the PoC (consumer ↔ swarm-frame
   port):

   | Metric                          | Before          | After (swarm-frame) | Delta       |
   |---------------------------------|-----------------|---------------------|-------------|
   | per-step boilerplate copies     | one per step    | 0 (frame-managed)   | every site  |
   | direct state-access sites       | many            | a few (resume-cue bridging only) | large reduction |
   | `step_mark` / `log_phase` calls | one per step    | 0 (frame-managed)   | every site  |
   | inline `parse_verdict`          | yes             | uses `frame.parse_verdict` | removed |

   The remaining direct state-access sites in the ported PoC are
   the algocline-flow-state → swarm-frame State resume-cue bridge.
   They disappear once a State backend adapter maps algocline flow
   state directly into the frame's backend interface.

5. **TODO** — Production migration of downstream consumers. The order
   is left to each consumer: smaller, cleaner pipelines first to
   validate the migration path; consumers with accumulated
   convention drift come last.

## 9. Open questions

- ~~The shape of the algocline dispatcher adapter~~ → **Resolved**:
  separate `swarm_frame_algocline` package (kept in the same repo for
  now). The core stays algocline-agnostic; only the adapter imports
  algocline-specific dependencies. Verified end-to-end via mocks in
  `tests/run.lua`.
- **TODO**: whether to upstream the warn sink into lshape now or wait
  until the PoC is observed in production-ish use.
- The chained vs. plain-call API style for `frame.register` — current
  decision: plain calls, no metatable sugar.
