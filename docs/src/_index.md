---
title: canvas_mojo
type: docs
weight: 100
---

A Mojo raster/drawing engine — pixel buffer, colors, primitives
(lines, shapes, curves, gradients), text, and image I/O.

Please note that this is heavily Claude-influenced, so I do not
guarantee consistency, logic, mapping to Cairo concepts, or design
decisions matching any particular reference library. If you know what
you're doing and want to contribute, let's chat!

**Start here:** [Examples](examples/) shows every primitive this
package can draw, source code next to its actual rendered output. For
the full API surface (every function `canvas_mojo` exposes, across
buffer/color/primitives/path/gradient/text/io), see the [`canvas_mojo`
package reference](canvas_mojo/). For what's built vs. still open and
why, see the [wiki](https://github.com/randyzwitch/canvas_mojo/wiki)
([Changelog](https://github.com/randyzwitch/canvas_mojo/wiki/Changelog)
/ [Backlog](https://github.com/randyzwitch/canvas_mojo/wiki/Backlog)).

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

## Install

```toml
[workspace]
preview = ["pixi-build"]  # git-source pixi dependencies are still a preview feature

[dependencies]
canvas_mojo = { git = "https://github.com/randyzwitch/canvas_mojo.git", branch = "main" }
```

`pixi install`/`pixi run` builds `canvas_mojo` from that git ref and
installs the resulting precompiled package into your own workspace's
pixi environment — Mojo's own toolchain finds it there automatically,
no `-I` flag needed.

## A first drawing

```mojo
from canvas_mojo import Canvas, Color, fill_circle_aa
from canvas_mojo.io.bmp import write_bmp

def main() raises:
    var c = Canvas(200, 200, Color(255, 255, 255))
    fill_circle_aa(c, 100, 100, 80, Color(40, 100, 200))
    write_bmp(c, "out.bmp")
```

See [Examples](examples/) for the same pattern applied to lines,
shapes, curves, gradients, dashes, transforms, clipping, text, and
PNG/BMP image I/O.

## Development

```sh
pixi run test      # tests/*.mojo
pixi run example   # examples/*.mojo, writes examples/out_*.{bmp,png}
pixi run docs      # regenerates this site -- run `example` first
```

## License

MIT — see [`LICENSE`](https://github.com/randyzwitch/canvas_mojo/blob/main/LICENSE).
