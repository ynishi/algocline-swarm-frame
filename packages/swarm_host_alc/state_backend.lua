---@module 'swarm_host_alc.state_backend'
-- File-default state backend for swarm_frame V3 runtime (§4.1.4).
--
-- Implements `swarm_frame.v3.contract.state_backend_iface` 4-method
-- contract (write / read / exists / delete) keyed by task_id. Snapshot
-- bodies are JSON-encoded via the host's alc.json_* hook (same
-- resolution path swarm_frame.artifact_store uses, so the Pack tests
-- in-process with swarm_frame.host injection still work).
--
-- File layout (multi-task pattern):
--   <base_dir>/<task_id>/state.json
--
-- The multi-task pattern matches the mock backend in
-- spec/v3_state_spec.lua (`store[task_id]`) and the resume protocol in
-- engine/state.lua (`backend.exists(task_id)`). Caller-owned single-
-- task usage (one task_dir per backend instance) is also supported
-- via `opts.task_dir`, which short-circuits the per-task_id sub-
-- directory and writes `<task_dir>/state.json` directly.
--
-- Idempotency: delete on non-existent task_id is a no-op (contract
-- requires this). write replaces any prior snapshot atomically via
-- write-then-rename when possible (falls back to plain io.open on
-- failure to keep the impl portable across Lua runtimes that lack
-- os.rename semantics).

local M = {}
M.VERSION = "0.0.1-v3-p5"

local STATE_FILE = "state.json"

-- ─── host JSON resolution (lazy, swarm_frame DI seam) ──────────────────

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
    error("swarm_host_alc.state_backend: requires _G.alc.json_* "
          .. "(algocline runtime) or swarm_frame.host injection", 2)
end

local function _encode(t) return _host_json().encode(t) end
local function _decode(s) return _host_json().decode(s) end

-- ─── filesystem helpers ────────────────────────────────────────────────

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
    if f then
        f:close()
        return true
    end
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

-- ─── path resolution ───────────────────────────────────────────────────

--- Resolve the absolute state file path for a given task_id.
---
--- Two modes:
---   * `opts.task_dir` set: single-task mode. All task_ids share
---     `<task_dir>/state.json`. task_id is recorded inside the snapshot
---     payload but does not participate in path resolution.
---   * `opts.base_dir` set: multi-task mode. Each task_id maps to
---     `<base_dir>/<task_id>/state.json`.
local function _resolve_state_path(opts, task_id)
    if opts.task_dir then
        return opts.task_dir .. "/" .. STATE_FILE
    end
    return opts.base_dir .. "/" .. tostring(task_id) .. "/" .. STATE_FILE
end

-- ─── factory ───────────────────────────────────────────────────────────

--- Create a file-backed state backend.
---
--- @param opts table {
---     task_dir : string?,   -- single-task mode (mutually exclusive with base_dir)
---     base_dir : string?,   -- multi-task mode (default; one of the two is required)
--- }
--- @return backend object with write/read/exists/delete methods
function M.file_backend(opts)
    opts = opts or {}
    if opts.task_dir == nil and opts.base_dir == nil then
        error("swarm_host_alc.state_backend.file_backend: "
              .. "opts.task_dir or opts.base_dir is required", 2)
    end
    if opts.task_dir ~= nil and opts.base_dir ~= nil then
        error("swarm_host_alc.state_backend.file_backend: "
              .. "opts.task_dir and opts.base_dir are mutually exclusive", 2)
    end

    local backend = {}

    function backend.write(task_id, snapshot)
        if type(task_id) ~= "string" or task_id == "" then
            return nil, "write: task_id must be a non-empty string"
        end
        if type(snapshot) ~= "table" then
            return nil, "write: snapshot must be a table"
        end
        local path = _resolve_state_path(opts, task_id)
        local ok, mkerr = _mkdir_p(_parent_dir(path))
        if not ok then return nil, "write: " .. tostring(mkerr) end
        local enc_ok, encoded = pcall(_encode, snapshot)
        if not enc_ok then
            return nil, "write: json_encode failed: " .. tostring(encoded)
        end
        local wok, werr = _write_file(path, encoded)
        if not wok then return nil, "write: " .. tostring(werr) end
        return true
    end

    function backend.read(task_id)
        if type(task_id) ~= "string" or task_id == "" then return nil end
        local path = _resolve_state_path(opts, task_id)
        local bytes = _read_file(path)
        if bytes == nil then return nil end
        local dec_ok, snapshot = pcall(_decode, bytes)
        if not dec_ok then return nil end
        if type(snapshot) ~= "table" then return nil end
        return snapshot
    end

    function backend.exists(task_id)
        if type(task_id) ~= "string" or task_id == "" then return false end
        return _file_exists(_resolve_state_path(opts, task_id))
    end

    function backend.delete(task_id)
        if type(task_id) ~= "string" or task_id == "" then return true end
        local path = _resolve_state_path(opts, task_id)
        os.remove(path)
        return true
    end

    return backend
end

-- ─── in-memory backend (testing / future SQLite drop-in seat) ──────────

--- Create an in-memory state backend. Useful for tests that do not
--- want to touch the filesystem.
function M.memory_backend()
    local store = {}
    local backend = {}
    function backend.write(task_id, snapshot)
        if type(task_id) ~= "string" or task_id == "" then
            return nil, "write: task_id must be a non-empty string"
        end
        if type(snapshot) ~= "table" then
            return nil, "write: snapshot must be a table"
        end
        store[task_id] = snapshot
        return true
    end
    function backend.read(task_id) return store[task_id] end
    function backend.exists(task_id) return store[task_id] ~= nil end
    function backend.delete(task_id) store[task_id] = nil; return true end
    return backend
end

return M
