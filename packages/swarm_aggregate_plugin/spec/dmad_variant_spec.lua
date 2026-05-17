-- dmad_variant_spec.lua — run_dmad dispatch chain + return shape spec
--
-- DSL 規約: lust global は alc_pkg_test runner が auto-inject する。
-- package.path 手動設定禁止 (§8-7-36)。
--
-- opts.alc / opts.frame / opts.sfa / opts.dmad / opts.flow をすべて mock 注入し、
-- 実 LLM / 実 dmad pkg / 実 flow pkg に依存せず走る。

local agg = require("swarm_aggregate_plugin")
local frame = require("swarm_frame")
local sfa = require("swarm_frame_algocline")
local describe, it, expect = lust.describe, lust.it, lust.expect

-- ─── helpers ────────────────────────────────────────────────────────

-- Plain-substring assertion (lust API has no `.contain`).
local function contains(s, sub) return type(s) == "string" and string.find(s, sub, 1, true) ~= nil end

-- Stub flow: non-check mode does not invoke flow.llm_bound, but
-- sfa.make_dispatcher evaluates `opts.flow or require("flow")` regardless.
-- Inject a non-nil stub to bypass the require lookup (flow pkg is in
-- ~/.algocline/packages, outside the alc_pkg_test VM's package.path).
local stub_flow = {
    llm_bound = function(_state, _slot_opts) error("stub_flow.llm_bound should not be invoked in non-check mode") end,
}

-- ─── mock builders ──────────────────────────────────────────────────

local function make_mock_dmad()
    return {
        build_init_prompt = function(o) return { prompt = "INIT:" .. (o.task or ""), system = "" } end,
        build_debate_prompt = function(_o) return { prompt = "DEBATE" } end,
        aggregate_majority = function(o)
            local first = (o.answers and o.answers[1]) or ""
            return { answer = first, tally = {} }
        end,
        extract_boxed = function(o) return o.text or "" end,
    }
end

local function make_mock_alc()
    local count = 0
    return {
        llm = function(_prompt, _opts)
            count = count + 1
            return "AGENT_RESPONSE_" .. count
        end,
        log = function(_level, _msg) end,
        -- expose counter for assertions
        _count = function() return count end,
    }
end

-- ─── specs ──────────────────────────────────────────────────────────

describe("run_dmad", function()
    -- ----------------------------------------------------------------
    -- validation
    -- ----------------------------------------------------------------

    describe("validation", function()
        it("errors when opts is not a table", function()
            local ok, err = pcall(agg.run_dmad, "bad")
            expect(ok).to.equal(false)
            expect(contains(err, "opts table required")).to.equal(true)
        end)

        it("errors when task is missing", function()
            local ok, err = pcall(agg.run_dmad, {})
            expect(ok).to.equal(false)
            expect(contains(err, "task")).to.equal(true)
        end)

        it("errors when task is empty string", function()
            local ok, err = pcall(agg.run_dmad, { task = "" })
            expect(ok).to.equal(false)
            expect(contains(err, "task")).to.equal(true)
        end)
    end)

    -- ----------------------------------------------------------------
    -- dispatch chain: n_agents=2, n_rounds=1
    -- ----------------------------------------------------------------

    describe("dispatch chain with mock injection", function()
        it("routes LLM calls through injected sfa / dmad and returns correct shape", function()
            frame._reset_for_testing()
            frame.init({ check_mode = "non-check" })

            local mock_alc = make_mock_alc()
            local mock_dmad = make_mock_dmad()

            local r = agg.run_dmad({
                task = "test task",
                n_agents = 2,
                n_rounds = 1,
                frame = frame,
                sfa = sfa,
                dmad = mock_dmad,
                alc = mock_alc,
                flow = stub_flow,
            })

            -- return shape
            expect(type(r.answer)).to.equal("string")
            expect(r.n_agents).to.equal(2)
            expect(r.n_rounds).to.equal(1)
            expect(type(r.total_llm_calls)).to.equal("number")
            expect(type(r.responses)).to.equal("table")
            expect(type(r.last_answers)).to.equal("table")
            expect(type(r.tally)).to.equal("table")
            expect(type(r.transcript)).to.equal("table")
        end)

        it("calls LLM n_agents * (n_rounds + 1) times", function()
            frame._reset_for_testing()
            frame.init({ check_mode = "non-check" })

            local call_count = 0
            local counting_alc = {
                llm = function(_p, _o)
                    call_count = call_count + 1
                    return "R"
                end,
                log = function() end,
            }

            agg.run_dmad({
                task = "counting task",
                n_agents = 3,
                n_rounds = 2,
                frame = frame,
                sfa = sfa,
                dmad = make_mock_dmad(),
                alc = counting_alc,
                flow = stub_flow,
            })

            -- round 0: 3 calls; round 1: 3 calls; round 2: 3 calls → 9 total
            expect(call_count).to.equal(9)
        end)

        it("fills responses[r+1][i] shape", function()
            frame._reset_for_testing()
            frame.init({ check_mode = "non-check" })

            local r = agg.run_dmad({
                task = "shape test",
                n_agents = 2,
                n_rounds = 1,
                frame = frame,
                sfa = sfa,
                dmad = make_mock_dmad(),
                alc = make_mock_alc(),
                flow = stub_flow,
            })

            -- responses[1] = round 0, responses[2] = round 1
            expect(type(r.responses[1])).to.equal("table")
            expect(type(r.responses[2])).to.equal("table")
            expect(#r.last_answers).to.equal(2)
        end)

        it("transcript has one entry per LLM call", function()
            frame._reset_for_testing()
            frame.init({ check_mode = "non-check" })

            local r = agg.run_dmad({
                task = "transcript test",
                n_agents = 2,
                n_rounds = 1,
                frame = frame,
                sfa = sfa,
                dmad = make_mock_dmad(),
                alc = make_mock_alc(),
                flow = stub_flow,
            })

            -- 2 agents × (1+1) rounds = 4 calls
            expect(#r.transcript).to.equal(4)
            -- each entry has agent / round / step / text fields
            local entry = r.transcript[1]
            expect(type(entry.agent)).to.equal("number")
            expect(type(entry.round)).to.equal("number")
            expect(type(entry.step)).to.equal("string")
            expect(type(entry.text)).to.equal("string")
        end)
    end)

    -- ----------------------------------------------------------------
    -- run() variant dispatch
    -- ----------------------------------------------------------------

    describe("run() variant dispatch", function()
        it("routes ctx.variant='dmad' to run_dmad", function()
            frame._reset_for_testing()
            frame.init({ check_mode = "non-check" })

            local r = agg.run({
                task = "via run()",
                n_agents = 2,
                n_rounds = 1,
                variant = "dmad",
                frame = frame,
                sfa = sfa,
                dmad = make_mock_dmad(),
                alc = make_mock_alc(),
                flow = stub_flow,
            })

            expect(type(r.answer)).to.equal("string")
            expect(r.n_agents).to.equal(2)
        end)

        it("defaults to dmad when variant is absent", function()
            frame._reset_for_testing()
            frame.init({ check_mode = "non-check" })

            local r = agg.run({
                task = "default variant",
                n_agents = 2,
                n_rounds = 1,
                frame = frame,
                sfa = sfa,
                dmad = make_mock_dmad(),
                alc = make_mock_alc(),
                flow = stub_flow,
            })

            expect(type(r.answer)).to.equal("string")
        end)

        it("errors on unknown variant", function()
            local ok, err = pcall(agg.run, {
                task = "bad variant",
                variant = "unknown_algo",
            })
            expect(ok).to.equal(false)
            expect(contains(err, "unknown variant")).to.equal(true)
        end)
    end)
end)
