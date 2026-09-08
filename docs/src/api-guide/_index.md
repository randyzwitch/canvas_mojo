---
title: API Reference
type: docs
weight: 145
---

The importable package is named `canvas`. This page groups its public
modules by task; each link opens generated documentation containing the
complete signatures, parameters, return values, and errors. See the
[full package reference](../canvas/) for the module tree.

## Start here

- [`buffer`](../canvas/buffer/) — `Canvas`, pixel access, drawing state,
  transforms, and clipping.
- [`color`](../canvas/color/) — `Color` and `ColorSpace`.
- [`geometry`](../canvas/geometry/) — `Point`, `FPoint`, `Transform2D`,
  and `Matrix2D`.
- [`vector.draw_target`](../canvas/vector/draw_target/) — the shared
  `DrawTarget` interface implemented by all three backends.

Most public entry points are also re-exported from the package root:

```mojo
from canvas import Canvas, Color, Path, fill_circle_aa, write_png
```

## Shapes

- [`shapes.lines`](../canvas/shapes/lines/) — lines, polylines, polygon
  outlines, dashes, caps, and joins.
- [`shapes.rects`](../canvas/shapes/rects/) — rectangle outlines and
  solid, gradient, radial-gradient, or pattern fills.
- [`shapes.circles`](../canvas/shapes/circles/) — circle outlines and
  fills, including batched equal-radius markers with `fill_circles_aa`.
- [`shapes.ellipses`](../canvas/shapes/ellipses/) — ellipse outlines and fills.
- [`shapes.arcs`](../canvas/shapes/arcs/) — arcs, wedges, and ring sectors.
- [`shapes.polygon_fill`](../canvas/shapes/polygon_fill/) — polygon fills.

Hard-edged primitives have plain names such as `draw_line`; anti-aliased
variants end in `_aa`.

## Paths and paint

- [`path`](../canvas/path/) — construct, query, transform, fill, and
  stroke multi-subpath `Path` values.
- [`fill_rule`](../canvas/fill_rule/) — `EVEN_ODD` and `NONZERO` interior rules.
- [`gradient`](../canvas/gradient/) — linear, radial, and conic gradients.
- [`pattern`](../canvas/pattern/) — raster tiles, hatches, and edge extension.
- [`named_colors`](../canvas/named_colors/) — CSS named-color constants.

## Text

- [`text.render`](../canvas/text/render/) — draw, stroke, measure,
  prepare, and place text on paths.
- [`text.font_cache`](../canvas/text/font_cache/) — caller-owned cache for
  font resolution, parsed faces, and glyph masks. Construction is cheap;
  font discovery occurs on the first lookup.
- [`text.font_discovery`](../canvas/text/font_discovery/) — resolve a
  family, slant, weight, or codepoint to an installed font.
- [`text.text_align`](../canvas/text/text_align/) — left, center, and right alignment.
- [`text.glyph_outline`](../canvas/text/glyph_outline/) — glyph paths and metrics.
- [`text.ttf`](../canvas/text/ttf/) — low-level TrueType/OpenType parsing.
- [`text.bidi`](../canvas/text/bidi/) — bidirectional layout primitives.

Use `measure_text` for a single line's `TextMetrics`, including advance.
Use `measure_text_block` for an anchor-relative multiline ink bounding
box. When the same text must be measured and drawn, `prepare_text`,
`measure_layout`, and `draw_layout` share one prepared `TextLayout`.

## Compositing and effects

- [`compose`](../canvas/compose/) — place, transform, filter, mask, and
  composite one canvas onto another.
- [`blend`](../canvas/blend/) — Porter-Duff composite operators and
  separable or non-separable blend modes.
- [`mask`](../canvas/mask/) — create and apply 8-bit coverage masks.
- [`blur`](../canvas/blur/) — Gaussian-like blur and drop shadows.
- [`resize`](../canvas/resize/) — integer downsampling and general resizing.

## Image I/O

- [`io.png`](../canvas/io/png/) — read PNG and write 8-bit,
  non-interlaced PNG; `PngLevel` selects encoding effort.
- [`io.bmp`](../canvas/io/bmp/) — read and write uncompressed BMP.
- [`io.jpeg`](../canvas/io/jpeg/) — read baseline and progressive JPEG.
- [`io.deflate`](../canvas/io/deflate/) — raw DEFLATE streams used by PNG.

## SVG and PDF

- [`vector.svg`](../canvas/vector/svg/) — `SvgCanvas`, SVG text, and `write_svg`.
- [`vector.pdf`](../canvas/vector/pdf/) — `PdfCanvas`, embedded text and
  images, multiple pages, and `write_pdf`.
- [`vector.pdf_font`](../canvas/vector/pdf_font/) — PDF font subsetting internals.

`Canvas`, `SvgCanvas`, and `PdfCanvas` share the core `DrawTarget`
primitives, transforms, blend state, and annotated groups. Text,
clipping, images, and some paint operations remain backend-specific;
consult each backend's generated reference for its supported surface.

## Internal modules

`aa_area`, `aa_crossing`, `shapes.dash`, `text.cff`, `text.joining`, and
`workers` are implementation modules rather than package-root APIs.
They remain visible in the [full package reference](../canvas/) for
contributors.
