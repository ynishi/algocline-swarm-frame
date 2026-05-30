--- swarm_frame.normalize — entry-boundary type coercion primitive.
---
--- Frame peer of `swarm_frame.plain_state`. Provides single-field
--- coercers (`coerce_boolean` / `coerce_string` / `coerce_number` /
--- `coerce_table`) and a bulk normalizer (`normalize_ctx`) for ctx
--- shape enforcement at orchestrator entry points.
---
--- ## Why a primitive
---
--- mlua-probe / mlua VM decoders surface JSON `null` as a `lightuserdata`
--- sentinel (commit `a0abfdf` crash class in algocline-bundled-packages
--- history). Downstream code patterns like
---
---     if ctx.plan_path then io.open(ctx.plan_path) ... end
---
--- crash when `plan_path` is the sentinel rather than `nil`. Each orch
--- has historically hand-rolled a `type(v) == expected` guard at its
--- entry point (`coding_orch/init.lua:737-788` is the canonical surviving
--- instance).
---
--- This module consolidates that idiom into one place so all 13 orchs
--- in `agent-profiles/packages/*` can delegate without re-inlining.
--- The behaviour is byte-for-byte identical to `coding_orch._normalize
--- _ctx_fields`: required-field mismatch raises, optional-field
--- mismatch coerces to `nil`, required strings must be non-empty.
---
--- See `design/normalize-primitive.md` (2026-05-13) for the discard
--- verdict re-evaluation against `design/delegate-extraction.md §7.1` and the
--- Cat-A / Cat-B carve-out (this module is Cat-A only; Cat-B verdict
--- vocabulary parser lives in a separate follow-up).
---
--- ## Migration pattern (for a non-frame orch)
---
--- Before (inline `_normalize_ctx_fields`):
---
---     local _NORM_TYPES = { ["string"] = {...}, ... }
---     local function _normalize_ctx_fields(ctx, spec)
---         for field, tag in pairs(spec) do ... end
---     end
---     -- inside M.run:
---     _normalize_ctx_fields(ctx, { task = "string", ... })
---
--- After:
---
---     local normalize = require("swarm_frame.normalize")
---     -- inside M.run:
---     normalize.normalize_ctx(ctx, { task = "string", ... })
---
--- ## Contract
---
--- All coercers are pure read-only checks: input value passes through
--- if `type(v)` matches; otherwise `nil`. The bulk `normalize_ctx`
--- mutates its `ctx` argument in place (optional fields with
--- non-matching types are deleted; required fields raise) and returns
--- the same table for chaining.

local M = {}

M.VERSION = "0.8.0"

-- ── single-field coercers ──────────────────────────────────────────────
-- Each coercer returns v iff type(v) matches the expected Lua type,
-- else nil. mlua JSON null lightuserdata sentinels naturally coerce to
-- nil because their `type(v)` is "userdata", which never matches
-- boolean / string / number / table. Use the `coerce_boolean(v) or false`
-- idiom at call sites that need a strict boolean.

--- Coerce a value to boolean if it is one, else nil.
--- @param v any
--- @return boolean | nil
function M.coerce_boolean(v)
    if type(v) == "boolean" then return v end
    return nil
end

--- Coerce a value to string if it is one, else nil.
--- Empty strings pass through here; non-empty enforcement is the job
--- of `normalize_ctx` (required-field path).
--- @param v any
--- @return string | nil
function M.coerce_string(v)
    if type(v) == "string" then return v end
    return nil
end

--- Coerce a value to number if it is one, else nil.
--- @param v any
--- @return number | nil
function M.coerce_number(v)
    if type(v) == "number" then return v end
    return nil
end

--- Coerce a value to table if it is one, else nil.
--- @param v any
--- @return table | nil
function M.coerce_table(v)
    if type(v) == "table" then return v end
    return nil
end

-- ── bulk normalizer ────────────────────────────────────────────────────

local _NORM_TYPES = {
    ["string"] = { lua_type = "string", required = true, nonempty = true },
    ["string?"] = { lua_type = "string", required = false, nonempty = false },
    ["boolean"] = { lua_type = "boolean", required = true, nonempty = false },
    ["boolean?"] = { lua_type = "boolean", required = false, nonempty = false },
    ["number"] = { lua_type = "number", required = true, nonempty = false },
    ["number?"] = { lua_type = "number", required = false, nonempty = false },
    ["table"] = { lua_type = "table", required = true, nonempty = false },
    ["table?"] = { lua_type = "table", required = false, nonempty = false },
}

local _PREFIX = "swarm_frame.normalize_ctx: "

--- Apply a per-field type spec to `ctx`, in place.
---
--- For each `field = tag` in `spec`:
---   - if `ctx[field]` matches the tag's Lua type, leave it as-is
---     (non-empty enforcement applies to required-string fields);
---   - if it doesn't match and the tag is required, raise;
---   - if it doesn't match and the tag is optional ("?"), set
---     `ctx[field] = nil` (sentinel sanitize).
---
--- @param ctx table
--- @param spec table<string, string>  -- tag ∈ {"string","string?", ...}
--- @return table  -- same ctx, mutated in place
function M.normalize_ctx(ctx, spec)
    assert(type(ctx) == "table", _PREFIX .. "ctx must be a table (got " .. type(ctx) .. ")")
    assert(type(spec) == "table", _PREFIX .. "spec must be a table (got " .. type(spec) .. ")")
    for field, tag in pairs(spec) do
        local td = _NORM_TYPES[tag]
        assert(
            td ~= nil,
            _PREFIX .. "unknown ctx type tag '" .. tostring(tag) .. "' for field '" .. tostring(field) .. "'"
        )
        local v = ctx[field]
        if type(v) == td.lua_type then
            if td.nonempty and v == "" then
                error(_PREFIX .. "ctx." .. tostring(field) .. " must be a non-empty string", 0)
            end
        else
            if td.required then
                error(
                    _PREFIX .. "ctx." .. tostring(field) .. " must be " .. td.lua_type .. " (got " .. type(v) .. ")",
                    0
                )
            end
            ctx[field] = nil
        end
    end
    return ctx
end

return M
