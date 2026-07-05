# Blueprint generators

`swarm_patterns` provides Blueprint generators that turn algocline's
proven strategy patterns into ready-to-run flow.ir + mlua-swarm-engine
Blueprints. Authoring stays in Lua (declarative data), execution moves
to the Rust engine.

## Common usage

```lua
local patterns = require("swarm_patterns")

-- 1. Call a generator with an opts table.
local blueprint = patterns.panel{ roles = {"advocate", "critic"} }

-- 2. `blueprint` is a plain Lua table (JSON-able), matching the mse
--    Blueprint wire schema (schema_version / id / flow / agents / origin
--    / metadata).
if alc and alc.json_encode then
  print(alc.json_encode(blueprint))
end

-- 3. Hand the JSON to mlua-swarm-engine (mse) for execution, e.g. via its
--    /v1/tasks endpoint, with `init_ctx = {task = "..."}`.
```

Every generator follows the same "opts in, Blueprint table out"
contract: `id`, `agent_kind`, `model`, `session_id`, and `spec` are
common options across all five generators.

## Available generators

### panel — multi-perspective deliberation with moderator synthesis

- source: `swarm_patterns.panel{roles?, id?, agent_kind?, model?, session_id?, spec?}`
- based on: algocline `panel` pkg
- shape: sequential N roles + moderator, all reading full ctx
- agents: N + 1
- externs required: none
- minimal example:

  ```lua
  local blueprint = patterns.panel{ roles = {"advocate", "critic", "pragmatist"} }
  ```

### reflect — self-critique refinement loop (Madaan et al. 2023)

- source: `swarm_patterns.reflect{max_rounds?, id?, agent_kind?, model?, session_id?, spec?}`
- based on: algocline `reflect` pkg (Self-Refine)
- shape: generate → {critic → reviser}* until convergence or max_rounds
- agents: 3 (generator, critic, reviser)
- externs required: none
- minimal example:

  ```lua
  local blueprint = patterns.reflect{ max_rounds = 3 }
  ```

### sc — self-consistency parallel sampling (Wang et al. 2022)

- source: `swarm_patterns.sc{n?, id?, agent_kind?, model?, session_id?, spec?}`
- based on: algocline `sc` pkg (Self-Consistency)
- shape: N independent reasoning paths (Fanout parallel) → judge vote
- agents: N + 1 (reasoners + judge)
- externs required: none
- minimal example:

  ```lua
  local blueprint = patterns.sc{ n = 5 }
  ```

### ucb — UCB1 bandit exploration

- source: `swarm_patterns.ucb{n?, rounds?, id?, agent_kind?, model?, session_id?, spec?}`
- based on: UCB1 multi-armed bandit hypothesis exploration
- shape: generate N hypotheses → {score all arms → refine the argmax arm}* rounds
- agents: N generators + 1 scorer + N refiners
- externs required: `ucb1` / `argmax_ucb` / `finalize_ranking` (register
  on the `TaskLaunchService` via `.with_externs(...)`)
- minimal example:

  ```lua
  local blueprint = patterns.ucb{ n = 3, rounds = 2 }
  ```

### moa — mixture-of-agents (Wang et al. 2024)

- source: `swarm_patterns.moa{n_layers?, proposers?, personas?, n_proposers?, id?, agent_kind?, model?, session_id?, spec?}`
- based on: algocline `moa` pkg (Mixture-of-Agents)
- shape: L layers × n proposers (Fanout parallel) → aggregator per layer
- agents: L × (n + 1)
- externs required: none (aggregation lives in the aggregator agent's
  system prompt — the Aggregate-and-Synthesize instruction from Wang
  2024 Table 1)
- paper anchor: Wang 2024 §3 defaults (`n_layers = 3`, `n_proposers = 6`);
  the caller MUST supply `proposers` (multi-model PATH, paper's main
  config) or `personas` (single-model rotation PATH, outside the paper's
  main config)
- minimal example:

  ```lua
  local blueprint = patterns.moa{
    personas = {"You are a math expert.", "You are a coder."},
  }
  ```

## References

- panel / reflect / sc / ucb / moa are each described in more detail in
  their generator function's ldoc comment inside
  `packages/swarm_patterns/init.lua`.
- `packages/swarm_blueprint/init.lua` is the pure Lua builder DSL
  (`bp.step` / `bp.seq` / `bp.fanout` / `bp.branch` / `bp.loop` /
  `bp.agent` / `bp.blueprint`) all five generators are built exclusively
  through.
