-- check_mode_spec.lua — Boundary regression spec for
-- swarm_host_alc.check_mode (P5 step 5).
--
-- Two helpers under test:
--   route_llm(prompt, llm_opts, slot, deps) -> response
--   format_postverify(response, step, deps) -> response | BLOCKED_str

local lust = require("lust")
local describe, it, expect = lust.describe, lust.it, lust.expect

local cm = require("swarm_host_alc.check_mode")

local function contains(s, sub)
    return type(s) == "string" and string.find(s, sub, 1, true) ~= nil
end

local function fake_json_decode(s)
    -- Test-only stub: accepts a literal string '{"status":"ok","flow_token":"t","flow_slot":"s1"}'
    -- and returns a fixed table; anything else returns nil to simulate parse failure.
    if s == '{"status":"ok","flow_token":"t","flow_slot":"s1"}' then
        return { status = "ok", flow_token = "t", flow_slot = "s1" }
    end
    if s == '{"status":"ok","flow_token":"t","flow_slot":"s_other"}' then
        return { status = "ok", flow_token = "t", flow_slot = "s_other" }
    end
    if s == '{"status":"","flow_token":"t","flow_slot":"s1"}' then
        return { status = "", flow_token = "t", flow_slot = "s1" }
    end
    if s == '{"flow_token":"t","flow_slot":"s1"}' then
        return { flow_token = "t", flow_slot = "s1" }
    end
    if s == '{"status":"ok","flow_slot":"s1"}' then
        return { status = "ok", flow_slot = "s1" }
    end
    if s == '{"status":"ok","flow_token":"t"}' then
        return { status = "ok", flow_token = "t" }
    end
    error("parse failed", 0)
end

-- ─── route_llm ────────────────────────────────────────────────────────

describe("swarm_host_alc.check_mode.route_llm", function()
    it("non-check mode routes through alc.llm", function()
        local seen_prompt, seen_opts
        local deps = {
            mode = "non-check",
            alc = {
                llm = function(prompt, opts)
                    seen_prompt = prompt
                    seen_opts = opts
                    return "alc-response"
                end,
            },
        }
        local got = cm.route_llm("p1", { max_tokens = 50 }, "s1", deps)
        expect(got).to.equal("alc-response")
        expect(seen_prompt).to.equal("p1")
        expect(seen_opts.max_tokens).to.equal(50)
    end)

    it("strict mode routes through flow.llm_bound with state + slot",
        function()
            local seen_state, seen_opts
            local deps = {
                mode = "strict",
                state = { my = "state" },
                flow = {
                    llm_bound = function(state, opts)
                        seen_state = state
                        seen_opts = opts
                        return "flow-response"
                    end,
                },
            }
            local got = cm.route_llm("p2", { system = "S" }, "s2", deps)
            expect(got).to.equal("flow-response")
            expect(seen_state.my).to.equal("state")
            expect(seen_opts.slot).to.equal("s2")
            expect(seen_opts.prompt).to.equal("p2")
            expect(seen_opts.llm_opts.system).to.equal("S")
        end)

    it("format mode routes through flow.llm_bound (same as strict)",
        function()
            local hit = false
            local deps = {
                mode = "format",
                state = {},
                flow = {
                    llm_bound = function(_state, _opts) hit = true; return "x" end,
                },
            }
            cm.route_llm("p", nil, "s", deps)
            expect(hit).to.equal(true)
        end)

    it("errors when deps is missing", function()
        local ok, err = pcall(cm.route_llm, "p", nil, "s", nil)
        expect(ok).to.equal(false)
        expect(contains(err, "deps")).to.equal(true)
    end)

    it("errors when deps.mode is missing", function()
        local ok, err = pcall(cm.route_llm, "p", nil, "s", {})
        expect(ok).to.equal(false)
        expect(contains(err, "deps.mode")).to.equal(true)
    end)

    it("errors when non-check mode but alc.llm is missing", function()
        local ok, err = pcall(cm.route_llm, "p", nil, "s",
            { mode = "non-check" })
        expect(ok).to.equal(false)
        expect(contains(err, "alc.llm")).to.equal(true)
    end)

    it("errors when strict mode but flow.llm_bound is missing", function()
        local ok, err = pcall(cm.route_llm, "p", nil, "s",
            { mode = "strict", state = {} })
        expect(ok).to.equal(false)
        expect(contains(err, "flow.llm_bound")).to.equal(true)
    end)
end)

-- ─── format_postverify ────────────────────────────────────────────────

describe("swarm_host_alc.check_mode.format_postverify", function()
    local deps = { json_decode = fake_json_decode }

    it("returns the raw response on PASS", function()
        local resp = '{"status":"ok","flow_token":"t","flow_slot":"s1"}'
        expect(cm.format_postverify(resp, "s1", deps)).to.equal(resp)
    end)

    it("returns BLOCKED format-non-json when no JSON object in response",
        function()
            local got = cm.format_postverify("plain text", "s1", deps)
            expect(contains(got, "BLOCKED")).to.equal(true)
            expect(contains(got, "format-non-json")).to.equal(true)
            expect(contains(got, "slot=s1")).to.equal(true)
        end)

    it("returns BLOCKED format-json-parse-error when JSON is malformed",
        function()
            local got = cm.format_postverify('{not-json}', "s1", deps)
            expect(contains(got, "BLOCKED")).to.equal(true)
            expect(contains(got, "format-json-parse-error")).to.equal(true)
        end)

    it("returns BLOCKED format-missing-status when status is empty",
        function()
            local got = cm.format_postverify(
                '{"status":"","flow_token":"t","flow_slot":"s1"}', "s1", deps)
            expect(contains(got, "format-missing-status")).to.equal(true)
        end)

    it("returns BLOCKED format-missing-status when status key absent",
        function()
            local got = cm.format_postverify(
                '{"flow_token":"t","flow_slot":"s1"}', "s1", deps)
            expect(contains(got, "format-missing-status")).to.equal(true)
        end)

    it("returns BLOCKED format-missing-flow-token when key absent",
        function()
            local got = cm.format_postverify(
                '{"status":"ok","flow_slot":"s1"}', "s1", deps)
            expect(contains(got, "format-missing-flow-token")).to.equal(true)
        end)

    it("returns BLOCKED format-missing-flow-slot when key absent",
        function()
            local got = cm.format_postverify(
                '{"status":"ok","flow_token":"t"}', "s1", deps)
            expect(contains(got, "format-missing-flow-slot")).to.equal(true)
        end)

    it("returns BLOCKED format-flow-slot-mismatch when slot differs",
        function()
            local got = cm.format_postverify(
                '{"status":"ok","flow_token":"t","flow_slot":"s_other"}',
                "s1", deps)
            expect(contains(got, "format-flow-slot-mismatch")).to.equal(true)
            expect(contains(got, "expected=s1")).to.equal(true)
            expect(contains(got, "got=s_other")).to.equal(true)
        end)

    it("errors when deps.json_decode is missing", function()
        local ok, err = pcall(cm.format_postverify, "x", "s1", {})
        expect(ok).to.equal(false)
        expect(contains(err, "json_decode")).to.equal(true)
    end)
end)
