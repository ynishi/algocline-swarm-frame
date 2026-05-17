--- swarm_frame_algocline — Token & Prompt round-trip primitive.
---
--- Thin wrapper exposing a dispatcher that swarm_frame.run_linear (or
--- any orch that wants the round-trip primitive) can use as
--- `ctx.dispatcher`. The adapter does exactly three things:
---
---   1. step_id_of(path)      — strip the path down to a step segment
---   2. builder(step, spec)   — call the orch-supplied prompt builder
---   3. route the prompt to alc.llm per `swarm_frame.check_mode()`:
---        * "strict"     → through `flow.llm_bound` (token round-trip
---                         + resume cue + echo verify, all owned by
---                         flow itself).
---        * "non-check"  → straight to `alc.llm(prompt, llm_opts)`,
---                         no token round-trip. The direct-prompt
---                         pattern, for one-shot prompts that do
---                         not need session-spanning identity.
---        * "format"     → through `flow.llm_bound` (same routing as
---                         strict) AND post-verify that the response
---                         is a Pure JSON object on the first line
---                         carrying `status` + `flow_token` +
---                         `flow_slot` fields, with `flow_slot`
---                         matching the dispatched step. Format
---                         conformance becomes the identity proof.
---                         Non-conformant responses are translated
---                         into a `BLOCKED reason=format-<detail>`
---                         verdict string so run_linear halts the
---                         pipeline with a structured reason.
---
--- Domain-shaped concerns — middleware chains, variant routing, shape
--- validation, prompt-budget warnings, agentId extraction,
--- `build_instruction_default` — live **above** this adapter in the
--- consuming orch (or in a plugin layered onto `make_dispatcher`). The
--- adapter is intentionally ignorant of those concerns; it provides the
--- Token & Prompt round-trip only and exposes plugin hooks
--- (`before_dispatch` / `around_dispatch` / `after_dispatch` /
--- `finalize`) for callers to layer the rest on top.
---
--- Status: v0.1.1 (Token & Prompt + format mode).

local M = {}

M.VERSION = "0.1.1"

M.meta = {
    name = "swarm_frame_algocline",
    version = "0.1.1",
    category = "frame_primitive",
    description = "Token & Prompt round-trip primitive — routes prompts to "
        .. "flow.llm_bound (strict / format) or alc.llm directly (non-check), "
        .. "with format-mode post-verify for JSON-shape conformance.",
}

-- Re-export swarm_frame.step_id_of so callers that hold this adapter
-- module don't need to require("swarm_frame") separately.
M.step_id_of = require("swarm_frame").step_id_of

--- Build the Token & Prompt round-trip dispatcher.
---
--- @param opts table {
---     builder  : fun(step:string, spec:table):string,  -- required
---     state    : table,                                -- required for strict mode (algocline flow state); unused in non-check mode
---     llm_opts : table?,                               -- forwarded (system / max_tokens / ...)
---     flow     : table?,                               -- test injection (defaults to require("flow"))
---     frame    : table?,                               -- test injection (defaults to require("swarm_frame"))
---     alc      : table?,                               -- test injection (defaults to _G.alc); used in non-check mode
---     extras   : table?,                               -- opaque pass-through dict (see below)
---     plugins  : table[]?,                             -- Phase 2 dispatch plugin chain (see below)
--- }
--- @return userdata callable_dispatcher           -- callable table; see below
---
--- The returned value is a **callable table** (function-like via the
--- `__call` metamethod) that accepts either a full swarm_frame path
--- ("/pkg/step/agent") or a bare step_id ("step_1"); both resolve to
--- the same step segment. It also exposes the caller-supplied opaque
--- dict at `dispatcher.extras` for downstream plugin / hook access:
---
---     local d = make_dispatcher({
---         builder  = ...,
---         state    = ...,
---         llm_opts = { system, max_tokens },
---         extras   = { abtest_agents = {...}, state_shape = ... },
---     })
---     d("/pkg/step/agent", spec, ctx)         -- dispatch (callable)
---     local v = d.extras.abtest_agents        -- plugin reads back
---
--- The adapter does NOT inspect or validate `extras` beyond the type
--- check (table or nil). It is intentionally opaque so an orch can
--- attach arbitrary per-dispatch config (variant routing, state shape,
--- Receive Key paths, anything else) without requiring the Frame to
--- learn a new field for each.
---
--- `opts.plugins` (Phase 2 DynamicDelegation): an optional ordered list
--- of plugin modules. Each plugin is a table with at minimum a
--- `name` string and any of four optional functions:
---
---   * before_dispatch(spec, ctx) — sequential, spec is mutable
---   * around_dispatch(inner, spec, ctx) — onion wrap, can multi-call
---   * after_dispatch(response, spec, ctx) — sequential, response read-only
---   * finalize(state) — collected during `dispatcher.finalize(opts)`,
---     used to build alc.card groups (Card creation primitive; see below)
---
--- ctx fields available to plugins:
---   ctx.path / ctx.step / ctx.state / ctx.extras / ctx.scratch /
---   ctx.frame (the swarm_frame package for parse_verdict access)
---
--- Plugins enable variant routing, retry, cascade, vote, reflexion,
--- observability, etc. to be composed as separate modules without
--- requiring the Frame to learn each domain. See
--- `design/plugin-abstraction.md` for the full Phase 2 design.
---
--- ── Card primitive (`dispatcher.finalize(opts)`) ────────────────
---
--- Card creation is an algocline first-class concept (`alc.card.*`),
--- so the Frame adapter owns the act of writing Cards. The Frame
--- never inventories specific pkg names / variant semantics — those
--- are caller-supplied metadata (`opts.pkg_name`) and plugin-defined
--- groups respectively.
---
--- Card payload Entity (Frame Input Schema, 6 top-level fields):
---
---     pkg      = { name = <pkg_name> }     ← caller (opts.pkg_name)
---     model    = { id   = <pkg_name> }     ← caller (opts.pkg_name)
---     scenario = { name = <task_id> }     ← state.data.task_id
---     params   = Frame default ⊕ plugin extra (per-key merge)
---                 default: { variant = <group_name> }
---     metadata = Frame default ⊕ plugin extra (per-key merge)
---                 default: { trace_id, task_dir, plugin, group, run_status }
---     extra    = plugin-only Kind-keyed nested dict
---                 (Frame never inspects the Kind contents)
---
--- `pkg` / `model` / `scenario` are NOT pluggable. Plugins cannot
--- change the Card's identity. The `extra` field is the single
--- pluggable namespace for orch / plugin-specific structured data
--- that does not fit the 5 structured fields (params / metadata /
--- scenario / pkg / model). Kinds inside `extra` are plugin-defined
--- and Frame-opaque.
---
--- Plugin finalize contract:
---
---     plugin.finalize(state) → nil | {
---         groups   = { <group_name> = samples[] },    -- REQUIRED
---         params   = { ... }?,                        -- OPTIONAL
---         metadata = { ... }?,                        -- OPTIONAL
---         extra    = { <kind> = { ... } }?,           -- OPTIONAL
---     }
---
--- Frame iterates plugins, collects results, and writes one alc.card
--- per non-empty group with the merged 6-field payload. Plugin-side
--- params / metadata override the Frame default per key; extra is
--- merged at the Kind level (`payload.extra[kind] = plugin.extra[kind]`).
--- If multiple plugins write the same Kind, last wins with a warn log.
---
--- Plugins decide what counts as a Card group (variant_ab → blue /
--- green; future cascade plugin → primary / fallback; vote plugin →
--- candidate_1 / candidate_2 / ...). The Frame writes them faithfully
--- without interpreting the group name or the extra Kind names.
function M.make_dispatcher(opts)
    if type(opts) ~= "table" then error("swarm_frame_algocline.make_dispatcher: opts table required") end
    if type(opts.builder) ~= "function" then
        error("swarm_frame_algocline.make_dispatcher: opts.builder must be a function")
    end
    if type(opts.state) ~= "table" then
        error("swarm_frame_algocline.make_dispatcher: opts.state (algocline flow state) required")
    end

    local flow_pkg = opts.flow or require("flow")
    local frame_pkg = opts.frame or require("swarm_frame")
    local alc_pkg = opts.alc or _G.alc
    local builder = opts.builder
    local state = opts.state
    local llm_opts = opts.llm_opts -- forwarded verbatim; may be nil

    -- Opaque extension dict. The adapter never reads from it; it is
    -- handed back to the caller via `dispatcher.extras` so plugins /
    -- hooks attached at the orch layer can pull config (variant
    -- routing, state shape, Receive Key paths, ...) without the Frame
    -- learning a new field for each.
    local extras = opts.extras
    if extras ~= nil and type(extras) ~= "table" then
        error("swarm_frame_algocline.make_dispatcher: opts.extras must be a table or nil")
    end
    extras = extras or {}

    -- Phase 2: dispatch plugin chain. Each plugin is a table with
    -- { name, before_dispatch?, around_dispatch?, after_dispatch? }
    -- optionally produced via plugin.create(opts). The adapter
    -- validates only structural shape (table + non-empty name);
    -- the hook semantics are owned by each plugin module.
    local plugins = opts.plugins
    if plugins ~= nil and type(plugins) ~= "table" then
        error("swarm_frame_algocline.make_dispatcher: opts.plugins must be a list or nil")
    end
    plugins = plugins or {}
    -- C2: Aggregation accumulators for declared write contracts.
    -- spec_writes_registry / state_writes_registry surface what each
    -- plugin intends to write (spec fields and state.data._* keys).
    -- Frame collects, validates shape, warns on collision (multiple
    -- plugins declaring write to the same field), and exposes the
    -- registry via dispatcher.spec_writes / dispatcher.state_writes
    -- for tooling and audit. Declarations are *advisory* contracts —
    -- Frame does not intercept actual writes (Lua proxy overhead is
    -- not worth it for the per-dispatch hot path; declaration-only
    -- discipline is the same camp as pluggy hookspec/hookimpl).
    local spec_writes_registry = {} -- { [field] = { plugin_name, ... } }
    local state_writes_registry = {} -- { [key]   = { plugin_name, ... } }
    for i, p in ipairs(plugins) do
        if type(p) ~= "table" then
            error("swarm_frame_algocline.make_dispatcher: plugins[" .. i .. "] must be a table, got " .. type(p))
        end
        if type(p.name) ~= "string" or p.name == "" then
            error("swarm_frame_algocline.make_dispatcher: plugins[" .. i .. "].name must be a non-empty string")
        end
        for _, hk in ipairs({ "before_dispatch", "around_dispatch", "after_dispatch", "finalize" }) do
            if p[hk] ~= nil and type(p[hk]) ~= "function" then
                error(
                    "swarm_frame_algocline.make_dispatcher: plugins[" .. i .. "]." .. hk .. " must be a function or nil"
                )
            end
        end
        -- C2: optional spec_writes declaration (list of spec field names)
        if p.spec_writes ~= nil then
            if type(p.spec_writes) ~= "table" then
                error(
                    "swarm_frame_algocline.make_dispatcher: plugins["
                        .. i
                        .. "].spec_writes must be a list of strings or nil"
                )
            end
            for j, f in ipairs(p.spec_writes) do
                if type(f) ~= "string" or f == "" then
                    error(
                        "swarm_frame_algocline.make_dispatcher: plugins["
                            .. i
                            .. "].spec_writes["
                            .. j
                            .. "] must be a non-empty string"
                    )
                end
                spec_writes_registry[f] = spec_writes_registry[f] or {}
                table.insert(spec_writes_registry[f], p.name)
            end
        end
        -- C2: optional state_writes declaration (list of state.data._* keys)
        if p.state_writes ~= nil then
            if type(p.state_writes) ~= "table" then
                error(
                    "swarm_frame_algocline.make_dispatcher: plugins["
                        .. i
                        .. "].state_writes must be a list of strings or nil"
                )
            end
            for j, k in ipairs(p.state_writes) do
                if type(k) ~= "string" or k == "" then
                    error(
                        "swarm_frame_algocline.make_dispatcher: plugins["
                            .. i
                            .. "].state_writes["
                            .. j
                            .. "] must be a non-empty string"
                    )
                end
                if not k:match("^_") then
                    error(
                        "swarm_frame_algocline.make_dispatcher: plugins["
                            .. i
                            .. "].state_writes["
                            .. j
                            .. "]="
                            .. k
                            .. " must start with '_' (state.data._* namespace convention)"
                    )
                end
                state_writes_registry[k] = state_writes_registry[k] or {}
                table.insert(state_writes_registry[k], p.name)
            end
        end
    end

    -- C2: collision warn (multiple plugins declaring write to same field).
    -- Warn-only, not error — the Frame can't prove the writes actually
    -- collide at runtime, and some compositions legitimately layer writes
    -- (e.g. variant_ab + retry both touching spec.admission). But surfacing
    -- declared overlaps catches the typical typo / accidental land grab.
    local function warn_collisions(registry, kind)
        for field, owners in pairs(registry) do
            if #owners > 1 and type(alc_pkg) == "table" and type(alc_pkg.log) == "function" then
                alc_pkg.log(
                    "warn",
                    "swarm_frame_algocline: "
                        .. kind
                        .. " collision on '"
                        .. field
                        .. "' declared by "
                        .. #owners
                        .. " plugins: "
                        .. table.concat(owners, ", ")
                )
            end
        end
    end
    warn_collisions(spec_writes_registry, "spec_writes")
    warn_collisions(state_writes_registry, "state_writes")

    -- C3: route_llm — shared check_mode-aware routing primitive. Both
    -- core_dispatch (the orch's intended call) and ctx.llm_call (plugin
    -- around_dispatch aux calls; replaces direct alc.llm bypasses) go
    -- through this helper so they share the Frame's strict/non-check/
    -- format routing decision and token round-trip discipline.
    local function route_llm(prompt, effective_opts, slot)
        local mode = frame_pkg.check_mode()
        if mode == "non-check" then
            if type(alc_pkg) ~= "table" or type(alc_pkg.llm) ~= "function" then
                error(
                    "swarm_frame_algocline: alc.llm is not available "
                        .. "(non-check mode requires opts.alc or _G.alc.llm)"
                )
            end
            return alc_pkg.llm(prompt, effective_opts)
        else -- "strict" or "format": through flow.llm_bound
            return flow_pkg.llm_bound(state, {
                slot = slot,
                prompt = prompt,
                llm_opts = effective_opts,
            })
        end
    end

    -- core_dispatch: builder → routing (flow.llm_bound | alc.llm) →
    -- format-mode post-verify. Plugin pipeline wraps this with
    -- before / around / after hooks at the call site below.
    --
    -- Per-call llm_opts override: spec.llm_opts_overlay, if present,
    -- shallow-merges over the constructor-time llm_opts. This is the
    -- canonical per-dispatch override channel — plugins set
    -- spec.llm_opts_overlay in before_dispatch (or pass it via the
    -- orch's per-call spec) instead of mutating the constructor-time
    -- llm_opts or registering a separate llm_opts_override plugin.
    -- Keeps the seam at the Frame level rather than a 9th implicit
    -- mutation channel through plugin code.
    local function core_dispatch(spec, ctx)
        local prompt = builder(ctx.step, spec)
        if type(prompt) ~= "string" then
            error(
                "swarm_frame_algocline: builder must return a string (got " .. type(prompt) .. ") for step=" .. ctx.step
            )
        end

        -- Compute effective llm_opts. spec.llm_opts_overlay (if present)
        -- shallow-merges over the closure-captured llm_opts. Keys present
        -- in the overlay win; keys absent from the overlay fall back to
        -- the base.
        local effective_llm_opts = llm_opts
        if type(spec) == "table" and spec.llm_opts_overlay ~= nil then
            local overlay = spec.llm_opts_overlay
            if type(overlay) ~= "table" then
                error(
                    "swarm_frame_algocline: spec.llm_opts_overlay must be "
                        .. "a table or nil (got "
                        .. type(overlay)
                        .. ") for step="
                        .. ctx.step
                )
            end
            effective_llm_opts = {}
            if type(llm_opts) == "table" then
                for k, v in pairs(llm_opts) do
                    effective_llm_opts[k] = v
                end
            end
            for k, v in pairs(overlay) do
                effective_llm_opts[k] = v
            end
        end

        local mode = frame_pkg.check_mode()
        local response = route_llm(prompt, effective_llm_opts, ctx.step)

        if mode == "format" then
            local resp_str = type(response) == "string" and response or ""
            local obj_str = resp_str:match("(%b{})")
            if not obj_str then return "BLOCKED reason=format-non-json slot=" .. ctx.step end
            local ok, obj = pcall(frame_pkg.json_decode, obj_str)
            if not ok or type(obj) ~= "table" then
                local snippet = obj_str:sub(1, 120):gsub("\n", "\\n")
                local err_str = tostring(obj):sub(1, 80)
                return "BLOCKED reason=format-json-parse-error "
                    .. "(snippet="
                    .. snippet
                    .. " err="
                    .. err_str
                    .. ") slot="
                    .. ctx.step
            end
            if type(obj.status) ~= "string" or obj.status == "" then
                return "BLOCKED reason=format-missing-status slot=" .. ctx.step
            end
            if type(obj.flow_token) ~= "string" or obj.flow_token == "" then
                return "BLOCKED reason=format-missing-flow-token slot=" .. ctx.step
            end
            if type(obj.flow_slot) ~= "string" or obj.flow_slot == "" then
                return "BLOCKED reason=format-missing-flow-slot slot=" .. ctx.step
            end
            if obj.flow_slot ~= ctx.step then
                return "BLOCKED reason=format-flow-slot-mismatch (expected="
                    .. ctx.step
                    .. " got="
                    .. tostring(obj.flow_slot)
                    .. ") slot="
                    .. ctx.step
            end
        end

        return response or ""
    end

    -- Card finalize primitive. Iterates plugins, collects each
    -- plugin's `finalize(state)` result (`{ groups = { <name> =
    -- samples[] }, params? = {...} }`), and writes one alc.card per
    -- non-empty group. The Frame supplies pkg_name (caller-supplied
    -- metadata, opaque) + run identifiers (task_id / task_dir /
    -- _run_status from state); plugins supply group_name +
    -- per-sample payloads. Returns the list of written `card`
    -- objects (each with `.card_id`).
    local function finalize_cards(finalize_opts)
        finalize_opts = finalize_opts or {}
        local pkg_name = finalize_opts.pkg_name
        if type(pkg_name) ~= "string" or pkg_name == "" then
            error("swarm_frame_algocline: dispatcher.finalize: " .. "opts.pkg_name (non-empty string) required")
        end

        if type(alc_pkg) ~= "table" or type(alc_pkg.card) ~= "table" then
            error(
                "swarm_frame_algocline: dispatcher.finalize: "
                    .. "alc.card primitive not available (opts.alc or _G.alc missing)"
            )
        end

        local data = (type(state) == "table" and state.data) or {}
        local task_id = data.task_id or "unknown"
        local task_dir = data.task_dir
        local run_status = data._run_status or "done"

        -- C3: 2-phase staged commit (Issue 2 partial commit semantics).
        -- Phase 1 (collect): iterate plugins, call each finalize(state),
        -- build the per-group payload list. No card.create runs here.
        -- A plugin's finalize that throws is warn-logged and skipped
        -- (its payloads are not added to the list). Compared to the
        -- prior inline pattern (where plugin K's card was committed
        -- as soon as K's loop iteration ran, before K+1 ran), this
        -- ensures that no card.create executes until every plugin's
        -- finalize collection step has completed.
        --
        -- Phase 2 (write): iterate the collected payload list, do
        -- card.create + write_samples per entry. Failures here are
        -- best-effort warn (algocline-side has no rollback API).
        local to_write = {} -- list of { plugin, group_name, payload, samples }

        for _, p in ipairs(plugins) do
            if type(p.finalize) ~= "function" then
                -- plugin opted out of Card finalization; skip
            else
                local ok_f, result = pcall(p.finalize, state)
                if not ok_f then
                    if alc_pkg.log then
                        alc_pkg.log(
                            "warn",
                            "swarm_frame_algocline: "
                                .. "plugin["
                                .. p.name
                                .. "].finalize raised: "
                                .. tostring(result)
                        )
                    end
                elseif type(result) == "table" and type(result.groups) == "table" then
                    for group_name, samples in pairs(result.groups) do
                        if type(samples) == "table" and #samples > 0 then
                            -- Card payload Entity (6 Frame Input Schema
                            -- fields). pkg / model / scenario are caller-
                            -- and state-derived only — plugins cannot
                            -- override them. params / metadata are Frame
                            -- default ⊕ plugin extra (per-key merge).
                            -- extra is plugin-only: Kind-keyed nested
                            -- dict for orch / plugin-specific
                            -- structured data that does not fit the
                            -- structured 5-field schema.
                            local payload = {
                                pkg = { name = pkg_name },
                                model = { id = pkg_name },
                                params = { variant = group_name },
                                scenario = { name = task_id },
                                metadata = {
                                    trace_id = task_id,
                                    task_dir = task_dir,
                                    plugin = p.name,
                                    group = group_name,
                                    run_status = run_status,
                                },
                                extra = {},
                            }
                            -- Plugin-supplied params: merged into
                            -- payload.params (per-key override of the
                            -- default `variant = group_name`).
                            if type(result.params) == "table" then
                                for k, v in pairs(result.params) do
                                    payload.params[k] = v
                                end
                            end
                            -- Plugin-supplied metadata: merged into
                            -- payload.metadata (per-key override of
                            -- the Frame default trace / task_dir /
                            -- plugin / group / run_status keys).
                            if type(result.metadata) == "table" then
                                for k, v in pairs(result.metadata) do
                                    payload.metadata[k] = v
                                end
                            end
                            -- Plugin-supplied extra: merged into
                            -- payload.extra at the Kind level
                            -- (`extra[kind] = value`). Frame never
                            -- inspects the Kind contents. If multiple
                            -- plugins write the same Kind, last wins
                            -- with a warn log.
                            if type(result.extra) == "table" then
                                for kind, value in pairs(result.extra) do
                                    if payload.extra[kind] ~= nil and alc_pkg.log then
                                        alc_pkg.log(
                                            "warn",
                                            "swarm_frame_algocline: "
                                                .. "plugin["
                                                .. p.name
                                                .. "] overrides extra["
                                                .. tostring(kind)
                                                .. "] already set "
                                                .. "(last wins)"
                                        )
                                    end
                                    payload.extra[kind] = value
                                end
                            end
                            to_write[#to_write + 1] = {
                                plugin = p,
                                group_name = group_name,
                                payload = payload,
                                samples = samples,
                            }
                        end
                    end
                end
            end
        end

        -- Phase 2: write all collected payloads (best-effort per card).
        local written = {}
        for _, entry in ipairs(to_write) do
            local pname = entry.plugin.name
            local group_name = entry.group_name
            local payload = entry.payload
            local samples = entry.samples
            local ok_c, card_or_err = pcall(alc_pkg.card.create, payload)
            if ok_c and type(card_or_err) == "table" and card_or_err.card_id then
                local card = card_or_err
                local ok_s, err_s = pcall(alc_pkg.card.write_samples, card.card_id, samples)
                if not ok_s and alc_pkg.log then
                    alc_pkg.log(
                        "warn",
                        "swarm_frame_algocline: "
                            .. "card.write_samples["
                            .. pname
                            .. "/"
                            .. group_name
                            .. "] failed: "
                            .. tostring(err_s)
                    )
                end
                if alc_pkg.log then
                    alc_pkg.log(
                        "info",
                        "swarm_frame_algocline: "
                            .. "card["
                            .. pname
                            .. "/"
                            .. group_name
                            .. "] finalized "
                            .. tostring(card.card_id)
                            .. " (n="
                            .. #samples
                            .. ")"
                    )
                end
                written[#written + 1] = card
            else
                if alc_pkg.log then
                    alc_pkg.log(
                        "warn",
                        "swarm_frame_algocline: "
                            .. "card.create["
                            .. pname
                            .. "/"
                            .. group_name
                            .. "] failed: "
                            .. tostring(card_or_err)
                    )
                end
            end
        end

        return written
    end

    -- Return a callable table:
    --   dispatcher(...)             dispatches via the __call metamethod
    --   dispatcher.extras           opaque pass-through dict (Phase 1)
    --   dispatcher.plugins          plugin chain (Phase 2)
    --   dispatcher.finalize         Card primitive (Phase 2; see above)
    --   dispatcher.spec_writes      declared spec-field contracts (C2)
    --   dispatcher.state_writes     declared state.data._* contracts (C2)
    return setmetatable({
        extras = extras,
        plugins = plugins,
        finalize = finalize_cards,
        spec_writes = spec_writes_registry,
        state_writes = state_writes_registry,
    }, {
        __call = function(_self, path_or_step, spec, _ctx)
            -- Build per-call ctx for plugins. Plugins should write to
            -- ctx.scratch for per-dispatch memos and use ctx.extras /
            -- ctx.flow_state for read-only config / shared algocline
            -- flow state. ctx.state (when set by frame.run_linear) is
            -- the swarm_frame.State container and is NOT overwritten
            -- here — Phase 2 separates the two state layers under
            -- distinct names to avoid namespace collision.
            local ctx = _ctx or {}
            ctx.path = path_or_step
            ctx.step = frame_pkg.step_id_of(path_or_step)
            ctx.flow_state = state
            ctx.extras = extras
            ctx.scratch = ctx.scratch or {}
            -- Expose frame to plugins that may need parse_verdict in
            -- around_dispatch (cascade / reflexion etc.).
            ctx.frame = frame_pkg

            -- C3: ctx.llm_call — auxiliary LLM call routed through the
            -- Frame's check_mode-aware route_llm helper. Plugins that
            -- need to make extra LLM calls inside around_dispatch
            -- (3-step protocol, cascade sub-calls, reflexion critique)
            -- should use this instead of raw alc.llm / flow.llm_bound
            -- so the calls share the Frame's strict / non-check /
            -- format routing and the constructor-time llm_opts base
            -- (overlay-mergeable per call).
            --
            -- Signature: ctx.llm_call({ prompt = "...", slot? = "...",
            --                           llm_opts_overlay? = { ... } })
            -- Defaults: slot = ctx.step .. ":aux" to avoid colliding
            -- with the orch's intended core_dispatch slot under the
            -- same flow.llm_bound state.
            -- Note: format-mode post-verify is intentionally NOT
            -- applied — these are protocol / sub-protocol calls, not
            -- the orch's intended call expected to produce a JSON
            -- verdict. Callers handle the response shape themselves.
            ctx.llm_call = function(call_opts)
                if type(call_opts) ~= "table" then
                    error(
                        "swarm_frame_algocline: ctx.llm_call requires "
                            .. "an opts table (got "
                            .. type(call_opts)
                            .. ")"
                    )
                end
                local call_prompt = call_opts.prompt
                if type(call_prompt) ~= "string" or call_prompt == "" then
                    error("swarm_frame_algocline: ctx.llm_call: " .. "opts.prompt (non-empty string) required")
                end
                local call_slot = call_opts.slot or (ctx.step .. ":aux")
                local overlay = call_opts.llm_opts_overlay
                local effective = llm_opts
                if overlay ~= nil then
                    if type(overlay) ~= "table" then
                        error(
                            "swarm_frame_algocline: ctx.llm_call: "
                                .. "llm_opts_overlay must be a table or nil "
                                .. "(got "
                                .. type(overlay)
                                .. ")"
                        )
                    end
                    effective = {}
                    if type(llm_opts) == "table" then
                        for k, v in pairs(llm_opts) do
                            effective[k] = v
                        end
                    end
                    for k, v in pairs(overlay) do
                        effective[k] = v
                    end
                end
                return route_llm(call_prompt, effective, call_slot)
            end

            -- before_dispatch: sequential, spec is mutable.
            for _, p in ipairs(plugins) do
                if p.before_dispatch then p.before_dispatch(spec, ctx) end
            end

            -- around_dispatch: onion wrap, innermost = core_dispatch.
            -- The wrap order is reverse so that plugins[1].around is
            -- the outermost layer (first to see spec, last to see
            -- response) — matches the intuitive before / after order.
            local wrapped = core_dispatch
            for i = #plugins, 1, -1 do
                local p = plugins[i]
                if p.around_dispatch then
                    local inner = wrapped
                    local this_p = p
                    wrapped = function(s, c) return this_p.around_dispatch(inner, s, c) end
                end
            end

            local response = wrapped(spec, ctx)

            -- after_dispatch: sequential, response read-only.
            for _, p in ipairs(plugins) do
                if p.after_dispatch then p.after_dispatch(response, spec, ctx) end
            end

            -- Cleanup Frame-injected fields so the caller's ctx stays
            -- JSON-encodable by the host (alc_run encodes the orch's
            -- return value as JSON; ctx.frame and any closure
            -- references trapped under ctx.scratch would crash that
            -- encode with `unsupported value type 'function'`).
            -- Plugins must capture anything they need via closure
            -- variables during the hook calls; reading these fields
            -- outside the dispatch is not supported.
            ctx.path = nil
            ctx.step = nil
            ctx.flow_state = nil
            ctx.extras = nil
            ctx.scratch = nil
            ctx.frame = nil
            ctx.llm_call = nil

            return response or ""
        end,
    })
end

return M
