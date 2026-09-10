---
title: Choosing a Backend
weight: 50
---

Choose the target from the artifact you need. `Canvas` owns an RGBA pixel
buffer and writes raster images. `SvgCanvas` records editable SVG markup.
`PdfCanvas` records one or more print-oriented PDF pages. All three conform
to `DrawTarget`, so code limited to that trait's primitives, state, and
annotations can render through any backend.

## Capability comparison

| Capability | `Canvas` | `SvgCanvas` | `PdfCanvas` |
| --- | --- | --- | --- |
| Primary output | PNG or BMP | SVG | PDF |
| `DrawTarget` shapes and paths | Yes | Yes | Yes |
| Transforms and `save`/`restore` | Yes | Yes | Yes |
| Linear, radial, and path gradients | Yes | Yes | Yes |
| Rectangle and path clipping | Yes | Yes | Yes |
| Blend modes and color-space state | Yes | Yes, emitted as SVG/CSS | Yes, emitted as PDF graphics state |
| Filled and stroked text | Rasterized glyphs | SVG text elements | Embedded font subsets |
| Text on a path | Yes | Yes | No |
| Raster image placement | Yes | No | Yes |
| Annotated groups | Accepted as no-ops | Labeled SVG groups | Marked-content groups |
| Multiple pages | No | No | Yes, with `new_page` |
| Pixel reads and writes | Yes | No | No |

The shared row does not mean the files are pixel-identical. `Canvas`
rasterizes immediately and applies its supersampling rules. SVG and PDF
preserve vector geometry and leave final rasterization to a viewer or
printer.

## Use Canvas for pixels

Use `Canvas` when you need PNG or BMP output, direct pixel access, masking,
blur and resize operations, or predictable raster output at a chosen
resolution. Raster text uses installed font outlines and supports color
bitmap glyphs. Image decoders return a `Canvas`, which can then be composed
with other raster content.

## Use SvgCanvas for editable vector output

Use `SvgCanvas` for a single scalable graphic that should remain inspectable
and editable as XML. Text stays as SVG text and therefore depends on the
viewer's available fonts. SVG additionally supports text on a path. It does
not currently provide raster image placement.

## Use PdfCanvas for documents and printing

Use `PdfCanvas` for print-oriented output, embedded raster images, or a
multi-page document. Call `new_page()` to finish the current page and begin
another; width and height can be inherited or changed. Used font glyphs are
embedded in subsets with a ToUnicode map so viewers can extract text.

## Write backend-generic drawing code

Accept a `DrawTarget` when a function only needs the common drawing contract:

```mojo
from canvas import Canvas, Color, DrawTarget, write_png

def draw_badge[T: DrawTarget](mut target: T) raises:
    target.fill_circle_aa(24.0, 24.0, 20.0, Color(40, 110, 220))
    target.draw_line_aa(15.0, 24.0, 22.0, 31.0, Color(255, 255, 255), width=3.0)
    target.draw_line_aa(22.0, 31.0, 34.0, 17.0, Color(255, 255, 255), width=3.0)


def main() raises:
    var canvas = Canvas(48, 48, Color(250, 250, 252))
    draw_badge(canvas)
    write_png(canvas, "badge.png")
```

Text is intentionally outside `DrawTarget` because its representation and
font behavior differ by backend. Image placement and backend-specific
document features are outside it as well. Keep those operations at the layer
that chooses the concrete target, or provide a separate path for each target.

See [Transforms and State](../transforms-and-state/) for the shared state
model and [Text](../text/) for text measurement, caching, and backend
differences.
