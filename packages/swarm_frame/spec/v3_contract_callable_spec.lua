-- v3_contract_callable_spec.lua — Boundary regression spec for the
-- dispatcher_iface.check_call callable-table extension (V3 #8b, P5
-- step 6.1 sub (b)).
--
-- Existing v3_contract_spec.lua covers the V3 contract surface as a
-- whole; this file zooms in on the check_call boundary so that the
-- function / callable-table / plain-table accept/reject paths each
-- have a dedicated testcase that fails loudly on regression.

local lust = require("lust")
local describe, it, expect = lust.describe, lust.it, lust.expect

local iface = require("swarm_frame.v3.contract.dispatcher_iface")

local function contains(s, sub)
    return type(s) == "string" and string.find(s, sub, 1, true) ~= nil
end

describe("swarm_frame.v3.contract.dispatcher_iface.check_call (#8b)", function()
    it("accepts a plain function (V1 baseline kept)", function()
        local fn = function(_ref, _input) return {} end
        local ok, err = iface.check_call(fn)
        expect(ok).to.equal(true)
        expect(err).to.equal(nil)
    end)

    it("accepts a callable table (setmetatable + __call) — V3 #8b", function()
        local t = setmetatable({
            extras = {},
            plugins = {},
        }, {
            __call = function(_self, _ref, _input) return {} end,
        })
        local ok, err = iface.check_call(t)
        expect(ok).to.equal(true)
        expect(err).to.equal(nil)
    end)

    it("rejects a plain table with no __call metamethod", function()
        local t = { extras = {}, plugins = {} } -- no metatable
        local ok, err = iface.check_call(t)
        expect(ok).to.equal(false)
        expect(contains(err, "function or callable table")).to.equal(true)
    end)

    it("rejects a table whose __call is non-function", function()
        local t = setmetatable({}, { __call = "not-a-function" })
        local ok, err = iface.check_call(t)
        expect(ok).to.equal(false)
        expect(contains(err, "function or callable table")).to.equal(true)
    end)

    it("rejects nil / number / string", function()
        local ok1, err1 = iface.check_call(nil)
        expect(ok1).to.equal(false)
        expect(contains(err1, "function or callable table")).to.equal(true)

        local ok2, err2 = iface.check_call(42)
        expect(ok2).to.equal(false)
        expect(contains(err2, "function or callable table")).to.equal(true)

        local ok3, err3 = iface.check_call("dispatcher")
        expect(ok3).to.equal(false)
        expect(contains(err3, "function or callable table")).to.equal(true)
    end)
end)
