---@module 'swarm_frame.v3.engine.observer'
-- Observer multiplexer — fans events to N registered observer fns.
--
-- Observers are plain functions `(event: EventPayload) -> nil` per
-- /contract/observer_hook. The engine emits events at step boundaries
-- (start / end / error); observers may log / store / metric them.
--
-- P3 minimal: stateless fan-out. Future phases may add filtering,
-- buffering, async dispatch.

local observer_hook = require("swarm_frame.v3.contract.observer_hook")

local M = {}
M.VERSION = "0.0.1-v3-p3"

--- new(observers) -> emitter fn
--- `emitter(event)` calls each observer in registration order. An
--- observer that raises does NOT block subsequent observers — the
--- error is captured and re-emitted as a "weird-observer" warning to
--- stderr (best-effort, never fatal).
function M.new(observers)
    observers = observers or {}
    -- Validate up-front so plumbing errors fail loudly at run() time.
    for i, fn in ipairs(observers) do
        local ok, reason = observer_hook.check_call(fn)
        if not ok then
            error("observer[" .. i .. "]: " .. reason, 2)
        end
    end
    return function(event)
        for _, fn in ipairs(observers) do
            local ok, err = pcall(fn, event)
            if not ok then
                io.stderr:write("[swarm.observer] handler raised: "
                    .. tostring(err) .. "\n")
            end
        end
    end
end

--- A no-op emitter — used as the default when no observers are
--- registered. Skips the for-loop entirely.
function M.noop() end

return M
