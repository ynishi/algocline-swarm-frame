# Token check strict mode — Design

Status: **deferred (2026-05-12)** — When the scope of the Token &
Prompt primitive extraction (`design/delegate-extraction.md`) was
reorganized, the decision was made **not to add a separate echo
verify on the adapter side**. The convention-based delegate path has
no existing independent verification either, so the §3.2 adapter
post-verify in this doc is withdrawn. If strict-ification is resumed,
it should be taken up as a separate task in one of two forms:
(a) upstream a `strict_echo` option into `flow.llm_bound` itself, or
(b) opt-in add a SubAgent convention + a separate-layer verify at
each consumer's entry point.

This doc is retained as history and **should not be used as a
reference for new implementation**. The `check_mode` in `swarm_frame`
is no longer the strict / off toggle described here; it has been
redefined as a separate concept indicating **dispatcher routing
policy** (`strict` = routed through `flow.llm_bound` / `non-check` =
direct `alc.llm` call / `format` = `flow.llm_bound` + JSON-shape
post-verify). See `design/delegate-extraction.md §6 check_mode policy`
for details.

## 1. Problem (historical)

`flow.llm_bound` (in the algocline-bundled flow package) extracts
`[flow_token=...]` from the string returned by a SubAgent using
`flow.util.parse_tag`, but **silently passes when the extraction
result is `nil`** — a fail-open design.

```lua
-- flow.llm_bound (sketch)
local mismatch
if type(out) == "string" then
    local echoed_token = util.parse_tag(out, "flow_token")
    if echoed_token and echoed_token ~= tok.value then
        mismatch = "..."
    end
end
-- when echoed_token == nil, mismatch stays nil and passes
```

In other words, **if the SubAgent doesn't echo the token, the guard
is effectively off**.

The empirical observation that motivated this doc was that a chain of
3 SubAgent dispatches returned `"DONE path=..."` with no
`[flow_token=...]` tag, and the pipeline accepted all three in a row
— a path where verify never ran. Passing while the token is set but
no echo arrives is a **bug**.

## 2. Requirements (ytk's original intent)

- **Default is strict**: missing echoed_token → BLOCKED, mismatch →
  BLOCKED.
- **Silent pass only when a token-check-off mode is explicitly
  specified at init time**.
- The explicit opt-out is accepted only at init time and immutable
  afterward.
- Before declaring the guard "wired in," prove three axes via tests:
    - (a) default behavior is strict
    - (b) opt-out works only when explicit
    - (c) missing-echo detection is active

## 3. Original design (withdrawn)

### 3.1 Mode state management (swarm_frame side)

```lua
-- swarm_frame/init.lua (proposed at the time)

local _initialised      = false
local _token_check_mode = "strict"   -- default

--- Initialise the frame's token check policy. Default is strict —
--- the adapter will translate a missing or mismatched `[flow_token=...]`
--- echo into a BLOCKED verdict. Pass { token_check = "off" } only
--- when the caller is intentionally bypassing the round-trip guard
--- (e.g. local smoke harness that mocks the SubAgent return).
---
--- Immutable: the first init() call freezes the mode. Subsequent
--- init() calls are no-ops. Tests reset via M._reset_for_testing().
---@param opts { token_check?: "strict" | "off" }?
function M.init(opts)
    if _initialised then return end
    opts = opts or {}
    if opts.token_check ~= nil then
        if opts.token_check ~= "strict" and opts.token_check ~= "off" then
            error("swarm_frame.init: token_check must be 'strict' or 'off' (got "
                .. tostring(opts.token_check) .. ")")
        end
        _token_check_mode = opts.token_check
    end
    _initialised = true
end

function M.token_check_mode()
    return _token_check_mode
end

function M._reset_for_testing()
    _initialised      = false
    _token_check_mode = "strict"
end
```

This shape was later subsumed by the broader `check_mode` axis
described in `design/delegate-extraction.md §6` (strict / non-check /
format). The `token_check` axis itself is no longer a thing in the
implementation.

### 3.2 Adapter-side verify (withdrawn)

The original proposal added a post-verify inside the adapter's
dispatcher: in strict mode, a missing `flow_token` echo translates
into a `BLOCKED reason=flow-token-echo-missing slot=<step>` string
and returns. The mismatch case already throws inside `flow.llm_bound`,
so the adapter only had to catch the missing case.

This adapter-side post-verify was **withdrawn** when the scope was
reorganized in `design/delegate-extraction.md`. Rationale: the
convention-based delegate had no extra verification either, so adding
adapter-side post-verify would shift the boundary that consumers
already rely on. Hardening the round-trip is a separate task.

### 3.3 SubAgent convention (later stage, not pursued in this doc)

The original plan spelled out the obligation that SubAgents echo
`[flow_token=<value>][flow_slot=<slot>]` at the end of their verdict
line in their `agent.md` Output Format section. This would have been
the convention-side counterpart of the adapter post-verify.

Since the adapter post-verify is withdrawn, the convention update is
not pursued here. If strict-ification is picked up again as a
separate task, the convention update lands alongside it.

## 4. API table (historical)

| API | I/O | default |
|---|---|---|
| `swarm_frame.init(opts?)` | `opts.token_check = "strict" \| "off"` | strict |
| `swarm_frame.token_check_mode()` | -> "strict" / "off" | "strict" on first call |
| `swarm_frame._reset_for_testing()` | side effect | test only |
| `swarm_frame_algocline.make_dispatcher(...)` | dispatcher function | (was: strict post-check included) |

(Superseded by the implemented `check_mode` axis. See
`design/delegate-extraction.md §6`.)

## 5. Verification (3 test axes, historical)

If the design were to be revived, the original 3-axis test plan
would still apply: verify (a) default strict, (b) explicit opt-out,
(c) missing-echo detection.

## 6. Why this doc is held back

- The convention-based delegate has no independent token verification
  either (confirmed via grep). Adding adapter-side post-verify alone
  would change the boundary that consumers rely on without solving
  the root issue inside `flow.llm_bound`.
- A path to upstream a `strict_echo` option (or
  `token_check_required` flag) into `flow.llm_bound` itself remains
  as a separate-task **TODO**. That would close the gap at the
  primitive layer without shifting the adapter boundary.
- Until then, the swarm-frame side does not add adapter post-verify.
  The current silent pass in `flow.llm_bound` is documented as a
  known fail-open behavior; downstream consumers that need
  enforcement add it at their own SubAgent entry point.

## 7. Future tasks (TODO)

- **TODO**: upstream a `strict_echo` option into `flow.llm_bound`
  (separate task, requires coordination with the flow package
  maintainer).
- **TODO**: define a SubAgent `agent.md` Output Format convention
  that echoes `[flow_token=<value>][flow_slot=<slot>]`, and add a
  separate-layer verify at consumer entry points if the upstream
  flow fix is not available in time.

Both tasks are out of scope for this design doc and out of scope for
the current `swarm_frame_algocline` adapter.
