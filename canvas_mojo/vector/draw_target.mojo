"""DrawTarget: the minimal drawing-primitive interface a higher-level
charting layer renders through, so a plot/scale/theme layer can target
either a raster `Canvas` or a vector `SvgCanvas` without knowing which
it holds. A vector backend has no fixed pixel resolution, so nothing
rendered through it deals in supersampling.

Narrow by design: the shape primitives a chart-rendering core needs
(`fill_rect`, `draw_line_aa`, `fill_circle_aa`, `fill_ellipse_aa`,
`fill_arc_aa`, `fill_ring_sector_aa`, `stroke_path_aa`,
`fill_path_aa`, `fill_rect_gradient`), not `canvas_mojo.shapes`'s full
surface -- no `fill_polygon`, dashes, clipping, radial gradients, or
path-shaped gradients.

The two ellipse methods are here for a reason worth stating, since
every other shape absent from this trait is absent because
`fill_path_aa`/`stroke_path_aa` already cover it: an ellipse is the one
case where that escape hatch fails. `Path.arc_to` takes a single
`radius`, so it builds circular arcs only, and an ellipse can therefore
only be *approximated* through `Path`, with cubics. Without these a
trait-targeting caller cannot draw one exactly -- which error ellipses
and confidence regions on a scatter plot need.

`draw_ellipse_aa` is consequently the one shape carrying both a fill
and an outline here, where circles and arcs carry only a fill. That
asymmetry is the point rather than an oversight: a circle outline is
`stroke_path_aa` over a `Path` with one `arc_to`, and an ellipse
outline has no such equivalent.

It also takes no `width`, unlike `draw_line_aa` and `stroke_path_aa`:
the raster primitive behind it draws a fixed ~1px outline, and a width
parameter the raster backend could only ignore would be worse than
none. `fill_rect_gradient` (linear only) is here
because a continuous color legend needs a real gradient bar rather
than a discrete color-strip approximation; the rest of
`canvas_mojo.gradient` has no caller through this interface.

Each method's parameters mirror the same-named function in
`canvas_mojo.shapes`/`canvas_mojo.path`, trimmed to what a generic
caller would pass: no `supersample`, `dashes`, or `fill_rule`. A raster
implementation picks its own supersample factor; a vector one has no
equivalent knob.

Text is excluded. The two backends draw it through different
mechanisms -- `Canvas` rasterizes glyph outlines via `fill_path_aa`,
`SvgCanvas` emits `<text>` markup for the viewer's font engine and
never touches an outline -- so there's no shared operation to
generalize the way there is for the shape primitives. A generic
chart-rendering core collects text as plain data (position, string,
color, size, alignment) and lets each backend draw that list its own
way, outside the generic path.

Excluding text also keeps `canvas_mojo.text`'s imports off every
`Canvas` user: Mojo resolves a struct's whole method surface eagerly,
so a `Canvas` method calling `draw_text` would pull that dependency
chain into any file importing `Canvas` at all.

Conformance is nominal, not structural, per Mojo's trait rule:
`Canvas` (`canvas_mojo/buffer.mojo`) and `SvgCanvas`
(`canvas_mojo/vector/svg.mojo`) each declare `DrawTarget` explicitly.
"""

from canvas_mojo.color import Color
from canvas_mojo.path import Path
from canvas_mojo.gradient import LinearGradient


trait DrawTarget:
    def fill_rect(
        mut self, x: Int, y: Int, width: Int, height: Int, color: Color
    ):
        ...

    def fill_rect_gradient(
        mut self,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        gradient: LinearGradient,
    ):
        ...

    def draw_line_aa(
        mut self,
        x0: Int,
        y0: Int,
        x1: Int,
        y1: Int,
        color: Color,
        width: Float64 = 1.0,
    ):
        ...

    def fill_circle_aa(mut self, cx: Int, cy: Int, radius: Int, color: Color):
        ...

    def fill_ellipse_aa(
        mut self, cx: Int, cy: Int, rx: Int, ry: Int, color: Color
    ):
        ...

    def draw_ellipse_aa(
        mut self, cx: Int, cy: Int, rx: Int, ry: Int, color: Color
    ):
        ...

    def fill_arc_aa(
        mut self,
        cx: Float64,
        cy: Float64,
        radius: Float64,
        start_angle: Float64,
        end_angle: Float64,
        color: Color,
    ):
        ...

    def fill_ring_sector_aa(
        mut self,
        cx: Float64,
        cy: Float64,
        inner_radius: Float64,
        outer_radius: Float64,
        start_angle: Float64,
        end_angle: Float64,
        color: Color,
    ):
        ...

    def stroke_path_aa(
        mut self, path: Path, color: Color, width: Float64 = 1.0
    ):
        ...

    def fill_path_aa(mut self, path: Path, color: Color):
        ...
