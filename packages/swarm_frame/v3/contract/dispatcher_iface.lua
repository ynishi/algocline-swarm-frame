---@module 'swarm_frame.v3.contract.dispatcher_iface'
-- Dispatcher iface — `dispatch(ref, input) -> response`.
--
-- Schema-as-data form per V3 §4.3.4 (ε採用: alc_shapes runtime validate +
-- alc_shapes.luacats codegen 補助). LuaCATS docstring is codegen'd via
-- `alc_shapes.luacats.gen(schema, prefix)` — hand-written annotations are
-- a fallback, the schema is the SoT.
--
-- The dispatcher is a Lua function, not a data table. alc_shapes cannot
-- shape-check a function, so we expose:
--   * M.DispatchInput / M.DispatchResponse — I/O value shapes
--   * M.check_call(fn) — light callable probe for the function itself

local T = require("alc_shapes.t")
local M = {}
M.VERSION = "0.0.1-v3-p4"

--- Input shape passed by the runtime to the dispatcher.
--- per R8 land (V3 §5.3.1): `input` MAY be nil when step.in_ is omitted.
M.DispatchInput = T.shape({
    ref   = T.string:describe("opaque agent / pkg ref string"),
    input = T.any:is_optional():describe(
        "dispatcher input value; nil per R8 land when step.in_ is omitted"),
}, { open = false })

--- Response shape returned by the dispatcher. Open by default — host
--- adapters may attach trace / metric / debug fields without
--- invalidating downstream consumers.
M.DispatchResponse = T.shape({}, { open = true })

--- Light contract probe — verifies the dispatcher is callable.
--- Returns `true` or `(nil, reason)`.
function M.check_call(fn)
    if type(fn) ~= "function" then
        return false, "dispatcher must be a function (ref, input) -> response"
    end
    return true
end

return M
