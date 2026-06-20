-- swarm_frame.artifact_store
--
-- Provides artifact persistence backends and a content-addressed store.
--
-- Backend contract (source-agnostic 4-method interface):
--   backend:write(rel_path, bytes)  -- bytes is an encoded string, no format logic here
--   backend:read(rel_path)          -- returns bytes string or nil
--   backend:exists(rel_path)        -- returns boolean
--   backend:delete(rel_path)        -- removes the artifact
--
-- Crux constraints enforced here:
--   1. backend impl must NOT contain format conversion or FS path resolution logic
--   2. artifact_store:offload is the SOLE site of payload-to-bytes conversion
--   3. M.summarize is a standalone pure function with no dependency on store/backend

local M = {}

-- ─── Internal json encode chain (circular require avoidance) ─────────────────
--
-- Do NOT eagerly call require("swarm_frame") here — that would create a
-- circular dependency since init.lua requires this module at the bottom.
-- Instead, look the parent module up lazily via package.loaded at call
-- time so the DI seam (swarm_frame.host) is honoured the same way the
-- init.lua resolver does. Resolution order:
--   1. swarm_frame.host explicit injection (test or app override)
--   2. _G.alc.json_encode / _G.alc.json_decode (algocline runtime)
-- Otherwise raise — same contract as init.lua's host().

local function _host()
    local sf = package.loaded["swarm_frame"]
    if sf and sf.host then
        if
            type(sf.host) == "table"
            and type(sf.host.encode) == "function"
            and type(sf.host.decode) == "function"
        then
            return sf.host
        end
    end
    if
        type(_G.alc) == "table"
        and type(_G.alc.json_encode) == "function"
        and type(_G.alc.json_decode) == "function"
    then
        return { encode = _G.alc.json_encode, decode = _G.alc.json_decode }
    end
    error("swarm_frame.artifact_store: requires _G.alc.json_* (algocline runtime) or swarm_frame.host injection", 2)
end

local function _json_encode(t) return _host().encode(t) end

-- ─── M.summarize — standalone pure helper ────────────────────────────────────
--
-- This function has ZERO import or runtime dependency on artifact_store or any
-- backend. It must remain callable without instantiating a store.
-- (crux-card §summarize as standalone pure export)

--- Produce a short summary string from payload.
-- @param payload  any Lua value
-- @param opts     table: { format="text"|"json", max_chars=number }
-- @return         string summary (truncated to max_chars if necessary)
function M.summarize(payload, opts)
    opts = opts or {}
    local fmt = opts.format or "text"
    local max_chars = opts.max_chars or 200

    local encoded
    if fmt == "text" then
        encoded = tostring(payload)
    elseif fmt == "json" then
        encoded = _json_encode(payload)
    else
        encoded = tostring(payload)
    end

    if #encoded <= max_chars then return encoded end
    return encoded:sub(1, max_chars)
end

-- ─── backend_artifact_memory ─────────────────────────────────────────────────
--
-- In-memory backend. Stores bytes (encoded strings) in a Lua table keyed by
-- rel_path. No format logic — bytes are accepted and returned verbatim.
-- (crux-card §source-agnostic backend interface)

--- Create an in-memory artifact backend.
-- @return  backend object with write/read/exists/delete methods
function M.backend_artifact_memory()
    local store = {}
    local backend = {}

    --- Write bytes to the in-memory store.
    -- @param rel_path  string key (relative path)
    -- @param bytes     string (encoded bytes, no format conversion here)
    function backend:write(rel_path, bytes) store[rel_path] = bytes end

    --- Read bytes from the in-memory store.
    -- @param rel_path  string key
    -- @return          string or nil
    function backend:read(rel_path) return store[rel_path] end

    --- Check if a key exists.
    -- @param rel_path  string key
    -- @return          boolean
    function backend:exists(rel_path) return store[rel_path] ~= nil end

    --- Delete an entry from the in-memory store.
    -- @param rel_path  string key
    function backend:delete(rel_path) store[rel_path] = nil end

    return backend
end

-- ─── backend_artifact_file ───────────────────────────────────────────────────
--
-- FS-backed backend. Stores bytes as files under task_dir.
-- Path logic is limited to: task_dir .. "/" .. rel_path (simple join).
-- No format conversion — bytes string is written as-is with "wb" mode.
-- (crux-card §source-agnostic backend interface)

--- POSIX shell-quote a path for use in os.execute.
local function _shell_quote(path) return "'" .. path:gsub("'", "'\\''") .. "'" end

--- Join task_dir and rel_path into an absolute path.
local function _abs_path(task_dir, rel_path) return task_dir .. "/" .. rel_path end

--- Ensure the parent directory of a path exists (mkdir -p).
-- @param abs  absolute file path
-- @return     true on success, nil+err on failure
local function _ensure_dir(abs)
    local dir = abs:match("^(.*)/[^/]+$") or "."
    local ok, _, code = os.execute("mkdir -p " .. _shell_quote(dir))
    if not ok then
        return nil, "swarm_frame.backend_artifact_file: mkdir -p failed (code=" .. tostring(code) .. ") for " .. dir
    end
    return true
end

--- Create a file-system artifact backend.
-- @param opts  table: { task_dir = string (required) }
-- @return      backend object with write/read/exists/delete methods
function M.backend_artifact_file(opts)
    opts = opts or {}
    local task_dir = opts.task_dir
    if not task_dir then error("swarm_frame.backend_artifact_file: opts.task_dir is required") end

    local backend = {}

    --- Write bytes to a file under task_dir/rel_path.
    -- @param rel_path  relative path string
    -- @param bytes     string (encoded bytes, no format conversion here)
    function backend:write(rel_path, bytes)
        local abs = _abs_path(task_dir, rel_path)
        local ok, err = _ensure_dir(abs)
        if not ok then error("swarm_frame.backend_artifact_file.write: " .. tostring(err)) end
        local f, ferr = io.open(abs, "wb")
        if not f then error("swarm_frame.backend_artifact_file.write: io.open failed: " .. tostring(ferr)) end
        local werr
        local wok = f:write(bytes)
        if not wok then werr = "write failed" end
        f:close()
        if not wok then error("swarm_frame.backend_artifact_file.write: " .. tostring(werr) .. " for " .. abs) end
    end

    --- Read bytes from a file under task_dir/rel_path.
    -- @param rel_path  relative path string
    -- @return          string or nil
    function backend:read(rel_path)
        local abs = _abs_path(task_dir, rel_path)
        local f = io.open(abs, "rb")
        if not f then return nil end
        local data = f:read("*a")
        f:close()
        return data
    end

    --- Check if a file exists under task_dir/rel_path.
    -- @param rel_path  relative path string
    -- @return          boolean
    function backend:exists(rel_path)
        local abs = _abs_path(task_dir, rel_path)
        local f = io.open(abs, "rb")
        if f then
            f:close()
            return true
        end
        return false
    end

    --- Delete a file under task_dir/rel_path.
    -- @param rel_path  relative path string
    function backend:delete(rel_path)
        local abs = _abs_path(task_dir, rel_path)
        os.remove(abs)
    end

    return backend
end

-- ─── artifact_store factory ──────────────────────────────────────────────────
--
-- Application-layer store that:
--   1. Validates the backend has the 4-method contract
--   2. Performs payload-to-bytes conversion (SOLE site — crux §payload-to-bytes)
--   3. Delegates raw bytes I/O to the backend

local _REQUIRED_BACKEND_METHODS = { "write", "read", "exists", "delete" }

--- Validate that a backend provides the required 4-method interface.
local function _validate_backend(backend)
    for _, method in ipairs(_REQUIRED_BACKEND_METHODS) do
        if type(backend[method]) ~= "function" then
            error("swarm_frame.artifact_store: backend missing method " .. method)
        end
    end
end

--- Create an artifact store wrapping a backend.
-- @param backend  object satisfying the 4-method contract
-- @return         store object with offload/read/exists/delete methods
function M.artifact_store(backend)
    _validate_backend(backend)

    local store = {}

    --- Persist a payload as an artifact.
    --
    -- This is the SOLE site of payload-to-bytes conversion.
    -- (crux-card §payload-to-bytes scoped to artifact_store)
    --
    -- @param payload  any Lua value
    -- @param opts     table: { name=string, task_dir=string (unused — backend owns path), format="text"|"json" }
    -- @return         rel_path string on success; nil, err_string on failure
    function store:offload(payload, opts)
        opts = opts or {}
        local fmt = opts.format or "text"
        local name = opts.name

        if not name then return nil, "swarm_frame.artifact_store.offload: opts.name is required" end

        -- payload-to-bytes conversion: ONLY here, never in any backend
        local bytes
        if fmt == "text" then
            bytes = tostring(payload)
        elseif fmt == "json" then
            bytes = _json_encode(payload)
        else
            error(
                "swarm_frame.artifact_store.offload: unsupported format "
                    .. tostring(fmt)
                    .. " (expected 'text' or 'json')"
            )
        end

        local rel_path = name
        local ok, err = pcall(function() backend:write(rel_path, bytes) end)
        if not ok then return nil, tostring(err) end
        return rel_path, nil
    end

    --- Read back the raw bytes for a previously offloaded artifact.
    -- @param rel_path  string
    -- @return          bytes string or nil
    function store:read(rel_path) return backend:read(rel_path) end

    --- Check whether an artifact exists.
    -- @param rel_path  string
    -- @return          boolean
    function store:exists(rel_path) return backend:exists(rel_path) end

    --- Delete an artifact.
    -- @param rel_path  string
    function store:delete(rel_path) backend:delete(rel_path) end

    return store
end

return M
