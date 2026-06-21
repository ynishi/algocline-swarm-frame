---@module 'swarm_frame.v3.contract.state_backend_iface'
-- State backend iface — 4 method (write / read / exists / delete) per
-- V3 §4.1.4 (default = file backend, host adapter provides impl).
--
-- The backend is a Lua table of methods, not a function. alc_shapes
-- cannot shape-check a callable table, so we expose:
--   * M.WriteArgs / M.ReadResult — I/O value shapes
--   * M.check_iface(backend) — light 4-method probe
--
-- Backends MUST be idempotent on delete (deleting a non-existent task_id
-- is OK), and MUST guarantee read-after-write consistency within a task.

local T = require("alc_shapes.t")
local state_schema = require("swarm_frame.v3.contract.state_schema")
local M = {}
M.VERSION = "0.0.1-v3-p4"

--- write(task_id, snapshot) -> ok? / (nil, reason)
M.WriteArgs = T.shape({
    task_id  = T.string,
    snapshot = T.any:describe("Snapshot table conforming to state_schema.Snapshot"),
}, { open = false })

--- read(task_id) -> snapshot? / nil (when missing)
M.ReadResult = T.shape({
    snapshot = T.any:describe(
        "Snapshot or nil if task_id has no persisted state"),
}, { open = true })

--- Light probe — verifies backend exposes the 4 required methods.
--- Returns `true` or `(nil, reason)`.
function M.check_iface(backend)
    if type(backend) ~= "table" then
        return false, "state_backend must be a table"
    end
    for _, method in ipairs({ "write", "read", "exists", "delete" }) do
        if type(backend[method]) ~= "function" then
            return false,
                "state_backend missing method '" .. method .. "' (or not a function)"
        end
    end
    return true
end

-- Re-export the Snapshot schema for caller convenience.
M.Snapshot = state_schema.Snapshot

return M
