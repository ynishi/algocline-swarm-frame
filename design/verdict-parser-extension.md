# swarm_frame verdict parser extension (Design)

Status: implemented v0.4.1
Related: design/normalize-primitive.md (peer task) /
packages/swarm_frame/init.lua (existing `parse_verdict` and the
`parse_label_verdict` / `parse_and_assert` extensions)

Draft / WIP — feedback welcome; discard if off.

## 1. Problem

Frame `parse_verdict` is a **3-token fixed** parser: JSON envelope
(status + flow_token + flow_slot) plus legacy regexes `DONE path=` /
`BLOCKED reason=` / `NEEDS_INPUT missing=`. Downstream consumers each
have their own verdict vocabulary and hand-roll support for it. From
an inventory of downstream call sites, the hand-rolls cluster into
the following kinds:

| Kind | Hand-roll content |
|---|---|
| **3-token fuzzy variant** | `DONE[:=]<path>` separator + an upper-level bare `DONE` fallback. A small superset of Frame `parse_verdict`. |
| **label verdict** (PASS / BLOCKED / READY / NEEDS_HUMAN / HAS_FINDINGS / ...) | Search for the `VERDICT: <label>` form + priority resolution over multiple labels. |
| **composite** (FAIL without PASS, etc.) | Presence of token A + absence of token B. |
| **domain vocabulary** (NO_HYPOTHESES / DIFFBACK / pyho / Language / status YAML) | Consumer-specific tokens. |
| **JSON envelope** | `alc.json_extract` + field comparison (does not pass through the regex path). |

## 2. Scope (v0.1 minimum)

**The responsibilities of v0.1 were limited to**:

- Add an `opts.fuzzy` flag to the existing `parse_verdict(response)`
  (default: false). With `fuzzy = true`, absorb the upper-level bare
  `DONE` and `DONE[:=]<path>` separator variants.
- Add a new `parse_label_verdict(response, labels)`:
  - Search case-insensitively for the `VERDICT: <label>` form.
  - `labels` is an ordered array (earlier = higher priority).
  - Return the first label that hits / `nil` if none match.
- The existing 3-token contract of `parse_verdict`
  (DONE / BLOCKED / NEEDS_INPUT) is unchanged.

**Out of scope for v0.1** (future extension points; see §3):

- composite (FAIL without PASS).
- JSON envelope routing — the path itself differs.
- domain vocabulary (NO_HYPOTHESES / pyho / Language / status YAML).
- multi-form prefix (VERDICT: + Overall:) — promoted in v0.2.
- word-boundary fallback — promoted in v0.2.

## 3. Future extension points (extension points, not implemented in v0.1)

These could be added later as `opts` axes on `parse_label_verdict`:

| Axis | What it solves |
|---|---|
| `opts.forms = { "VERDICT:", "Overall:" }` | Multiple prefixes (variants of the label form). |
| `opts.fallback_negate = { bad = "BLOCKED", good = "PASS" }` | Word-boundary fallback when no VERDICT line exists (bad present + good absent → bad). |
| `opts.case_sensitive = true` | Strict upper-case token match. |
| `opts.line_anchor = true` | Match only at BOL. |
| Separate function `parse_label_with_confidence(r, labels)` | label+confidence 2-tuple of the form `VERDICT: <label> (<float>)`. |

Consumers that need these keep the hand-roll until the axis is
enrolled. Enrollment happens once a caller demand surfaces (YAGNI).

## 4. API shape

```
-- Existing, extended ───────────────────────────────────────────────
M.parse_verdict(response, opts) → table
  opts.fuzzy (boolean, default: false)
    - When true, additionally recognize:
      * "DONE: <path>" / "DONE= <path>"  (separator variants)
      * "BLOCKED: <reason>" / "BLOCKED= <reason>"
      * If none of the above match but response upper-cased contains
        "DONE" at an identifier boundary → status = "DONE", path = nil
  The existing JSON envelope / "DONE path=" / "BLOCKED reason=" /
  "NEEDS_INPUT missing=" contract is unchanged.

-- New ─────────────────────────────────────────────────────────────
M.parse_label_verdict(response, labels) → string | nil
  - labels: ordered array of strings (earlier = higher priority)
  - For each label, search case-insensitively for "VERDICT:%s*<label>"
  - Walk labels from the head; return the first label that hits
  - If no label matches → nil
  - response is nil → nil
  - labels is empty → nil

  -- Examples:
  -- pass_block (BLOCKED wins over PASS):
  --   parse_label_verdict(r, {"BLOCKED", "PASS"})
  -- needs_human, 3-valued:
  --   parse_label_verdict(r, {"NEEDS_HUMAN", "BLOCKED", "PASS"})
  -- ready/not_ready (NOT_READY wins):
  --   parse_label_verdict(r, {"NOT_READY", "READY"})
  -- pass/conditional/fail:
  --   parse_label_verdict(r, {"FAIL", "CONDITIONAL", "PASS"})
  -- has_findings:
  --   parse_label_verdict(r, {"HAS_FINDINGS", "CLEAN"})
```

## 5. v0.1 call-site coverage (validation, abstracted)

| Caller kind | Replacement in v0.1 |
|---|---|
| `parse_verdict` hand-roll with `DONE[:=]` separator / fuzzy bare DONE | `frame.parse_verdict(r, { fuzzy = true })` |
| `VERDICT: <label>` priority search (single label or multi-label priority) | `frame.parse_label_verdict(r, { ...labels... })` |

Not absorbable by v0.1 (hand-roll retained for that release):

- Word-boundary composite ("FAIL without PASS").
- `Overall:` form fallback in addition to `VERDICT:`.
- Domain vocabulary (NO_HYPOTHESES / DIFFBACK / pyho / Language /
  status YAML).
- JSON envelope routing.

These are addressed by the v0.2 / v0.3 enrollment described below.

## 6. Placement

```
packages/swarm_frame/
├ init.lua            (extends existing parse_verdict + adds parse_label_verdict + parse_and_assert)
├ plain_state.lua     (existing peer)
├ normalize.lua       (peer; added in the same Cat-A session)
```

`parse_label_verdict` / `parse_and_assert` are **added directly under
`init.lua`** (not split into separate modules):

- Same "verdict parsing" responsibility axis as the existing
  `parse_verdict`.
- Single functions, no benefit from sub-modules.
- The existing `parse_verdict` also lives directly under `init.lua`.

## 7. Consumer-side migration plan (separate per-consumer tasks)

1. **Done (Frame side)** — extend `parse_verdict` with `fuzzy`, add
   `parse_label_verdict`, add v0.2 / v0.3 / v0.4 enrollment, add
   `parse_and_assert`, add tests.
2. **TODO (Consumer side)** — replace consumer hand-rolls with Frame
   primitive calls. Done as separate per-consumer tasks once a
   regression baseline exists.

## 8. Open questions

- The v0.1 extension to `parse_verdict` adds a new `opts` argument —
  **does the existing caller API signature change?** Verified:
  callers that only invoke `parse_verdict(response)` continue to work
  (when `opts` is nil the default path is taken, behaviorally
  identical to before). Backward-compatible.
- Should `parse_label_verdict`'s return type be `string | nil` or
  `table { matched=string|nil, raw=string }`? → For v0.1, keep it
  simple as `string | nil`. If a caller needs `raw`, expand the
  surface in a later release.
- The prefix `"VERDICT:"` for `parse_label_verdict` is a fixed
  default in v0.1. Multiple prefixes via `opts.forms` enrolled in
  v0.2.

## 9. v0.2 extension (3-axis enrollment)

### 9.1 Motivation

The v0.1 minimum (`VERDICT:` prefix required) initially claimed it
could absorb a handful of consumer hand-rolls. Inspection of those
hand-rolls in practice revealed that **bare token search dominates**
across the inventory and does not fit the v0.1 input contract.

v0.2 enrolls 3 axes (promoted from the future extension points in
§3):

| Axis | What it solves |
|---|---|
| `opts.forms = { "VERDICT:", "Overall:" }` | Multiple prefix forms for the label search. |
| `opts.bare_token = true` | Word-boundary bare-label search after prefix-form fails. |
| `opts.require_absent = { <label> = <negator> }` | Composite ("X without Y") semantics on the bare path. |

Each axis has multiple consumer callers in the inventory, so no
YAGNI violation.

### 9.2 v0.2 API

```
M.parse_label_verdict(response, labels, opts) → string | nil

  labels: existing contract (earlier = higher priority)

  opts (all optional):
    forms (string[], default: { "VERDICT:" })
      - Multiple prefix forms. For each label, try each prefix in forms
        in order, case-insensitively. Return the first label that hits.
      - Callers can declare "VERDICT:" / "Overall:" / "Result:" etc.

    bare_token (boolean, default: false)
      - When true, after prefix-form matches, try an identifier-boundary
        match of bare labels. The boundary is equivalent to Lua's
        %f[%w_]...%f[^%w_] pattern (case-insensitive; underscore is
        included in the identifier set).
      - Priority between prefix-form and bare: **prefix-form first
        (unconditional)**. Bare runs as a later stage (and is further
        conditioned by require_absent).

    require_absent (table { [label] = negator_string }, default: {})
      - Active only on the bare path (does not apply to prefix-form
        matches).
      - Example: `{ BLOCKED = "PASS" }` = even if bare BLOCKED matches,
        if a bare PASS (word-boundary) also exists in the response,
        BLOCKED is not adopted; we move on to the next label.
      - A device for expressing "composite (X without Y)" semantics.

  Algorithm:
    1. Phase A (prefix-form): search `<form><whitespace?><label>` in
       labels-priority × forms-priority order; return the first hit.
    2. Phase B (when bare_token=true): search bare label (word-boundary)
       in labels priority order. On hit:
         - If require_absent[label] is declared and its bare negator
           also matches, skip.
         - Otherwise, return label.
    3. nil

  Backward compat:
    - All opts nil/unspecified → same behavior as v0.1
      (forms=["VERDICT:"], bare_token=false, require_absent={})
    - The existing v0.1 tests + the back-compat test "nil opts" all
      continue to PASS.
```

### 9.3 v0.2 call-site coverage (abstracted)

| Caller kind | v0.2 form |
|---|---|
| `BLOCKED` priority + `BLOCKED` requires absent `PASS` (bare composite) | `parse_label_verdict(r, {"BLOCKED","PASS"}, {bare_token=true, require_absent={BLOCKED="PASS"}}) == "BLOCKED"` |
| `NEEDS_HUMAN` with `VERDICT:` or `Overall:` form | `parse_label_verdict(r, {"NEEDS_HUMAN"}, {forms={"VERDICT:","Overall:"}}) ~= nil` |
| `NEEDS_HUMAN`/`BLOCKED`/`PASS` with both forms + bare composite | `parse_label_verdict(r, {"NEEDS_HUMAN","BLOCKED","PASS"}, {forms={"VERDICT:","Overall:"}, bare_token=true, require_absent={BLOCKED="PASS"}})` |
| `NOT_READY`/`READY` bare priority | `parse_label_verdict(r, {"NOT_READY","READY"}, {bare_token=true}) or "READY"` (caller's default fallback) |
| `HAS_FINDINGS`/`CLEAN` bare priority | `parse_label_verdict(r, {"HAS_FINDINGS","CLEAN"}, {bare_token=true}) or "UNKNOWN"` (caller's default fallback) |
| `FAIL`/`PASS` bare composite (FAIL wins, absent PASS) | `parse_label_verdict(r, {"FAIL","PASS"}, {bare_token=true, require_absent={FAIL="PASS"}}) == "FAIL"` |
| Single-label bare presence | `parse_label_verdict(r, {token}, {bare_token=true}) ~= nil` |
| `CHANGES_REQUIRED`/`HEALTHY` bare priority | `parse_label_verdict(r, {"CHANGES_REQUIRED","HEALTHY"}, {bare_token=true}) == "CHANGES_REQUIRED"` |

### 9.4 Not absorbed by v0.2 (hand-roll continues)

- Mixed anchor semantics: leading anchor (`^%s*rejected`) +
  word-boundary `not approved` + 4-valued status.
- `status:` YAML-style key match.
- `Language:` header capture (capture-family; not a verdict).
- Simple substring / word-boundary checks (`is_proceed` /
  `is_no_hypotheses` / `is_diffback` / `has_pyho_modifier`); little
  benefit from promotion to a Frame primitive.
- Capture (not verdict decision) — e.g. extracting a hypothesis or
  numeric count.
- JSON envelope (separate path entirely).
- `VERDICT: <label> (<float>)` 2-tuple confidence; candidate for a
  separate `parse_label_with_confidence` function.

### 9.5 Remaining extension points after v0.2 (v0.3 candidates)

- `opts.case_sensitive` (strict casing).
- `opts.line_anchor` (BOL only).
- `parse_label_with_confidence` (label + float 2-tuple).
- Capture-family primitive (`parse_field(r, "Language", "%w_-")`).

## 10. v0.3 extension (bare_substring axis enrollment)

### 10.1 Motivation

In the caller-migration inventory taken immediately after v0.2
enrollment, we found that some `FAIL` / `PASS` composite callers
cannot be absorbed under the **word-boundary** semantics of v0.2
`bare_token`. Both callers used **substring search**:

```lua
-- Existing hand-roll (shape)
local u = response:upper()
if u:find("FAIL", 1, true) and not u:find("PASS", 1, true) then
    return true
end
```

- `"test FAILED"` → `"FAIL"` matches as a substring (catches the
  FAIL inside FAILED).
- v0.2 `bare_token` (identifier-boundary, currently
  `%f[%w_]FAIL%f[^%w_]`) does not match `"FAILED"` → false negative.

In contexts where the E2E test runner / credential gate response can
realistically take the form `"test FAILED"` / `"test PASSED"`,
tightening to word-boundary causes FAIL states to be missed (loses
gate sensitivity).

v0.3 enrolls the `bare_substring` axis and absorbs those callers
into the Frame path.

### 10.2 v0.3 API

```
opts.bare_substring (boolean, default: false)
  - When true, after prefix-form matches, try a substring match on bare
    labels (equivalent to Lua's find(..., 1, true), case-insensitive).
  - If bare_token and bare_substring are both true, bare_substring wins
    (they are treated as mutually exclusive; substring is the wider
    semantic side).
  - require_absent works on the substring path with the same semantics
    (the negator search is also a substring search).
```

Algorithm (revised Phase B):

```
2. Phase B (when bare_substring=true OR bare_token=true):
   Search bare label in labels priority order:
     - If bare_substring=true → substring path (find(label_lc, 1, true))
     - Else if bare_token=true → identifier-boundary path
       (%f[%w_]...%f[^%w_])
   On hit:
     - If require_absent[label] is declared and its bare negator also
       matches, skip (the negator search uses the same semantics as the
       adopted path).
     - Otherwise, return label.
```

Backward compat:

- All opts nil/unspecified → same behavior as v0.1 (forms=["VERDICT:"],
  bare_token=false, bare_substring=false, require_absent={}).
- Existing v0.2 callers (forms / bare_token / require_absent) are
  unaffected.
- The existing test suite keeps passing.

### 10.3 v0.3 call-site coverage (abstracted)

| Caller kind | v0.3 form |
|---|---|
| `FAILED`/`PASSED` substring composite (FAIL wins, absent PASS, substring boundary) | `parse_label_verdict(r, {"FAIL","PASS"}, {bare_substring=true, require_absent={FAIL="PASS"}}) == "FAIL"` |

### 10.4 Remaining extension points after v0.3 (v0.4+ candidates)

- `opts.case_sensitive` (strict casing).
- `opts.line_anchor` (BOL only).
- `parse_label_with_confidence` (label + float 2-tuple).
- Capture-family primitive (generic header value extraction).

## 11. v0.4 extension (parse_and_assert primitive)

### 11.1 Motivation

An entity-oriented boilerplate inventory of downstream consumers
exposed two related kinds of duplication:

**(A) Delegate-Done assert guard** — appears as a 4-line block at
many sites across multiple consumers:

```lua
local parsed = parse_verdict_wrapper(resp)
if parsed.status ~= "DONE" then
    error("<orch> <phase> failed: " .. (parsed.reason or parsed.raw))
end
```

The detail fallback chain in the error message
(`parsed.reason or parsed.missing or parsed.raw or "?"`) drifts
subtly between callers (some use only `reason / raw`, others fall
back through `missing` down to `"?"`), which becomes a source of
format inconsistency.

**(B) Per-consumer parse wrapper duplication** — defined
independently per consumer, each a thin wrapper over
`frame.parse_verdict(response, { fuzzy = true })` (plus, in some
consumers, an extension that captures additional fields).

Standing up a primitive that absorbs (A) also makes (B) unnecessary
for the assert portion — callers invoke `frame.parse_and_assert`
directly. Consumers with capture extensions keep their wrapper for
the capture path, but share the assert via the Frame primitive.

### 11.2 v0.4 API

```
frame.parse_and_assert(response, step_label, opts) → parsed_table

  Internally:
    1. parsed = frame.parse_verdict(response, opts)
    2. if parsed.status == "DONE" then return parsed
    3. error(step_label .. " failed: " .. detail)
       where detail = parsed.reason
                   or parsed.missing
                   or parsed.raw
                   or "?"

  Arguments:
    response (string|nil)
      - Raw response from the LLM/dispatcher. nil is allowed (via
        parse_verdict it becomes UNKNOWN and falls into the error path).
    step_label (string)
      - Leading label of the error message. A "<orch> <phase>"
        identifier is recommended.
    opts (table?, default {})
      - Forwarded as-is to parse_verdict (fuzzy / other axes).

  Return:
    parsed_table (DONE only) — { status="DONE", path?, raw, ... }
    Anything other than DONE raises (does not return).

  Backward compat:
    Existing API surface unchanged. New function added only.
```

### 11.3 v0.4 call-site coverage (abstracted)

| Caller kind | Shape |
|---|---|
| Per-phase delegate-Done assert with fuzzy `parse_verdict` | `parse_and_assert(resp, "<orch> <phase>", { fuzzy = true })` |
| Same, plus per-consumer wrapper that also captures extra fields (e.g. `jumps=`) downstream | `parse_and_assert(resp, "<orch> STEP_N", { fuzzy = true })`; capture separately downstream |

### 11.4 Not absorbed by v0.4 / out of scope

- Delegate families that are already routed through `run_linear` and
  loop on `ctx.result` early returns — out of scope for this
  primitive.
- Capture-family extensions (e.g. `jumps=` field capture): stay as
  additional processing inside the consumer's wrapper (`jumps=` is
  outside the scope of `parse_verdict`).
- Patterns where the caller branches on BLOCKED / NEEDS_INPUT
  without raising an error: do not use `parse_and_assert`; keep
  calling `parse_verdict` directly.

### 11.5 Remaining extension points after v0.4 (v0.5+ candidates)

- Carrying over from §10.4: `case_sensitive` / `line_anchor` /
  `parse_label_with_confidence` / `parse_field` (capture-family).
- `assert_handler` axis: invoke a caller-provided handler instead of
  raising (flexibility for cases like wanting BLOCKED to be a warn).
  Currently fine to error in every caller.

## 12. v0.4.1 / patch (boundary tightening, API unchanged)

### 12.1 Background

Two boundary leakages were found on the bare-token paths of
`parse_verdict` / `parse_label_verdict`:

- **B1**: `parse_verdict` fuzzy bare-DONE used
  `r:upper():find("DONE", 1, true)` (plain substring), producing
  false positives on mid-word / identifier-internal "DONE" such as
  `"abandoned"` (ABAN**DONE**D) / `"redone"` / `"undone"` /
  `"overdone"` / `"IS_DONE"`.
- **B2**: The `%f[%w]...%f[%W]` frontier on the `bare_token` path of
  `parse_label_verdict` treated underscore as a boundary, so the
  label `NEEDS_HUMAN` would partially match
  `"foo_NEEDS_HUMAN_HOOK"` (Lua's `%w` is `[A-Za-z0-9]` and does not
  include underscore). This conflicts with the word-boundary contract
  advertised in §9.2.

### 12.2 Fix

Both paths are unified on **identifier-boundary**:

- B1: `r:upper():find("%f[%w_]DONE%f[^%w_]")`
- B2: `r:find("%f[%w_]" .. esc_label .. "%f[^%w_]")` (applied to
  both the label path and the `require_absent` negator path).

By using `[%w_]` (alnum + underscore = the identifier char set) as
the frontier set, underscore is also treated as part of an
identifier, and only true positives at identifier boundaries are
captured.

### 12.3 Scope of impact

- No impact on API / opts / return values / back-compat. Pattern
  swap only.
- The §10.1 conclusion that "FAILED is not matched by word-boundary"
  is unchanged (`E` ∈ `[%w_]`, so `%f[^%w_]` does not hold), and the
  rationale for `bare_substring` still stands.
- 8 regression specs added to `tests/run.lua`; all current cases
  pass on `just test`.
