# canvas_mojo

> A native Mojo 2D drawing library for raster images, SVG, and PDF.
> It includes shapes, paths, gradients, compositing, transforms,
> clipping, system-font text, and image codecs without C rendering
> dependencies.

The importable package is `canvas`; the project is `canvas_mojo`.
`Canvas`, `SvgCanvas`, and `PdfCanvas` implement the `DrawTarget` trait.
The generated public API inventory follows this hand-written guide in
`llms.txt`.

Documentation: https://randyzwitch.com/canvas_mojo/
Examples: https://randyzwitch.com/canvas_mojo/examples/

## Install

```toml
[workspace]
preview = ["pixi-build"]

[dependencies]
canvas_mojo = { git = "https://github.com/randyzwitch/canvas_mojo.git", branch = "main" }
```

Import common entry points from the package root:

```mojo
from canvas import Canvas, Color, Path, fill_circle_aa, write_png
```

## Core model

- `Canvas(width, height, fill)` owns an RGBA pixel buffer.
- `SvgCanvas(width, height)` accumulates SVG markup.
- `PdfCanvas(width, height)` creates a PDF document; `new_page` adds pages.
- A function generic over `DrawTarget` can issue the shared drawing
  operations to any backend.
- Free drawing functions take their target first. `Canvas` also exposes
  the core operations as methods.

## Coordinate and color conventions

- The origin is at the top-left. X increases right and y increases down.
- Pixel `(x, y)` is centered at `(x, y)` and spans half a pixel on each side.
- `Int` rectangle overloads identify covered pixels. `Float64` rectangle
  overloads describe geometric edges and snap them to pixel boundaries.
- Angles are radians and clockwise-positive in the y-down coordinate system.
- Functions ending in `_aa` are anti-aliased. Plain variants are hard-edged.
- `Color(r, g, b, a=255)` uses 8-bit straight alpha.
- Drawing uses source-over by default. Set a `BlendMode` or `ColorSpace` on
  the target when another behavior is required.
- Every primitive respects the current transform and clip. Use `save` and
  `restore` to scope state changes.

## Paths

Build a `Path` from `move_to`, `line_to`, `quad_curve_to`,
`cubic_curve_to`, `arc_to`, and `close`. Every subpath begins with
`move_to`, including one whose first segment is an arc.

Use `fill_path_aa` for its interior or `stroke_path_aa` for its outline.
`FillRule.EVEN_ODD` is the default; use `FillRule.NONZERO` when winding
direction should determine the interior.

## Text

`draw_text` anchors text at its baseline. `TextAlign.LEFT`, `CENTER`, and
`RIGHT` control horizontal placement around the anchor. Fonts are resolved
from those installed on the system, with fallback for missing glyphs.

Create one `FontCache` and pass it through the `cache=` overloads when
performing related text operations. Construction does not scan the system;
font discovery is initialized on the first lookup.

- `measure_text` treats text as one line and returns `TextMetrics`, including
  width, height, and advance.
- `measure_text_block` lays out newline-separated text and returns its
  anchor-relative ink bounds.
- `prepare_text` returns a `TextLayout` for reuse with `measure_layout` and
  `draw_layout`. Draw it with the same `FontCache` that prepared it.

## Images and output

- `read_png` and `read_bmp` decode images with their alpha where supported.
- `read_jpeg` decodes baseline and progressive JPEG into an opaque `Canvas`.
- `write_png` and `write_bmp` write raster output.
- `write_svg` writes an `SvgCanvas`; `write_pdf` writes a `PdfCanvas`.
- `PngLevel.FAST`, `DEFAULT`, and `SMALL` select encoding effort. They do
  not change decoded pixels.
- `draw_canvas` composites one canvas onto another and can apply opacity,
  a mask, a transform, and nearest or bilinear filtering.
- `downsample` reduces by an integer factor. `resize` accepts any positive
  output dimensions and uses alpha-aware filtering.

## Minimal raster example

```mojo
from canvas import Canvas, Color, fill_circle_aa, write_png


def main() raises:
    var canvas = Canvas(200, 200, Color(255, 255, 255))
    fill_circle_aa(canvas, 100, 100, 80, Color(40, 100, 200))
    write_png(canvas, "circle.png")
```

## One scene, three backends

```mojo
from canvas import Canvas, Color, PdfCanvas, SvgCanvas, write_pdf, write_png, write_svg
from canvas.vector.draw_target import DrawTarget


def draw_scene[T: DrawTarget](mut target: T) raises:
    target.fill_rect(20, 20, 200, 120, Color(40, 100, 200))
    target.fill_circle_aa(400.0, 100.0, 70.0, Color(30, 160, 80))
    target.draw_line_aa(20.0, 200.0, 760.0, 220.0, Color(0, 0, 0), 4.0)


def main() raises:
    var raster = Canvas(800, 300, Color(255, 255, 255))
    draw_scene(raster)
    write_png(raster, "scene.png")

    var svg = SvgCanvas(800, 300)
    draw_scene(svg)
    write_svg(svg, "scene.svg")

    var pdf = PdfCanvas(800, 300)
    pdf.fill_rect(0, 0, 800, 300, Color(255, 255, 255))
    draw_scene(pdf)
    write_pdf(pdf, "scene.pdf")
```

Text, clipping, image placement, and some paint operations are
backend-specific rather than part of `DrawTarget`. Use the relevant
backend method when a shared trait operation is unavailable.
