-- resolve_task_dir_spec.lua — M.resolve_task_dir の env DI / path / mkdir spec
--
-- DSL 規約: lust global は alc_pkg_test runner が auto-inject する。
-- package.path 手動設定禁止 (§8-7-36)。
local sfa = require("swarm_frame_algocline")
local describe, it, expect = lust.describe, lust.it, lust.expect

-- ─── helpers ────────────────────────────────────────────────────────

local function _shell_quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

local function _rm_rf(path) os.execute("rm -rf " .. _shell_quote(path)) end

--- Build an env-injector from a key→value map.
local function make_env(map)
    return function(name) return map[name] end
end

--- Unique temp base dir per test to avoid cross-test pollution.
local function tmp_base() return "/tmp/sfa_rtd_" .. tostring(math.random(1000000, 9999999)) end

-- ─── specs ──────────────────────────────────────────────────────────

describe("resolve_task_dir", function()
    -- ----------------------------------------------------------------
    -- 1. source priority: opts.project_root (highest)
    -- ----------------------------------------------------------------
    it("uses opts.project_root when given (ignores ALC_PROJECT_ROOT / PWD)", function()
        local base = tmp_base()
        local env = make_env({ ALC_PROJECT_ROOT = "/should/not/use", PWD = "/also/not" })
        local p, err = sfa.resolve_task_dir({
            project_root = base,
            task_id = "t1",
            _env = env,
        })
        expect(err).to.equal(nil)
        expect(p).to.equal(base .. "/workspace/tasks/t1")
        _rm_rf(base)
    end)

    -- ----------------------------------------------------------------
    -- 2. source priority: ALC_PROJECT_ROOT (second)
    -- ----------------------------------------------------------------
    it("falls back to ALC_PROJECT_ROOT when opts.project_root is nil", function()
        local base = tmp_base()
        local env = make_env({ ALC_PROJECT_ROOT = base, PWD = "/should/not/use" })
        local p, err = sfa.resolve_task_dir({
            task_id = "t2",
            _env = env,
        })
        expect(err).to.equal(nil)
        expect(p).to.equal(base .. "/workspace/tasks/t2")
        _rm_rf(base)
    end)

    -- ----------------------------------------------------------------
    -- 3. source priority: PWD (third)
    -- ----------------------------------------------------------------
    it("falls back to PWD when both opts.project_root and ALC_PROJECT_ROOT are nil", function()
        local base = tmp_base()
        local env = make_env({ PWD = base })
        local p, err = sfa.resolve_task_dir({
            task_id = "t3",
            _env = env,
        })
        expect(err).to.equal(nil)
        expect(p).to.equal(base .. "/workspace/tasks/t3")
        _rm_rf(base)
    end)

    -- ----------------------------------------------------------------
    -- 4. all sources nil → nil, err
    -- ----------------------------------------------------------------
    it("returns nil, err_string when all three sources are nil", function()
        local env = make_env({})
        local p, err = sfa.resolve_task_dir({
            task_id = "t4",
            _env = env,
        })
        expect(p).to.equal(nil)
        expect(type(err)).to.equal("string")
        -- error message must mention expected var names
        expect(string.find(err, "ALC_PROJECT_ROOT", 1, true) ~= nil).to.equal(true)
        expect(string.find(err, "PWD", 1, true) ~= nil).to.equal(true)
    end)

    -- ----------------------------------------------------------------
    -- 5. namespace absent → workspace/tasks/<task_id>
    -- ----------------------------------------------------------------
    it("produces workspace/tasks/<task_id> when namespace is absent", function()
        local base = tmp_base()
        local env = make_env({ ALC_PROJECT_ROOT = base })
        local p, err = sfa.resolve_task_dir({
            task_id = "no-ns",
            _env = env,
        })
        expect(err).to.equal(nil)
        expect(p).to.equal(base .. "/workspace/tasks/no-ns")
        _rm_rf(base)
    end)

    -- ----------------------------------------------------------------
    -- 6. namespace present → workspace/tasks/<namespace>/<task_id>
    -- ----------------------------------------------------------------
    it("inserts namespace segment when given", function()
        local base = tmp_base()
        local env = make_env({ ALC_PROJECT_ROOT = base })
        local p, err = sfa.resolve_task_dir({
            task_id = "my-task",
            namespace = "my-ns",
            _env = env,
        })
        expect(err).to.equal(nil)
        expect(p).to.equal(base .. "/workspace/tasks/my-ns/my-task")
        _rm_rf(base)
    end)

    -- ----------------------------------------------------------------
    -- 7. mkdir -p is idempotent
    -- ----------------------------------------------------------------
    it("mkdir -p is idempotent (calling twice yields same path, no error)", function()
        local base = tmp_base()
        local env = make_env({ ALC_PROJECT_ROOT = base })
        local p1, err1 = sfa.resolve_task_dir({
            task_id = "idem",
            _env = env,
        })
        expect(err1).to.equal(nil)
        local p2, err2 = sfa.resolve_task_dir({
            task_id = "idem",
            _env = env,
        })
        expect(err2).to.equal(nil)
        expect(p1).to.equal(p2)
        _rm_rf(base)
    end)

    -- ----------------------------------------------------------------
    -- 8. task_id missing → error (programming error)
    -- ----------------------------------------------------------------
    it("raises when task_id is nil", function()
        local env = make_env({ ALC_PROJECT_ROOT = "/some/path" })
        local ok, err = pcall(function() sfa.resolve_task_dir({ _env = env }) end)
        expect(ok).to.equal(false)
        expect(string.find(err, "task_id is required", 1, true) ~= nil).to.equal(true)
    end)

    -- ----------------------------------------------------------------
    -- 9. task_id empty string → error (programming error)
    -- ----------------------------------------------------------------
    it("raises when task_id is empty string", function()
        local env = make_env({ ALC_PROJECT_ROOT = "/some/path" })
        local ok, err = pcall(function() sfa.resolve_task_dir({ task_id = "", _env = env }) end)
        expect(ok).to.equal(false)
        expect(string.find(err, "task_id is required", 1, true) ~= nil).to.equal(true)
    end)

    -- ----------------------------------------------------------------
    -- 10. opts = nil → raises for missing task_id (not crash on nil opts)
    -- ----------------------------------------------------------------
    it("raises for missing task_id even when opts is nil", function()
        local ok, err = pcall(function() sfa.resolve_task_dir(nil) end)
        expect(ok).to.equal(false)
        expect(string.find(err, "task_id is required", 1, true) ~= nil).to.equal(true)
    end)
end)
