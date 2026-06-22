-- dispatcher_spec.lua — Boundary regression spec for
-- swarm_host_alc.dispatcher.make_dispatcher (P5 step 6.1 sub (c)).
--
-- Covers opts validation (required + optional), plugin structured
-- shape validation, writes registry aggregation + collision warn,
-- and callable-table skeleton (#8b iface probe + placeholder errors
-- for finalize / __call until Step 6.4-6.5 lands them).

local lust = require("lust")
local describe, it, expect = lust.describe, lust.it, lust.expect

local dispatcher = require("swarm_host_alc.dispatcher")
local iface = require("swarm_frame.v3.contract.dispatcher_iface")

local function contains(s, sub)
    return type(s) == "string" and string.find(s, sub, 1, true) ~= nil
end

-- minimal valid opts factory (overrides merged on top).
local function minimal_opts(overrides)
    local o = {
        builder = function(_step, _spec) return "PROMPT" end,
        flow_state = {},
        pkg_name = "swarm_test",
    }
    if overrides then
        for k, v in pairs(overrides) do o[k] = v end
    end
    return o
end

-- ─── required opts ────────────────────────────────────────────────────

describe("swarm_host_alc.dispatcher.make_dispatcher — required opts", function()
    it("errors when opts is not a table", function()
        local ok, err = pcall(dispatcher.make_dispatcher, "bad")
        expect(ok).to.equal(false)
        expect(contains(err, "opts must be a table")).to.equal(true)
    end)

    it("errors when opts.builder is missing / non-function", function()
        local ok1, err1 = pcall(dispatcher.make_dispatcher,
            { flow_state = {}, pkg_name = "p" })
        expect(ok1).to.equal(false)
        expect(contains(err1, "opts.builder must be a function")).to.equal(true)

        local ok2, err2 = pcall(dispatcher.make_dispatcher,
            minimal_opts({ builder = "x" }))
        expect(ok2).to.equal(false)
        expect(contains(err2, "opts.builder")).to.equal(true)
    end)

    it("errors when opts.flow_state is missing / non-table", function()
        local ok1, err1 = pcall(dispatcher.make_dispatcher,
            { builder = function() end, pkg_name = "p" })
        expect(ok1).to.equal(false)
        expect(contains(err1, "opts.flow_state must be a table")).to.equal(true)

        local ok2, err2 = pcall(dispatcher.make_dispatcher,
            minimal_opts({ flow_state = "x" }))
        expect(ok2).to.equal(false)
        expect(contains(err2, "opts.flow_state")).to.equal(true)
    end)

    it("errors when opts.pkg_name is missing / empty / non-string", function()
        local ok1, err1 = pcall(dispatcher.make_dispatcher,
            { builder = function() end, flow_state = {} })
        expect(ok1).to.equal(false)
        expect(contains(err1, "opts.pkg_name must be a non-empty string"))
            .to.equal(true)

        local ok2, err2 = pcall(dispatcher.make_dispatcher,
            minimal_opts({ pkg_name = "" }))
        expect(ok2).to.equal(false)
        expect(contains(err2, "pkg_name")).to.equal(true)

        local ok3, err3 = pcall(dispatcher.make_dispatcher,
            minimal_opts({ pkg_name = 42 }))
        expect(ok3).to.equal(false)
        expect(contains(err3, "pkg_name")).to.equal(true)
    end)
end)

-- ─── optional opts ────────────────────────────────────────────────────

describe("swarm_host_alc.dispatcher.make_dispatcher — optional opts", function()
    it("errors when opts.deps is non-table", function()
        local ok, err = pcall(dispatcher.make_dispatcher,
            minimal_opts({ deps = "x" }))
        expect(ok).to.equal(false)
        expect(contains(err, "opts.deps")).to.equal(true)
    end)

    it("errors when opts.llm_opts_base is non-table", function()
        local ok, err = pcall(dispatcher.make_dispatcher,
            minimal_opts({ llm_opts_base = "x" }))
        expect(ok).to.equal(false)
        expect(contains(err, "opts.llm_opts_base")).to.equal(true)
    end)

    it("errors when opts.extras is non-table", function()
        local ok, err = pcall(dispatcher.make_dispatcher,
            minimal_opts({ extras = "x" }))
        expect(ok).to.equal(false)
        expect(contains(err, "opts.extras")).to.equal(true)
    end)

    it("errors when opts.plugins is non-table", function()
        local ok, err = pcall(dispatcher.make_dispatcher,
            minimal_opts({ plugins = "x" }))
        expect(ok).to.equal(false)
        expect(contains(err, "opts.plugins")).to.equal(true)
    end)

    it("invalid opts.safeguard surfaces error from safeguard.merge",
        function()
        local ok, err = pcall(dispatcher.make_dispatcher,
            minimal_opts({ safeguard = { max_dispatch_per_step = 0 } }))
        expect(ok).to.equal(false)
        expect(contains(err, "max_dispatch_per_step")).to.equal(true)
    end)
end)

-- ─── plugin structured shape ──────────────────────────────────────────

describe("swarm_host_alc.dispatcher.make_dispatcher — plugin shape", function()
    it("errors when plugins[i] is non-table", function()
        local ok, err = pcall(dispatcher.make_dispatcher,
            minimal_opts({ plugins = { "bad" } }))
        expect(ok).to.equal(false)
        expect(contains(err, "plugins[1] must be a table")).to.equal(true)
    end)

    it("errors when plugins[i].name is missing / empty", function()
        local ok1, err1 = pcall(dispatcher.make_dispatcher,
            minimal_opts({ plugins = { {} } }))
        expect(ok1).to.equal(false)
        expect(contains(err1, "plugins[1].name")).to.equal(true)

        local ok2, err2 = pcall(dispatcher.make_dispatcher,
            minimal_opts({ plugins = { { name = "" } } }))
        expect(ok2).to.equal(false)
        expect(contains(err2, "plugins[1].name")).to.equal(true)
    end)

    it("errors when plugins[i].hooks is non-table / hook is non-function",
        function()
        local ok1, err1 = pcall(dispatcher.make_dispatcher,
            minimal_opts({ plugins = { { name = "p", hooks = "x" } } }))
        expect(ok1).to.equal(false)
        expect(contains(err1, "plugins[1].hooks must be a table")).to.equal(true)

        local ok2, err2 = pcall(dispatcher.make_dispatcher,
            minimal_opts({ plugins = {
                { name = "p", hooks = { before_dispatch = "x" } }
            } }))
        expect(ok2).to.equal(false)
        expect(contains(err2, "plugins[1].hooks.before_dispatch")).to.equal(true)

        local ok3, err3 = pcall(dispatcher.make_dispatcher,
            minimal_opts({ plugins = {
                { name = "p", hooks = { finalize = 42 } }
            } }))
        expect(ok3).to.equal(false)
        expect(contains(err3, "plugins[1].hooks.finalize")).to.equal(true)
    end)

    it("errors when plugins[i].writes shape is invalid", function()
        local ok1, err1 = pcall(dispatcher.make_dispatcher,
            minimal_opts({ plugins = { { name = "p", writes = "x" } } }))
        expect(ok1).to.equal(false)
        expect(contains(err1, "plugins[1].writes")).to.equal(true)

        local ok2, err2 = pcall(dispatcher.make_dispatcher,
            minimal_opts({ plugins = {
                { name = "p", writes = { spec = "x" } }
            } }))
        expect(ok2).to.equal(false)
        expect(contains(err2, "plugins[1].writes.spec")).to.equal(true)

        local ok3, err3 = pcall(dispatcher.make_dispatcher,
            minimal_opts({ plugins = {
                { name = "p", writes = { state = { "no_underscore" } } }
            } }))
        expect(ok3).to.equal(false)
        expect(contains(err3, "must start with '_'")).to.equal(true)
    end)
end)

-- ─── writes aggregation ───────────────────────────────────────────────

describe("swarm_host_alc.dispatcher.make_dispatcher — writes registry", function()
    it("aggregates a single plugin's spec/state/step writes into "
        .. "dispatcher.writes", function()
        local d = dispatcher.make_dispatcher(minimal_opts({
            plugins = {
                {
                    name = "p1",
                    writes = {
                        spec = { "admission", "verdict" },
                        state = { "_iter_count" },
                        step = { "validator" },
                    },
                },
            },
        }))
        expect(#d.writes.spec.admission).to.equal(1)
        expect(d.writes.spec.admission[1]).to.equal("p1")
        expect(d.writes.spec.verdict[1]).to.equal("p1")
        expect(d.writes.state._iter_count[1]).to.equal("p1")
        expect(d.writes.step.validator[1]).to.equal("p1")
    end)

    it("emits one warn per (axis, field) collision when two plugins "
        .. "declare the same field", function()
        local logs = {}
        local fake_alc = {
            log = function(level, msg)
                table.insert(logs, { level = level, msg = msg })
            end
        }
        dispatcher.make_dispatcher(minimal_opts({
            deps = { alc = fake_alc },
            plugins = {
                { name = "p1", writes = {
                    spec = { "admission" },
                    state = { "_x" },
                    step = { "s1" },
                }},
                { name = "p2", writes = {
                    spec = { "admission" },
                    state = { "_x" },
                    step = { "s1" },
                }},
            },
        }))
        -- 3 axes × 1 collision each = 3 warns expected.
        expect(#logs).to.equal(3)
        local seen = {}
        for _, e in ipairs(logs) do
            expect(e.level).to.equal("warn")
            if contains(e.msg, "writes.spec") then seen.spec = true end
            if contains(e.msg, "writes.state") then seen.state = true end
            if contains(e.msg, "writes.step") then seen.step = true end
        end
        expect(seen.spec).to.equal(true)
        expect(seen.state).to.equal(true)
        expect(seen.step).to.equal(true)
    end)
end)

-- ─── callable table skeleton ──────────────────────────────────────────

describe("swarm_host_alc.dispatcher.make_dispatcher — callable skeleton",
    function()
    it("returns a callable table that passes dispatcher_iface.check_call "
        .. "(#8b)", function()
        local d = dispatcher.make_dispatcher(minimal_opts())
        local ok, err = iface.check_call(d)
        expect(ok).to.equal(true)
        expect(err).to.equal(nil)
    end)

    it("exposes extras / plugins / writes / finalize fields with defaults",
        function()
        local d = dispatcher.make_dispatcher(minimal_opts())
        expect(type(d.extras)).to.equal("table")
        expect(type(d.plugins)).to.equal("table")
        expect(type(d.writes)).to.equal("table")
        expect(type(d.writes.spec)).to.equal("table")
        expect(type(d.writes.state)).to.equal("table")
        expect(type(d.writes.step)).to.equal("table")
        expect(type(d.finalize)).to.equal("function")
    end)

    it("__call is callable (Step 6.5 replaced placeholder), errors "
        .. "via lazy deps validation when deps.frame is absent", function()
        -- Step 6.1: __call placeholder NotYetImplemented error.
        -- Step 6.5: real lifecycle impl + lazy build. minimal_opts has
        -- no deps, so first __call triggers get_call_fn → _build_core_dispatch
        -- which requires frame_pkg.check_mode (= first lazy validation
        -- hit at the core_dispatch factory).
        local d = dispatcher.make_dispatcher(minimal_opts())
        local ok, err = pcall(d, "step_0", {})
        expect(ok).to.equal(false)
        expect(contains(err, "frame_pkg.check_mode")).to.equal(true)
    end)

    it("finalize is callable but errors via lazy alc.card validation "
        .. "when deps.alc not injected (Step 6.4 replaced placeholder)",
        function()
        -- Step 6.1: placeholder NotYetImplemented error.
        -- Step 6.4: real finalize impl + lazy alc.card validation.
        -- minimal_opts() doesn't inject deps.alc, so finalize() now
        -- errors with the lazy-validation message instead.
        local d = dispatcher.make_dispatcher(minimal_opts())
        local ok, err = pcall(d.finalize)
        expect(ok).to.equal(false)
        expect(contains(err, "alc.card.create")).to.equal(true)
    end)
end)
