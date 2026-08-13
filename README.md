# canvas_mojo

A from-scratch, stdlib-only Mojo raster/drawing engine — pixel buffer,
colors, primitives (lines, shapes, curves, gradients), text, and image
I/O. No chart or data-visualization concepts; see
[`dataviz_mojo`](https://github.com/randyzwitch/dataviz_mojo) for a
grammar-of-graphics-flavored charting library built entirely on this
package's public API.

Split out of a combined `graphics` workspace on 2026-08-13 into its own
standalone repo — see `canvas_mojo/ROADMAP.md` for the full history and
design rationale of everything in this package.

## Status

Stdlib-only except one deliberate exception: `third_party/cairo_mojo`
(vendored, MIT-licensed), used only by `canvas_mojo/text.mojo` for real
system-font text rendering via the system's `libcairo` — see that
directory's own `VENDORED.md` for provenance and why it's vendored
instead of a normal pixi dependency.

This package is **not yet installable via `pixi build`/`pixi install`**
— see `pixi.toml`'s own `[package]` section and `canvas_mojo/ROADMAP.md`
for why (a real, confirmed bug in the `pixi-build-mojo` backend against
current Mojo, external to this repo). For now, consume this package by
cloning it and importing via Mojo's `-I` search-path flag, the same way
it's developed here.

## Development

```sh
pixi run test      # canvas_mojo/tests/*.mojo
pixi run example    # canvas_mojo/examples/*.mojo, writes canvas_mojo/examples/out_*.{bmp,png}
```

Tests use the stdlib's `TestSuite`:

```mojo
from std.testing import assert_equal, TestSuite

def test_something() raises:
    assert_equal(1 + 1, 2)

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
```

`mojo test` was removed upstream (Oct 2025); run a test file directly
with `mojo run`, or `pixi run test` to run the whole suite. Any function
named `test_*` in a file is discovered and run automatically — no
registration needed.

Everything imports with `-I .` except `canvas_mojo/text.mojo` and
anything that imports it directly or transitively
(`canvas_mojo/examples/text.mojo`, `canvas_mojo/tests/test_text.mojo`,
or anything importing `canvas_mojo/__init__.mojo` directly, since it
re-exports text functions too) — those also need
`-I third_party/cairo_mojo`. `pixi.toml`'s own `test`/`example` tasks
already pass both flags where needed.

## License

MIT — see `LICENSE`.
