-- examples/pd_spike — W15 iterated Prisoner's Dilemma via 5 Primitives.
--
-- umbrella 1779690943-76260 primitives-draft.md §9 4th spike — verifies
-- new P2 scalar_pool Primitive on the game-theory / social domain. This
-- closes Primitive verify (P1 P2 P3 P4 P6 P7 + Q1 subordinate; P5
-- knowledge_channel deferred to LLM-bearing future spike).
--
-- Composition (Pure names per primitives-draft.md §1 v1):
--   - P1 slot_table       : N=8 players, payload = {coop_rate, state}
--   - P2 scalar_pool (NEW): cumulative tournament payoff per player
--                           with inter-gen decay (50% carry-over)
--   - P4 lineage          : parent->child edge graph for evolved players
--   - Q1 mutation_op (sub): cooperation rate jitter ±0.1
--   - P7 transition_rules : active -> elite / eliminated per gen
--
-- Tournament: round-robin pairing, each pair plays ROUNDS_PER_GEN rounds.
-- Payoff matrix (standard PD): CC=(3,3), CD=(0,5), DC=(5,0), DD=(1,1).
-- Mixed strategy: each player has cooperation_rate in [0,1]; per round
-- the move is sampled (cooperate with prob coop_rate).
--
-- Run: lua examples/pd_spike/main.lua

package.path = "./packages/?/init.lua;./packages/?.lua;" .. package.path

local st = require("slot_table")
local sp = require("scalar_pool")
local ln = require("lineage")
local tr = require("transition_rules")

local N = 8
local GENS = 5
local ROUNDS_PER_GEN = 10
local ELITE = 3
local DECAY = 0.5      -- 50% carry-over of payoff into next generation

math.randomseed(2026)

-- Payoff matrix
local function payoff(c1, c2)
    if c1 and c2 then return 3, 3 end
    if c1 and not c2 then return 0, 5 end
    if not c1 and c2 then return 5, 0 end
    return 1, 1
end

local function choose(rate) return math.random() < rate end

-- P1
local pop = st.new(N, function()
    return { coop_rate = math.random(), state = "active" }
end)

-- P2 scalar_pool
local pool = sp.new()

-- P4 + Q1 mutation_op (subordinate)
local lineage = ln.new()
lineage:set_mutation_op(function(parent_p)
    local r = parent_p.coop_rate + (math.random() - 0.5) * 0.2
    if r < 0 then r = 0 end
    if r > 1 then r = 1 end
    return { coop_rate = r, state = "active" }
end)

-- P7 selection
local rules = tr.new()
rules:add("active", "elite", function(_, ctx) return ctx.is_elite end)
rules:add("active", "eliminated", function() return true end)

local function copy_payload(p)
    local c = {}
    for k, v in pairs(p) do c[k] = v end
    return c
end

for gen = 1, GENS do
    -- round-robin tournament
    for _ = 1, ROUNDS_PER_GEN do
        for i = 1, N do
            for j = i + 1, N do
                local pi, pj = pop:get(i), pop:get(j)
                if pi.state == "active" and pj.state == "active" then
                    local ci, cj = choose(pi.coop_rate), choose(pj.coop_rate)
                    local payoff_i, payoff_j = payoff(ci, cj)
                    pool:credit(i, "tournament", payoff_i)
                    pool:credit(j, "tournament", payoff_j)
                end
            end
        end
    end

    -- selection by cumulative payoff
    local order = {}
    for i = 1, N do
        order[#order + 1] = { i = i, f = pool:total(i) }
    end
    table.sort(order, function(a, b) return a.f > b.f end)
    local elite_set, elite_list = {}, {}
    for k = 1, ELITE do
        elite_set[order[k].i] = true
        table.insert(elite_list, order[k].i)
    end

    local mean = 0
    for _, o in ipairs(order) do mean = mean + o.f end
    mean = mean / N
    local mean_coop = 0
    for _, p in pop:iter() do mean_coop = mean_coop + p.coop_rate end
    mean_coop = mean_coop / N
    print(string.format(
        "gen %d: best=%.1f mean_payoff=%.1f mean_coop=%.3f",
        gen, order[1].f, mean, mean_coop))

    -- P7 apply
    for i, p in pop:iter() do
        local reset = copy_payload(p)
        reset.state = "active"
        pop:set(i, rules:apply(reset, { is_elite = elite_set[i] }))
    end

    -- P4 beget for eliminated + P2 reset (slot reuse semantics)
    for i, p in pop:iter() do
        if p.state == "eliminated" then
            local parent_idx = elite_list[math.random(1, ELITE)]
            local parent_p = pop:get(parent_idx)
            local child_p = lineage:beget(parent_idx, i, gen, parent_p)
            pop:set(i, child_p)
            pool:reset(i)  -- new lifetime, payoff history cleared
        end
    end

    -- P2 inter-gen decay (50% carry-over) — keeps elite scores partial
    -- so freshly begotten slots can catch up over a couple of gens
    pool:apply_decay(DECAY)
end

-- ─── spike asserts ───────────────────────────────────────────────────
assert(pop:size() == N, "size mismatch")

-- P2 was exercised: pool must have non-zero entries somewhere
local total_pool = 0
local n_slots_with_payoff = 0
for _, slot in ipairs(pool:slots()) do
    local t = pool:total(slot)
    total_pool = total_pool + t
    if t > 0 then n_slots_with_payoff = n_slots_with_payoff + 1 end
end
assert(total_pool > 0,
    "scalar_pool empty — tournament payoffs did not accumulate")
assert(n_slots_with_payoff >= ELITE,
    string.format("only %d slots have payoff (expected >= %d elites)",
        n_slots_with_payoff, ELITE))

-- P2 by_source: only "tournament" was used; verify it equals total per slot
for _, slot in ipairs(pool:slots()) do
    local by_src = pool:by_source(slot, "tournament")
    assert(math.abs(by_src - pool:total(slot)) < 1e-9,
        string.format("by_source/total mismatch on slot %d: %s vs %s",
            slot, by_src, pool:total(slot)))
end

-- P4 lineage was exercised
assert(lineage:size() > 0, "lineage edges empty")

-- final summary
local mean_coop = 0
for _, p in pop:iter() do mean_coop = mean_coop + p.coop_rate end
mean_coop = mean_coop / N

print(string.format(
    "[OK] pd_spike completed (gens=%d N=%d rounds=%d edges=%d pool_total=%.1f mean_coop=%.3f)",
    GENS, N, ROUNDS_PER_GEN, lineage:size(), total_pool, mean_coop))
