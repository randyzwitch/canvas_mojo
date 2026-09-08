---
title: Text
weight: 40
---

canvas_mojo resolves installed fonts, shapes text, reads glyph outlines,
and renders them without an external font library. Results depend on the
fonts installed on the machine.

## Draw text

The `(x, y)` anchor is on the baseline. Alignment controls the anchor's
horizontal relationship to each line:

```mojo
from canvas import Color, FontCache, TextAlign, draw_text

var cache = FontCache()
draw_text(
    canvas,
    300,
    80,
    "Centered title",
    Color(20, 20, 20),
    32.0,
    align=TextAlign.CENTER,
    cache=cache,
)
```

`family` accepts an installed family name or a generic alias such as
`"Sans"`, `"Serif"`, or `"Monospace"`. `FontSlant` and `FontWeight`
select a face within the family. Missing glyphs may be resolved from a
fallback font.

## Reuse a FontCache

`FontCache()` is cheap to construct and scans nothing immediately. Its
first lookup initializes the font database. Reuse one cache across
related measurement and drawing calls so resolved paths, parsed faces,
and rasterized glyph masks can be shared.

The overloads without `cache=` remain convenient for isolated calls.

## Choose a measurement API

`measure_text` treats its input as one line and returns `TextMetrics`:

- `width` and `height` describe the line's tight ink size.
- `advance` is the distance to the next text position.

`measure_text_block` handles newline-separated lines, alignment, and
rotation. It returns `TextBlockBounds`, an anchor-relative ink bounding
box with `x`, `y`, `width`, and `height`.

Neither function draws into a canvas.

## Measure and draw one prepared layout

Prepare text when the same layout must be measured and drawn:

```mojo
from canvas import draw_layout, measure_layout, prepare_text

var layout = prepare_text(
    "Prepared title",
    32.0,
    align=TextAlign.CENTER,
    cache=cache,
)
var bounds = measure_layout(layout)
draw_layout(canvas, 300.0, 80.0, layout, Color(20, 20, 20), cache=cache)
```

A `TextLayout` retains the string and every option that affects shaping
or placement, but not the anchor or color. It can be drawn at several
positions and colors. Draw it with the same `FontCache` used to prepare
it because its glyph indices refer to faces owned by that cache.

## Backend differences

- `Canvas` rasterizes glyph outlines and color bitmap glyphs.
- `SvgCanvas.draw_text` emits an SVG text element using a CSS family value.
- `PdfCanvas.draw_text` embeds used font subsets and a ToUnicode map.

Text is not part of `DrawTarget`; call the concrete backend's text API.
