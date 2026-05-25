-- examples/arena_spike — W4 Arena (reduced) via 6 Primitives.
--
-- umbrella 1779690943-76260 primitives-draft.md §9 5th spike — verifies
-- new P5 knowledge_channel Primitive (last un-verified primitive) plus
-- P6 broadcast_bus on a different aggregation form (plurality vote)
-- than Conway (8-neighbor sum). Closes Primitive verify 7/7 + Q1 sub.
--
-- Composition (Pure names per primitives-draft.md §1 v1):
--   - P1 slot_table         : N=6 agents, payload = {boldness, finesse,
--                             harmony, record, state}
--   - P2 scalar_pool        : per-gen vote tally accumulator
--   - P4 lineage            : parent->child edge graph
--   - Q1 mutation_op (sub)  : strategy vector ±0.1 jitter
--   - P5 knowledge_channel  : strategy_record (wins/losses/top_styles)
--                             reshape on inheritance
--   - P6 broadcast_bus      : voters publish best candidate; aggregate
--                             into per-candidate vote_count (plurality)
--   - P7 transition_rules   : active -> elite / eliminated
--
-- Domain: each agent has a 3-axis strategy vector. Each round every
-- active agent votes for the (non-self) candidate whose vector is
-- closest to its own (homophily semantic). Top-K by total vote
-- become elite; eliminated slots are begotten from a random elite
-- via lineage + mutation, and inherit a TRANSFORMED strategy_record
-- via knowledge_channel.
--
-- Run: lua examples/arena_spike/main.lua

package.path = "./packages/?/init.lua;./packages/?.lua;" .. package.path

local st = require("slot_table")
local sp = require("scalar_pool")
local ln = require("lineage")
local tr = require("transition_rules")
local bb = require("broadcast_bus")
local kc = require("knowledge_channel")

local N = 6
local GENS = 4
local ROUNDS_PER_GEN = 3
local ELITE = 3

math.randomseed(2026)

-- P1
local pop = st.new(N, function()
    return {
        boldness = math.random(),
        finesse = math.random(),
        harmony = math.random(),
        record = { wins = 0, losses = 0, top_styles = {}, gen_born = 0 },
        state = "active",
    }
end)

-- P2 scalar_pool (vote tally)
local pool = sp.new()

-- P4 + Q1 mutation_op (vector jitter)
local function jitter(v)
    local r = v + (math.random() - 0.5) * 0.2
    if r < 0 then r = 0 end
    if r > 1 then r = 1 end
    return r
end

local lineage = ln.new()
lineage:set_mutation_op(function(parent_p)
    return {
        boldness = jitter(parent_p.boldness),
        finesse = jitter(parent_p.finesse),
        harmony = jitter(parent_p.harmony),
        record = nil,  -- filled by P5 transform after beget
        state = "active",
    }
end)

-- P5 knowledge_channel: transform parent's record for successor.
-- Schema reshape: reset wins/losses to 0, inherit top_styles (string
-- list), tag ancestor_wins, stamp gen_born. This is the kind of
-- structural payload transform that distinguishes P5 from Q1.
local k_channel = kc.new()
k_channel:set_transform(function(parent_record, ctx)
    local inherited_styles = {}
    for _, s in ipairs(parent_record.top_styles or {}) do
        inherited_styles[#inherited_styles + 1] = s
    end
    return {
        wins = 0,
        losses = 0,
        top_styles = inherited_styles,
        ancestor_wins = parent_record.wins,
        gen_born = (ctx and ctx.gen) or 0,
    }
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

local function similarity(a, b)
    -- homophily: closer vectors -> higher voter-candidate fit
    return 1.0 - (math.abs(a.boldness - b.boldness)
        + math.abs(a.finesse - b.finesse)
        + math.abs(a.harmony - b.harmony)) / 3.0
end

for gen = 1, GENS do
    -- ROUNDS_PER_GEN tournament rounds, each builds a fresh bus
    for _ = 1, ROUNDS_PER_GEN do
        local bus = bb.new()

        -- voter -> publish vote for best non-self candidate
        for i, voter in pop:iter() do
            if voter.state == "active" then
                local best_j, best_s = nil, -math.huge
                for j, cand in pop:iter() do
                    if j ~= i and cand.state == "active" then
                        local s = similarity(voter, cand) + (math.random() - 0.5) * 0.05
                        if s > best_s then best_j, best_s = j, s end
                    end
                end
                if best_j then bus:publish(i, best_j) end
            end
        end

        -- P6 aggregation per candidate: count "votes addressed to j"
        for j = 1, N do
            if pop:get(j).state == "active" then
                local votes = bus:aggregate_for(
                    j,
                    function(src) return src ~= j end,  -- exclude self
                    function(msgs)
                        local count = 0
                        for _, m in ipairs(msgs) do
                            if m == j then count = count + 1 end
                        end
                        return count
                    end
                )
                pool:credit(j, "vote", votes)
            end
        end
    end

    -- elite selection by total votes
    local order = {}
    for i = 1, N do order[#order + 1] = { i = i, f = pool:total(i) } end
    table.sort(order, function(a, b) return a.f > b.f end)
    local elite_set, elite_list = {}, {}
    for k = 1, ELITE do
        elite_set[order[k].i] = true
        table.insert(elite_list, order[k].i)
    end

    -- update strategy_record (wins / losses / top_styles)
    for i = 1, N do
        local p = pop:get(i)
        if elite_set[i] then
            p.record.wins = p.record.wins + 1
            -- biggest axis becomes the recorded "top style"
            local biggest, biggest_axis = p.boldness, "boldness"
            if p.finesse > biggest then biggest, biggest_axis = p.finesse, "finesse" end
            if p.harmony > biggest then biggest, biggest_axis = p.harmony, "harmony" end
            table.insert(p.record.top_styles, biggest_axis)
        else
            p.record.losses = p.record.losses + 1
        end
    end

    local mean = 0
    for _, o in ipairs(order) do mean = mean + o.f end
    mean = mean / N
    print(string.format("gen %d: best_votes=%.1f mean_votes=%.1f", gen, order[1].f, mean))

    -- P7 apply
    for i, p in pop:iter() do
        local reset = copy_payload(p)
        reset.state = "active"
        pop:set(i, rules:apply(reset, { is_elite = elite_set[i] }))
    end

    -- P4 beget + P5 transform for eliminated
    for i, p in pop:iter() do
        if p.state == "eliminated" then
            local parent_idx = elite_list[math.random(1, ELITE)]
            local parent_p = pop:get(parent_idx)
            local child_p = lineage:beget(parent_idx, i, gen, parent_p)
            child_p.record = k_channel:transfer(parent_idx, i, parent_p.record, { gen = gen })
            pop:set(i, child_p)
            pool:reset(i)
        end
    end

    pool:apply_decay(0.5)
end

-- ─── spike asserts ───────────────────────────────────────────────────
assert(pop:size() == N, "size mismatch")

-- P5 was exercised
local k_size = k_channel:size()
assert(k_size > 0, "knowledge_channel history empty")

-- P5 transform result verify on the LATEST transfer (slot reuse aware)
local history = k_channel:history()
local last = history[#history]
local child = pop:get(last.successor)
-- wins/losses must be 0 (transform reset semantic)
assert(child.record.wins == 0,
    string.format("P5 transform: wins=%d on successor=%d (expected 0)",
        child.record.wins, last.successor))
assert(child.record.losses == 0,
    string.format("P5 transform: losses=%d on successor=%d (expected 0)",
        child.record.losses, last.successor))
assert(type(child.record.top_styles) == "table",
    "P5 transform: top_styles must be table")
assert(type(child.record.ancestor_wins) == "number",
    "P5 transform: ancestor_wins (schema reshape) must be number")
assert(type(child.record.gen_born) == "number",
    "P5 transform: gen_born (ctx pickup) must be number")

-- P6 was exercised
local pool_total = 0
for _, slot in ipairs(pool:slots()) do pool_total = pool_total + pool:total(slot) end
assert(pool_total > 0, "scalar_pool empty (no votes accumulated?)")

-- P4 was exercised
assert(lineage:size() > 0, "lineage edges empty")

print(string.format(
    "[OK] arena_spike completed (gens=%d N=%d rounds=%d edges=%d transfers=%d pool=%.1f)",
    GENS, N, ROUNDS_PER_GEN, lineage:size(), k_size, pool_total))
