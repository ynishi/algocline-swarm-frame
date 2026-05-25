-- examples/ga_spike — W11 Pure Genetic Algorithm via 4 Primitives.
--
-- umbrella 1779690943-76260 primitives-draft.md §9 (v) 2nd spike (A
-- candidate). Verifies the Pure Primitive set on the *evolutionary
-- algorithm* domain, orthogonal to W1 Conway (cellular automaton).
--
-- Composition (Pure names per primitives-draft.md §1 v1):
--   - P1 slot_table       : N=10 individuals, payload = {genome,
--                           fitness, state}
--   - P4 lineage          : parent->child edge graph + generation tag
--   - Q1 mutation_op      : (lineage subordinate) Gaussian-ish jitter
--                           on genome scalar
--   - P7 transition_rules : selection state machine (active ->
--                           elite / eliminated)
--
-- Problem: maximize fitness(genome) = 1 - |genome - TARGET| with
-- genome in [0, 1]. Trivial unimodal landscape; the point of the spike
-- is not the optimization but verifying that the 4 primitives compose
-- without domain leak.
--
-- Run: lua examples/ga_spike/main.lua

package.path = "./packages/?/init.lua;./packages/?.lua;" .. package.path

local st = require("slot_table")
local ln = require("lineage")
local tr = require("transition_rules")

local N, GENS = 10, 8
local TARGET = 0.7
local ELITE = 3

math.randomseed(2026)

-- ─── P4 lineage with Q1 mutation_op (subordinate) ────────────────────
local lineage = ln.new()
lineage:set_mutation_op(function(parent_p)
    local g = parent_p.genome + (math.random() - 0.5) * 0.2
    if g < 0 then g = 0 end
    if g > 1 then g = 1 end
    return { genome = g, fitness = 0, state = "active" }
end)

-- ─── P7 selection state machine ──────────────────────────────────────
-- active -> elite (top-K by fitness, marked via ctx.is_elite)
-- active -> eliminated (otherwise; fallback rule)
-- Note: elite/eliminated states persist for the gen but each new gen
-- resets payloads via lineage:beget or stays in elite seat.
local rules = tr.new()
rules:add("active", "elite", function(_, ctx) return ctx.is_elite end)
rules:add("active", "eliminated", function() return true end)

-- ─── P1 N individuals ────────────────────────────────────────────────
local pop = st.new(N, function()
    return { genome = math.random(), fitness = 0, state = "active" }
end)

local function fitness(p) return 1.0 - math.abs(p.genome - TARGET) end

local function eval_all()
    for _, p in pop:iter() do p.fitness = fitness(p) end
end

local function summary(gen)
    local best, mean = -math.huge, 0
    for _, p in pop:iter() do
        if p.fitness > best then best = p.fitness end
        mean = mean + p.fitness
    end
    return string.format("gen %d: best=%.4f mean=%.4f", gen, best, mean / N)
end

-- ─── gen 0: evaluate initial random population ───────────────────────
eval_all()
print(summary(0))

-- ─── generation loop ─────────────────────────────────────────────────
for gen = 1, GENS do
    -- top-K elite selection (by fitness)
    local order = {}
    for i, p in pop:iter() do order[#order + 1] = { i = i, f = p.fitness } end
    table.sort(order, function(a, b) return a.f > b.f end)
    local elite_set, elite_list = {}, {}
    for k = 1, ELITE do
        elite_set[order[k].i] = true
        table.insert(elite_list, order[k].i)
    end

    -- P7 apply: state -> elite / eliminated
    -- payload state is reset to "active" before applying so the rules
    -- fire freshly each gen (P7 spec: first-match-wins on from_state).
    for i, p in pop:iter() do
        local reset = {}
        for k, v in pairs(p) do reset[k] = v end
        reset.state = "active"
        pop:set(i, rules:apply(reset, { is_elite = elite_set[i] }))
    end

    -- P4 beget: eliminated slots are replaced by elite parent's child
    -- (mutation_op applied automatically inside lineage:beget).
    for i, p in pop:iter() do
        if p.state == "eliminated" then
            local parent_idx = elite_list[math.random(1, ELITE)]
            local parent_p = pop:get(parent_idx)
            local child_p = lineage:beget(parent_idx, i, gen, parent_p)
            pop:set(i, child_p)
        end
    end

    -- evaluate new generation
    eval_all()
    print(summary(gen))
end

-- ─── spike asserts ───────────────────────────────────────────────────
assert(pop:size() == N, "size mismatch")

local final_best = -math.huge
for _, p in pop:iter() do
    if p.fitness > final_best then final_best = p.fitness end
end
-- Loose convergence bound: 8 gens with ±0.1 jitter + 3 elites on a
-- unimodal landscape should comfortably beat 0.85.
assert(final_best > 0.85,
    string.format("GA failed to converge: best=%.4f after %d gens (TARGET=%.2f)",
        final_best, GENS, TARGET))

-- P4 lineage verify
local edge_count = lineage:size()
assert(edge_count > 0, "lineage edges empty (no eliminations occurred?)")

-- Each non-elite slot per gen produces 1 edge. Expected lower bound:
-- GENS * (N - ELITE) = 8 * 7 = 56 if all gens behaved nominally.
-- Allow some slack for variance though math.randomseed pins it.
assert(edge_count >= GENS * (N - ELITE) // 2,
    string.format("lineage edge_count=%d unexpectedly low", edge_count))

-- parent pointer integrity sample.
-- NOTE: slot recycling — same child_slot may be re-beget across gens
-- (eliminated slot 5 at gen 1 may again be eliminated at gen 3).
-- edges() is append-only history; parent() / generation() reflect the
-- LATEST beget on that slot. Verify on the latest edge for state
-- consistency. (See lineage init.lua docstring.)
local edges = lineage:edges()
local sample = edges[#edges]
assert(lineage:parent(sample.child) == sample.parent,
    string.format("latest parent pointer mismatch: parent(%d)=%s vs sample.parent=%d",
        sample.child, tostring(lineage:parent(sample.child)), sample.parent))
assert(lineage:generation(sample.child) == sample.gen,
    string.format("latest generation tag mismatch: gen(%d)=%d vs sample.gen=%d",
        sample.child, lineage:generation(sample.child), sample.gen))

-- children list integrity: latest sample.parent's history should
-- include sample.child (append-only children history per parent).
local kids = lineage:children(sample.parent)
local found = false
for _, c in ipairs(kids) do
    if c == sample.child then found = true; break end
end
assert(found,
    string.format("children(%d) history missing sample.child=%d",
        sample.parent, sample.child))

print(string.format(
    "[OK] ga_spike completed (gens=%d N=%d final_best=%.4f edges=%d)",
    GENS, N, final_best, edge_count))
