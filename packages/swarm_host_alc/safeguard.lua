---@module 'swarm_host_alc.safeguard'
-- Safeguard defaults + opts merge for make_dispatcher.
--
-- Single source of truth for the per-dispatcher safeguard knobs:
--   * max_dispatch_per_step — per-plugin per-step ctx.dispatch call cap
--   * max_recursion_depth   — overall ctx.dispatch nesting cap
--
-- V3 reframe (#7): default values were previously hardcoded inside
-- swarm_frame_algocline.make_dispatcher (line 188-189). Lifting them
-- into a dedicated module makes the SoT a single place and lets the
-- dispatcher reach them as `safeguard.DEFAULTS.<key>` for both opts
-- merging and runtime introspection.

local M = {}
M.VERSION = "0.0.1-v3-p5"

M.meta = {
    name = "swarm_host_alc.safeguard",
    version = M.VERSION,
    category = "frame",
    description = "Safeguard defaults + opts merge for make_dispatcher "
        .. "(max_dispatch_per_step / max_recursion_depth SoT).",
}

--- Default safeguard knobs. Held as a plain table so callers can read
--- the defaults without invoking `merge` (e.g. for documentation or
--- introspection in tooling).
M.DEFAULTS = {
    max_dispatch_per_step = 16,
    max_recursion_depth = 4,
}

local function _is_positive_int(v)
    return type(v) == "number" and v >= 1 and v == math.floor(v)
end

--- Merge user-supplied safeguard opts over DEFAULTS, validate, and
--- return the effective {max_dispatch_per_step, max_recursion_depth}
--- table.
---
--- @param opts table? user-supplied opts (nil = use DEFAULTS verbatim)
--- @return table effective
function M.merge(opts)
    if opts ~= nil and type(opts) ~= "table" then
        error("swarm_host_alc.safeguard.merge: opts must be a table or nil "
            .. "(got " .. type(opts) .. ")")
    end
    opts = opts or {}
    local effective = {
        max_dispatch_per_step = opts.max_dispatch_per_step
            or M.DEFAULTS.max_dispatch_per_step,
        max_recursion_depth = opts.max_recursion_depth
            or M.DEFAULTS.max_recursion_depth,
    }
    if not _is_positive_int(effective.max_dispatch_per_step) then
        error("swarm_host_alc.safeguard.merge: max_dispatch_per_step must "
            .. "be a positive integer (got "
            .. tostring(effective.max_dispatch_per_step) .. ")")
    end
    if not _is_positive_int(effective.max_recursion_depth) then
        error("swarm_host_alc.safeguard.merge: max_recursion_depth must "
            .. "be a positive integer (got "
            .. tostring(effective.max_recursion_depth) .. ")")
    end
    return effective
end

return M
