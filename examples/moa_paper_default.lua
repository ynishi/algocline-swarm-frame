--- Wang 2024 default: 3 layers × 6 proposers.
---
--- This example uses the paper's 6 open-source proposer model names
--- (Wang 2024 §3 main experiment) as caller-supplied proposers. Adjust to
--- the actual models available in your deployment — this pkg does not
--- hard-code them, the caller MUST supply `proposers` or `personas`.

local patterns = require("swarm_patterns")

local blueprint = patterns.moa({
    n_layers = 3, -- Wang §3 "We use 3 MoA layers"
    n_proposers = 6, -- Wang §3 main experiment uses 6 open-source proposers
    proposers = {
        { model = "qwen-1.5-110b-chat" },
        { model = "qwen-1.5-72b-chat" },
        { model = "wizardlm-8x22b" },
        { model = "llama-3-70b-instruct" },
        { model = "mixtral-8x22b-v0.1" },
        { model = "dbrx-instruct" },
    },
    id = "moa-wang-2024-default",
})

-- Hand `blueprint` to mse for execution (init_ctx = {task = "<query>"}).
if alc and alc.json_encode then
    print(alc.json_encode(blueprint))
end
