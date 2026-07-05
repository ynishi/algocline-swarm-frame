---@module 'swarm_host_alc'
-- swarm_host_alc — Host adapter package for the swarm_frame V3
-- runtime, scoped to algocline as the host environment.
--
-- Provides:
--   * state_backend  — file-default persistence for FlowState snapshots
--                      (§4.1.4)
--   * artifact_backend — file-default + memory option for raw bytes
--                        artifacts (§4.1.4)
--   * state_method   — swarm_state_method 1:1 absorb
--                      (update_dispatch_record verb)
--   * prompt_builder — builder injection + llm_opts_overlay merge
--   * check_mode     — strict / non-check / format routing
--   * dispatcher     — Token & Prompt round-trip (final integration)
--
-- V3 §4.5 scope: rename + scope shrink of swarm_frame_algocline (1084
-- lines) + swarm_state_method (194 lines) → ~900 lines total across
-- the 6 sub-modules above. swarm_frame core stays host-neutral; this
-- pkg is the only place that knows about algocline-specific JSON
-- encoders, task_dir conventions, and alc.json injection seams.
--
-- ## Deprecated (2026-07-05)
--
-- Adapter for the deprecated swarm_frame V3 runtime; deprecated by
-- transitivity. New pipelines should target the flow.ir + mse stack
-- (swarm_blueprint / swarm_patterns), where host concerns like state
-- persistence, dispatcher wiring, and prompt building are owned by the
-- Rust engine (mse) instead of a Lua host adapter. See README
-- §Package status for the split.
--
-- Not scheduled for removal: kept as long as swarm_frame is kept, so
-- existing OrchV1 consumers on algocline continue to work.

local M = {}
M.VERSION = "0.0.1-v3-p5"

M.meta = {
    name = "swarm_host_alc",
    version = M.VERSION,
    category = "frame",
    description = "Host adapter for swarm_frame V3 runtime, scoped to "
        .. "algocline (state_backend / artifact_backend / state_method / "
        .. "prompt_builder / check_mode / dispatcher).",
}

-- Sub-module re-exports — P5 phased land COMPLETE at Step 6.5.
-- 7 sub-module aggregator: state_backend / artifact_backend /
-- state_method / prompt_builder / check_mode / safeguard / dispatcher.

M.state_backend    = require("swarm_host_alc.state_backend")
M.artifact_backend = require("swarm_host_alc.artifact_backend")
M.state_method     = require("swarm_host_alc.state_method")
M.prompt_builder   = require("swarm_host_alc.prompt_builder")
M.check_mode       = require("swarm_host_alc.check_mode")
M.safeguard        = require("swarm_host_alc.safeguard")
M.dispatcher       = require("swarm_host_alc.dispatcher")

return M
