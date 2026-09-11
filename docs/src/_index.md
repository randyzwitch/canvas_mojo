---
title: canvas_mojo
type: docs
weight: 100
---

![A bar chart, pie wedge, donut segment, scatter plot with an error ellipse, and a filled area shape, all drawn by canvas_mojo](examples/out_vector.svg)

canvas_mojo is a native Mojo 2D drawing library for raster images, SVG,
and PDF. It provides shapes, paths, gradients, compositing, transforms,
clipping, image decoding, and system-font text without C rendering
dependencies.

Use `Canvas` for pixels, `SvgCanvas` for SVG markup, or `PdfCanvas` for
paged PDF output. All three implement `DrawTarget`, so one drawing
routine can target every backend.

## Quickstart

Add the package to your existing project's `pixi.toml`. For a complete
configuration, start with [Getting Started](getting-started/).

```toml
[workspace]
preview = ["pixi-build"]

[dependencies]
canvas_mojo = { git = "https://github.com/randyzwitch/canvas_mojo.git", branch = "main" }
```

Then create a canvas, draw, and write an image:

```mojo
from canvas import Canvas, Color, fill_circle_aa, write_png


def main() raises:
    var canvas = Canvas(200, 200, Color(255, 255, 255))
    fill_circle_aa(canvas, 100, 100, 80, Color(40, 100, 200))
    write_png(canvas, "circle.png")
```

Coordinates start at the top-left, with x increasing right and y
increasing down. Functions ending in `_aa` draw anti-aliased shapes;
prefer them for normal rendered output.

## What it includes

- Lines, rectangles, circles, ellipses, arcs, polygons, and Bezier paths
- Linear, radial, and conic gradients, plus raster patterns
- Transforms, clipping, masks, blend modes, blur, and shadows
- Text using installed TrueType and OpenType fonts
- PNG and BMP reading and writing, plus baseline and progressive JPEG reading
- Raster `Canvas`, `SvgCanvas`, and multipage `PdfCanvas` backends

## Where to go next

- **[Getting Started](getting-started/)** walks from installation to PNG, SVG, and PDF output.
- **[Guides](guides/)** explains coordinates, shapes, state, transforms, and text.
- **[Examples](examples/)** shows complete programs beside their rendered output.
- **[API reference](api-guide/)** groups the public package by task and links to generated symbol documentation.
- **[Full package reference](canvas/)** contains every generated module and signature.
- **[Architecture](https://github.com/randyzwitch/canvas_mojo/wiki/Architecture)** explains the rendering pipeline for contributors.

The project is under active development. See the
[Changelog](https://github.com/randyzwitch/canvas_mojo/wiki/Changelog),
[Backlog](https://github.com/randyzwitch/canvas_mojo/wiki/Backlog), and
[GitHub repository](https://github.com/randyzwitch/canvas_mojo) for
release and contribution details.

## Development

```sh
pixi run test      # run the test suite
pixi run example   # render the examples
pixi run docs      # rebuild the documentation site
```

## License

MIT — see [LICENSE](https://github.com/randyzwitch/canvas_mojo/blob/main/LICENSE).
