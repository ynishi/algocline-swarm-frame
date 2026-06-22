-- v3_smoke standalone runner — bypasses unrelated pre-existing failures
-- in resolve_task_dir_spec.lua (HEAD baseline at 39a8a52). Runs only the
-- V3 P1 vertical slice for fast architecture validation.

package.path = "./packages/?/init.lua;./packages/?.lua;"
    .. "./tests/vendor/?.lua;"
    .. (os.getenv("HOME") or "")
    .. "/.algocline/packages/?/init.lua;"
    .. (os.getenv("HOME") or "")
    .. "/.algocline/packages/?.lua;"
    .. package.path

-- _G.alc bootstrap (flow.ir persistence requires _G.alc.json_*).
do
    local ok_dkjson, dkjson = pcall(require, "dkjson")
    local encode, decode
    if ok_dkjson then
        encode = dkjson.encode
        decode = dkjson.decode
    else
        encode = function(t) return tostring(t) end
        decode = function(s) return s end
    end
    _G.alc = _G.alc or {}
    _G.alc.json_encode = _G.alc.json_encode or encode
    _G.alc.json_decode = _G.alc.json_decode or decode
    _G.alc.log = _G.alc.log or function() end
end

local lust = require("lust")
dofile("packages/swarm_frame/spec/v3_smoke_spec.lua")
dofile("packages/swarm_frame/spec/v3_primitive_spec.lua")
dofile("packages/swarm_frame/spec/v3_contract_spec.lua")
dofile("packages/swarm_frame/spec/v3_composite_spec.lua")
dofile("packages/swarm_frame/spec/v3_engine_spec.lua")
dofile("packages/swarm_frame/spec/v3_state_spec.lua")
dofile("packages/swarm_host_alc/spec/state_backend_spec.lua")
dofile("packages/swarm_host_alc/spec/artifact_backend_spec.lua")
dofile("packages/swarm_host_alc/spec/state_method_spec.lua")
dofile("packages/swarm_host_alc/spec/prompt_builder_spec.lua")
dofile("packages/swarm_host_alc/spec/check_mode_spec.lua")
dofile("packages/swarm_host_alc/spec/safeguard_spec.lua")
dofile("packages/swarm_frame/spec/v3_contract_callable_spec.lua")
dofile("packages/swarm_host_alc/spec/dispatcher_spec.lua")
dofile("packages/swarm_host_alc/spec/dispatcher_core_dispatch_spec.lua")
dofile("packages/swarm_host_alc/spec/dispatcher_chain_spec.lua")
dofile("packages/swarm_host_alc/spec/dispatcher_finalize_spec.lua")
dofile("packages/swarm_host_alc/spec/dispatcher_call_spec.lua")
dofile("packages/swarm_host_alc/spec/dispatcher_integration_spec.lua")

local r = lust.get_results()
print()
print(string.format("=== Results: %d passed, %d failed (total %d) ===",
    r.passed, r.failed, r.total))
if r.failed > 0 then os.exit(1) end
