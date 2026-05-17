-- host_seam_spec.lua — Tests for the M.host DI seam and 4-step JSON chain.
--
-- Tests the following chain paths (all 3 are acceptance criteria):
--   (a) M.host explicit injection — custom encode/decode used
--   (b) _G.alc.json_encode/decode mock — algocline-engine VM path
--   (c) vendored pure_json fallback — when M.host=nil, _G.alc absent,
--       dkjson absent, cjson absent

local frame = require("swarm_frame")
local describe, it, expect = lust.describe, lust.it, lust.expect

describe("host seam", function()
    lust.before(function() frame._reset_host_for_testing() end)
    lust.after(function() frame._reset_host_for_testing() end)

    -- ─── (a) M.host explicit injection ───────────────────────────────────────

    describe("M.host explicit injection", function()
        it("uses M.host.encode when M.host is set", function()
            frame.host = {
                encode = function(t) return "MOCK_ENCODE" end,
                decode = function(s) return { mocked = true } end,
            }
            expect(frame.json_encode({})).to.equal("MOCK_ENCODE")
        end)

        it("uses M.host.decode when M.host is set", function()
            frame.host = {
                encode = function(t) return "MOCK_ENCODE" end,
                decode = function(s) return { mocked = true } end,
            }
            local result = frame.json_decode("ignored")
            expect(result.mocked).to.equal(true)
        end)

        it("raises an error when M.host lacks encode", function()
            frame.host = { decode = function(s) return {} end }
            expect(function() frame.json_encode({}) end).to.fail()
        end)

        it("raises an error when M.host lacks decode", function()
            frame.host = { encode = function(t) return "{}" end }
            expect(function() frame.json_decode("{}") end).to.fail()
        end)

        it("raises an error when M.host is a non-table", function()
            frame.host = "invalid"
            expect(function() frame.json_encode({}) end).to.fail()
        end)

        it("error message mentions encode and decode", function()
            frame.host = { encode = 42, decode = function(s) return {} end }
            expect(function() frame.json_encode({}) end).to.fail.with("encode and decode")
        end)
    end)

    -- ─── (b) _G.alc mock path ────────────────────────────────────────────────

    describe("_G.alc.json_encode/decode mock path", function()
        local saved_alc

        lust.before(function()
            saved_alc = _G.alc
            frame._reset_host_for_testing()
        end)

        lust.after(function()
            _G.alc = saved_alc
            frame._reset_host_for_testing()
        end)

        it("uses _G.alc when M.host is nil", function()
            local called_encode = false
            local called_decode = false
            _G.alc = {
                json_encode = function(t)
                    called_encode = true
                    return "ALC_ENCODE"
                end,
                json_decode = function(s)
                    called_decode = true
                    return { alc = true }
                end,
            }
            expect(frame.json_encode({})).to.equal("ALC_ENCODE")
            expect(called_encode).to.equal(true)
            local result = frame.json_decode("{}")
            expect(result.alc).to.equal(true)
            expect(called_decode).to.equal(true)
        end)

        it("does NOT use _G.alc when M.host is set", function()
            local alc_called = false
            _G.alc = {
                json_encode = function(t)
                    alc_called = true
                    return "ALC"
                end,
                json_decode = function(s)
                    alc_called = true
                    return {}
                end,
            }
            frame.host = {
                encode = function(t) return "HOST_ENCODE" end,
                decode = function(s) return {} end,
            }
            frame.json_encode({})
            expect(alc_called).to.equal(false)
        end)
    end)

    -- ─── (c) vendored pure_json fallback ────────────────────────────────────
    --
    -- In the test environment (lua tests/run.lua / alc_pkg_test), neither
    -- dkjson nor cjson is installed. With M.host=nil and _G.alc=nil the
    -- chain reaches the vendored pure_json automatically.

    describe("vendored pure_json fallback", function()
        local saved_alc

        lust.before(function()
            saved_alc = _G.alc
            frame._reset_host_for_testing()
        end)

        lust.after(function()
            _G.alc = saved_alc
            frame._reset_host_for_testing()
        end)

        it("falls back to pure_json when M.host=nil and _G.alc is absent", function()
            -- Remove _G.alc so the chain passes through dkjson/cjson probes.
            -- In this test environment neither dkjson nor cjson is installed,
            -- so the chain reaches swarm_frame.pure_json (always vendored).
            _G.alc = nil

            local encoded = frame.json_encode({ hello = "world" })
            expect(type(encoded)).to.equal("string")
            expect(encoded).to.match('"hello"')

            local decoded = frame.json_decode('{"hello":"world"}')
            expect(type(decoded)).to.equal("table")
            expect(decoded.hello).to.equal("world")
        end)

        it("pure_json encode round-trips a nested table", function()
            _G.alc = nil
            local tbl = { a = 1, b = { c = true } }
            local encoded = frame.json_encode(tbl)
            local decoded = frame.json_decode(encoded)
            expect(decoded.a).to.equal(1)
            expect(decoded.b.c).to.equal(true)
        end)

        it("pure_json decode returns nil for JSON null", function()
            _G.alc = nil
            local decoded = frame.json_decode("null")
            expect(decoded).to.equal(nil)
        end)
    end)

    -- ─── _reset_host_for_testing ─────────────────────────────────────────────

    describe("_reset_host_for_testing", function()
        it("resets M.host to nil", function()
            frame.host = {
                encode = function(t) return "MOCK" end,
                decode = function(s) return {} end,
            }
            frame._reset_host_for_testing()
            expect(frame.host).to.equal(nil)
        end)
    end)
end)
