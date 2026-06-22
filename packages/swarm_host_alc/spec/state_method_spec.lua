-- state_method_spec.lua — Validation, happy path, error propagation
-- (1:1 absorb of swarm_state_method/spec/update_dispatch_record_spec.lua,
-- adjusted for standalone runner + swarm_host_alc.state_method namespace).
--
-- opts.alc を mock 注入し、 実 _G.alc / 実 state store に依存せず走る。

local lust = require("lust")
local describe, it, expect = lust.describe, lust.it, lust.expect

local M = require("swarm_host_alc.state_method")

-- ─── helpers ────────────────────────────────────────────────────────

local function contains(s, sub)
    return type(s) == "string" and string.find(s, sub, 1, true) ~= nil
end

local function make_mock_alc(seed_state)
    local last = { ns = nil, key = nil, value = nil, calls = 0 }
    return {
        state = {
            show = function(_ns, _key) return seed_state end,
            set_dispatched = function(ns, key, value)
                last.ns = ns
                last.key = key
                last.value = value
                last.calls = last.calls + 1
            end,
        },
    }, last
end

local function make_alc_show_returns(value)
    return {
        state = {
            show = function(_ns, _key) return value end,
            set_dispatched = function(_ns, _key, _value) end,
        },
    }
end

-- ─── specs ──────────────────────────────────────────────────────────

describe("swarm_host_alc.state_method.run", function()
    describe("entry-point validation", function()
        it("errors when opts is not a table", function()
            local ok, err = pcall(M.run, "bad")
            expect(ok).to.equal(false)
            expect(contains(err, "opts table required")).to.equal(true)
        end)

        it("errors when opts.action is missing", function()
            local ok, err = pcall(M.run, {})
            expect(ok).to.equal(false)
            expect(contains(err, "opts.action")).to.equal(true)
        end)

        it("errors when opts.action is empty string", function()
            local ok, err = pcall(M.run, { action = "" })
            expect(ok).to.equal(false)
            expect(contains(err, "opts.action")).to.equal(true)
        end)

        it("errors when alc is not a table", function()
            local ok, err = pcall(M.run, {
                action = "update_dispatch_record", alc = "bad",
            })
            expect(ok).to.equal(false)
            expect(contains(err, "alc")).to.equal(true)
        end)

        it("errors on unknown action", function()
            local mock = make_alc_show_returns({ data = {} })
            local ok, err = pcall(M.run, {
                action = "rollback_step", alc = mock,
            })
            expect(ok).to.equal(false)
            expect(contains(err, "unknown action")).to.equal(true)
            expect(contains(err, "rollback_step")).to.equal(true)
        end)
    end)

    describe("update_dispatch_record validation", function()
        it("errors when namespace is missing", function()
            local mock = make_alc_show_returns({ data = {} })
            local ok, err = pcall(M.run, {
                action = "update_dispatch_record",
                alc = mock, key = "k", update = {},
            })
            expect(ok).to.equal(false)
            expect(contains(err, "namespace")).to.equal(true)
        end)

        it("errors when key is missing", function()
            local mock = make_alc_show_returns({ data = {} })
            local ok, err = pcall(M.run, {
                action = "update_dispatch_record",
                alc = mock, namespace = "ns", update = {},
            })
            expect(ok).to.equal(false)
            expect(contains(err, "key")).to.equal(true)
        end)

        it("errors when update is missing", function()
            local mock = make_alc_show_returns({ data = {} })
            local ok, err = pcall(M.run, {
                action = "update_dispatch_record",
                alc = mock, namespace = "ns", key = "k",
            })
            expect(ok).to.equal(false)
            expect(contains(err, "update")).to.equal(true)
        end)

        it("errors when update is not a table", function()
            local mock = make_alc_show_returns({ data = {} })
            local ok, err = pcall(M.run, {
                action = "update_dispatch_record",
                alc = mock, namespace = "ns", key = "k", update = "bad",
            })
            expect(ok).to.equal(false)
            expect(contains(err, "update")).to.equal(true)
        end)

        it("errors when update has non-string keys", function()
            local mock = make_alc_show_returns({ data = {} })
            local ok, err = pcall(M.run, {
                action = "update_dispatch_record",
                alc = mock, namespace = "ns", key = "k",
                update = { [1] = "bad" },
            })
            expect(ok).to.equal(false)
            expect(contains(err, "keys must be strings")).to.equal(true)
        end)

        it("errors when alc.state.show is missing", function()
            local mock = { state = { set_dispatched = function() end } }
            local ok, err = pcall(M.run, {
                action = "update_dispatch_record",
                alc = mock, namespace = "ns", key = "k",
                update = { status = "done" },
            })
            expect(ok).to.equal(false)
            expect(contains(err, "alc.state.show")).to.equal(true)
        end)

        it("errors when alc.state.set_dispatched is missing", function()
            local mock = { state = {
                show = function() return { data = {} } end,
            } }
            local ok, err = pcall(M.run, {
                action = "update_dispatch_record",
                alc = mock, namespace = "ns", key = "k",
                update = { status = "done" },
            })
            expect(ok).to.equal(false)
            expect(contains(err, "alc.state.set_dispatched")).to.equal(true)
        end)

        it("errors when alc.state.show returns nil", function()
            local mock = make_alc_show_returns(nil)
            mock.state.show = function() return nil end
            local ok, err = pcall(M.run, {
                action = "update_dispatch_record",
                alc = mock, namespace = "ns", key = "k",
                update = { status = "done" },
            })
            expect(ok).to.equal(false)
            expect(contains(err, "non-table")).to.equal(true)
            expect(contains(err, "ns/k")).to.equal(true)
        end)

        it("errors when show returns string and json_decode missing",
            function()
                local mock = {
                    state = {
                        show = function() return '{"data":{"x":1}}' end,
                        set_dispatched = function() end,
                    },
                    -- json_decode intentionally absent
                }
                local ok, err = pcall(M.run, {
                    action = "update_dispatch_record",
                    alc = mock, namespace = "ns", key = "k",
                    update = { status = "done" },
                })
                expect(ok).to.equal(false)
                expect(contains(err, "alc.json_decode is unavailable"))
                    .to.equal(true)
            end)

        it("errors when alc.json_decode fails on the show payload",
            function()
                local mock = {
                    state = {
                        show = function() return "not-valid-json{{" end,
                        set_dispatched = function() end,
                    },
                    json_decode = function(_s) error("bad json", 0) end,
                }
                local ok, err = pcall(M.run, {
                    action = "update_dispatch_record",
                    alc = mock, namespace = "ns", key = "k",
                    update = { status = "done" },
                })
                expect(ok).to.equal(false)
                expect(contains(err, "alc.json_decode failed"))
                    .to.equal(true)
            end)
    end)

    describe("update_dispatch_record happy path", function()
        it("decodes JSON string returned by alc.state.show via alc.json_decode",
            function()
                local set_calls = 0
                local last_value = nil
                local mock = {
                    state = {
                        show = function()
                            return '{"data":{"status":"pending","actor":"old"}}'
                        end,
                        set_dispatched = function(_ns, _key, value)
                            set_calls = set_calls + 1
                            last_value = value
                        end,
                    },
                    json_decode = function(s)
                        expect(s).to.equal(
                            '{"data":{"status":"pending","actor":"old"}}')
                        return { data = {
                            status = "pending", actor = "old",
                        } }
                    end,
                }
                local result = M.run({
                    action = "update_dispatch_record",
                    alc = mock, namespace = "orch",
                    key = "task_decoded",
                    update = { status = "done" },
                })
                expect(result.ok).to.equal(true)
                expect(set_calls).to.equal(1)
                expect(last_value.data.status).to.equal("done")
                expect(last_value.data.actor).to.equal("old")
            end)

        it("merges patch into state.data and writes back via set_dispatched",
            function()
                local seed = {
                    data = { status = "pending", actor = "old" },
                    identity = { task_id = "k" },
                }
                local mock, last = make_mock_alc(seed)
                local result = M.run({
                    action = "update_dispatch_record",
                    alc = mock, namespace = "orch", key = "task_abc",
                    update = { status = "done", result = "passed" },
                })
                expect(result.ok).to.equal(true)
                expect(result.namespace).to.equal("orch")
                expect(result.key).to.equal("task_abc")
                expect(#result.updated_fields).to.equal(2)
                expect(result.updated_fields[1]).to.equal("result")
                expect(result.updated_fields[2]).to.equal("status")
                expect(last.calls).to.equal(1)
                expect(last.ns).to.equal("orch")
                expect(last.key).to.equal("task_abc")
                expect(last.value.data.status).to.equal("done")
                expect(last.value.data.result).to.equal("passed")
                expect(last.value.data.actor).to.equal("old")
                expect(last.value.identity.task_id).to.equal("k")
            end)

        it("creates data table when current state lacks one", function()
            local seed = { identity = { task_id = "k" } }
            local mock, last = make_mock_alc(seed)
            local result = M.run({
                action = "update_dispatch_record",
                alc = mock, namespace = "orch", key = "task_xyz",
                update = { status = "fresh" },
            })
            expect(result.ok).to.equal(true)
            expect(last.value.data.status).to.equal("fresh")
        end)

        it("returns empty updated_fields when update table is empty",
            function()
                local seed = { data = { x = 1 } }
                local mock, last = make_mock_alc(seed)
                local result = M.run({
                    action = "update_dispatch_record",
                    alc = mock, namespace = "orch", key = "task_empty",
                    update = {},
                })
                expect(result.ok).to.equal(true)
                expect(#result.updated_fields).to.equal(0)
                expect(last.calls).to.equal(1)
                expect(last.value.data.x).to.equal(1)
            end)
    end)

    describe("opts.alc seam", function()
        it("uses _G.alc when opts.alc is omitted", function()
            local seed = { data = {} }
            local saved = _G.alc
            local writes = 0
            _G.alc = {
                state = {
                    show = function() return seed end,
                    set_dispatched = function() writes = writes + 1 end,
                },
            }
            local result = M.run({
                action = "update_dispatch_record",
                namespace = "ns", key = "k",
                update = { a = 1 },
            })
            _G.alc = saved
            expect(result.ok).to.equal(true)
            expect(writes).to.equal(1)
        end)
    end)
end)

describe("swarm_host_alc.state_method.meta", function()
    it("declares pkg version", function()
        expect(M.meta.version).to.equal("0.0.1-v3-p5")
        expect(M.VERSION).to.equal("0.0.1-v3-p5")
    end)

    it("declares category=state_method", function()
        expect(M.meta.category).to.equal("state_method")
    end)
end)
