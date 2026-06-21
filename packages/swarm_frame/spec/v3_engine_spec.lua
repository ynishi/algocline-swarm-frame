-- v3_engine_spec.lua — /engine sub-modules (P3 minimal coverage).
--
-- Covers: plugin_chain (before/around/after/finalize), observer fan-out,
-- safeguard (max_dispatch_total / max_recursion_depth), store
-- (offload / restore). state semantics built-in is deferred to P5.

local lust  = require("lust")
local swarm = require("swarm_frame.v3")
local E     = swarm.engine
local describe, it, expect = lust.describe, lust.it, lust.expect

-- ── plugin_chain ────────────────────────────────────────────────────

describe("swarm.v3.engine.plugin_chain", function()
    it("wrap_dispatch with no plugins is identity", function()
        local function d(ref) return { took = ref } end
        local w = E.plugin_chain.wrap_dispatch({}, d)
        expect(w("@a").took).to.equal("@a")
    end)

    it("before runs outer-to-inner", function()
        local trace = {}
        local plugins = {
            { name = "outer", before = function(ref) trace[#trace+1] = "outer:" .. ref end },
            { name = "inner", before = function(ref) trace[#trace+1] = "inner:" .. ref end },
        }
        local w = E.plugin_chain.wrap_dispatch(plugins,
            function(ref) trace[#trace+1] = "real:" .. ref; return ref end)
        w("@x")
        expect(table.concat(trace, ",")).to.equal("outer:@x,inner:@x,real:@x")
    end)

    it("around wraps and may short-circuit", function()
        local plugins = {
            { name = "guard",
              around = function(next_fn, ref, input, ctx)
                  if ref == "@blocked" then return { blocked = true } end
                  return next_fn(ref, input, ctx)
              end },
        }
        local w = E.plugin_chain.wrap_dispatch(plugins,
            function(ref) return { ok = ref } end)
        expect(w("@blocked").blocked).to.equal(true)
        expect(w("@allowed").ok).to.equal("@allowed")
    end)

    it("after runs inner-to-outer", function()
        local trace = {}
        local plugins = {
            { name = "outer", after = function(ref) trace[#trace+1] = "outer" end },
            { name = "inner", after = function(ref) trace[#trace+1] = "inner" end },
        }
        local w = E.plugin_chain.wrap_dispatch(plugins, function() return nil end)
        w("@x")
        expect(table.concat(trace, ",")).to.equal("inner,outer")
    end)

    it("finalize transforms result if it returns non-nil", function()
        local plugins = {
            { name = "outer", finalize = function(r) r.tag_outer = true; return r end },
            { name = "inner", finalize = function(r) r.tag_inner = true end }, -- no return
        }
        local r = E.plugin_chain.run_finalize(plugins, { status = "ok" })
        expect(r.tag_inner).to.equal(true)
        expect(r.tag_outer).to.equal(true)
    end)

    it("wrap_dispatch raises on non-function dispatch", function()
        expect(pcall(function() E.plugin_chain.wrap_dispatch({}, nil) end)).to.equal(false)
    end)
end)

-- ── observer ────────────────────────────────────────────────────────

describe("swarm.v3.engine.observer", function()
    it("new() fans events to N observers in order", function()
        local got = {}
        local emit = E.observer.new({
            function(ev) got[#got+1] = "a:" .. ev.phase end,
            function(ev) got[#got+1] = "b:" .. ev.phase end,
        })
        emit({ phase = "start" })
        emit({ phase = "end" })
        expect(table.concat(got, ",")).to.equal("a:start,b:start,a:end,b:end")
    end)
    it("raises if a non-fn observer is passed", function()
        expect(pcall(function() E.observer.new({ "not-a-fn" }) end)).to.equal(false)
    end)
    it("noop emitter is safe to call", function()
        E.observer.noop({ phase = "start" })
        expect(true).to.equal(true)  -- reached
    end)
end)

-- ── safeguard ───────────────────────────────────────────────────────

describe("swarm.v3.engine.safeguard", function()
    it("counts dispatches under max", function()
        local sg = E.safeguard.new({ max_dispatch_total = 5 })
        for i = 1, 5 do E.safeguard.check_dispatch(sg) end
        expect(sg.dispatch_count).to.equal(5)
    end)
    it("raises when max_dispatch_total exceeded", function()
        local sg = E.safeguard.new({ max_dispatch_total = 2 })
        E.safeguard.check_dispatch(sg)
        E.safeguard.check_dispatch(sg)
        expect(pcall(function() E.safeguard.check_dispatch(sg) end)).to.equal(false)
    end)
    it("recursion depth bookend works", function()
        local sg = E.safeguard.new({ max_recursion_depth = 3 })
        E.safeguard.enter_recursion(sg)
        E.safeguard.enter_recursion(sg)
        E.safeguard.leave_recursion(sg)
        expect(sg.recursion_depth).to.equal(1)
    end)
    it("raises when max_recursion_depth exceeded", function()
        local sg = E.safeguard.new({ max_recursion_depth = 2 })
        E.safeguard.enter_recursion(sg)
        E.safeguard.enter_recursion(sg)
        expect(pcall(function() E.safeguard.enter_recursion(sg) end)).to.equal(false)
    end)
end)

-- ── store ───────────────────────────────────────────────────────────

describe("swarm.v3.engine.store", function()
    local function make_memory_backend()
        local mem = {}
        return {
            mem    = mem,
            write  = function(self, id, payload) self.mem[id] = payload; return true end,
            read   = function(self, id) return self.mem[id] end,
            exists = function(self, id) return self.mem[id] ~= nil end,
            delete = function(self, id) self.mem[id] = nil; return true end,
        }
    end
    it("offload returns Summary stub and writes to backend", function()
        local backend = make_memory_backend()
        local summary = E.store.offload("hello world", backend,
            { artifact_id = "a1", kind = "text", preview_chars = 5 })
        expect(summary.artifact_id).to.equal("a1")
        expect(summary.kind).to.equal("text")
        expect(summary.size).to.equal(11)
        expect(summary.preview).to.equal("hello")
        expect(backend.mem.a1).to.equal("hello world")
    end)
    it("restore reads payload via backend", function()
        local backend = make_memory_backend()
        E.store.offload("payload-x", backend, { artifact_id = "a2" })
        expect(E.store.restore({ artifact_id = "a2" }, backend)).to.equal("payload-x")
    end)
    it("offload raises on bad backend", function()
        expect(pcall(function() E.store.offload("x", {}, { artifact_id = "a" }) end))
            .to.equal(false)
    end)
end)

-- ── runtime wiring (e2e) ────────────────────────────────────────────

describe("swarm.v3 runtime with plugins / observers / safeguard", function()
    it("plugins observe each dispatch and transform result via finalize", function()
        local plugin_trace = {}
        local plugins = {
            { name = "tag",
              before = function(ref) plugin_trace[#plugin_trace+1] = "b:" .. ref end,
              after  = function(ref) plugin_trace[#plugin_trace+1] = "a:" .. ref end,
              finalize = function(r) r.touched = true; return r end },
        }
        local shape = swarm.chain({
            swarm.step("@s", { out = "ctx.r" }),
        })
        local result = swarm.run({
            shape    = shape,
            dispatch = function(ref) return { ref = ref } end,
            plugins  = plugins,
        })
        expect(result.status).to.equal("ok")
        expect(result.touched).to.equal(true)
        expect(table.concat(plugin_trace, ",")).to.equal("b:@s,a:@s")
    end)

    it("observers receive start / end events per dispatch", function()
        local events = {}
        local shape = swarm.chain({
            swarm.step("@a", { out = "ctx.a" }),
            swarm.step("@b", { out = "ctx.b" }),
        })
        local result = swarm.run({
            shape     = shape,
            dispatch  = function() return nil end,
            observers = { function(ev) events[#events+1] = ev.phase .. ":" .. ev.ref end },
        })
        expect(result.status).to.equal("ok")
        expect(table.concat(events, ",")).to.equal("start:@a,end:@a,start:@b,end:@b")
    end)

    it("safeguard.max_dispatch_total triggers safeguard_breach", function()
        local shape = swarm.chain({
            swarm.step("@a", { out = "ctx.a" }),
            swarm.step("@b", { out = "ctx.b" }),
        })
        local result = swarm.run({
            shape     = shape,
            dispatch  = function() return nil end,
            safeguard = { max_dispatch_total = 1 },
        })
        expect(result.status).to.equal("error")
        expect(result.error.kind).to.equal("safeguard_breach")
    end)
end)
