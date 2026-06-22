-- safeguard_spec.lua — Boundary regression spec for
-- swarm_host_alc.safeguard (P5 step 6.1 sub (a)).
--
-- Covers M.DEFAULTS introspection + M.merge(opts) 6 boundary cases.

local lust = require("lust")
local describe, it, expect = lust.describe, lust.it, lust.expect

local sg = require("swarm_host_alc.safeguard")

local function contains(s, sub)
    return type(s) == "string" and string.find(s, sub, 1, true) ~= nil
end

describe("swarm_host_alc.safeguard.DEFAULTS", function()
    it("exposes the canonical defaults as a plain table", function()
        expect(sg.DEFAULTS.max_dispatch_per_step).to.equal(16)
        expect(sg.DEFAULTS.max_recursion_depth).to.equal(4)
    end)
end)

describe("swarm_host_alc.safeguard.merge", function()
    it("returns DEFAULTS verbatim when opts is nil", function()
        local got = sg.merge(nil)
        expect(got.max_dispatch_per_step).to.equal(16)
        expect(got.max_recursion_depth).to.equal(4)
    end)

    it("returns DEFAULTS verbatim when opts is an empty table", function()
        local got = sg.merge({})
        expect(got.max_dispatch_per_step).to.equal(16)
        expect(got.max_recursion_depth).to.equal(4)
    end)

    it("merges partial opts over DEFAULTS (per-key)", function()
        local got = sg.merge({ max_dispatch_per_step = 8 })
        expect(got.max_dispatch_per_step).to.equal(8)
        expect(got.max_recursion_depth).to.equal(4) -- default kept

        local got2 = sg.merge({ max_recursion_depth = 12 })
        expect(got2.max_dispatch_per_step).to.equal(16) -- default kept
        expect(got2.max_recursion_depth).to.equal(12)
    end)

    it("errors when opts is a non-nil non-table", function()
        local ok, err = pcall(sg.merge, "bad")
        expect(ok).to.equal(false)
        expect(contains(err, "opts must be a table or nil")).to.equal(true)
        expect(contains(err, "got string")).to.equal(true)
    end)

    it("errors when max_dispatch_per_step is non-positive / non-int", function()
        local ok1, err1 = pcall(sg.merge, { max_dispatch_per_step = 0 })
        expect(ok1).to.equal(false)
        expect(contains(err1, "max_dispatch_per_step must be a positive integer"))
            .to.equal(true)

        local ok2, err2 = pcall(sg.merge, { max_dispatch_per_step = -3 })
        expect(ok2).to.equal(false)
        expect(contains(err2, "max_dispatch_per_step")).to.equal(true)

        local ok3, err3 = pcall(sg.merge, { max_dispatch_per_step = 2.5 })
        expect(ok3).to.equal(false)
        expect(contains(err3, "max_dispatch_per_step")).to.equal(true)

        local ok4, err4 = pcall(sg.merge, { max_dispatch_per_step = "8" })
        expect(ok4).to.equal(false)
        expect(contains(err4, "max_dispatch_per_step")).to.equal(true)
    end)

    it("errors when max_recursion_depth is non-positive / non-int", function()
        local ok1, err1 = pcall(sg.merge, { max_recursion_depth = 0 })
        expect(ok1).to.equal(false)
        expect(contains(err1, "max_recursion_depth must be a positive integer"))
            .to.equal(true)

        local ok2, err2 = pcall(sg.merge, { max_recursion_depth = -1 })
        expect(ok2).to.equal(false)
        expect(contains(err2, "max_recursion_depth")).to.equal(true)

        local ok3, err3 = pcall(sg.merge, { max_recursion_depth = 1.5 })
        expect(ok3).to.equal(false)
        expect(contains(err3, "max_recursion_depth")).to.equal(true)

        local ok4, err4 = pcall(sg.merge, { max_recursion_depth = {} })
        expect(ok4).to.equal(false)
        expect(contains(err4, "max_recursion_depth")).to.equal(true)
    end)
end)
