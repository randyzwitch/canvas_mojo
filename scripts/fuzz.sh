#!/usr/bin/env bash
# Drive scripts/fuzz_decoders.mojo for a time box: build it once, then
# run batches in parallel workers under `timeout` and `ulimit -v` until
# the deadline, collecting every case that killed a batch (#430).
#
#   pixi run fuzz <decoder> <seed-dir-or-file> [minutes] [workers]
#
# <decoder> is png, jpeg, bmp, deflate or font. Seeds are a directory
# or one file; for fonts, a directory of symlinks to every font the
# machine has is one line:
#
#   mkdir -p .fuzz/seeds/fonts && fc-list : file | sed 's/: *$//' \
#     | grep -iE '\.(ttf|otf|ttc)$' | sort -u | while read -r f; do \
#     ln -sf "$f" ".fuzz/seeds/fonts/$(basename "$f")"; done
#
# Findings land in
# .fuzz/findings/<decoder>/ as the case file plus a .txt sidecar naming
# the seed, mutation and RNG state; the batch's exit status is in the
# file name (134 abort, 139 segfault, 124 timeout, 137 killed by the
# memory limit). Replay one with
#
#   .fuzz/fuzz_decoders one <decoder> .fuzz/findings/<decoder>/<case>
#
# and, for a symbolicated trace, rebuild with
# `-debug-level=line-tables -D CANVAS_CHECKED_READS`. The harness is
# built with checked reads (canvas/io/view.mojo) unless
# CANVAS_FUZZ_CHECKED=0, so a read past a buffer in an image codec
# aborts naming the index instead of passing silently. Not wired into CI: this needs hours on a
# quiet machine and its output is nondeterministic. Run it before a
# release the way bench-check is run; the harness stays here so the
# next release can rerun it. `.fuzz/` is ignored by git.
#
# A worker's RNG seed is its index plus the batch count times the
# worker count, so two workers never repeat each other's stream and a
# rerun with the same arguments replays the same cases.
set -euo pipefail

decoder="${1:?usage: fuzz.sh <decoder> <seeds> [minutes] [workers]}"
seeds="${2:?usage: fuzz.sh <decoder> <seeds> [minutes] [workers]}"
minutes="${3:-10}"
workers="${4:-$(( $(nproc 2>/dev/null || sysctl -n hw.ncpu) / 2 ))}"
iterations="${CANVAS_FUZZ_ITERATIONS:-500}"
batch_timeout="${CANVAS_FUZZ_BATCH_TIMEOUT:-600}"
memory_kb="${CANVAS_FUZZ_MEMORY_KB:-8000000}"
[[ "$workers" -ge 1 ]] || workers=1

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$root/.fuzz"
findings="$work/findings/$decoder"
mkdir -p "$work/cases" "$findings"

# Rebuilt when the harness or anything under canvas/ is newer than the
# binary, so a fix to a parser is what the next batch runs. Built with
# checked reads unless CANVAS_FUZZ_CHECKED=0: the image codecs read
# through raw pointers, and a read past a buffer only faults once it
# reaches an unmapped page, so without the check that whole class of
# bug passes every run (canvas/io/view.mojo).
checked="${CANVAS_FUZZ_CHECKED:-1}"
define=()
if [[ "$checked" != "0" ]]; then
    define=(-D CANVAS_CHECKED_READS)
fi
stamp="$work/fuzz_decoders.checked=$checked"
if [[ ! -x "$work/fuzz_decoders" || ! -f "$stamp" ]] || [[ -n "$(find "$root/canvas" "$root/scripts/fuzz_decoders.mojo" -newer "$work/fuzz_decoders" -print -quit)" ]]; then
    echo "fuzz: building the harness (checked reads: $checked)"
    rm -f "$work"/fuzz_decoders.checked=*
    (cd "$root" && mojo build -I . "${define[@]}" -o "$work/fuzz_decoders" scripts/fuzz_decoders.mojo)
    touch "$stamp"
fi
harness="$work/fuzz_decoders"

# GNU timeout, or the perl fallback scripts/run_parallel.sh documents.
if command -v timeout >/dev/null 2>&1; then
    limit() { timeout "$1" "${@:2}"; }
elif command -v gtimeout >/dev/null 2>&1; then
    limit() { gtimeout "$1" "${@:2}"; }
else
    limit() { perl -e 'alarm shift; exec @ARGV' "$@"; }
fi

deadline=$(( $(date +%s) + minutes * 60 ))
echo "fuzz: $decoder over $seeds for $minutes min, $workers workers, $iterations iterations per batch"

worker() {
    local index="$1" batches=0 found=0 status
    local case="$work/cases/$decoder.$index.case"
    while [[ "$(date +%s)" -lt "$deadline" ]]; do
        local rng=$(( index + batches * workers + 1 ))
        set +e
        limit "$batch_timeout" bash -c "ulimit -v $memory_kb; exec '$harness' batch '$decoder' '$seeds' '$case' '$iterations' '$rng'" \
            > "$case.log" 2>&1
        status=$?
        set -e
        if [[ "$status" -ne 0 && -f "$case" ]]; then
            found=$(( found + 1 ))
            local stamp; stamp="$(date +%Y%m%d-%H%M%S)-w$index-b$batches-exit$status"
            cp "$case" "$findings/$stamp.case"
            cp "$case.txt" "$findings/$stamp.case.txt" 2>/dev/null || true
            # The whole batch log: the abort message names the file
            # and line, and sits well above the stack dump's tail.
            cp "$case.log" "$findings/$stamp.case.log" 2>/dev/null || true
            echo "fuzz: worker $index batch $batches exit $status -> $findings/$stamp.case"
            rm -f "$case" "$case.txt"
        elif [[ "$status" -ne 0 ]]; then
            echo "fuzz: worker $index batch $batches exit $status with no case on disk (harness error?)"
            tail -n 3 "$case.log"
        fi
        batches=$(( batches + 1 ))
    done
    echo "fuzz: worker $index done, $batches batches, $found findings"
}

pids=()
for (( i = 0; i < workers; i++ )); do
    worker "$i" &
    pids+=($!)
done
for pid in "${pids[@]}"; do
    wait "$pid"
done

count=$(find "$findings" -name '*.case' | wc -l | tr -d ' ')
echo "fuzz: $count finding(s) in $findings"
