# swarm_frame_algocline — Token & Prompt round-trip primitive (Design)

Status: draft (2026-05-12, scope narrowed to primitive extraction)
Related: design/design-doc.md / design/token-strict-mode.md

Draft / WIP — feedback welcome; discard if off.

## 1. Problem

A downstream consumer's delegate implementation has typically wrapped
`flow.llm_bound` inside a thicker domain layer (middleware, variant
routing, shape validation, prompt-size warnings). The **Token & Prompt
round-trip portion** itself — builder invocation → `flow.llm_bound` —
is a thin wrapper. No caller ever reaches that primitive directly,
while `flow.llm_bound` itself is already a complete token round-trip
apparatus. The token mechanism (token.issue → a per-slot resume marker
persist → echo verify) can therefore be extracted as an independent
primitive.

Cost of leaving it un-extracted:

- `flow.llm_bound` is unreachable without going through the consumer's
  middleware / variant / shape domain logic (the thin primitive layer
  is missing).
- Lightweight one-shot prompts that don't need the token round-trip
  still have to go through `flow.llm_bound` (no "direct-prompt
  pattern").
- There is no hard surface that guarantees "just Token & Prompt
  round-trip, reliably".

## 2. Scope (narrow)

**This task's sole responsibility**:

- Land the Token & Prompt round-trip primitive (`step_id_of` +
  builder acceptance + prompt routing) in `swarm_frame_algocline`.
- Routing has 2 paths, selected by `swarm_frame.check_mode()`:
  - **"strict"** (default) → via `flow.llm_bound` (token round-trip
    on; send + receive verify is closed inside flow).
  - **"non-check"** → call `alc.llm` directly (no token round-trip;
    the "direct-prompt pattern").
- Provide an adapter call site that downstream delegate
  implementations can invoke for **just the Token & Prompt portion**,
  leaving their domain logic untouched.

**Out of scope** (stays in consumer code):

- Builder content (system prompt assembly, agent-type maps, instruction
  templates).
- Middleware system (retry / variant_ab / observability / inject_deps
  / template_resolve) — see `design/plugin-abstraction.md` for the
  Frame-side path to express these as plugins.
- Variant Producer stash + finalize routines.
- Shape validation paths (`shape_dev` / `shape_light`).
- Prompt size warning (e.g. `PROMPT_HINT_WARN_BYTES`).
- Package-name injection.
- Agent-id tail regex extraction.

These are domain logic and do not migrate into the Frame.

**`flow.llm_bound`'s own behavior (including echo verify's fail-open)
is inherited verbatim**. The adapter **adds no extra verification**.
Tightening echo into strict mode is out of scope for this task — it
is taken up as a separate task (a flow upstream PR, or opt-in
verification at each consumer's entry point).

## 3. Architecture (ASCII)

```
consumer (a downstream orchestration package)
    │
    │  delegate = make_delegate(cfg, st)
    │  -- consumer-side surface preserved. middleware / variant /
    │     builder still apply here.
    ▼
make_delegate (Domain logic, lives in consumer code)
    │
    │  - middleware chain (before/around/after)
    │  - variant pick + stash
    │  - shape validate
    │  - prompt size warn
    │  - builder(phase, spec) assembles the instruction
    │
    │  -- ↓↓ only Token & Prompt round-trip is delegated to the Frame ↓↓
    │  dispatcher = swarm_frame_algocline.make_dispatcher({
    │      builder  = function(step, spec_) ... cfg.builder(...) end,
    │      state    = st,
    │      llm_opts = { system = cfg.system, max_tokens = cfg.max_tokens },
    │      flow     = orch_rt.flow(cfg),   -- runtime override compatible
    │  })
    │  return dispatcher(phase, spec)
    ▼
swarm_frame_algocline.make_dispatcher (Primitive: Token & Prompt)
    │
    │  return function(path_or_step, spec, _ctx)
    │    local step   = step_id_of(path_or_step)
    │    local prompt = builder(step, spec)
    │    local mode   = swarm_frame.check_mode()      -- 'strict' | 'non-check'
    │    if mode == "non-check" then
    │      return alc.llm(prompt, llm_opts)           -- no token round-trip
    │    else  -- "strict" (default)
    │      return flow.llm_bound(state, {             -- token round-trip on
    │        slot     = step,
    │        prompt   = prompt,
    │        llm_opts = llm_opts,
    │      })
    │    end
    │  end
    ▼
flow.llm_bound (algocline-bundled flow package) — unchanged
    │
    │  - token.issue(st) → tok.value
    │  - state.data: per-slot resume marker persist
    │  - prompt ++ "[flow_token=...][flow_slot=...]"
    │  - alc.llm(prompt, llm_opts)
    │  - echo verify: mismatch → error / absent → fail-open
    │  - per-slot resume marker clear
    ▼
alc.llm (algocline-engine bridge)

Dependency direction: consumer → consumer's delegate → swarm_frame_algocline → flow / alc
(the Frame does not require any specific consumer package)
```

## 4. API (Frame side)

```lua
-- swarm_frame_algocline/init.lua

local M = {}

M.VERSION = "0.1.0"

M.meta = {
    name        = "swarm_frame_algocline",
    version     = "0.1.0",
    category    = "frame_primitive",
    description = "Token & Prompt round-trip primitive — routes prompts to "
        .. "flow.llm_bound (strict / format) or alc.llm directly (non-check), "
        .. "with format-mode post-verify for JSON-shape conformance.",
}

--- step_id_of("/pkg/step_1/agent") -> "step_1"
--- step_id_of("step_1") -> "step_1"  (bare step passes through unchanged)
function M.step_id_of(path) ... end

--- Build the Token & Prompt round-trip dispatcher.
---@param opts {
---     builder  : fun(step:string, spec:table):string,  -- required
---     state    : table,                                -- required for strict mode (algocline flow state); unused in non-check mode
---     llm_opts : table?,                               -- forwarded (system / max_tokens / ...)
---     flow     : table?,                               -- test injection (defaults to require("flow"))
---     frame    : table?,                               -- test injection (defaults to require("swarm_frame"))
---     alc      : table?,                               -- test injection (defaults to _G.alc); used in non-check mode
---     extras   : table?,                               -- opaque pass-through slot for consumer-side plugin config
---     plugins  : plugin[]?,                            -- plugin pipeline (see design/plugin-abstraction.md)
--- }
---@return fun(path_or_step:string, spec:table, ctx:table?):string
function M.make_dispatcher(opts) ... end

return M
```

## 5. Token continuity (why there is no regression)

| Aspect | Before (bind inside consumer's delegate) | After (via Frame.make_dispatcher) | Regression |
|---|---|---|---|
| `token.issue` | inside `flow.llm_bound` | inside `flow.llm_bound` (strict path) | none |
| a per-slot resume marker persist | inside `flow.llm_bound` | inside `flow.llm_bound` (strict) | none |
| prompt tag append | inside `flow.llm_bound` | inside `flow.llm_bound` (strict) | none |
| echo mismatch → error | inside `flow.llm_bound` | inside `flow.llm_bound` (strict) | none |
| echo absent → silent pass | inside `flow.llm_bound` | inside `flow.llm_bound` (strict, fail-open inherited) | none |
| `llm_opts` pass-through | consumer code | `make_dispatcher` opts → `flow.llm_bound` / `alc.llm` | none |
| direct `alc.llm` path | none | new (opt-in via non-check mode) | **new capability** |

= the strict path inherits `flow.llm_bound` in full, so zero
regression. `non-check` is a new opt-in path aimed at cases where the
token round-trip is unnecessary overhead.

## 6. check_mode policy (init-time freeze)

`swarm_frame.init({ check_mode = "strict" | "non-check" | "format" })`
is the policy lever that freezes the mode exactly once. Mode meanings:

| mode | dispatcher routing | token round-trip | resume cue | use case |
|---|---|---|---|---|
| `"strict"` (default) | via `flow.llm_bound` | yes | a per-slot resume marker persist | typical session-spanning round-trip |
| `"non-check"` | direct `alc.llm` | no | none | lightweight one-shot prompts, the "direct-prompt pattern" |
| `"format"` | via `flow.llm_bound` + JSON-shape post-verify | yes | a per-slot resume marker persist | sessions where format conformance proves identity |

API:

- `swarm_frame.init({ check_mode = "strict" \| "non-check" \| "format" })`
  — freezes once. Subsequent calls are silent no-ops (first call wins).
- `swarm_frame.check_mode()` — returns the current mode (before
  `init`, defaults to `"strict"`).
- `swarm_frame._reset_for_testing()` — test only.

The adapter **reads the mode at runtime** and **adds no extra token
verification of its own**. Tightening `flow.llm_bound`'s echo into
strict mode is held as a separate task
(`design/token-strict-mode.md` is the deferred record).

## 7. Consumer-side change (the other half of this task)

In the consumer's delegate implementation, replace **only the Token &
Prompt portion** with a Frame call. Everything else stays
**untouched**.

```lua
local sfa = require("swarm_frame_algocline")

function M.bind(cfg, st)
    ...
    return function(phase_name, spec)
        ...
        local flow = orch_rt.flow(cfg)
        local a = orch_rt.alc(cfg)
        if a and a.log then
            a.log("info", cfg.pkg_name .. ": >>> " .. phase_name)
        end
        local dispatcher = sfa.make_dispatcher({
            builder = function(step, spec_)
                return cfg.builder(step, spec_, cfg.agent_type_map)
            end,
            state    = st,
            llm_opts = { system = cfg.system, max_tokens = cfg.max_tokens },
            flow     = flow,    -- compatible with cfg.runtime / set_runtime override
        })
        local response = dispatcher(phase_name, spec)
        if a and a.log then
            a.log("info", cfg.pkg_name .. ": <<< " .. phase_name .. " done")
        end
        return response or ""
    end
end
```

The wrapping `make_delegate` (middleware chain / variant stash / shape
validate / prompt warn / agent-id extraction) stays **fully
unchanged**. Only the **Token & Prompt** part inside `bind` is
delegated to the Frame.

## 8. Test plan

### Frame side (swarm_frame_algocline)

| Group | Count | Content |
|---|---|---|
| check_mode policy | 6+ | default strict / no-opts strict / non-check freeze / invalid raise / second call no-op / format mode acceptance |
| Token & Prompt primitive | 8+ | `step_id_of` × 2 / rejects missing opts / delegates via flow (happy) / `run_linear` integration / strict via flow / non-check via alc / non-check + alc unavailable raise / format-mode post-verify |

The full Lua test suite at `tests/run.lua` covers 193 cases (frame
core + adapter + plugin pipeline + parser + normalize + examples). On
`just test` all pass.

### Consumer side (regression)

After the `bind`-equivalent change in a consumer, that consumer's
existing test suite must continue to pass without modification. Domain
logic (middleware / variant / shape) is unchanged, so regressions
should be limited to anything that incidentally touched the Token &
Prompt boundary.

## 9. Phased plan

1. Design review (ytk) — Done.
2. Implement `init` / `check_mode` / `_reset_for_testing` in
   `swarm_frame` — Done.
3. Land `swarm_frame_algocline.make_dispatcher` with mode branching —
   Done.
4. Update `tests/run.lua` with check_mode + Token & Prompt primitive
   tests — Done.
5. Catch `examples/bundled_base_curator` up to the new adapter API —
   Done.
6. **commit 1** (swarm-frame repo): primitive + check_mode policy —
   Done.
7. **TODO**: replace the Token & Prompt portion of the consumer's
   delegate with the Frame call. Consumer-side regression run.
8. **TODO**: consumer-side commit recording the migration.

## 10. Risks / Notes

- Dependency direction is fixed: **consumer → consumer's delegate →
  swarm_frame_algocline → flow / alc**. The Frame **does not require**
  any consumer package.
- `swarm_frame_algocline` v0.1.0 surface: `builder` / `state` /
  `llm_opts` / `flow` / `frame` / `alc` / `extras` / `plugins`.
- Existing consumers stay on default `"strict"` and behave identically
  (going through `flow.llm_bound`, the same path as before extraction).
- `"non-check"` is a new opt-in. Only processes whose entry point
  calls `swarm_frame.init({ check_mode = "non-check" })` switch to
  direct `alc.llm` (a single freeze applies to every subsequent
  dispatch — by design).
- `"format"` is a stricter opt-in: identity verification rides on
  JSON-shape conformance rather than echo. Non-conformant responses
  become `BLOCKED reason=format-<detail>`. See
  `packages/swarm_frame_algocline/init.lua` for the post-verify shape.
- `flow.llm_bound`'s fail-open is not touched in this task. The
  deferred `design/token-strict-mode.md` captures the hardening
  proposal as a separate-task record.

Draft / WIP — feedback welcome; discard if off.
