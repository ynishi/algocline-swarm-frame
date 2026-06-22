-- prompt_builder_spec.lua — Boundary regression spec for
-- swarm_host_alc.prompt_builder (P5 step 4).
--
-- Two helpers under test:
--   invoke(builder, step, spec) -> prompt
--   merge_llm_opts(base, overlay, step) -> effective

local lust = require("lust")
local describe, it, expect = lust.describe, lust.it, lust.expect

local pb = require("swarm_host_alc.prompt_builder")

local function contains(s, sub)
    return type(s) == "string" and string.find(s, sub, 1, true) ~= nil
end

-- ─── invoke ───────────────────────────────────────────────────────────

describe("swarm_host_alc.prompt_builder.invoke", function()
    it("returns the prompt string when builder is valid", function()
        local builder = function(step, _spec) return "PROMPT for " .. step end
        expect(pb.invoke(builder, "s1", { x = 1 })).to.equal("PROMPT for s1")
    end)

    it("passes step + spec verbatim to the builder", function()
        local seen_step, seen_spec
        local builder = function(step, spec)
            seen_step = step
            seen_spec = spec
            return "ok"
        end
        pb.invoke(builder, "s2", { hello = "world" })
        expect(seen_step).to.equal("s2")
        expect(seen_spec.hello).to.equal("world")
    end)

    it("errors when builder is not a function", function()
        local ok, err = pcall(pb.invoke, "not-a-fn", "s1", {})
        expect(ok).to.equal(false)
        expect(contains(err, "builder must be a function")).to.equal(true)
    end)

    it("errors when builder returns non-string", function()
        local builder = function() return 42 end
        local ok, err = pcall(pb.invoke, builder, "s1", {})
        expect(ok).to.equal(false)
        expect(contains(err, "must return a string")).to.equal(true)
        expect(contains(err, "step=s1")).to.equal(true)
    end)

    it("errors when builder returns nil", function()
        local builder = function() return nil end
        local ok, err = pcall(pb.invoke, builder, "s1", {})
        expect(ok).to.equal(false)
        expect(contains(err, "must return a string")).to.equal(true)
    end)
end)

-- ─── merge_llm_opts ───────────────────────────────────────────────────

describe("swarm_host_alc.prompt_builder.merge_llm_opts", function()
    it("returns base verbatim when overlay is nil", function()
        local base = { system = "S", max_tokens = 100 }
        local got = pb.merge_llm_opts(base, nil, "s1")
        -- identity (no copy on nil overlay)
        expect(got).to.equal(base)
    end)

    it("returns nil when both base and overlay are nil", function()
        expect(pb.merge_llm_opts(nil, nil, "s1")).to.equal(nil)
    end)

    it("returns a fresh table when overlay is present", function()
        local base = { system = "S" }
        local got = pb.merge_llm_opts(base, { max_tokens = 100 }, "s1")
        -- a fresh table, not base
        expect(got).to_not.equal(base)
        expect(got.system).to.equal("S")
        expect(got.max_tokens).to.equal(100)
    end)

    it("overlay keys overwrite base keys on collision", function()
        local got = pb.merge_llm_opts(
            { system = "base", max_tokens = 100 },
            { system = "overlay" },
            "s1"
        )
        expect(got.system).to.equal("overlay")
        expect(got.max_tokens).to.equal(100)
    end)

    it("works when base is nil but overlay is a table", function()
        local got = pb.merge_llm_opts(nil, { max_tokens = 50 }, "s1")
        expect(got.max_tokens).to.equal(50)
    end)

    it("errors when overlay is a non-nil non-table", function()
        local ok, err = pcall(pb.merge_llm_opts, { system = "S" },
            "bad", "s1")
        expect(ok).to.equal(false)
        expect(contains(err, "overlay must be a table")).to.equal(true)
        expect(contains(err, "step=s1")).to.equal(true)
    end)

    it("does not mutate the base table", function()
        local base = { system = "S" }
        pb.merge_llm_opts(base, { extra = "x" }, "s1")
        expect(base.extra).to.equal(nil)
    end)
end)
