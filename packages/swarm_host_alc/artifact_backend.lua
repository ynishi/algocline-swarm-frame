---@module 'swarm_host_alc.artifact_backend'
-- File-default + memory artifact backend for swarm_frame V3 runtime
-- (§4.1.4 / §4.3.2 offload semantics).
--
-- Implements `swarm_frame.v3.contract.artifact_backend_iface` 4-method
-- contract (write / read / exists / delete) keyed by artifact_id.
-- Called by `swarm_frame.v3.engine.store.offload` with colon-syntax
-- (`backend:write(artifact_id, payload, opts)` etc.); methods are
-- defined with `function backend:method(...)` so the `self` receiver
-- is implicit.
--
-- Encoding policy (§4.3.2):
--   * opts.kind == "binary": payload written as-is via tostring()
--   * opts.kind == "json"  : payload JSON-encoded via the host hook
--   * default              : tostring() — raw string passthrough
--
-- The backend stores raw bytes; round-tripping a table payload requires
-- the caller to set opts.kind = "json" on write AND decode on read.
-- engine/store.restore returns the raw bytes verbatim so the decode
-- decision lives at the consumer layer (contract-spec-compatible).
--
-- File layout (file_backend):
--   <task_dir>/artifacts/<artifact_id>

local M = {}
M.VERSION = "0.0.1-v3-p5"

local ARTIFACT_SUBDIR = "artifacts"

-- ─── host JSON resolution (lazy, shared shape with state_backend) ──────

local function _host_json()
    local sf = package.loaded["swarm_frame"]
    if sf and type(sf.host) == "table"
       and type(sf.host.encode) == "function"
       and type(sf.host.decode) == "function" then
        return sf.host
    end
    if type(_G.alc) == "table"
       and type(_G.alc.json_encode) == "function"
       and type(_G.alc.json_decode) == "function" then
        return { encode = _G.alc.json_encode, decode = _G.alc.json_decode }
    end
    error("swarm_host_alc.artifact_backend: requires _G.alc.json_* "
          .. "(algocline runtime) or swarm_frame.host injection", 2)
end

local function _encode_json(t) return _host_json().encode(t) end

-- ─── filesystem helpers (mirrors state_backend) ────────────────────────

local function _shell_quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

local function _mkdir_p(dir)
    local ok, _, code = os.execute("mkdir -p " .. _shell_quote(dir))
    if not ok then
        return nil, "mkdir -p failed (code=" .. tostring(code) .. ") for " .. dir
    end
    return true
end

local function _parent_dir(path)
    return path:match("^(.*)/[^/]+$") or "."
end

local function _file_exists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

local function _read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function _write_file(path, bytes)
    local f, err = io.open(path, "wb")
    if not f then return nil, "io.open failed: " .. tostring(err) end
    local wok = f:write(bytes)
    f:close()
    if not wok then return nil, "write failed for " .. path end
    return true
end

-- ─── payload-to-bytes encoder (sole encode site, mirrors artifact_store) ─

local function _payload_to_bytes(payload, kind)
    if kind == "json" then
        return _encode_json(payload)
    end
    -- "binary" / "text" / nil — passthrough via tostring()
    return tostring(payload)
end

-- ─── factory: file_backend ─────────────────────────────────────────────

--- Create a file-system artifact backend.
---
--- @param opts table {
---     task_dir : string,   -- required. artifacts written under
---                          -- <task_dir>/artifacts/<artifact_id>
--- }
function M.file_backend(opts)
    opts = opts or {}
    local task_dir = opts.task_dir
    if type(task_dir) ~= "string" or task_dir == "" then
        error("swarm_host_alc.artifact_backend.file_backend: "
              .. "opts.task_dir (non-empty string) is required", 2)
    end

    local backend = {}

    local function _abs(artifact_id)
        return task_dir .. "/" .. ARTIFACT_SUBDIR .. "/" .. tostring(artifact_id)
    end

    --- write(artifact_id, payload, opts?) — encode then persist bytes.
    function backend:write(artifact_id, payload, write_opts)
        if type(artifact_id) ~= "string" or artifact_id == "" then
            return false, "write: artifact_id must be a non-empty string"
        end
        write_opts = write_opts or {}
        local enc_ok, bytes = pcall(_payload_to_bytes, payload, write_opts.kind)
        if not enc_ok then
            return false, "write: encode failed: " .. tostring(bytes)
        end
        local path = _abs(artifact_id)
        local mok, mkerr = _mkdir_p(_parent_dir(path))
        if not mok then return false, "write: " .. tostring(mkerr) end
        local wok, werr = _write_file(path, bytes)
        if not wok then return false, "write: " .. tostring(werr) end
        return true
    end

    --- read(artifact_id) — raw bytes; nil when missing.
    function backend:read(artifact_id)
        if type(artifact_id) ~= "string" or artifact_id == "" then return nil end
        return _read_file(_abs(artifact_id))
    end

    --- exists(artifact_id) — bool.
    function backend:exists(artifact_id)
        if type(artifact_id) ~= "string" or artifact_id == "" then return false end
        return _file_exists(_abs(artifact_id))
    end

    --- delete(artifact_id) — idempotent.
    function backend:delete(artifact_id)
        if type(artifact_id) ~= "string" or artifact_id == "" then return true end
        os.remove(_abs(artifact_id))
        return true
    end

    return backend
end

-- ─── factory: memory_backend ───────────────────────────────────────────

--- Create an in-memory artifact backend. The payload is stored verbatim
--- (no encode) so memory_backend round-trips tables natively. This is
--- intentionally different from file_backend (which always serialises
--- to bytes); tests can choose whichever shape matches their assertion.
function M.memory_backend()
    local store = {}
    local backend = {}

    function backend:write(artifact_id, payload, _opts)
        if type(artifact_id) ~= "string" or artifact_id == "" then
            return false, "write: artifact_id must be a non-empty string"
        end
        store[artifact_id] = payload
        return true
    end

    function backend:read(artifact_id) return store[artifact_id] end

    function backend:exists(artifact_id) return store[artifact_id] ~= nil end

    function backend:delete(artifact_id)
        store[artifact_id] = nil
        return true
    end

    return backend
end

return M
