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

-- ─── plain_state.gate_decide ctx-aware applicability ─────────────────────────

describe("plain_state.gate_decide ctx-aware applicability", function()
    -- Crux 1: 5-arg and 6-arg ctx=nil are bit-identical
    it("5-arg and 6-arg ctx=nil produce bit-identical gates[name] shape (Crux 1)", function()
        local gates5, steps5 = {}, {}
        local gates6, steps6 = {}, {}
        local v = ps.verdict({ label = "BLOCKED", next_action = "halt" })

        ps.gate_decide(gates5, steps5, "g", v)
        ps.gate_decide(gates6, steps6, "g", v, nil, nil)

        expect(gates5.g.retries).to.equal(gates6.g.retries)
        expect(#steps5).to.equal(#steps6)
        expect(steps5[1]).to.equal(steps6[1])
        expect(type(gates5.g.marked_at)).to.equal(type(gates6.g.marked_at))
        expect(gates5.g.skipped).to.equal(gates6.g.skipped) -- both nil
    end)

    -- Crux 1: 5-arg with save_fn and 6-arg with save_fn + ctx=nil are bit-identical
    it("5-arg save_fn and 6-arg save_fn+ctx=nil produce bit-identical shape (Crux 1)", function()
        local gates5, steps5 = {}, {}
        local gates6, steps6 = {}, {}
        local v = ps.verdict({ label = "PASS", next_action = nil })
        local save5_count, save6_count = 0, 0

        ps.gate_decide(gates5, steps5, "g", v, function() save5_count = save5_count + 1 end)
        ps.gate_decide(gates6, steps6, "g", v, function() save6_count = save6_count + 1 end, nil)

        expect(gates5.g.retries).to.equal(gates6.g.retries)
        expect(#steps5).to.equal(#steps6)
        expect(save5_count).to.equal(1)
        expect(save6_count).to.equal(1)
        expect(gates5.g.skipped).to.equal(gates6.g.skipped) -- both nil
    end)

    -- Skip when ctx.strategy not in applicable_under list
    it("skips gate when ctx.strategy is not in applicable_under list", function()
        local gates, steps = {}, {}
        local v = ps.verdict({ label = "PASS", next_action = nil, applicable_under = { "topic-only" } })
        ps.gate_decide(gates, steps, "g", v, nil, { strategy = "main" })

        expect(gates.g.skipped).to.equal(true)
        expect(type(gates.g.skip_reason)).to.equal("string")
        expect(gates.g.skip_reason:find("not in applicable_under") ~= nil).to.equal(true)
        -- completed_steps not appended on skip
        expect(#steps).to.equal(0)
        -- marked_at not set on skip
        expect(gates.g.marked_at).to.equal(nil)
        -- retries is incremented even on skip
        expect(gates.g.retries).to.equal(1)
    end)

    -- Verdict pass-through on skip path (Rich Verdict pass-through contract, skip path)
    it("skip path stores verdict as pass-through (Rich Verdict contract on skip)", function()
        local gates, steps = {}, {}
        local v = ps.verdict({
            label = "BLOCKED",
            next_action = "halt",
            applicable_under = { "topic-only" },
            detail = "some detail",
        })
        ps.gate_decide(gates, steps, "g", v, nil, { strategy = "main" })

        expect(gates.g.skipped).to.equal(true)
        -- verdict is stored verbatim even on skip
        expect(gates.g.verdict).to.equal(v)
        expect(gates.g.verdict.label).to.equal("BLOCKED")
        expect(gates.g.verdict.detail).to.equal("some detail")
    end)

    -- Apply when ctx.strategy is in applicable_under list
    it("applies gate normally when ctx.strategy is in applicable_under list", function()
        local gates, steps = {}, {}
        local v = ps.verdict({ label = "BLOCKED", next_action = "halt", applicable_under = { "topic-only", "main" } })
        ps.gate_decide(gates, steps, "g", v, nil, { strategy = "topic-only" })

        expect(gates.g.skipped).to.equal(nil)
        expect(#steps).to.equal(1) -- halt -> appended
        expect(steps[1]).to.equal("g")
    end)

    -- applicable_under = "*" always applies regardless of ctx.strategy
    it("applies when applicable_under = '*' regardless of ctx.strategy", function()
        local gates, steps = {}, {}
        local v = ps.verdict({ label = "PASS", next_action = nil, applicable_under = "*" })
        ps.gate_decide(gates, steps, "g", v, nil, { strategy = "any-strategy" })

        expect(gates.g.skipped).to.equal(nil)
        expect(#steps).to.equal(0) -- PASS -> not appended, but also not skipped
    end)

    -- ctx = nil with applicable_under set: no applicability check (Crux 1 fallback)
    it("does NOT skip when ctx is nil, even with applicable_under set", function()
        local gates, steps = {}, {}
        local v = ps.verdict({ label = "BLOCKED", next_action = "halt", applicable_under = { "topic-only" } })
        ps.gate_decide(gates, steps, "g", v, nil, nil)

        expect(gates.g.skipped).to.equal(nil)
        expect(#steps).to.equal(1) -- normal halt path
    end)

    -- ctx = {} (ctx.strategy nil): applicability check skipped (bit-identical fallback)
    it("does NOT skip when ctx.strategy is nil (ctx = {})", function()
        local gates, steps = {}, {}
        local v = ps.verdict({ label = "BLOCKED", next_action = "halt", applicable_under = { "topic-only" } })
        ps.gate_decide(gates, steps, "g", v, nil, {})

        expect(gates.g.skipped).to.equal(nil)
        expect(#steps).to.equal(1) -- normal halt path
    end)

    -- Crux 2: literal verdict (no applicable_under method) defaults to "*" — never skip
    it("literal table verdict with no applicable_under method is treated as '*' (Crux 2)", function()
        local gates, steps = {}, {}
        -- Raw literal table: no metatable, applicable_under field absent
        local v = { label = "BLOCKED", next_action = "halt" }
        ps.gate_decide(gates, steps, "g", v, nil, { strategy = "topic-only" })

        -- Must NOT skip — Crux 2: method-absent → default "*" → always apply
        expect(gates.g.skipped).to.equal(nil)
        expect(#steps).to.equal(1)
    end)

    -- Non-table ctx raises error
    it("errors when ctx is a non-table non-nil value", function()
        local gates, steps = {}, {}
        local v = ps.verdict({ label = "PASS", next_action = nil })
        local ok, err = pcall(ps.gate_decide, gates, steps, "g", v, nil, "not-a-table")
        expect(ok).to.equal(false)
        expect(type(err)).to.equal("string")
        expect(err:find("ctx must be a table or nil") ~= nil).to.equal(true)
    end)

    -- skip_reason string contains strategy name
    it("skip_reason includes the strategy name for observability", function()
        local gates, steps = {}, {}
        local v = ps.verdict({ label = "PASS", next_action = nil, applicable_under = { "topic-only" } })
        ps.gate_decide(gates, steps, "g", v, nil, { strategy = "main" })

        expect(gates.g.skip_reason:find("main") ~= nil).to.equal(true)
    end)

    -- save_fn is invoked even on skip path
    it("invokes save_fn on skip path", function()
        local gates, steps = {}, {}
        local v = ps.verdict({ label = "PASS", next_action = nil, applicable_under = { "topic-only" } })
        local save_called = false
        ps.gate_decide(gates, steps, "g", v, function() save_called = true end, { strategy = "main" })

        expect(save_called).to.equal(true)
        expect(gates.g.skipped).to.equal(true)
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

-- ─── State:gate_decide ctx pass-through ──────────────────────────────────────

describe("State:gate_decide ctx pass-through", function()
    -- Crux 1 transitivity: 2-arg and 4-arg ctx=nil must produce bit-identical shape
    it("2-arg and 4-arg ctx=nil produce bit-identical gates[name] shape", function()
        local v = ps.verdict({ label = "PASS", next_action = nil })

        local st1 = frame.state_new()
        st1:gate_decide("g", v)

        local st2 = frame.state_new()
        st2:gate_decide("g", v, nil, nil)

        expect(st1._data.gates.g.retries).to.equal(st2._data.gates.g.retries)
        expect(st1._data.gates.g.skipped).to.equal(st2._data.gates.g.skipped)
        expect(#st1._data.completed_steps).to.equal(#st2._data.completed_steps)
    end)

    -- applicable_under mismatch → skipped=true at State layer
    it("skips gate when ctx.strategy is not in applicable_under", function()
        local v = ps.verdict({ label = "PASS", next_action = nil, applicable_under = { "other" } })
        local st = frame.state_new()
        st:gate_decide("g", v, nil, { strategy = "topic-only" })
        expect(st._data.gates.g.skipped).to.equal(true)
        expect(#st._data.completed_steps).to.equal(0)
    end)

    -- applicable_under match → normal transition at State layer
    it("applies gate when ctx.strategy matches applicable_under", function()
        local v = ps.verdict({ label = "BLOCKED", next_action = "halt", applicable_under = { "topic-only" } })
        local st = frame.state_new()
        st:gate_decide("g", v, nil, { strategy = "topic-only" })
        expect(st._data.gates.g.skipped).to.equal(nil)
        expect(#st._data.completed_steps).to.equal(1)
    end)

    -- dump/restore round-trip preserves skipped tag
    it("preserves skipped tag across dump/restore", function()
        local v = ps.verdict({ label = "PASS", next_action = nil, applicable_under = { "other" } })
        local st = frame.state_new()
        st:gate_decide("sk_gate", v, nil, { strategy = "topic-only" })
        expect(st._data.gates.sk_gate.skipped).to.equal(true)

        local dumped = st:dump()
        local st2 = frame.state_new()
        st2:restore(dumped)

        expect(st2._data.gates.sk_gate.skipped).to.equal(true)
        expect(type(st2._data.gates.sk_gate.skip_reason)).to.equal("string")
    end)
end)
