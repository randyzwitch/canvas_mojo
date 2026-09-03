"""DrawTarget: the drawing-primitive interface a higher-level charting
layer renders through, so a plot/scale/theme layer can target either a
raster `Canvas` or a vector `SvgCanvas` without knowing which it holds.
A vector backend has no fixed pixel resolution, so nothing rendered
through the trait deals in supersampling.

Ten primitives are declared -- `fill_rect`, `fill_rect_gradient`,
`draw_line_aa`, `fill_circle_aa`, `fill_ellipse_aa`, `draw_ellipse_aa`,
`fill_arc_aa`, `fill_ring_sector_aa`, `stroke_path_aa` and
`fill_path_aa` -- a subset of `canvas.shapes`. `fill_polygon`, dashes,
clipping, radial gradients and path-shaped gradients are not on the
trait; each exists as a free function or a `Canvas` method instead.

The two ellipse methods are the shapes `fill_path_aa`/`stroke_path_aa`
cannot reproduce exactly: `Path.arc_to` takes a single `radius`, so a
`Path` builds circular arcs only and an ellipse comes out as a cubic
approximation. That also makes `draw_ellipse_aa` the only outline
primitive here -- a circle outline is `stroke_path_aa` over a Path with
one `arc_to`. It takes no `width`, unlike `draw_line_aa` and
`stroke_path_aa`, because the raster primitive behind it draws a fixed
~1px outline. `fill_rect_gradient` covers linear gradients, which a
continuous color legend needs.

Method parameters mirror the same-named function in
`canvas.shapes`/`canvas.path`, minus `supersample`, `dashes` and
`fill_rule`: a raster implementation picks its own supersample factor,
and a vector one has no equivalent knob.

Text is not on the trait. `Canvas` rasterizes glyph outlines through
`fill_path_aa` while `SvgCanvas` emits `<text>` markup for the viewer's
font engine, so there is no shared operation to declare. A generic
caller collects text as plain data (position, string, color, size,
alignment) and lets each backend draw that list outside the generic
path. Keeping text off `Canvas`'s method surface also keeps
`canvas.text`'s imports off every `Canvas` user, since Mojo resolves a
struct's whole method surface eagerly.

Conformance is nominal, not structural: `Canvas` (`canvas/buffer.mojo`)
and `SvgCanvas` (`canvas/vector/svg.mojo`) each name `DrawTarget` in
their struct declaration.
"""

from canvas.color import Color
from canvas.path import Path
from canvas.gradient import LinearGradient


trait DrawTarget:
    def fill_rect(
        mut self, x: Int, y: Int, width: Int, height: Int, color: Color
    ):
        """Fill a solid rectangle (x, y is the top-left corner).

        Args:
            x: Rectangle's left edge.
            y: Rectangle's top edge.
            width: Rectangle's width.
            height: Rectangle's height.
            color: Fill color.
        """
        ...

    def fill_rect_gradient(
        mut self,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        gradient: LinearGradient,
    ):
        """Fill a rectangle, sourcing each point's color from
        `gradient` rather than one flat color.

        Args:
            x: Rectangle's left edge.
            y: Rectangle's top edge.
            width: Rectangle's width.
            height: Rectangle's height.
            gradient: Fill source, projected across the rectangle.
        """
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
        """An anti-aliased line with round end caps.

        Args:
            x0: Start point x.
            y0: Start point y.
            x1: End point x.
            y1: End point y.
            color: Line color.
            width: Stroke width in pixels.
        """
        ...

    def fill_circle_aa(mut self, cx: Int, cy: Int, radius: Int, color: Color):
        """An anti-aliased filled disk.

        Args:
            cx: Center x.
            cy: Center y.
            radius: Circle radius in pixels.
            color: Fill color.
        """
        ...

    def fill_ellipse_aa(
        mut self, cx: Int, cy: Int, rx: Int, ry: Int, color: Color
    ):
        """An anti-aliased filled ellipse.

        Args:
            cx: Center x.
            cy: Center y.
            rx: Horizontal radius in pixels.
            ry: Vertical radius in pixels.
            color: Fill color.
        """
        ...

    def draw_ellipse_aa(
        mut self, cx: Int, cy: Int, rx: Int, ry: Int, color: Color
    ):
        """An anti-aliased ellipse outline, ~1px wide.

        Args:
            cx: Center x.
            cy: Center y.
            rx: Horizontal radius in pixels.
            ry: Vertical radius in pixels.
            color: Outline color.
        """
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
        """An anti-aliased filled pie-slice wedge.

        Args:
            cx: Center x.
            cy: Center y.
            radius: Wedge radius in pixels.
            start_angle: Sweep start, radians, 0 pointing along +x.
            end_angle: Sweep end, radians. Must be >= start_angle.
            color: Fill color.
        """
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
        """An anti-aliased filled ring/donut segment.

        Args:
            cx: Center x.
            cy: Center y.
            inner_radius: Ring's inner edge, in pixels.
            outer_radius: Ring's outer edge, in pixels. Must exceed
                inner_radius.
            start_angle: Sweep start, radians, 0 pointing along +x.
            end_angle: Sweep end, radians. Must be >= start_angle.
            color: Fill color.
        """
        ...

    def stroke_path_aa(
        mut self, path: Path, color: Color, width: Float64 = 1.0
    ):
        """An anti-aliased stroke of a Path's outline.

        Args:
            path: Path to stroke.
            color: Stroke color.
            width: Stroke width in pixels.
        """
        ...

    def fill_path_aa(mut self, path: Path, color: Color):
        """An anti-aliased fill of a Path's interior.

        Args:
            path: Path to fill.
            color: Fill color.
        """
        ...
