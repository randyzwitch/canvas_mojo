"""DrawTarget: the drawing-primitive interface a higher-level charting
layer renders through, so a plot/scale/theme layer can target a raster
`Canvas`, a vector `SvgCanvas` or a `PdfCanvas` page without knowing
which it holds. Neither vector backend has a fixed pixel resolution,
so nothing rendered through the trait deals in supersampling.

Twelve drawing primitives are declared -- `fill_rect`,
`fill_rect_gradient`, `draw_line_aa`, `fill_circle_aa`,
`fill_circles_aa`, `draw_circle_aa`, `fill_ellipse_aa`,
`draw_ellipse_aa`, `fill_arc_aa`, `fill_ring_sector_aa`,
`stroke_path_aa` and `fill_path_aa` -- a subset of `canvas.shapes`.
`fill_circles_aa` is the one that is not a distinct shape: it is
`fill_circle_aa` in bulk, on the trait because a generic caller has no
other way to reach the raster backend's batched path. `fill_polygon`, clipping, radial gradients and
path-shaped gradients are not on the trait; each exists as a free
function or a `Canvas` method instead. The two strokes, `draw_line_aa`
and `stroke_path_aa`, take the full stroke style -- `dashes`,
`dash_offset`, `cap`, `join`, `miter_limit` -- so a dashed series or a
square-capped rule renders the same way on every backend.

Circle and ellipse outlines take sub-pixel centers and radii plus a
stroke width. They do not support dashes.

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
a wedge -- and draw at the origin on any backend. `SvgCanvas` puts
the current matrix on each element as a `transform` attribute and
`PdfCanvas` as a `cm` inside the element's `q`/`Q` pair. One
rule holds on both: strokes are built in user space, so under a
`scale` a stroke's width, dashes and caps scale with the shape; the
state is for placement and rotation, and data still maps through
scales.

Placement is one rule on every backend. Pixel (px, py) is centered at
(px, py) and spans half a pixel each way. `Int` arguments are pixel
indices: a rectangle from column x with width w covers pixels x
through x + w - 1, whose geometric edges are x - 0.5 and x + w - 0.5;
a circle's center (cx, cy) is a pixel's center. `Float64` arguments
are geometry: a rectangle from x spanning w has edges at x and x + w,
and `fill_rect` snaps each edge to the nearest pixel boundary, so
`fill_rect(19.5, 4.5, 40.0, 30.0)` and `fill_rect(20, 5, 40, 30)` are
the same call. Under a transform every primitive maps its geometry --
an `Int` rectangle maps its edges at x - 0.5, not x -- and a
rectangle then snaps in the space it is drawn in: device space on
`Canvas`, user space on `SvgCanvas` and `PdfCanvas`, which have no
device pixels. That one rule is what makes the supersampling recipe on
`downsample` exact for rectangles as well as paths and text.

The blend mode is on the trait as well: `set_blend_mode` and
`blend_mode`, carried by `save`/`restore`, with the formulas in
canvas/blend.mojo. `SvgCanvas` emits the blend modes as
`mix-blend-mode` and draws the Porter-Duff operators source-over,
since CSS has no keyword for them; `PdfCanvas` emits them as an
`ExtGState` `/BM`. So is the color space -- `set_color_space` and
`color_space` -- which decides whether a later source-over blend mixes
in sRGB or linear light.

`begin_annotated_group` and `end_annotated_group` label the enclosed
drawing. SVG and PDF preserve the label; `Canvas` treats both calls as
no-ops.

Text is backend-specific and is not part of this trait.

Conformance is nominal, not structural: `Canvas` (`canvas/buffer.mojo`),
`SvgCanvas` (`canvas/vector/svg.mojo`) and `PdfCanvas`
(`canvas/vector/pdf.mojo`) each name `DrawTarget` in their struct
declaration.
"""

from canvas.blend import BlendMode
from canvas.color import Color, ColorSpace
from canvas.fill_rule import FillRule
from canvas.geometry import FPoint, Matrix2D
from canvas.path import Path
from canvas.gradient import LinearGradient
from canvas.shapes.lines import LineCap, LineJoin


trait DrawTarget:
    def fill_rect(
        mut self, x: Int, y: Int, width: Int, height: Int, color: Color
    ):
        """Fill the pixels x through x + width - 1 by y through
        y + height - 1 with a solid color.

        Args:
            x: First column.
            y: First row.
            width: Columns.
            height: Rows.
            color: Fill color.
        """
        ...

    def fill_rect(
        mut self,
        x: Float64,
        y: Float64,
        width: Float64,
        height: Float64,
        color: Color,
    ):
        """Fill the geometric box from (x, y) spanning width x height,
        snapped to whole pixels: each edge goes to the nearest pixel
        boundary (pixel k spans k - 0.5 to k + 0.5), so a caller laying
        out in `Float64` gets crisp edges without rounding itself. See
        the placement rule in this module's docstring.

        Args:
            x: Left edge.
            y: Top edge.
            width: Width.
            height: Height.
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
            x: First column.
            y: First row.
            width: Columns.
            height: Rows.
            gradient: Fill source, projected across the rectangle.
        """
        ...

    def fill_rect_gradient(
        mut self,
        x: Float64,
        y: Float64,
        width: Float64,
        height: Float64,
        gradient: LinearGradient,
    ):
        """`fill_rect_gradient` for a geometric box, snapped to whole
        pixels as the `Float64` `fill_rect` is.

        Args:
            x: Left edge.
            y: Top edge.
            width: Width.
            height: Height.
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

    def draw_line_aa(
        mut self,
        x0: Float64,
        y0: Float64,
        x1: Float64,
        y1: Float64,
        color: Color,
        width: Float64 = 1.0,
        dashes: List[Float64] = List[Float64](),
        dash_offset: Float64 = 0.0,
        cap: LineCap = LineCap.ROUND,
        join: LineJoin = LineJoin.ROUND,
        miter_limit: Float64 = 4.0,
    ):
        """An anti-aliased line between sub-pixel endpoints, round-capped
        by default.

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

    def fill_circle_aa(
        mut self, cx: Float64, cy: Float64, radius: Float64, color: Color
    ):
        """An anti-aliased filled disk at a sub-pixel center and
        radius.

        Args:
            cx: Center x, sub-pixel.
            cy: Center y, sub-pixel.
            radius: Circle radius in pixels.
            color: Fill color.
        """
        ...

    def fill_circles_aa(
        mut self,
        centers: List[FPoint],
        radius: Float64,
        color: Color,
    ) raises:
        """Many equal-radius disks in one call, in draw order.

        The same pixels as `fill_circle_aa` per centre, and on the
        raster backend a great deal faster: it splits the canvas
        across cores rather than the markers, which are individually
        far too small to be worth a thread. A vector backend emits one
        element per marker either way, so there the batch is the loop
        and nothing changes but the call.

        On the trait because a caller drawing a scatter through it
        cannot otherwise reach the batched path: Mojo has no way to
        specialize a `[T: DrawTarget]` function on the concrete type,
        so the alternative is a second copy of the marker loop that
        drifts from the first.

        Args:
            centers: Sub-pixel centre of each marker, in draw order.
            radius: Radius shared by every marker, in pixels.
            color: Fill color shared by every marker.
        """
        ...

    def fill_circles_aa(
        mut self,
        centers: List[FPoint],
        radius: Float64,
        colors: List[Color],
    ) raises:
        """`fill_circles_aa` with a color per marker -- a scatter
        whose points carry a color scale.

        The only method on this trait that raises, because it is the
        only one with an argument that can disagree with another:
        `colors` has to be the same length as `centers`, and silently
        drawing the shorter of the two would lose markers.

        Args:
            centers: Sub-pixel centre of each marker, in draw order.
            radius: Radius shared by every marker, in pixels.
            colors: One color per centre, same length as `centers`.
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

    def fill_ellipse_aa(
        mut self,
        cx: Float64,
        cy: Float64,
        rx: Float64,
        ry: Float64,
        color: Color,
    ):
        """An anti-aliased filled ellipse at a sub-pixel center and
        radii.

        Args:
            cx: Center x, sub-pixel.
            cy: Center y, sub-pixel.
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
                The same rule on every backend.
        """
        ...

    def begin_annotated_group(mut self, title: String):
        """Open a group labeled `title`, covering every primitive
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

    def set_color_space(mut self, space: ColorSpace):
        """Set the space later source-over blends mix in (see
        `ColorSpace`). `save`/`restore` carry it. The raster backend
        blends in it; `SvgCanvas` asks the viewer to, with
        `color-interpolation="linearRGB"`.

        Args:
            space: The color space later calls blend in.
        """
        ...

    def color_space(self) -> ColorSpace:
        """The color space later drawing calls will blend in.

        Returns:
            The current space, `ColorSpace.SRGB` until
            `set_color_space` says otherwise.
        """
        ...
