---
title: API Reference
type: docs
weight: 145
---

The `canvas` package, grouped by what you're trying to do rather
than the alphabetical module list `mojo doc` produces on its own.
Every entry below links to that module's full generated reference —
every type, function, and parameter it exposes. Prefer to browse or
search the raw, complete listing instead? See the
[full package reference](../canvas/).

## Core canvas & color

The pixel buffer everything else draws into, and the color type every
fill/stroke color is.

- [`buffer`](../canvas/buffer/) — `Canvas`: the pixel buffer.
  Construct one, then either call its drawing methods directly
  (`canvas.fill_circle_aa(...)`) or use the free-function form
  (`fill_circle_aa(canvas, ...)`) — both call the same code. It also
  carries the drawing state: `save`/`restore`, `translate`/`rotate`/
  `scale`/`transform` for a current transform every primitive maps
  through, and `push_clip`/`push_clip_path` for clipping.
- [`color`](../canvas/color/) — `Color`: 8-bit RGBA, plus
  `blend_over` for compositing a translucent color onto a background.
- [`geometry`](../canvas/geometry/) — `Point` (an integer x/y
  pair, for polylines/polygons), `Transform2D` (scale, rotate,
  translate a coordinate before it hits the canvas) and `Matrix2D`
  (a general affine map, the type behind the canvas transform).

## Shape primitives

The discrete shapes: lines, rectangles, circles, ellipses, arcs,
polylines/polygons. Each comes in a hard-edged variant (fast, aliased)
and an `_aa` variant (anti-aliased: exact-area coverage for nonzero
fills, 4×4 supersampled for even-odd fills and strokes) — see
[Examples](../examples/) for both side by side.

- [`shapes.lines`](../canvas/shapes/lines/) — `draw_line`,
  `draw_polyline`, `draw_polygon`, and their `_aa` counterparts.
- [`shapes.rects`](../canvas/shapes/rects/) — `draw_rect`,
  `fill_rect`, plus `fill_rect_gradient`/`fill_rect_radial_gradient`.
- [`shapes.circles`](../canvas/shapes/circles/) — `draw_circle`,
  `fill_circle`, and their `_aa` counterparts.
- [`shapes.ellipses`](../canvas/shapes/ellipses/) —
  `draw_ellipse`, `fill_ellipse`, and their `_aa` counterparts.
- [`shapes.arcs`](../canvas/shapes/arcs/) — `draw_arc`,
  `fill_arc`, `fill_ring_sector`, and their `_aa` counterparts.
- [`shapes.polygon_fill`](../canvas/shapes/polygon_fill/) —
  `fill_polygon`/`fill_polygon_aa`: the scanline fill the shapes above
  and `Path` both build on, callable directly for an arbitrary point
  list.

## Paths & fills

Bezier curves, multi-sub-path shapes, and the rule that decides what
"inside" means for a self-intersecting one.

- [`path`](../canvas/path/) — `Path`: `move_to` →
  `line_to`/`quad_curve_to`/`cubic_curve_to`/`arc_to`, then
  `fill_path`/`fill_path_aa`/`stroke_path`/`stroke_path_aa` (plus
  gradient-filled variants) to render it.
- [`fill_rule`](../canvas/fill_rule/) — `FillRule`: `EVEN_ODD`
  (the default) vs. `NONZERO`, for `fill_polygon`/`fill_path` and
  their gradient variants.

## Gradients

Fill sources, not shapes of their own — pass one to a `*_gradient`
function above.

- [`gradient`](../canvas/gradient/) — `LinearGradient` and
  `RadialGradient`: add color stops with `add_stop`, then hand the
  gradient to `fill_rect_gradient`/`fill_path_gradient` or their
  radial counterparts.

## Text

Real system-font rendering, all of it native: this package's own font
discovery resolves a family/style to an installed file, its own parser
reads that file, and the result feeds `fill_path_aa` like any other
shape.

- [`text.render`](../canvas/text/render/) — `draw_text` and
  `measure_text`/`measure_text_block`, the entry points most callers
  need.
- [`text.font_discovery`](../canvas/text/font_discovery/) —
  `resolve_font_file`/`resolve_font_file_for_char`, `FontDatabase`,
  `FontSlant`, `FontWeight`: family/style name → installed font file,
  by scanning the machine's font directories and matching each font's
  own `name`/`OS/2` tables. Set `CANVAS_MOJO_FONT_PATH`
  (colon-separated directories) to search font trees outside the
  platform's usual locations.
- [`text.font_cache`](../canvas/text/font_cache/) — `FontCache`:
  reuses a resolved font file/parsed face across repeated draws
  instead of re-resolving and re-parsing each call. Worth passing
  `cache=` for anything drawing more than a handful of labels: it
  scans the installed fonts once, at construction, and every later
  lookup reads from that.
- [`text.ttf`](../canvas/text/ttf/) — `TTFFace`: the native
  TrueType parser (glyph outlines, metrics) underneath `text.render`.
- [`text.glyph_outline`](../canvas/text/glyph_outline/) — a
  single glyph's outline as a `Path`, plus its metrics.
- [`text.bidi`](../canvas/text/bidi/) — `detect_base_level`/
  `visual_order`: right-to-left and mixed-direction text layout.
- [`text.text_align`](../canvas/text/text_align/) — `TextAlign`,
  the alignment enum `draw_text` takes.

## Vector output (SVG)

A drawing routine written once against `DrawTarget` renders through
either backend — raster or vector — without knowing which it holds.

- [`vector.svg`](../canvas/vector/svg/) — `SvgCanvas`: the same
  drawing methods as `Canvas`, producing SVG markup instead of
  pixels — `to_string()` for the markup, `write_svg` for a file.
- [`vector.draw_target`](../canvas/vector/draw_target/) —
  `DrawTarget`: the trait both `Canvas` and `SvgCanvas` implement.
  Write against this instead of `Canvas` directly and your code works
  against either.

## Image I/O & resizing

Getting a `Canvas` to and from disk, and shrinking one after rendering
it oversized for extra anti-aliasing.

- [`io.png`](../canvas/io/png/) — `write_png`/`read_png`, this
  package's own DEFLATE-compressed PNG encoder/decoder.
- [`io.bmp`](../canvas/io/bmp/) — `write_bmp`, for the simpler
  uncompressed format.
- [`io.deflate`](../canvas/io/deflate/) — `deflate`/`inflate`,
  the compression `io.png` runs on; only worth using directly if you
  need DEFLATE bytes for something other than a PNG.
- [`resize`](../canvas/resize/) — `downsample`: shrink a `Canvas`
  by an integer factor, box-filtering each output pixel from the
  source block it covers — render oversized, then downsample, for
  finer anti-aliasing than a single-resolution render gets you.

---

Two modules with no public exports (`aa_crossing`, `shapes.dash`) are
left off this list — internal machinery shared between the shapes
above, not something you call directly. They're still in the
[full package reference](../canvas/) if you're curious.
