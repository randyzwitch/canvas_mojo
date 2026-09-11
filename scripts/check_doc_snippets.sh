#!/usr/bin/env bash
# Execute complete Mojo programs directly from the hand-written Markdown.
# Each block gets its own working directory so output files cannot collide.
set -euo pipefail

repo_root="$(pwd)"
scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/canvas-docs.XXXXXX")"
trap 'rm -rf "$scratch_dir"' EXIT
count=0

while IFS= read -r page; do
    mkdir -p "$scratch_dir/blocks"
    awk -v target="$scratch_dir/blocks" '
        /^```mojo[[:space:]]*$/ { active = 1; block++; start = NR; code = ""; complete = 0; next }
        active && /^```[[:space:]]*$/ {
            if (complete) {
                path = target "/" start ".mojo"
                printf "%s", code > path
                close(path)
            }
            active = 0
            next
        }
        active {
            code = code $0 "\n"
            if ($0 ~ /^(def|fn) main\(/) complete = 1
        }
        END { if (active) exit 1 }
    ' "$page"
    for snippet in "$scratch_dir"/blocks/*.mojo; do
        [ -f "$snippet" ] || continue
        line="$(basename "$snippet" .mojo)"
        printf 'Checking %s:%s\n' "$page" "$line"
        mkdir -p "$scratch_dir/run"
        (cd "$scratch_dir/run" && mojo run -I "$repo_root" "$snippet")
        # The walkthrough image is produced by the exact code the reader sees.
        if [ "$page" = "docs/src/getting-started/_index.md" ] && [ -f "$scratch_dir/run/first_drawing.png" ]; then
            mkdir -p docs/site/static/guide-figures
            cp "$scratch_dir/run/first_drawing.png" docs/site/static/guide-figures/
        fi
        rm -rf "$scratch_dir/run"
        count=$((count + 1))
    done
    rm -rf "$scratch_dir/blocks"
done < <(printf '%s\n' README.md; find docs/src -name '*.md' ! -path 'docs/src/examples/*' | sort)

if [ "$count" -eq 0 ]; then
    printf 'No complete documentation programs found.\n' >&2
    exit 1
fi
printf 'Checked %s complete documentation programs; fragments are not executed.\n' "$count"
