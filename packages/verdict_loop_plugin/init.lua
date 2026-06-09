--- verdict_loop_plugin is a Swarm plugin that wraps a pipeline step with gate-verdict-fix-retry loop semantics
---
--- Implements VerdictLoop: for each attempt up to max_retries+1, dispatch
--- the gate step, evaluate the response with parser(), return on "pass",
--- call ctx.dispatch(fix_spec) on "blocked" if fix_spec is present, and
--- return an exhausted BLOCKED string after all attempts are consumed.
---
--- This plugin uses around_step + ctx.dispatch (Middle v0.3.0 primitives)
--- and applies to a single declared step_id; all other steps pass through
--- transparently, enabling multiple instances to co-exist in opts.plugins.
---
--- V1 coding_orch._verdict_loop 14 call-sites pattern is the reference.
---
--- Status: v0.1.0

local M = {}

M.VERSION = "0.1.0"

M.meta = {
    name = "verdict_loop_plugin",
    version = "0.1.0",
    category = "frame_plugin",
    description = "Swarm plugin: wraps a pipeline step with gate-verdict-fix-retry loop semantics "
        .. "(around_step + ctx.dispatch). Dispatches gate, evaluates parser(resp, ctx), "
        .. "calls ctx.dispatch(fix_spec) on blocked, exhausts after max_retries+1 attempts.",
}

--- Create a VerdictLoop plugin instance.
---
---@param opts {
---   step_id    : string,         -- required; step to wrap (others pass through)
---   gate_spec  : table,          -- required; spec forwarded to inner() (must have agent string)
---   parser     : function,       -- required; fun(resp:string, ctx:table)->"pass"|"blocked"
---   fix_spec   : table?,         -- optional; spec forwarded to ctx.dispatch() on blocked
---   max_retries: integer?,       -- optional; default 2 (V1 gate_max_retries or 2)
---   verdict_key: string?,        -- optional; if set, parser receives ctx[verdict_key] shared-ref
--- }
---@return table plugin_instance
function M.create(opts)
    opts = opts or {}

    -- ── required field validation ────────────────────────────────────
    if type(opts.step_id) ~= "string" or opts.step_id == "" then
        error("verdict_loop_plugin.create: opts.step_id must be a non-empty string")
    end
    if type(opts.gate_spec) ~= "table" then error("verdict_loop_plugin.create: opts.gate_spec must be a table") end
    if type(opts.gate_spec.agent) ~= "string" or opts.gate_spec.agent == "" then
        error("verdict_loop_plugin.create: opts.gate_spec.agent must be a non-empty string")
    end
    if type(opts.parser) ~= "function" then error("verdict_loop_plugin.create: opts.parser must be a function") end

    -- ── optional fields with defaults ────────────────────────────────
    local step_id = opts.step_id
    local gate_spec = opts.gate_spec
    local fix_spec = opts.fix_spec -- nil is valid (1-attempt-only pattern)
    local parser = opts.parser
    local max_retries = opts.max_retries
    if max_retries == nil then max_retries = 2 end
    local verdict_key = opts.verdict_key -- nil is valid

    -- ── plugin instance ───────────────────────────────────────────────
    return {
        name = "verdict_loop_plugin:" .. step_id,

        --- Step-level onion wrap — VerdictLoop logic.
        --- inner(step_spec) invokes the full dispatch chain
        --- (before/around/after_dispatch → core_dispatch), satisfying
        --- Crux 2: around_step's inner() passes through around_dispatch
        --- onion, not a stub.
        ---
        --- ctx.dispatch(fix_spec) invokes the same __call dispatch chain
        --- (before/around/after_dispatch), satisfying Crux 1: no chain skip.
        around_step = function(inner, sid, step_spec, ctx)
            -- Transparent passthrough for steps this plugin does not own.
            if sid ~= step_id then return inner(step_spec, ctx) end

            local max_attempts = max_retries + 1
            local last_resp

            for attempt = 1, max_attempts do
                -- Gate dispatch: inner() goes through full dispatch chain.
                local resp = inner(gate_spec, ctx)
                last_resp = resp

                -- Evaluate verdict.
                local verdict
                if verdict_key ~= nil then
                    -- Shared-ref pattern: parser reads ctx[verdict_key] updated
                    -- by the gate dispatch (e.g. gate_ctx_wrapper in 3_GATE).
                    verdict = parser(resp, ctx, ctx[verdict_key])
                else
                    verdict = parser(resp, ctx)
                end

                if verdict == "pass" then return resp end

                -- Blocked path.
                if attempt < max_attempts and fix_spec ~= nil then
                    -- ctx.dispatch traverses before/around/after_dispatch chain
                    -- (Crux 1: chain passthrough via Middle v0.3.0).
                    local fix_resp = ctx.dispatch(fix_spec)

                    -- If Middle safeguard returned BLOCKED, propagate immediately
                    -- (OQ-3 recommendation (a): fix falling → exhausted immediately).
                    if type(fix_resp) == "string" and string.sub(fix_resp, 1, 7) == "BLOCKED" then
                        return "BLOCKED reason=verdict_loop_plugin.exhausted"
                            .. " plugin=verdict_loop_plugin:"
                            .. step_id
                            .. " attempts="
                            .. tostring(attempt)
                            .. " fix_blocked="
                            .. fix_resp
                    end
                end

                -- fix_spec == nil or last attempt: loop ends naturally.
                -- If fix_spec == nil, break after the first attempt regardless
                -- of max_retries (V1 secret/hygiene/committer 1-attempt pattern).
                if fix_spec == nil then break end
            end

            -- All attempts exhausted (or fix_spec == nil and single attempt blocked).
            return "BLOCKED reason=verdict_loop_plugin.exhausted"
                .. " plugin=verdict_loop_plugin:"
                .. step_id
                .. " attempts="
                .. tostring((fix_spec == nil) and 1 or max_attempts)
        end,

        --- Advisory: this plugin wraps step_id. Middle warns on collision
        --- when two plugins declare the same step_id.
        step_writes = { step_id },
    }
end

return M
