---
title: canvas_mojo
type: docs
weight: 100
---

![A bar chart, pie wedge, donut segment, scatter plot with an error ellipse, and a filled area shape, all drawn by canvas_mojo itself](examples/out_vector.svg)

A 2D drawing engine written entirely in Mojo: pixel buffers, shape and
path primitives, gradients, real system-font text, and PNG/BMP/SVG
output — no Cairo, no FreeType, no other C rendering library anywhere
in the pipeline.

## Why canvas_mojo?

Drawing shapes and text to an image is usually a job you hand to a C
library — Cairo, Skia, FreeType — from whatever language you're
actually working in. canvas_mojo asks what that same job looks like
kept entirely in Mojo instead: one language, top to bottom, so the
whole rasterizer is readable and hackable rather than a thin wrapper
around someone else's binary. `Canvas` (raster) and `SvgCanvas`
(vector) both implement the same `DrawTarget` trait, so code written
against that trait — a chart library's own rendering core, say — works
against either backend without knowing which one it's drawing into.

This is an early-stage, heavily Claude-influenced personal project, so
don't expect polish or a clean mapping onto Cairo's concepts. If you
know what you're doing and want to contribute, let's chat.

## Quickstart

Add `canvas_mojo` as a git dependency in your own `pixi.toml`:

```toml
[workspace]
preview = ["pixi-build"]  # git-source pixi dependencies are still a preview feature

[dependencies]
canvas_mojo = { git = "https://github.com/randyzwitch/canvas_mojo.git", branch = "main" }
```

`pixi install`/`pixi run` builds `canvas_mojo` from that git ref and
installs the resulting precompiled package into your own workspace's
pixi environment — Mojo's own toolchain finds it there automatically,
no `-I` flag needed. Then draw something:

```mojo
from canvas_mojo import Canvas, Color, fill_circle_aa
from canvas_mojo.io.bmp import write_bmp

def main() raises:
    var c = Canvas(200, 200, Color(255, 255, 255))
    fill_circle_aa(c, 100, 100, 80, Color(40, 100, 200))
    write_bmp(c, "out.bmp")
```

That's a filled, anti-aliased circle on a white background, written
out as a real BMP file.

## Where to next

- **[Examples](examples/)** — the same pattern applied to lines,
  shapes, curves, gradients, dashes, transforms, clipping, text, and
  PNG/BMP image I/O, source next to its actual rendered output.
- **[API reference](api-guide/)** — the package grouped by what you're
  trying to do (canvas & color, shapes, paths, gradients, text,
  vector, image I/O), each entry linking to its full generated
  reference, straight from this repo's own docstrings.
- **[Wiki](https://github.com/randyzwitch/canvas_mojo/wiki)** — what's
  built
  ([Changelog](https://github.com/randyzwitch/canvas_mojo/wiki/Changelog))
  vs. still open
  ([Backlog](https://github.com/randyzwitch/canvas_mojo/wiki/Backlog)),
  plus an [Architecture](https://github.com/randyzwitch/canvas_mojo/wiki/Architecture)
  walkthrough of how a drawing call moves through `Canvas`/`SvgCanvas`,
  `Path`, and text rendering.

## Status

Mojo-only, plus one small direct FFI dependency on a system library
`canvas_mojo/text/render.mojo` links against for real system-font text
rendering: `libfontconfig` (font matching — resolving a family/style
name to an actual installed font file — `canvas_mojo/text/
font_discovery.mojo`), a typical, near-universally-installed system
library, not a new requirement this package introduces. Font *parsing*
(glyph outlines, metrics, `canvas_mojo/text/ttf.mojo`) and
rasterization (this package's own `fill_path_aa`) are both native
Mojo -- no FreeType, no Cairo, no other third-party rendering/font
engine anywhere in the pipeline.

## Development

```sh
pixi run test      # tests/*.mojo
pixi run example   # examples/*.mojo, writes examples/out_*.{bmp,png}
pixi run docs      # regenerates this site -- run `example` first
```

## License

MIT — see [`LICENSE`](https://github.com/randyzwitch/canvas_mojo/blob/main/LICENSE).
