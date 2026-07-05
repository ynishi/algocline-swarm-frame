--- Minimal example: run a panel deliberation Blueprint.
---
--- This script builds the Blueprint via swarm_patterns.panel and prints
--- the resulting JSON to stdout. To actually execute, hand the JSON to
--- mlua-swarm-engine (mse) via its /v1/tasks endpoint, with
--- init_ctx = {task = "<topic>"}.

local patterns = require("swarm_patterns")

local blueprint = patterns.panel({
    roles = { "advocate", "critic", "pragmatist" },
    id = "panel-example-v1",
    model = "haiku",
})

-- The blueprint is a plain Lua table matching the mse Blueprint schema.
-- Serialize it with your JSON encoder of choice.
if alc and alc.json_encode then
    print(alc.json_encode(blueprint))
else
    -- Fallback dump for standalone lua runs (no algocline host available).
    local function dump(t, indent)
        indent = indent or ""
        if type(t) ~= "table" then
            print(indent .. tostring(t))
            return
        end
        for k, v in pairs(t) do
            if type(v) == "table" then
                print(indent .. tostring(k) .. ":")
                dump(v, indent .. "  ")
            else
                print(indent .. tostring(k) .. " = " .. tostring(v))
            end
        end
    end
    dump(blueprint)
end
