-- v3_contract_spec.lua — Contract 5 sub-module (P4 coverage).
--
-- Validates alc_shapes runtime check pass / fail for each schema, and
-- the 4-method probes for state_backend / artifact_backend / dispatcher /
-- observer. /contract is the SoT for swarm_host_alc impl + caller-side
-- input validation.

local lust     = require("lust")
local alc      = require("alc_shapes")
local swarm    = require("swarm_frame.v3")
local C        = swarm.contract
local describe, it, expect = lust.describe, lust.it, lust.expect

describe("swarm.v3.contract aggregator", function()
    it("re-exports 5 sub-modules", function()
        expect(type(C.dispatcher_iface)).to.equal("table")
        expect(type(C.observer_hook)).to.equal("table")
        expect(type(C.state_schema)).to.equal("table")
        expect(type(C.state_backend_iface)).to.equal("table")
        expect(type(C.artifact_backend_iface)).to.equal("table")
    end)
    it("each sub-module declares VERSION", function()
        expect(type(C.dispatcher_iface.VERSION)).to.equal("string")
        expect(type(C.observer_hook.VERSION)).to.equal("string")
        expect(type(C.state_schema.VERSION)).to.equal("string")
        expect(type(C.state_backend_iface.VERSION)).to.equal("string")
        expect(type(C.artifact_backend_iface.VERSION)).to.equal("string")
    end)
end)

describe("swarm.v3.contract.dispatcher_iface", function()
    it("DispatchInput.check passes for valid {ref, input}", function()
        local ok = alc.check({ ref = "@a", input = nil }, C.dispatcher_iface.DispatchInput)
        expect(ok).to.equal(true)
    end)
    it("DispatchInput.check passes for non-nil input", function()
        local ok = alc.check({ ref = "@a", input = { x = 1 } },
                             C.dispatcher_iface.DispatchInput)
        expect(ok).to.equal(true)
    end)
    it("DispatchInput.check rejects missing ref", function()
        local ok, reason = alc.check({ input = nil }, C.dispatcher_iface.DispatchInput)
        expect(ok).to.equal(false)
        expect(reason).to_not.equal(nil)
    end)
    it("DispatchInput.check rejects non-string ref", function()
        local ok = alc.check({ ref = 42, input = nil }, C.dispatcher_iface.DispatchInput)
        expect(ok).to.equal(false)
    end)
    it("check_call: function passes", function()
        local ok = C.dispatcher_iface.check_call(function(ref, input) end)
        expect(ok).to.equal(true)
    end)
    it("check_call: non-function fails with reason", function()
        local ok, reason = C.dispatcher_iface.check_call({})
        expect(ok).to.equal(false)
        expect(tostring(reason):find("function")).to_not.equal(nil)
    end)
end)

describe("swarm.v3.contract.observer_hook", function()
    it("EventPayload.check passes for {phase='start', step_id=...}", function()
        local ok = alc.check({ phase = "start", step_id = "s1" },
                             C.observer_hook.EventPayload)
        expect(ok).to.equal(true)
    end)
    it("EventPayload.check passes for error event with structured error", function()
        local ok = alc.check({
            phase = "error",
            error = { kind = "exec_fail", message = "boom" },
        }, C.observer_hook.EventPayload)
        expect(ok).to.equal(true)
    end)
    it("EventPayload.check rejects invalid phase value", function()
        local ok = alc.check({ phase = "weird" }, C.observer_hook.EventPayload)
        expect(ok).to.equal(false)
    end)
    it("check_call: function passes", function()
        local ok = C.observer_hook.check_call(function() end)
        expect(ok).to.equal(true)
    end)
end)

describe("swarm.v3.contract.state_schema", function()
    it("Snapshot.check passes for minimal valid snapshot", function()
        local ok = alc.check({
            task_id = "t1",
            status  = "in_progress",
            ctx     = {},
        }, C.state_schema.Snapshot)
        expect(ok).to.equal(true)
    end)
    it("Snapshot.check rejects invalid status value", function()
        local ok = alc.check({
            task_id = "t1",
            status  = "running",  -- not in the 5-value set
            ctx     = {},
        }, C.state_schema.Snapshot)
        expect(ok).to.equal(false)
    end)
    it("Snapshot.check accepts optional progress entries", function()
        local ok = alc.check({
            task_id  = "t1",
            status   = "in_progress",
            ctx      = {},
            progress = {
                { step_id = "s1", status = "done" },
                { step_id = "s2", status = "pending" },
            },
        }, C.state_schema.Snapshot)
        expect(ok).to.equal(true)
    end)
    it("Snapshot.check rejects invalid progress status", function()
        local ok = alc.check({
            task_id  = "t1",
            status   = "in_progress",
            ctx      = {},
            progress = { { step_id = "s1", status = "weird" } },
        }, C.state_schema.Snapshot)
        expect(ok).to.equal(false)
    end)
end)

describe("swarm.v3.contract.state_backend_iface", function()
    local function make_backend()
        return {
            write  = function(self, task_id, snap) end,
            read   = function(self, task_id) end,
            exists = function(self, task_id) end,
            delete = function(self, task_id) end,
        }
    end
    it("check_iface: 4-method table passes", function()
        local ok = C.state_backend_iface.check_iface(make_backend())
        expect(ok).to.equal(true)
    end)
    it("check_iface: missing method fails with reason", function()
        local b = make_backend()
        b.delete = nil
        local ok, reason = C.state_backend_iface.check_iface(b)
        expect(ok).to.equal(false)
        expect(tostring(reason):find("delete")).to_not.equal(nil)
    end)
    it("check_iface: non-table fails", function()
        local ok = C.state_backend_iface.check_iface(function() end)
        expect(ok).to.equal(false)
    end)
    it("re-exports Snapshot for convenience", function()
        expect(C.state_backend_iface.Snapshot).to.equal(C.state_schema.Snapshot)
    end)
end)

describe("swarm.v3.contract.artifact_backend_iface", function()
    local function make_backend()
        return {
            write  = function() end,
            read   = function() end,
            exists = function() end,
            delete = function() end,
        }
    end
    it("check_iface: 4-method table passes", function()
        local ok = C.artifact_backend_iface.check_iface(make_backend())
        expect(ok).to.equal(true)
    end)
    it("check_iface: missing method fails", function()
        local b = make_backend()
        b.read = nil
        local ok, reason = C.artifact_backend_iface.check_iface(b)
        expect(ok).to.equal(false)
        expect(tostring(reason):find("read")).to_not.equal(nil)
    end)
    it("Summary schema check passes for minimal valid stub", function()
        local ok = alc.check({ artifact_id = "a1" },
                             C.artifact_backend_iface.Summary)
        expect(ok).to.equal(true)
    end)
end)
