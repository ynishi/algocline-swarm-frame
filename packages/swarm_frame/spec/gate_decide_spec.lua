-- Usage: mcp__algocline__alc_pkg_test pkg=swarm_frame
local ps = require("swarm_frame.plain_state")
local frame = require("swarm_frame")
local describe, it, expect = lust.describe, lust.it, lust.expect

-- ─── plain_state.gate_decide ─────────────────────────────────────────────────

describe("plain_state.gate_decide", function()
    it("appends to completed_steps when is_halting=true", function()
        local gates, steps = {}, {}
        local v = ps.verdict({ label = "BLOCKED", next_action = "halt" })
        ps.gate_decide(gates, steps, "gate_1", v)
        expect(#steps).to.equal(1)
        expect(steps[1]).to.equal("gate_1")
    end)

    it("does NOT append when is_halting=false", function()
        local gates, steps = {}, {}
        local v = ps.verdict({ label = "PASS", next_action = nil })
        ps.gate_decide(gates, steps, "gate_1", v)
        expect(#steps).to.equal(0)
    end)

    -- ★ CRUX: Rich Verdict pass-through 非解釈
    -- must_not_simplify: gate_decide は受け取った verdict オブジェクト全体を
    --   gates[name].verdict に格納しなければならず、next_action / detail / raw / label
    --   のいずれのフィールドも primitive 内部で意味解釈・変換・削除してはならない。
    it("stores Rich verdict in gates[name].verdict (full pass-through)", function()
        local gates, steps = {}, {}
        local v = ps.verdict({
            label = "BLOCKED",
            next_action = "halt",
            detail = "upstream timed out",
            raw = { code = 503, retry_after = 60 },
        })
        ps.gate_decide(gates, steps, "gate_rich", v)
        local stored = gates.gate_rich.verdict
        -- All four fields must survive verbatim — no interpretation, no removal
        expect(stored.label).to.equal("BLOCKED")
        expect(stored.next_action).to.equal("halt")
        expect(stored.detail).to.equal("upstream timed out")
        expect(stored.raw.code).to.equal(503)
        expect(stored.raw.retry_after).to.equal(60)
        -- The stored object is the same reference (not a copy)
        expect(stored).to.equal(v)
    end)

    it("increments gates[name].retries on every call", function()
        local gates, steps = {}, {}
        local v_pass = ps.verdict({ label = "PASS", next_action = nil })
        local v_halt = ps.verdict({ label = "BLOCKED", next_action = "halt" })

        -- First call (PASS)
        ps.gate_decide(gates, steps, "g", v_pass)
        expect(gates.g.retries).to.equal(1)

        -- Second call (PASS) — retries still increments
        ps.gate_decide(gates, steps, "g", v_pass)
        expect(gates.g.retries).to.equal(2)

        -- Third call (halt) — retries still increments regardless
        ps.gate_decide(gates, steps, "g", v_halt)
        expect(gates.g.retries).to.equal(3)
    end)

    it("sets gates[name].marked_at only when halt", function()
        local gates, steps = {}, {}
        local v_pass = ps.verdict({ label = "PASS", next_action = nil })
        ps.gate_decide(gates, steps, "g", v_pass)
        -- No halt -> marked_at should be nil
        expect(gates.g.marked_at).to.equal(nil)

        local v_halt = ps.verdict({ label = "BLOCKED", next_action = "halt" })
        ps.gate_decide(gates, steps, "g", v_halt)
        -- Halt -> marked_at is set to a number (os.time())
        expect(type(gates.g.marked_at)).to.equal("number")
    end)

    it("invokes save_fn after state mutation", function()
        local gates, steps = {}, {}
        local v = ps.verdict({ label = "BLOCKED", next_action = "halt" })
        local save_called = false
        local steps_at_save_time = nil

        ps.gate_decide(gates, steps, "g", v, function()
            save_called = true
            -- Snapshot the length at the moment save_fn is called
            steps_at_save_time = #steps
        end)

        expect(save_called).to.equal(true)
        -- save_fn is called AFTER state mutation, so steps already contains the new entry
        expect(steps_at_save_time).to.equal(1)
    end)

    it("does not invoke save_fn when it is nil", function()
        local gates, steps = {}, {}
        local v = ps.verdict({ label = "PASS", next_action = nil })
        local ok = pcall(ps.gate_decide, gates, steps, "g", v, nil)
        expect(ok).to.equal(true)
    end)

    -- Literal table verdict: metatable-less table should still work via fallback
    it("accepts literal table verdict (factory not required)", function()
        local gates, steps = {}, {}
        -- No ps.verdict() call — raw literal table, no metatable
        local v = { label = "BLOCKED", next_action = "halt" }
        -- Must NOT raise "attempt to call a nil value (method 'is_halting')"
        local ok = pcall(ps.gate_decide, gates, steps, "g", v)
        expect(ok).to.equal(true)
        -- Since next_action == "halt", fallback default is_halting returns true -> appended
        expect(#steps).to.equal(1)
        expect(steps[1]).to.equal("g")
    end)

    it("literal table verdict with next_action~='halt' does NOT append", function()
        local gates, steps = {}, {}
        local v = { label = "PASS", next_action = "pass" }
        local ok = pcall(ps.gate_decide, gates, steps, "g", v)
        expect(ok).to.equal(true)
        expect(#steps).to.equal(0)
    end)

    -- ─── Input validation (error cases) ──────────────────────────────────────

    it("errors on non-string name", function()
        local gates, steps = {}, {}
        local v = ps.verdict({ label = "L", next_action = "halt" })
        local ok, err = pcall(ps.gate_decide, gates, steps, 123, v)
        expect(ok).to.equal(false)
        expect(type(err)).to.equal("string")
        expect(err:find("name must be a string") ~= nil).to.equal(true)
    end)

    it("errors on non-table gates", function()
        local steps = {}
        local v = ps.verdict({ label = "L", next_action = "halt" })
        local ok, err = pcall(ps.gate_decide, "not-a-table", steps, "g", v)
        expect(ok).to.equal(false)
        expect(type(err)).to.equal("string")
        expect(err:find("gates must be a table") ~= nil).to.equal(true)
    end)

    it("errors on non-table completed_steps", function()
        local gates = {}
        local v = ps.verdict({ label = "L", next_action = "halt" })
        local ok, err = pcall(ps.gate_decide, gates, "not-a-table", "g", v)
        expect(ok).to.equal(false)
        expect(type(err)).to.equal("string")
        expect(err:find("completed_steps must be a table") ~= nil).to.equal(true)
    end)

    it("errors on non-table verdict", function()
        local gates, steps = {}, {}
        local ok, err = pcall(ps.gate_decide, gates, steps, "g", "not-a-table")
        expect(ok).to.equal(false)
        expect(type(err)).to.equal("string")
        expect(err:find("verdict must be a table") ~= nil).to.equal(true)
    end)

    it("accumulates multiple gate entries independently", function()
        local gates, steps = {}, {}
        local v_a = ps.verdict({ label = "BLOCKED", next_action = "halt" })
        local v_b = ps.verdict({ label = "PASS", next_action = nil })

        ps.gate_decide(gates, steps, "gate_a", v_a)
        ps.gate_decide(gates, steps, "gate_b", v_b)

        expect(#steps).to.equal(1)
        expect(steps[1]).to.equal("gate_a")
        expect(gates.gate_a.retries).to.equal(1)
        expect(gates.gate_b.retries).to.equal(1)
    end)
end)

-- ─── State:gate_decide ───────────────────────────────────────────────────────

describe("State:gate_decide", function()
    it("mirrors plain_state.gate_decide on _data.completed_steps (halt)", function()
        local st = frame.state_new()
        local v = ps.verdict({ label = "BLOCKED", next_action = "halt" })
        st:gate_decide("gate_1", v)
        expect(#st._data.completed_steps).to.equal(1)
        expect(st._data.completed_steps[1]).to.equal("gate_1")
    end)

    it("mirrors plain_state.gate_decide on _data.completed_steps (pass)", function()
        local st = frame.state_new()
        local v = ps.verdict({ label = "PASS", next_action = nil })
        st:gate_decide("gate_1", v)
        expect(#st._data.completed_steps).to.equal(0)
    end)

    it("lazy-inits _data.gates and _data.completed_steps on first call", function()
        local st = frame.state_new()
        -- Before any gate_decide call, these fields should not exist
        expect(st._data.gates).to.equal(nil)
        expect(st._data.completed_steps).to.equal(nil)

        local v = ps.verdict({ label = "PASS", next_action = nil })
        st:gate_decide("g", v)

        -- After first call, both are initialised
        expect(type(st._data.gates)).to.equal("table")
        expect(type(st._data.completed_steps)).to.equal("table")
    end)

    it("stores Rich verdict in gates[name].verdict via State surface", function()
        local st = frame.state_new()
        local v = ps.verdict({
            label = "BLOCKED",
            next_action = "halt",
            detail = "timeout",
            raw = { attempt = 3 },
        })
        st:gate_decide("qgate", v)
        local stored = st._data.gates.qgate.verdict
        expect(stored.label).to.equal("BLOCKED")
        expect(stored.next_action).to.equal("halt")
        expect(stored.detail).to.equal("timeout")
        expect(stored.raw.attempt).to.equal(3)
    end)

    it("increments retries across multiple calls on same gate", function()
        local st = frame.state_new()
        local v = ps.verdict({ label = "PASS", next_action = nil })
        st:gate_decide("g", v)
        st:gate_decide("g", v)
        expect(st._data.gates.g.retries).to.equal(2)
    end)

    it("preserves gate state across dump/restore", function()
        local st = frame.state_new()
        local v_pass = ps.verdict({ label = "PASS", next_action = nil })
        local v_halt = ps.verdict({ label = "BLOCKED", next_action = "halt" })

        -- Mutate state: one PASS + one HALT gate
        st:gate_decide("gate_p", v_pass)
        st:gate_decide("gate_h", v_halt)

        -- Round-trip through JSON
        local dumped = st:dump()
        local st2 = frame.state_new()
        st2:restore(dumped)

        -- Verify _data.gates and _data.completed_steps survived
        expect(type(st2._data.gates)).to.equal("table")
        expect(type(st2._data.completed_steps)).to.equal("table")
        expect(#st2._data.completed_steps).to.equal(1)
        expect(st2._data.completed_steps[1]).to.equal("gate_h")
        expect(st2._data.gates.gate_p.retries).to.equal(1)
        expect(st2._data.gates.gate_h.retries).to.equal(1)

        -- Further gate_decide after restore works correctly
        local v2 = ps.verdict({ label = "BLOCKED", next_action = "halt" })
        st2:gate_decide("gate_p", v2) -- now gate_p halts
        expect(#st2._data.completed_steps).to.equal(2)
        expect(st2._data.gates.gate_p.retries).to.equal(2)
    end)
end)
