"""DrawTarget: the drawing-primitive interface a higher-level charting
layer renders through, so a plot/scale/theme layer can target either a
raster `Canvas` or a vector `SvgCanvas` without knowing which it holds.
A vector backend has no fixed pixel resolution, so nothing rendered
through the trait deals in supersampling.

Ten drawing primitives are declared -- `fill_rect`, `fill_rect_gradient`,
`draw_line_aa`, `fill_circle_aa`, `fill_ellipse_aa`, `draw_ellipse_aa`,
`fill_arc_aa`, `fill_ring_sector_aa`, `stroke_path_aa` and
`fill_path_aa` -- a subset of `canvas.shapes`. `fill_polygon`, dashes,
clipping, radial gradients and path-shaped gradients are not on the
trait; each exists as a free function or a `Canvas` method instead.

The ellipse methods are the shapes `fill_path_aa`/`stroke_path_aa`
cannot reproduce exactly: `Path.arc_to` takes a single `radius`, so a
`Path` builds circular arcs only and an ellipse comes out as a cubic
approximation. That makes `draw_ellipse_aa` the only outline primitive
here, and it takes no `width`, since the raster primitive behind it
draws a fixed ~1px outline.

Method parameters mirror the same-named function in
`canvas.shapes`/`canvas.path`, minus `supersample` and `dashes`: a
raster implementation picks its own supersample factor, and a vector
one has no equivalent knob. `fill_path_aa` does take a `fill_rule`,
defaulting to `EVEN_ODD` as the raster function does, because the two
backends would otherwise disagree on a path with more than one
sub-path: SVG's own default is nonzero, so a hole that even-odd
punches in a PNG would fill solid in the SVG unless the element says
`fill-rule="evenodd"`.

Two further methods, `begin_annotated_group` and
`end_annotated_group`, declare no drawing at all: they label whatever
is drawn between them. A vector backend has somewhere to put that
label and a raster one does not, so `SvgCanvas` wraps the run in
`<g><title>` and `Canvas` implements both as no-ops. That asymmetry is
the point rather than a wart -- a raster image has no per-shape
metadata to carry, and a caller drawing through the trait should not
have to know which backend it holds in order to name what it draws.

They are scoped rather than a `title` parameter on each primitive
because one datum is often several primitives: a box plot's box,
whiskers, median and caps are one thing to a reader and four calls to
this trait. A group spans however many a datum happens to need.

Text is not on the trait. `Canvas` rasterizes glyph outlines through
`fill_path_aa` while `SvgCanvas` emits `<text>` markup, so there is no
shared operation to declare. A generic caller collects text as plain
data (position, string, color, size, alignment) and lets each backend
draw it. Keeping text off `Canvas`'s method surface also keeps
`canvas.text`'s imports off every `Canvas` user, since Mojo resolves a
struct's whole method surface eagerly.

Conformance is nominal, not structural: `Canvas` (`canvas/buffer.mojo`)
and `SvgCanvas` (`canvas/vector/svg.mojo`) each name `DrawTarget` in
their struct declaration.
"""

from canvas.color import Color
from canvas.fill_rule import FillRule
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

    def fill_path_aa(
        mut self,
        path: Path,
        color: Color,
        fill_rule: FillRule = FillRule.EVEN_ODD,
    ):
        """An anti-aliased fill of a Path's interior.

        Args:
            path: Path to fill.
            color: Fill color.
            fill_rule: EVEN_ODD (default) or NONZERO -- see FillRule.
                The same rule on either backend.
        """
        ...

    def begin_annotated_group(mut self, title: String):
        """Open a group labelled `title`, covering every primitive
        drawn until `end_annotated_group`. A backend that can carry the
        label does; one that cannot ignores it.

        On `SvgCanvas` this emits `<g><title>...</title>`, which is
        what a browser shows as a hover tooltip and what a screen
        reader announces for the group. On `Canvas` it does nothing: a
        raster image has nowhere to put a name.

        Groups do not nest. Opening one while another is open closes
        the first, so the markup stays well formed however a caller
        pairs its calls, and a group left open when the document is
        serialized is closed then.

        Args:
            title: Human-readable label for the drawing that follows.
                Escaped by the backend; pass it raw.
        """
        ...

    def end_annotated_group(mut self):
        """Close the group opened by `begin_annotated_group`, a no-op
        if none is open -- matching `Canvas.pop_clip`, which also
        treats an unbalanced close as nothing to undo rather than an
        error.
        """
        ...
