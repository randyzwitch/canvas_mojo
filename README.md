# canvas_mojo

A Mojo raster/drawing engine — pixel buffer, colors, primitives (lines, shapes, curves, gradients), text, and image I/O.

## Why?

Scratching the itch of "What would it take to not use Cairo or other existing libraries as base for data visualization"! 

Please note that this is heavily Claude-influenced, so I do not guarantee consistency, logic, mapping to Cairo concepts or anything else. If you know what you're doing and what to contribute, let's chat! 

**[Docs & examples](https://randyzwitch.com/canvas_mojo/)** --
every example's source next to its actual rendered output, plus the
full `canvas_mojo` API reference (generated from this repo's own
docstrings via [modo](https://github.com/mlange-42/modo), see
`docs/modo.yaml`/`pixi run docs`).

See the [wiki](https://github.com/randyzwitch/canvas_mojo/wiki) for
exactly what's built ([Changelog](https://github.com/randyzwitch/canvas_mojo/wiki/Changelog))
vs. still open ([Backlog](https://github.com/randyzwitch/canvas_mojo/wiki/Backlog)).

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

## Status

Mojo-only, plus one small direct FFI dependency on a system
library `canvas_mojo/text/render.mojo` links against for real
system-font text rendering: `libfontconfig` (font matching —
resolving a family/style name to an actual installed font file --
`canvas_mojo/text/font_discovery.mojo`), a typical,
near-universally-installed system library, not a new requirement
this package introduces. Font *parsing* (glyph outlines, metrics,
`canvas_mojo/text/ttf.mojo`) and rasterization (this package's own
`fill_path_aa`) are both native Mojo -- no FreeType, no Cairo, no
other third-party rendering/font engine anywhere in the pipeline.

## Development

```sh
pixi run test      # tests/*.mojo
pixi run example   # examples/*.mojo, writes examples/out_*.{bmp,png}
pixi run docs      # regenerates docs/ (served via GitHub Pages) -- run `example` first
```

`docs/` also rebuilds and deploys automatically
(`.github/workflows/docs-deploy.yml`) on every push to `main` that
touches `canvas_mojo/`, `examples/`, or `docs/` -- manual `pixi run
docs`/`pixi run docs-serve` are for previewing locally before you
push, not required to keep the site in sync. A pull request runs the
same build (`.github/workflows/docs.yml`) as a status check, without
deploying.

## License

MIT — see `LICENSE`.
