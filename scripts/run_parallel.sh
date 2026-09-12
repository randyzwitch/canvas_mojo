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
# What this covers, since the limit lives here rather than in a task:
# `pixi run test` and `pixi run example` both fan out through this
# script, so both are guarded. That the examples are covered is luck
# rather than design -- the reason for the limit was a hung test
# module, and the examples came along because they share the runner.
# Worth knowing because a consumer's hang appeared in a generated
# docs example rather than a test. NOT covered: the bare `mojo run`
# calls in `docs-build` and `docs-figures`, which invoke the doc and
# figure generators directly. Those run one at a time, which is not
# the same as being safe: the deadlock behind this limit is
# intra-process, and the runtime sizes its thread pool to the core
# count inside every process, so a lone invocation still has ~65
# threads that can park on each other. Nobody has observed a serial
# invocation wedge; the point is only that running alone does not
# rule it out. A guard there would be a different shape from a
# limit inside a fan-out, which is why it is not in this change.
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
# `timeout` is GNU coreutils and a stock macOS has neither it nor
# `gtimeout`, so macOS ran every file unguarded until #422 -- which
# nobody could see until the line below started naming the guard.
# The third choice is perl, which macOS does ship, so the guard needs
# no dependency and no CI install step. Two defects in the obvious
# version of it were found by testing rather than by reading, and
# both are described where the program is defined below: a missing
# interpreter exiting 0, and a wedged module's children surviving the
# kill.
#
# All three forms exit 124 on a timeout and kill the wedged module's
# whole process group, so nothing downstream has to know which fired.
set -euo pipefail

CORES="$(getconf _NPROCESSORS_ONLN)"
LIMIT="${CANVAS_TEST_TIMEOUT:-3600}"

# A timeout in the perl every macOS ships. The one-line version of
# this -- set an alarm, exec, let SIGALRM terminate the process -- is
# wrong in a way that took a test to see: it kills the process and
# not its children, so a module that forks leaves the pipe open and
# the run blocks for the module's full duration while reporting a
# timeout. Measured against `timeout` on the same wedged stub: 3 s
# for `timeout`, 60 s for the one-liner. `timeout` puts the child in
# its own process group and kills the group, so this does too, which
# needs a parent that outlives the alarm and therefore a fork rather
# than an exec.
ALARM='
    my $limit = shift @ARGV;
    my $pid = fork();
    exit 127 unless defined $pid;
    if ($pid == 0) { setpgrp(0, 0); exec @ARGV; exit 127; }
    my $fired = 0;
    $SIG{ALRM} = sub { $fired = 1; kill "KILL", -$pid; };
    alarm $limit;
    waitpid $pid, 0;
    my $status = $?;
    alarm 0;
    exit 124 if $fired;
    exit 128 + ($status & 127) if ($status & 127);
    exit $status >> 8;
'

MODE="none"
if command -v timeout >/dev/null 2>&1; then
    MODE="timeout"
    printf 'run_parallel: each file limited to %s s by timeout\n' "$LIMIT" >&2
elif command -v gtimeout >/dev/null 2>&1; then
    MODE="gtimeout"
    printf 'run_parallel: each file limited to %s s by gtimeout\n' "$LIMIT" >&2
elif command -v perl >/dev/null 2>&1; then
    MODE="perl"
    printf 'run_parallel: each file limited to %s s by perl alarm\n' "$LIMIT" >&2
else
    # Say so rather than fall through quietly. A guard that is not
    # running looks exactly like a guard that is: the tell is a run
    # that never ends, which is the thing the guard exists to prevent
    # and the thing nobody watches for. A consumer of this package
    # shipped the same fallback and found their macOS workers exiting
    # 127 -- the opposite failure, loud instead of silent, and they
    # found it in minutes because of that.
    printf 'run_parallel: no timeout, gtimeout or perl, files run unguarded\n' >&2
fi

printf '%s\n' "$@" | xargs -P "$CORES" -I {} bash -c '
    case "$2" in
        timeout)  out="$(timeout "$3" mojo run -I . "$1" 2>&1)"; code=$? ;;
        gtimeout) out="$(gtimeout "$3" mojo run -I . "$1" 2>&1)"; code=$? ;;
        perl)     out="$(perl -e "$4" "$3" mojo run -I . "$1" 2>&1)"; code=$? ;;
        *)        out="$(mojo run -I . "$1" 2>&1)"; code=$? ;;
    esac
    printf "%s\n" "$out"
    if [ "$code" = "124" ]; then
        printf "TIMEOUT after %s s: %s\n" "$3" "$1"
    fi
    exit "$code"
' _ {} "$MODE" "$LIMIT" "$ALARM"
