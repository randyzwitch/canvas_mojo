# canvas_mojo

> A 2D drawing engine written entirely in Mojo: raster pixels, SVG
> markup and PDF pages behind one `DrawTarget` trait; shapes, paths,
> gradients, blend modes, clipping, transforms, real system-font text;
> PNG/BMP/JPEG in, PNG/BMP/SVG/PDF out. No Cairo, FreeType, zlib or
> libjpeg anywhere.

This file is the whole public API in one page, for a model or a person
building against the library: how to install it, the conventions that
matter, working recipes, then every public function and type with its
signature and one line of purpose. The API section is generated from
the source docstrings by `scripts/gen_llms_txt.mojo`; the full
reference with every argument documented is at
https://randyzwitch.com/canvas_mojo/ and the rendered examples at
https://randyzwitch.com/canvas_mojo/examples/.

## Install

```toml
# pixi.toml of the project using it
[workspace]
preview = ["pixi-build"]

[dependencies]
canvas_mojo = { git = "https://github.com/randyzwitch/canvas_mojo.git", branch = "main" }
```

Then `from canvas import Canvas, Color, fill_circle_aa, write_png`. The
importable package is named `canvas`; the project is `canvas_mojo`.

## Conventions worth knowing before the first call

- Coordinates are pixels, x right, y down, origin top-left. Pixel
  (x, y) is the square from x - 0.5 to x + 0.5; `Float64` positions are
  pixel centers, so a circle at (100.0, 100.0) is centered on pixel
  100's center. `Int` overloads of `fill_rect` cover whole pixels;
  `Float64` overloads snap each edge to the nearest pixel boundary.
- `Color(r, g, b, a=255)` is 8-bit straight alpha. Translucent colors
  blend source-over; every primitive writes each pixel once, so a 50%
  fill never double-blends at its own seams.
- `_aa` functions are anti-aliased; the plain ones are hard-edged
  (Bresenham lines, whole-pixel fills). Use the `_aa` family for
  anything a person will look at.
- Angles are radians, clockwise-positive on the y-down canvas.
  `fill_arc_aa` sweeps from `start_angle` to `end_angle`.
- Paths: `Path()` then `move_to`, `line_to`, `quad_curve_to`,
  `cubic_curve_to`, `arc_to`, `close`; every sub-path starts with
  `move_to`, `arc_to` included; fill with `fill_path_aa` under
  `FillRule.EVEN_ODD` (default) or `NONZERO`; stroke with
  `stroke_path_aa` (width, dashes, `LineCap`, `LineJoin`).
- State on a canvas: `save`/`restore`, `translate`/`rotate`/`scale`/
  `transform`, `set_blend_mode`, `set_color_space`, `push_clip`
  (rectangle) and `push_clip_path` (any outline), all undone by
  `restore`.
- Text: `draw_text(canvas, x, y, text, color, size, family="Sans", ...)`
  anchors at the baseline; `align` is `TextAlign.LEFT/CENTER/RIGHT`.
  Fonts come from the system; `FontCache()` shared across calls avoids
  re-resolving. `measure_text` gives the ink box before drawing.
- Measuring a label and then drawing it lays it out twice. To pay
  once, `prepare_text(text, size, ..., cache=cache)` returns a
  `TextLayout` that `measure_layout(layout)` and
  `draw_layout(canvas, x, y, layout, color, cache=cache)` share --
  about 1.25x on the pair. The layout is anchor-relative, so one
  prepared layout draws at any position; it pins the string, size,
  family, slant, weight, rotation, alignment, kerning and ligature
  settings, and changing any of them needs a new one. Reuse is
  caller-managed: there is no hidden cache.
- `DrawTarget` is the trait `Canvas`, `SvgCanvas` and `PdfCanvas`
  share. Code written against it draws to any backend; text, clipping
  and gradient path fills are backend methods rather than trait
  methods, so call them once you know which backend you hold.
- `write_png(canvas, path, level)` takes a `PngLevel`: `FAST` is about
  a fifth quicker on flat content at the same bytes, `SMALL` trades
  roughly 1.7x the time for a smaller file, `DEFAULT` is the default.
  Every level decodes to the same pixels.
- `resize(canvas, width, height)` resamples to any target size --
  fractional ratios, anisotropic, one axis up while the other goes
  down. Area filtering where an axis shrinks, linear where it grows,
  color weighted by alpha throughout. `downsample(canvas, factor)`
  stays the faster path for an integer factor dividing both
  dimensions, and the two agree byte for byte there.
- `fill_circles_aa(canvas, centers, radius, color)` draws a whole
  scatter in one call, banding the canvas across cores instead of
  drawing one marker at a time -- 8.5x on 2,000 small markers and
  15x on 100,000, the ratio rising as the batch amortizes the
  dispatch. `centers` is a `List[FPoint]` in draw order; a
  `List[Color]` in place of the single color gives one color per
  marker. The result is identical to `fill_circle_aa` per center,
  overlapping translucent markers included.
- `canvas.set_max_workers(n)` caps how many threads one render's
  banded passes may use, for an application drawing several canvases
  at once. It is a per-render ceiling, not a budget across renders,
  and `save`/`restore` do not carry it. The output is identical at any
  worker count.
- `FontCache` bounds its rasterized glyphs by bytes and releases the
  older of two generations when it fills. `glyph_mask_bytes()` reports
  what it holds and `clear_glyph_masks()` releases them all, keeping
  the resolved fonts.

## Recipes

### A chart-like scene to PNG

```mojo
from canvas import Canvas, Color, write_png
from canvas.shapes.rects import fill_rect
from canvas.shapes.circles import fill_circle_aa
from canvas.shapes.lines import draw_polyline_aa
from canvas.geometry import FPoint
from canvas.text.render import draw_text

def main() raises:
    var c = Canvas(800, 500, Color(255, 255, 255))
    fill_rect(c, 60, 400, 680, 2, Color(60, 60, 60))          # axis
    var heights: List[Int] = [120, 260, 180, 300]
    for i in range(len(heights)):
        fill_rect(c, 100 + i * 160, 400 - heights[i], 100, heights[i], Color(40, 100, 200))
    var pts = List[FPoint]()
    for i in range(20):
        pts.append(FPoint(60.0 + Float64(i) * 36.0, 300.0 - 80.0 * Float64((i * 7) % 5) / 4.0))
    draw_polyline_aa(c, pts, Color(220, 60, 60), 3.0)
    fill_circle_aa(c, 400.0, 120.0, 30.0, Color(30, 160, 80, 160))
    draw_text(c, 60, 40, "Quarterly revenue", Color(20, 20, 20), 28.0)
    write_png(c, "chart.png")
```

### The same drawing to raster, SVG and PDF

```mojo
from canvas import Canvas, Color, SvgCanvas, PdfCanvas, write_png, write_svg, write_pdf
from canvas.vector.draw_target import DrawTarget

def scene[T: DrawTarget](mut t: T) raises:
    t.fill_rect(20, 20, 200, 120, Color(40, 100, 200))
    t.fill_circle_aa(400.0, 100.0, 70.0, Color(30, 160, 80))
    t.draw_line_aa(20.0, 200.0, 760.0, 220.0, Color(0, 0, 0), 4.0)

def main() raises:
    var c = Canvas(800, 300, Color(255, 255, 255))
    scene(c)
    write_png(c, "scene.png")
    var svg = SvgCanvas(800, 300)
    scene(svg)
    write_svg(svg, "scene.svg")
    var pdf = PdfCanvas(800, 300)          # 1 unit = 1 point
    pdf.fill_rect(0, 0, 800, 300, Color(255, 255, 255))
    scene(pdf)
    # Real text: the font is embedded as a subset with a ToUnicode
    # map, so this is selectable and searchable in a viewer.
    pdf.draw_text(20.0, 280.0, "Selectable text", Color(0, 0, 0), 18.0)
    write_pdf(pdf, "scene.pdf")
```

### Gradients, clipping and transforms

```mojo
from canvas import Canvas, Color, ColorSpace, write_png
from canvas.gradient import LinearGradient, RadialGradient
from canvas.path import Path, fill_path_gradient_aa, fill_path_aa
from canvas.shapes.rects import fill_rect_gradient
from std.math import pi

def main() raises:
    var c = Canvas(600, 400, Color(255, 255, 255))
    var g = LinearGradient(50.0, 0.0, 550.0, 0.0)
    g.add_stop(0.0, Color(255, 80, 0))
    g.add_stop(1.0, Color(0, 120, 255))
    g.set_color_space(ColorSpace.LINEAR)   # no dark sag through the middle
    fill_rect_gradient(c, 50, 50, 500, 100, g)

    var donut = Path()
    donut.move_to(390.0, 280.0)                    # arc_to needs a current point
    donut.arc_to(300.0, 280.0, 90.0, 0.0, 2.0 * pi)
    donut.close()
    donut.move_to(345.0, 280.0)
    donut.arc_to(300.0, 280.0, 45.0, 0.0, 2.0 * pi)
    donut.close()
    fill_path_aa(c, donut, Color(60, 60, 60))      # EVEN_ODD punches the hole

    c.save()
    c.push_clip(0, 200, 300, 200)                  # left half only
    c.translate(300.0, 280.0)
    c.rotate(pi / 6.0)
    c.fill_rect(-120, -20, 240, 40, Color(200, 40, 40, 180))
    c.restore()
    write_png(c, "gradients.png")
```

### Text with measurement and alignment

```mojo
from canvas import Canvas, Color, write_png
from canvas.text.font_cache import FontCache
from canvas.text.font_discovery import FontWeight
from canvas.text.render import draw_text, measure_text
from canvas.text.text_align import TextAlign

def main() raises:
    var c = Canvas(600, 200, Color(255, 255, 255))
    var cache = FontCache()
    var m = measure_text("Centered title", 32.0, family="Sans", cache=cache)
    draw_text(c, 300, 80, "Centered title", Color(0, 0, 0), 32.0,
              weight=FontWeight.BOLD, align=TextAlign.CENTER, cache=cache)
    draw_text(c, 300, 140, "width " + String(Int(m.width)) + " px", Color(90, 90, 90), 16.0,
              align=TextAlign.CENTER, cache=cache)
    write_png(c, "text.png")
```

### Reading images and drawing them

```mojo
from canvas import Canvas, Color, write_png
from canvas.io.png import read_png
from canvas.io.jpeg import read_jpeg
from canvas.compose import draw_canvas
from canvas.geometry import Matrix2D

def main() raises:
    var photo = read_jpeg("photo.jpg")            # baseline JPEG, opaque RGBA
    var logo = read_png("logo.png")               # alpha preserved
    var c = Canvas(photo.width, photo.height, Color(0, 0, 0))
    draw_canvas(c, photo, 0, 0)
    draw_canvas(c, logo, Matrix2D.translation(20.0, 20.0).then(Matrix2D.scaling(0.5, 0.5)))
    write_png(c, "composed.png")
```

### Seeing what you drew

Run the script, then open the PNG. For a PDF, `pdftoppm -r 72 -png
out.pdf page` renders it and `pdftotext out.pdf -` shows the text a
viewer extracts. Compare against the rendered examples on the docs
site when something looks off; every example page shows source beside
its output.

