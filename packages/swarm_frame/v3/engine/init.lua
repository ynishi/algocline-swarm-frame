---@module 'swarm_frame.v3.engine'
-- Engine aggregator — re-exports the /engine sub-modules so callers
-- can write `local E = require("swarm_frame.v3.engine")` and access
-- the whole engine surface.
--
-- Each sub-module is also requireable standalone (e.g.
-- `require("swarm_frame.v3.engine.plugin_chain")`).
--
-- P5 land: 5 sub-module + state semantics built-in. state_backend
-- impl ships with swarm_host_alc (P5 §4.1.4 default = file backend).

local M = {}
M.VERSION = "0.0.2-v3-p5"

M.runtime      = require("swarm_frame.v3.engine.runtime")
M.plugin_chain = require("swarm_frame.v3.engine.plugin_chain")
M.observer     = require("swarm_frame.v3.engine.observer")
M.safeguard    = require("swarm_frame.v3.engine.safeguard")
M.store        = require("swarm_frame.v3.engine.store")
M.state        = require("swarm_frame.v3.engine.state")

return M
