# algocline-swarm-frame — task runner
#
# Usage:
#   just                  -> list recipes
#   just test             -> run all Lua tests (pure, no LLM)
#   just smoke            -> run mock-LLM example (no API key needed)
#   just check            -> lshape schema self-check on swarm_frame contracts
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

# Pure-Lua test suite (mock host, no LLM, no network).
test:
    lua tests/run.lua

# lshape schema self-check on swarm_frame contracts.
check:
    LSHAPE_CHECK=1 lua tests/run.lua

# Mock-LLM example: drives swarm_aggregate_plugin.run_dmad through a
# deterministic in-process mock alc.llm. Verifies the dispatcher chain
# end-to-end without any external dependency. No API key required.
smoke:
    lua examples/swarm_aggregate_dmad.lua

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

# Cleanup Lua build artifacts.
clean:
    rm -rf .luarocks/ *.rock *.src.rock *.o *.so

# Regenerate hub_index.json from packages/ for Hub source consumption
# (BUNDLED_SOURCES / AUTO_INSTALL_SOURCES on the algocline side).
dist:
    @echo "Use the algocline MCP tool: alc_hub_dist source_dir=./packages output_path=./hub_index.json"
    @echo "(direct CLI invocation is not yet exposed; reindex result lands at ./hub_index.json)"

# Run spec/ tests via the algocline MCP tool (alc_pkg_test).
# alc is an MCP server binary, not a CLI — this recipe only documents
# the MCP invocation. Run the actual tests by invoking the MCP tool from
# a Claude Code / agent session.
test-spec:
    @echo "Use the algocline MCP tool: alc_pkg_test pkg=swarm_frame"
    @echo "                            alc_pkg_test pkg=swarm_frame_algocline"
    @echo "                            alc_pkg_test pkg=swarm_aggregate_plugin"
