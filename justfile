# algocline-swarm-frame — task runner
#
# Usage:
#   just                  -> list recipes
#   just test             -> run V3 standalone runner (333 testcase, no LLM)
#   just combinator-demo  -> mock-LLM example (verdict_loop retry, no API key)
#   just conway-spike     -> Conway GoL Primitive spike
#   just ga-spike         -> GA Primitive spike
#   just market-spike     -> Market Primitive spike
#   just pd-spike         -> PD Primitive spike
#   just arena-spike      -> Arena Primitive spike
#   just e2e <name>       -> run real-LLM end-to-end via agent-block
#   just e2e-all          -> run every E2E under scripts/e2e/
#
# Prereqs for e2e:
#   - `agent-block` installed (cargo install agent-block)
#   - `alc` MCP server available on PATH (cargo install algocline)
#   - ANTHROPIC_API_KEY exported (or OPENAI_API_KEY for OpenAI-compat path)
#   - CWD must be repo root (alc.toml at root is the project marker)

default:
    @just --list

# V3 standalone runner (333 testcase: sub-module + factory seam + integration).
# Pure-Lua, no LLM, no network. Sole test runner after V3 P8 cleanup —
# 旧 tests/run.lua (swarm_frame_algocline-based) は P8 Phase 2 で撤去済。
test:
    lua tests/run.lua

# Mock-LLM example for the Engine combinators: drives combinator_demo
# (verdict_loop wrapping a single alc.llm gate) with a deterministic
# mock that fails the parser twice then passes on attempt 3. Proves
# verdict_loop retry + short-circuit semantics end-to-end. No API key
# required.
combinator-demo:
    lua examples/combinator_demo.lua

# Conway GoL Primitive spike (umbrella 1779690943-76260 §9 (iv)).
# 5x5 grid + glider + 5 generations, composed from 3 Pure Primitives:
# slot_table (P1) + broadcast_bus (P6) + transition_rules (P7).
# Verifies Domain 抽象度 quality on the cellular-automaton end.
conway-spike:
    lua examples/conway_gol_spike/main.lua

# Pure GA Primitive spike (umbrella 1779690943-76260 §9 (v) A).
# N=10 + 8 gens + scalar fitness landscape, composed from 4 Primitives:
# slot_table (P1) + lineage (P4) + Q1 mutation_op (lineage subordinate)
# + transition_rules (P7 selection). Verifies Domain 抽象度 on the
# evolutionary algorithm end, orthogonal to Conway.
ga-spike:
    lua examples/ga_spike/main.lua

# Zero-sum market Primitive spike (umbrella 1779690943-76260 §9 W13).
# N=8 traders + 20 rounds + bankrupt/reentry, composed from 3 Primitives:
# slot_table (P1) + ledger (P3, NEW) + transition_rules (P7 double-headed
# active<->bankrupt verifying transition (b)). Verifies the conservation
# invariant total() == credit_total() at end.
market-spike:
    lua examples/market_spike/main.lua

# Iterated PD Primitive spike (umbrella 1779690943-76260 §9 W15).
# N=8 + 5 gens + 10 rounds/gen tournament + mixed cooperation strategy,
# composed from 5 Primitives: slot_table (P1) + scalar_pool (P2, NEW)
# + lineage (P4) + Q1 mutation_op (lineage subordinate) + transition_rules
# (P7 selection). Closes Primitive verify (6/7 + Q1 subordinate; P5
# knowledge_channel deferred to LLM-bearing future spike).
pd-spike:
    lua examples/pd_spike/main.lua

# Arena (reduced) Primitive spike (umbrella 1779690943-76260 §9 W4).
# N=6 + 4 gens + 3 rounds/gen plurality vote, composed from 6
# Primitives: slot_table (P1) + scalar_pool (P2) + lineage (P4) + Q1
# (lineage subordinate) + knowledge_channel (P5, NEW) + broadcast_bus
# (P6 plurality vote aggregation) + transition_rules (P7). Closes
# Primitive verify 7/7 + Q1 subordinate; P5 covers the last gap.
arena-spike:
    lua examples/arena_spike/main.lua

# Run a single real-LLM end-to-end via agent-block. `name` is the
# filename stem under scripts/e2e/. Drives the agent ReAct loop +
# spawned `alc` MCP server. Real API calls — incurs charges.
# [group('allow-agent')]
e2e name:
    agent-block -s scripts/e2e/{{name}}.lua -p .

# Run all E2E scenarios sequentially. Continues on individual failures.
# [group('allow-agent')]
e2e-all:
    #!/usr/bin/env bash
    set -u
    fail=0
    for f in scripts/e2e/*.lua; do
        name=$(basename "$f" .lua)
        if [[ "$name" == "common" ]]; then continue; fi
        echo "=== E2E: $name ==="
        if ! agent-block -s "$f" -p .; then
            echo "FAILED: $name"
            fail=$((fail + 1))
        fi
    done
    if [[ $fail -gt 0 ]]; then
        echo "=== $fail E2E(s) failed ==="
        exit 1
    fi
    echo "=== All E2Es passed ==="

# Format all Lua files in-place via stylua (uses .stylua.toml + .styluaignore).
format:
    stylua .

# Check formatting without writing (exit 1 if any file needs reformat).
format-check:
    stylua --check .

# Cleanup Lua build artifacts.
clean:
    rm -rf .luarocks/ *.rock *.src.rock *.o *.so

# Regenerate hub_index.json from packages/ for Hub source consumption
# (BUNDLED_SOURCES / AUTO_INSTALL_SOURCES on the algocline side).
dist:
    @echo "Use the algocline MCP tool: alc_hub_dist source_dir=./packages output_path=./hub_index.json"
    @echo "(direct CLI invocation is not yet exposed; reindex result lands at ./hub_index.json)"
