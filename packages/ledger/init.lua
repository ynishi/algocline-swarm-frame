--- ledger — P3 Primitive (W13 market spike).
---
--- Zero-sum transfer + per-slot balance + append-only transaction log.
--- Pure & thin:
---   - new(opts?)                          : empty ledger
---       opts.allow_negative (default false): if false, transfer that
---           would push from_slot's balance below 0 is REJECTED
---           (returns false). If true, transfer always succeeds and
---           balance may go negative (margin/debt semantics).
---   - credit(slot, amount)                : external inflow into slot
---           (NOT zero-sum — seed / bailout / reentry); credit_total
---           accumulates these inflows.
---   - transfer(from, to, amount)          : ZERO-SUM transfer between
---           slots; returns true on success, false on insufficient
---           funds (when allow_negative=false).
---   - balance(slot) / total()             : state accessors
---   - credit_total()                      : sum of all credit() calls
---   - transactions() / size()             : append-only history
---
--- Invariant (must hold after any sequence of credit / transfer):
---   total() == credit_total()
--- (= transfer is zero-sum, credit is the only inflow channel.)
---
--- Status: v0.1.0-spike — same provenance as slot_table.

local M = {}

M.VERSION = "0.1.0-spike"
M.meta = {
    name = "ledger",
    version = M.VERSION,
    description = "P3 zero-sum transfer state + credit (external inflow) + tx log.",
}

local Ledger = {}
Ledger.__index = Ledger

local function is_pos_int(v)
    return type(v) == "number" and v >= 1 and math.floor(v) == v
end

--- Build an empty ledger.
--- @param opts table? { allow_negative = boolean? (default false) }
function M.new(opts)
    opts = opts or {}
    local allow_negative = opts.allow_negative
    if allow_negative == nil then allow_negative = false end
    if type(allow_negative) ~= "boolean" then
        error("ledger.new: opts.allow_negative must be boolean (got " .. type(allow_negative) .. ")")
    end
    return setmetatable({
        _balance = {},
        _credit_total = 0,
        _allow_negative = allow_negative,
        _txs = {},
    }, Ledger)
end

--- External inflow into `slot`. Not zero-sum (this is the only channel
--- that increases total()).
function Ledger:credit(slot, amount)
    if not is_pos_int(slot) then
        error("ledger.credit: slot must be positive integer (got " .. tostring(slot) .. ")")
    end
    if type(amount) ~= "number" or amount < 0 then
        error("ledger.credit: amount must be non-negative number (got " .. tostring(amount) .. ")")
    end
    self._balance[slot] = (self._balance[slot] or 0) + amount
    self._credit_total = self._credit_total + amount
    table.insert(self._txs, { kind = "credit", to = slot, amount = amount })
end

--- Zero-sum transfer from `from` to `to`. Returns true on success,
--- false on insufficient funds (allow_negative=false only).
function Ledger:transfer(from, to, amount)
    if not is_pos_int(from) then
        error("ledger.transfer: from must be positive integer (got " .. tostring(from) .. ")")
    end
    if not is_pos_int(to) then
        error("ledger.transfer: to must be positive integer (got " .. tostring(to) .. ")")
    end
    if from == to then
        error("ledger.transfer: from == to is meaningless (got " .. tostring(from) .. ")")
    end
    if type(amount) ~= "number" or amount <= 0 then
        error("ledger.transfer: amount must be positive number (got " .. tostring(amount) .. ")")
    end
    local from_bal = self._balance[from] or 0
    if not self._allow_negative and from_bal < amount then
        return false
    end
    self._balance[from] = from_bal - amount
    self._balance[to] = (self._balance[to] or 0) + amount
    table.insert(self._txs, { kind = "transfer", from = from, to = to, amount = amount })
    return true
end

function Ledger:balance(slot)
    return self._balance[slot] or 0
end

function Ledger:total()
    local s = 0
    for _, b in pairs(self._balance) do s = s + b end
    return s
end

function Ledger:credit_total()
    return self._credit_total
end

function Ledger:transactions()
    local copy = {}
    for i, t in ipairs(self._txs) do
        copy[i] = { kind = t.kind, from = t.from, to = t.to, amount = t.amount }
    end
    return copy
end

function Ledger:size() return #self._txs end

M.Ledger = Ledger
return M
