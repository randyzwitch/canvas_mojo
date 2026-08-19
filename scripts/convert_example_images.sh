#!/usr/bin/env bash
# Converts every examples/out_*.bmp into a real, DEFLATE-compressed PNG
# in docs/src/examples/ -- see pixi.toml's own imagemagick dependency
# comment for why: canvas_mojo.io.png's own write_png is deliberately
# uncompressed (a correct tradeoff for the library itself, wrong for a
# deployed docs site serving dozens of these per page -- a raw BMP at
# this resolution runs into the megabytes per image; the converted PNG
# is typically 30-500x smaller, confirmed directly across several
# examples, not assumed). Only the .bmp is converted, even for
# png_output.mojo (the one example that also writes its own
# canvas_mojo-encoded .png) -- that file's own .png is a demo of this
# package's own write_png/read_png round trip, not a docs-display
# asset. Uniform conversion from one always-present source (every
# example writes a .bmp) keeps this script's own logic simple -- no
# separate "does this example already have a .png" branch.
set -euo pipefail

for bmp in examples/out_*.bmp; do
    name="$(basename "$bmp" .bmp)"
    magick "$bmp" "docs/src/examples/${name}.png"
done
