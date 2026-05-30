--- swarm_frame — Thin runtime for ProgramableSwarm.
---
--- Provides the back-stage that user code never has to think about:
--- state container, session-key path registry, verdict parsing, linear
--- pipeline runner, and an lshape 3-mode validation wrapper. User code
--- only registers a spec (and optionally a handler) per session-key
--- path; state operations, step bookkeeping, logging, and verdict
--- handling are confined to the frame.
---
--- Schema-as-Data and the persistable-by-construction invariant are
--- inherited from lshape. See design/design-doc.md for details.
---
--- Status: v0.6.0 (ctx-aware gate routing on top of Rich Verdict 2-layer). API surface is under
--- verification through the bundled_base_curator_orch rewrite.

local M = {}

M.VERSION = "0.6.0"

-- DI seam: inject a custom JSON host to override the auto-detect chain.
-- Set to a table { encode = fn, decode = fn } before any JSON helper is
-- called. Leave nil to use the auto-detect chain (see host() below).
M.host = nil

-- ─── check_mode (init-time freeze, strict by default) ───────────────────────
--
-- `M.init({ check_mode = "strict" | "non-check" | "format" })` is callable
-- exactly once per process. Subsequent calls are silent no-ops (the first
-- call wins). Tests reset via `M._reset_for_testing()`.
--
-- check_mode expresses **how the dispatcher reaches alc.llm AND what
-- verdict shape it expects back**:
--
--   * "strict"     (default) — go through `flow.llm_bound`, which
--                              appends `[flow_token=...][flow_slot=...]`
--                              to every prompt, persists a resume cue
--                              on `state.data._flow_req_<slot>`, and
--                              verifies the echoed pair on return
--                              (fail-open on absent echo, error on
--                              mismatch). Verdict shape: free text;
--                              identity verification is whatever flow
--                              itself does. Use this for the standard
--                              session-spanning round-trip.
--
--   * "non-check"  — bypass flow entirely and call `alc.llm(prompt,
--                              llm_opts)` directly. No token round-
--                              trip, no resume cue, no echo verify.
--                              Use this only for one-shot prompts that
--                              do not need session-spanning identity
--                              (the direct-prompt pattern).
--
--   * "format"     — go through `flow.llm_bound` (same routing as
--                              "strict") but **require the verdict to
--                              be a JSON object on the first line**,
--                              containing `status` plus `flow_token` /
--                              `flow_slot` fields. The Frame validates
--                              the format and the slot match; identity
--                              is established by *format conformance*
--                              rather than by post-hoc echo verifica-
--                              tion. This is the "stricter than the
--                              current build" mode — opt-in only.
--
-- Adapter packages (e.g. swarm_frame_algocline.make_dispatcher) read
-- the mode via `M.check_mode()` and pick the route + verdict shape.

local _initialised = false
local _check_mode = "strict"

--- Freeze the frame's dispatcher routing + verdict shape policy.
--- @param opts { check_mode?: "strict" | "non-check" | "format" }?
function M.init(opts)
    if _initialised then return end
    opts = opts or {}
    if opts.check_mode ~= nil then
        if opts.check_mode ~= "strict" and opts.check_mode ~= "non-check" and opts.check_mode ~= "format" then
            error(
                "swarm_frame.init: check_mode must be "
                    .. "'strict' | 'non-check' | 'format' "
                    .. "(got "
                    .. tostring(opts.check_mode)
                    .. ")"
            )
        end
        _check_mode = opts.check_mode
    end
    _initialised = true
end

--- Return the current check_mode ("strict" before init counts as
--- the default; the value is locked once `init` runs).
function M.check_mode() return _check_mode end

--- Test-only: clear the freeze flag and restore the default mode.
function M._reset_for_testing()
    _initialised = false
    _check_mode = "strict"
end

--- Test-only: reset M.host to nil so the auto-detect chain is used.
function M._reset_host_for_testing() M.host = nil end

M.meta = {
    name = "swarm_frame",
    version = "0.6.0",
    category = "frame",
    description = "Thin runtime for ProgramableSwarm — state container, "
        .. "session-key path registry, verdict parser, linear pipeline runner, "
        .. "and lshape 3-mode validation wrapper.",
}

-- ─── JSON helpers (preserves the lshape Persistable invariant) ───────────────
--
-- host() resolves a JSON provider through a 5-step chain, in order:
--   1. M.host explicit injection (test or app override)
--   2. _G.alc.json_encode / _G.alc.json_decode (algocline engine VM)
--   3. dkjson (pure Lua, portable)
--   4. cjson (C extension fallback)
--   5. vendored pure_json (swarm_frame.pure_json, always present)
-- The chain must never be short-circuited to a single hard-wired provider.

local function host()
    if M.host then
        if type(M.host) ~= "table" or type(M.host.encode) ~= "function" or type(M.host.decode) ~= "function" then
            error("swarm_frame: M.host must have encode and decode functions")
        end
        return M.host
    end
    if
        type(_G.alc) == "table"
        and type(_G.alc.json_encode) == "function"
        and type(_G.alc.json_decode) == "function"
    then
        return { encode = _G.alc.json_encode, decode = _G.alc.json_decode }
    end
    local ok, dkjson = pcall(require, "dkjson")
    if ok then return { encode = dkjson.encode, decode = dkjson.decode } end
    local ok2, cjson = pcall(require, "cjson")
    if ok2 then return { encode = cjson.encode, decode = cjson.decode } end
    return require("swarm_frame.pure_json")
end

local function json_encode(t) return host().encode(t) end
local function json_decode(s) return host().decode(s) end

-- Expose JSON helpers so adapter packages (swarm_frame_algocline) can
-- reuse the same encoder/decoder without re-detecting the provider.
M.json_decode = json_decode
M.json_encode = json_encode

-- ─── Dotted-path access helper for state.get/set ─────────────────────────────

local function get_path(tbl, dotted)
    local cur = tbl
    for seg in string.gmatch(dotted, "[^.]+") do
        if type(cur) ~= "table" then return nil end
        cur = cur[seg]
    end
    return cur
end

local function set_path(tbl, dotted, value)
    local cur = tbl
    local segs, n = {}, 0
    for seg in string.gmatch(dotted, "[^.]+") do
        n = n + 1
        segs[n] = seg
    end
    for i = 1, n - 1 do
        local seg = segs[i]
        if type(cur[seg]) ~= "table" then cur[seg] = {} end
        cur = cur[seg]
    end
    cur[segs[n]] = value
end

-- ─── State container ─────────────────────────────────────────────────────────
--
-- Plain data only — no functions, userdata, or coroutines. Conforms to
-- lshape's persistable invariant: :dump() returns a lossless JSON string
-- and :restore(json) rebuilds an identical container.

local State = {}
State.__index = State

function M.state_new(opts)
    opts = opts or {}
    local self = setmetatable({}, State)
    self._data = {}
    self._backend = opts.backend -- nil means memory-only
    self._step_done = {} -- step_id -> true
    self._log = {} -- list of { step, kind, detail }
    if opts.dump then self:restore(opts.dump) end
    return self
end

function State:get(key) return get_path(self._data, key) end

function State:set(key, value) set_path(self._data, key, value) end

function State:step_done(step_id) return self._step_done[step_id] == true end

function State:step_mark(step_id) self._step_done[step_id] = true end

--- Apply a gate verdict using the plain_state.gate_decide primitive.
--- Lazily initialises self._data.gates and self._data.completed_steps
--- (both are separate namespaces from self._step_done).
---
--- @param name string       gate identifier
--- @param verdict table     Rich Verdict (from M.plain_state.verdict or literal)
--- @param save_fn fun()?    optional persistence callback
--- @param ctx table?        optional routing context (e.g. { strategy = "..." })
function State:gate_decide(name, verdict, save_fn, ctx)
    self._data.gates = self._data.gates or {}
    self._data.completed_steps = self._data.completed_steps or {}
    M.plain_state.gate_decide(self._data.gates, self._data.completed_steps, name, verdict, save_fn, ctx)
end

function State:log_phase(step, kind, detail)
    self._log[#self._log + 1] = {
        step = step,
        kind = kind,
        detail = detail or "",
    }
end

function State:commit()
    if self._backend and self._backend.save then self._backend:save(self:_snapshot()) end
end

function State:_snapshot()
    return {
        data = self._data,
        step_done = self._step_done,
        log = self._log,
    }
end

function State:dump() return json_encode(self:_snapshot()) end

--- Return the inner plain-table view of the state. Used by frame
--- internals (and the orch convention) when handing off to a
--- spec-builder whose signature expects `state.task_dir`-style
--- access rather than `state:get("task_dir")`.
--- Mutations to the returned table are visible inside the container.
function State:data() return self._data end

function State:restore(json_str)
    local snap = json_decode(json_str)
    self._data = snap.data or {}
    self._step_done = snap.step_done or {}
    self._log = snap.log or {}
end

M.State = State

-- ─── Backend interface (file-backed initial implementation) ──────────────────

local FileBackend = {}
FileBackend.__index = FileBackend

function M.backend_file(path)
    local self = setmetatable({}, FileBackend)
    self.path = path
    return self
end

function FileBackend:save(snap)
    local f, err = io.open(self.path, "w")
    if not f then error("swarm_frame.backend_file save: " .. tostring(err)) end
    f:write(json_encode(snap))
    f:close()
end

function FileBackend:load()
    local f = io.open(self.path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    if s == "" then return nil end
    return json_decode(s)
end

M.FileBackend = FileBackend

-- ─── Handler registry (session-key path -> spec / handler) ───────────────────
--
-- `spec` can be either a plain table (static spec) or a function
-- (spec-builder: receives a `state` argument and returns the spec).
-- Spec-builders run lazily at dispatch / build_step_instruction time so
-- that the orch can defer materialising prompt strings until a real
-- state container is available (resume-friendly, no eager binding).

local registry = {}

function M.register(path, spec, handler)
    if type(path) ~= "string" or not path:match("^/") then
        error("swarm_frame.register: path must start with '/' (got " .. tostring(path) .. ")")
    end
    registry[path] = { spec = spec or {}, handler = handler }
end

function M.unregister(path) registry[path] = nil end

function M.resolve(path) return registry[path] end

function M._registry() return registry end -- exposed for testing only

--- Reduce a state argument to a plain table for spec-builder consumption.
--- The orch convention spec-builders use `state.task_dir`-style access;
--- frame.State containers expose `:data()` to honour that shape.
local function as_plain_state(state)
    if type(state) == "table" and type(state.data) == "function" then return state:data() end
    return state
end

--- Resolve a registry entry's spec — invoke spec-builder with the
--- plain-state view if it is a function, otherwise return the static
--- spec table unchanged. Local helper; the public `M.resolve_spec`
--- wraps it with a path-based lookup so the two surfaces have
--- different shapes (entry vs path) and no longer share a name.
local function _resolve_entry_spec(entry, state)
    if type(entry.spec) == "function" then return entry.spec(as_plain_state(state)) end
    return entry.spec
end

M.resolve_spec = function(path, state)
    local entry = registry[path]
    if not entry then error("swarm_frame.resolve_spec: unknown path=" .. path) end
    return _resolve_entry_spec(entry, state)
end

--- Extract the step id segment from a session-key path.
--- "/pkg/step_1/agent" -> "step_1"
local function step_id_of(path) return (path:match("/([^/]+)/[^/]+$")) or path end

M.step_id_of = step_id_of

--- Build a step instruction string from the registered spec at `path`,
--- resolved against `state` if the spec is a builder, then passed to
--- `instruction_builder(step_id, spec)` which is supplied by the orch.
---
--- This is the public surface that orchs re-export as `M.build_prompt`
--- to satisfy the swarming/agents/package-scaffolder convention
--- (`M.build_prompt(step, state)` — public dispatcher).
---
--- Identity round-tripping (send token / verify echo) is handled by
--- the `flow` package downstream — see flow.llm_bound /
--- flow.token_verify_bound. The frame returns the orch builder's body
--- as-is; flow attaches and verifies its own token pair around it.
function M.build_step_instruction(path, state, instruction_builder)
    local entry = registry[path]
    if not entry then error("swarm_frame.build_step_instruction: unknown path=" .. tostring(path)) end
    if type(instruction_builder) ~= "function" then
        error("swarm_frame.build_step_instruction: instruction_builder must be a function")
    end
    local spec = _resolve_entry_spec(entry, state)
    return instruction_builder(step_id_of(path), spec)
end

-- ─── Verdict parser ──────────────────────────────────────────────────────────
--
-- Standard verdict line forms:
--   "DONE path=X"
--   "BLOCKED reason=Y"
--   "NEEDS_INPUT missing=Z"

function M.parse_verdict(response, opts)
    local r = response or ""
    opts = opts or {}
    local fuzzy = opts.fuzzy == true
    -- Format-mode path: find the first balanced JSON object anywhere in
    -- the response. Anchoring to "first line, no leading whitespace"
    -- was too strict against the LLM's "consider → conclude" output
    -- pattern; format conformance (JSON shape + required fields + slot
    -- match) is still enforced by the consumers of this result, which
    -- is the real identity proof. When check_mode = "strict" /
    -- "non-check" the response is plain text and `r:match("(%b{})")`
    -- typically yields nothing — this path falls through to the legacy
    -- regex below, so both modes coexist on the same parser.
    local obj_str = r:match("(%b{})")
    if obj_str then
        local ok, obj = pcall(json_decode, obj_str)
        if ok and type(obj) == "table" and type(obj.status) == "string" then
            return {
                status = obj.status,
                path = obj.path,
                reason = obj.reason,
                missing = obj.missing,
                next_action = type(obj.next_action) == "string" and obj.next_action or nil,
                flow_token = obj.flow_token,
                flow_slot = obj.flow_slot,
                raw = r,
            }
        end
    end
    -- Legacy text path: regex over the full response.
    local p = r:match("DONE%s+path=([^%s]+)")
    if p then return { status = "DONE", path = p, raw = r } end
    if fuzzy then
        p = r:match("DONE%s*[:=]%s*([^%s]+)")
        if p then return { status = "DONE", path = p, raw = r } end
    end
    local reason = r:match("BLOCKED%s+reason=(.+)")
    if reason then return { status = "BLOCKED", reason = reason:match("^%s*(.-)%s*$"), raw = r } end
    if fuzzy then
        reason = r:match("BLOCKED%s*[:=]%s*(.+)")
        if reason then return { status = "BLOCKED", reason = reason:match("^%s*(.-)%s*$"), raw = r } end
    end
    local miss = r:match("NEEDS_INPUT%s+missing=([^%s]+)")
    if miss then return { status = "NEEDS_INPUT", missing = miss, raw = r } end
    if fuzzy and r:upper():find("%f[%w_]DONE%f[^%w_]") then
        -- Bare DONE token anywhere (case-insensitive). Used by
        -- flow_design / flow_refine_orch when the executor returns
        -- "DONE" without a path, signalling step completion of a
        -- side-effect-only phase. path is intentionally nil.
        -- Word-boundary uses [%w_] (identifier chars) to reject
        -- in-identifier substrings like "abandoned", "redone",
        -- "undone", "overdone", or "IS_DONE".
        return { status = "DONE", path = nil, raw = r }
    end
    return { status = "UNKNOWN", raw = r }
end

-- ─── parse_label_verdict (label form, ordered priority) ─────────────────────
--
-- Parse `<form><whitespace?><label>` from a free-form LLM response. `labels`
-- is an ordered array; the function scans the response once per label, in
-- the caller's order, and returns the FIRST label that matches. The array
-- head is the highest-priority label.
--
-- v0.1 minimum (no opts): `VERDICT:%s*<label>` only (case-insensitive).
-- v0.2 enrolls 3 axes — see design/verdict-parser-extension.md §9:
--
--   opts.forms (string[], default {"VERDICT:"})
--     Multi-prefix forms to search. Each is tried per label in order.
--     Example: { "VERDICT:", "Overall:" } enables Crux Gate / plan-gate
--     dual-form responses.
--
--   opts.bare_token (boolean, default false)
--     When true, after the prefix-form pass, also try matching each
--     label as a bare word (word-boundary, case-insensitive). Used for
--     callers whose LLMs emit raw tokens (NOT_READY, HAS_FINDINGS,
--     CHANGES_REQUIRED, etc.) without a "VERDICT:" prefix.
--
--   opts.require_absent (table { [label] = negator_string }, default {})
--     Only consulted on bare matches (prefix-form matches are
--     unconditional). When bare `label` matches, if `require_absent[label]`
--     is set, the bare negator must NOT also match for the label to win.
--     The negator search uses the same axis as the matched label
--     (bare_substring search if bare_substring=true, otherwise word-
--     boundary). Example: { BLOCKED = "PASS" } expresses
--     "BLOCKED bare AND !PASS bare".
--
-- v0.3 enrolls 1 additional axis — see design/verdict-parser-extension.md §10:
--
--   opts.bare_substring (boolean, default false)
--     When true, after the prefix-form pass, try matching each label as a
--     bare substring (Lua `find(..., 1, true)`, case-insensitive). Wider
--     than bare_token: "FAILED" matches the label "FAIL" because the
--     substring is contained. Used by callers whose responses contain
--     suffixed forms like "test FAILED" / "test PASSED" where word-
--     boundary would emit false negatives. When bare_substring=true and
--     bare_token=true are both set, bare_substring wins (the wider
--     semantic dominates).
--
-- Examples (v0.1 forms, opts omitted):
--   parse_label_verdict(r, {"BLOCKED", "PASS"})
--   parse_label_verdict(r, {"NEEDS_HUMAN", "BLOCKED", "PASS"})
--
-- Examples (v0.2 forms):
--   parse_label_verdict(r, {"NEEDS_HUMAN"}, {forms = {"VERDICT:","Overall:"}})
--   parse_label_verdict(r, {"NOT_READY","READY"}, {bare_token = true})
--   parse_label_verdict(r, {"BLOCKED","PASS"},
--     {bare_token = true, require_absent = {BLOCKED = "PASS"}})
--
-- Examples (v0.3 bare_substring):
--   parse_label_verdict(r, {"FAIL","PASS"},
--     {bare_substring = true, require_absent = {FAIL = "PASS"}})
--   -- catches "test FAILED" + suppresses if "PASSED" appears elsewhere
--
-- v0.4 enrolls 1 additional axis — BLOCKED L-shape rich payload:
--
--   opts.structured (boolean, default false)
--     When true, instead of returning the matched label as a bare string,
--     the function returns a 3-field table:
--       { verdict = <label> | nil,
--         next_action = <string> | nil,
--         reason = <string> | nil }
--     `next_action` and `reason` are extracted leniently from the response
--     (line-form `next_action: X` / `reason: X` or JSON `"next_action":"X"`
--     style, case-insensitive). When `next_action` is absent from the
--     response, a label-specific safety default is applied:
--       BLOCKED     → "halt"     (do not auto-retry)
--       NEEDS_HUMAN → "escalate" (kick to Human)
--       PASS        → nil        (no next step forced)
--     For custom labels the missing-field default is nil.
--     When no label matched, the table form is still returned with all
--     three fields = nil, so the caller can do
--     `local v = parse_label_verdict(..., {structured=true}); if v.verdict then ...`.
--
-- Future extension points (v0.5 candidates, see design doc §10.4):
--   opts.case_sensitive, opts.line_anchor, parse_label_with_confidence

local function _escape_lua_pattern(s) return s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1") end

-- ─── structured payload helpers (BLOCKED L-shape extension) ────────────────
--
-- Used by parse_label_verdict when opts.structured = true. The extraction
-- is lenient (case-insensitive, accepts ":" / "=" / whitespace as the
-- key-value separator) and returns the FIRST hit. Missing values come
-- back as nil and the caller applies label-specific defaults.

local function _extract_field(response, field)
    if type(response) ~= "string" then return nil end
    -- Try JSON-style first: "field":"value"
    local v = response:match('"' .. field .. '"%s*:%s*"([^"]*)"')
    if v and v ~= "" then return v end
    -- Then line-form: field: value / field = value
    -- Value extends to end-of-line (trimmed). Allows custom strings.
    local lower = response:lower()
    local lf = field:lower()
    local s, e = lower:find(lf .. "%s*[:=]%s*", 1)
    if s then
        local tail = response:sub(e + 1)
        local line = tail:match("([^\r\n]*)")
        if line then
            line = line:match("^%s*(.-)%s*$") -- trim
            if line ~= "" then return line end
        end
    end
    return nil
end

-- Default next_action when the field is absent from the response.
-- Safe-side: BLOCKED / NEEDS_HUMAN stop the pipeline even without an
-- explicit next_action (halt / escalate). PASS does not force a next
-- step (nil). Custom labels default to nil (caller-defined).
local _DEFAULT_NEXT_ACTION = {
    BLOCKED = "halt",
    NEEDS_HUMAN = "escalate",
    PASS = nil,
}

function M.parse_label_verdict(response, labels, opts)
    if response == nil then return nil end
    if type(labels) ~= "table" or #labels == 0 then return nil end
    opts = opts or {}
    local forms = opts.forms or { "VERDICT:" }
    local bare_token = opts.bare_token == true
    local bare_substring = opts.bare_substring == true
    local structured = opts.structured == true
    local require_absent = opts.require_absent or {}
    local r = tostring(response):lower()
    local raw_response = tostring(response)

    -- Build the L-shape structured return when opts.structured = true.
    -- For nil (no label matched) we still return a table so callers can
    -- dispatch on .verdict == nil without a separate type check.
    local function _build_result(label)
        if not structured then return label end
        if not label then return { verdict = nil, next_action = nil, reason = nil } end
        local na = _extract_field(raw_response, "next_action")
        if not na or na == "" then na = _DEFAULT_NEXT_ACTION[label] end
        local reason = _extract_field(raw_response, "reason")
        return { verdict = label, next_action = na, reason = reason }
    end

    -- Per-label interleaved matching: for each label in priority order,
    -- try ALL prefix-form matches first, then (if a bare axis is on)
    -- the bare match (substring if bare_substring, otherwise word-
    -- boundary). Labels[1] gets the FIRST chance regardless of which
    -- axis matches, which preserves the "priority head wins" intent
    -- (e.g. HAS_FINDINGS wins over `VERDICT: CLEAN` even when
    -- HAS_FINDINGS appears only as a bare token).
    for _, label in ipairs(labels) do
        local lower_label = label:lower()
        local esc_label = _escape_lua_pattern(lower_label)
        -- Axis 1: prefix-form match (unconditional, no require_absent)
        for _, form in ipairs(forms) do
            local esc_form = _escape_lua_pattern(form):lower()
            if r:find(esc_form .. "%s*" .. esc_label) then return _build_result(label) end
        end
        -- Axis 2: bare label match.
        --   bare_substring=true  → plain substring (find(..., 1, true))
        --   bare_token=true      → identifier-boundary (%f[%w_]...%f[^%w_])
        --   both true            → bare_substring wins (wider semantic)
        --
        -- Token boundary uses [%w_] so that underscore is treated as
        -- part of the identifier. This prevents "foo_NEEDS_HUMAN_HOOK"
        -- from matching label "NEEDS_HUMAN" — Lua's bare %w excludes
        -- underscore, which would let identifier-internal labels leak
        -- through.
        if bare_substring or bare_token then
            local matched
            if bare_substring then
                matched = (r:find(lower_label, 1, true) ~= nil)
            else
                matched = (r:find("%f[%w_]" .. esc_label .. "%f[^%w_]") ~= nil)
            end
            if matched then
                local negator = require_absent[label]
                if negator then
                    local neg_matched
                    if bare_substring then
                        neg_matched = (r:find(negator:lower(), 1, true) ~= nil)
                    else
                        local esc_neg = _escape_lua_pattern(negator):lower()
                        neg_matched = (r:find("%f[%w_]" .. esc_neg .. "%f[^%w_]") ~= nil)
                    end
                    if neg_matched then
                        -- negator present, label disqualified — continue
                        -- to next label
                    else
                        return _build_result(label)
                    end
                else
                    return _build_result(label)
                end
            end
        end
    end

    return _build_result(nil)
end

-- ─── parse_and_assert (delegate-done assert primitive) ────────────────────
--
-- Wraps `parse_verdict` with a uniform "DONE-or-die" assertion. Absorbs the
-- common per-Phase boilerplate found in non-linear phase-orchestrators
-- (flow_design / distillation_orch), where each delegate call is followed
-- by a 4-line `parse + status check + error` block.
--
-- Algorithm:
--   1. parsed = M.parse_verdict(response, opts)
--   2. if parsed.status == "DONE" then return parsed
--   3. otherwise raise: `<step_label> failed: <detail>`
--      where detail = parsed.reason or parsed.missing or parsed.raw or "?"
--
-- Use this primitive ONLY when DONE is mandatory at the call site (BLOCKED
-- and NEEDS_INPUT are fatal). For callers that branch on verdict status
-- (e.g. run_linear's ctx.result early-return pattern), keep using
-- `parse_verdict` directly.
--
-- Example:
--   local parsed = frame.parse_and_assert(resp, "flow_design Phase 0",
--                                         { fuzzy = true })

function M.parse_and_assert(response, step_label, opts)
    local parsed = M.parse_verdict(response, opts)
    if parsed.status == "DONE" then return parsed end
    local detail = parsed.reason or parsed.missing or parsed.raw or "?"
    error(tostring(step_label) .. " failed: " .. detail)
end

-- ─── Dispatch (single path) ──────────────────────────────────────────────────

function M.dispatch(path, ctx)
    local entry = registry[path]
    if not entry then error("swarm_frame.dispatch: unknown path=" .. path) end
    if type(entry.handler) ~= "function" then
        error(
            "swarm_frame.dispatch: no handler for path="
                .. path
                .. " (spec-only registration cannot be dispatched without external dispatcher)"
        )
    end
    local spec = _resolve_entry_spec(entry, ctx and ctx.state)
    return entry.handler(ctx, spec)
end

-- ─── Linear pipeline runner ──────────────────────────────────────────────────
--
-- paths: { "/pkg/step_1/agent", "/pkg/step_2/agent", ... }
-- ctx.state: required (built via M.state_new).
-- ctx.dispatcher: optional. When a registered path has no inline handler,
--                 the runner calls dispatcher(path, spec, ctx) to obtain
--                 a verdict response string. For the PoC, the
--                 bundled_base_curator rewrite wraps algocline's
--                 make_delegate in such a dispatcher.
--
-- For each path the frame performs, behind the scenes:
--   1. skip if already step_done
--   2. log_phase("start")
--   3. invoke the handler directly or call dispatcher
--   4. parse_verdict
--   5. on non-DONE: capture ctx.result and stop the pipeline
--      (NEEDS_INPUT and BLOCKED are reported through ctx.result rather
--       than raised; the caller decides what to do next)
--   6. on DONE: log_phase("done"), step_mark, commit
-- This collapses what used to be six copy-pasted blocks into one place.

function M.run_linear(paths, ctx)
    local state = ctx.state or error("swarm_frame.run_linear: ctx.state required")
    local dispatcher = ctx.dispatcher -- optional
    local artifacts_key = ctx.artifacts_key or "artifacts"
    for _, path in ipairs(paths) do
        local step_id = step_id_of(path)
        if not state:step_done(step_id) then
            state:log_phase(step_id, "start", path)
            local entry = registry[path]
            if not entry then error("swarm_frame.run_linear: unknown path=" .. path) end
            local spec = _resolve_entry_spec(entry, state)
            local response
            if entry.handler then
                response = entry.handler(ctx, spec)
            elseif dispatcher then
                response = dispatcher(path, spec, ctx)
            else
                error("swarm_frame.run_linear: path " .. path .. " has no handler and ctx.dispatcher is nil")
            end
            local v = M.parse_verdict(response)
            if v.status ~= "DONE" then
                state:log_phase(step_id, v.status, v.reason or v.missing or v.raw)
                state:commit()
                local na = v.next_action
                if not na then
                    -- Default mapping when the LLM didn't emit next_action.
                    -- Safe-side: BLOCKED -> halt, NEEDS_INPUT -> escalate.
                    if v.status == "BLOCKED" then
                        na = "halt"
                    elseif v.status == "NEEDS_INPUT" then
                        na = "escalate"
                    end
                end
                ctx.result = {
                    status = v.status,
                    reason = v.reason,
                    missing = v.missing,
                    next_action = na,
                    raw_verdict = v.raw,
                    failed_path = path,
                }
                return ctx
            end
            state:set(artifacts_key .. "." .. step_id, v.path)
            state:log_phase(step_id, "done", v.path)
            state:step_mark(step_id)
            state:commit()
        end
    end
    ctx.result = {
        status = "DONE",
        [artifacts_key] = state:get(artifacts_key),
    }
    return ctx
end

-- ─── lshape validation wrapper (3 modes) ─────────────────────────────────────
--
-- Mode precedence: explicit argument > SWARM_FRAME_SCHEMA_MODE env > "warn".

local function resolve_mode(explicit)
    if explicit then return explicit end
    local env = os.getenv("SWARM_FRAME_SCHEMA_MODE")
    if env and env ~= "" then return env end
    return "warn"
end

M._warn_sink = function(reason, ctx_hint)
    io.stderr:write(string.format("[swarm_frame.validate WARN] %s: %s\n", ctx_hint or "", reason))
end

function M.set_warn_sink(fn) M._warn_sink = fn end

function M.validate(value, schema, ctx_hint, mode)
    local resolved = resolve_mode(mode)
    if resolved == "off" then return value end
    local lshape_ok, lshape = pcall(require, "lshape")
    if not lshape_ok then error("swarm_frame.validate: lshape not available (install via alc_pkg_link)") end
    local check = lshape.check
    if resolved == "strict" then
        return check.assert(value, schema, ctx_hint)
    elseif resolved == "dev" then
        return check.assert_dev(value, schema, ctx_hint)
    else -- "warn" (default)
        local ok, reason = check.check(value, schema)
        if not ok and M._warn_sink then M._warn_sink(reason, ctx_hint) end
        return value
    end
end

-- ─── plain_state sub-module (function-based peer of State) ─────────────────
--
-- `swarm_frame.plain_state.{step_done, step_mark, log_phase}` mirrors
-- `State:step_done / :step_mark / :log_phase` as free functions over plain
-- Lua tables. Two surfaces, same primitives, two valid container shapes:
--
--   * `swarm_frame.State`        — opaque container, method form
--                                  (used by orchs that adopt `state_new`)
--   * `swarm_frame.plain_state`  — free functions over plain lists
--                                  (used by orchs on `flow.state_new`)
--
-- Neither is deprecated; the 13 agent-profiles orchs that stay on
-- `flow.state_new` consume `plain_state` without forcing a wholesale
-- container migration. See `swarm_frame/plain_state.lua` for the
-- migration-from-closures pattern.

M.plain_state = require("swarm_frame.plain_state")

-- ─── normalize sub-module (entry-boundary type coercion) ───────────────────
--
-- `swarm_frame.normalize.{coerce_boolean, coerce_string, coerce_number,
-- coerce_table, normalize_ctx}` provides ctx-entry shape enforcement and
-- mlua JSON null sentinel sanitize. Peer of `plain_state` (not `validate`/
-- lshape: lshape is full Schema-as-Data, `normalize` is the narrow Lua-
-- type + sentinel idiom hoisted out of `coding_orch:737-788`). See
-- `swarm_frame/normalize.lua` for the migration pattern and
-- `design/normalize-primitive.md` for the discard re-evaluation rationale.

M.normalize = require("swarm_frame.normalize")

-- ─── artifact_store sub-module ────────────────────────────────────────────────
--
-- `swarm_frame.artifact_store(backend)`     — store factory
-- `swarm_frame.backend_artifact_file(opts)` — FS backend (4-method contract)
-- `swarm_frame.backend_artifact_memory()`   — in-memory backend (4-method contract)
-- `swarm_frame.summarize(payload, opts)`    — standalone pure summary helper

local _astore = require("swarm_frame.artifact_store")
M.artifact_store = _astore.artifact_store
M.backend_artifact_file = _astore.backend_artifact_file
M.backend_artifact_memory = _astore.backend_artifact_memory
M.summarize = _astore.summarize

return M
