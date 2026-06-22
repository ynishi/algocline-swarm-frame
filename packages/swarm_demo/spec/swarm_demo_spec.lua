-- swarm_demo_spec.lua — Boundary + integration spec for swarm_demo.
--
-- Coverage:
--   * opts validation (table / task / alc.llm)
--   * 3 Agent linear flow with mock alc.llm
--   * prompt threading (Researcher → Drafter → Reviewer)
--   * verdict parser (OK / NG / UNKNOWN)
--   * minimal flow shim auto-injection
--
-- Run via: lua tests/run.lua (or just test).

local lust = require("lust")
local describe, it, expect = lust.describe, lust.it, lust.expect

local demo = require("swarm_demo")

local function contains(s, sub)
    return type(s) == "string" and string.find(s, sub, 1, true) ~= nil
end

-- Mock alc.llm helper: handler returns response based on call index.
local function with_mock_alc(handler, fn)
    local original_alc = _G.alc
    local original_flow = _G.flow
    local log = {}
    _G.alc = {
        llm = function(prompt, _opts)
            table.insert(log, prompt)
            return handler(prompt, #log)
        end,
        log = function() end,
        json_decode = function() return {} end,
    }
    _G.flow = nil -- force minimal shim path
    local ok, result_or_err = pcall(fn, log)
    _G.alc = original_alc
    _G.flow = original_flow
    if not ok then error(result_or_err) end
    return result_or_err, log
end

-- ─── opts validation ─────────────────────────────────────────────────

describe("swarm_demo.run — opts validation", function()
    it("errors when opts is not a table", function()
        local ok, err = pcall(demo.run, "bad")
        expect(ok).to.equal(false)
        expect(contains(err, "opts table required")).to.equal(true)
    end)

    it("errors when opts.task is missing", function()
        local ok, err = pcall(demo.run, {})
        expect(ok).to.equal(false)
        expect(contains(err, "task")).to.equal(true)
    end)

    it("errors when opts.task is non-string", function()
        local ok, err = pcall(demo.run, { task = 42 })
        expect(ok).to.equal(false)
        expect(contains(err, "task")).to.equal(true)
    end)

    it("errors when alc.llm is unavailable", function()
        local original_alc = _G.alc
        _G.alc = nil
        local ok, err = pcall(demo.run, { task = "T" })
        expect(ok).to.equal(false)
        expect(contains(err, "alc.llm")).to.equal(true)
        _G.alc = original_alc
    end)
end)

-- ─── 3-Agent linear flow ─────────────────────────────────────────────

describe("swarm_demo.run — 3-Agent linear flow", function()
    it("calls Researcher → Drafter → Reviewer in order (3 LLM calls)",
        function()
            local result, log = with_mock_alc(function(_prompt, idx)
                if idx == 1 then return "- alpha\n- beta\n- gamma" end
                if idx == 2 then return "Draft body.\nSWARM_DEMO_END" end
                if idx == 3 then return "OK: clear and concise." end
                return "ERR"
            end, function(_log)
                return demo.run({ task = "Explain X." })
            end)
            expect(#log).to.equal(3)
            expect(result.ok).to.equal(true)
            expect(result.verdict).to.equal("OK")
            expect(contains(result.research, "alpha")).to.equal(true)
            expect(contains(result.draft, "Draft body")).to.equal(true)
            expect(contains(result.review, "OK:")).to.equal(true)
        end)

    it("threads Researcher output into Drafter prompt", function()
        local _result, log = with_mock_alc(function(_prompt, idx)
            if idx == 1 then return "RESEARCH_TOKEN_X" end
            if idx == 2 then return "draft\nSWARM_DEMO_END" end
            if idx == 3 then return "OK: yes" end
            return "ERR"
        end, function(_log)
            return demo.run({ task = "T" })
        end)
        -- log[2] = Drafter prompt; it must embed Researcher's output.
        expect(contains(log[2], "RESEARCH_TOKEN_X")).to.equal(true)
    end)

    it("threads Drafter output into Reviewer prompt", function()
        local _result, log = with_mock_alc(function(_prompt, idx)
            if idx == 1 then return "research" end
            if idx == 2 then return "DRAFT_TOKEN_Y\nSWARM_DEMO_END" end
            if idx == 3 then return "OK: yes" end
            return "ERR"
        end, function(_log)
            return demo.run({ task = "T" })
        end)
        expect(contains(log[3], "DRAFT_TOKEN_Y")).to.equal(true)
    end)
end)

-- ─── verdict parser ──────────────────────────────────────────────────

describe("swarm_demo.run — verdict parser", function()
    it("returns ok=false / verdict=NG when Reviewer rejects", function()
        local result, _log = with_mock_alc(function(_prompt, idx)
            if idx == 1 then return "research" end
            if idx == 2 then return "draft\nSWARM_DEMO_END" end
            if idx == 3 then return "NG: too short" end
            return "ERR"
        end, function(_log)
            return demo.run({ task = "T" })
        end)
        expect(result.ok).to.equal(false)
        expect(result.verdict).to.equal("NG")
    end)

    it("returns verdict=UNKNOWN when Reviewer response is malformed",
        function()
            local result, _log = with_mock_alc(function(_prompt, idx)
                if idx == 1 then return "research" end
                if idx == 2 then return "draft\nSWARM_DEMO_END" end
                if idx == 3 then return "I'm not sure what to say" end
                return "ERR"
            end, function(_log)
                return demo.run({ task = "T" })
            end)
            expect(result.ok).to.equal(false)
            expect(result.verdict).to.equal("UNKNOWN")
        end)

    it("_for_test.parse_verdict standalone — OK / NG / UNKNOWN", function()
        local pv = demo._for_test.parse_verdict
        expect(pv("OK: foo")).to.equal("OK")
        expect(pv("OK foo")).to.equal("OK")
        expect(pv("NG: bar")).to.equal("NG")
        expect(pv("NG bar")).to.equal("NG")
        expect(pv("maybe")).to.equal("UNKNOWN")
        expect(pv(nil)).to.equal("UNKNOWN")
        expect(pv("")).to.equal("UNKNOWN")
    end)
end)

-- ─── prompt templates ────────────────────────────────────────────────

describe("swarm_demo prompts — role-specific content", function()
    it("Researcher prompt mentions task and 3 bullets", function()
        local p = demo._for_test.researcher_prompt({ task = "Topic Z" })
        expect(contains(p, "Topic Z")).to.equal(true)
        expect(contains(p, "Researcher")).to.equal(true)
        expect(contains(p, "3")).to.equal(true)
    end)

    it("Drafter prompt embeds research notes + sentinel instruction",
        function()
            local p = demo._for_test.drafter_prompt({
                task = "T",
                research = "RES_X",
            })
            expect(contains(p, "RES_X")).to.equal(true)
            expect(contains(p, "Drafter")).to.equal(true)
            expect(contains(p, "SWARM_DEMO_END")).to.equal(true)
        end)

    it("Reviewer prompt embeds draft + asks for OK/NG one-liner",
        function()
            local p = demo._for_test.reviewer_prompt({
                task = "T",
                draft = "DRA_Y",
            })
            expect(contains(p, "DRA_Y")).to.equal(true)
            expect(contains(p, "Reviewer")).to.equal(true)
            expect(contains(p, "OK:")).to.equal(true)
            expect(contains(p, "NG:")).to.equal(true)
        end)
end)
