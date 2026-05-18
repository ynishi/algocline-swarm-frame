-- parse_label_verdict_spec.lua — Tests for the v0.4 BLOCKED L-shape extension.
--
-- Issue: 1779065252-8162 — Frame primitive for rich BLOCKED payload.
--
-- Covers:
--   * Legacy back-compat (no opts / opts.structured = false)
--   * opts.structured = true L-shape (verdict / next_action / reason)
--   * 3 standard next_action values (retry / escalate / halt)
--   * custom next_action string pass-through
--   * label-specific defaults when next_action field is absent
--   * reason extraction (line-form + JSON-form)
--   * no-match returns table with all-nil fields (still inspectable)

local frame = require("swarm_frame")
local describe, it, expect = lust.describe, lust.it, lust.expect

describe("parse_label_verdict — L-shape (v0.4)", function()
    -- ─── Legacy back-compat ──────────────────────────────────────────────

    describe("legacy mode (opts.structured = false)", function()
        it("returns label string when no opts is given", function()
            local v = frame.parse_label_verdict("VERDICT: BLOCKED", { "BLOCKED", "PASS" })
            expect(v).to.equal("BLOCKED")
        end)

        it("returns label string when opts.structured = false", function()
            local v = frame.parse_label_verdict("VERDICT: PASS", { "BLOCKED", "PASS" }, { structured = false })
            expect(v).to.equal("PASS")
        end)

        it("returns nil when no label matches and structured is off", function()
            local v = frame.parse_label_verdict("nothing", { "BLOCKED", "PASS" })
            expect(v).to.equal(nil)
        end)
    end)

    -- ─── structured mode shape ──────────────────────────────────────────

    describe("structured mode (opts.structured = true)", function()
        it("returns a table with verdict/next_action/reason fields", function()
            local v = frame.parse_label_verdict(
                "VERDICT: BLOCKED\nnext_action: retry\nreason: transient_io",
                { "BLOCKED", "PASS" },
                { structured = true }
            )
            expect(type(v)).to.equal("table")
            expect(v.verdict).to.equal("BLOCKED")
            expect(v.next_action).to.equal("retry")
            expect(v.reason).to.equal("transient_io")
        end)

        it("returns all-nil table when no label matches", function()
            local v = frame.parse_label_verdict("nothing", { "BLOCKED", "PASS" }, { structured = true })
            expect(type(v)).to.equal("table")
            expect(v.verdict).to.equal(nil)
            expect(v.next_action).to.equal(nil)
            expect(v.reason).to.equal(nil)
        end)
    end)

    -- ─── 3 standard next_action values ──────────────────────────────────

    describe("standard next_action values", function()
        it("extracts retry", function()
            local v = frame.parse_label_verdict(
                "VERDICT: BLOCKED\nnext_action: retry",
                { "BLOCKED" },
                { structured = true }
            )
            expect(v.next_action).to.equal("retry")
        end)

        it("extracts escalate", function()
            local v = frame.parse_label_verdict(
                "VERDICT: NEEDS_HUMAN\nnext_action: escalate",
                { "NEEDS_HUMAN" },
                { structured = true }
            )
            expect(v.next_action).to.equal("escalate")
        end)

        it("extracts halt", function()
            local v = frame.parse_label_verdict(
                "VERDICT: BLOCKED\nnext_action: halt",
                { "BLOCKED" },
                { structured = true }
            )
            expect(v.next_action).to.equal("halt")
        end)
    end)

    -- ─── custom string pass-through ─────────────────────────────────────

    describe("custom next_action string", function()
        it("passes through a non-standard token", function()
            local v = frame.parse_label_verdict(
                "VERDICT: BLOCKED\nnext_action: wait_dependency",
                { "BLOCKED" },
                { structured = true }
            )
            expect(v.next_action).to.equal("wait_dependency")
        end)

        it("preserves casing of custom string", function()
            local v = frame.parse_label_verdict(
                "VERDICT: BLOCKED\nnext_action: WaitForPRMerge",
                { "BLOCKED" },
                { structured = true }
            )
            expect(v.next_action).to.equal("WaitForPRMerge")
        end)
    end)

    -- ─── default fallback when next_action absent ───────────────────────

    describe("label-specific default fallback", function()
        it("BLOCKED without next_action defaults to halt", function()
            local v = frame.parse_label_verdict("VERDICT: BLOCKED", { "BLOCKED" }, { structured = true })
            expect(v.verdict).to.equal("BLOCKED")
            expect(v.next_action).to.equal("halt")
        end)

        it("NEEDS_HUMAN without next_action defaults to escalate", function()
            local v = frame.parse_label_verdict("VERDICT: NEEDS_HUMAN", { "NEEDS_HUMAN" }, { structured = true })
            expect(v.verdict).to.equal("NEEDS_HUMAN")
            expect(v.next_action).to.equal("escalate")
        end)

        it("PASS without next_action stays nil (no forced next step)", function()
            local v = frame.parse_label_verdict("VERDICT: PASS", { "PASS" }, { structured = true })
            expect(v.verdict).to.equal("PASS")
            expect(v.next_action).to.equal(nil)
        end)
    end)

    -- ─── reason extraction ──────────────────────────────────────────────

    describe("reason extraction", function()
        it("extracts line-form reason", function()
            local v = frame.parse_label_verdict(
                "VERDICT: BLOCKED\nreason: missing upstream PR",
                { "BLOCKED" },
                { structured = true }
            )
            expect(v.reason).to.equal("missing upstream PR")
        end)

        it("extracts JSON-form reason", function()
            local v = frame.parse_label_verdict(
                'VERDICT: BLOCKED { "reason": "missing api key", "next_action": "halt" }',
                { "BLOCKED" },
                { structured = true }
            )
            expect(v.reason).to.equal("missing api key")
            expect(v.next_action).to.equal("halt")
        end)

        it("returns nil reason when absent", function()
            local v = frame.parse_label_verdict("VERDICT: BLOCKED", { "BLOCKED" }, { structured = true })
            expect(v.reason).to.equal(nil)
        end)
    end)
end)

describe("parse_verdict — next_action JSON pickup (v0.4)", function()
    it("picks up next_action from JSON payload", function()
        local v = frame.parse_verdict('{"status":"BLOCKED","reason":"x","next_action":"retry"}')
        expect(v.status).to.equal("BLOCKED")
        expect(v.next_action).to.equal("retry")
    end)

    it("leaves next_action nil when JSON omits the field", function()
        local v = frame.parse_verdict('{"status":"DONE","path":"/pkg/step_1"}')
        expect(v.next_action).to.equal(nil)
    end)

    it("legacy text BLOCKED has no next_action (caller default applies)", function()
        local v = frame.parse_verdict("BLOCKED reason=needs_review")
        expect(v.status).to.equal("BLOCKED")
        expect(v.next_action).to.equal(nil)
    end)
end)

describe("run_linear — next_action flow to ctx.result (v0.4)", function()
    local function reset()
        frame._reset_for_testing()
        frame._reset_host_for_testing()
        local reg = frame._registry()
        for k in pairs(reg) do
            frame.unregister(k)
        end
    end
    lust.before(function() reset() end)
    lust.after(function() reset() end)

    it("flows next_action from JSON verdict to ctx.result", function()
        frame.register("/pkg/step_x/agent", {})
        local s = frame.state_new()
        local ctx = {
            state = s,
            dispatcher = function(path, spec, c)
                return '{"status":"BLOCKED","reason":"upstream","next_action":"retry"}'
            end,
        }
        frame.run_linear({ "/pkg/step_x/agent" }, ctx)
        expect(ctx.result.status).to.equal("BLOCKED")
        expect(ctx.result.next_action).to.equal("retry")
    end)

    it("applies BLOCKED → halt default when text verdict omits next_action", function()
        frame.register("/pkg/step_y/agent", {})
        local s = frame.state_new()
        local ctx = {
            state = s,
            dispatcher = function(path, spec, c) return "BLOCKED reason=external_dep" end,
        }
        frame.run_linear({ "/pkg/step_y/agent" }, ctx)
        expect(ctx.result.status).to.equal("BLOCKED")
        expect(ctx.result.next_action).to.equal("halt")
    end)

    it("applies NEEDS_INPUT → escalate default", function()
        frame.register("/pkg/step_z/agent", {})
        local s = frame.state_new()
        local ctx = {
            state = s,
            dispatcher = function(path, spec, c) return "NEEDS_INPUT missing=api_key" end,
        }
        frame.run_linear({ "/pkg/step_z/agent" }, ctx)
        expect(ctx.result.status).to.equal("NEEDS_INPUT")
        expect(ctx.result.next_action).to.equal("escalate")
    end)
end)
