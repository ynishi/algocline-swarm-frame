# algocline-swarm-frame — task runner
#
# Usage:
#   just              -> list recipes
#   just test         -> run all Lua tests
#   just check        -> lshape schema self-check on swarm_frame contracts

default:
    @just --list

test:
    lua tests/run.lua

check:
    LSHAPE_CHECK=1 lua tests/run.lua

clean:
    rm -rf .luarocks/ *.rock *.src.rock *.o *.so

# Regenerate hub_index.json from packages/ for Hub source consumption
# (BUNDLED_SOURCES / AUTO_INSTALL_SOURCES on the algocline side).
dist:
    @echo "Use the algocline MCP tool: alc_hub_dist source_dir=./packages output_path=./hub_index.json"
    @echo "(direct CLI invocation is not yet exposed; reindex result lands at ./hub_index.json)"
