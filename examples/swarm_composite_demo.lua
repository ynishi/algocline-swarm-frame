--- examples/swarm_composite_demo.lua — V3 composite + IR pipeline demo.
---
--- Companion to examples/swarm_demo.lua (raw 3-dispatcher form).
--- This sample illustrates the **declarative IR + composite** path:
--- the pipeline shape is expressed as data (`swarm.chain({step, step,
--- ...})`) and `swarm.run({shape, dispatch})` walks the IR, invoking
--- `dispatch(ref, input, ctx)` per step. Same domain (3-Agent linear)
--- as swarm_demo.lua, written in the engine-native form.
---
--- Two paths are illustrated:
---   1. chain (3 steps linear, ctx threading via step.out)
---   2. verdict_loop composite (retry pattern, single step + until_)
---
--- Why this sample exists (companion to swarm_demo.lua):
--- swarm_frame V3 already provides a "base pipeline frame" via the
--- composite library (verdict_loop / aggregate) + the 7 primitives
--- (chain / fan / loop / route / let / step / call). This demo proves
--- you can author full pipelines as IR data, with dispatcher
--- complexity (e.g. swarm_host_alc.dispatcher) plugged in at the
--- `dispatch` seam — no extra Agent-spec layer required.
---
--- Run (no API key needed):
---     lua examples/swarm_composite_demo.lua
---     just swarm-composite-demo

package.path = "./packages/?/init.lua;./packages/?.lua;"
    .. "./tests/vendor/?.lua;"
    .. (os.getenv("HOME") or "")
    .. "/.algocline/packages/?/init.lua;"
    .. (os.getenv("HOME") or "")
    .. "/.algocline/packages/?.lua;"
    .. package.path

-- _G.alc bootstrap (flow.ir persistence requires _G.alc.json_*).
-- Same bootstrap shape as tests/run.lua.
do
    local ok_dkjson, dkjson = pcall(require, "dkjson")
    local encode, decode
    if ok_dkjson then
        encode = dkjson.encode
        decode = dkjson.decode
    else
        encode = function(t) return tostring(t) end
        decode = function(s) return s end
    end
    _G.alc = _G.alc or {}
    _G.alc.json_encode = _G.alc.json_encode or encode
    _G.alc.json_decode = _G.alc.json_decode or decode
    _G.alc.log = _G.alc.log or function() end
end

local swarm = require("swarm_frame.v3")

-- ── Path 1: chain (3-Agent linear) ──────────────────────────────────
--
-- Shape: chain({ step("@researcher"), step("@drafter"), step("@reviewer") })
-- The engine walks the chain, calling `dispatch(ref, input)` once per
-- step. Each step's response lands at the `out` ctx path, visible in
-- the final result.ctx.
--
-- Note: the engine keeps ctx internal to the IR (dispatch is invoked
-- as `dispatch(ref, input)` — no ctx parameter). Cross-step threading
-- of dispatcher-side state, when needed in a demo, is done via outer
-- closure capture. Production code typically uses step.out → step.in
-- routing or shape.let to flow values declaratively at the IR layer.

local function path1_chain()
    local shape = swarm.chain({
        swarm.step("@researcher", { out = "ctx.research" }),
        swarm.step("@drafter",    { out = "ctx.draft" }),
        swarm.step("@reviewer",   { out = "ctx.review" }),
    })

    -- Closure-captured prior outputs for the educational threading.
    local prior = {}
    local call_log = {}

    local result = swarm.run({
        shape = shape,
        dispatch = function(ref, _input)
            table.insert(call_log, ref)
            local response
            if ref == "@researcher" then
                response = {
                    content = "- Photosynthesis converts light to chemical energy\n"
                        .. "- Happens in chloroplasts\n"
                        .. "- Releases oxygen as a byproduct",
                }
                prior.research = response.content
            elseif ref == "@drafter" then
                response = {
                    content = "Photosynthesis is the process by which plants "
                        .. "convert sunlight into chemical energy, drawing on:\n"
                        .. (prior.research or ""),
                }
                prior.draft = response.content
            elseif ref == "@reviewer" then
                response = {
                    content = "OK: covers conversion, location, and oxygen byproduct.",
                    verdict = "OK",
                }
            end
            return response or {}
        end,
    })
    return result, call_log
end

-- ── Path 2: verdict_loop composite (1-step retry) ────────────────────
--
-- Shape: verdict_loop({ step="@gate", until_token="DONE", max=5 })
-- Compiles to: loop({ body=step("@gate", {out="ctx.gate"}),
--                     until_=eq(path("$.ctx.gate.verdict"), lit("DONE")),
--                     max=5, counter="ctx.iter" })
-- The engine loops the body step until the verdict field matches
-- until_token, capped by `max`.

local function path2_verdict_loop()
    local shape = swarm.composite.verdict_loop({
        step        = "@gate",
        until_token = "DONE",
        max         = 5,
        out         = "ctx.gate",
    })

    local attempts = 0
    local result = swarm.run({
        shape = shape,
        dispatch = function(_ref, _input, _ctx)
            attempts = attempts + 1
            if attempts < 3 then return { verdict = "RETRY" } end
            return { verdict = "DONE" }
        end,
    })
    return result, attempts
end

-- ── Run + report + assertions ───────────────────────────────────────

print("=== V3 composite + IR pipeline demo ===")
print("")

local r1, log1 = path1_chain()
print(string.format("Path 1 (chain): status=%s, steps=%d", r1.status, #log1))
if r1.status ~= "ok" then
    local e = r1.error or {}
    print("  error: kind=" .. tostring(e.kind) .. " message=" .. tostring(e.message))
    print("  log so far: " .. table.concat(log1, " → "))
    os.exit(1)
end
print("  dispatch ref order: "
    .. log1[1] .. " → " .. log1[2] .. " → " .. log1[3])
print("  ctx.research.content (head): "
    .. (((r1.ctx.research or {}).content) or "?"):sub(1, 60))
print("  ctx.draft.content    (head): "
    .. (((r1.ctx.draft    or {}).content) or "?"):sub(1, 60))
print("  ctx.review.content   (head): "
    .. (((r1.ctx.review   or {}).content) or "?"):sub(1, 60))
print("  ctx.review.verdict        : "
    .. tostring((r1.ctx.review or {}).verdict))
print("")

assert(r1.status == "ok", "Path 1: expected status=ok, got " .. tostring(r1.status))
assert(#log1 == 3, "Path 1: expected 3 dispatch calls, got " .. #log1)
assert(log1[1] == "@researcher" and log1[2] == "@drafter" and log1[3] == "@reviewer",
    "Path 1: expected order Researcher → Drafter → Reviewer")
assert((r1.ctx.review or {}).verdict == "OK",
    "Path 1: expected final verdict=OK")

local r2, attempts2 = path2_verdict_loop()
print(string.format("Path 2 (verdict_loop): status=%s, attempts=%d (max=5)",
    r2.status, attempts2))
print("  ctx.gate.verdict (final): " .. tostring((r2.ctx.gate or {}).verdict))
print("")

assert(r2.status == "ok", "Path 2: expected status=ok, got " .. tostring(r2.status))
assert(attempts2 == 3, "Path 2: expected 3 attempts, got " .. attempts2)
assert((r2.ctx.gate or {}).verdict == "DONE",
    "Path 2: expected final verdict=DONE")

print("PASS: V3 composite + IR demo")
print("  - Path 1: chain(3 steps) walked declaratively, ctx threading via step.out")
print("  - Path 2: verdict_loop retry until until_token, capped by max")
print("")
print("Note: This sample stays at the engine layer (no swarm_host_alc.")
print("dispatcher used). For the real-LLM round-trip path, see")
print("examples/swarm_demo.lua + scripts/e2e/swarm_demo.lua, which plug")
print("swarm_host_alc.dispatcher into the same composite/IR seam.")
