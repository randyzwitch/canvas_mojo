# canvas_mojo

A Mojo raster/drawing engine — pixel buffer, colors, primitives (lines, shapes, curves, gradients), text, and image I/O.

## Why?

Scratching the itch of "What would it take to not use Cairo or other existing libraries as base for data visualization"! 

Please note that this is heavily Claude-influenced, so I do not guarantee consistency, logic, mapping to Cairo concepts or anything else. If you know what you're doing and what to contribute, let's chat! 

## Status

Stdlib-only, plus two small direct FFI dependencies on system
libraries `canvas_mojo/text/render.mojo` links against for real
system-font text rendering: `libfontconfig` (font matching —
`canvas_mojo/text/font_discovery.mojo`) and `libfreetype` (glyph
outlines/metrics/hinting — `canvas_mojo/text/freetype_face.mojo`,
`canvas_mojo/text/glyph_outline.mojo`). Both are typical,
near-universally-installed system libraries, not new requirements
this package introduces.
Rasterization is this package's own `fill_path_aa` — no third-party
rendering engine (i.e. Cairo) anywhere in the pipeline.

This package is **not yet installable via `pixi build`/`pixi install`
on a stock pixi install** — see `pixi.toml`'s own `[package]` section
and the wiki for additional information (a real, confirmed bug in the
published `pixi-build-mojo` backend against current Mojo, external to
this repo -- already root-caused and fixed, verified end-to-end
against a locally-patched build of the backend, waiting on the fix to
land upstream). For now, consume this package by cloning it and
importing via Mojo's `-I` search-path flag, the same way it's
developed here.

## Development

```sh
pixi run test      # tests/*.mojo
pixi run example    # examples/*.mojo, writes examples/out_*.{bmp,png}
```

Tests use the stdlib's `TestSuite`:

```mojo
from std.testing import assert_equal, TestSuite

def test_something() raises:
    assert_equal(1 + 1, 2)

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
```

## License

MIT — see `LICENSE`.
