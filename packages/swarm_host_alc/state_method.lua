---@module 'swarm_host_alc.state_method'
-- Domain-aware state update verbs (1:1 absorb of swarm_state_method
-- v0.1.0, scope shrink to swarm_host_alc).
--
-- Composes the namespace-generic alc MCP layer (`alc.state.list / show /
-- reset / set_dispatched / delete_dispatched`) into domain verbs callable
-- via `alc_advice` without writing Lua on the spot.
--
-- Initial verb: `update_dispatch_record` — shallow-merge a patch into an
-- existing dispatch record's `data`. Reads the current record via
-- `alc.state.show`, merges top-level fields from `opts.update` into
-- `state.data`, and writes back via `alc.state.set_dispatched` (Phase B
-- explicit-namespace set).
--
-- The `opts.alc` injection seam follows the convention established by
-- `combinator_demo/init.lua`: production picks up `_G.alc`, tests pass
-- a mocked table.

-- alc_shapes is optional: used for type annotation stubs only.
local _S_ok, S = pcall(require, "alc_shapes")
local _T = (_S_ok and S) and S.T or {}

local M = {}
M.VERSION = "0.0.1-v3-p5"

M.meta = {
    name        = "swarm_host_alc.state_method",
    version     = M.VERSION,
    category    = "state_method",
    description = "Domain-aware state update verbs composing alc.state.* "
        .. "primitive (initial verb: update_dispatch_record).",
}

M.spec = {
    entries = {
        run = {
            -- placeholder for future spec wiring
        },
    },
}

-- ─── validators ─────────────────────────────────────────────────────

local function require_string(v, name, fn)
    if type(v) ~= "string" or v == "" then
        error("swarm_host_alc.state_method." .. fn .. ": " .. name
              .. " (non-empty string) required, got " .. type(v), 3)
    end
end

local function require_table(v, name, fn)
    if type(v) ~= "table" then
        error("swarm_host_alc.state_method." .. fn .. ": " .. name
              .. " (table) required, got " .. type(v), 3)
    end
end

local function require_alc_fn(alc, path, fn)
    local node = alc
    for segment in path:gmatch("[^.]+") do
        if type(node) ~= "table" then
            error("swarm_host_alc.state_method." .. fn .. ": alc." .. path
                  .. " required (alc table malformed)", 3)
        end
        node = node[segment]
    end
    if type(node) ~= "function" then
        error("swarm_host_alc.state_method." .. fn .. ": alc." .. path
              .. " (function) required", 3)
    end
    return node
end

-- ─── verb: update_dispatch_record ───────────────────────────────────

--- Decode a state value into a Lua table.
---
--- The Lua bridge `alc.state.show` returns a JSON-encoded string in
--- production (algocline ≥ v0.44.0); tests may inject a mock that
--- returns a table directly. Accept both, decode strings via
--- `alc.json_decode` when present.
local function ensure_state_table(value, alc, ns, key)
    if type(value) == "table" then return value end
    if type(value) == "string" then
        if type(alc.json_decode) ~= "function" then
            error("swarm_host_alc.state_method.update_dispatch_record: "
                  .. "alc.state.show returned a JSON string but "
                  .. "alc.json_decode is unavailable; cannot decode "
                  .. ns .. "/" .. key, 3)
        end
        local ok, parsed = pcall(alc.json_decode, value)
        if not ok or type(parsed) ~= "table" then
            error("swarm_host_alc.state_method.update_dispatch_record: "
                  .. "alc.json_decode failed for " .. ns .. "/" .. key
                  .. " (string: " .. string.sub(value, 1, 60) .. ")", 3)
        end
        return parsed
    end
    error("swarm_host_alc.state_method.update_dispatch_record: "
          .. "alc.state.show returned non-table for " .. ns .. "/" .. key
          .. " (got " .. type(value) .. ")", 3)
end

--- Shallow-merge a patch into an existing dispatch record's `data`.
---
--- @param opts {
---     namespace : string,    -- REQUIRED (state namespace, e.g. "orch")
---     key       : string,    -- REQUIRED (record key, e.g. task_id)
---     update    : table,     -- REQUIRED (top-level fields to merge into state.data)
---     alc       : table?,    -- defaults to _G.alc; requires .state.show / .state.set_dispatched
--- }
--- @return {
---     ok             : boolean,
---     namespace      : string,
---     key            : string,
---     updated_fields : string[],
--- }
local function run_update_dispatch_record(opts, alc)
    require_string(opts.namespace, "namespace", "update_dispatch_record")
    require_string(opts.key, "key", "update_dispatch_record")
    require_table(opts.update, "update", "update_dispatch_record")

    local show = require_alc_fn(alc, "state.show", "update_dispatch_record")
    local set_dispatched = require_alc_fn(alc, "state.set_dispatched",
        "update_dispatch_record")

    local cur = ensure_state_table(show(opts.namespace, opts.key),
        alc, opts.namespace, opts.key)

    if type(cur.data) ~= "table" then cur.data = {} end

    local updated_fields = {}
    for field, value in pairs(opts.update) do
        if type(field) ~= "string" then
            error("swarm_host_alc.state_method.update_dispatch_record: "
                  .. "opts.update keys must be strings, got " .. type(field), 3)
        end
        cur.data[field] = value
        table.insert(updated_fields, field)
    end
    table.sort(updated_fields)

    set_dispatched(opts.namespace, opts.key, cur)

    return {
        ok             = true,
        namespace      = opts.namespace,
        key            = opts.key,
        updated_fields = updated_fields,
    }
end

-- ─── entry point ────────────────────────────────────────────────────

--- Dispatch a domain verb against the state store.
function M.run(opts)
    if type(opts) ~= "table" then
        error("swarm_host_alc.state_method.run: opts table required", 2)
    end
    local action = opts.action
    if type(action) ~= "string" or action == "" then
        error("swarm_host_alc.state_method.run: opts.action (non-empty string) required", 2)
    end

    local alc = opts.alc or _G.alc
    if type(alc) ~= "table" then
        error("swarm_host_alc.state_method.run: alc (table) required "
              .. "(set _G.alc or pass opts.alc)", 2)
    end

    if action == "update_dispatch_record" then
        return run_update_dispatch_record(opts, alc)
    end

    error("swarm_host_alc.state_method.run: unknown action: " .. action, 2)
end

return M
