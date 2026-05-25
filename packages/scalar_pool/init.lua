--- scalar_pool — P2 Primitive (W15 PD spike).
---
--- Multi-source per-slot scalar accumulator. Pure & thin:
---   - new                              : empty pool
---   - credit(slot, source, amount)     : add `amount` (+/-) to slot's
---                                        `source` bucket
---   - debit(slot, source, amount)      : subtract from slot's `source`
---                                        bucket (= credit of -amount)
---   - by_source(slot, source)          : current value in that bucket
---   - total(slot)                      : sum across all sources for
---                                        that slot
---   - reset(slot)                      : drop the slot from the pool
---                                        (used at slot death / reuse)
---   - apply_decay(rate)                : multiply every (slot, source)
---                                        bucket by `rate` in [0, 1]
---   - slots()                          : sorted list of slot indices
---                                        with at least one bucket
---
--- Distinct from P3 ledger:
---   - scalar_pool is ACCUMULATE semantic (multiple credits add up;
---     no conservation invariant across slots).
---   - ledger is TRANSFER semantic (zero-sum between slots, with
---     credit as the only external inflow channel).
---
--- Domain examples (primitives-draft.md §1 v1 P2):
---   - PD iterated tournament: credit(slot, "tournament", payoff)
---   - Creative Farm iR/mR:    credit(slot, "peer", delta),
---                             credit(slot, "market", delta)
---   - Bandit-style reward:    credit(slot, "trial", reward)
---
--- Status: v0.1.0-spike — same provenance as slot_table.

local M = {}

M.VERSION = "0.1.0-spike"
M.meta = {
    name = "scalar_pool",
    version = M.VERSION,
    description = "P2 multi-source per-slot scalar accumulator with decay.",
}

local Pool = {}
Pool.__index = Pool

local function is_pos_int(v)
    return type(v) == "number" and v >= 1 and math.floor(v) == v
end

local function require_source(s, fn)
    if type(s) ~= "string" or s == "" then
        error("scalar_pool." .. fn .. ": source must be non-empty string (got " .. type(s) .. ")", 3)
    end
end

local function require_slot(v, fn)
    if not is_pos_int(v) then
        error("scalar_pool." .. fn .. ": slot must be positive integer (got " .. tostring(v) .. ")", 3)
    end
end

local function require_number(v, name, fn)
    if type(v) ~= "number" then
        error("scalar_pool." .. fn .. ": " .. name .. " must be number (got " .. type(v) .. ")", 3)
    end
end

--- Build an empty pool.
function M.new()
    return setmetatable({ _balances = {} }, Pool)
end

--- Add `amount` (can be negative) to slot's `source` bucket.
function Pool:credit(slot, source, amount)
    require_slot(slot, "credit")
    require_source(source, "credit")
    require_number(amount, "amount", "credit")
    self._balances[slot] = self._balances[slot] or {}
    self._balances[slot][source] = (self._balances[slot][source] or 0) + amount
end

--- Convenience: credit of -amount.
function Pool:debit(slot, source, amount)
    require_slot(slot, "debit")
    require_source(source, "debit")
    require_number(amount, "amount", "debit")
    self._balances[slot] = self._balances[slot] or {}
    self._balances[slot][source] = (self._balances[slot][source] or 0) - amount
end

function Pool:by_source(slot, source)
    local s = self._balances[slot]
    if not s then return 0 end
    return s[source] or 0
end

function Pool:total(slot)
    local s = self._balances[slot]
    if not s then return 0 end
    local sum = 0
    for _, amt in pairs(s) do sum = sum + amt end
    return sum
end

--- Drop slot from pool (slot death / reuse).
function Pool:reset(slot)
    require_slot(slot, "reset")
    self._balances[slot] = nil
end

--- Multiply every (slot, source) bucket by `rate` in [0, 1].
function Pool:apply_decay(rate)
    if type(rate) ~= "number" or rate < 0 or rate > 1 then
        error("scalar_pool.apply_decay: rate must be number in [0, 1] (got " .. tostring(rate) .. ")")
    end
    for slot, sources in pairs(self._balances) do
        for source, amt in pairs(sources) do
            self._balances[slot][source] = amt * rate
        end
    end
end

--- Sorted list of slot indices currently registered in the pool.
function Pool:slots()
    local out = {}
    for slot, _ in pairs(self._balances) do out[#out + 1] = slot end
    table.sort(out)
    return out
end

M.Pool = Pool
return M
