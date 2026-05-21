# Changelog

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
