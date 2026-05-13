# swarm_frame.normalize — Entry-boundary type coercion primitive (Design)

Status: draft (2026-05-13, peer of plain_state)
Related: design/design-doc.md / design/delegate-extraction.md /
packages/swarm_frame/plain_state.lua (peer module pattern)

Draft / WIP — feedback welcome; discard if off.

## 1. Problem

Downstream consumers of algocline routinely carry an entry-boundary
ctx normalizer (a per-field tag table + a bulk normalizer function)
inline in their own `init.lua`, performing two responsibilities:

- **Entry-boundary ctx type coercion** — required fields raise on type
  mismatch, optional fields coerce non-matching values to `nil` so
  downstream `if x then io.open(x) ... end` is safe.
- **mlua JSON null light-userdata sentinel sanitize** — the mlua-VM
  side of algocline can present JSON `null` as a light-userdata sentinel
  rather than a Lua `nil`, and downstream code has to filter it out.

The same idiom shows up across multiple pipelines. Leaving each one
to hand-roll the same code leads to:

- mlua JSON null sentinel sanitize is **mlua-VM-specific language
  plumbing**. An idiom no individual pipeline wants to own bleeds
  into every pipeline.
- Single-field coercers (`coerce_boolean(v)` / `coerce_string(v)` /
  others) are not consistently available, so the
  `coerce_boolean(v) or false` idiom is not shareable across
  consumers.
- There is no shared home for the ctx normalize spec's tag vocabulary
  (`"string?"`, `"boolean?"`, etc.).

## 2. Re-evaluating the "user code only" verdict

An earlier deprecation note (see `design/delegate-extraction.md`)
classified normalize / coerce primitives as **discard**, with the
reasoning:

> entry-boundary coerce is user code's responsibility; do not pull it
> into the Frame.

That call was correct in its original context — caution against the
**LangChain trap** of interposing an extra intermediate abstraction
between user code and the runtime. But what we observe in practice is
that the coercion idiom is being **reborn inline at every consumer**,
not because user code wants to own it, but because re-implementing it
directly is lighter than depending on a retired helper. That makes the
duplication:

- **not** an intermediate abstraction;
- **but** language- and VM-specific foundational plumbing (mlua
  sentinel sanitize is mandatory under the mlua-probe environment).

This puts it outside the LangChain trap's scope. We re-propose it in
the direction of **reviving it as a peer module**. Just as
`State / plain_state` are peer surfaces, `normalize` settles in as a
peer primitive of the Frame.

## 3. Scope (narrow)

**This task's responsibility, and only this**:

- Add `swarm_frame.normalize` as a peer module of `plain_state`.
- Export 4 single-field coercers (`coerce_boolean` / `coerce_string` /
  `coerce_number` / `coerce_table`).
- Export a bulk normalizer (`normalize_ctx(ctx, spec)`) carrying an
  8-tag vocabulary (`"string"` / `"string?"` / `"boolean"` /
  `"boolean?"` / `"number"` / `"number?"` / `"table"` / `"table?"`).
- Include the mlua JSON null light-userdata sentinel in the sanitize
  set.

**Out of scope for this task**:

- Extending the verdict-string parser (PASS / READY / PROCEED support
  in `parse_verdict`) — handled in `design/verdict-parser-extension.md`.
- Migrating each consumer (this design doc covers only **adding the
  Frame-side primitive**; consumer-side adoption rolls out in
  separate staged tasks).
- Whole-ctx schema validation (the strain that calls lshape from
  `M.validate` is a different axis; this primitive is dedicated to
  entry-boundary type coercion).

## 4. Shape (draft)

```
swarm_frame.normalize  (peer of swarm_frame.plain_state, function form)

-- ── single-field coercers ──────────────────────────────────────
-- Out-of-shape input (wrong type, or mlua null sentinel) → nil
-- Use case: coerce_boolean(v) or false  for entry-boundary sanitize

M.coerce_boolean(v) → boolean | nil
  - v is boolean → v as is
  - v is mlua JSON null (light-userdata) → nil
  - otherwise → nil

M.coerce_string(v) → string | nil
  - v is string → v as is (empty string passes through as string;
    required check belongs to normalize_ctx)
  - v is mlua JSON null → nil
  - otherwise → nil

M.coerce_number(v) → number | nil
  - same shape

M.coerce_table(v) → table | nil
  - same shape

-- ── bulk normalizer ────────────────────────────────────────────
-- Apply a schema to the whole ctx.

M.normalize_ctx(ctx, spec) → ctx
  - spec = { field_name = tag_string, ... }
  - tag_string ∈ {
      "string"   = required, must be string, non-empty
      "string?"  = optional, coerce non-string → nil
      "boolean"  = required, must be boolean
      "boolean?" = optional, coerce non-boolean → nil
      "number"   = required, must be number
      "number?"  = optional, coerce non-number → nil
      "table"    = required, must be table
      "table?"   = optional, coerce non-table → nil
    }
  - required mismatch → error (consistent per-field message)
  - optional mismatch → ctx[field] = nil
  - Return value is the input ctx, mutated in place
    (caller-compatible with existing inline implementations)

```

Mode control (env / warn sink) is not included in v0.1. Enroll with
strict fixed, and add it as a later v0.x axis once demand is confirmed
(see §7).

### Module layout

```
packages/swarm_frame/
├ init.lua            (existing; lifts M.normalize via require)
├ plain_state.lua     (existing peer)
└ normalize.lua       (this task, new peer)
```

At the tail of `init.lua` (next to the current `M.plain_state = require(...)`),
lift `M.normalize = require("swarm_frame.normalize")`.

## 5. Detecting the mlua JSON null sentinel

The exact detection shape is **not yet pinned down** in this design
doc. Decide at implementation time:

- **Option A**: reject crudely with `type(v) == "userdata"`
  → risky (may misclassify other lightuserdata).
- **Option B**: identity check against `alc.json_null`
  (`v == alc.json_null`)
  → assumes the alc API is present; confirm `alc.json_null` resolves
  in the test environment.
- **Option C**: identity check against the cjson.null sentinel
  → aligns with swarm_frame's json fallback chain
  (`alc.json_*` → cjson → dkjson).
- **Option D**: define a canonical lightuserdata sentinel inside the
  Frame as the "nil proxy" (`M.NULL_SENTINEL`) and normalize
  `json_decode` output to it
  → cleanest, but requires changes to `json_decode`.

**TODO**: pick from A–D at implementation time after reproducing the
sentinel shape under the mlua-probe environment.

## 6. Migration plan (after the peer lands, as a separate task)

1. **Frame side**: add `swarm_frame.normalize` and tests (this task).
2. **Consumer side** (separate per-consumer tasks): rewrite each
   inline normalizer to delegate to `M.normalize.normalize_ctx`,
   same three-stage pattern as the plain_state migration: "add peer
   → consumer adoption → remove old inline".

Leave the consumer's inline implementation in place, prove through
tests that `M.normalize_ctx` matches its behaviour, then switch to
the delegate.

## 7. Open questions / future enrollment candidates

- Final shape of the mlua JSON null sentinel detection (§5 options
  A–D).
- Vocabulary extensions for `M.normalize_ctx` (whether to support
  `"any"` / `"string|nil"` / `"oneof:a,b,c"` later) — v0.1 is fixed
  to the current 8 tags.
- **TODO** — Mode control (env / warn sink):
  `SWARM_FRAME_NORMALIZE_MODE` (`strict` / `warn` / `off`) plus
  `M.set_warn_sink`, mirroring `SWARM_FRAME_SCHEMA_MODE`. Enroll once
  demand to observe migration-era coercion failures through the warn
  path is confirmed (deferred in v0.1 because sink registration
  introduces global state at the package level).
- Error message prefix format — only within bounds that do not break
  existing caller-side error catches.
- Coercer return: `nil` vs `false` (whether the Frame should provide
  an idiom that collapses to the boolean default) → keep the current
  `coerce_boolean(v) or false` style on the caller side.

## 8. Related — connection to the parser cleanup

In parallel with this task (entry-boundary type coercion), an LLM
verdict-string parser cleanup is on deck — see
`design/verdict-parser-extension.md`.

- Today's `swarm_frame.parse_verdict` recognizes DONE / BLOCKED /
  NEEDS_INPUT.
- Domain vocabulary like PASS / READY / PROCEED has been hand-rolled
  by consumers via `:match("(PASS|BLOCKED|...)")`.
- The parser extension adds primitives (`opts.fuzzy`,
  `parse_label_verdict`, and later `bare_token` /
  `require_absent` / `bare_substring` / `parse_and_assert`) whose
  preset / vocabulary is extensible.

Normalize is closer to language- and VM-specific plumbing; the parser
extension widens once preset discussions start. The two tasks are
peers; either can land first.
