---@module 'swarm_frame.v3.contract.artifact_backend_iface'
-- Artifact backend iface — 4 method (write / read / exists / delete) for
-- /engine/store offload semantics (V3 §4.3.2). Large step responses
-- (raw text / tokens / structured artifact) are offloaded to backend and
-- replaced with an artifact_id reference in ctx.
--
-- The backend is a Lua table of methods. Same form as state_backend_iface
-- (sibling iface): expose I/O shapes + light 4-method probe.

local T = require("alc_shapes.t")
local M = {}
M.VERSION = "0.0.1-v3-p4"

--- write(artifact_id, payload, opts?) -> ok? / (nil, reason)
M.WriteArgs = T.shape({
    artifact_id = T.string:describe("opaque content-addressed or sequential id"),
    payload     = T.any:describe("raw bytes / string / serializable table"),
    opts        = T.table:is_optional(),
}, { open = false })

--- read(artifact_id) -> payload? / nil (when missing)
M.ReadResult = T.shape({
    payload = T.any:describe("raw payload or nil if artifact_id has no record"),
}, { open = true })

--- Summary descriptor written into ctx in place of the raw payload.
--- Consumers see this stub; they can fetch the full payload via the
--- backend when needed.
M.Summary = T.shape({
    artifact_id = T.string,
    kind        = T.one_of({ "text", "json", "binary" }):is_optional(),
    size        = T.number:is_optional():describe("byte / char length hint"),
    preview     = T.string:is_optional():describe("first N chars / bytes"),
}, { open = true })

--- Light probe — verifies backend exposes the 4 required methods.
function M.check_iface(backend)
    if type(backend) ~= "table" then
        return false, "artifact_backend must be a table"
    end
    for _, method in ipairs({ "write", "read", "exists", "delete" }) do
        if type(backend[method]) ~= "function" then
            return false,
                "artifact_backend missing method '" .. method .. "' (or not a function)"
        end
    end
    return true
end

return M
