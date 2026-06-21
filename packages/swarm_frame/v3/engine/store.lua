---@module 'swarm_frame.v3.engine.store'
-- Offload semantics: raw payload -> artifact_id reference (V3 §4.3.2).
-- Large step responses (raw text / tokens / structured artifacts) are
-- offloaded to the artifact_backend and the ctx receives a compact
-- Summary stub instead of the raw payload. Downstream consumers fetch
-- the full payload from the backend on demand.
--
-- P3 minimal: offload / restore helpers. Inline (no auto-trigger),
-- caller decides when to offload by calling store.offload(payload,
-- backend, opts). Auto-offload heuristics (size threshold, schema
-- annotation) is a future phase carry.

local artifact_iface = require("swarm_frame.v3.contract.artifact_backend_iface")

local M = {}
M.VERSION = "0.0.1-v3-p3"

--- offload(payload, backend, opts) -> Summary stub
--- opts: { artifact_id = string?, kind = string?, preview_chars = integer? }
function M.offload(payload, backend, opts)
    opts = opts or {}
    local ok, reason = artifact_iface.check_iface(backend)
    if not ok then
        error("store.offload: " .. reason, 2)
    end
    local artifact_id = opts.artifact_id
        or ("a-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000)))
    local ok_w, err = backend:write(artifact_id, payload, opts)
    if ok_w == false then
        error("store.offload: backend.write failed: " .. tostring(err), 2)
    end
    local preview
    if opts.preview_chars and type(payload) == "string" then
        preview = payload:sub(1, opts.preview_chars)
    end
    return {
        artifact_id = artifact_id,
        kind        = opts.kind,
        size        = (type(payload) == "string") and #payload or nil,
        preview     = preview,
    }
end

--- restore(summary, backend) -> payload
function M.restore(summary, backend)
    if type(summary) ~= "table" or type(summary.artifact_id) ~= "string" then
        error("store.restore: summary.artifact_id (string) required", 2)
    end
    local ok, reason = artifact_iface.check_iface(backend)
    if not ok then
        error("store.restore: " .. reason, 2)
    end
    return backend:read(summary.artifact_id)
end

return M
