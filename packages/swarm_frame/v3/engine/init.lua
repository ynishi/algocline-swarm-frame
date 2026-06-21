---@module 'swarm_frame.v3.engine'
-- Engine aggregator — re-exports the /engine sub-modules so callers
-- can write `local E = require("swarm_frame.v3.engine")` and access
-- the whole engine surface.
--
-- Each sub-module is also requireable standalone (e.g.
-- `require("swarm_frame.v3.engine.plugin_chain")`).
--
-- P3 minimal: 4 sub-module wired. State semantics built-in (step_mark /
-- step_done / gate_decide on flow.FlowState) is deferred to P5 (depends
-- on state_backend impl shipping with swarm_host_alc).

local M = {}
M.VERSION = "0.0.1-v3-p3"

M.runtime      = require("swarm_frame.v3.engine.runtime")
M.plugin_chain = require("swarm_frame.v3.engine.plugin_chain")
M.observer     = require("swarm_frame.v3.engine.observer")
M.safeguard    = require("swarm_frame.v3.engine.safeguard")
M.store        = require("swarm_frame.v3.engine.store")

return M
