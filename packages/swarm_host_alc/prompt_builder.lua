---@module 'swarm_host_alc.prompt_builder'
-- Prompt builder injection + llm_opts overlay merge (scope-shrunk
-- absorb of the relevant slice of swarm_frame_algocline core_dispatch).
--
-- Two pure helpers:
--   * invoke(builder, step, spec) -> string prompt
--       calls the caller-supplied builder fn with (step, spec) and
--       enforces the contract "builder must return a non-nil string".
--   * merge_llm_opts(base, overlay, step) -> effective_llm_opts
--       shallow-merge spec.llm_opts_overlay over the constructor-time
--       base. nil overlay returns base verbatim; non-table overlay
--       raises with a step-tagged message.
--
-- The dispatcher (P5 Step 6) composes these two helpers in
-- core_dispatch.

local M = {}
M.VERSION = "0.0.1-v3-p5"

--- Call the builder fn for a given step + spec and validate the result.
---
--- @param builder function   -- fun(step:string, spec:table?):string
--- @param step    string     -- step / slot identifier (for error trace)
--- @param spec    table?     -- per-call spec (optional)
--- @return string prompt
function M.invoke(builder, step, spec)
    if type(builder) ~= "function" then
        error("swarm_host_alc.prompt_builder.invoke: "
              .. "builder must be a function (got " .. type(builder) .. ")", 2)
    end
    local prompt = builder(step, spec)
    if type(prompt) ~= "string" then
        error("swarm_host_alc.prompt_builder.invoke: "
              .. "builder must return a string (got " .. type(prompt)
              .. ") for step=" .. tostring(step), 2)
    end
    return prompt
end

--- Shallow-merge spec.llm_opts_overlay over a constructor-time base.
---
--- Semantics (preserved from swarm_frame_algocline):
---   * overlay == nil: returns base verbatim (no copy)
---   * overlay is a table: returns a fresh table with base keys first,
---     overlay keys overwriting on collision
---   * overlay is anything else: error tagged with step
---
--- @param base    table?  -- constructor-time llm_opts (may be nil)
--- @param overlay any     -- spec.llm_opts_overlay (may be nil, table, or invalid)
--- @param step    string  -- step / slot identifier (for error trace)
--- @return table? effective_llm_opts
function M.merge_llm_opts(base, overlay, step)
    if overlay == nil then return base end
    if type(overlay) ~= "table" then
        error("swarm_host_alc.prompt_builder.merge_llm_opts: "
              .. "overlay must be a table or nil (got " .. type(overlay)
              .. ") for step=" .. tostring(step), 2)
    end
    local merged = {}
    if type(base) == "table" then
        for k, v in pairs(base) do merged[k] = v end
    end
    for k, v in pairs(overlay) do merged[k] = v end
    return merged
end

return M
