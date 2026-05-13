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
