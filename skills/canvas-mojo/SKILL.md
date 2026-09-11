---
name: canvas-mojo
description: Draw 2D graphics in Mojo with canvas_mojo -- raster PNG/BMP, SVG and PDF from one API; shapes, paths, gradients, clipping, transforms, system-font text, image input. Use when writing or debugging Mojo code that renders pictures or charts, or when a project depends on canvas_mojo.
---

# Drawing with canvas_mojo

canvas_mojo is a 2D drawing engine written entirely in Mojo. `Canvas`
(raster), `SvgCanvas` and `PdfCanvas` implement the same `DrawTarget`
trait; code written against the trait draws to any of them.

## First, load the API digest

Fetch https://randyzwitch.com/canvas_mojo/llms.txt (or read
`docs/site/static/llms.txt` after `pixi run llms` in a checkout). It
holds the conventions, five working recipes, and every public function
with its signature and purpose. Do not guess signatures from memory:
the library's API has changed quickly and the digest is regenerated
from the source on every docs build.

## Setup in the user's project

```toml
[workspace]
preview = ["pixi-build"]
[dependencies]
canvas_mojo = { git = "https://github.com/randyzwitch/canvas_mojo.git", branch = "main" }
```

`pixi install`, then `from canvas import Canvas, Color, ...`. The
package is `canvas`; subpackages are `canvas.shapes`, `canvas.path`,
`canvas.gradient`, `canvas.text`, `canvas.io`, `canvas.vector`.

## The five things that go wrong

1. Coordinates are y-down pixels and `Float64` positions are pixel
   centers: pixel (x, y) spans x - 0.5 to x + 0.5. Draw with the
   `Float64` and `_aa` overloads for anything visual.
2. Angles are radians, clockwise on screen; a wedge sweeps from
   `start_angle` to `end_angle`.
3. `fill_path_aa` defaults to `FillRule.EVEN_ODD`, which punches holes
   where sub-paths overlap; pass `FillRule.NONZERO` for a union.
   TrueType glyph outlines from `text_path` need `NONZERO`.
4. Text and gradient path fills are backend methods, not trait
   methods; the rectangle clip `push_clip`/`pop_clip` is on the trait,
   so a generic mark layer can keep its drawing inside a plot area. Write the shared drawing against `DrawTarget`, then
   call those on the concrete backend. `draw_image` is on the trait:
   it places a `Canvas` as a block of cells where a `fill_rect` at the
   same box would land, one `<image>` in SVG rather than a `<rect>`
   per cell, so draw a heatmap or image plot through it.
5. Mojo: `Path` builder calls raise (a segment or arc before any
   `move_to` is an error), so a function building one is `raises`; a `List[FPoint]` literal needs the type annotation; strings
   slice with `s[byte = a:b]`.

## Verify by looking

Every drawing task ends with rendering and viewing the result:

```sh
pixi run mojo run -I . my_drawing.mojo   # writes out.png
```

Then open the PNG. For a PDF: `pdftoppm -r 72 -png out.pdf page` and
`pdftotext out.pdf -`. The examples at
https://randyzwitch.com/canvas_mojo/examples/ show source beside output
for every feature; match the one closest to the task when something
looks wrong.

## Performance notes for large drawings

Anti-aliased fills, strokes, gradients, blur and compositing are
banded across cores automatically, by how much work there is rather
than by the core count. An application rendering several canvases at
once can cap one render with `canvas.set_max_workers(n)` so they share
the machine instead of each taking it; output is identical at any
count. Reuse one `FontCache` across text calls; the first call on a
fresh cache scans the system fonts, and the cache bounds its glyph
masks by bytes, releasing the least recently used generation rather
than everything. For thousands of small markers, `fill_circle_aa` is
cheap; prefer it to a path per marker, and wrap the loop in
`canvas.begin_batch()` / `canvas.end_batch()`: a shape too small to
split across cores runs on one core when drawn alone, and a batch
draws everything inside it in one parallel pass, in order, with the
same pixels. Gridlines, ticks, markers and bars all batch; text and
gradients inside a batch draw immediately, in order, and reads see the
batch only after `end_batch`. Read PNG and JPEG with
`read_png`/`read_jpeg` (baseline JPEG only). `write_png` takes an
optional `PngLevel`: `FAST` for export throughput, `SMALL` for a
smaller file, and every level decodes to the same pixels.
