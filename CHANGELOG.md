# Changelog

## v0.11.0 (2026-06-20, breaking)

### Changed — swarm_frame (JSON provider chain reduced to 2-step injection seam)

- `swarm_frame` JSON provider chain shrunk from 5 steps to 2: (1) `M.host` explicit injection (DI seam for spec mocks) → (2) `_G.alc.json_encode/decode` (algocline runtime). If neither is available the resolver raises (`requires _G.alc.json_* (algocline runtime) or M.host injection`)
- Same 2-step shrink in `swarm_frame.artifact_store` internal `_host()` (M.host not honoured at sub-module level — `_G.alc` only)

### Removed — fallback providers (back-compat break)

- `packages/swarm_frame/pure_json.lua` deleted (rxi/json.lua MIT vendor); the always-present fallback is no longer carried
- `dkjson` / `cjson` `pcall(require, ...)` probes removed from both `swarm_frame/init.lua` and `swarm_frame/artifact_store.lua`
- Pkgs that were ever executed outside the algocline runtime without an `M.host` override will now raise — intentional. Tests inject `M.host`, production uses `_G.alc.json_*` (alc_run / alc_pkg_test).

### Internal

- spec: `packages/swarm_frame/spec/host_seam_spec.lua` (c) `vendored pure_json fallback` block replaced with `missing host raises` (asserts `M.host=nil` + `_G.alc=nil` → `json_encode/decode` fail with `algocline runtime` message)
- `swarm_frame` docstring Status line updated to v0.10.0

### Bumped

- `swarm_frame` v0.9.0 → v0.10.0 (minor, breaking — fallback chain removal)
- repo tag v0.10.0 → v0.11.0 (Hub collection bump trigger (b) — existing pkg breaking change)

## v0.10.0 (2026-06-14, additive)

### Added — packages/swarm_state_method (new pkg)

- `swarm_state_method.run({action = "update_dispatch_record", namespace, key, update})` — domain-aware state update verb composing the algocline >= v0.44.0 Alc MCP layer (`alc.state.show` + `alc.state.set_dispatched`) into a single business action callable via `alc_advice` without writing Lua on the spot
- Initial verb `update_dispatch_record` — shallow-merge a patch into an existing record's `state.data` via show → merge → set_dispatched; preserves `identity` and non-overlapping data fields; returns `{ok, namespace, key, updated_fields[sorted]}`
- `ensure_state_table` decode seam — absorbs the bridge return shape (JSON string in production vs table in `alc.state.show` docstring) by decoding through `alc.json_decode` when needed, while keeping mock injection (table-direct) intact for unit tests
- `opts.alc` injection seam follows the `combinator_demo/init.lua:57` convention (production picks up `_G.alc`, tests pass a mocked table)

### Added — packages/verdict_loop_plugin (new pkg)

- `verdict_loop_plugin` — Swarm plugin wrapping a pipeline step with gate-verdict-fix-retry loop semantics on top of `around_step` + `ctx.dispatch` (swarm_frame_algocline v0.3.0 primitives)
- Per attempt up to `max_retries + 1`: dispatch gate step → evaluate response with `parser()` → return on `"pass"` → call `ctx.dispatch(fix_spec)` on `"blocked"` if `fix_spec` is present → return exhausted BLOCKED string after all attempts
- Applies to a single declared `step_id`; all other steps pass through transparently, so multiple instances can co-exist in `opts.plugins`
- Reference pattern: V1 coding_orch `_verdict_loop` 14 call-sites

### Added — swarm_frame_algocline (step lifecycle hooks + ctx.dispatch)

- `before_step` / `around_step` / `after_step` plugin hooks on `make_dispatcher` — per-step lifecycle around the dispatcher round-trip
- `ctx.dispatch(spec)` primitive — caller-triggered inner dispatch from inside `around_step`; enables retry / fallback / fix-loop patterns without leaking dispatcher state
- Safeguard: bounded recursion depth (`max_recursion_depth`) on `ctx.dispatch` to prevent infinite fix loops

### Internal

- spec: `packages/swarm_state_method/spec/update_dispatch_record_spec.lua` (23 lust cases — entry-point validation / verb validation / decode / happy / opts.alc seam / meta)
- `M.spec` carries `alc_shapes_compat = ">=0.25.0, <0.26"` and a stub `entries.run` skeleton (T.shape() detail deferred to a later minor)
- spec: `packages/verdict_loop_plugin/spec/*.lua` — gate/fix dispatch chain + return shape + boundary cases
- spec: `packages/swarm_frame_algocline/spec/dispatcher_spec.lua` `max_recursion_depth` test routed through `around_dispatch` (commit 6d35efa)
- spec: lust import cleanup + `verdict_loop_plugin` assertion fix (commit 97a4ea8)
- chore: `hub_index.json` regenerated after swarm_frame_algocline v0.3.0 bump (commit 672425e)
- design: topic/plugin-verdict-loop-step-design tracked the 2-stage rollout (st1 → st2 → final)
- Refs: `algocline/docs/state-management.md` (Phase C swarm package layer specification); cross-ref to algocline GH issue #6 (state primitive 2-layer split, Phase A + B shipped in algocline v0.44.0)

### Bumped

- `swarm_frame_algocline` v0.2.0 → v0.3.0 (minor additive — step lifecycle hooks + ctx.dispatch + safeguard)
- `verdict_loop_plugin` 新規 v0.1.0
- `swarm_state_method` 新規 v0.1.0
- repo tag v0.9.0 → v0.10.0 (Hub collection bump trigger (a) — 2 new pkgs added)

## v0.9.0 (2026-06-02, additive)

### Added — swarm_frame (control-flow combinators)

- `swarm_frame.sequence({handlers, cp_key?})` — ordered Handler list, short-circuits on non-DONE verdict
- `swarm_frame.loop({body, until_, max, cp_key?})` — bounded iteration with `until_(ctx, response)` predicate exit
- `swarm_frame.branch({cond, then_, else_?})` — single-shot dispatch; synthesizes DONE when `else_` is omitted on falsy cond
- `swarm_frame.verdict_loop({gate, fix?, parser, max_retries, cp_key?})` — retry-on-FAIL gate with optional fix between attempts
- lshape schemas registered into `lshape.check.default_registry` as `SwarmFrame.SequenceOpts` / `SwarmFrame.LoopOpts` / `SwarmFrame.BranchOpts` / `SwarmFrame.VerdictLoopOpts` / `SwarmFrame.Handler`

### Added — packages/combinator_demo (new pkg)

- `combinator_demo.run({task, max_retries?})` — minimal verdict_loop demo: asks `alc.llm` for an answer, retries when the response does not contain `\boxed{...}`
- `examples/combinator_demo.lua` — mock-LLM smoke (`just combinator-demo`)
- `scripts/e2e/combinator_demo.lua` — real-LLM e2e via agent-block (`just e2e combinator_demo`), uses `alc_run` trampoline since `alc_advice`'s strategy lookup does not consult variant scope in current alc

### Internal

- spec: `packages/swarm_frame/spec/combinator_{sequence,loop,branch,verdict_loop}_spec.lua` (3 contract cases per primitive, 12 total)
- spec: `packages/swarm_frame/spec/combinator_composability_spec.lua` (4 boundary cases — nested verdict_loop⊃sequence, sequence⊃verdict_loop, branch⊃loop+sequence, callable-table handler)
- design: `design/design-doc.md` §9 Control-flow combinators section added; mechanism/policy boundary documented; `_verdict_loop` direct-promote rejection rationale recorded

### Bumped

- `swarm_frame` v0.8.0 → v0.9.0 (minor additive)
- `swarm_frame.plain_state.VERSION` 同 (sub-module 揃え)
- `swarm_frame.normalize.VERSION` 同 (sub-module 揃え)
- `combinator_demo` 新規 v0.1.0

## v0.8.0 (2026-05-31, additive)

### Added — swarm_frame (artifact_store sub-module)

- `swarm_frame.artifact_store(backend)` — store factory with `:offload(payload, {name, task_dir, format}) → (abs_path, err)`
- `swarm_frame.backend_artifact_file([opts])` — default FS backend (4-method: write/read/exists/delete)
- `swarm_frame.backend_artifact_memory()` — in-memory backend, test 用
- `swarm_frame.summarize(payload, {format, max_chars})` — standalone pure helper, format=text/json

### Added — swarm_frame_algocline (resolve_task_dir)

- `swarm_frame_algocline.resolve_task_dir({project_root, task_id, namespace?})` — task_dir resolver with ctx → ALC_PROJECT_ROOT → PWD priority, mkdir -p included

### Bumped

- `swarm_frame` v0.7.0 → v0.8.0 (minor additive)
- `swarm_frame.plain_state.VERSION` 同 (sub-module 揃え)
- `swarm_frame.normalize.VERSION` 同 (sub-module 揃え)
- `swarm_frame_algocline` v0.1.1 → v0.2.0 (minor additive ※ repo tag v0.7.0 衝突回避のため v0.1.2 は unpublished pre-release)

### Internal

- spec: `packages/swarm_frame/spec/artifact_store_spec.lua` (backend contract test for memory + FS, artifact_store.offload, summarize standalone)
- spec: `packages/swarm_frame_algocline/spec/resolve_task_dir_spec.lua` (env DI 3-path coverage)
- fix: `local lust = require("lust")` を 2 新規 spec 先頭に追加 (dofile-from-tests/run.lua 経路の global lust 未解決 regression 解消)

## v0.7.0 (2026-05-27, additive)

### Added — examples

- `examples/conway_gol_spike/` — Conway Game of Life via 3 Pure Primitives (P1/P6/P7)
- `examples/ga_spike/` — Pure GA via P1+P4+Q1+P7
- `examples/market_spike/` — Zero-sum market via P1+P3+P7
- `examples/pd_spike/` — Iterated Prisoner's Dilemma via P1+P2+P4+Q1+P7
- `examples/arena_spike/` — Arena via P1+P2+P4+Q1+P5+P6+P7

### Added — infrastructure

- `justfile` spike recipes (`spike-conway`, `spike-ga`, `spike-market`, `spike-pd`, `spike-arena`)
- `tests/run.lua` extended with unit tests for new primitives (ledger P3, scalar_pool P2, knowledge_channel P5)

### Fixes

- `packages/swarm_aggregate_plugin/init.lua` docstring: removed internal workspace path reference

## v0.6.0 (YYYY-MM-DD, additive)

### Added — swarm_frame

- `swarm_frame.plain_state.gate_decide` signature 拡張: 第 6 引数に `ctx?` を追加し
  `(gates, completed_steps, name, verdict, save_fn?, ctx?)` となった。
  `ctx` は省略または `nil` 渡し可。省略時は v0.5.0 と bit-identical な動作を保証する
  (Crux 1: ctx omission bit-identical compat)。

- `Verdict:applicable_under()` method を metatable に追加。default 実装は
  `self.applicable_under or "*"` を返す。factory (`M.verdict`) 経由で生成した
  Verdict は常に本 method を持つ。factory 外の literal table verdict は
  `applicable_under` field / method を持たなくてよく、その場合は `"*"` (全 strategy
  で適用) として扱われる (Crux 2: custom Verdict method-absent default)。
  `applicable_under` は factory 呼び出し時点でのみ設定可能で、後付け setter は
  Frame 側に存在しない (Crux 3: applicable_under factory-only immutability)。

- `swarm_frame.State:gate_decide(name, verdict, save_fn?, ctx?)` — 第 4 引数 `ctx?`
  を追加。`plain_state.gate_decide` への thin delegate として ctx を透過 pass-through
  する。

### Contract — ctx-aware gate routing

```
[ctx 省略時 (v0.5.0 互換パス)]
  gate_decide(...) と gate_decide(..., nil, nil) は gates[name] の shape が
  bit-identical であることを保証する。既存の 5-arg 呼び出し形式は変更不要。

[ctx あり / applicable_under 照合パス]
  ctx.strategy が verdict:applicable_under() の返す list に含まれる場合:
    → 通常の transition (halt/pass 判定 → completed_steps append 等)
  ctx.strategy が list に含まれない場合:
    → gates[name].skipped = true
    → gates[name].skip_reason = "ctx.strategy '<s>' not in applicable_under"
    → retries は +1 (呼び出し回数)
    → marked_at 不設定 / completed_steps append なし
    → gates[name].verdict は pass-through 保存 (Rich Verdict 契約と一貫)

[method-absent / 値不正 フォールバック]
  verdict.applicable_under が function でない (literal table 等) → "*" 扱い
  ctx.strategy が nil (ctx={} 等) → applicability check skip → 全 strategy で apply
  ctx が nil → 従来 path (bit-identical)
```

### Version bump

- `swarm_frame` v0.5.0 → v0.6.0 (minor additive)
- `swarm_frame.plain_state.VERSION` 同 (sub-module 揃え)
- `swarm_frame.normalize.VERSION` 同 (sub-module 揃え)
- `M.meta.version` 同
- `packages/swarm_frame/init.lua:13` docstring `Status: v0.3.0` → `v0.6.0` (debt #3 同時解消)
- `tests/run.lua:1506` normalize.VERSION assertion `"0.4.0"` → `"0.6.0"` (debt #1 同時解消)

## v0.5.0 (2026-05-19, additive)

### Added — swarm_frame

- `swarm_frame.plain_state.verdict(fields)` Verdict factory: Rich Verdict
  オブジェクトを生成し、`is_halting()` method を metatable 経由で注入する。
  Custom `is_halting` override は producer が `fields.is_halting = function(self) ... end`
  で渡すことで `__index` chain の先勝ちにより default を覆せる。
  factory を経由しない literal table verdict も `gate_decide` 内部のフォールバック
  (metatable 不在時に Verdict metatable を付与) で受け付ける。

- `swarm_frame.plain_state.gate_decide(gates, completed_steps, name, verdict, save_fn?)`:
  新 primitive。Rich Verdict 2 層分離 (Internal `is_halting()` transition /
  Host information pass-through) を実装する唯一の transition window。
  `retries` は halt/pass 問わず呼び出しごとに +1 (gate_decide 呼び出し回数を数える)。
  `marked_at` は halt 時のみセット。`save_fn` があれば state mutation 後に invoke する。

- `swarm_frame.State:gate_decide(name, verdict, save_fn?)`: State method 版。
  `_data.gates` / `_data.completed_steps` を lazy init し、
  `plain_state.gate_decide` に委譲する。

### Contract — Rich Verdict 2 層分離

```
[Internal transition layer (硬い)]
  verdict:is_halting() -> bool
    State machine の transition を決める唯一の関数。
    gate_decide はこれ以外を読まない。string match 禁止。
  default 実装: next_action == "halt" のときのみ true

[Host information layer (Rich)]
  verdict.next_action   string  -- "halt"/"escalate"/"retry"/Custom
  verdict.detail        string?
  verdict.raw           any
  verdict.label         string
  -> state.data.gates[name].verdict に丸ごと pass-through 保存される
  -> gate_decide は意味解釈・変換・削除を一切行わない
  -> consumer / Human が Rich Verdict を読んで自由に判断する
```

### Custom verdict producer の責務

新規 Verdict producer 追加時:

- `is_halting()` を実装する (default: `next_action == "halt"` を継承可)
- `next_action` には Host 向け semantics を任意 string で入れてよい
  (例: `"human_escalation_needed"` / `"rate_limited_retry"`)
- primitive は Custom next_action 値で挙動を変えない (硬い分離)

### Design note — plain_state vs State 統合 撤退

v0.5.0 では `plain_state` (list 形 free function) と `State` (map 形 method) の
2 surface 統合は行わない。2 surface の container 形 (`_step_done` map vs
`completed_steps` list) が異なり、統合には既存 spec 書き換えが伴うため、
今回は並存継続を選択した。新 primitive `gate_decide` は両 surface に提供する。
統合は将来の minor version で再検討する。

### Version bump

- `swarm_frame` v0.4.0 → v0.5.0 (minor additive)
- `swarm_frame.plain_state.VERSION` 同 (sub-module 揃え)
- `swarm_frame.normalize.VERSION` 同 (sub-module 揃え)
- `M.meta.version` 同
