"""DrawTarget: the drawing-primitive interface a higher-level charting
layer renders through, so a plot/scale/theme layer can target either a
raster `Canvas` or a vector `SvgCanvas` without knowing which it holds.
A vector backend has no fixed pixel resolution, so nothing rendered
through the trait deals in supersampling.

Eleven drawing primitives are declared -- `fill_rect`,
`fill_rect_gradient`, `draw_line_aa`, `fill_circle_aa`, `draw_circle_aa`,
`fill_ellipse_aa`, `draw_ellipse_aa`, `fill_arc_aa`,
`fill_ring_sector_aa`, `stroke_path_aa` and `fill_path_aa` -- a subset
of `canvas.shapes`. `fill_polygon`, clipping, radial gradients and
path-shaped gradients are not on the trait; each exists as a free
function or a `Canvas` method instead. The two strokes, `draw_line_aa`
and `stroke_path_aa`, take the full stroke style -- `dashes`,
`dash_offset`, `cap`, `join`, `miter_limit` -- so a dashed series or a
square-capped rule renders the same way on either backend.

`draw_ellipse_aa` is the outline `fill_path_aa`/`stroke_path_aa` cannot
reproduce exactly: `Path.arc_to` takes a single `radius`, so a `Path`
builds circular arcs only and an ellipse comes out as a cubic
approximation. `draw_circle_aa` has no such gap -- a stroked circular
`Path` is exact -- and is on the trait instead for parity with
`fill_circle_aa` and with the sub-pixel, width-taking overloads
`Canvas` already carries as free-function calls. Both outlines take a
sub-pixel `(cx, cy)`, the matching sub-pixel radii, and `width`; neither
takes `dashes`, since the raster primitives behind them do not.

Method parameters mirror the same-named function in
`canvas.shapes`/`canvas.path`, minus `supersample`: a raster
implementation picks its own supersample factor, and a vector one has
no equivalent knob. `fill_path_aa` does take a `fill_rule`,
defaulting to `EVEN_ODD` as the raster function does, because the two
backends would otherwise disagree on a path with more than one
sub-path: SVG's own default is nonzero, so a hole that even-odd
punches in a PNG would fill solid in the SVG unless the element says
`fill-rule="evenodd"`.

The transform state is on the trait too: `save`/`restore`,
`translate`/`rotate`/`scale`/`transform`/`set_transform`/
`reset_transform`, `current_transform` and `has_transform`, with the
semantics `Canvas` defines (see `Canvas.save`). A mark drawn through
the trait can set up a local frame -- translate to a panel, rotate for
a wedge -- and draw at the origin on either backend. `SvgCanvas` puts
the current matrix on each element as a `transform` attribute. One
rule holds on both: strokes are built in user space, so under a
`scale` a stroke's width, dashes and caps scale with the shape; the
state is for placement and rotation, and data still maps through
scales.

The blend mode is on the trait as well: `set_blend_mode` and
`blend_mode`, carried by `save`/`restore`, with the formulas in
canvas/blend.mojo. `SvgCanvas` emits the six separable modes as
`mix-blend-mode` and draws the Porter-Duff operators source-over,
since CSS has no keyword for them.

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

from canvas.blend import BlendMode
from canvas.color import Color
from canvas.fill_rule import FillRule
from canvas.geometry import Matrix2D
from canvas.path import Path
from canvas.gradient import LinearGradient
from canvas.shapes.lines import LineCap, LineJoin


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
        dashes: List[Float64] = List[Float64](),
        dash_offset: Float64 = 0.0,
        cap: LineCap = LineCap.ROUND,
        join: LineJoin = LineJoin.ROUND,
        miter_limit: Float64 = 4.0,
    ):
        """An anti-aliased line, round-capped by default.

        Args:
            x0: Start point x.
            y0: Start point y.
            x1: End point x.
            y1: End point y.
            color: Line color.
            width: Stroke width in pixels.
            dashes: On/off segment lengths in user-space pixels, cycled
                along the line. Empty (default) draws a solid line.
            dash_offset: Distance into the dash pattern the line starts
                at.
            cap: How the two ends are finished -- see LineCap.
            join: Unused for a single segment, which has no corners.
            miter_limit: Unused for a single segment.
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

    def draw_circle_aa(
        mut self,
        cx: Float64,
        cy: Float64,
        radius: Float64,
        color: Color,
        width: Float64 = 1.0,
    ):
        """An anti-aliased circle outline, `width` pixels wide (default
        1), at a sub-pixel center and radius.

        Args:
            cx: Center x, sub-pixel.
            cy: Center y, sub-pixel.
            radius: Circle radius in pixels, to the middle of the
                stroke.
            color: Outline color.
            width: Stroke width in pixels.
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

    def draw_ellipse_aa(
        mut self,
        cx: Float64,
        cy: Float64,
        rx: Float64,
        ry: Float64,
        color: Color,
        width: Float64 = 1.0,
    ):
        """An anti-aliased ellipse outline, `width` pixels wide
        (default 1), at a sub-pixel center and radii.

        Args:
            cx: Center x, sub-pixel.
            cy: Center y, sub-pixel.
            rx: Horizontal radius in pixels, to the middle of the
                stroke.
            ry: Vertical radius in pixels, to the middle of the
                stroke.
            color: Outline color.
            width: Stroke width in pixels.
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
        mut self,
        path: Path,
        color: Color,
        width: Float64 = 1.0,
        dashes: List[Float64] = List[Float64](),
        dash_offset: Float64 = 0.0,
        cap: LineCap = LineCap.ROUND,
        join: LineJoin = LineJoin.ROUND,
        miter_limit: Float64 = 4.0,
    ):
        """An anti-aliased stroke of a Path's outline.

        Args:
            path: Path to stroke.
            color: Stroke color.
            width: Stroke width in pixels.
            dashes: On/off segment lengths in user-space pixels, cycled
                along the stroke. Empty (default) draws a solid line.
            dash_offset: Distance into the dash pattern the stroke
                starts at.
            cap: How an open sub-path's two ends are finished -- see
                LineCap.
            join: How corners are turned -- see LineJoin.
            miter_limit: Ratio past which a MITER join falls back to
                BEVEL, as a multiple of half the stroke width.
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

    def save(mut self):
        """Push the current transform (and, on a backend that clips,
        the clip state) for `restore` to put back.
        """
        ...

    def restore(mut self):
        """Pop what `save` pushed. A no-op with nothing saved."""
        ...

    def translate(mut self, tx: Float64, ty: Float64):
        """Shift subsequent drawing by (tx, ty) in the current user
        space.

        Args:
            tx: Horizontal shift.
            ty: Vertical shift.
        """
        ...

    def rotate(mut self, angle: Float64):
        """Turn subsequent drawing by `angle` radians about the current
        origin; positive is clockwise on screen.

        Args:
            angle: Radians.
        """
        ...

    def scale(mut self, sx: Float64, sy: Float64):
        """Scale subsequent drawing about the current origin, each
        axis by its own factor.

        Args:
            sx: Horizontal factor.
            sy: Vertical factor.
        """
        ...

    def transform(mut self, matrix: Matrix2D):
        """Compose `matrix` into the current transform, applied to
        coordinates before everything already in place.

        Args:
            matrix: The map to apply first.
        """
        ...

    def set_transform(mut self, matrix: Matrix2D):
        """Replace the current transform outright.

        Args:
            matrix: The new map from user space to the backend's
                own coordinates.
        """
        ...

    def reset_transform(mut self):
        """Back to the identity."""
        ...

    def current_transform(self) -> Matrix2D:
        """The map every drawing call currently applies.

        Returns:
            The current transform; the identity if none is set.
        """
        ...

    def has_transform(self) -> Bool:
        """Whether the current transform is anything but the identity.

        Returns:
            True if drawing is being mapped.
        """
        ...

    def set_blend_mode(mut self, mode: BlendMode):
        """Set how later drawing calls combine with what is already
        there. `save`/`restore` carry the mode. A backend that cannot
        express a mode draws source-over and says so in its docstring
        (`SvgCanvas` has no attribute for the Porter-Duff operators).

        Args:
            mode: The blend mode later calls use.
        """
        ...

    def blend_mode(self) -> BlendMode:
        """The blend mode later drawing calls will use.

        Returns:
            The current mode, `BlendMode.SOURCE_OVER` until
            `set_blend_mode` says otherwise.
        """
        ...
