#!/usr/bin/env bash
# Keep the explicit longest-job-first order, but reject an incomplete
# task list before compiling anything. CI must cover every test module.
set -euo pipefail

CHECK_ONLY=0
if [[ "${1:-}" == "--check" ]]; then
    CHECK_ONLY=1
    shift
fi

for test_file in tests/test_*.mojo; do
    registered=0
    for argument in "$@"; do
        if [[ "$argument" == "$test_file" ]]; then
            registered=1
            break
        fi
    done
    if [[ "$registered" == 0 ]]; then
        printf 'Test missing from pixi.toml test task: %s\n' "$test_file" >&2
        exit 1
    fi
done

for argument in "$@"; do
    if [[ ! -f "$argument" ]]; then
        printf 'Test task references a missing file: %s\n' "$argument" >&2
        exit 1
    fi
done

if [[ "$CHECK_ONLY" == 0 ]]; then
    exec bash scripts/run_parallel.sh "$@"
fi
