--- swarm_population — Population primitive (spike).
---
--- N-body variant container with 4 mechanical operations:
---   new / iter / replace / snapshot
---
--- Pure & thin: NO selection / mutation / fitness / crossover policy.
--- Those are domain logic and live in the caller (Example / Cohort runner).
--- Frame retain check is observation point (c) of issue 1779687339-50091.
---
--- Status: v0.1.0-spike — Example-first probe to validate the Umbrella
--- layer assignment (Population belongs in swarm-frame vs bundled).
--- API surface is provisional and may be reshaped after spike conclusion.

local M = {}

M.VERSION = "0.1.0-spike"
M.meta = {
    name = "swarm_population",
    version = M.VERSION,
    description = "N-body variant container; mechanical 4-op surface.",
}

local Population = {}
Population.__index = Population

--- Build a Population of `n` agents from a per-individual `spec` template.
--- Each agent starts as a shallow copy of `spec` plus a `_slot` index.
--- @param spec table per-individual template (shallow-copied per slot)
--- @param n integer positive integer; number of variants
--- @return Population
function M.new(spec, n)
    if type(spec) ~= "table" then
        error("swarm_population.new: spec must be table (got " .. type(spec) .. ")")
    end
    if type(n) ~= "number" or n < 1 or math.floor(n) ~= n then
        error("swarm_population.new: n must be positive integer (got " .. tostring(n) .. ")")
    end
    local agents = {}
    for i = 1, n do
        local agent = {}
        for k, v in pairs(spec) do agent[k] = v end
        agent._slot = i
        agents[i] = agent
    end
    return setmetatable({ _agents = agents, _n = n }, Population)
end

--- Population size (number of slots).
function Population:size() return self._n end

--- Indexed accessor. Returns the agent table by 1-based slot index.
function Population:get(idx)
    if idx < 1 or idx > self._n then
        error("swarm_population.get: idx out of range (got " .. tostring(idx) .. ", size=" .. self._n .. ")")
    end
    return self._agents[idx]
end

--- Stateless iterator over (idx, agent) pairs.
--- Mechanical mapping only — no ordering policy, no filtering.
function Population:iter()
    local i = 0
    local n = self._n
    return function()
        i = i + 1
        if i > n then return nil end
        return i, self._agents[i]
    end
end

--- Slot-unit replacement. Replaces the agent at `idx` with `agent`.
--- No identity check, no diff — the caller owns succession policy.
function Population:replace(idx, agent)
    if idx < 1 or idx > self._n then
        error("swarm_population.replace: idx out of range (got " .. tostring(idx) .. ", size=" .. self._n .. ")")
    end
    if type(agent) ~= "table" then
        error("swarm_population.replace: agent must be table (got " .. type(agent) .. ")")
    end
    self._agents[idx] = agent
end

--- Plain-table dump suitable for JSON round-trip via swarm_frame state
--- backends. Each agent is shallow-copied; the caller is responsible
--- for keeping agent values JSON-safe (no functions / userdata).
function Population:snapshot()
    local out = { n = self._n, agents = {} }
    for i = 1, self._n do
        local copy = {}
        for k, v in pairs(self._agents[i]) do copy[k] = v end
        out.agents[i] = copy
    end
    return out
end

--- Rehydrate a Population from a snapshot produced by `:snapshot()`.
--- Verifies shape and copies agent tables.
function M.restore(snap)
    if type(snap) ~= "table" or type(snap.n) ~= "number" or type(snap.agents) ~= "table" then
        error("swarm_population.restore: invalid snapshot shape")
    end
    local agents = {}
    for i = 1, snap.n do
        local src = snap.agents[i]
        if type(src) ~= "table" then
            error("swarm_population.restore: snapshot.agents[" .. i .. "] must be table")
        end
        local copy = {}
        for k, v in pairs(src) do copy[k] = v end
        agents[i] = copy
    end
    return setmetatable({ _agents = agents, _n = snap.n }, Population)
end

M.Population = Population
return M
