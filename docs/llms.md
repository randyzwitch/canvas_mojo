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
- `BoundsTarget(width, height)` is a fourth conformer that draws
  nothing and keeps the union of what it was asked to draw: render a
  scene into one, read `ink_pixels()` as `(x, y, width, height)`, then
  render again into a target of that size with `translate(-x, -y)`.
  That is a tight crop on every backend. `has_ink()` tells an empty
  scene from a box at the origin; `ink_bounds()` is the geometric box.
  Measure without the scene's background fill: a full-page background
  counts as ink, which makes the box the whole page and the crop a
  no-op. Paint it into the cropped target instead.
- Free drawing functions take their target first. `Canvas` also exposes
  the core operations as methods.
- `begin_batch()` / `end_batch()` on any target defer the anti-aliased
  shapes between them and draw them in one parallel pass, in order,
  with the same pixels; the vector backends treat both as no-ops. Wrap
  a loop of markers, gridlines or bars in one.
- `draw_image(image, x, y, width, height)` on any target places a
  `Canvas` as a block of hard-edged cells in user space, where a
  `fill_rect` at the same box would land: a heatmap or image plot is
  one `<image>` in SVG and one XObject in PDF rather than a rectangle
  per cell.

## Coordinate and color conventions

- The origin is at the top-left. X increases right and y increases down.
- Pixel `(x, y)` is centered at `(x, y)` and spans half a pixel on each side.
- `Int` rectangle overloads identify covered pixels. `Float64` rectangle
  overloads describe geometric edges and snap them to pixel boundaries.
- `round_to_int` is the package's rounding (halves away from zero).
  `snap_to_pixel_edge` moves a coordinate to the nearest pixel boundary,
  for a filled rectangle's edge; `snap_to_pixel_center` to the nearest
  pixel center, for a hairline. Snap in user space before a supersampled
  region so the edge stays hard after the downsample.
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
`rect`, `round_rect`, `ellipse` and `regular_polygon` add a whole closed
shape as one subpath. `curve_through` adds a smooth open subpath through
points with Catmull-Rom tangents; `curve_to_through` continues the current
subpath with the same curve, for a closed band with two smoothed edges.
`arrow_head` adds a closed arrowhead pointing along a direction; stroke the
shaft to the tip so the head covers the join. `transformed` maps a whole
path into a new one; `extend` appends another path's commands, adopting its
current point, so a shape built at unit size and mapped into place joins a
larger path as its own subpath -- sharing one fill with the rest under
`FillRule.NONZERO` instead of seaming against it.

Use `fill_path_aa` for its interior or `stroke_path_aa` for its outline.
`FillRule.EVEN_ODD` is the default; use `FillRule.NONZERO` when winding
direction should determine the interior.

## Text

`draw_text` anchors text at its baseline. `TextAlign.LEFT`, `CENTER`, and
`RIGHT` control horizontal placement around the anchor. Fonts are resolved
from those installed on the system, with fallback for missing glyphs.
It is on `DrawTarget` as a method with a `cache=` keyword, so a function
generic over the trait can label what it draws on all three backends.

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

- `push_clip(x, y, width, height)` / `pop_clip()` on any target
  restrict drawing to a rectangle and undo that, intersecting with any
  clip already active. Wrap a chart's marks in one so they cannot
  paint over the axes.

- `draw_text(x, y, text, color, size, ..., cache=cache)` on any target
  draws a label at a sub-pixel baseline anchor with the same alignment
  and rotation on every backend; `family` takes the raster names, and
  SVG maps the generic ones to CSS.

Gradient path fills, outlined text and text on a path are backend
methods rather than part of `DrawTarget`. Use the relevant backend
method when a shared trait operation is unavailable.
