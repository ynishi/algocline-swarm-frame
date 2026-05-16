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
│   │   ├── init.lua          -- frame core
│   │   ├── normalize.lua     -- normalize_ctx primitive
│   │   └── plain_state.lua   -- State container
│   └── swarm_frame_algocline/
│       └── init.lua          -- algocline adapter (Token & Prompt)
├── examples/
│   └── bundled_base_curator/ -- 6-step pipeline reference impl
├── tests/
│   └── run.lua               -- Lua test suite (193 cases)
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

# Run the test suite (193 cases, Pure Lua — no algocline required)
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

v0.2.0. Frame core (`swarm_frame` v0.1.1), Token & Prompt round-trip
primitive (`swarm_frame_algocline` v0.1.1), and Swarm aggregate plugin
(`swarm_aggregate_plugin` v0.1.0) bridging multi-agent debate (dmad
/ Du 2023) onto the dispatcher. 193 lua tests + mock smoke + real-LLM
e2e (agent-block) all passing. Hub `hub_index.json` (3 entries) for
`alc init` / `alc_hub_search` consumption.

## License

Dual-licensed under MIT or Apache-2.0 at your option. See
`LICENSE-MIT` and `LICENSE-APACHE`.
