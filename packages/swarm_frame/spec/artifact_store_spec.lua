-- Usage: mcp__algocline__alc_pkg_test pkg=swarm_frame
local lust = require("lust")
local sf = require("swarm_frame")
local describe, it, expect = lust.describe, lust.it, lust.expect

-- ─── tmpdir helper for FS backend tests ──────────────────────────────────────

local function make_tmpdir()
    local base = os.getenv("TMPDIR") or "/tmp"
    -- Strip trailing slash if present
    base = base:gsub("/$", "")
    local path = base .. "/swarm_frame_test_" .. tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999))
    os.execute("mkdir -p '" .. path .. "'")
    return path
end

local function rm_rf(path) os.execute("rm -rf '" .. path .. "'") end

-- ─── Backend contract tests (table-driven: memory + FS) ──────────────────────
--
-- Both backends must satisfy the same 4-method contract: write/read/exists/delete.
-- Crux §source-agnostic backend interface: backend impl contains no format logic.

local backends = {
    {
        name = "memory",
        make = function(_tmpdir) return sf.backend_artifact_memory() end,
        cleanup = function(_tmpdir) end,
    },
    {
        name = "file",
        make = function(tmpdir) return sf.backend_artifact_file({ task_dir = tmpdir }) end,
        cleanup = function(tmpdir) rm_rf(tmpdir) end,
    },
}

for _, b in ipairs(backends) do
    describe("backend contract: " .. b.name, function()
        local tmpdir, backend

        it("setup", function()
            tmpdir = make_tmpdir()
            backend = b.make(tmpdir)
            expect(type(backend)).to.equal("table")
        end)

        it("write then read returns same bytes", function()
            tmpdir = make_tmpdir()
            backend = b.make(tmpdir)
            backend:write("test/hello.txt", "hello bytes")
            local got = backend:read("test/hello.txt")
            expect(got).to.equal("hello bytes")
        end)

        it("exists returns false for missing key", function()
            tmpdir = make_tmpdir()
            backend = b.make(tmpdir)
            expect(backend:exists("not/there.txt")).to.equal(false)
        end)

        it("exists returns true after write", function()
            tmpdir = make_tmpdir()
            backend = b.make(tmpdir)
            backend:write("artifact.json", "{}")
            expect(backend:exists("artifact.json")).to.equal(true)
        end)

        it("delete removes the artifact", function()
            tmpdir = make_tmpdir()
            backend = b.make(tmpdir)
            backend:write("to_delete.txt", "bye")
            expect(backend:exists("to_delete.txt")).to.equal(true)
            backend:delete("to_delete.txt")
            expect(backend:exists("to_delete.txt")).to.equal(false)
        end)

        it("read returns nil for deleted artifact", function()
            tmpdir = make_tmpdir()
            backend = b.make(tmpdir)
            backend:write("will_delete.txt", "data")
            backend:delete("will_delete.txt")
            expect(backend:read("will_delete.txt")).to.equal(nil)
        end)

        it("write overwrites existing bytes", function()
            tmpdir = make_tmpdir()
            backend = b.make(tmpdir)
            backend:write("overwrite.txt", "v1")
            backend:write("overwrite.txt", "v2")
            expect(backend:read("overwrite.txt")).to.equal("v2")
        end)

        it("cleanup", function()
            if tmpdir then b.cleanup(tmpdir) end
            expect(true).to.equal(true)
        end)
    end)
end

-- ─── artifact_store.offload tests ────────────────────────────────────────────
--
-- offload is the SOLE site of payload-to-bytes conversion.
-- (crux §payload-to-bytes scoped to artifact_store)

describe("artifact_store.offload (memory backend)", function()
    local mem_backend, store

    it("setup", function()
        mem_backend = sf.backend_artifact_memory()
        store = sf.artifact_store(mem_backend)
        expect(type(store)).to.equal("table")
    end)

    it("text format writes tostring(payload)", function()
        mem_backend = sf.backend_artifact_memory()
        store = sf.artifact_store(mem_backend)
        local rel, err = store:offload("hello world", { name = "out.txt", format = "text" })
        expect(err).to.equal(nil)
        expect(rel).to.equal("out.txt")
        local stored = mem_backend:read("out.txt")
        expect(stored).to.equal(tostring("hello world"))
    end)

    it("text format stores tostring of a number", function()
        mem_backend = sf.backend_artifact_memory()
        store = sf.artifact_store(mem_backend)
        store:offload(42, { name = "num.txt", format = "text" })
        expect(mem_backend:read("num.txt")).to.equal("42")
    end)

    it("json format writes encoded payload", function()
        mem_backend = sf.backend_artifact_memory()
        store = sf.artifact_store(mem_backend)
        local payload = { key = "value", n = 1 }
        local rel, err = store:offload(payload, { name = "data.json", format = "json" })
        expect(err).to.equal(nil)
        expect(rel).to.equal("data.json")
        local stored = mem_backend:read("data.json")
        -- stored should be a valid JSON string
        expect(type(stored)).to.equal("string")
        -- must contain the key
        expect(stored:find("value") ~= nil).to.equal(true)
    end)

    it("unsupported format raises error", function()
        mem_backend = sf.backend_artifact_memory()
        store = sf.artifact_store(mem_backend)
        local ok = pcall(function() store:offload("data", { name = "x.bin", format = "binary" }) end)
        expect(ok).to.equal(false)
    end)

    it("returns nil, err when opts.name is missing", function()
        mem_backend = sf.backend_artifact_memory()
        store = sf.artifact_store(mem_backend)
        local rel, err = store:offload("data", { format = "text" })
        expect(rel).to.equal(nil)
        expect(type(err)).to.equal("string")
    end)

    it("returns nil, err when backend write fails", function()
        -- backend that always errors on write
        local bad_backend = {
            write = function(_, _, _) error("write failure") end,
            read = function(_, _) return nil end,
            exists = function(_, _) return false end,
            delete = function(_, _) end,
        }
        store = sf.artifact_store(bad_backend)
        local rel, err = store:offload("data", { name = "fail.txt", format = "text" })
        expect(rel).to.equal(nil)
        expect(type(err)).to.equal("string")
    end)

    it("backend receives encoded bytes, not original payload", function()
        -- Verify crux §payload-to-bytes: backend sees only string bytes
        local received_bytes = nil
        local spy_backend = {
            write = function(_, rel_path, bytes) received_bytes = bytes end,
            read = function(_, _) return nil end,
            exists = function(_, _) return false end,
            delete = function(_, _) end,
        }
        store = sf.artifact_store(spy_backend)
        local payload = { x = 1 }
        store:offload(payload, { name = "spy.json", format = "json" })
        -- backend should have received a string (encoded bytes), not the original table
        expect(type(received_bytes)).to.equal("string")
    end)
end)

describe("artifact_store.offload (file backend)", function()
    it("round-trip write and read via store", function()
        local tmpdir = make_tmpdir()
        local file_backend = sf.backend_artifact_file({ task_dir = tmpdir })
        local store = sf.artifact_store(file_backend)
        local rel, err = store:offload("file content", { name = "output.txt", format = "text" })
        expect(err).to.equal(nil)
        expect(rel).to.equal("output.txt")
        local got = store:read("output.txt")
        expect(got).to.equal("file content")
        rm_rf(tmpdir)
    end)

    it("exists and delete via store proxy", function()
        local tmpdir = make_tmpdir()
        local file_backend = sf.backend_artifact_file({ task_dir = tmpdir })
        local store = sf.artifact_store(file_backend)
        store:offload("data", { name = "check.txt", format = "text" })
        expect(store:exists("check.txt")).to.equal(true)
        store:delete("check.txt")
        expect(store:exists("check.txt")).to.equal(false)
        rm_rf(tmpdir)
    end)
end)

describe("artifact_store: backend validation", function()
    it("raises when backend is missing write method", function()
        local bad = { read = function() end, exists = function() end, delete = function() end }
        local ok = pcall(sf.artifact_store, bad)
        expect(ok).to.equal(false)
    end)

    it("raises when backend is missing read method", function()
        local bad = { write = function() end, exists = function() end, delete = function() end }
        local ok = pcall(sf.artifact_store, bad)
        expect(ok).to.equal(false)
    end)

    it("raises when backend is missing exists method", function()
        local bad = { write = function() end, read = function() end, delete = function() end }
        local ok = pcall(sf.artifact_store, bad)
        expect(ok).to.equal(false)
    end)

    it("raises when backend is missing delete method", function()
        local bad = { write = function() end, read = function() end, exists = function() end }
        local ok = pcall(sf.artifact_store, bad)
        expect(ok).to.equal(false)
    end)
end)

-- ─── backend_artifact_file specific tests ────────────────────────────────────

describe("backend_artifact_file: opts validation", function()
    it("raises when task_dir is not provided", function()
        local ok = pcall(sf.backend_artifact_file, {})
        expect(ok).to.equal(false)
    end)

    it("raises when called with no opts", function()
        -- opts defaults to {}, so task_dir will be nil
        local ok = pcall(sf.backend_artifact_file)
        expect(ok).to.equal(false)
    end)
end)

-- ─── summarize: standalone pure export ───────────────────────────────────────
--
-- Crux §summarize as standalone pure export:
-- M.summarize must be callable without instantiating any store or backend.
-- This describe block intentionally does NOT require artifact_store or any backend.

describe("summarize (standalone)", function()
    it("is accessible as sf.summarize without any store instance", function()
        -- Call directly — no store, no backend, no require of artifact_store module
        local result = sf.summarize("hello", { format = "text", max_chars = 200 })
        expect(type(result)).to.equal("string")
        expect(result).to.equal("hello")
    end)

    it("text format returns tostring of payload", function()
        local result = sf.summarize(42, { format = "text", max_chars = 200 })
        expect(result).to.equal("42")
    end)

    it("text format truncates to max_chars", function()
        local long = string.rep("a", 300)
        local result = sf.summarize(long, { format = "text", max_chars = 100 })
        expect(#result).to.equal(100)
    end)

    it("text format returns full string when within max_chars", function()
        local result = sf.summarize("short", { format = "text", max_chars = 200 })
        expect(result).to.equal("short")
    end)

    it("json format returns encoded string", function()
        local result = sf.summarize({ a = 1 }, { format = "json", max_chars = 200 })
        expect(type(result)).to.equal("string")
        -- should be valid-looking JSON
        expect(result:find("{") ~= nil).to.equal(true)
    end)

    it("json format truncates to max_chars", function()
        local big = {}
        for i = 1, 100 do
            big[i] = string.rep("x", 10)
        end
        local result = sf.summarize(big, { format = "json", max_chars = 50 })
        expect(#result <= 50).to.equal(true)
    end)

    it("defaults to max_chars=200 when not specified", function()
        local long = string.rep("b", 300)
        local result = sf.summarize(long, { format = "text" })
        expect(#result).to.equal(200)
    end)

    it("defaults to text format when format not specified", function()
        local result = sf.summarize("plain", {})
        expect(result).to.equal("plain")
    end)

    it("unknown format falls back to tostring", function()
        -- summarize does not error on unknown format; it falls back to tostring
        local result = sf.summarize("data", { format = "unknown", max_chars = 200 })
        expect(type(result)).to.equal("string")
    end)
end)
