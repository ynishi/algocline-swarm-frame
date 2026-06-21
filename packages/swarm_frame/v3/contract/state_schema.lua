---@module 'swarm_frame.v3.contract.state_schema'
-- FlowState snapshot field 規約 (V3 §4.1.3 state semantics built-in,
-- §5.6.2 State / Resume Protocol R5 land).
--
-- Snapshot is the canonical persisted form for state_backend. Open
-- shape: host adapters MAY attach extra fields (e.g. host-specific
-- progress markers, audit trail) without invalidating the contract.

local T = require("alc_shapes.t")
local M = {}
M.VERSION = "0.0.1-v3-p4"

--- Per-step progress entry. Used by the resume protocol to decide
--- skip / replay / fresh-dispatch path for each step (V3 §5.6.2).
M.ProgressEntry = T.shape({
    step_id     = T.string,
    status      = T.one_of({ "pending", "done", "error" }),
    artifact_id = T.string:is_optional():describe("ref into /engine/store offload"),
}, { open = true })

--- Snapshot: persistable summary of a flow run.
M.Snapshot = T.shape({
    task_id    = T.string:describe("uuid / user-provided id"),
    status     = T.one_of({
        "not_started", "in_progress", "completed", "failed", "interrupted",
    }):describe("5-value status per R5 land (V3 §5.6.2 §1)"),
    ctx        = T.table:describe("the runtime ctx; mutated in place by exec"),
    progress   = T.array_of(M.ProgressEntry):is_optional():describe(
        "per-step progress entries for resume decisions"),
    started_at = T.number:is_optional(),
    updated_at = T.number:is_optional(),
}, { open = true })

return M
