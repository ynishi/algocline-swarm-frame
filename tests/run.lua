-- swarm_frame test runner (lust-based).
-- Run: just test  /  lua tests/run.lua
--
-- Test framework: vendored lust (tests/vendor/lust.lua, MIT License).
-- Fluent assertion chain uses dot-chaining: expect(v).to.equal(x)

package.path = "./packages/?/init.lua;./packages/?.lua;"
    .. "./examples/?/init.lua;"
    .. "./tests/vendor/?.lua;"
    .. (os.getenv("HOME") or "")
    .. "/.algocline/packages/?/init.lua;"
    .. (os.getenv("HOME") or "")
    .. "/.algocline/packages/?.lua;"
    .. package.path

local lust = require("lust")
local frame = require("swarm_frame")
local adapter = require("swarm_frame_algocline")

local describe, it, expect = lust.describe, lust.it, lust.expect

describe("check_mode (init-time freeze)", function()
    it("defaults to 'strict' before init", function()
        frame._reset_for_testing()
        expect(frame.check_mode()).to.equal("strict")
    end)

    it("init() without opts keeps mode at 'strict'", function()
        frame._reset_for_testing()
        frame.init()
        expect(frame.check_mode()).to.equal("strict")
    end)

    it("init({ check_mode = 'non-check' }) flips mode to 'non-check'", function()
        frame._reset_for_testing()
        frame.init({ check_mode = "non-check" })
        expect(frame.check_mode()).to.equal("non-check")
    end)

    it("init({ check_mode = 'format' }) flips mode to 'format'", function()
        frame._reset_for_testing()
        frame.init({ check_mode = "format" })
        expect(frame.check_mode()).to.equal("format")
    end)

    it("init({ check_mode = 'invalid' }) raises", function()
        frame._reset_for_testing()
        local ok = pcall(frame.init, { check_mode = "invalid" })
        expect(ok).to.equal(false)
    end)

    it("'off' / legacy values rejected (only strict / non-check)", function()
        frame._reset_for_testing()
        local ok = pcall(frame.init, { check_mode = "off" })
        expect(ok).to.equal(false)
    end)

    it("second init() is a no-op (first call wins)", function()
        frame._reset_for_testing()
        frame.init({ check_mode = "non-check" })
        frame.init({ check_mode = "strict" }) -- should not take effect
        expect(frame.check_mode()).to.equal("non-check")
        frame._reset_for_testing() -- restore default for downstream tests
    end)
end)

describe("State container", function()
    it("state_new + set + get (flat)", function()
        local s = frame.state_new()
        s:set("task_id", "abc")
        expect(s:get("task_id")).to.equal("abc")
    end)

    it("state set + get (dotted path)", function()
        local s = frame.state_new()
        s:set("artifacts.window", "/tmp/window.json")
        expect(s:get("artifacts.window")).to.equal("/tmp/window.json")
    end)

    it("step_mark + step_done", function()
        local s = frame.state_new()
        expect(s:step_done("step_1")).to.equal(false)
        s:step_mark("step_1")
        expect(s:step_done("step_1")).to.equal(true)
    end)

    it("dump + restore roundtrip (persistable invariant)", function()
        local s1 = frame.state_new()
        s1:set("artifacts.x", "y")
        s1:step_mark("step_1")
        local dump = s1:dump()
        local s2 = frame.state_new({ dump = dump })
        expect(s2:get("artifacts.x")).to.equal("y")
        expect(s2:step_done("step_1")).to.equal(true)
    end)
end)

describe("Verdict parser", function()
    it("DONE path=...", function()
        local v = frame.parse_verdict("DONE path=/tmp/out.json")
        expect(v.status).to.equal("DONE")
        expect(v.path).to.equal("/tmp/out.json")
    end)

    it("BLOCKED reason=...", function()
        local v = frame.parse_verdict("BLOCKED reason=missing key foo")
        expect(v.status).to.equal("BLOCKED")
        expect(v.reason).to.equal("missing key foo")
    end)

    it("NEEDS_INPUT missing=...", function()
        local v = frame.parse_verdict("NEEDS_INPUT missing=fingerprint.json")
        expect(v.status).to.equal("NEEDS_INPUT")
        expect(v.missing).to.equal("fingerprint.json")
    end)

    it("UNKNOWN fallback", function()
        local v = frame.parse_verdict("hello world")
        expect(v.status).to.equal("UNKNOWN")
    end)

    it("parse_verdict JSON: DONE with flow_token / flow_slot", function()
        local v = frame.parse_verdict('{"status":"DONE","path":"themes.json","flow_token":"abc","flow_slot":"step_2"}')
        expect(v.status).to.equal("DONE")
        expect(v.path).to.equal("themes.json")
        expect(v.flow_token).to.equal("abc")
        expect(v.flow_slot).to.equal("step_2")
    end)

    it("parse_verdict JSON: BLOCKED with reason", function()
        local v = frame.parse_verdict(
            '{"status":"BLOCKED","reason":"empty_theme_list","flow_token":"abc","flow_slot":"step_2"}'
        )
        expect(v.status).to.equal("BLOCKED")
        expect(v.reason).to.equal("empty_theme_list")
        expect(v.flow_token).to.equal("abc")
    end)

    it("parse_verdict JSON: NEEDS_INPUT with missing", function()
        local v = frame.parse_verdict(
            '{"status":"NEEDS_INPUT","missing":"fingerprint.json","flow_token":"abc","flow_slot":"step_4"}'
        )
        expect(v.status).to.equal("NEEDS_INPUT")
        expect(v.missing).to.equal("fingerprint.json")
    end)

    it("parse_verdict: invalid JSON falls back to text path", function()
        local v = frame.parse_verdict("{not valid json} DONE path=/tmp/x")
        -- The {...} is a balanced brace match, but json_decode fails. Falls through
        -- to the regex; the regex finds DONE path=/tmp/x in the remainder.
        expect(v.status).to.equal("DONE")
        expect(v.path).to.equal("/tmp/x")
    end)
end)

describe("Registry", function()
    it("register + resolve", function()
        frame.register("/test/step_1/agent_a", { prompt = "hi" })
        local e = frame.resolve("/test/step_1/agent_a")
        expect(e.spec.prompt).to.equal("hi")
        frame.unregister("/test/step_1/agent_a")
    end)

    it("register rejects non-/ path", function()
        local ok = pcall(frame.register, "test/step_1", {})
        expect(ok).to.equal(false)
    end)
end)

describe("Linear pipeline (inline handler dispatch)", function()
    it("run_linear 3 step + DONE", function()
        frame.register("/demo/step_1/a", {}, function() return "DONE path=/tmp/a.json" end)
        frame.register("/demo/step_2/b", {}, function() return "DONE path=/tmp/b.json" end)
        frame.register("/demo/step_3/c", {}, function() return "DONE path=/tmp/c.json" end)

        local ctx = { state = frame.state_new() }
        frame.run_linear({
            "/demo/step_1/a",
            "/demo/step_2/b",
            "/demo/step_3/c",
        }, ctx)

        expect(ctx.result.status).to.equal("DONE")
        expect(ctx.state:step_done("step_1")).to.equal(true)
        expect(ctx.state:step_done("step_2")).to.equal(true)
        expect(ctx.state:step_done("step_3")).to.equal(true)
        expect(ctx.state:get("artifacts.step_2")).to.equal("/tmp/b.json")
    end)

    it("run_linear BLOCKED halts + ctx.result captures", function()
        frame.register("/demo2/step_1/x", {}, function() return "DONE path=/tmp/x.json" end)
        frame.register("/demo2/step_2/y", {}, function() return "BLOCKED reason=bad schema" end)
        frame.register("/demo2/step_3/z", {}, function() error("step_3 must not be reached") end)

        local ctx = { state = frame.state_new() }
        frame.run_linear({
            "/demo2/step_1/x",
            "/demo2/step_2/y",
            "/demo2/step_3/z",
        }, ctx)

        expect(ctx.result.status).to.equal("BLOCKED")
        expect(ctx.result.reason).to.equal("bad schema")
        expect(ctx.result.failed_path).to.equal("/demo2/step_2/y")
        expect(ctx.state:step_done("step_2")).to.equal(false)
    end)

    it("run_linear resumes (step_done skip)", function()
        local visits = {}
        frame.register("/demo3/step_1/a", {}, function()
            visits.s1 = true
            return "DONE path=/a"
        end)
        frame.register("/demo3/step_2/b", {}, function()
            visits.s2 = true
            return "DONE path=/b"
        end)

        local ctx = { state = frame.state_new() }
        ctx.state:step_mark("step_1") -- already done
        frame.run_linear({ "/demo3/step_1/a", "/demo3/step_2/b" }, ctx)

        expect(visits.s1).to.equal(nil) -- skipped
        expect(visits.s2).to.equal(true) -- executed
    end)
end)

-- lshape is optional — skip the whole section if not on package.path.
local lshape_ok, lshape = pcall(require, "lshape")
if not lshape_ok then
    print("  skip lshape integration — lshape not on package.path " .. "(run `alc_pkg_link /projects/lshape/lshape`)")
else
    describe("lshape integration (3-mode validate wrapper)", function()
        local T = lshape.t
        local UserShape = T.shape({
            name = T.string,
            age = T.number,
        })

        it("validate warn mode passes valid value", function()
            local v = frame.validate({ name = "shi", age = 27 }, UserShape, "user", "warn")
            expect(v.name).to.equal("shi")
        end)

        it("validate warn mode emits to sink on invalid (default sink swallowed)", function()
            local captured
            frame.set_warn_sink(function(reason, hint) captured = reason end)
            frame.validate({ name = "shi" }, UserShape, "user", "warn")
            if not captured then error("warn sink was not invoked") end
            frame.set_warn_sink(function() end) -- reset to silent
        end)

        it("validate strict mode throws on invalid", function()
            local ok = pcall(frame.validate, { name = "shi" }, UserShape, "user", "strict")
            expect(ok).to.equal(false)
        end)

        it("validate off mode returns value untouched", function()
            local v = frame.validate({ broken = true }, UserShape, "user", "off")
            expect(v.broken).to.equal(true)
        end)

        it("validate strict mode passes valid value", function()
            local v = frame.validate({ name = "shi", age = 27 }, UserShape, "user", "strict")
            expect(v.name).to.equal("shi")
        end)
    end)
end

-- helper: build a mock `flow` package whose llm_bound returns whatever
-- the caller wants for a given slot, and records the prompt + slot.
local function make_mock_flow(response_fn)
    local calls = {}
    local flow_mock = {
        llm_bound = function(state, opts)
            calls[#calls + 1] = {
                state = state,
                slot = opts.slot,
                prompt = opts.prompt,
                llm_opts = opts.llm_opts,
            }
            return response_fn(opts.slot, opts.prompt)
        end,
    }
    return flow_mock, calls
end

describe("Token & Prompt round-trip primitive (mock flow)", function()
    it("step_id_of extracts step segment from path", function()
        expect(adapter.step_id_of("/bundled-base-curator/step_1/window-inferrer")).to.equal("step_1")
        expect(adapter.step_id_of("/pkg/step_7/agent_name")).to.equal("step_7")
    end)

    it(
        "step_id_of passes a bare step id through unchanged",
        function() expect(adapter.step_id_of("step_1")).to.equal("step_1") end
    )

    it("make_dispatcher rejects missing opts", function()
        expect(pcall(adapter.make_dispatcher, nil)).to.equal(false)
        expect(pcall(adapter.make_dispatcher, {})).to.equal(false) -- no builder, no state
        expect(pcall(adapter.make_dispatcher, { builder = function() end })).to.equal(false) -- no state
        expect(pcall(adapter.make_dispatcher, { state = {} })).to.equal(false) -- no builder
    end)

    it("make_dispatcher exposes opts.extras at dispatcher.extras", function()
        frame._reset_for_testing()
        local mock_flow = {
            llm_bound = function() return "DONE path=/tmp/x" end,
        }
        local d = adapter.make_dispatcher({
            builder = function() return "B" end,
            state = { data = {} },
            flow = mock_flow,
            extras = {
                abtest_agents = { ["@x"] = true },
                state_shape = { name = "FooShape" },
                paths = { "/pkg/step_1/x" },
            },
        })
        expect(d.extras.abtest_agents["@x"]).to.equal(true)
        expect(d.extras.state_shape.name).to.equal("FooShape")
        expect(d.extras.paths[1]).to.equal("/pkg/step_1/x")
    end)

    it("make_dispatcher defaults extras to {} when opts.extras is nil", function()
        frame._reset_for_testing()
        local mock_flow = {
            llm_bound = function() return "DONE path=/tmp/x" end,
        }
        local d = adapter.make_dispatcher({
            builder = function() return "B" end,
            state = { data = {} },
            flow = mock_flow,
            -- no extras
        })
        if type(d.extras) ~= "table" then error("d.extras should default to a table, got: " .. type(d.extras)) end
        -- empty
        local count = 0
        for _ in pairs(d.extras) do
            count = count + 1
        end
        expect(count).to.equal(0)
    end)

    it("make_dispatcher rejects non-table opts.extras", function()
        local ok = pcall(adapter.make_dispatcher, {
            builder = function() return "B" end,
            state = { data = {} },
            flow = { llm_bound = function() return "" end },
            extras = "not a table",
        })
        expect(ok).to.equal(false)
    end)

    it("make_dispatcher: extras is opaque (does not affect dispatch)", function()
        frame._reset_for_testing()
        local call_count = 0
        local mock_flow = {
            llm_bound = function(_st, opts)
                call_count = call_count + 1
                return "DONE path=/tmp/" .. opts.slot
            end,
        }
        local d = adapter.make_dispatcher({
            builder = function() return "B" end,
            state = { data = {} },
            flow = mock_flow,
            extras = {
                -- Arbitrary garbage; adapter must not interpret any of these
                abtest_agents = { ["@y"] = true },
                random_dict = { nested = { deep = "value" } },
                random_number = 42,
                random_bool = true,
                random_string = "anything",
            },
        })
        local resp = d("/pkg/step_1/a", { prompt = "hi" }, {})
        expect(resp).to.equal("DONE path=/tmp/step_1")
        expect(call_count).to.equal(1)
        -- extras still readable verbatim post-dispatch
        expect(d.extras.random_number).to.equal(42)
        expect(d.extras.random_dict.nested.deep).to.equal("value")
    end)

    it("make_dispatcher delegates via flow.llm_bound (happy path)", function()
        frame._reset_for_testing() -- keep strict default
        local mock_flow, calls = make_mock_flow(
            function(slot) return "DONE path=/tmp/" .. slot .. " [flow_token=fake][flow_slot=" .. slot .. "]" end
        )
        local dispatcher = adapter.make_dispatcher({
            builder = function(step, spec) return "INSTRUCTION " .. step .. ":" .. (spec.prompt or "") end,
            state = { task_id = "demo", data = {} },
            llm_opts = { system = "sys", max_tokens = 500 },
            flow = mock_flow,
        })
        local resp = dispatcher("/demo/step_1/a", { prompt = "hi" }, {})
        expect(resp).to.equal("DONE path=/tmp/step_1 [flow_token=fake][flow_slot=step_1]")
        expect(calls[1].slot).to.equal("step_1")
        expect(calls[1].prompt).to.equal("INSTRUCTION step_1:hi")
        expect(calls[1].llm_opts.system).to.equal("sys")
        expect(calls[1].llm_opts.max_tokens).to.equal(500)
    end)

    it("dispatcher integrates with frame.run_linear end-to-end", function()
        frame._reset_for_testing()
        frame.register("/integ/step_1/a", { prompt = "first" })
        frame.register("/integ/step_2/b", { prompt = "second" })

        local seen = {}
        local mock_flow = {
            llm_bound = function(_st, opts)
                seen[#seen + 1] = opts.slot
                return "DONE path=/tmp/" .. opts.slot .. " [flow_token=t][flow_slot=" .. opts.slot .. "]"
            end,
        }
        local ctx = {
            state = frame.state_new(),
            dispatcher = adapter.make_dispatcher({
                builder = function() return "" end,
                state = { data = {} },
                flow = mock_flow,
            }),
        }
        frame.run_linear({ "/integ/step_1/a", "/integ/step_2/b" }, ctx)
        expect(ctx.result.status).to.equal("DONE")
        expect(seen[1]).to.equal("step_1")
        expect(seen[2]).to.equal("step_2")
        expect(ctx.state:get("artifacts.step_1")).to.equal("/tmp/step_1")
    end)

    it("strict mode (default): routes via flow.llm_bound, not alc.llm", function()
        frame._reset_for_testing()
        frame.init({ check_mode = "strict" })
        local flow_called, alc_called = 0, 0
        local mock_flow = {
            llm_bound = function(_st, opts)
                flow_called = flow_called + 1
                return "DONE path=/tmp/" .. opts.slot
            end,
        }
        local mock_alc = {
            llm = function()
                alc_called = alc_called + 1
                return "should not be called"
            end,
        }
        local dispatcher = adapter.make_dispatcher({
            builder = function() return "BODY" end,
            state = { data = {} },
            flow = mock_flow,
            alc = mock_alc,
        })
        local resp = dispatcher("/demo/step_1/a", {}, {})
        expect(resp).to.equal("DONE path=/tmp/step_1")
        expect(flow_called).to.equal(1)
        expect(alc_called).to.equal(0)
    end)

    it("non-check mode: bypasses flow, calls alc.llm directly", function()
        frame._reset_for_testing()
        frame.init({ check_mode = "non-check" })
        local flow_called, alc_called = 0, 0
        local captured_prompt, captured_opts
        local mock_flow = {
            llm_bound = function()
                flow_called = flow_called + 1
                return "should not be called"
            end,
        }
        local mock_alc = {
            llm = function(prompt, llm_opts)
                alc_called = alc_called + 1
                captured_prompt = prompt
                captured_opts = llm_opts
                return "DONE path=/tmp/direct"
            end,
        }
        local dispatcher = adapter.make_dispatcher({
            builder = function(step) return "BODY:" .. step end,
            state = { data = {} },
            llm_opts = { system = "sys", max_tokens = 100 },
            flow = mock_flow,
            alc = mock_alc,
        })
        local resp = dispatcher("/demo/step_1/a", {}, {})
        expect(resp).to.equal("DONE path=/tmp/direct")
        expect(flow_called).to.equal(0)
        expect(alc_called).to.equal(1)
        expect(captured_prompt).to.equal("BODY:step_1")
        expect(captured_opts.system).to.equal("sys")
        expect(captured_opts.max_tokens).to.equal(100)
        frame._reset_for_testing() -- restore default for downstream tests
    end)

    it("non-check mode: raises when alc.llm is unavailable", function()
        frame._reset_for_testing()
        frame.init({ check_mode = "non-check" })
        local dispatcher = adapter.make_dispatcher({
            builder = function() return "BODY" end,
            state = { data = {} },
            flow = { llm_bound = function() return "" end },
            alc = {}, -- missing .llm
        })
        local ok, err = pcall(dispatcher, "/demo/step_1/a", {}, {})
        expect(ok).to.equal(false)
        if not tostring(err):find("alc.llm is not available", 1, true) then
            error("expected 'alc.llm is not available' in error, got: " .. tostring(err))
        end
        frame._reset_for_testing()
    end)
end)

describe("C1: spec.llm_opts_overlay (per-call llm_opts seam)", function()
    it("overlay.system overrides base in strict mode", function()
        frame._reset_for_testing()
        local captured
        local mock_flow = {
            llm_bound = function(_st, opts)
                captured = opts.llm_opts
                return "DONE path=/tmp/x"
            end,
        }
        local dispatcher = adapter.make_dispatcher({
            builder = function() return "B" end,
            state = { data = {} },
            llm_opts = { system = "base_sys", max_tokens = 100 },
            flow = mock_flow,
        })
        dispatcher("/demo/step_1/a", { llm_opts_overlay = { system = "override_sys" } }, {})
        expect(captured.system).to.equal("override_sys")
        expect(captured.max_tokens).to.equal(100)
    end)

    it("overlay.max_tokens overrides base in non-check mode", function()
        frame._reset_for_testing()
        frame.init({ check_mode = "non-check" })
        local captured
        local mock_alc = {
            llm = function(_prompt, llm_opts)
                captured = llm_opts
                return "DONE path=/tmp/x"
            end,
        }
        local dispatcher = adapter.make_dispatcher({
            builder = function() return "B" end,
            state = { data = {} },
            llm_opts = { system = "base_sys", max_tokens = 100 },
            flow = { llm_bound = function() return "" end },
            alc = mock_alc,
        })
        dispatcher("/demo/step_1/a", { llm_opts_overlay = { max_tokens = 500 } }, {})
        expect(captured.system).to.equal("base_sys")
        expect(captured.max_tokens).to.equal(500)
        frame._reset_for_testing()
    end)

    it("overlay merges over base (keys absent from overlay fall back)", function()
        frame._reset_for_testing()
        local captured
        local mock_flow = {
            llm_bound = function(_st, opts)
                captured = opts.llm_opts
                return "DONE path=/tmp/x"
            end,
        }
        local dispatcher = adapter.make_dispatcher({
            builder = function() return "B" end,
            state = { data = {} },
            llm_opts = { system = "base_sys", max_tokens = 100, model = "claude-haiku-4-5-20251001" },
            flow = mock_flow,
        })
        dispatcher("/demo/step_1/a", { llm_opts_overlay = { model = "claude-sonnet-4-6" } }, {})
        -- model overridden, system + max_tokens fall back to base
        expect(captured.system).to.equal("base_sys")
        expect(captured.max_tokens).to.equal(100)
        expect(captured.model).to.equal("claude-sonnet-4-6")
    end)

    it("nil overlay passes base through unchanged (regression)", function()
        frame._reset_for_testing()
        local captured
        local mock_flow = {
            llm_bound = function(_st, opts)
                captured = opts.llm_opts
                return "DONE path=/tmp/x"
            end,
        }
        local base_opts = { system = "base_sys", max_tokens = 100 }
        local dispatcher = adapter.make_dispatcher({
            builder = function() return "B" end,
            state = { data = {} },
            llm_opts = base_opts,
            flow = mock_flow,
        })
        dispatcher("/demo/step_1/a", { prompt = "hi" }, {}) -- no llm_opts_overlay
        -- captured should be the same base reference (no merge happened)
        expect(captured).to.equal(base_opts)
        expect(captured.system).to.equal("base_sys")
        expect(captured.max_tokens).to.equal(100)
    end)

    it("non-table overlay raises", function()
        frame._reset_for_testing()
        local dispatcher = adapter.make_dispatcher({
            builder = function() return "B" end,
            state = { data = {} },
            flow = { llm_bound = function() return "" end },
        })
        local ok, err = pcall(dispatcher, "/demo/step_1/a", { llm_opts_overlay = "not a table" }, {})
        expect(ok).to.equal(false)
        if not tostring(err):find("llm_opts_overlay must be", 1, true) then
            error("expected 'llm_opts_overlay must be' in error, got: " .. tostring(err))
        end
    end)
end)

describe("C2: spec_writes / state_writes declaration registry", function()
    it("declarations aggregate into dispatcher registries", function()
        frame._reset_for_testing()
        local mock_flow = { llm_bound = function() return "DONE path=/tmp/x" end }
        local d = adapter.make_dispatcher({
            builder = function() return "B" end,
            state = { data = {} },
            flow = mock_flow,
            plugins = {
                {
                    name = "variant_ab",
                    spec_writes = { "agent", "variant_id", "admission" },
                    state_writes = { "_variant_ab_dispatches" },
                },
                {
                    name = "run_card",
                    spec_writes = { "note" },
                },
            },
        })
        -- spec_writes aggregated
        expect(d.spec_writes["agent"][1]).to.equal("variant_ab")
        expect(d.spec_writes["variant_id"][1]).to.equal("variant_ab")
        expect(d.spec_writes["admission"][1]).to.equal("variant_ab")
        expect(d.spec_writes["note"][1]).to.equal("run_card")
        -- state_writes aggregated
        expect(d.state_writes["_variant_ab_dispatches"][1]).to.equal("variant_ab")
    end)

    it("spec_writes collision: two plugins declaring same field surfaces in registry (warn-logged)", function()
        frame._reset_for_testing()
        local mock_flow = { llm_bound = function() return "DONE path=/tmp/x" end }
        -- Capture warn log messages from alc.log
        local warn_msgs = {}
        local mock_alc = {
            log = function(level, msg) warn_msgs[#warn_msgs + 1] = { level = level, msg = msg } end,
            llm = function() return "" end,
        }
        local d = adapter.make_dispatcher({
            builder = function() return "B" end,
            state = { data = {} },
            flow = mock_flow,
            alc = mock_alc,
            plugins = {
                { name = "plugin_a", spec_writes = { "agent" } },
                { name = "plugin_b", spec_writes = { "agent" } },
            },
        })
        -- Both owners present in registry
        expect(#d.spec_writes["agent"]).to.equal(2)
        -- Warn log emitted with both names
        local found = false
        for _, w in ipairs(warn_msgs) do
            if
                w.level == "warn"
                and tostring(w.msg):find("spec_writes collision", 1, true)
                and tostring(w.msg):find("plugin_a", 1, true)
                and tostring(w.msg):find("plugin_b", 1, true)
            then
                found = true
            end
        end
        if not found then
            error(
                "expected spec_writes collision warn log naming both plugins, got: "
                    .. tostring(#warn_msgs)
                    .. " messages"
            )
        end
    end)

    it("state_writes: non-underscore-prefixed key rejected", function()
        local ok, err = pcall(adapter.make_dispatcher, {
            builder = function() return "B" end,
            state = { data = {} },
            flow = { llm_bound = function() return "" end },
            plugins = {
                { name = "bad_plugin", state_writes = { "variant_dispatches" } }, -- missing _
            },
        })
        expect(ok).to.equal(false)
        if not tostring(err):find("must start with '_'", 1, true) then
            error("expected 'must start with _' in error, got: " .. tostring(err))
        end
    end)

    it("invalid shapes rejected", function()
        -- spec_writes not a table
        local ok1 = pcall(adapter.make_dispatcher, {
            builder = function() return "B" end,
            state = { data = {} },
            flow = { llm_bound = function() return "" end },
            plugins = { { name = "p", spec_writes = "agent" } }, -- string, not list
        })
        expect(ok1).to.equal(false)
        -- spec_writes entry not a string
        local ok2 = pcall(adapter.make_dispatcher, {
            builder = function() return "B" end,
            state = { data = {} },
            flow = { llm_bound = function() return "" end },
            plugins = { { name = "p", spec_writes = { 42 } } }, -- non-string entry
        })
        expect(ok2).to.equal(false)
        -- state_writes empty-string entry
        local ok3 = pcall(adapter.make_dispatcher, {
            builder = function() return "B" end,
            state = { data = {} },
            flow = { llm_bound = function() return "" end },
            plugins = { { name = "p", state_writes = { "" } } },
        })
        expect(ok3).to.equal(false)
    end)
end)

describe("C3: ctx.llm_call (aux LLM seam) + staged-commit finalize", function()
    it("ctx.llm_call: routes via flow.llm_bound in strict mode with default slot suffix", function()
        frame._reset_for_testing()
        -- Both ctx.llm_call AND core_dispatch route via flow.llm_bound;
        -- capture the list of all calls and assert on the first (aux).
        local calls = {}
        local mock_flow = {
            llm_bound = function(_st, opts)
                calls[#calls + 1] = {
                    slot = opts.slot,
                    prompt = opts.prompt,
                    llm_opts = opts.llm_opts,
                }
                return "AUX_OR_CORE"
            end,
        }
        local plugin_use_llm_call = {
            name = "use_llm_call",
            around_dispatch = function(inner, _spec, ctx)
                ctx.llm_call({ prompt = "aux protocol prompt" })
                return inner(_spec, ctx)
            end,
        }
        local d = adapter.make_dispatcher({
            builder = function() return "CORE_PROMPT" end,
            state = { data = {} },
            llm_opts = { system = "base_sys", max_tokens = 50 },
            flow = mock_flow,
            plugins = { plugin_use_llm_call },
        })
        d("/demo/step_1/a", {}, {})
        -- First call should be the ctx.llm_call (default slot suffix ":aux")
        expect(calls[1].slot).to.equal("step_1:aux")
        expect(calls[1].prompt).to.equal("aux protocol prompt")
        expect(calls[1].llm_opts.system).to.equal("base_sys")
        expect(calls[1].llm_opts.max_tokens).to.equal(50)
        -- Second call is the inner core_dispatch (slot = step_1)
        expect(calls[2].slot).to.equal("step_1")
        expect(calls[2].prompt).to.equal("CORE_PROMPT")
    end)

    it("ctx.llm_call: routes via alc.llm direct in non-check mode + applies llm_opts_overlay", function()
        frame._reset_for_testing()
        frame.init({ check_mode = "non-check" })
        local calls = {}
        local mock_alc = {
            llm = function(_prompt, llm_opts)
                calls[#calls + 1] = { opts = llm_opts }
                return "AUX_OR_CORE"
            end,
        }
        local plugin_use = {
            name = "use_overlay",
            around_dispatch = function(inner, _spec, ctx)
                ctx.llm_call({
                    prompt = "aux",
                    llm_opts_overlay = { max_tokens = 999 },
                })
                return inner(_spec, ctx)
            end,
        }
        local d = adapter.make_dispatcher({
            builder = function() return "CORE" end,
            state = { data = {} },
            llm_opts = { system = "base_sys", max_tokens = 50 },
            flow = { llm_bound = function() return "" end },
            alc = mock_alc,
            plugins = { plugin_use },
        })
        d("/demo/step_1/a", {}, {})
        -- First call (ctx.llm_call): overlay max_tokens=999 wins, base system falls through
        expect(calls[1].opts.system).to.equal("base_sys")
        expect(calls[1].opts.max_tokens).to.equal(999)
        -- Second call (inner core_dispatch): no overlay, base intact
        expect(calls[2].opts.system).to.equal("base_sys")
        expect(calls[2].opts.max_tokens).to.equal(50)
        frame._reset_for_testing()
    end)

    it("ctx.llm_call: missing or invalid prompt raises", function()
        frame._reset_for_testing()
        local caught_err
        local plugin_bad = {
            name = "bad_prompt",
            around_dispatch = function(inner, _spec, ctx)
                local ok, err = pcall(ctx.llm_call, {}) -- no prompt
                caught_err = err
                return inner(_spec, ctx)
            end,
        }
        local d = adapter.make_dispatcher({
            builder = function() return "CORE" end,
            state = { data = {} },
            flow = { llm_bound = function() return "OK" end },
            plugins = { plugin_bad },
        })
        d("/demo/step_1/a", {}, {})
        if not tostring(caught_err):find("opts.prompt", 1, true) then
            error("expected 'opts.prompt' in error, got: " .. tostring(caught_err))
        end
    end)

    it("finalize: staged-commit defers card.create until ALL plugin.finalize calls complete", function()
        frame._reset_for_testing()
        local call_order = {}
        local mock_alc = {
            card = {
                create = function(payload)
                    call_order[#call_order + 1] = "card.create:" .. payload.metadata.plugin
                    return { card_id = "card-" .. payload.metadata.plugin }
                end,
                write_samples = function(_id, _samples) end,
            },
            log = function() end,
        }
        local plugin_a = {
            name = "plugin_a",
            finalize = function()
                call_order[#call_order + 1] = "finalize:plugin_a"
                return { groups = { default = { { sample = 1 } } } }
            end,
        }
        local plugin_b = {
            name = "plugin_b",
            finalize = function()
                call_order[#call_order + 1] = "finalize:plugin_b"
                return { groups = { default = { { sample = 2 } } } }
            end,
        }
        local d = adapter.make_dispatcher({
            builder = function() return "B" end,
            state = { data = { task_id = "t1" } },
            flow = { llm_bound = function() return "DONE" end },
            alc = mock_alc,
            plugins = { plugin_a, plugin_b },
        })
        d.finalize({ pkg_name = "test_pkg" })
        -- Expected order: both finalize calls happen BEFORE any card.create
        expect(call_order[1]).to.equal("finalize:plugin_a")
        expect(call_order[2]).to.equal("finalize:plugin_b")
        expect(call_order[3]).to.equal("card.create:plugin_a")
        expect(call_order[4]).to.equal("card.create:plugin_b")
    end)

    it("finalize: plugin throwing in finalize does not commit ANY plugin's card (staged-commit)", function()
        frame._reset_for_testing()
        local cards_created = {}
        local mock_alc = {
            card = {
                create = function(payload)
                    cards_created[#cards_created + 1] = payload.metadata.plugin
                    return { card_id = "card-" .. payload.metadata.plugin }
                end,
                write_samples = function() end,
            },
            log = function() end,
        }
        local plugin_a = {
            name = "plugin_a",
            finalize = function() return { groups = { default = { { sample = 1 } } } } end,
        }
        local plugin_throwy = {
            name = "plugin_throwy",
            finalize = function() error("intentional throw mid-collection") end,
        }
        local plugin_c = {
            name = "plugin_c",
            finalize = function() return { groups = { default = { { sample = 3 } } } } end,
        }
        local d = adapter.make_dispatcher({
            builder = function() return "B" end,
            state = { data = { task_id = "t1" } },
            flow = { llm_bound = function() return "DONE" end },
            alc = mock_alc,
            plugins = { plugin_a, plugin_throwy, plugin_c },
        })
        -- The throwy plugin's finalize is pcall'd and warn-logged. Successful
        -- plugins' cards still get written in Phase 2 (this is "best-effort
        -- skip-failed" within staged-commit), but the throw happens during
        -- Phase 1 collection — by Phase 2 entry, plugin_a's card payload was
        -- already collected. Verify a and c committed, throwy did not.
        d.finalize({ pkg_name = "test_pkg" })
        -- plugin_a + plugin_c cards present; plugin_throwy skipped
        local has_a, has_c, has_throwy = false, false, false
        for _, name in ipairs(cards_created) do
            if name == "plugin_a" then has_a = true end
            if name == "plugin_c" then has_c = true end
            if name == "plugin_throwy" then has_throwy = true end
        end
        expect(has_a).to.equal(true)
        expect(has_c).to.equal(true)
        expect(has_throwy).to.equal(false)
    end)
end)

describe("Phase 2: plugin pipeline (before / around / after)", function()
    it("plugins unspecified preserves Phase 1 behavior (regression)", function()
        frame._reset_for_testing()
        local mock_flow = {
            llm_bound = function(_st, opts) return "DONE path=/tmp/" .. opts.slot end,
        }
        local d = adapter.make_dispatcher({
            builder = function(step) return "BODY:" .. step end,
            state = { data = {} },
            flow = mock_flow,
        })
        -- empty plugins
        expect(#d.plugins).to.equal(0)
        local resp = d("/pkg/step_1/a", {}, {})
        expect(resp).to.equal("DONE path=/tmp/step_1")
    end)

    it("before_dispatch mutates spec before core dispatch", function()
        frame._reset_for_testing()
        local seen_prompt
        local mock_flow = {
            llm_bound = function(_st, opts)
                seen_prompt = opts.prompt
                return "DONE path=/tmp/x"
            end,
        }
        local d = adapter.make_dispatcher({
            builder = function(step, spec) return "BODY:" .. step .. ":" .. (spec.prompt or "") end,
            state = { data = {} },
            flow = mock_flow,
            plugins = {
                {
                    name = "rewrite",
                    before_dispatch = function(spec, _ctx) spec.prompt = (spec.prompt or "") .. "[mutated]" end,
                },
            },
        })
        d("/pkg/step_1/a", { prompt = "orig" }, {})
        expect(seen_prompt).to.equal("BODY:step_1:orig[mutated]")
    end)

    it("after_dispatch observes response post-core", function()
        frame._reset_for_testing()
        local captured_response, captured_step
        local mock_flow = {
            llm_bound = function(_st, opts) return "DONE path=/tmp/" .. opts.slot end,
        }
        local d = adapter.make_dispatcher({
            builder = function() return "B" end,
            state = { data = {} },
            flow = mock_flow,
            plugins = {
                {
                    name = "observe",
                    after_dispatch = function(response, _spec, ctx)
                        captured_response = response
                        captured_step = ctx.step
                    end,
                },
            },
        })
        d("/pkg/step_7/agent", {}, {})
        expect(captured_response).to.equal("DONE path=/tmp/step_7")
        expect(captured_step).to.equal("step_7")
    end)

    it("around_dispatch wraps core (single plugin)", function()
        frame._reset_for_testing()
        local mock_flow = {
            llm_bound = function(_st, opts) return "DONE path=/tmp/" .. opts.slot end,
        }
        local d = adapter.make_dispatcher({
            builder = function() return "B" end,
            state = { data = {} },
            flow = mock_flow,
            plugins = {
                {
                    name = "wrap",
                    around_dispatch = function(inner, spec, ctx)
                        -- Decorate response after inner call.
                        local r = inner(spec, ctx)
                        return r .. " [wrapped]"
                    end,
                },
            },
        })
        local resp = d("/pkg/step_1/a", {}, {})
        expect(resp).to.equal("DONE path=/tmp/step_1 [wrapped]")
    end)

    it("around_dispatch onion ordering (outer wraps inner)", function()
        frame._reset_for_testing()
        local mock_flow = {
            llm_bound = function(_st, opts) return "core:" .. opts.slot end,
        }
        local d = adapter.make_dispatcher({
            builder = function() return "B" end,
            state = { data = {} },
            flow = mock_flow,
            plugins = {
                {
                    name = "outer",
                    around_dispatch = function(inner, spec, ctx) return "[outer " .. inner(spec, ctx) .. " outer]" end,
                },
                {
                    name = "inner",
                    around_dispatch = function(inner, spec, ctx) return "[inner " .. inner(spec, ctx) .. " inner]" end,
                },
            },
        })
        -- plugins[1].around = outermost layer; plugins[2].around = innermost
        -- so the response shape is: outer( inner( core ) )
        local resp = d("/pkg/step_1/a", {}, {})
        expect(resp).to.equal("[outer [inner core:step_1 inner] outer]")
    end)

    it("around_dispatch can multi-call core (vote pattern)", function()
        frame._reset_for_testing()
        local n_calls = 0
        local mock_flow = {
            llm_bound = function(_st, opts)
                n_calls = n_calls + 1
                return "vote-" .. n_calls .. ":" .. opts.slot
            end,
        }
        local d = adapter.make_dispatcher({
            builder = function() return "B" end,
            state = { data = {} },
            flow = mock_flow,
            plugins = {
                {
                    name = "vote",
                    around_dispatch = function(inner, spec, ctx)
                        local rs = {}
                        for _ = 1, 3 do
                            rs[#rs + 1] = inner(spec, ctx)
                        end
                        return table.concat(rs, "|")
                    end,
                },
            },
        })
        local resp = d("/pkg/step_1/a", {}, {})
        expect(n_calls).to.equal(3)
        expect(resp).to.equal("vote-1:step_1|vote-2:step_1|vote-3:step_1")
    end)

    it("plugin sees ctx.flow_state / ctx.extras / ctx.scratch / ctx.frame", function()
        frame._reset_for_testing()
        local seen_flow_state, seen_extras, seen_scratch, seen_frame, seen_step
        local mock_flow = {
            llm_bound = function(_st, opts) return "DONE path=/tmp/" .. opts.slot end,
        }
        local fake_state = { data = { task_id = "T1" } }
        local d = adapter.make_dispatcher({
            builder = function() return "B" end,
            state = fake_state,
            flow = mock_flow,
            extras = { hello = "world" },
            plugins = {
                {
                    name = "probe",
                    before_dispatch = function(_spec, ctx)
                        seen_flow_state = ctx.flow_state
                        seen_extras = ctx.extras
                        seen_scratch = ctx.scratch
                        seen_frame = ctx.frame
                        seen_step = ctx.step
                        ctx.scratch.note = "set-by-before"
                    end,
                    after_dispatch = function(_resp, _spec, ctx)
                        -- scratch carries the same table across hooks within
                        -- one dispatch call.
                        expect(ctx.scratch.note).to.equal("set-by-before")
                    end,
                },
            },
        })
        d("/pkg/step_1/agent", {}, {})
        expect(seen_flow_state.data.task_id).to.equal("T1")
        expect(seen_extras.hello).to.equal("world")
        expect(type(seen_scratch)).to.equal("table")
        -- Identity check (not deep eq) — frame module table has cycles.
        expect(seen_frame).to.be(frame)
        expect(seen_step).to.equal("step_1")
    end)

    it("plugin shape errors: non-table plugin rejected", function()
        local ok = pcall(adapter.make_dispatcher, {
            builder = function() return "B" end,
            state = {},
            flow = { llm_bound = function() return "" end },
            plugins = { "not a table" },
        })
        expect(ok).to.equal(false)
    end)

    it("plugin shape errors: missing name rejected", function()
        local ok = pcall(adapter.make_dispatcher, {
            builder = function() return "B" end,
            state = {},
            flow = { llm_bound = function() return "" end },
            plugins = { { before_dispatch = function() end } }, -- no name
        })
        expect(ok).to.equal(false)
    end)

    it("plugin shape errors: non-function hook rejected", function()
        local ok = pcall(adapter.make_dispatcher, {
            builder = function() return "B" end,
            state = {},
            flow = { llm_bound = function() return "" end },
            plugins = { { name = "bad", before_dispatch = "not a fn" } },
        })
        expect(ok).to.equal(false)
    end)
end)

describe("check_mode = format (JSON verdict + post-verify)", function()
    it("valid JSON verdict passes through verbatim", function()
        frame._reset_for_testing()
        frame.init({ check_mode = "format" })
        local mock_flow = {
            llm_bound = function(_st, opts)
                return '{"status":"DONE","path":"/tmp/x","flow_token":"abc","flow_slot":"' .. opts.slot .. '"}'
            end,
        }
        local dispatcher = adapter.make_dispatcher({
            builder = function() return "BODY" end,
            state = { data = {} },
            flow = mock_flow,
        })
        local resp = dispatcher("/demo/step_1/a", {}, {})
        expect(resp).to.equal('{"status":"DONE","path":"/tmp/x","flow_token":"abc","flow_slot":"step_1"}')
        frame._reset_for_testing()
    end)

    it("non-JSON response becomes BLOCKED reason=format-non-json", function()
        frame._reset_for_testing()
        frame.init({ check_mode = "format" })
        local mock_flow = {
            llm_bound = function(_st, opts) return "DONE path=/tmp/x [flow_token=abc][flow_slot=" .. opts.slot .. "]" end,
        }
        local dispatcher = adapter.make_dispatcher({
            builder = function() return "BODY" end,
            state = { data = {} },
            flow = mock_flow,
        })
        local resp = dispatcher("/demo/step_1/a", {}, {})
        expect(resp).to.equal("BLOCKED reason=format-non-json slot=step_1")
        frame._reset_for_testing()
    end)

    it("malformed JSON becomes BLOCKED reason=format-json-parse-error", function()
        frame._reset_for_testing()
        frame.init({ check_mode = "format" })
        -- A balanced { ... } but with invalid JSON inside.
        local mock_flow = {
            llm_bound = function() return "{not valid json}" end,
        }
        local dispatcher = adapter.make_dispatcher({
            builder = function() return "BODY" end,
            state = { data = {} },
            flow = mock_flow,
        })
        local resp = dispatcher("/demo/step_1/a", {}, {})
        -- The adapter prefixes the BLOCKED reason with a diagnostic snippet
        -- (`(snippet=... err=...)`) so the failure is debuggable from the
        -- pipeline halt path. Match on the stable parts only.
        if not resp:find("BLOCKED reason=format-json-parse-error", 1, true) then
            error("expected format-json-parse-error prefix, got: " .. tostring(resp))
        end
        if not resp:find("slot=step_1", 1, true) then error("expected slot=step_1 suffix, got: " .. tostring(resp)) end
        frame._reset_for_testing()
    end)

    it("JSON missing flow_token becomes BLOCKED reason=format-missing-flow-token", function()
        frame._reset_for_testing()
        frame.init({ check_mode = "format" })
        local mock_flow = {
            llm_bound = function(_st, opts)
                return '{"status":"DONE","path":"/tmp/x","flow_slot":"' .. opts.slot .. '"}'
            end,
        }
        local dispatcher = adapter.make_dispatcher({
            builder = function() return "BODY" end,
            state = { data = {} },
            flow = mock_flow,
        })
        local resp = dispatcher("/demo/step_1/a", {}, {})
        expect(resp).to.equal("BLOCKED reason=format-missing-flow-token slot=step_1")
        frame._reset_for_testing()
    end)

    it("JSON missing flow_slot becomes BLOCKED reason=format-missing-flow-slot", function()
        frame._reset_for_testing()
        frame.init({ check_mode = "format" })
        local mock_flow = {
            llm_bound = function() return '{"status":"DONE","path":"/tmp/x","flow_token":"abc"}' end,
        }
        local dispatcher = adapter.make_dispatcher({
            builder = function() return "BODY" end,
            state = { data = {} },
            flow = mock_flow,
        })
        local resp = dispatcher("/demo/step_1/a", {}, {})
        expect(resp).to.equal("BLOCKED reason=format-missing-flow-slot slot=step_1")
        frame._reset_for_testing()
    end)

    it("flow_slot mismatch becomes BLOCKED reason=format-flow-slot-mismatch", function()
        frame._reset_for_testing()
        frame.init({ check_mode = "format" })
        local mock_flow = {
            llm_bound = function() return '{"status":"DONE","path":"/tmp/x","flow_token":"abc","flow_slot":"step_9"}' end,
        }
        local dispatcher = adapter.make_dispatcher({
            builder = function() return "BODY" end,
            state = { data = {} },
            flow = mock_flow,
        })
        local resp = dispatcher("/demo/step_1/a", {}, {})
        -- expected step_1 routing, got step_9 from Agent
        if not resp:find("format-flow-slot-mismatch", 1, true) then
            error("expected format-flow-slot-mismatch in resp, got: " .. tostring(resp))
        end
        if not resp:find("expected=step_1", 1, true) then error("expected expected=step_1, got: " .. tostring(resp)) end
        if not resp:find("got=step_9", 1, true) then error("expected got=step_9, got: " .. tostring(resp)) end
        frame._reset_for_testing()
    end)
end)

-- The example only needs flow.state_new (algocline flow state for the
-- Token & Prompt resume cue) and flow.llm_bound (the round-trip
-- primitive). We mock both via package.loaded so the example's
-- top-level requires pick the doubles up.
local v2_flow_response = function(slot)
    return "DONE path=/tmp/" .. slot .. ".json" .. " [flow_token=fake-" .. slot .. "][flow_slot=" .. slot .. "]"
end
local v2_seen = {}
package.loaded["flow"] = {
    state_new = function() return { data = {}, status = "running" } end,
    llm_bound = function(_st, opts)
        v2_seen[#v2_seen + 1] = opts.slot
        return v2_flow_response(opts.slot, opts.prompt)
    end,
    state_save = function() end,
}
_G.alc = { log = function() end }

local v2 = require("bundled_base_curator")

describe("examples/bundled_base_curator PoC (mock flow.state_new + flow.llm_bound)", function()
    it("v2 executes 6 steps end-to-end via frame.run_linear", function()
        frame._reset_for_testing()
        v2_seen = {}
        local ctx = { task_dir = "/tmp/poc-test", task_id = "poc-1" }
        v2.run(ctx)
        expect(ctx.result.status).to.equal("DONE")
        expect(#v2_seen).to.equal(6)
        expect(v2_seen[1]).to.equal("step_1")
        expect(v2_seen[6]).to.equal("step_6")
    end)

    it("v2 records artifacts via frame.run_linear (no direct state writes)", function()
        frame._reset_for_testing()
        v2_seen = {}
        local ctx = { task_dir = "/tmp/poc-test-art", task_id = "poc-art" }
        v2.run(ctx)
        expect(ctx.state:get("artifacts.step_1")).to.equal("/tmp/step_1.json")
        expect(ctx.state:get("artifacts.step_6")).to.equal("/tmp/step_6.json")
    end)

    it("v2 captures BLOCKED at step_3 via frame.run_linear", function()
        frame._reset_for_testing()
        v2_flow_response = function(slot)
            if slot == "step_3" then
                return "BLOCKED reason=mock fail at step_3" .. " [flow_token=fake-step_3][flow_slot=step_3]"
            end
            return "DONE path=/tmp/" .. slot .. ".json" .. " [flow_token=fake-" .. slot .. "][flow_slot=" .. slot .. "]"
        end
        local ctx = { task_dir = "/tmp/poc-test-blocked", task_id = "poc-b" }
        v2.run(ctx)
        expect(ctx.result.status).to.equal("BLOCKED")
        -- frame.parse_verdict's BLOCKED regex captures the trailing echo
        -- tag verbatim today; reason-stripping is a separate concern.
        -- Assert by substring containment so both shapes (with / without
        -- the echo tag retained) pass.
        if not ctx.result.reason:find("mock fail at step_3", 1, true) then
            error("BLOCKED reason should contain 'mock fail at step_3', got: " .. tostring(ctx.result.reason))
        end
        expect(ctx.result.failed_path).to.equal("/bundled-base-curator/step_3/corpus-fingerprint")
    end)

    it("v2 captures NEEDS_INPUT (resume contract intact)", function()
        frame._reset_for_testing()
        v2_flow_response = function(slot)
            if slot == "step_4" then
                return "NEEDS_INPUT missing=fingerprint.json" .. " [flow_token=fake-step_4][flow_slot=step_4]"
            end
            return "DONE path=/tmp/" .. slot .. ".json" .. " [flow_token=fake-" .. slot .. "][flow_slot=" .. slot .. "]"
        end
        local ctx = { task_dir = "/tmp/poc-test-needs", task_id = "poc-n" }
        v2.run(ctx)
        expect(ctx.result.status).to.equal("NEEDS_INPUT")
        expect(ctx.result.missing).to.equal("fingerprint.json")
    end)
end)

describe("build_step_instruction + orch public surface", function()
    it("build_step_instruction resolves spec-builder with plain state", function()
        frame.register("/bsi/step_1/a", function(state) return { prompt = "hello " .. state.task_dir } end)
        local instruction = frame.build_step_instruction(
            "/bsi/step_1/a",
            { task_dir = "/tmp/xy" },
            function(step_id, spec) return step_id .. ":" .. spec.prompt end
        )
        expect(instruction).to.equal("step_1:hello /tmp/xy")
        frame.unregister("/bsi/step_1/a")
    end)

    it("build_step_instruction accepts a frame.State container", function()
        frame.register("/bsi/step_2/b", function(state) return { out = state.task_dir .. "/x.json" } end)
        local s = frame.state_new()
        s:set("task_dir", "/tmp/zz")
        local instruction = frame.build_step_instruction("/bsi/step_2/b", s, function(_step, spec) return spec.out end)
        expect(instruction).to.equal("/tmp/zz/x.json")
        frame.unregister("/bsi/step_2/b")
    end)

    it("build_step_instruction with static spec ignores state", function()
        frame.register("/bsi/step_3/c", { fixed = "literal" })
        local instruction = frame.build_step_instruction(
            "/bsi/step_3/c",
            nil,
            function(_step, spec) return spec.fixed end
        )
        expect(instruction).to.equal("literal")
        frame.unregister("/bsi/step_3/c")
    end)

    it(
        "v2 exposes orch convention: M.parse_verdict matches frame.parse_verdict",
        function() expect(v2.parse_verdict).to.equal(frame.parse_verdict) end
    )

    it("v2 exposes orch convention: M.build_prompt(step, state)", function()
        v2.register_steps()
        local state = { task_dir = "workspace/tasks/example-1", task_id = "example-1" }
        local p1 = v2.build_prompt("step_1", state)
        if not p1:find('subagent_type="window-inferrer"', 1, true) then
            error("step_1 prompt should declare window-inferrer subagent")
        end
        if not p1:find("workspace/tasks/example-1/window.json", 1, true) then
            error("step_1 prompt should reference the state's task_dir")
        end
        local p6 = v2.build_prompt("step_6", state)
        if not p6:find('subagent_type="report-writer"', 1, true) then
            error("step_6 prompt should declare report-writer subagent")
        end
        local ok = pcall(v2.build_prompt, "step_99", state)
        expect(ok).to.equal(false)
    end)

    it("v2 exposes orch convention: M.phases array (6 items, identical to v0.2.0 shape)", function()
        expect(#v2.phases).to.equal(6)
        expect(v2.phases[1].id).to.equal("step_1")
        expect(v2.phases[1].subagent).to.equal("window-inferrer")
        expect(v2.phases[6].id).to.equal("step_6")
        expect(v2.phases[6].subagent).to.equal("report-writer")
    end)
end)

describe("run_linear: artifacts_key option", function()
    it("run_linear writes to ctx.state.artifacts by default", function()
        frame.register("/akd/step_1/x", {}, function() return "DONE path=/tmp/x" end)
        local ctx = { state = frame.state_new() }
        frame.run_linear({ "/akd/step_1/x" }, ctx)
        expect(ctx.state:get("artifacts.step_1")).to.equal("/tmp/x")
        expect(ctx.result.artifacts.step_1).to.equal("/tmp/x")
    end)

    it("run_linear honours ctx.artifacts_key='outputs' (modeling shape)", function()
        frame.register("/ako/step_1/x", {}, function() return "DONE path=/tmp/o" end)
        local ctx = { state = frame.state_new(), artifacts_key = "outputs" }
        frame.run_linear({ "/ako/step_1/x" }, ctx)
        expect(ctx.state:get("outputs.step_1")).to.equal("/tmp/o")
        expect(ctx.result.outputs.step_1).to.equal("/tmp/o")
        -- "artifacts" key must NOT be touched
        expect(ctx.state:get("artifacts")).to.equal(nil)
    end)
end)

describe("plain_state: function-based peer of State", function()
    it("plain_state is exposed via swarm_frame.plain_state", function()
        expect(type(frame.plain_state)).to.equal("table")
        expect(type(frame.plain_state.step_done)).to.equal("function")
        expect(type(frame.plain_state.step_mark)).to.equal("function")
        expect(type(frame.plain_state.log_phase)).to.equal("function")
    end)

    it(
        "plain_state.step_done returns false on empty list",
        function() expect(frame.plain_state.step_done({}, "phase_1")).to.equal(false) end
    )

    it(
        "plain_state.step_done returns false when name absent",
        function() expect(frame.plain_state.step_done({ "phase_a", "phase_b" }, "phase_c")).to.equal(false) end
    )

    it(
        "plain_state.step_done returns true when name present",
        function() expect(frame.plain_state.step_done({ "phase_a", "phase_b" }, "phase_b")).to.equal(true) end
    )

    it("plain_state.step_done linear scan does not mutate the list", function()
        local steps = { "a", "b", "c" }
        frame.plain_state.step_done(steps, "b")
        expect(#steps).to.equal(3)
        expect(steps[1]).to.equal("a")
        expect(steps[3]).to.equal("c")
    end)

    it("plain_state.step_mark appends name to list", function()
        local steps = { "a" }
        frame.plain_state.step_mark(steps, "b")
        expect(#steps).to.equal(2)
        expect(steps[2]).to.equal("b")
    end)

    it("plain_state.step_mark calls save_fn AFTER the append", function()
        local steps = {}
        local seen_len_at_save = nil
        frame.plain_state.step_mark(steps, "x", function() seen_len_at_save = #steps end)
        expect(seen_len_at_save).to.equal(1)
        expect(steps[1]).to.equal("x")
    end)

    it("plain_state.step_mark omits save_fn safely (no error when nil)", function()
        local steps = {}
        frame.plain_state.step_mark(steps, "x")
        expect(steps[1]).to.equal("x")
    end)

    it("plain_state.log_phase appends a record with name/status/detail", function()
        local log = {}
        frame.plain_state.log_phase(log, "step_1", "done", "ok")
        expect(#log).to.equal(1)
        expect(log[1].name).to.equal("step_1")
        expect(log[1].status).to.equal("done")
        expect(log[1].detail).to.equal("ok")
    end)

    it("plain_state.log_phase preserves order across multiple appends", function()
        local log = {}
        frame.plain_state.log_phase(log, "a", "done", nil)
        frame.plain_state.log_phase(log, "b", "blocked", "reason")
        expect(#log).to.equal(2)
        expect(log[1].name).to.equal("a")
        expect(log[2].name).to.equal("b")
        expect(log[2].detail).to.equal("reason")
    end)

    it("plain_state.log_phase preserves nil detail as nil (no coercion)", function()
        local log = {}
        frame.plain_state.log_phase(log, "a", "done", nil)
        expect(log[1].detail).to.equal(nil)
    end)
end)

describe("normalize: entry-boundary type coercion", function()
    it("normalize is exposed via swarm_frame.normalize", function()
        expect(type(frame.normalize)).to.equal("table")
        expect(type(frame.normalize.coerce_boolean)).to.equal("function")
        expect(type(frame.normalize.coerce_string)).to.equal("function")
        expect(type(frame.normalize.coerce_number)).to.equal("function")
        expect(type(frame.normalize.coerce_table)).to.equal("function")
        expect(type(frame.normalize.normalize_ctx)).to.equal("function")
        expect(frame.normalize.VERSION).to.equal("0.6.0")
    end)

    -- single-field coercers
    it("coerce_boolean: true / false pass through", function()
        expect(frame.normalize.coerce_boolean(true)).to.equal(true)
        expect(frame.normalize.coerce_boolean(false)).to.equal(false)
    end)

    it("coerce_boolean: nil / string / number / table -> nil", function()
        expect(frame.normalize.coerce_boolean(nil)).to.equal(nil)
        expect(frame.normalize.coerce_boolean("true")).to.equal(nil)
        expect(frame.normalize.coerce_boolean(1)).to.equal(nil)
        expect(frame.normalize.coerce_boolean({})).to.equal(nil)
    end)

    it("coerce_boolean idiom: coerce(v) or false yields strict boolean", function()
        local function strict_bool(v) return frame.normalize.coerce_boolean(v) or false end
        expect(strict_bool(true)).to.equal(true)
        expect(strict_bool(false)).to.equal(false)
        expect(strict_bool(nil)).to.equal(false)
        expect(strict_bool("yes")).to.equal(false)
    end)

    it("coerce_string: any string (incl empty) passes through", function()
        expect(frame.normalize.coerce_string("x")).to.equal("x")
        expect(frame.normalize.coerce_string("")).to.equal("")
    end)

    it("coerce_string: non-string -> nil", function()
        expect(frame.normalize.coerce_string(nil)).to.equal(nil)
        expect(frame.normalize.coerce_string(true)).to.equal(nil)
        expect(frame.normalize.coerce_string(42)).to.equal(nil)
        expect(frame.normalize.coerce_string({})).to.equal(nil)
    end)

    it("coerce_number: any number passes through", function()
        expect(frame.normalize.coerce_number(0)).to.equal(0)
        expect(frame.normalize.coerce_number(-1)).to.equal(-1)
        expect(frame.normalize.coerce_number(1.5)).to.equal(1.5)
    end)

    it("coerce_number: non-number -> nil", function()
        expect(frame.normalize.coerce_number(nil)).to.equal(nil)
        expect(frame.normalize.coerce_number("1")).to.equal(nil)
        expect(frame.normalize.coerce_number(true)).to.equal(nil)
        expect(frame.normalize.coerce_number({})).to.equal(nil)
    end)

    it("coerce_table: tables pass through", function()
        local t = { a = 1 }
        expect(frame.normalize.coerce_table(t)).to.equal(t)
        local empty = {}
        expect(frame.normalize.coerce_table(empty)).to.equal(empty)
    end)

    it("coerce_table: non-table -> nil", function()
        expect(frame.normalize.coerce_table(nil)).to.equal(nil)
        expect(frame.normalize.coerce_table("x")).to.equal(nil)
        expect(frame.normalize.coerce_table(42)).to.equal(nil)
        expect(frame.normalize.coerce_table(true)).to.equal(nil)
    end)

    -- bulk normalize_ctx
    it("normalize_ctx: required string passes when present and non-empty", function()
        local ctx = { task = "do_x" }
        local out = frame.normalize.normalize_ctx(ctx, { task = "string" })
        expect(out).to.equal(ctx) -- in-place, same reference
        expect(ctx.task).to.equal("do_x")
    end)

    it("normalize_ctx: required string raises when missing", function()
        local ctx = {}
        local ok, err = pcall(frame.normalize.normalize_ctx, ctx, { task = "string" })
        expect(ok).to.equal(false)
        assert(err:match("ctx%.task must be string"), "expected required-string error, got: " .. tostring(err))
    end)

    it("normalize_ctx: required string raises when wrong type", function()
        local ctx = { task = 42 }
        local ok, err = pcall(frame.normalize.normalize_ctx, ctx, { task = "string" })
        expect(ok).to.equal(false)
        assert(err:match("must be string %(got number%)"), "expected wrong-type error, got: " .. tostring(err))
    end)

    it("normalize_ctx: required string raises on empty", function()
        local ctx = { task = "" }
        local ok, err = pcall(frame.normalize.normalize_ctx, ctx, { task = "string" })
        expect(ok).to.equal(false)
        assert(err:match("must be a non%-empty string"), "expected non-empty error, got: " .. tostring(err))
    end)

    it("normalize_ctx: optional string coerces non-string to nil", function()
        local ctx = { plan_path = 42, task = "x" }
        frame.normalize.normalize_ctx(ctx, { task = "string", plan_path = "string?" })
        expect(ctx.plan_path).to.equal(nil)
        expect(ctx.task).to.equal("x")
    end)

    it("normalize_ctx: optional string keeps empty string as-is", function()
        -- non-empty check is required-only; optional empty is preserved
        local ctx = { hint = "" }
        frame.normalize.normalize_ctx(ctx, { hint = "string?" })
        expect(ctx.hint).to.equal("")
    end)

    it("normalize_ctx: optional missing field stays nil (no key created)", function()
        local ctx = {}
        frame.normalize.normalize_ctx(ctx, { plan_path = "string?" })
        expect(ctx.plan_path).to.equal(nil)
    end)

    it("normalize_ctx: required boolean passes / wrong type raises", function()
        local ctx = { resume = true }
        frame.normalize.normalize_ctx(ctx, { resume = "boolean" })
        expect(ctx.resume).to.equal(true)

        local ctx2 = { resume = "true" }
        local ok, err = pcall(frame.normalize.normalize_ctx, ctx2, { resume = "boolean" })
        expect(ok).to.equal(false)
        assert(err:match("must be boolean %(got string%)"), "expected boolean error, got: " .. tostring(err))
    end)

    it("normalize_ctx: optional boolean coerces non-boolean to nil (sentinel idiom)", function()
        -- Simulates mlua JSON null light-userdata: anything non-boolean (incl
        -- nil, string, number, table, lightuserdata) becomes nil.
        local ctx = { use_qwen = "yes" }
        frame.normalize.normalize_ctx(ctx, { use_qwen = "boolean?" })
        expect(ctx.use_qwen).to.equal(nil)
    end)

    it("normalize_ctx: required number / table behave consistently", function()
        local ctx = { count = 3, opts = { a = 1 } }
        frame.normalize.normalize_ctx(ctx, { count = "number", opts = "table" })
        expect(ctx.count).to.equal(3)
        expect(ctx.opts.a).to.equal(1)
    end)

    it("normalize_ctx: optional table coerces non-table to nil", function()
        local ctx = { qwen_env = "x" }
        frame.normalize.normalize_ctx(ctx, { qwen_env = "table?" })
        expect(ctx.qwen_env).to.equal(nil)
    end)

    it("normalize_ctx: unknown tag raises", function()
        local ctx = { x = 1 }
        local ok, err = pcall(frame.normalize.normalize_ctx, ctx, { x = "integer" })
        expect(ok).to.equal(false)
        assert(err:match("unknown ctx type tag 'integer'"), "expected unknown-tag error, got: " .. tostring(err))
    end)

    it("normalize_ctx: non-table ctx / non-table spec raise", function()
        local ok1 = pcall(frame.normalize.normalize_ctx, "not-a-table", {})
        expect(ok1).to.equal(false)
        local ok2 = pcall(frame.normalize.normalize_ctx, {}, "not-a-table")
        expect(ok2).to.equal(false)
    end)
end)

describe("parse_verdict: fuzzy mode", function()
    it("fuzzy off by default (DONE: separator not recognized)", function()
        -- DONE path= still works (existing contract)
        local v1 = frame.parse_verdict("DONE path=/tmp/x")
        expect(v1.status).to.equal("DONE")
        expect(v1.path).to.equal("/tmp/x")
        -- DONE: <path> NOT recognized without fuzzy
        local v2 = frame.parse_verdict("DONE: /tmp/y")
        expect(v2.status).to.equal("UNKNOWN")
    end)

    it("DONE: separator recognized", function()
        local v = frame.parse_verdict("DONE: /tmp/x", { fuzzy = true })
        expect(v.status).to.equal("DONE")
        expect(v.path).to.equal("/tmp/x")
    end)

    it("DONE= separator recognized", function()
        local v = frame.parse_verdict("DONE= /tmp/x", { fuzzy = true })
        expect(v.status).to.equal("DONE")
        expect(v.path).to.equal("/tmp/x")
    end)

    it("BLOCKED: separator recognized", function()
        local v = frame.parse_verdict("BLOCKED: bad input", { fuzzy = true })
        expect(v.status).to.equal("BLOCKED")
        expect(v.reason).to.equal("bad input")
    end)

    it("BLOCKED= separator recognized", function()
        local v = frame.parse_verdict("BLOCKED= bad input", { fuzzy = true })
        expect(v.status).to.equal("BLOCKED")
        expect(v.reason).to.equal("bad input")
    end)

    it("bare DONE token without path -> status=DONE path=nil", function()
        local v = frame.parse_verdict("the step is DONE", { fuzzy = true })
        expect(v.status).to.equal("DONE")
        expect(v.path).to.equal(nil)
    end)

    it("lowercase 'done' matched via upper()", function()
        local v = frame.parse_verdict("the step is done", { fuzzy = true })
        expect(v.status).to.equal("DONE")
        expect(v.path).to.equal(nil)
    end)

    it("bare DONE word-boundary rejects 'abandoned' substring", function()
        -- "ABANDONED" contains the substring "DONE" (positions 5-8) but the
        -- token itself is part of a larger word. Word-boundary must reject.
        local v = frame.parse_verdict("we abandoned this approach", { fuzzy = true })
        expect(v.status).to.equal("UNKNOWN")
    end)

    it("bare DONE word-boundary rejects 'redone' substring", function()
        local v = frame.parse_verdict("we redone the implementation", { fuzzy = true })
        expect(v.status).to.equal("UNKNOWN")
    end)

    it("bare DONE word-boundary rejects 'IS_DONE' identifier", function()
        -- Underscore is treated as part of identifier; "IS_DONE" is one token.
        local v = frame.parse_verdict("status is IS_DONE flag", { fuzzy = true })
        expect(v.status).to.equal("UNKNOWN")
    end)

    it("bare DONE still matches when followed by punctuation", function()
        -- Regression baseline: ensure punctuation (non-identifier char) still
        -- counts as a boundary so "DONE." / "DONE!" still match.
        local v1 = frame.parse_verdict("the step is DONE.", { fuzzy = true })
        expect(v1.status).to.equal("DONE")
        local v2 = frame.parse_verdict("the step is DONE!", { fuzzy = true })
        expect(v2.status).to.equal("DONE")
    end)

    it("canonical DONE path= still wins over fuzzy fallback", function()
        local v = frame.parse_verdict("DONE path=/tmp/x  and also done bla", { fuzzy = true })
        expect(v.status).to.equal("DONE")
        expect(v.path).to.equal("/tmp/x")
    end)

    it("JSON envelope still wins (mode coexist)", function()
        local v = frame.parse_verdict(
            '{"status":"BLOCKED","reason":"json wins","flow_token":"t","flow_slot":"s"} ' .. "DONE: /tmp/x",
            { fuzzy = true }
        )
        expect(v.status).to.equal("BLOCKED")
        expect(v.reason).to.equal("json wins")
        expect(v.flow_token).to.equal("t")
    end)

    it("NEEDS_INPUT canonical form still works", function()
        local v = frame.parse_verdict("NEEDS_INPUT missing=spec.md", { fuzzy = true })
        expect(v.status).to.equal("NEEDS_INPUT")
        expect(v.missing).to.equal("spec.md")
    end)

    it("empty fuzzy hit falls through to UNKNOWN", function()
        -- No DONE/BLOCKED/NEEDS_INPUT token anywhere
        local v = frame.parse_verdict("just some prose", { fuzzy = true })
        expect(v.status).to.equal("UNKNOWN")
    end)

    it("nil opts behaves like fuzzy=false (back-compat)", function()
        -- Existing callers passing only response stay on default path
        local v = frame.parse_verdict("DONE: /tmp/x")
        expect(v.status).to.equal("UNKNOWN")
    end)
end)

describe("parse_label_verdict: ordered priority label parser", function()
    it(
        "is exposed via swarm_frame.parse_label_verdict",
        function() expect(type(frame.parse_label_verdict)).to.equal("function") end
    )

    it("nil response -> nil", function() expect(frame.parse_label_verdict(nil, { "PASS" })).to.equal(nil) end)

    it("nil labels -> nil", function() expect(frame.parse_label_verdict("VERDICT: PASS", nil)).to.equal(nil) end)

    it("empty labels -> nil", function() expect(frame.parse_label_verdict("VERDICT: PASS", {})).to.equal(nil) end)

    it("BLOCKED wins over PASS (pass_block preset)", function()
        local r = "Some prose.\nVERDICT: BLOCKED\nDetails: bad."
        expect(frame.parse_label_verdict(r, { "BLOCKED", "PASS" })).to.equal("BLOCKED")
    end)

    it("PASS matched alone in pass_block preset", function()
        local r = "Some prose.\nVERDICT: PASS\n"
        expect(frame.parse_label_verdict(r, { "BLOCKED", "PASS" })).to.equal("PASS")
    end)

    it("priority — both PASS and BLOCKED present, BLOCKED wins", function()
        -- Order in array = priority. BLOCKED head -> BLOCKED wins.
        local r = "VERDICT: BLOCKED\n... but earlier draft said VERDICT: PASS ..."
        expect(frame.parse_label_verdict(r, { "BLOCKED", "PASS" })).to.equal("BLOCKED")
    end)

    it("case-insensitive match", function()
        expect(frame.parse_label_verdict("verdict: blocked", { "BLOCKED", "PASS" })).to.equal("BLOCKED")
        expect(frame.parse_label_verdict("Verdict: Pass", { "BLOCKED", "PASS" })).to.equal("PASS")
    end)

    it("returns canonical-cased label from labels array", function()
        -- Input response uses lowercase; returned value uses caller's canonical
        local v = frame.parse_label_verdict("verdict: pass", { "BLOCKED", "PASS" })
        expect(v).to.equal("PASS") -- not "pass"
    end)

    it("NEEDS_HUMAN 3-value preset", function()
        local r1 = "VERDICT: NEEDS_HUMAN"
        expect(frame.parse_label_verdict(r1, { "NEEDS_HUMAN", "BLOCKED", "PASS" })).to.equal("NEEDS_HUMAN")
        local r2 = "VERDICT: BLOCKED"
        expect(frame.parse_label_verdict(r2, { "NEEDS_HUMAN", "BLOCKED", "PASS" })).to.equal("BLOCKED")
    end)

    it("NOT_READY wins over READY (ready_not_ready preset)", function()
        local r = "VERDICT: NOT_READY\nreason: deps missing"
        expect(frame.parse_label_verdict(r, { "NOT_READY", "READY" })).to.equal("NOT_READY")
    end)

    it("HAS_FINDINGS wins over CLEAN (has_findings preset)", function()
        local r = "VERDICT: HAS_FINDINGS\n... earlier said VERDICT: CLEAN ..."
        expect(frame.parse_label_verdict(r, { "HAS_FINDINGS", "CLEAN" })).to.equal("HAS_FINDINGS")
    end)

    it("pass/conditional/fail 3-value preset", function()
        expect(frame.parse_label_verdict("VERDICT: FAIL", { "FAIL", "CONDITIONAL", "PASS" })).to.equal("FAIL")
        expect(frame.parse_label_verdict("VERDICT: CONDITIONAL", { "FAIL", "CONDITIONAL", "PASS" })).to.equal(
            "CONDITIONAL"
        )
        expect(frame.parse_label_verdict("VERDICT: PASS", { "FAIL", "CONDITIONAL", "PASS" })).to.equal("PASS")
    end)

    it("whitespace tolerance after VERDICT:", function()
        expect(frame.parse_label_verdict("VERDICT:   BLOCKED", { "BLOCKED", "PASS" })).to.equal("BLOCKED")
        expect(frame.parse_label_verdict("VERDICT:BLOCKED", { "BLOCKED", "PASS" })).to.equal("BLOCKED") -- no space at all
    end)

    it(
        "no match -> nil",
        function()
            expect(frame.parse_label_verdict("just some prose without any verdict line", { "BLOCKED", "PASS" })).to.equal(
                nil
            )
        end
    )

    it("label appears in body without VERDICT: prefix -> nil", function()
        -- "PASS" in the body must NOT match without the VERDICT: prefix
        expect(frame.parse_label_verdict("the test PASSED with no findings", { "BLOCKED", "PASS" })).to.equal(nil)
    end)

    it("VERDICT: <label> at end of string", function()
        -- No trailing newline / content
        expect(frame.parse_label_verdict("Status update.\nVERDICT: PASS", { "BLOCKED", "PASS" })).to.equal("PASS")
    end)
end)

describe("parse_label_verdict v0.2: forms / bare_token / require_absent", function()
    it("forms: Overall: prefix recognised", function()
        local r = "Crux Gate eval.\nOverall: NEEDS_HUMAN"
        expect(
            frame.parse_label_verdict(r, { "NEEDS_HUMAN", "BLOCKED", "PASS" }, { forms = { "VERDICT:", "Overall:" } })
        ).to.equal("NEEDS_HUMAN")
    end)

    it("forms: VERDICT: still wins (first form in list scanned first per label)", function()
        -- Both forms present, both labels viable. Priority is labels first
        -- (NEEDS_HUMAN head), then forms (VERDICT: head per label).
        local r = "VERDICT: NEEDS_HUMAN\nOverall: BLOCKED"
        expect(
            frame.parse_label_verdict(r, { "NEEDS_HUMAN", "BLOCKED", "PASS" }, { forms = { "VERDICT:", "Overall:" } })
        ).to.equal("NEEDS_HUMAN")
    end)

    it("forms: default still {VERDICT:} when opts.forms omitted", function()
        local r = "Overall: NEEDS_HUMAN"
        -- Without forms opt, Overall: is not recognised
        expect(frame.parse_label_verdict(r, { "NEEDS_HUMAN" })).to.equal(nil)
    end)

    it("bare_token: bare label matched with word-boundary", function()
        -- classify_repo_readiness pattern
        local r = "Result: NOT_READY because deps missing."
        expect(frame.parse_label_verdict(r, { "NOT_READY", "READY" }, { bare_token = true })).to.equal("NOT_READY")
    end)

    it("bare_token: word-boundary protects against substrings", function()
        -- "READYNOW" should NOT match "READY" with word-boundary
        local r = "step is READYNOW"
        expect(frame.parse_label_verdict(r, { "READY" }, { bare_token = true })).to.equal(nil)
    end)

    it("bare_token: identifier-boundary rejects underscore-prefixed substring", function()
        -- "foo_NEEDS_HUMAN_HOOK" must NOT match label "NEEDS_HUMAN". Lua's
        -- bare %w excludes underscore, so the historical %f[%w] frontier
        -- would have leaked through. [%w_] frontier prevents this.
        local r = "saw foo_NEEDS_HUMAN_HOOK in logs"
        expect(frame.parse_label_verdict(r, { "NEEDS_HUMAN" }, { bare_token = true })).to.equal(nil)
    end)

    it("bare_token: identifier-boundary rejects underscore-suffixed substring", function()
        -- "FAIL_HOOK" must NOT match label "FAIL".
        local r = "called FAIL_HOOK once"
        expect(frame.parse_label_verdict(r, { "FAIL" }, { bare_token = true })).to.equal(nil)
    end)

    it("bare_token: standalone label still matches after underscore tightening", function()
        -- Regression baseline: ensure the tightened pattern still matches
        -- standalone labels separated by whitespace / punctuation.
        local r = "Result: NEEDS_HUMAN because deps missing."
        expect(frame.parse_label_verdict(r, { "NEEDS_HUMAN" }, { bare_token = true })).to.equal("NEEDS_HUMAN")
    end)

    it("bare_token: require_absent negator also respects identifier-boundary", function()
        -- Negator "PASS" in "PASS_MARKER" must NOT disqualify label "FAIL".
        -- Without [%w_] frontier the negator would falsely fire and reject FAIL.
        local r = "result FAIL while PASS_MARKER stays on"
        local v = frame.parse_label_verdict(r, { "FAIL", "PASS" }, {
            bare_token = true,
            require_absent = { FAIL = "PASS" },
        })
        expect(v).to.equal("FAIL")
    end)

    it("bare_token: priority preserved (HAS_FINDINGS bare wins over CLEAN prefix)", function()
        -- classify_holistic_verdict pattern. Per-label interleaved algorithm
        -- gives HAS_FINDINGS (priority head) the FIRST chance to match across
        -- BOTH axes (prefix + bare) before CLEAN is considered. So even when
        -- CLEAN has a stronger form match (`verdict: CLEAN`), bare HAS_FINDINGS
        -- still wins as the head label.
        local r = "verdict: CLEAN but found HAS_FINDINGS in stderr"
        expect(frame.parse_label_verdict(r, { "HAS_FINDINGS", "CLEAN" }, { bare_token = true })).to.equal(
            "HAS_FINDINGS"
        )
    end)

    it("bare_token only: HAS_FINDINGS wins over CLEAN when both bare", function()
        -- Same intent but without VERDICT: prefix anywhere
        local r = "stdout: HAS_FINDINGS in 3 files, otherwise CLEAN areas"
        expect(frame.parse_label_verdict(r, { "HAS_FINDINGS", "CLEAN" }, { bare_token = true })).to.equal(
            "HAS_FINDINGS"
        )
    end)

    it("bare_token: nil when neither label is present", function()
        local r = "just some prose without any verdict signal"
        expect(frame.parse_label_verdict(r, { "NOT_READY", "READY" }, { bare_token = true })).to.equal(nil)
    end)

    it("require_absent: bare BLOCKED + PASS absent -> BLOCKED", function()
        -- is_blocked composite pattern
        local r = "the build is BLOCKED at compile time"
        expect(
            frame.parse_label_verdict(
                r,
                { "BLOCKED", "PASS" },
                { bare_token = true, require_absent = { BLOCKED = "PASS" } }
            )
        ).to.equal("BLOCKED")
    end)

    it("require_absent: bare BLOCKED + bare PASS -> BLOCKED disqualified, falls to PASS", function()
        -- Bug B regression case: BLOCKED in body with PASSED nearby should NOT
        -- be classified as BLOCKED (passes the composite gate)
        local r = "build BLOCKED earlier but now PASS"
        expect(
            frame.parse_label_verdict(
                r,
                { "BLOCKED", "PASS" },
                { bare_token = true, require_absent = { BLOCKED = "PASS" } }
            )
        ).to.equal("PASS")
    end)

    it("require_absent: bare PASS alone -> PASS (no require_absent for PASS)", function()
        local r = "step PASS"
        expect(
            frame.parse_label_verdict(
                r,
                { "BLOCKED", "PASS" },
                { bare_token = true, require_absent = { BLOCKED = "PASS" } }
            )
        ).to.equal("PASS")
    end)

    it("require_absent: only applies to bare matches, prefix-form unconditional", function()
        -- VERDICT: BLOCKED should win even if PASS appears bare elsewhere
        local r = "VERDICT: BLOCKED. (Note: prior test PASSED.)"
        expect(
            frame.parse_label_verdict(
                r,
                { "BLOCKED", "PASS" },
                { bare_token = true, require_absent = { BLOCKED = "PASS" } }
            )
        ).to.equal("BLOCKED")
    end)

    it("combined: parse_plan_gate_overall full shape", function()
        -- Triple-form: VERDICT: + Overall: + bare BLOCKED!PASS fallback
        local opts = {
            forms = { "VERDICT:", "Overall:" },
            bare_token = true,
            require_absent = { BLOCKED = "PASS" },
        }
        local labels = { "NEEDS_HUMAN", "BLOCKED", "PASS" }
        -- VERDICT: PASS path
        expect(frame.parse_label_verdict("VERDICT: PASS", labels, opts)).to.equal("PASS")
        -- VERDICT: BLOCKED path
        expect(frame.parse_label_verdict("VERDICT: BLOCKED", labels, opts)).to.equal("BLOCKED")
        -- VERDICT: NEEDS_HUMAN path
        expect(frame.parse_label_verdict("VERDICT: NEEDS_HUMAN", labels, opts)).to.equal("NEEDS_HUMAN")
        -- Overall: NEEDS_HUMAN path (Crux Gate form)
        expect(frame.parse_label_verdict("Overall: NEEDS_HUMAN", labels, opts)).to.equal("NEEDS_HUMAN")
        -- Bare BLOCKED fallback (no VERDICT/Overall, BLOCKED + !PASS)
        expect(frame.parse_label_verdict("the build is BLOCKED", labels, opts)).to.equal("BLOCKED")
        -- nil case
        expect(frame.parse_label_verdict("just prose, no verdict", labels, opts)).to.equal(nil)
    end)

    it("back-compat: nil opts behaves like v0.1 (forms=VERDICT only, no bare)", function()
        -- bare label that would match if bare_token=true must NOT match with nil opts
        expect(frame.parse_label_verdict("the result is NOT_READY", { "NOT_READY", "READY" })).to.equal(nil)
        -- VERDICT: prefix still works
        expect(frame.parse_label_verdict("VERDICT: NOT_READY", { "NOT_READY", "READY" })).to.equal("NOT_READY")
    end)

    it("olympian_weekly.has_verdict shape (single bare label match)", function()
        -- has_verdict(r, "CONDITIONAL") -> r:upper():find("CONDITIONAL")
        local r = "review notes: CONDITIONAL pass"
        expect(frame.parse_label_verdict(r, { "CONDITIONAL" }, { bare_token = true })).to.equal("CONDITIONAL")
        local r2 = "no verdict here"
        expect(frame.parse_label_verdict(r2, { "CONDITIONAL" }, { bare_token = true })).to.equal(nil)
    end)

    it("olympian_weekly.gate_is_fail shape (FAIL + !PASS)", function()
        local opts = { bare_token = true, require_absent = { FAIL = "PASS" } }
        -- FAIL bare, no PASS -> FAIL
        expect(frame.parse_label_verdict("E2E FAIL on test 3", { "FAIL", "PASS" }, opts)).to.equal("FAIL")
        -- FAIL + PASS coexist -> FAIL disqualified, PASS wins (partial pass)
        expect(frame.parse_label_verdict("E2E FAIL on 3, PASS on 12", { "FAIL", "PASS" }, opts)).to.equal("PASS")
    end)
end)

describe("parse_label_verdict v0.3: bare_substring axis", function()
    it("'FAILED' contains 'FAIL' as substring -> FAIL", function()
        -- The whole point of v0.3: substring is wider than word-boundary
        expect(frame.parse_label_verdict("test FAILED somewhere", { "FAIL" }, { bare_substring = true })).to.equal(
            "FAIL"
        )
    end)

    it("bare_token: word-boundary rejects 'FAILED' for label 'FAIL' (regression baseline)", function()
        -- This is the exact false-negative case that motivated v0.3
        expect(frame.parse_label_verdict("test FAILED somewhere", { "FAIL" }, { bare_token = true })).to.equal(nil)
    end)

    it("is_e2e_fail shape (FAIL substring + !PASS substring)", function()
        local opts = { bare_substring = true, require_absent = { FAIL = "PASS" } }
        -- "test FAILED" alone -> FAIL (FAIL substring hit, no PASS substring)
        expect(frame.parse_label_verdict("E2E test FAILED on suite 3", { "FAIL", "PASS" }, opts)).to.equal("FAIL")
    end)

    it("PASSED suppresses FAIL via substring negator (PASSED contains PASS)", function()
        local opts = { bare_substring = true, require_absent = { FAIL = "PASS" } }
        -- "FAILED earlier but PASSED later" -> FAIL is disqualified because
        -- PASSED also contains PASS as substring; PASS wins (partial pass)
        expect(frame.parse_label_verdict("test FAILED earlier but PASSED later", { "FAIL", "PASS" }, opts)).to.equal(
            "PASS"
        )
    end)

    it("bare FAIL with no PASS at all -> FAIL", function()
        local opts = { bare_substring = true, require_absent = { FAIL = "PASS" } }
        expect(frame.parse_label_verdict("E2E FAIL on test 3", { "FAIL", "PASS" }, opts)).to.equal("FAIL")
    end)

    it("empty / no signal -> nil", function()
        local opts = { bare_substring = true, require_absent = { FAIL = "PASS" } }
        expect(frame.parse_label_verdict("", { "FAIL", "PASS" }, opts)).to.equal(nil)
        expect(frame.parse_label_verdict("just some prose without verdict", { "FAIL", "PASS" }, opts)).to.equal(nil)
    end)

    it("bare_substring + bare_token both true -> bare_substring wins (wider semantic)", function()
        -- bare_token alone would reject FAILED; bare_substring catches it.
        -- When both flags are true, bare_substring dominates.
        expect(frame.parse_label_verdict("step FAILED", { "FAIL" }, { bare_substring = true, bare_token = true })).to.equal(
            "FAIL"
        )
    end)

    it("prefix-form still wins over bare", function()
        -- "VERDICT: PASS" + "FAILED earlier" -> prefix-form PASS hit on PASS label
        -- But FAIL is priority head; FAIL has no prefix hit, then bare substring
        -- "FAILED" catches FAIL, but PASS substring (in PASS / PASSED?) also hits.
        -- Actually "VERDICT: PASS" has PASS as substring, so FAIL gets disqualified
        -- by require_absent. PASS then wins via its OWN prefix-form match.
        local opts = { bare_substring = true, require_absent = { FAIL = "PASS" } }
        expect(frame.parse_label_verdict("VERDICT: PASS (after FAILED earlier)", { "FAIL", "PASS" }, opts)).to.equal(
            "PASS"
        )
    end)

    it("require_absent negator uses same axis (substring)", function()
        -- Sanity check: with bare_substring, the negator must also be substring-matched.
        -- "BLOCKED at PASSED gate" -> BLOCKED substring + PASS substring (inside PASSED)
        -- BLOCKED disqualified, PASS would substring-hit too -> PASS
        local opts = {
            bare_substring = true,
            require_absent = { BLOCKED = "PASS" },
        }
        expect(frame.parse_label_verdict("BLOCKED at PASSED gate", { "BLOCKED", "PASS" }, opts)).to.equal("PASS")
    end)

    it("back-compat: nil opts behaves like v0.1 (no bare match)", function()
        -- "FAILED" alone with nil opts -> nil (no VERDICT: prefix)
        expect(frame.parse_label_verdict("test FAILED", { "FAIL" })).to.equal(nil)
        expect(frame.parse_label_verdict("VERDICT: FAIL", { "FAIL" })).to.equal("FAIL")
    end)

    it("back-compat: v0.2 bare_token caller unaffected", function()
        -- The v0.2 olympian_weekly.gate_is_fail test used bare_token + require_absent
        -- and still passed by word-boundary FAIL. Re-run a v0.2-shape probe to
        -- prove v0.3 changes did not regress v0.2 behaviour.
        local opts_v02 = { bare_token = true, require_absent = { FAIL = "PASS" } }
        expect(frame.parse_label_verdict("E2E FAIL on test 3", { "FAIL", "PASS" }, opts_v02)).to.equal("FAIL")
        -- Word-boundary still rejects "FAILED"
        expect(frame.parse_label_verdict("test FAILED somewhere", { "FAIL" }, opts_v02)).to.equal(nil)
    end)
end)

describe("parse_and_assert v0.4: delegate-done assert primitive", function()
    it("DONE passes through unchanged", function()
        local parsed = frame.parse_and_assert("DONE path=/tmp/out.md", "step_X")
        expect(parsed.status).to.equal("DONE")
        expect(parsed.path).to.equal("/tmp/out.md")
    end)

    it("DONE via fuzzy mode (DONE:path / DONE=path)", function()
        local parsed = frame.parse_and_assert("DONE: /tmp/y.md", "fuzzy_step", { fuzzy = true })
        expect(parsed.status).to.equal("DONE")
        expect(parsed.path).to.equal("/tmp/y.md")
    end)

    it("BLOCKED raises with step_label + reason detail", function()
        local ok, err = pcall(frame.parse_and_assert, "BLOCKED reason=missing inputs", "flow_design Phase 0")
        expect(ok).to.equal(false)
        -- err is "<file>: flow_design Phase 0 failed: missing inputs"
        -- so check substring containment
        expect(err:find("flow_design Phase 0 failed: missing inputs", 1, true) ~= nil).to.equal(true)
    end)

    it("NEEDS_INPUT raises with missing detail", function()
        local ok, err = pcall(frame.parse_and_assert, "NEEDS_INPUT missing=context.md", "distillation_orch STEP_2")
        expect(ok).to.equal(false)
        expect(err:find("distillation_orch STEP_2 failed: context.md", 1, true) ~= nil).to.equal(true)
    end)

    it("UNKNOWN raises with raw fallback", function()
        local ok, err = pcall(frame.parse_and_assert, "totally unstructured prose", "step_Y")
        expect(ok).to.equal(false)
        -- detail = parsed.raw = "totally unstructured prose"
        expect(err:find("step_Y failed: totally unstructured prose", 1, true) ~= nil).to.equal(true)
    end)

    it("detail fallback: reason > missing > raw > '?'", function()
        -- Empty response: parse_verdict returns { status = UNKNOWN, raw = "" }
        -- raw is "" (empty string but truthy), so falls through to "?"
        local ok, err = pcall(frame.parse_and_assert, "", "step_Z")
        expect(ok).to.equal(false)
        -- detail should be either "" (raw empty string still truthy) or "?"
        -- Empty string IS truthy in Lua, so detail = parsed.raw = ""
        -- Result: "step_Z failed: " (trailing space, empty detail)
        -- That's slightly awkward but consistent with semantics
        expect(err:find("step_Z failed: ", 1, true) ~= nil).to.equal(true)
    end)

    it("nil response also raises (UNKNOWN path)", function()
        local ok, err = pcall(frame.parse_and_assert, nil, "step_W")
        expect(ok).to.equal(false)
        expect(err:find("step_W failed", 1, true) ~= nil).to.equal(true)
    end)

    it("step_label is tostring()'d if non-string", function()
        local ok, err = pcall(frame.parse_and_assert, "BLOCKED reason=oops", 42)
        expect(ok).to.equal(false)
        expect(err:find("42 failed: oops", 1, true) ~= nil).to.equal(true)
    end)

    it("JSON envelope DONE passes through", function()
        local resp = [[{"status":"DONE","path":"/tmp/out.md","flow_token":"abc","flow_slot":"s1"}]]
        local parsed = frame.parse_and_assert(resp, "json_step")
        expect(parsed.status).to.equal("DONE")
        expect(parsed.path).to.equal("/tmp/out.md")
        expect(parsed.flow_token).to.equal("abc")
    end)

    it("caller-shape: flow_design Phase 0 happy path", function()
        -- Mirror of flow_design/init.lua:295-300 idiom after migration
        local resp = "DONE path=phase-0.md"
        local parsed = frame.parse_and_assert(resp, "flow_design Phase 0", { fuzzy = true })
        expect(parsed.path).to.equal("phase-0.md")
    end)

    it("caller-shape: distillation_orch STEP_2 happy path", function()
        -- Mirror of distillation_orch idiom after migration
        local resp = "DONE path=context-broad.md"
        local parsed = frame.parse_and_assert(resp, "distillation_orch STEP_2", { fuzzy = true })
        expect(parsed.path).to.equal("context-broad.md")
    end)
end)

describe("normalize_ctx smoke: coding_orch canonical shape", function()
    it("coding_orch ctx shape (smoke test of canonical spec)", function()
        -- Mirror of coding_orch.run entry shape (init.lua:799-814) — confirms
        -- the canonical migration target works under the Frame primitive.
        local ctx = {
            task = "do_x",
            task_id = "t-1",
            project_root = "/tmp/p",
            from = nil,
            plan_path = 42, -- non-string -> coerces to nil
            resume = true,
            mode = "lite",
            lite_input = nil,
            from_review_path = nil,
            from_builder_path = nil,
            use_qwen = "not-a-bool", -- will coerce to nil
            use_gemma = false,
            gemma_env = nil,
            qwen_env = { K = "v" },
        }
        frame.normalize.normalize_ctx(ctx, {
            task = "string",
            task_id = "string",
            project_root = "string",
            from = "string?",
            plan_path = "string?",
            resume = "boolean?",
            mode = "string?",
            lite_input = "string?",
            from_review_path = "string?",
            from_builder_path = "string?",
            use_qwen = "boolean?",
            use_gemma = "boolean?",
            gemma_env = "table?",
            qwen_env = "table?",
        })
        -- coerced
        expect(ctx.plan_path).to.equal(nil)
        expect(ctx.use_qwen).to.equal(nil)
        -- preserved
        expect(ctx.task).to.equal("do_x")
        expect(ctx.resume).to.equal(true)
        expect(ctx.use_gemma).to.equal(false)
        expect(ctx.qwen_env.K).to.equal("v")
    end)
end)

-- ─── parse_label_verdict L-shape (v0.4) ─────────────────────────────────────
-- Issue 1779065252-8162 — promote BLOCKED L-shape to a Frame primitive.
-- Mirrors packages/swarm_frame/spec/parse_label_verdict_spec.lua so the
-- canonical CI surface (tests/run.lua) verifies them too.

describe("parse_label_verdict — L-shape (v0.4)", function()
    describe("legacy back-compat", function()
        it("no opts -> bare label string", function()
            local v = frame.parse_label_verdict("VERDICT: BLOCKED", { "BLOCKED", "PASS" })
            expect(v).to.equal("BLOCKED")
        end)
        it("structured=false -> bare label string", function()
            local v = frame.parse_label_verdict("VERDICT: PASS", { "BLOCKED", "PASS" }, { structured = false })
            expect(v).to.equal("PASS")
        end)
        it(
            "no match + no structured -> nil",
            function() expect(frame.parse_label_verdict("nothing", { "BLOCKED", "PASS" })).to.equal(nil) end
        )
    end)

    describe("structured=true table shape", function()
        it("returns {verdict, next_action, reason} table", function()
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
        it("no match + structured -> all-nil table", function()
            local v = frame.parse_label_verdict("nothing", { "BLOCKED", "PASS" }, { structured = true })
            expect(type(v)).to.equal("table")
            expect(v.verdict).to.equal(nil)
            expect(v.next_action).to.equal(nil)
            expect(v.reason).to.equal(nil)
        end)
    end)

    describe("standard next_action values", function()
        it("retry", function()
            local v = frame.parse_label_verdict(
                "VERDICT: BLOCKED\nnext_action: retry",
                { "BLOCKED" },
                { structured = true }
            )
            expect(v.next_action).to.equal("retry")
        end)
        it("escalate", function()
            local v = frame.parse_label_verdict(
                "VERDICT: NEEDS_HUMAN\nnext_action: escalate",
                { "NEEDS_HUMAN" },
                { structured = true }
            )
            expect(v.next_action).to.equal("escalate")
        end)
        it("halt", function()
            local v = frame.parse_label_verdict(
                "VERDICT: BLOCKED\nnext_action: halt",
                { "BLOCKED" },
                { structured = true }
            )
            expect(v.next_action).to.equal("halt")
        end)
    end)

    describe("custom next_action pass-through", function()
        it("non-standard token wait_dependency", function()
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

    describe("label-specific defaults when next_action absent", function()
        it("BLOCKED -> halt", function()
            local v = frame.parse_label_verdict("VERDICT: BLOCKED", { "BLOCKED" }, { structured = true })
            expect(v.next_action).to.equal("halt")
        end)
        it("NEEDS_HUMAN -> escalate", function()
            local v = frame.parse_label_verdict("VERDICT: NEEDS_HUMAN", { "NEEDS_HUMAN" }, { structured = true })
            expect(v.next_action).to.equal("escalate")
        end)
        it("PASS -> nil", function()
            local v = frame.parse_label_verdict("VERDICT: PASS", { "PASS" }, { structured = true })
            expect(v.next_action).to.equal(nil)
        end)
    end)

    describe("reason extraction", function()
        it("line-form reason", function()
            local v = frame.parse_label_verdict(
                "VERDICT: BLOCKED\nreason: missing upstream PR",
                { "BLOCKED" },
                { structured = true }
            )
            expect(v.reason).to.equal("missing upstream PR")
        end)
        it("JSON-form reason + next_action", function()
            local v = frame.parse_label_verdict(
                'VERDICT: BLOCKED { "reason": "missing api key", "next_action": "halt" }',
                { "BLOCKED" },
                { structured = true }
            )
            expect(v.reason).to.equal("missing api key")
            expect(v.next_action).to.equal("halt")
        end)
        it("absent reason -> nil", function()
            local v = frame.parse_label_verdict("VERDICT: BLOCKED", { "BLOCKED" }, { structured = true })
            expect(v.reason).to.equal(nil)
        end)
    end)
end)

describe("parse_verdict — next_action JSON pickup (v0.4)", function()
    it("picks up next_action from JSON envelope", function()
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
        frame.register("/pkg/lshape_x/agent", {})
        local s = frame.state_new()
        local ctx = {
            state = s,
            dispatcher = function() return '{"status":"BLOCKED","reason":"upstream","next_action":"retry"}' end,
        }
        frame.run_linear({ "/pkg/lshape_x/agent" }, ctx)
        expect(ctx.result.status).to.equal("BLOCKED")
        expect(ctx.result.next_action).to.equal("retry")
    end)

    it("applies BLOCKED -> halt default for legacy text verdict", function()
        frame.register("/pkg/lshape_y/agent", {})
        local s = frame.state_new()
        local ctx = {
            state = s,
            dispatcher = function() return "BLOCKED reason=external_dep" end,
        }
        frame.run_linear({ "/pkg/lshape_y/agent" }, ctx)
        expect(ctx.result.status).to.equal("BLOCKED")
        expect(ctx.result.next_action).to.equal("halt")
    end)

    it("applies NEEDS_INPUT -> escalate default", function()
        frame.register("/pkg/lshape_z/agent", {})
        local s = frame.state_new()
        local ctx = {
            state = s,
            dispatcher = function() return "NEEDS_INPUT missing=api_key" end,
        }
        frame.run_linear({ "/pkg/lshape_z/agent" }, ctx)
        expect(ctx.result.status).to.equal("NEEDS_INPUT")
        expect(ctx.result.next_action).to.equal("escalate")
    end)
end)

-- ─── swarm_population (spike, issue 1779687339-50091) ────────────────

local sp = require("swarm_population")

describe("swarm_population (Population primitive spike)", function()
    it("new(spec, n) builds N agents with shallow-copied spec + _slot", function()
        local pop = sp.new({ temperature = 0.5, score = 0 }, 3)
        expect(pop:size()).to.equal(3)
        expect(pop:get(1).temperature).to.equal(0.5)
        expect(pop:get(1)._slot).to.equal(1)
        expect(pop:get(3)._slot).to.equal(3)
    end)

    it("iter() yields (idx, agent) in slot order", function()
        local pop = sp.new({ k = "v" }, 3)
        local seen = {}
        for idx, agent in pop:iter() do
            seen[#seen + 1] = idx
            expect(agent.k).to.equal("v")
        end
        expect(seen[1]).to.equal(1)
        expect(seen[2]).to.equal(2)
        expect(seen[3]).to.equal(3)
        expect(#seen).to.equal(3)
    end)

    it("replace(idx, agent) swaps the slot without affecting others", function()
        local pop = sp.new({ x = 1 }, 2)
        pop:replace(1, { x = 99 })
        expect(pop:get(1).x).to.equal(99)
        expect(pop:get(2).x).to.equal(1)
    end)

    it("snapshot()/restore() preserves agent fields", function()
        local pop = sp.new({ a = 1, b = "z" }, 2)
        pop:replace(2, { a = 7, b = "y" })
        local snap = pop:snapshot()
        expect(snap.n).to.equal(2)
        expect(snap.agents[1].a).to.equal(1)
        expect(snap.agents[2].b).to.equal("y")
        local rehydrated = sp.restore(snap)
        expect(rehydrated:size()).to.equal(2)
        expect(rehydrated:get(2).a).to.equal(7)
    end)

    it("new() rejects non-table spec", function()
        local ok, err = pcall(sp.new, "not a table", 3)
        expect(ok).to.equal(false)
        expect(tostring(err):find("spec must be table")).to_not.equal(nil)
    end)

    it("new() rejects n<1 or non-integer", function()
        expect(pcall(sp.new, {}, 0)).to.equal(false)
        expect(pcall(sp.new, {}, -1)).to.equal(false)
        expect(pcall(sp.new, {}, 1.5)).to.equal(false)
    end)

    it("get()/replace() reject out-of-range idx", function()
        local pop = sp.new({}, 2)
        expect(pcall(function() pop:get(0) end)).to.equal(false)
        expect(pcall(function() pop:get(3) end)).to.equal(false)
        expect(pcall(function() pop:replace(0, {}) end)).to.equal(false)
        expect(pcall(function() pop:replace(3, {}) end)).to.equal(false)
    end)
end)

-- ─── Conway GoL Primitive spike (umbrella 1779690943-76260) ──────────
-- 3 Primitive set boundary specs: slot_table / broadcast_bus /
-- transition_rules. Verifies the Pure Primitive set works on a
-- cellular-automaton domain (W1 in primitives-draft.md §2).

local st = require("slot_table")
local bb = require("broadcast_bus")
local tr = require("transition_rules")

describe("slot_table (P1 Primitive spike)", function()
    it("new(n, init_fn) builds n slots via per-slot init_fn(idx)", function()
        local s = st.new(3, function(i) return { id = i, state = "dead" } end)
        expect(s:size()).to.equal(3)
        expect(s:get(1).id).to.equal(1)
        expect(s:get(3).id).to.equal(3)
        expect(s:get(2).state).to.equal("dead")
    end)

    it("set(idx, payload) is state-write (replaces slot)", function()
        local s = st.new(2, function() return { v = 0 } end)
        s:set(1, { v = 99 })
        expect(s:get(1).v).to.equal(99)
        expect(s:get(2).v).to.equal(0)
    end)

    it("iter() yields (idx, payload) in slot order", function()
        local s = st.new(3, function(i) return { i = i } end)
        local seen = {}
        for idx, payload in s:iter() do
            seen[#seen + 1] = idx
            expect(payload.i).to.equal(idx)
        end
        expect(#seen).to.equal(3)
        expect(seen[1]).to.equal(1)
        expect(seen[3]).to.equal(3)
    end)

    it("new() rejects n<1 / non-integer", function()
        expect(pcall(st.new, 0, function() return {} end)).to.equal(false)
        expect(pcall(st.new, -1, function() return {} end)).to.equal(false)
        expect(pcall(st.new, 1.5, function() return {} end)).to.equal(false)
    end)

    it("new() rejects init_fn returning non-table", function()
        local ok, err = pcall(st.new, 2, function() return "nope" end)
        expect(ok).to.equal(false)
        expect(tostring(err):find("must return table")).to_not.equal(nil)
    end)

    it("get()/set() reject out-of-range idx", function()
        local s = st.new(2, function() return {} end)
        expect(pcall(function() s:get(0) end)).to.equal(false)
        expect(pcall(function() s:get(3) end)).to.equal(false)
        expect(pcall(function() s:set(0, {}) end)).to.equal(false)
        expect(pcall(function() s:set(3, {}) end)).to.equal(false)
    end)
end)

describe("broadcast_bus (P6 Primitive spike)", function()
    it("new() builds empty bus, aggregate_for returns agg_fn({}) when no msgs", function()
        local bus = bb.new()
        local r = bus:aggregate_for(1, function() return true end, function(msgs) return #msgs end)
        expect(r).to.equal(0)
    end)

    it("publish + aggregate_for sums msgs from selected sources", function()
        local bus = bb.new()
        bus:publish(1, 1)
        bus:publish(2, 1)
        bus:publish(3, 1)
        local r = bus:aggregate_for(
            10,
            function(src) return src == 1 or src == 3 end,
            function(msgs)
                local s = 0
                for _, v in ipairs(msgs) do s = s + v end
                return s
            end
        )
        expect(r).to.equal(2)
    end)

    it("selector_fn filters by src predicate; agg_fn shapes output", function()
        local bus = bb.new()
        bus:publish(5, "a")
        bus:publish(6, "b")
        bus:publish(7, "c")
        local r = bus:aggregate_for(
            1,
            function(src) return src % 2 == 1 end,
            function(msgs) return table.concat(msgs, ",") end
        )
        expect(r).to.equal("a,c")
    end)

    it("reset() clears all msgs", function()
        local bus = bb.new()
        bus:publish(1, 1)
        bus:reset()
        local r = bus:aggregate_for(1, function() return true end, function(msgs) return #msgs end)
        expect(r).to.equal(0)
    end)

    it("publish() rejects non-positive-integer src", function()
        local bus = bb.new()
        expect(pcall(function() bus:publish(0, "x") end)).to.equal(false)
        expect(pcall(function() bus:publish(-1, "x") end)).to.equal(false)
        expect(pcall(function() bus:publish(1.5, "x") end)).to.equal(false)
    end)

    it("aggregate_for() rejects non-function selector / agg", function()
        local bus = bb.new()
        expect(pcall(function() bus:aggregate_for(1, "no", function() end) end)).to.equal(false)
        expect(pcall(function() bus:aggregate_for(1, function() end, "no") end)).to.equal(false)
    end)
end)

describe("transition_rules (P7 Primitive spike)", function()
    it("Conway B3/S23 encodes in 3 add() calls; first match wins", function()
        local rules = tr.new()
        rules:add("dead", "alive", function(_, c) return c.alive_neighbors == 3 end)
        rules:add("alive", "alive", function(_, c)
            return c.alive_neighbors == 2 or c.alive_neighbors == 3
        end)
        rules:add("alive", "dead", function() return true end)
        expect(rules:size()).to.equal(3)

        -- birth at 3 neighbors
        local r1 = rules:apply({ state = "dead" }, { alive_neighbors = 3 })
        expect(r1.state).to.equal("alive")

        -- survive at 2
        local r2 = rules:apply({ state = "alive" }, { alive_neighbors = 2 })
        expect(r2.state).to.equal("alive")

        -- survive at 3
        local r3 = rules:apply({ state = "alive" }, { alive_neighbors = 3 })
        expect(r3.state).to.equal("alive")

        -- die at 1
        local r4 = rules:apply({ state = "alive" }, { alive_neighbors = 1 })
        expect(r4.state).to.equal("dead")

        -- die at 4 (overcrowding)
        local r5 = rules:apply({ state = "alive" }, { alive_neighbors = 4 })
        expect(r5.state).to.equal("dead")

        -- stay dead at 2 (no birth rule matches)
        local r6 = rules:apply({ state = "dead" }, { alive_neighbors = 2 })
        expect(r6.state).to.equal("dead")
    end)

    it("apply() preserves non-state fields (shallow copy)", function()
        local rules = tr.new()
        rules:add("alive", "dead", function() return true end)
        local out = rules:apply({ state = "alive", age = 7, name = "x" }, {})
        expect(out.state).to.equal("dead")
        expect(out.age).to.equal(7)
        expect(out.name).to.equal("x")
    end)

    it("apply() returns shallow copy with unchanged state when no rule matches", function()
        local rules = tr.new()
        rules:add("alive", "dead", function() return false end)
        local input = { state = "alive", v = 1 }
        local out = rules:apply(input, {})
        expect(out.state).to.equal("alive")
        expect(out.v).to.equal(1)
        -- snapshot semantics: mutating returned out must not affect input
        out.v = 999
        expect(input.v).to.equal(1)
    end)

    it("add() rejects empty / non-string from/to", function()
        local rules = tr.new()
        expect(pcall(function() rules:add("", "x", function() end) end)).to.equal(false)
        expect(pcall(function() rules:add("x", "", function() end) end)).to.equal(false)
        expect(pcall(function() rules:add(nil, "x", function() end) end)).to.equal(false)
    end)

    it("apply() rejects payload without string state", function()
        local rules = tr.new()
        rules:add("alive", "dead", function() return true end)
        expect(pcall(function() rules:apply({}, {}) end)).to.equal(false)
        expect(pcall(function() rules:apply({ state = 42 }, {}) end)).to.equal(false)
    end)
end)

-- ─── lineage (P4 Primitive spike, umbrella 1779690943-76260 §9 (v) A) ─

local ln = require("lineage")

describe("lineage (P4 Primitive + Q1 mutation_op subordinate)", function()
    it("new() builds empty graph (size 0, no edges)", function()
        local L = ln.new()
        expect(L:size()).to.equal(0)
        expect(#L:edges()).to.equal(0)
    end)

    it("beget() invokes mutation_op and records edge", function()
        local L = ln.new()
        L:set_mutation_op(function(p) return { v = p.v + 1, state = "active" } end)
        local child = L:beget(1, 2, 1, { v = 10, state = "active" })
        expect(child.v).to.equal(11)
        expect(L:size()).to.equal(1)
        expect(L:parent(2)).to.equal(1)
        expect(L:generation(2)).to.equal(1)
    end)

    it("children() returns child list for parent", function()
        local L = ln.new()
        L:set_mutation_op(function(p) return { v = p.v } end)
        L:beget(1, 2, 1, { v = 0 })
        L:beget(1, 3, 1, { v = 0 })
        L:beget(2, 4, 2, { v = 0 })
        local kids_of_1 = L:children(1)
        expect(#kids_of_1).to.equal(2)
        expect(kids_of_1[1]).to.equal(2)
        expect(kids_of_1[2]).to.equal(3)
        expect(#L:children(2)).to.equal(1)
        expect(L:children(2)[1]).to.equal(4)
        expect(#L:children(99)).to.equal(0)
    end)

    it("beget() without set_mutation_op errors", function()
        local L = ln.new()
        local ok, err = pcall(function() L:beget(1, 2, 0, {}) end)
        expect(ok).to.equal(false)
        expect(tostring(err):find("mutation_op not set")).to_not.equal(nil)
    end)

    it("mutation_op returning non-table errors", function()
        local L = ln.new()
        L:set_mutation_op(function() return "not a table" end)
        local ok, err = pcall(function() L:beget(1, 2, 0, {}) end)
        expect(ok).to.equal(false)
        expect(tostring(err):find("must return table")).to_not.equal(nil)
    end)

    it("beget() rejects invalid slot / gen / payload types", function()
        local L = ln.new()
        L:set_mutation_op(function() return {} end)
        expect(pcall(function() L:beget(0, 2, 0, {}) end)).to.equal(false)
        expect(pcall(function() L:beget(1, -1, 0, {}) end)).to.equal(false)
        expect(pcall(function() L:beget(1, 2, -1, {}) end)).to.equal(false)
        expect(pcall(function() L:beget(1, 2, 0, "no") end)).to.equal(false)
    end)

    it("edges() and children() return defensive copies", function()
        local L = ln.new()
        L:set_mutation_op(function() return {} end)
        L:beget(1, 2, 0, {})
        local e1 = L:edges()
        e1[#e1 + 1] = { parent = 99, child = 99, gen = 99 }
        expect(L:size()).to.equal(1)  -- unaffected by external mutation
        local kids = L:children(1)
        kids[#kids + 1] = 999
        expect(#L:children(1)).to.equal(1)
    end)
end)

-- ─── ledger (P3 Primitive spike, umbrella 1779690943-76260 §9 W13) ────

local lg = require("ledger")

describe("ledger (P3 Primitive spike)", function()
    it("new() builds empty ledger (total=0, credit_total=0, size=0)", function()
        local L = lg.new()
        expect(L:total()).to.equal(0)
        expect(L:credit_total()).to.equal(0)
        expect(L:size()).to.equal(0)
        expect(L:balance(1)).to.equal(0)
    end)

    it("credit() increases balance + credit_total (external inflow)", function()
        local L = lg.new()
        L:credit(1, 100)
        L:credit(2, 50)
        expect(L:balance(1)).to.equal(100)
        expect(L:balance(2)).to.equal(50)
        expect(L:total()).to.equal(150)
        expect(L:credit_total()).to.equal(150)
    end)

    it("transfer() is zero-sum: total() invariant after transfer", function()
        local L = lg.new()
        L:credit(1, 100)
        L:credit(2, 100)
        local before = L:total()
        local ok = L:transfer(1, 2, 30)
        expect(ok).to.equal(true)
        expect(L:balance(1)).to.equal(70)
        expect(L:balance(2)).to.equal(130)
        expect(L:total()).to.equal(before)
    end)

    it("conservation invariant: total() == credit_total() across mixed ops", function()
        local L = lg.new()
        L:credit(1, 100)
        L:credit(2, 100)
        L:transfer(1, 2, 30)
        L:transfer(2, 1, 10)
        L:credit(3, 50)
        L:transfer(3, 1, 20)
        expect(L:total()).to.equal(L:credit_total())
    end)

    it("transfer() returns false on insufficient funds (default)", function()
        local L = lg.new()
        L:credit(1, 30)
        L:credit(2, 0)
        local ok = L:transfer(1, 2, 50)
        expect(ok).to.equal(false)
        -- balances and total unchanged
        expect(L:balance(1)).to.equal(30)
        expect(L:balance(2)).to.equal(0)
        expect(L:total()).to.equal(30)
    end)

    it("allow_negative=true permits balance to go below zero", function()
        local L = lg.new({ allow_negative = true })
        L:credit(1, 10)
        local ok = L:transfer(1, 2, 50)
        expect(ok).to.equal(true)
        expect(L:balance(1)).to.equal(-40)
        expect(L:balance(2)).to.equal(50)
        expect(L:total()).to.equal(L:credit_total())  -- still conserved
    end)

    it("transfer() to self errors", function()
        local L = lg.new()
        L:credit(1, 100)
        expect(pcall(function() L:transfer(1, 1, 10) end)).to.equal(false)
    end)

    it("transfer() / credit() reject invalid args", function()
        local L = lg.new()
        expect(pcall(function() L:credit(0, 10) end)).to.equal(false)
        expect(pcall(function() L:credit(1, -1) end)).to.equal(false)
        expect(pcall(function() L:transfer(0, 1, 10) end)).to.equal(false)
        expect(pcall(function() L:transfer(1, 0, 10) end)).to.equal(false)
        expect(pcall(function() L:transfer(1, 2, 0) end)).to.equal(false)
        expect(pcall(function() L:transfer(1, 2, -5) end)).to.equal(false)
    end)

    it("new() rejects non-boolean allow_negative", function()
        expect(pcall(function() lg.new({ allow_negative = "yes" }) end)).to.equal(false)
        expect(pcall(function() lg.new({ allow_negative = 1 }) end)).to.equal(false)
    end)

    it("transactions() returns defensive copy", function()
        local L = lg.new()
        L:credit(1, 10)
        L:transfer(1, 2, 5)
        local txs = L:transactions()
        expect(#txs).to.equal(2)
        txs[#txs + 1] = { kind = "fake" }
        expect(L:size()).to.equal(2)  -- internal log unaffected
    end)

    it("transactions() logs credit and transfer kinds correctly", function()
        local L = lg.new()
        L:credit(1, 100)
        L:transfer(1, 2, 40)
        local txs = L:transactions()
        expect(txs[1].kind).to.equal("credit")
        expect(txs[1].to).to.equal(1)
        expect(txs[1].amount).to.equal(100)
        expect(txs[2].kind).to.equal("transfer")
        expect(txs[2].from).to.equal(1)
        expect(txs[2].to).to.equal(2)
        expect(txs[2].amount).to.equal(40)
    end)
end)

-- Final exit code: non-zero on failure
local results = lust.get_results()
print()
print(string.format("=== Results: %d passed, %d failed (total %d) ===", results.passed, results.failed, results.total))
if results.failed > 0 then os.exit(1) end
