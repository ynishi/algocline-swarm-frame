# Changelog

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
