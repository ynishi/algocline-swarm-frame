-- init_spec.lua — Tests for core swarm_frame public API.
--
-- Covers: state_new, register/resolve, step_id_of, parse_verdict,
-- run_linear (with mock dispatcher), VERSION.

local frame = require("swarm_frame")
local describe, it, expect = lust.describe, lust.it, lust.expect

-- Helper: reset frame state between tests.
local function reset()
    frame._reset_for_testing()
    frame._reset_host_for_testing()
    -- Unregister any paths left over from previous tests.
    local reg = frame._registry()
    for k in pairs(reg) do
        frame.unregister(k)
    end
end

describe("swarm_frame core", function()
    lust.before(function() reset() end)
    lust.after(function() reset() end)

    -- ─── VERSION ─────────────────────────────────────────────────────────────

    describe("VERSION", function()
        it("is 0.4.0", function() expect(frame.VERSION).to.equal("0.4.0") end)

        it("meta.version matches VERSION", function() expect(frame.meta.version).to.equal(frame.VERSION) end)
    end)

    -- ─── state_new ───────────────────────────────────────────────────────────

    describe("state_new", function()
        it("returns a state object", function()
            local s = frame.state_new()
            expect(s).to.exist()
            expect(type(s)).to.equal("table")
        end)

        it("get returns nil for unset key", function()
            local s = frame.state_new()
            expect(s:get("missing.key")).to.equal(nil)
        end)

        it("set and get round-trips a value", function()
            local s = frame.state_new()
            s:set("task.name", "foo")
            expect(s:get("task.name")).to.equal("foo")
        end)

        it("step_done returns false before step_mark", function()
            local s = frame.state_new()
            expect(s:step_done("step_1")).to.equal(false)
        end)

        it("step_done returns true after step_mark", function()
            local s = frame.state_new()
            s:step_mark("step_1")
            expect(s:step_done("step_1")).to.equal(true)
        end)

        it("dump returns a JSON string", function()
            local s = frame.state_new()
            s:set("x", 42)
            local dumped = s:dump()
            expect(type(dumped)).to.equal("string")
            expect(dumped).to.match('"x"')
        end)

        it("restore rebuilds data from dump", function()
            local s1 = frame.state_new()
            s1:set("key", "value")
            local dumped = s1:dump()
            local s2 = frame.state_new()
            s2:restore(dumped)
            expect(s2:get("key")).to.equal("value")
        end)
    end)

    -- ─── register / resolve ──────────────────────────────────────────────────

    describe("register and resolve", function()
        it("register and resolve a spec", function()
            local spec = { role = "agent" }
            frame.register("/pkg/step_1/agent", spec)
            local entry = frame.resolve("/pkg/step_1/agent")
            expect(entry).to.exist()
            expect(entry.spec).to.equal(spec)
        end)

        it("register requires path starting with /", function()
            expect(function() frame.register("no_slash", {}) end).to.fail()
        end)

        it("resolve returns nil for unknown path", function() expect(frame.resolve("/unknown/path")).to.equal(nil) end)

        it("unregister removes a path", function()
            frame.register("/pkg/step_x/agent", {})
            frame.unregister("/pkg/step_x/agent")
            expect(frame.resolve("/pkg/step_x/agent")).to.equal(nil)
        end)

        it("resolve_spec returns static spec", function()
            local spec = { prompt = "hello" }
            frame.register("/pkg/step_2/agent", spec)
            local resolved = frame.resolve_spec("/pkg/step_2/agent", {})
            expect(resolved.prompt).to.equal("hello")
        end)

        it("resolve_spec calls spec-builder function with plain state", function()
            local captured_state = nil
            frame.register("/pkg/step_3/agent", function(state)
                captured_state = state
                return { built = true }
            end)
            local s = frame.state_new()
            s:set("x", 99)
            local resolved = frame.resolve_spec("/pkg/step_3/agent", s)
            expect(resolved.built).to.equal(true)
            -- plain state is a plain table, not a State object
            expect(type(captured_state)).to.equal("table")
        end)
    end)

    -- ─── step_id_of ─────────────────────────────────────────────────────────

    describe("step_id_of", function()
        it(
            "extracts step id from 3-segment path",
            function() expect(frame.step_id_of("/pkg/step_1/agent")).to.equal("step_1") end
        )

        it("returns path unchanged for bare paths", function()
            local result = frame.step_id_of("/no_step")
            -- Pattern returns the whole string when it can't match
            expect(type(result)).to.equal("string")
        end)
    end)

    -- ─── parse_verdict ───────────────────────────────────────────────────────

    describe("parse_verdict", function()
        it("parses DONE path=X", function()
            local v = frame.parse_verdict("DONE path=/pkg/step_1")
            expect(v.status).to.equal("DONE")
            expect(v.path).to.equal("/pkg/step_1")
        end)

        it("parses BLOCKED reason=...", function()
            local v = frame.parse_verdict("BLOCKED reason=needs_review")
            expect(v.status).to.equal("BLOCKED")
            expect(v.reason).to.equal("needs_review")
        end)

        it("parses NEEDS_INPUT missing=...", function()
            local v = frame.parse_verdict("NEEDS_INPUT missing=api_key")
            expect(v.status).to.equal("NEEDS_INPUT")
            expect(v.missing).to.equal("api_key")
        end)

        it("returns UNKNOWN for unrecognised response", function()
            local v = frame.parse_verdict("nothing recognizable here")
            expect(v.status).to.equal("UNKNOWN")
        end)

        it("parses JSON object with status field (format mode)", function()
            local v = frame.parse_verdict('{"status":"DONE","path":"/pkg/step_1"}')
            expect(v.status).to.equal("DONE")
            expect(v.path).to.equal("/pkg/step_1")
        end)

        it("fuzzy mode matches bare DONE token", function()
            local v = frame.parse_verdict("The task is DONE", { fuzzy = true })
            expect(v.status).to.equal("DONE")
        end)
    end)

    -- ─── run_linear ─────────────────────────────────────────────────────────

    describe("run_linear", function()
        it("runs a single-step pipeline to completion", function()
            frame.register("/pkg/step_a/agent", { role = "worker" })
            local s = frame.state_new()
            local ctx = {
                state = s,
                dispatcher = function(path, spec, c) return "DONE path=" .. path end,
            }
            frame.run_linear({ "/pkg/step_a/agent" }, ctx)
            expect(ctx.result.status).to.equal("DONE")
            expect(s:step_done("step_a")).to.equal(true)
        end)

        it("stops on BLOCKED verdict and sets ctx.result", function()
            frame.register("/pkg/step_b/agent", {})
            local s = frame.state_new()
            local ctx = {
                state = s,
                dispatcher = function(path, spec, c) return "BLOCKED reason=external_dep" end,
            }
            frame.run_linear({ "/pkg/step_b/agent" }, ctx)
            expect(ctx.result.status).to.equal("BLOCKED")
            expect(ctx.result.reason).to.equal("external_dep")
            expect(s:step_done("step_b")).to.equal(false)
        end)

        it("skips already completed steps", function()
            frame.register("/pkg/step_c/agent", {})
            local s = frame.state_new()
            s:step_mark("step_c") -- pre-mark as done
            local dispatcher_calls = 0
            local ctx = {
                state = s,
                dispatcher = function(path, spec, c)
                    dispatcher_calls = dispatcher_calls + 1
                    return "DONE path=" .. path
                end,
            }
            frame.run_linear({ "/pkg/step_c/agent" }, ctx)
            expect(dispatcher_calls).to.equal(0)
            expect(ctx.result.status).to.equal("DONE")
        end)

        it("runs two steps in sequence", function()
            frame.register("/pkg/step_d/agent", {})
            frame.register("/pkg/step_e/agent", {})
            local s = frame.state_new()
            local executed = {}
            local ctx = {
                state = s,
                dispatcher = function(path, spec, c)
                    table.insert(executed, path)
                    return "DONE path=" .. path
                end,
            }
            frame.run_linear({ "/pkg/step_d/agent", "/pkg/step_e/agent" }, ctx)
            expect(ctx.result.status).to.equal("DONE")
            expect(#executed).to.equal(2)
            expect(executed[1]).to.equal("/pkg/step_d/agent")
            expect(executed[2]).to.equal("/pkg/step_e/agent")
        end)

        it("raises when ctx.state is missing", function()
            expect(function() frame.run_linear({}, {}) end).to.fail()
        end)
    end)
end)
