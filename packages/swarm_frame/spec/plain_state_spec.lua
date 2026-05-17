-- Usage: mcp__algocline__alc_pkg_test pkg=swarm_frame
local ps = require("swarm_frame.plain_state")
local describe, it, expect = lust.describe, lust.it, lust.expect

describe("step_done", function()
    it("returns false on an empty list", function()
        local steps = {}
        expect(ps.step_done(steps, "step_1")).to.equal(false)
    end)
    it("returns true when the step is present", function()
        local steps = { "step_1", "step_2" }
        expect(ps.step_done(steps, "step_1")).to.equal(true)
    end)
    it("returns true when the step is the last element", function()
        local steps = { "step_1", "step_2", "step_3" }
        expect(ps.step_done(steps, "step_3")).to.equal(true)
    end)
    it("returns false when the step is absent", function()
        local steps = { "step_1", "step_2" }
        expect(ps.step_done(steps, "step_99")).to.equal(false)
    end)
    it("does not mutate the list", function()
        local steps = { "step_1" }
        ps.step_done(steps, "step_1")
        expect(#steps).to.equal(1)
    end)
end)

describe("step_mark", function()
    it("appends the step name to completed_steps", function()
        local steps = {}
        ps.step_mark(steps, "step_1")
        expect(steps[1]).to.equal("step_1")
    end)
    it("appends to an existing list", function()
        local steps = { "step_0" }
        ps.step_mark(steps, "step_1")
        expect(#steps).to.equal(2)
        expect(steps[2]).to.equal("step_1")
    end)
    it("calls save_fn after appending when provided", function()
        local steps = {}
        local called = false
        ps.step_mark(steps, "step_1", function() called = true end)
        expect(called).to.equal(true)
        -- save_fn is invoked after append, so snapshot includes the new step
        expect(steps[1]).to.equal("step_1")
    end)
    it("does not error when save_fn is nil", function()
        local steps = {}
        local ok = pcall(ps.step_mark, steps, "step_1", nil)
        expect(ok).to.equal(true)
    end)
end)

describe("log_phase", function()
    it("appends a record with name / status / detail", function()
        local logs = {}
        ps.log_phase(logs, "phase_a", "done", "all good")
        expect(#logs).to.equal(1)
        expect(logs[1].name).to.equal("phase_a")
        expect(logs[1].status).to.equal("done")
        expect(logs[1].detail).to.equal("all good")
    end)
    it("appends multiple records in order", function()
        local logs = {}
        ps.log_phase(logs, "phase_a", "started", nil)
        ps.log_phase(logs, "phase_b", "done", "ok")
        expect(#logs).to.equal(2)
        expect(logs[2].name).to.equal("phase_b")
    end)
    it("accepts nil detail without error", function()
        local logs = {}
        local ok = pcall(ps.log_phase, logs, "phase_a", "done", nil)
        expect(ok).to.equal(true)
        expect(logs[1].detail).to.equal(nil)
    end)
end)
