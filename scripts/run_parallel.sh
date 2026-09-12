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
#
# Each file also gets a wall-clock limit, because the failure this
# guards is not a slow test but a hung one. A consumer of this package
# watched a `mojo run` sit for 27 minutes at zero CPU with every
# thread parked on a futex, and a deadlocked module produces no exit
# code at all: the suite stops, nothing fails, and there is nothing to
# read.
#
# The limit sits far above the slowest honest module rather than
# anywhere near the hang, because the two errors do not cost the same.
# A deadlocked module never finishes, so any finite limit catches it
# and a generous one only delays the report. A limit that fires on
# honest work produces a false failure, and a gate that fails at
# random stops being read. So the number is chosen against the slowest
# real module, with room over it.
#
# The limit that matters in CI is probably a different number: there
# this runs on a two-to-four core runner, so fifty files go through at
# width two to four and each module gets most of a core, which is not
# the regime the figures below describe. Unmeasured as well.
#
# Measured here, warm, with fifty modules sharing this machine:
# tests/test_lines.mojo takes 1855, 1898 and 2102 s across three runs.
# Nobody had looked before, because the suite exits zero and only the
# total gets read. What is NOT measured is a cold run under full
# parallel load, which is plausibly the real worst case; the hour
# leaves room for it rather than being known to fit. Raise
# CANVAS_TEST_TIMEOUT if a real module ever trips it -- that is a
# false failure, not a finding.
#
# `timeout` is GNU coreutils and absent on a stock macOS, so it is
# used when present and skipped when not: the guard is best-effort
# rather than a portability regression.
set -euo pipefail

CORES="$(getconf _NPROCESSORS_ONLN)"
LIMIT="${CANVAS_TEST_TIMEOUT:-3600}"

RUNNER=""
if command -v timeout >/dev/null 2>&1; then
    RUNNER="timeout ${LIMIT}"
elif command -v gtimeout >/dev/null 2>&1; then
    RUNNER="gtimeout ${LIMIT}"
fi

printf '%s\n' "$@" | xargs -P "$CORES" -I {} bash -c '
    out="$($2 mojo run -I . "$1" 2>&1)"
    code=$?
    printf "%s\n" "$out"
    if [ "$code" = "124" ]; then
        printf "TIMEOUT after %s s: %s\n" "$3" "$1"
    fi
    exit "$code"
' _ {} "$RUNNER" "$LIMIT"
