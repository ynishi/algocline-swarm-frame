---@module 'swarm_frame.v3'
-- V3 entry: public surface for the new Pattern A swarm_frame.
--
-- This module exposes the builder primitives + Expr DSL + Driver from
-- the new /engine + /frame sub-trees. The legacy swarm_frame entry
-- (packages/swarm_frame/init.lua) is untouched in P1-P7 and will be
-- replaced by this module in P8 (cleanup phase, draft-v3 §4.5).
--
-- Surface (V3 §5.2):
--   Builder primitives (7): step / chain / fan / loop / route / let / call
--   Expr DSL (9):           path / lit / eq / and_ / or_ / not_ / lt / len / ext
--   Driver:                 run({shape, dispatch, externs?, flows?, ...})
--
-- P2 completes all 7 builder primitives + 9 Expr ops + extends Driver
-- to pass externs / flows / max_call_depth through to flow.ir.exec.

local shape      = require("swarm_frame.v3.frame.shape")
local engine     = require("swarm_frame.v3.engine")
local contract   = require("swarm_frame.v3.contract")
local composites = require("swarm_frame.v3.composites")

local runtime = engine.runtime

local M = {}
M.VERSION = "0.0.2-v3-p5"

-- ── Engine namespace (advanced: caller may compose plugin_chain etc.)
M.engine = engine

-- ── Contract namespace (host adapter consumes; caller may validate) ─
M.contract = contract

-- ── Composite library (verdict_loop / aggregate, V3 §5.8) ──────────
M.composite = composites

-- ── State semantics built-in (R5 land, §4.1.3 + §5.6.2) ────────────
M.STATUS                      = runtime.STATUS
M.step_mark                   = runtime.step_mark
M.step_done                   = runtime.step_done
M.gate_decide                 = runtime.gate_decide
M.resolve_state               = runtime.resolve_state
M.wrap_dispatch_with_progress = runtime.wrap_dispatch_with_progress
M.make_checkpoint_plugin      = runtime.make_checkpoint_plugin

-- ── Builder primitives (7) ──────────────────────────────────────────
M.step  = shape.step
M.chain = shape.chain
M.fan   = shape.fan
M.loop  = shape.loop
M.route = shape.route
M.let   = shape.let
M.call  = shape.call

-- ── Expr DSL (9) ────────────────────────────────────────────────────
M.path = shape.path
M.lit  = shape.lit
M.eq   = shape.eq
M.and_ = shape.and_
M.or_  = shape.or_
M.not_ = shape.not_
M.lt   = shape.lt
M.len  = shape.len
M.ext  = shape.ext

-- ── Driver ──────────────────────────────────────────────────────────
M.run = runtime.run

return M
