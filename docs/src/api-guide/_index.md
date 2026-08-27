---
title: API Reference
type: docs
weight: 145
---

The `canvas_mojo` package, grouped by what you're trying to do rather
than the alphabetical module list `mojo doc` produces on its own.
Every entry below links to that module's full generated reference —
every type, function, and parameter it exposes. Prefer to browse or
search the raw, complete listing instead? See the
[full package reference](../canvas_mojo/).

## Core canvas & color

The pixel buffer everything else draws into, and the color type every
fill/stroke color is.

- [`buffer`](../canvas_mojo/buffer/) — `Canvas`: the pixel buffer.
  Construct one, then either call its drawing methods directly
  (`canvas.fill_circle_aa(...)`) or use the free-function form
  (`fill_circle_aa(canvas, ...)`) — both call the same code.
- [`color`](../canvas_mojo/color/) — `Color`: 8-bit RGBA, plus
  `blend_over` for compositing a translucent color onto a background.
- [`geometry`](../canvas_mojo/geometry/) — `Point` (an integer x/y
  pair, for polylines/polygons) and `Transform2D` (scale, rotate,
  translate a coordinate before it hits the canvas).

## Shape primitives

The discrete shapes: lines, rectangles, circles, ellipses, arcs,
polylines/polygons. Each comes in a hard-edged variant (fast, aliased)
and an `_aa` variant (supersampled, anti-aliased) — see
[Examples](../examples/) for both side by side.

- [`shapes.lines`](../canvas_mojo/shapes/lines/) — `draw_line`,
  `draw_polyline`, `draw_polygon`, and their `_aa` counterparts.
- [`shapes.rects`](../canvas_mojo/shapes/rects/) — `draw_rect`,
  `fill_rect`, plus `fill_rect_gradient`/`fill_rect_radial_gradient`.
- [`shapes.circles`](../canvas_mojo/shapes/circles/) — `draw_circle`,
  `fill_circle`, and their `_aa` counterparts.
- [`shapes.ellipses`](../canvas_mojo/shapes/ellipses/) —
  `draw_ellipse`, `fill_ellipse`, and their `_aa` counterparts.
- [`shapes.arcs`](../canvas_mojo/shapes/arcs/) — `draw_arc`,
  `fill_arc`, `fill_ring_sector`, and their `_aa` counterparts.
- [`shapes.polygon_fill`](../canvas_mojo/shapes/polygon_fill/) —
  `fill_polygon`/`fill_polygon_aa`: the scanline fill the shapes above
  and `Path` both build on, callable directly for an arbitrary point
  list.

## Paths & fills

Bezier curves, multi-sub-path shapes, and the rule that decides what
"inside" means for a self-intersecting one.

- [`path`](../canvas_mojo/path/) — `Path`: `move_to` →
  `line_to`/`quad_curve_to`/`cubic_curve_to`/`arc_to`, then
  `fill_path`/`fill_path_aa`/`stroke_path`/`stroke_path_aa` (plus
  gradient-filled variants) to render it.
- [`fill_rule`](../canvas_mojo/fill_rule/) — `FillRule`: `EVEN_ODD`
  (the default) vs. `NONZERO`, for `fill_polygon`/`fill_path` and
  their gradient variants.

## Gradients

Fill sources, not shapes of their own — pass one to a `*_gradient`
function above.

- [`gradient`](../canvas_mojo/gradient/) — `LinearGradient` and
  `RadialGradient`: add color stops with `add_stop`, then hand the
  gradient to `fill_rect_gradient`/`fill_path_gradient` or their
  radial counterparts.

## Text

Real system-font rendering: fontconfig resolves a family/style to a
file, this package's own parser reads it, and the result feeds
`fill_path_aa` like any other shape.

- [`text.render`](../canvas_mojo/text/render/) — `draw_text` and
  `measure_text`/`measure_text_block`, the entry points most callers
  need.
- [`text.font_discovery`](../canvas_mojo/text/font_discovery/) —
  `resolve_font_file`/`resolve_font_file_for_char`, `FontSlant`,
  `FontWeight`: family/style name → installed font file, via
  fontconfig.
- [`text.font_cache`](../canvas_mojo/text/font_cache/) — `FontCache`:
  reuses a resolved font file/parsed face across repeated draws
  instead of re-resolving and re-parsing each call.
- [`text.ttf`](../canvas_mojo/text/ttf/) — `TTFFace`: the native
  TrueType parser (glyph outlines, metrics) underneath `text.render`.
- [`text.glyph_outline`](../canvas_mojo/text/glyph_outline/) — a
  single glyph's outline as a `Path`, plus its metrics.
- [`text.bidi`](../canvas_mojo/text/bidi/) — `detect_base_level`/
  `visual_order`: right-to-left and mixed-direction text layout.
- [`text.text_align`](../canvas_mojo/text/text_align/) — `TextAlign`,
  the alignment enum `draw_text` takes.

## Vector output (SVG)

A drawing routine written once against `DrawTarget` renders through
either backend — raster or vector — without knowing which it holds.

- [`vector.svg`](../canvas_mojo/vector/svg/) — `SvgCanvas`: the same
  drawing methods as `Canvas`, producing SVG markup instead of
  pixels — `to_string()` for the markup, `write_svg` for a file.
- [`vector.draw_target`](../canvas_mojo/vector/draw_target/) —
  `DrawTarget`: the trait both `Canvas` and `SvgCanvas` implement.
  Write against this instead of `Canvas` directly and your code works
  against either.

## Image I/O & resizing

Getting a `Canvas` to and from disk, and shrinking one after rendering
it oversized for extra anti-aliasing.

- [`io.png`](../canvas_mojo/io/png/) — `write_png`/`read_png`, this
  package's own DEFLATE-compressed PNG encoder/decoder.
- [`io.bmp`](../canvas_mojo/io/bmp/) — `write_bmp`, for the simpler
  uncompressed format.
- [`io.deflate`](../canvas_mojo/io/deflate/) — `deflate`/`inflate`,
  the compression `io.png` runs on; only worth using directly if you
  need DEFLATE bytes for something other than a PNG.
- [`resize`](../canvas_mojo/resize/) — `downsample`: shrink a `Canvas`
  by an integer factor, box-filtering each output pixel from the
  source block it covers — render oversized, then downsample, for
  finer anti-aliasing than a single-resolution render gets you.

---

Two modules with no public exports (`aa_crossing`, `shapes.dash`) are
left off this list — internal machinery shared between the shapes
above, not something you call directly. They're still in the
[full package reference](../canvas_mojo/) if you're curious.
