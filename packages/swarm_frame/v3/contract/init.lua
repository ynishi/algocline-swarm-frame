---@module 'swarm_frame.v3.contract'
-- Contract aggregator — re-exports the 5 sub-modules so callers can
-- write `local C = require("swarm_frame.v3.contract")` and access the
-- whole contract surface via `C.dispatcher_iface`, `C.state_schema`, etc.
--
-- Each sub-module is also requireable standalone (e.g.
-- `require("swarm_frame.v3.contract.dispatcher_iface")`).

local M = {}
M.VERSION = "0.0.1-v3-p4"

M.dispatcher_iface       = require("swarm_frame.v3.contract.dispatcher_iface")
M.observer_hook          = require("swarm_frame.v3.contract.observer_hook")
M.state_schema           = require("swarm_frame.v3.contract.state_schema")
M.state_backend_iface    = require("swarm_frame.v3.contract.state_backend_iface")
M.artifact_backend_iface = require("swarm_frame.v3.contract.artifact_backend_iface")

return M
