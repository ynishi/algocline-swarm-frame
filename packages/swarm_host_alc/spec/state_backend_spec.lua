-- state_backend_spec.lua — Boundary regression spec for
-- swarm_host_alc.state_backend (P5 step 1).
--
-- Per workspace-pipeline.md §Frame/orch 改修後 checklist:
--   (1) target helper module-local exposure: M.file_backend / M.memory_backend
--   (2) backend shape probe (4 methods via state_backend_iface.check_iface)
--   (3) accept / reject path coverage (write/read/exists/delete + boundary cases)
--   (4) error message substring assertion (json_encode failure / missing opts)
--   (5) runtime integration: drop into engine.state.resolve and verify
--       the resume path picks up the persisted snapshot.

local lust = require("lust")
local describe, it, expect = lust.describe, lust.it, lust.expect

local sb = require("swarm_host_alc.state_backend")
local iface = require("swarm_frame.v3.contract.state_backend_iface")
local state = require("swarm_frame.v3.engine.state")

-- ─── tmp dir helper ──────────────────────────────────────────────────

local _tmp_seq = 0
local function make_tmp_dir()
    _tmp_seq = _tmp_seq + 1
    local base = (os.getenv("TMPDIR") or "/tmp") .. "/swarm_host_alc_test"
    local path = string.format("%s/%d-%d-%d", base, os.time(), _tmp_seq,
        math.random(0, 1e9))
    os.execute("mkdir -p '" .. path:gsub("'", "'\\''") .. "'")
    return path
end

-- ─── factory / shape contract ────────────────────────────────────────

describe("swarm_host_alc.state_backend factory", function()
    it("memory_backend satisfies state_backend_iface 4-method probe", function()
        local b = sb.memory_backend()
        local ok, reason = iface.check_iface(b)
        expect(ok).to.equal(true)
        expect(reason).to.equal(nil)
    end)

    it("file_backend satisfies state_backend_iface 4-method probe", function()
        local b = sb.file_backend({ base_dir = make_tmp_dir() })
        local ok, reason = iface.check_iface(b)
        expect(ok).to.equal(true)
        expect(reason).to.equal(nil)
    end)

    it("file_backend rejects calls without task_dir or base_dir", function()
        local ok, err = pcall(function() sb.file_backend({}) end)
        expect(ok).to.equal(false)
        expect(tostring(err):find("task_dir or opts.base_dir is required",
            1, true) ~= nil).to.equal(true)
    end)

    it("file_backend rejects mutually exclusive opts", function()
        local ok, err = pcall(function()
            sb.file_backend({ task_dir = "/tmp/a", base_dir = "/tmp/b" })
        end)
        expect(ok).to.equal(false)
        expect(tostring(err):find("mutually exclusive", 1, true) ~= nil)
            .to.equal(true)
    end)
end)

-- ─── memory_backend semantics ─────────────────────────────────────────

describe("swarm_host_alc.state_backend.memory_backend", function()
    it("write then read returns the same snapshot table", function()
        local b = sb.memory_backend()
        local snap = { task_id = "t1", status = "in_progress", ctx = { n = 1 } }
        local ok, err = b.write("t1", snap)
        expect(ok).to.equal(true)
        expect(err).to.equal(nil)
        local got = b.read("t1")
        expect(got).to.equal(snap)
    end)

    it("exists reflects write / delete state", function()
        local b = sb.memory_backend()
        expect(b.exists("t1")).to.equal(false)
        b.write("t1", { task_id = "t1", status = "in_progress", ctx = {} })
        expect(b.exists("t1")).to.equal(true)
        b.delete("t1")
        expect(b.exists("t1")).to.equal(false)
    end)

    it("delete on missing task_id is a no-op (idempotent)", function()
        local b = sb.memory_backend()
        local ok = b.delete("never-written")
        expect(ok).to.equal(true)
    end)

    it("read on missing task_id returns nil", function()
        local b = sb.memory_backend()
        expect(b.read("missing")).to.equal(nil)
    end)

    it("rejects non-string task_id on write", function()
        local b = sb.memory_backend()
        local ok, err = b.write(nil, { status = "in_progress" })
        expect(ok).to.equal(nil)
        expect(tostring(err):find("task_id", 1, true) ~= nil).to.equal(true)
    end)

    it("rejects non-table snapshot on write", function()
        local b = sb.memory_backend()
        local ok, err = b.write("t1", "not-a-table")
        expect(ok).to.equal(nil)
        expect(tostring(err):find("snapshot", 1, true) ~= nil).to.equal(true)
    end)
end)

-- ─── file_backend semantics (base_dir, multi-task) ────────────────────

describe("swarm_host_alc.state_backend.file_backend (base_dir)", function()
    it("write then read round-trips a snapshot via JSON", function()
        local b = sb.file_backend({ base_dir = make_tmp_dir() })
        local snap = {
            task_id = "t1",
            status  = "in_progress",
            ctx     = { _progress = {}, items = { "a", "b" } },
        }
        local ok = b.write("t1", snap)
        expect(ok).to.equal(true)
        local got = b.read("t1")
        expect(type(got)).to.equal("table")
        expect(got.task_id).to.equal("t1")
        expect(got.status).to.equal("in_progress")
        expect(type(got.ctx)).to.equal("table")
    end)

    it("exists is false before write, true after", function()
        local b = sb.file_backend({ base_dir = make_tmp_dir() })
        expect(b.exists("t1")).to.equal(false)
        b.write("t1", { task_id = "t1", status = "in_progress", ctx = {} })
        expect(b.exists("t1")).to.equal(true)
    end)

    it("delete on missing task_id is idempotent", function()
        local b = sb.file_backend({ base_dir = make_tmp_dir() })
        local ok = b.delete("never-written")
        expect(ok).to.equal(true)
        expect(b.exists("never-written")).to.equal(false)
    end)

    it("read on missing task_id returns nil", function()
        local b = sb.file_backend({ base_dir = make_tmp_dir() })
        expect(b.read("missing")).to.equal(nil)
    end)

    it("write replaces the prior snapshot under the same task_id", function()
        local b = sb.file_backend({ base_dir = make_tmp_dir() })
        b.write("t1", { task_id = "t1", status = "in_progress", ctx = {} })
        b.write("t1", { task_id = "t1", status = "completed", ctx = {} })
        local got = b.read("t1")
        expect(got.status).to.equal("completed")
    end)

    it("isolates snapshots between task_ids", function()
        local b = sb.file_backend({ base_dir = make_tmp_dir() })
        b.write("ta", { task_id = "ta", status = "in_progress", ctx = {} })
        b.write("tb", { task_id = "tb", status = "completed", ctx = {} })
        expect(b.read("ta").status).to.equal("in_progress")
        expect(b.read("tb").status).to.equal("completed")
    end)
end)

-- ─── file_backend semantics (task_dir, single-task) ───────────────────

describe("swarm_host_alc.state_backend.file_backend (task_dir)", function()
    it("ignores task_id on path resolution", function()
        local dir = make_tmp_dir()
        local b = sb.file_backend({ task_dir = dir })
        b.write("anything", { task_id = "anything", status = "in_progress",
            ctx = {} })
        -- the state file is the single state.json under task_dir
        local f = io.open(dir .. "/state.json", "rb")
        expect(f).to.exist()
        if f then f:close() end
    end)
end)

-- ─── runtime integration: resolve picks up persisted snapshot ─────────

describe("swarm_host_alc.state_backend integrated with engine.state.resolve",
    function()
        it("file_backend resume path returns mode=cached_return after COMPLETED write",
            function()
                local b = sb.file_backend({ base_dir = make_tmp_dir() })
                b.write("t1", {
                    task_id = "t1",
                    status  = state.STATUS.COMPLETED,
                    ctx     = { _progress = {}, hello = "world" },
                    result  = { status = "ok" },
                })
                local r = state.resolve(b, { task_id = "t1" })
                expect(r.mode).to.equal("cached_return")
                expect(r.task_id).to.equal("t1")
                expect(r.ctx.hello).to.equal("world")
            end)

        it("file_backend resume path returns mode=resume after INTERRUPTED write",
            function()
                local b = sb.file_backend({ base_dir = make_tmp_dir() })
                b.write("t2", {
                    task_id = "t2",
                    status  = state.STATUS.INTERRUPTED,
                    ctx     = { _progress = { s1 = { status = "done" } } },
                })
                local r = state.resolve(b, { task_id = "t2" })
                expect(r.mode).to.equal("resume")
                expect(r.ctx._progress.s1.status).to.equal("done")
            end)

        it("file_backend force_fresh deletes the prior snapshot",
            function()
                local b = sb.file_backend({ base_dir = make_tmp_dir() })
                b.write("t3", {
                    task_id = "t3",
                    status  = state.STATUS.COMPLETED,
                    ctx     = {},
                })
                expect(b.exists("t3")).to.equal(true)
                local r = state.resolve(b, {
                    task_id     = "t3",
                    force_fresh = true,
                })
                expect(r.mode).to.equal("fresh")
                expect(b.exists("t3")).to.equal(false)
            end)
    end)
