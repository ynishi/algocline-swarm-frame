---@module 'swarm_frame.v3.contract.observer_hook'
-- Observer event payload schema (V3 §4.3.4).
--
-- Open shape: observer impls (logger / journal / metric collector) MAY
-- ignore fields they do not care about and MAY emit extra fields without
-- invalidating other consumers. Field semantics:
--
--   step_id     opaque step id (let / step / branch / loop / fan / call)
--   phase       lifecycle hook ("start" | "end" | "error")
--   ref         dispatcher ref string (only meaningful for step / call)
--   duration_ms wall-clock duration (end / error events)
--   verdict     domain verdict string (e.g. "DONE" for verdict_loop composites)
--   artifact_id reference to /engine/store offload (if any)
--   error       structured error payload (kind + message), error events only
--
-- §8.4 OQ #5 carry: full field set is "open + suggested" — V4 may
-- tighten to a closed shape once observer consumers stabilize.

local T = require("alc_shapes.t")
local M = {}
M.VERSION = "0.0.1-v3-p4"

M.EventPayload = T.shape({
    step_id     = T.string:is_optional(),
    phase       = T.one_of({ "start", "end", "error" }):is_optional(),
    ref         = T.string:is_optional(),
    duration_ms = T.number:is_optional(),
    verdict     = T.string:is_optional(),
    artifact_id = T.string:is_optional(),
    error       = T.shape({
        kind    = T.string,
        message = T.string,
    }, { open = true }):is_optional(),
}, { open = true })

--- Observer is a Lua function `(event: EventPayload) -> nil`.
--- Light probe — caller-side validate before plumbing into Engine.
function M.check_call(fn)
    if type(fn) ~= "function" then
        return false, "observer must be a function (event) -> nil"
    end
    return true
end

return M
