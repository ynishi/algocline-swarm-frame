---@module 'swarm_frame.v3.engine.plugin_chain'
-- before / around / after / finalize 4-stage chain composition.
--
-- A plugin is a plain Lua table with any subset of these optional
-- hooks. The chain wraps the real dispatcher so that:
--
--   before(ref, input, ctx)        -- outer-to-inner, no return value used
--   around(next, ref, input, ctx)  -- like Rack / Plug middleware; must
--                                  -- call next(ref, input, ctx) to
--                                  -- proceed (may also short-circuit)
--   after(ref, input, ctx, resp)   -- inner-to-outer, no return value used
--   finalize(result)               -- outermost first, runs on swarm.run()
--                                  -- Result before returning to caller
--
-- Plugin shape:
--   { name = string?, before? = fn, around? = fn, after? = fn,
--     finalize? = fn }
--
-- The order of plugins as passed by the caller defines the "outer-to-
-- inner" stack: plugins[1] is the outermost wrapper.
--
-- This module returns IR-pure data: wrap_dispatch produces a single
-- function, run_finalize folds the result through finalize hooks.

local M = {}
M.VERSION = "0.0.1-v3-p3"

local function _is_callable(v)
    return type(v) == "function"
end

--- Wrap a dispatcher with the plugin chain. Returns a new dispatcher
--- with the same `(ref, input, ctx?) -> response` signature.
---
--- Composition order:
---   plugins[1].around(next=plugins[2].around(..., real_dispatch))
---
--- before / after are injected inside each plugin's own frame so they
--- run in the conventional outer-to-inner / inner-to-outer order.
function M.wrap_dispatch(plugins, dispatch)
    if type(dispatch) ~= "function" then
        error("plugin_chain.wrap_dispatch: dispatch must be a function", 2)
    end
    plugins = plugins or {}
    if #plugins == 0 then return dispatch end

    -- Build inner-out: start from the real dispatch, wrap with each
    -- plugin from last to first so plugins[1] ends up outermost.
    local current = dispatch
    for i = #plugins, 1, -1 do
        local p = plugins[i]
        local next_fn = current
        current = function(ref, input, ctx)
            if _is_callable(p.before) then p.before(ref, input, ctx) end
            local response
            if _is_callable(p.around) then
                response = p.around(next_fn, ref, input, ctx)
            else
                response = next_fn(ref, input, ctx)
            end
            if _is_callable(p.after) then p.after(ref, input, ctx, response) end
            return response
        end
    end
    return current
end

--- Fold a Result through plugin.finalize hooks. Outermost first
--- (matches around-style ordering: caller's [1] runs first / last
--- depending on whether you think of it as outer or last wrapped).
--- For finalize, semantics is "outermost runs after innermost" so we
--- iterate plugins in reverse.
function M.run_finalize(plugins, result)
    plugins = plugins or {}
    for i = #plugins, 1, -1 do
        local p = plugins[i]
        if _is_callable(p.finalize) then
            local new_result = p.finalize(result)
            -- Plugins may return a transformed result, or nil to keep
            -- the current one (immutable-by-default semantics).
            if new_result ~= nil then result = new_result end
        end
    end
    return result
end

return M
