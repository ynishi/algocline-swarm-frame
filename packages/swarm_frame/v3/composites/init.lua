---@module 'swarm_frame.v3.composites'
-- Composite library (V3 §5.8) — thin wrappers over the 7 builder
-- primitives + Expr DSL. Composites do NOT introduce new IR; they only
-- compose existing primitives.
--
-- Placement: (i) swarm_frame 内 (V3 §5.9 軸 A 暫定 default、 §8.1 R7 carry).
-- Configuration knobs intentionally rebrand to the historical plugin
-- caller IF so verdict_loop_plugin (137 行) / swarm_aggregate_plugin
-- (229 行) replacement is 1:1 at the call-site.

local verdict_loop   = require("swarm_frame.v3.composites.verdict_loop")
local aggregate      = require("swarm_frame.v3.composites.aggregate")
local escalate_gate  = require("swarm_frame.v3.composites.escalate_gate")
local enhance_loop   = require("swarm_frame.v3.composites.enhance_loop")

local M = {}
M.VERSION = "0.0.3-v3-p9"

M.verdict_loop  = verdict_loop.build
M.aggregate     = aggregate.build
M.escalate_gate = escalate_gate.build
M.enhance_loop  = enhance_loop.build

return M
