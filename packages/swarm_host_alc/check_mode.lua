---@module 'swarm_host_alc.check_mode'
-- Check-mode aware LLM routing + format-mode post-verify (scope-shrunk
-- absorb of swarm_frame_algocline core_dispatch's route_llm + format
-- post-verify slice).
--
-- Two pure helpers:
--   * route_llm(prompt, llm_opts, slot, deps) -> raw response
--       routes to alc.llm (non-check) or flow.llm_bound (strict / format)
--       per `deps.mode`. Token round-trip discipline lives in the
--       Frame layer (flow.llm_bound) — this module just dispatches.
--   * format_postverify(response, step, deps) -> response | BLOCKED_str
--       only relevant when mode == "format". Validates the response is
--       JSON with required {status, flow_token, flow_slot} fields and
--       flow_slot matches step. Returns the raw response on PASS, a
--       BLOCKED diagnostic string on any failure (per existing
--       swarm_frame_algocline convention).
--
-- The dispatcher (P5 Step 6) composes these helpers in core_dispatch.

local M = {}
M.VERSION = "0.0.1-v3-p5"

--- Route an LLM call through the check-mode-aware path.
---
--- @param prompt     string
--- @param llm_opts   table?
--- @param slot       string   -- step / slot identifier
--- @param deps table {
---     mode  : string,   -- "strict" | "non-check" | "format"
---     alc   : table?,   -- required for non-check (must have .llm fn)
---     flow  : table?,   -- required for strict / format (must have .llm_bound fn)
---     state : table?,   -- required for strict / format (algocline flow state)
--- }
--- @return any response
function M.route_llm(prompt, llm_opts, slot, deps)
    if type(deps) ~= "table" then
        error("swarm_host_alc.check_mode.route_llm: "
              .. "deps (table) required", 2)
    end
    local mode = deps.mode
    if type(mode) ~= "string" or mode == "" then
        error("swarm_host_alc.check_mode.route_llm: "
              .. "deps.mode (non-empty string) required", 2)
    end
    if mode == "non-check" then
        if type(deps.alc) ~= "table" or type(deps.alc.llm) ~= "function" then
            error("swarm_host_alc.check_mode.route_llm: alc.llm is not "
                  .. "available (non-check mode requires deps.alc.llm)", 2)
        end
        return deps.alc.llm(prompt, llm_opts)
    end
    -- strict | format: through flow.llm_bound
    if type(deps.flow) ~= "table" or type(deps.flow.llm_bound) ~= "function" then
        error("swarm_host_alc.check_mode.route_llm: flow.llm_bound is not "
              .. "available (" .. mode .. " mode requires deps.flow.llm_bound)", 2)
    end
    return deps.flow.llm_bound(deps.state, {
        slot     = slot,
        prompt   = prompt,
        llm_opts = llm_opts,
    })
end

--- Post-verify a format-mode response.
---
--- Returns:
---   * the raw response on PASS (response is a JSON object with
---     {status, flow_token, flow_slot}, flow_slot matches step)
---   * a `"BLOCKED reason=<r> slot=<s>"` diagnostic string on any failure
---
--- @param response any
--- @param step     string
--- @param deps table { json_decode : fun(s:string):any }
--- @return any response_or_blocked
function M.format_postverify(response, step, deps)
    if type(deps) ~= "table" or type(deps.json_decode) ~= "function" then
        error("swarm_host_alc.check_mode.format_postverify: "
              .. "deps.json_decode (function) required", 2)
    end
    local resp_str = (type(response) == "string") and response or ""
    local obj_str = resp_str:match("(%b{})")
    if not obj_str then
        return "BLOCKED reason=format-non-json slot=" .. tostring(step)
    end
    local ok, obj = pcall(deps.json_decode, obj_str)
    if not ok or type(obj) ~= "table" then
        local snippet = obj_str:sub(1, 120):gsub("\n", "\\n")
        local err_str = tostring(obj):sub(1, 80)
        return "BLOCKED reason=format-json-parse-error (snippet="
               .. snippet .. " err=" .. err_str .. ") slot=" .. tostring(step)
    end
    if type(obj.status) ~= "string" or obj.status == "" then
        return "BLOCKED reason=format-missing-status slot=" .. tostring(step)
    end
    if type(obj.flow_token) ~= "string" or obj.flow_token == "" then
        return "BLOCKED reason=format-missing-flow-token slot=" .. tostring(step)
    end
    if type(obj.flow_slot) ~= "string" or obj.flow_slot == "" then
        return "BLOCKED reason=format-missing-flow-slot slot=" .. tostring(step)
    end
    if obj.flow_slot ~= step then
        return "BLOCKED reason=format-flow-slot-mismatch (expected="
               .. tostring(step) .. " got=" .. tostring(obj.flow_slot)
               .. ") slot=" .. tostring(step)
    end
    return response
end

return M
