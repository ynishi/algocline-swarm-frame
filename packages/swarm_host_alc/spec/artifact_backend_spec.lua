-- artifact_backend_spec.lua — Boundary regression spec for
-- swarm_host_alc.artifact_backend (P5 step 2).
--
-- Per workspace-pipeline.md §Frame/orch 改修後 checklist:
--   (1) module-local helper exposure (M.file_backend / M.memory_backend)
--   (2) backend shape probe (artifact_backend_iface.check_iface)
--   (3) accept / reject path coverage
--   (4) error message substring assertion
--   (5) runtime integration: engine.store.offload + restore round-trip

local lust = require("lust")
local describe, it, expect = lust.describe, lust.it, lust.expect

local ab    = require("swarm_host_alc.artifact_backend")
local iface = require("swarm_frame.v3.contract.artifact_backend_iface")
local store = require("swarm_frame.v3.engine.store")

-- ─── tmp dir helper ──────────────────────────────────────────────────

local _tmp_seq = 0
local function make_tmp_dir()
    _tmp_seq = _tmp_seq + 1
    local base = (os.getenv("TMPDIR") or "/tmp") .. "/swarm_host_alc_artifact"
    local path = string.format("%s/%d-%d-%d", base, os.time(), _tmp_seq,
        math.random(0, 1e9))
    os.execute("mkdir -p '" .. path:gsub("'", "'\\''") .. "'")
    return path
end

-- ─── factory / shape contract ────────────────────────────────────────

describe("swarm_host_alc.artifact_backend factory", function()
    it("memory_backend satisfies artifact_backend_iface 4-method probe",
        function()
            local b = ab.memory_backend()
            local ok, reason = iface.check_iface(b)
            expect(ok).to.equal(true)
            expect(reason).to.equal(nil)
        end)

    it("file_backend satisfies artifact_backend_iface 4-method probe",
        function()
            local b = ab.file_backend({ task_dir = make_tmp_dir() })
            local ok, reason = iface.check_iface(b)
            expect(ok).to.equal(true)
            expect(reason).to.equal(nil)
        end)

    it("file_backend rejects calls without task_dir", function()
        local ok, err = pcall(function() ab.file_backend({}) end)
        expect(ok).to.equal(false)
        expect(tostring(err):find("opts.task_dir", 1, true) ~= nil)
            .to.equal(true)
    end)

    it("file_backend rejects empty task_dir", function()
        local ok, err = pcall(function()
            ab.file_backend({ task_dir = "" })
        end)
        expect(ok).to.equal(false)
        expect(tostring(err):find("non-empty", 1, true) ~= nil)
            .to.equal(true)
    end)
end)

-- ─── memory_backend semantics ─────────────────────────────────────────

describe("swarm_host_alc.artifact_backend.memory_backend", function()
    it("write then read returns the original payload verbatim", function()
        local b = ab.memory_backend()
        local ok = b:write("a-1", { hello = "world" })
        expect(ok).to.equal(true)
        local got = b:read("a-1")
        expect(type(got)).to.equal("table")
        expect(got.hello).to.equal("world")
    end)

    it("exists reflects write / delete state", function()
        local b = ab.memory_backend()
        expect(b:exists("a-1")).to.equal(false)
        b:write("a-1", "payload")
        expect(b:exists("a-1")).to.equal(true)
        b:delete("a-1")
        expect(b:exists("a-1")).to.equal(false)
    end)

    it("delete on missing artifact_id is idempotent", function()
        local b = ab.memory_backend()
        expect(b:delete("never-written")).to.equal(true)
    end)

    it("rejects non-string artifact_id on write", function()
        local b = ab.memory_backend()
        local ok, err = b:write(nil, "x")
        expect(ok).to.equal(false)
        expect(tostring(err):find("artifact_id", 1, true) ~= nil)
            .to.equal(true)
    end)
end)

-- ─── file_backend semantics ───────────────────────────────────────────

describe("swarm_host_alc.artifact_backend.file_backend", function()
    it("write then read round-trips a string payload", function()
        local b = ab.file_backend({ task_dir = make_tmp_dir() })
        local payload = "hello world"
        local ok = b:write("a-text", payload)
        expect(ok).to.equal(true)
        expect(b:read("a-text")).to.equal(payload)
    end)

    it("write encodes table payload when opts.kind == 'json'", function()
        local b = ab.file_backend({ task_dir = make_tmp_dir() })
        local ok = b:write("a-json", { k = "v" }, { kind = "json" })
        expect(ok).to.equal(true)
        local bytes = b:read("a-json")
        expect(type(bytes)).to.equal("string")
        -- dkjson encodes { k = "v" } to {"k":"v"} (or similar)
        expect(bytes:find("\"k\"", 1, true) ~= nil).to.equal(true)
    end)

    it("exists is false before write, true after", function()
        local b = ab.file_backend({ task_dir = make_tmp_dir() })
        expect(b:exists("a-1")).to.equal(false)
        b:write("a-1", "payload")
        expect(b:exists("a-1")).to.equal(true)
    end)

    it("delete on missing artifact_id is idempotent", function()
        local b = ab.file_backend({ task_dir = make_tmp_dir() })
        expect(b:delete("never-written")).to.equal(true)
        expect(b:exists("never-written")).to.equal(false)
    end)

    it("read on missing artifact_id returns nil", function()
        local b = ab.file_backend({ task_dir = make_tmp_dir() })
        expect(b:read("missing")).to.equal(nil)
    end)

    it("isolates artifacts between artifact_ids", function()
        local b = ab.file_backend({ task_dir = make_tmp_dir() })
        b:write("a-1", "alpha")
        b:write("a-2", "beta")
        expect(b:read("a-1")).to.equal("alpha")
        expect(b:read("a-2")).to.equal("beta")
    end)

    it("write replaces the prior payload under the same artifact_id",
        function()
            local b = ab.file_backend({ task_dir = make_tmp_dir() })
            b:write("a-1", "v1")
            b:write("a-1", "v2")
            expect(b:read("a-1")).to.equal("v2")
        end)

    it("artifacts live under <task_dir>/artifacts/<artifact_id>", function()
        local dir = make_tmp_dir()
        local b = ab.file_backend({ task_dir = dir })
        b:write("a-1", "payload")
        local f = io.open(dir .. "/artifacts/a-1", "rb")
        expect(f).to.exist()
        if f then f:close() end
    end)
end)

-- ─── runtime integration: engine.store.offload / restore round-trip ───

describe("swarm_host_alc.artifact_backend integrated with engine.store",
    function()
        it("store.offload + store.restore round-trip a string via memory_backend",
            function()
                local b = ab.memory_backend()
                local summary = store.offload("hello", b, {
                    artifact_id = "a-1",
                    preview_chars = 5,
                })
                expect(summary.artifact_id).to.equal("a-1")
                expect(summary.size).to.equal(#"hello")
                expect(summary.preview).to.equal("hello")
                expect(store.restore(summary, b)).to.equal("hello")
            end)

        it("store.offload + store.restore round-trip a string via file_backend",
            function()
                local b = ab.file_backend({ task_dir = make_tmp_dir() })
                local summary = store.offload("file payload", b, {
                    artifact_id = "a-1",
                    kind        = "text",
                })
                expect(summary.artifact_id).to.equal("a-1")
                expect(store.restore(summary, b)).to.equal("file payload")
            end)

        it("file_backend round-trips a json-encoded table when caller decodes",
            function()
                local b = ab.file_backend({ task_dir = make_tmp_dir() })
                local summary = store.offload({ k = "v" }, b, {
                    artifact_id = "a-1",
                    kind        = "json",
                })
                local bytes = store.restore(summary, b)
                expect(type(bytes)).to.equal("string")
                -- caller-side decode
                local decoded = _G.alc.json_decode(bytes)
                expect(type(decoded)).to.equal("table")
                expect(decoded.k).to.equal("v")
            end)
    end)
