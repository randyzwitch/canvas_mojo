#!/usr/bin/env bash
# Bump this directory's vendored cairo-mojo snapshot to a chosen upstream
# commit. Deliberate only -- this never runs automatically (no CI hook, no
# `pixi run` task) and never tracks a moving branch; you always pass an
# explicit commit-ish. See VENDORED.md for why this is vendored at all
# instead of a real pixi dependency, and for what "vendored" excludes.
#
# Usage:
#   third_party/cairo_mojo/update_vendor.sh <commit-ish>   # e.g. a full SHA,
#                                                            # or a branch/tag
#
# What it does:
#   1. Clones https://github.com/MoSafi2/cairo-mojo at the given commit-ish
#      into a scratch directory.
#   2. Replaces this directory's cairo_mojo/ and LICENSE with that commit's
#      versions -- nothing else (their examples/, test/, third_party/cairo/
#      headers, and pixi.toml/build recipe stay excluded, same as today).
#   3. Rewrites VENDORED.md's "Commit" line to the resolved full SHA and
#      today's date.
#
# What it does NOT do: run tests, commit, or push. Run `pixi run test`
# yourself afterward and inspect the diff before committing -- a bump is a
# real code change, not a formality.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <commit-ish>" >&2
  exit 1
fi

readonly commit_ish="$1"
readonly upstream_url="https://github.com/MoSafi2/cairo-mojo.git"
readonly vendor_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly scratch_dir="$(mktemp -d)"
trap 'rm -rf "$scratch_dir"' EXIT

echo "Cloning $upstream_url @ $commit_ish ..." >&2
git clone --quiet "$upstream_url" "$scratch_dir"
git -C "$scratch_dir" checkout --quiet "$commit_ish"
readonly resolved_sha="$(git -C "$scratch_dir" rev-parse HEAD)"

for required in cairo_mojo LICENSE; do
  if [[ ! -e "$scratch_dir/$required" ]]; then
    echo "error: upstream commit $resolved_sha has no $required -- refusing to vendor" >&2
    exit 1
  fi
done

echo "Replacing vendored cairo_mojo/ and LICENSE with $resolved_sha ..." >&2
rm -rf "$vendor_dir/cairo_mojo"
cp -R "$scratch_dir/cairo_mojo" "$vendor_dir/cairo_mojo"
cp "$scratch_dir/LICENSE" "$vendor_dir/LICENSE"

readonly today="$(date +%Y-%m-%d)"
sed -i.bak -E \
  "s#\*\*Commit\*\*: \`[0-9a-f]+\` \([0-9-]+\)#**Commit**: \`$resolved_sha\` ($today)#" \
  "$vendor_dir/VENDORED.md"
rm -f "$vendor_dir/VENDORED.md.bak"

cat >&2 <<EOF

Done -- vendored copy now matches $resolved_sha ($today).
Next steps (not automated on purpose):
  1. Review the diff: git -C "$vendor_dir" status / git diff
  2. Run the test suite: pixi run test
  3. Commit only if both look right.
EOF
