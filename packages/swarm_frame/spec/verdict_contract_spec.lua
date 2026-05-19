-- Usage: mcp__algocline__alc_pkg_test pkg=swarm_frame
local ps = require("swarm_frame.plain_state")
local describe, it, expect = lust.describe, lust.it, lust.expect

-- ─── Default is_halting behaviour ────────────────────────────────────────────

describe("Verdict default is_halting", function()
    it("returns true when next_action == 'halt'", function()
        local v = ps.verdict({ label = "BLOCKED", next_action = "halt" })
        expect(v:is_halting()).to.equal(true)
    end)

    it("returns false when next_action == 'escalate'", function()
        local v = ps.verdict({ label = "NEEDS_HUMAN", next_action = "escalate" })
        expect(v:is_halting()).to.equal(false)
    end)

    it("returns false when next_action == nil", function()
        local v = ps.verdict({ label = "PASS", next_action = nil })
        expect(v:is_halting()).to.equal(false)
    end)

    it("returns false when next_action == 'retry'", function()
        local v = ps.verdict({ label = "RETRY", next_action = "retry" })
        expect(v:is_halting()).to.equal(false)
    end)

    it("returns false when next_action is an unrecognised string", function()
        local v = ps.verdict({ label = "CUSTOM", next_action = "something_else" })
        expect(v:is_halting()).to.equal(false)
    end)
end)

-- ─── Custom is_halting override ──────────────────────────────────────────────

describe("Verdict Custom is_halting override", function()
    it("allows producer to override is_halting via fields", function()
        local v = ps.verdict({
            label = "NEEDS_HUMAN",
            next_action = "escalate",
            is_halting = function(self) return true end,
        })
        -- Custom override wins over default (next_action == "escalate" would be false)
        expect(v:is_halting()).to.equal(true)
    end)

    it("allows producer to force is_halting=false even for next_action=='halt'", function()
        local v = ps.verdict({
            label = "FAKE_HALT",
            next_action = "halt",
            is_halting = function(self) return false end,
        })
        expect(v:is_halting()).to.equal(false)
    end)

    it("custom is_halting receives self as first argument", function()
        local captured_self = nil
        local v = ps.verdict({
            label = "L",
            next_action = "escalate",
            is_halting = function(self)
                captured_self = self
                return false
            end,
        })
        v:is_halting()
        expect(captured_self).to_not.equal(nil)
        expect(captured_self.label).to.equal("L")
    end)
end)

-- ─── verdict factory input validation ────────────────────────────────────────

describe("verdict factory input validation", function()
    it("errors when fields is not a table", function()
        local ok, err = pcall(ps.verdict, "not-a-table")
        expect(ok).to.equal(false)
        expect(type(err)).to.equal("string")
        -- message contains module path hint
        expect(err:find("swarm_frame.plain_state.verdict") ~= nil).to.equal(true)
    end)

    it("errors when fields is nil", function()
        local ok, err = pcall(ps.verdict, nil)
        expect(ok).to.equal(false)
        expect(type(err)).to.equal("string")
    end)

    it("errors when fields is a number", function()
        local ok, err = pcall(ps.verdict, 42)
        expect(ok).to.equal(false)
        expect(type(err)).to.equal("string")
    end)

    it("accepts an empty table (minimal valid call)", function()
        local ok = pcall(ps.verdict, {})
        expect(ok).to.equal(true)
    end)
end)

-- ─── CRUX: Custom verdict halt 非介入 spec ───────────────────────────────────
--
-- Crux label: "Custom verdict halt 非介入 spec"
-- must_not_simplify: Custom next_action 値（例:"human_escalation_needed"）を持ち
--   is_halting() が false を返す verdict を gate_decide に渡したとき、
--   completed_steps への append が発生しないことを専用 spec で明示的に検証する。

describe("Custom next_action does NOT cause halt by string match", function()
    -- ★ CRUX CASE (d): Custom next_action="human_escalation_needed"
    --    is_halting omitted -> default returns false (na ~= "halt")
    --    -> completed_steps must NOT be appended
    it("Custom next_action='human_escalation_needed' with is_halting=false does NOT append", function()
        local gates, steps = {}, {}
        local v = ps.verdict({
            label = "CUSTOM_LABEL",
            next_action = "human_escalation_needed",
            -- is_halting omitted: default impl returns false (na ~= "halt")
        })
        ps.gate_decide(gates, steps, "gate_x", v)
        expect(#steps).to.equal(0) -- ★ no append (crux validation)
        -- pass-through: the Custom next_action is still in the stored verdict
        expect(gates.gate_x.verdict.next_action).to.equal("human_escalation_needed")
    end)

    -- ★ CRUX CASE (e): primitive does NOT inspect next_action / detail / raw / label
    --    Multiple Custom strings — all yield is_halting=false -> no append
    it("primitive does NOT inspect next_action / detail / raw / label values", function()
        local custom_actions = {
            "human_escalation_needed",
            "rate_limited_retry",
            "waiting_for_upstream",
            "operator_intervention_required",
            "custom_domain_specific_action",
        }
        for _, na in ipairs(custom_actions) do
            local gates, steps = {}, {}
            local v = ps.verdict({
                label = "TEST",
                next_action = na,
                detail = "some detail",
                raw = { anything = true },
            })
            ps.gate_decide(gates, steps, "g", v)
            -- None of these Custom strings should trigger an append
            expect(#steps).to.equal(0)
            -- All fields pass-through verbatim
            expect(gates.g.verdict.next_action).to.equal(na)
            expect(gates.g.verdict.detail).to.equal("some detail")
            expect(gates.g.verdict.raw.anything).to.equal(true)
        end
    end)

    it("only 'halt' triggers is_halting=true via default implementation", function()
        local gates_halt, steps_halt = {}, {}
        local v_halt = ps.verdict({ label = "BLOCKED", next_action = "halt" })
        ps.gate_decide(gates_halt, steps_halt, "g", v_halt)
        expect(#steps_halt).to.equal(1) -- halt -> appended

        local gates_pass, steps_pass = {}, {}
        local v_pass = ps.verdict({ label = "PASS", next_action = "pass" })
        ps.gate_decide(gates_pass, steps_pass, "g", v_pass)
        expect(#steps_pass).to.equal(0) -- non-halt -> not appended
    end)
end)
