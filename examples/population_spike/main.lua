-- examples/population_spike — N=3 variant generation loop demo.
--
-- Issue 1779687339-50091: Population primitive Example spike.
-- Drives swarm_population through a 3-generation loop using a
-- handwritten scalar fitness + naive jitter mutation.
--
-- Selection / mutation / fitness all live HERE (in the Example),
-- NOT in swarm_population (Pure & thin retention check — observation
-- point (c) of the issue). The inline `cohort_step` function is the
-- prototype that the future bundled #6 Cohort frame will absorb.
--
-- Observation evidence collected by running this file:
--   (a) parallel spawn:   swarm_frame.run_parallel not implemented in
--                         v0.6.0 — this example uses sequential :iter().
--                         Evidence for the spike report.
--   (b) JSON dumpability: snapshot() is called at the end and the shape
--                         is printed; downstream JSON round-trip can
--                         be wired via swarm_frame.state_new backend.
--   (c) Pure & thin:      verify by inspecting packages/swarm_population/
--                         — no fitness/selection/mutation code there.
--   (d) Cohort boundary:  `cohort_step` below is the extract candidate.
--
-- Run: lua examples/population_spike/main.lua

package.path = "./packages/?/init.lua;./packages/?.lua;" .. package.path

local sp = require("swarm_population")

local N, GENS = 3, 3
local TARGET = 0.7

math.randomseed(42)

-- ─── domain policy (caller-owned, NOT Frame) ──────────────────────────

local function fitness(agent)
    return 1.0 - math.abs(agent.temperature - TARGET)
end

local function mutate(agent)
    local delta = (math.random() - 0.5) * 0.2
    local t = agent.temperature + delta
    if t < 0 then t = 0 end
    if t > 1 then t = 1 end
    return { temperature = t, score = 0 }
end

-- One generation step: evaluate → pick champion → replace losers with
-- mutated champion. Pure caller-side policy; Population only exposes
-- mechanical iter/replace/get. This is the prototype for bundled #6.
local function cohort_step(pop, gen)
    local best_idx, best_score = 1, -math.huge
    for idx, agent in pop:iter() do
        agent.score = fitness(agent)
        if agent.score > best_score then
            best_idx, best_score = idx, agent.score
        end
    end

    print(string.format("=== gen %d (best slot=%d score=%.4f) ===", gen, best_idx, best_score))
    for idx, agent in pop:iter() do
        local marker = (idx == best_idx) and "  <-- champion" or ""
        print(string.format("  slot %d: temp=%.4f score=%.4f%s",
            idx, agent.temperature, agent.score, marker))
    end

    local champion = pop:get(best_idx)
    for idx, _ in pop:iter() do
        if idx ~= best_idx then
            pop:replace(idx, mutate(champion))
        end
    end
end

-- ─── spike main ──────────────────────────────────────────────────────

local pop = sp.new({ temperature = 0.5, score = 0 }, N)
assert(pop:size() == N, "size mismatch")

for gen = 1, GENS do
    cohort_step(pop, gen)
end

-- Observation (b): snapshot is plain-table, JSON-dumpable.
local snap = pop:snapshot()
assert(snap.n == N, "snapshot.n mismatch")
assert(type(snap.agents) == "table", "snapshot.agents must be table")
assert(snap.agents[1].temperature ~= nil, "agent[1].temperature missing")

print(string.format("snapshot.n=%d snapshot.agents[1].temperature=%.4f",
    snap.n, snap.agents[1].temperature))

-- Observation (b) continued: restore round-trip.
local rehydrated = sp.restore(snap)
assert(rehydrated:size() == N, "restore size mismatch")
assert(rehydrated:get(1).temperature == snap.agents[1].temperature,
    "restore temperature mismatch")

print("[OK] population_spike completed")
