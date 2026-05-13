# swarm-frame examples

Reference implementations of pipelines built on top of swarm_frame +
swarm_frame_algocline. They are **not** consumed by the frame
itself; they exist so contributors can see what a real pipeline
looks like.

## bundled_base_curator

A 6-step linear pipeline that demonstrates the canonical
swarm-frame usage: register specs, run `frame.run_linear`, and let
the frame own per-step state mutation, verdict parsing, and BLOCKED
propagation.

Why this example matters: it shows how the frame eliminates the
per-step boilerplate (`if not step_done → spec → delegate →
parse_verdict → error if !DONE → step_mark`) that downstream
pipelines otherwise copy-paste at every step. That boilerplate is
the structural source of the state-management bug class the frame
is designed to prevent.

### Running

```
just test   # runs the full suite including the example's mock tests
```

The example assumes `lshape` is available via `alc_pkg_link` (see
`README.md` §Setup). No live algocline runtime is required to run
the tests — `tests/run.lua` injects mocks for the algocline runtime
dependencies (`flow`, the convention-based delegate package, and the
`alc` global).
