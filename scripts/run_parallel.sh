#!/usr/bin/env bash
# Runs `mojo run -I . <file>` for every .mojo file given as an
# argument, in parallel, capped at the machine's CPU count.
#
# getconf, not the GNU-only `nproc`: this repo targets linux-64 and
# osx-arm64 and getconf is POSIX. xargs -P, not GNU parallel: nothing
# new to install. Capping at the real core count is what makes this a
# speedup rather than resource contention on a 2-4 core CI runner.
#
# Each file's output is captured and printed as one block after it
# finishes, since unbuffered output from concurrent `mojo run`
# processes interleaves unreadably. Blocks may print out of order.
#
# Exit status is nonzero if any file failed, so `pixi run test` fails
# the CI job rather than reporting the last-finished job's status.
set -euo pipefail

CORES="$(getconf _NPROCESSORS_ONLN)"

printf '%s\n' "$@" | xargs -P "$CORES" -I {} bash -c '
    out="$(mojo run -I . "$1" 2>&1)"
    code=$?
    printf "%s\n" "$out"
    exit "$code"
' _ {}
