-- examples/market_spike — W13 zero-sum trade via 3 Primitives.
--
-- umbrella 1779690943-76260 primitives-draft.md §9 3rd spike: verify
-- P3 ledger (new Primitive) + P7 transition_rules (b) reentry semantics
-- on the economic / market domain — farthest yet from Creative Farm.
--
-- Composition (Pure names per primitives-draft.md §1 v1):
--   - P1 slot_table       : N=8 traders, payload = {id, state}
--   - P3 ledger (NEW)     : zero-sum transfer + bankrupt detection +
--                           reentry via credit()
--   - P7 transition_rules : active <-> bankrupt (both directions,
--                           verifying (b) state machine's double-headed
--                           transition that the v2 "退場 predicate" (a)
--                           cannot express)
--
-- Conservation invariant verified at the end:
--   sum of all balances == sum of all credit() calls
--
-- Run: lua examples/market_spike/main.lua

package.path = "./packages/?/init.lua;./packages/?.lua;" .. package.path

local st = require("slot_table")
local lg = require("ledger")
local tr = require("transition_rules")

local N, ROUNDS = 8, 20
local INITIAL = 100
local TRANSFER_MAX = 30
local REENTRY = 50
-- bankrupt = "can't fund a minimum transfer" (insolvent semantics).
-- This is a domain-specific threshold encoded in the P7 predicate, not
-- in the P3 ledger primitive itself (ledger only cares about balance
-- and zero-sum invariant; "what counts as bankrupt" is policy).
local BANKRUPT_THRESHOLD = TRANSFER_MAX

math.randomseed(2026)

-- P3 ledger (default: allow_negative=false → underfunded transfer is
-- REJECTED at the ledger boundary, regardless of bankrupt state)
local L = lg.new()

-- P1 traders
local traders = st.new(N, function(i) return { id = i, state = "active" } end)

-- seed credit
for i = 1, N do L:credit(i, INITIAL) end
assert(L:total() == N * INITIAL, "initial seed total mismatch")
assert(L:credit_total() == N * INITIAL, "initial credit_total mismatch")

-- P7 active <-> bankrupt (both directions, verifying (b) double-headed
-- transitions; (a) v2 "退場 predicate" cannot express bankrupt -> active
-- reentry)
local rules = tr.new()
rules:add("active", "bankrupt", function(_, ctx) return ctx.balance < BANKRUPT_THRESHOLD end)
rules:add("bankrupt", "active", function(_, ctx) return ctx.balance >= BANKRUPT_THRESHOLD end)

local function copy_payload(p)
    local c = {}
    for k, v in pairs(p) do c[k] = v end
    return c
end

local function apply_p7()
    for i, p in traders:iter() do
        traders:set(i, rules:apply(copy_payload(p), { balance = L:balance(i) }))
    end
end

local rejected, bankrupt_events, reentries = 0, 0, 0

for round = 1, ROUNDS do
    -- 1. P7 apply (start of round): refilled bankrupts -> active
    apply_p7()

    -- 2. transfer phase: only active traders attempt random trades
    for i, p in traders:iter() do
        if p.state == "active" then
            local partner = math.random(1, N)
            while partner == i do partner = math.random(1, N) end
            local amount = math.random(1, TRANSFER_MAX)
            local ok = L:transfer(i, partner, amount)
            if not ok then rejected = rejected + 1 end
        end
    end

    -- 3. P7 apply (end of transfer): active(balance<=0) -> bankrupt
    local before_states = {}
    for i, p in traders:iter() do before_states[i] = p.state end
    apply_p7()
    for i, p in traders:iter() do
        if before_states[i] == "active" and p.state == "bankrupt" then
            bankrupt_events = bankrupt_events + 1
        end
    end

    -- 4. reentry credit: bankrupt slots receive REENTRY external inflow
    --    (next round's Step 1 transitions them back to active)
    for i, p in traders:iter() do
        if p.state == "bankrupt" then
            L:credit(i, REENTRY)
            reentries = reentries + 1
        end
    end
end

-- ─── final state summary ─────────────────────────────────────────────
local active, bankrupt_now = 0, 0
for _, p in traders:iter() do
    if p.state == "active" then active = active + 1 end
    if p.state == "bankrupt" then bankrupt_now = bankrupt_now + 1 end
end

print(string.format("rounds=%d traders=%d initial=%d transfer_max=%d reentry=%d",
    ROUNDS, N, INITIAL, TRANSFER_MAX, REENTRY))
print(string.format("  rejected_txs=%d bankrupt_events=%d reentries=%d",
    rejected, bankrupt_events, reentries))
print(string.format("  final_active=%d final_bankrupt=%d", active, bankrupt_now))

-- ─── conservation verify (P3 ledger invariant) ───────────────────────
-- total() must equal credit_total() because transfer is zero-sum.
local expected_credit = N * INITIAL + reentries * REENTRY
assert(L:credit_total() == expected_credit,
    string.format("credit_total mismatch: got=%d expected=%d",
        L:credit_total(), expected_credit))

local total_bal = L:total()
assert(total_bal == L:credit_total(),
    string.format("ledger conservation violated: total_bal=%d credit_total=%d (diff=%d)",
        total_bal, L:credit_total(), total_bal - L:credit_total()))

-- transaction log non-empty
assert(L:size() > 0, "transaction log empty")

-- bankrupt events and reentries must have occurred — that is the core
-- of W13 (transition_rules (b) double-headed verify on the market
-- domain).
assert(bankrupt_events > 0,
    "no bankrupt events — spike did not exercise active->bankrupt transition")
assert(reentries > 0,
    "no reentries — spike did not exercise bankrupt->active reentry transition (b)")

-- NOTE: `rejected_txs` may legitimately be 0 here. When P7 fires
-- active->bankrupt the moment balance < BANKRUPT_THRESHOLD, bankrupt
-- traders skip the transfer phase entirely, so the ledger's own
-- insufficient-funds check is never reached. That is *correct*
-- behavior: P7 (policy layer) guards the P3 ledger boundary before
-- it would have to reject. Layered responsibility verified.
-- The ledger's reject path is covered by ledger spec tests directly
-- (tests/run.lua "transfer() returns false on insufficient funds").

print(string.format(
    "[OK] market_spike completed (conservation PASS: total=%d == credit_total=%d, txs=%d)",
    total_bal, L:credit_total(), L:size()))
