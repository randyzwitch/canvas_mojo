"""A `DrawTarget` that draws nothing and remembers where the ink would
have gone: `BoundsTarget`.

A caller generic over the trait renders its scene into one of these,
reads the box back, and then renders for real into a target sized to
that box -- the `bbox_inches="tight"` of a figure export, on every
backend. It exists because nothing else can answer the question. A
raster `Canvas` can be scanned for non-background pixels, but
`SvgCanvas` and `PdfCanvas` hold markup and operators with nothing to
scan, and the extents that matter are per-primitive knowledge this
package holds and a consumer would otherwise reproduce by hand: a
stroke's box is its outline with the width, caps and joins
(`Path.stroke_bounds`), an arc's needs the flattening the fill uses,
text's needs the font metrics and the layout `draw_text` performs
(`measure_text_block`) (#460).

It is the same idea `measure_text` is -- a layout you can ask about
without drawing -- and it lives beside the three drawing backends as a
fourth conformer rather than as a running box inside each of them, so
no existing backend gains an invariant to keep, only callers that ask
pay, and a primitive added to the trait later fails to compile here
rather than silently contributing no extent.

## What the box is

Two readings of one union, both in the target's own coordinates after
the transform in force at each call:

- `ink_bounds()` is geometric: the smallest axis-aligned box, in
  `Float64`, around every shape's outline as the fills flatten it.
- `ink_pixels()` is that box as whole pixels: every pixel whose square
  `[k - 0.5, k + 0.5]` the geometry enters, which is the set an
  anti-aliased edge can give coverage to. The rule is stated once, in
  `_PIXEL_HALF`, and `tests/test_bounds.mojo` pins it against a raster
  scan of the same scene: the scan is a subset of this box, and this
  box is at most one pixel wider on any side. Erring outward is the
  right direction for a crop, since a box that excludes a barely-inked
  pixel shaves the edge it was cropping to.

`has_ink()` tells a scene with nothing drawn from one with a box at
the origin. Both readings are clipped to the page -- `BoundsTarget(w,
h)` inks nothing outside `[0, w) x [0, h)` -- and to any `push_clip`
in force, so a shape drawn wholly outside a clip contributes nothing.

## What is exact and what is generous

Under no transform, a translation, or an axis-aligned scale every
primitive's box is the box the raster backend inks: rectangles snap
the way `fill_rect` snaps, disks and wedges flatten the way the fills
flatten, strokes are measured on their own outline, text on its
laid-out block. Under a rotation or a skew three things are measured
as the bounding box of a mapped bounding box, which is never smaller
than the ink and can be larger: a stroke under a skew, a text block
under any rotation of the *canvas* (the block's own `rotation` is
exact), and a rectangular clip. A chart's tight crop is an unrotated
page, so this is the case that matters least.

Blend mode and color space are carried for `save`/`restore` and
otherwise ignored: `CLEAR` or `DESTINATION_OUT` still count as ink,
since the box answers where a primitive drew, not what it left.

## Measuring a scene that has a background

A full-page background fill is ink like any other, so a scene that
paints one measures as the whole page and a crop to that box is a
no-op. A caller measuring for a tight crop should draw the scene
without its background and paint the background into the cropped
target afterwards. The same applies to any mark placed to cover the
page rather than to be seen, such as a border drawn at the edges.
"""

from std.math import cos, sin, floor, ceil

from canvas.blend import BlendMode
from canvas.buffer import Canvas
from canvas.color import Color, ColorSpace
from canvas.fill_rule import FillRule
from canvas.geometry import FPoint, Matrix2D, _snap_rect
from canvas.gradient import LinearGradient
from canvas.path import Path, _through
from canvas.shapes.lines import LineCap, LineJoin
from canvas.text.font_cache import FontCache
from canvas.text.font_discovery import FontSlant, FontWeight
from canvas.text.render import measure_text_block
from canvas.text.text_align import TextAlign
from canvas.vector.draw_target import DrawTarget


# Half a pixel: pixel k is the square [k - 0.5, k + 0.5], the
# convention every rasterizer in the package shares, so a geometric
# extent reaching past k - 0.5 can give pixel k coverage. This is the
# one number `ink_pixels` adds to the geometry, and the raster-scan
# test is what defines it: if it and the rasterizers ever disagreed,
# the scan would find a covered pixel outside the box.
comptime _PIXEL_HALF = 0.5


struct _Box(ImplicitlyCopyable, Movable):
    """A geometric axis-aligned box, (min_x, min_y, max_x, max_y)."""

    var min_x: Float64
    var min_y: Float64
    var max_x: Float64
    var max_y: Float64

    def __init__(
        out self, min_x: Float64, min_y: Float64, max_x: Float64, max_y: Float64
    ):
        self.min_x = min_x
        self.min_y = min_y
        self.max_x = max_x
        self.max_y = max_y

    def intersect(self, other: _Box) -> _Box:
        return _Box(
            max(self.min_x, other.min_x),
            max(self.min_y, other.min_y),
            min(self.max_x, other.max_x),
            min(self.max_y, other.max_y),
        )

    def has_area(self) -> Bool:
        return self.max_x > self.min_x and self.max_y > self.min_y


struct _BoundsState(ImplicitlyCopyable, Movable):
    """What `save` records: the transform, the blend mode, the color
    space and the clip depth."""

    var transform: Matrix2D
    var transformed: Bool
    var blend: BlendMode
    var space: ColorSpace
    var clip_depth: Int

    def __init__(
        out self,
        transform: Matrix2D,
        transformed: Bool,
        blend: BlendMode,
        space: ColorSpace,
        clip_depth: Int,
    ):
        self.transform = transform
        self.transformed = transformed
        self.blend = blend
        self.space = space
        self.clip_depth = clip_depth


def _corners_box(
    m: Matrix2D, x0: Float64, y0: Float64, x1: Float64, y1: Float64
) -> _Box:
    """The axis-aligned box around the four corners of the geometric
    box (x0, y0)-(x1, y1) mapped through `m`. Exact for an axis-aligned
    map; the bounding box of the mapped shape otherwise, which is never
    smaller than it.
    """
    var p = m.apply(x0, y0)
    var min_x = p.x
    var max_x = p.x
    var min_y = p.y
    var max_y = p.y
    for corner in range(1, 4):
        var cx = x1 if corner % 2 == 1 else x0
        var cy = y1 if corner >= 2 else y0
        var q = m.apply(cx, cy)
        min_x = min(min_x, q.x)
        max_x = max(max_x, q.x)
        min_y = min(min_y, q.y)
        max_y = max(max_y, q.y)
    return _Box(min_x, min_y, max_x, max_y)


struct BoundsTarget(DrawTarget, Movable):
    """A `DrawTarget` that keeps the union of what it was asked to draw
    and draws nothing. See this module's docstring for what the box
    means and where it is exact.

    Construct with the page size, draw the scene through the trait,
    then read `has_ink()`, `ink_bounds()` or `ink_pixels()`. A target
    can be reused: `reset()` clears the union and every piece of state.
    """

    var width: Int
    var height: Int
    var _has_ink: Bool
    var _ink: _Box
    var _clips: List[_Box]
    var _transform: Matrix2D
    var _transformed: Bool
    var _blend: BlendMode
    var _space: ColorSpace
    var _saved: List[_BoundsState]

    def __init__(out self, width: Int, height: Int):
        """A measuring target the size of the page a scene will be
        drawn on.

        Args:
            width: Page width in pixels; ink past it does not count.
            height: Page height in pixels.
        """
        self.width = width
        self.height = height
        self._has_ink = False
        self._ink = _Box(0.0, 0.0, 0.0, 0.0)
        self._clips = List[_Box]()
        self._transform = Matrix2D.identity()
        self._transformed = False
        self._blend = BlendMode.SOURCE_OVER
        self._space = ColorSpace.SRGB
        self._saved = List[_BoundsState]()

    # --- Reading the answer ---------------------------------------------

    def has_ink(self) -> Bool:
        """Whether anything drawn so far had positive area inside the
        page and the clips in force when it was drawn.

        Returns:
            True once any primitive contributed an extent.
        """
        return self._has_ink

    def ink_bounds(self) -> Tuple[Float64, Float64, Float64, Float64]:
        """The geometric box around everything drawn, as
        (min_x, min_y, max_x, max_y) in this target's coordinates,
        the convention of `Path.bounds`. All zeros with no ink; check
        `has_ink()` to tell that from a box at the origin.

        Returns:
            (min_x, min_y, max_x, max_y).
        """
        if not self._has_ink:
            return (0.0, 0.0, 0.0, 0.0)
        return (
            self._ink.min_x,
            self._ink.min_y,
            self._ink.max_x,
            self._ink.max_y,
        )

    def ink_pixels(self) -> Tuple[Int, Int, Int, Int]:
        """The whole-pixel box around everything drawn, as
        (x, y, width, height): every pixel whose square the geometry
        enters, which is every pixel an anti-aliased edge can touch.
        Zero size with no ink.

        A crop is `Canvas(width, height)` drawn with `translate(-x, -y)`,
        which lands the ink at the new origin.

        Returns:
            (x, y, width, height), in pixels.
        """
        if not self._has_ink:
            return (0, 0, 0, 0)
        var left = Int(floor(self._ink.min_x + _PIXEL_HALF))
        var top = Int(floor(self._ink.min_y + _PIXEL_HALF))
        var right = Int(ceil(self._ink.max_x - _PIXEL_HALF))
        var bottom = Int(ceil(self._ink.max_y - _PIXEL_HALF))
        # A box that ends exactly on a pixel boundary (max_x = k + 0.5)
        # does not enter pixel k + 1; one ending anywhere inside pixel
        # k's square does enter it. `ceil(max - 0.5)` gives k in both
        # cases; the width is then inclusive of that pixel.
        return (left, top, right - left + 1, bottom - top + 1)

    def reset(mut self):
        """Forget every extent and every piece of state, so the target
        can measure another scene on the same page."""
        self._has_ink = False
        self._ink = _Box(0.0, 0.0, 0.0, 0.0)
        self._clips = List[_Box]()
        self._transform = Matrix2D.identity()
        self._transformed = False
        self._blend = BlendMode.SOURCE_OVER
        self._space = ColorSpace.SRGB
        self._saved = List[_BoundsState]()

    # --- Accumulating -----------------------------------------------------

    def _page(self) -> _Box:
        """The page as a geometric box: the squares of its pixels."""
        return _Box(
            -_PIXEL_HALF,
            -_PIXEL_HALF,
            Float64(self.width) - _PIXEL_HALF,
            Float64(self.height) - _PIXEL_HALF,
        )

    def _clip(self) -> _Box:
        """The box ink is currently confined to: the innermost clip,
        which is already intersected with every outer one and the page.
        """
        if len(self._clips) == 0:
            return self._page()
        return self._clips[len(self._clips) - 1]

    def _add(mut self, box: _Box):
        """Union `box`, a device-space geometric extent, into the ink,
        after confining it to the clip in force. A box with no area
        left contributes nothing.
        """
        var b = box.intersect(self._clip())
        if not b.has_area():
            return
        if not self._has_ink:
            self._ink = b
            self._has_ink = True
            return
        self._ink = _Box(
            min(self._ink.min_x, b.min_x),
            min(self._ink.min_y, b.min_y),
            max(self._ink.max_x, b.max_x),
            max(self._ink.max_y, b.max_y),
        )

    def _add_path(mut self, path: Path):
        """A filled path's extent: its flattened outline under the
        transform, as `fill_path_aa` draws it."""
        var b: Tuple[Float64, Float64, Float64, Float64]
        if self._transformed:
            b = _through(path, self._transform).bounds()
        else:
            b = path.bounds()
        self._add(_Box(b[0], b[1], b[2], b[3]))

    def _add_stroke(
        mut self,
        path: Path,
        width: Float64,
        dashes: List[Float64],
        dash_offset: Float64,
        cap: LineCap,
        join: LineJoin,
        miter_limit: Float64,
    ):
        """A stroke's extent: `Path.stroke_bounds` with the same style,
        so caps, joins and a dash pattern ending short all count.
        Strokes are built in user space and scale with the transform,
        so under a similarity the path is mapped and the width and
        dashes scaled, which is exact; under a skew the user-space box
        is mapped corner by corner, which is generous.
        """
        if not self._transformed:
            var b = path.stroke_bounds(
                width, 0, dashes, dash_offset, cap, join, miter_limit
            )
            self._add(_Box(b[0], b[1], b[2], b[3]))
            return
        var m = self._transform
        if m.is_similarity():
            var s = m.scale_factor()
            var scaled = List[Float64](capacity=len(dashes))
            for i in range(len(dashes)):
                scaled.append(dashes[i] * s)
            var b = _through(path, m).stroke_bounds(
                width * s, 0, scaled, dash_offset * s, cap, join, miter_limit
            )
            self._add(_Box(b[0], b[1], b[2], b[3]))
            return
        var b = path.stroke_bounds(
            width, 0, dashes, dash_offset, cap, join, miter_limit
        )
        self._add(_corners_box(m, b[0], b[1], b[2], b[3]))

    def _add_rect(mut self, x: Float64, y: Float64, w: Float64, h: Float64):
        """A geometric rectangle the way `fill_rect` places it: edges
        snapped to pixel boundaries under no transform or an
        axis-aligned one, a path under any other."""
        if w <= 0.0 or h <= 0.0:
            return
        var m = self._transform
        if not self._transformed or m.is_axis_aligned():
            var p0 = m.apply(x, y)
            var p1 = m.apply(x + w, y + h)
            var r = _snap_rect(p0.x, p0.y, p1.x, p1.y)
            if r[2] <= 0 or r[3] <= 0:
                return
            self._add(
                _Box(
                    Float64(r[0]) - _PIXEL_HALF,
                    Float64(r[1]) - _PIXEL_HALF,
                    Float64(r[0] + r[2]) - _PIXEL_HALF,
                    Float64(r[1] + r[3]) - _PIXEL_HALF,
                )
            )
            return
        var p = Path()
        try:
            p.rect(x, y, w, h)
        except e:
            return
        self._add_path(p)

    def _add_ellipse(
        mut self, cx: Float64, cy: Float64, rx: Float64, ry: Float64
    ):
        """A disk or ellipse as the path the fills fall back to."""
        if rx <= 0.0 or ry <= 0.0:
            return
        var p = Path()
        try:
            p.ellipse(cx, cy, rx, ry)
        except e:
            return
        self._add_path(p)

    def _add_wedge(
        mut self,
        cx: Float64,
        cy: Float64,
        radius: Float64,
        start_angle: Float64,
        end_angle: Float64,
    ):
        """`fill_arc_aa`'s pie wedge: center, out to the arc's start,
        round the arc, and back."""
        if radius <= 0.0 or end_angle <= start_angle:
            return
        var p = Path()
        try:
            p.move_to(cx, cy)
            p.line_to(
                cx + radius * cos(start_angle), cy + radius * sin(start_angle)
            )
            p.arc_to(cx, cy, radius, start_angle, end_angle)
            p.close()
        except e:
            return
        self._add_path(p)

    # --- The trait: shapes ------------------------------------------------

    def fill_rect(
        mut self, x: Int, y: Int, width: Int, height: Int, color: Color
    ):
        """The pixels x through x + width - 1 by y through y + height - 1.

        Args:
            x: First column.
            y: First row.
            width: Columns.
            height: Rows.
            color: Ignored.
        """
        self._add_rect(
            Float64(x) - _PIXEL_HALF,
            Float64(y) - _PIXEL_HALF,
            Float64(width),
            Float64(height),
        )

    def fill_rect(
        mut self,
        x: Float64,
        y: Float64,
        width: Float64,
        height: Float64,
        color: Color,
    ):
        """The geometric box from (x, y) spanning width x height,
        snapped the way `fill_rect` snaps it.

        Args:
            x: Left edge.
            y: Top edge.
            width: Width.
            height: Height.
            color: Ignored.
        """
        self._add_rect(x, y, width, height)

    def fill_rect_gradient(
        mut self,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        gradient: LinearGradient,
    ):
        """As `fill_rect`; the gradient does not change the extent.

        Args:
            x: First column.
            y: First row.
            width: Columns.
            height: Rows.
            gradient: Ignored.
        """
        self._add_rect(
            Float64(x) - _PIXEL_HALF,
            Float64(y) - _PIXEL_HALF,
            Float64(width),
            Float64(height),
        )

    def fill_rect_gradient(
        mut self,
        x: Float64,
        y: Float64,
        width: Float64,
        height: Float64,
        gradient: LinearGradient,
    ):
        """As `fill_rect`; the gradient does not change the extent.

        Args:
            x: Left edge.
            y: Top edge.
            width: Width.
            height: Height.
            gradient: Ignored.
        """
        self._add_rect(x, y, width, height)

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
        """A stroked segment between two pixel centers, with its caps.

        Args:
            x0: Start point x.
            y0: Start point y.
            x1: End point x.
            y1: End point y.
            color: Ignored.
            width: Stroke width in pixels.
            dashes: On/off segment lengths; a pattern ending short of
                the line ends the box short too.
            dash_offset: Distance into the dash pattern the line starts at.
            cap: How the two ends are finished.
            join: Unused for a single segment.
            miter_limit: Unused for a single segment.
        """
        self.draw_line_aa(
            Float64(x0),
            Float64(y0),
            Float64(x1),
            Float64(y1),
            color,
            width,
            dashes,
            dash_offset,
            cap,
            join,
            miter_limit,
        )

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
        """A stroked segment between sub-pixel endpoints, with its caps.

        Args:
            x0: Start point x.
            y0: Start point y.
            x1: End point x.
            y1: End point y.
            color: Ignored.
            width: Stroke width in pixels.
            dashes: On/off segment lengths.
            dash_offset: Distance into the dash pattern the line starts at.
            cap: How the two ends are finished.
            join: Unused for a single segment.
            miter_limit: Unused for a single segment.
        """
        var p = Path()
        try:
            p.move_to(x0, y0)
            p.line_to(x1, y1)
        except e:
            return
        self._add_stroke(p, width, dashes, dash_offset, cap, join, miter_limit)

    def fill_circle_aa(mut self, cx: Int, cy: Int, radius: Int, color: Color):
        """A disk centered on a pixel center.

        Args:
            cx: Center x.
            cy: Center y.
            radius: Radius in pixels.
            color: Ignored.
        """
        self._add_ellipse(
            Float64(cx), Float64(cy), Float64(radius), Float64(radius)
        )

    def fill_circle_aa(
        mut self, cx: Float64, cy: Float64, radius: Float64, color: Color
    ):
        """A disk at a sub-pixel center.

        Args:
            cx: Center x.
            cy: Center y.
            radius: Radius in pixels.
            color: Ignored.
        """
        self._add_ellipse(cx, cy, radius, radius)

    def fill_circles_aa(
        mut self,
        centers: List[FPoint],
        radius: Float64,
        color: Color,
    ) raises:
        """Every disk of a bulk marker call.

        Args:
            centers: Disk centers.
            radius: Shared radius.
            color: Ignored.
        """
        for i in range(len(centers)):
            self._add_ellipse(centers[i].x, centers[i].y, radius, radius)

    def fill_circles_aa(
        mut self,
        centers: List[FPoint],
        radius: Float64,
        colors: List[Color],
    ) raises:
        """Every disk of a bulk marker call with a color per disk.

        Args:
            centers: Disk centers.
            radius: Shared radius.
            colors: Ignored.
        """
        for i in range(len(centers)):
            self._add_ellipse(centers[i].x, centers[i].y, radius, radius)

    def _add_mesh(mut self, points: List[FPoint], faces: List[Int]) raises:
        """The box around every vertex a face references, mapped; a
        vertex no face uses is not drawn and does not count.

        Raises:
            Error: A face index is out of range.
        """
        if len(faces) == 0:
            return
        var m = self._transform
        var seen = False
        var min_x = 0.0
        var min_y = 0.0
        var max_x = 0.0
        var max_y = 0.0
        for i in range(len(faces)):
            var idx = faces[i]
            if idx < 0 or idx >= len(points):
                raise Error(
                    "fill_mesh: face index "
                    + String(idx)
                    + " is outside the "
                    + String(len(points))
                    + " points"
                )
            var q = m.apply(points[idx].x, points[idx].y)
            if not seen:
                min_x = q.x
                max_x = q.x
                min_y = q.y
                max_y = q.y
                seen = True
                continue
            min_x = min(min_x, q.x)
            max_x = max(max_x, q.x)
            min_y = min(min_y, q.y)
            max_y = max(max_y, q.y)
        if seen:
            self._add(_Box(min_x, min_y, max_x, max_y))

    def fill_mesh(
        mut self,
        points: List[FPoint],
        faces: List[Int],
        colors: List[Color],
    ) raises:
        """The box around every vertex a face references.

        Args:
            points: Vertices.
            faces: Index triples.
            colors: Ignored.

        Raises:
            Error: A face index is out of range.
        """
        self._add_mesh(points, faces)

    def fill_mesh_shaded(
        mut self,
        points: List[FPoint],
        faces: List[Int],
        vertex_colors: List[Color],
    ) raises:
        """The box around every vertex a face references.

        Args:
            points: Vertices.
            faces: Index triples.
            vertex_colors: Ignored.

        Raises:
            Error: A face index is out of range.
        """
        self._add_mesh(points, faces)

    def fill_ellipses_aa(
        mut self,
        centers: List[FPoint],
        rx: Float64,
        ry: Float64,
        color: Color,
    ) raises:
        """Every ellipse of a bulk marker call.

        Args:
            centers: Ellipse centers.
            rx: Shared horizontal radius.
            ry: Shared vertical radius.
            color: Ignored.
        """
        for i in range(len(centers)):
            self._add_ellipse(centers[i].x, centers[i].y, rx, ry)

    def fill_ellipses_aa(
        mut self,
        centers: List[FPoint],
        rx: Float64,
        ry: Float64,
        colors: List[Color],
    ) raises:
        """Every ellipse of a bulk marker call with a color per ellipse.

        Args:
            centers: Ellipse centers.
            rx: Shared horizontal radius.
            ry: Shared vertical radius.
            colors: Ignored.
        """
        for i in range(len(centers)):
            self._add_ellipse(centers[i].x, centers[i].y, rx, ry)

    def draw_circle_aa(
        mut self,
        cx: Float64,
        cy: Float64,
        radius: Float64,
        color: Color,
        width: Float64 = 1.0,
    ):
        """A ring: the disk out to the stroke's outer edge, which is
        the radius plus half the width.

        Args:
            cx: Center x.
            cy: Center y.
            radius: Radius to the middle of the stroke.
            color: Ignored.
            width: Stroke width.
        """
        var half = width * 0.5
        self._add_ellipse(cx, cy, radius + half, radius + half)

    def fill_ellipse_aa(
        mut self, cx: Int, cy: Int, rx: Int, ry: Int, color: Color
    ):
        """An ellipse centered on a pixel center.

        Args:
            cx: Center x.
            cy: Center y.
            rx: Horizontal radius.
            ry: Vertical radius.
            color: Ignored.
        """
        self._add_ellipse(Float64(cx), Float64(cy), Float64(rx), Float64(ry))

    def fill_ellipse_aa(
        mut self,
        cx: Float64,
        cy: Float64,
        rx: Float64,
        ry: Float64,
        color: Color,
    ):
        """An ellipse at a sub-pixel center.

        Args:
            cx: Center x.
            cy: Center y.
            rx: Horizontal radius.
            ry: Vertical radius.
            color: Ignored.
        """
        self._add_ellipse(cx, cy, rx, ry)

    def draw_ellipse_aa(
        mut self, cx: Int, cy: Int, rx: Int, ry: Int, color: Color
    ):
        """A one-pixel ellipse outline centered on a pixel center.

        Args:
            cx: Center x.
            cy: Center y.
            rx: Horizontal radius to the middle of the stroke.
            ry: Vertical radius to the middle of the stroke.
            color: Ignored.
        """
        self.draw_ellipse_aa(
            Float64(cx), Float64(cy), Float64(rx), Float64(ry), color, 1.0
        )

    def draw_ellipse_aa(
        mut self,
        cx: Float64,
        cy: Float64,
        rx: Float64,
        ry: Float64,
        color: Color,
        width: Float64 = 1.0,
    ):
        """An ellipse outline: the ellipse out to the stroke's outer
        edge.

        Args:
            cx: Center x.
            cy: Center y.
            rx: Horizontal radius to the middle of the stroke.
            ry: Vertical radius to the middle of the stroke.
            color: Ignored.
            width: Stroke width.
        """
        var half = width * 0.5
        self._add_ellipse(cx, cy, rx + half, ry + half)

    def fill_arc_aa(
        mut self,
        cx: Float64,
        cy: Float64,
        radius: Float64,
        start_angle: Float64,
        end_angle: Float64,
        color: Color,
    ):
        """A pie wedge, flattened the way the fill flattens it.

        Args:
            cx: Center x.
            cy: Center y.
            radius: Wedge radius.
            start_angle: Sweep start, radians.
            end_angle: Sweep end, radians.
            color: Ignored.
        """
        self._add_wedge(cx, cy, radius, start_angle, end_angle)

    def fill_arcs_aa(
        mut self,
        centers: List[FPoint],
        radius: Float64,
        start_angle: Float64,
        end_angle: Float64,
        color: Color,
    ) raises:
        """Every wedge of a bulk call.

        Args:
            centers: Wedge centers.
            radius: Shared radius.
            start_angle: Shared sweep start, radians.
            end_angle: Shared sweep end, radians.
            color: Ignored.
        """
        for i in range(len(centers)):
            self._add_wedge(
                centers[i].x, centers[i].y, radius, start_angle, end_angle
            )

    def fill_arcs_aa(
        mut self,
        centers: List[FPoint],
        radius: Float64,
        start_angle: Float64,
        end_angle: Float64,
        colors: List[Color],
    ) raises:
        """Every wedge of a bulk call with a color per wedge.

        Args:
            centers: Wedge centers.
            radius: Shared radius.
            start_angle: Shared sweep start, radians.
            end_angle: Shared sweep end, radians.
            colors: Ignored.
        """
        for i in range(len(centers)):
            self._add_wedge(
                centers[i].x, centers[i].y, radius, start_angle, end_angle
            )

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
        """A ring segment: along the outer arc, in to the inner arc
        and back along it, flattened the way the fill flattens it.

        Args:
            cx: Center x.
            cy: Center y.
            inner_radius: Radius of the hole.
            outer_radius: Outer radius.
            start_angle: Sweep start, radians.
            end_angle: Sweep end, radians.
            color: Ignored.
        """
        if outer_radius <= 0.0 or end_angle <= start_angle:
            return
        if inner_radius <= 0.0:
            self._add_wedge(cx, cy, outer_radius, start_angle, end_angle)
            return
        var p = Path()
        try:
            p.move_to(
                cx + outer_radius * cos(start_angle),
                cy + outer_radius * sin(start_angle),
            )
            p.arc_to(cx, cy, outer_radius, start_angle, end_angle)
            p.line_to(
                cx + inner_radius * cos(end_angle),
                cy + inner_radius * sin(end_angle),
            )
            p.arc_to(cx, cy, inner_radius, end_angle, start_angle)
            p.close()
        except e:
            return
        self._add_path(p)

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
        """A stroke's outline with its caps and joins: `Path.stroke_bounds`
        with the same style.

        Args:
            path: The path to stroke.
            color: Ignored.
            width: Stroke width in pixels.
            dashes: On/off segment lengths.
            dash_offset: Distance into the dash pattern the stroke starts at.
            cap: How open sub-paths end.
            join: How corners are turned; a MITER spike counts.
            miter_limit: Ratio past which MITER falls back to BEVEL.
        """
        self._add_stroke(
            path, width, dashes, dash_offset, cap, join, miter_limit
        )

    def fill_path_aa(
        mut self,
        path: Path,
        color: Color,
        fill_rule: FillRule = FillRule.EVEN_ODD,
    ):
        """A filled path's flattened outline. The fill rule cannot
        change the outer box, so it is ignored.

        Args:
            path: The path to fill.
            color: Ignored.
            fill_rule: Ignored.
        """
        self._add_path(path)

    def draw_image(
        mut self,
        image: Canvas,
        x: Float64,
        y: Float64,
        width: Float64 = 0.0,
        height: Float64 = 0.0,
    ) raises:
        """The box the image is scaled to, placed as a `fill_rect` at
        the same coordinates would be.

        Args:
            image: The pixels; only its size is read.
            x: Left edge in user space.
            y: Top edge in user space.
            width: Drawn width, or 0 for `image.width`.
            height: Drawn height, or 0 for `image.height`.
        """
        if image.width <= 0 or image.height <= 0:
            return
        var w = width if width > 0.0 else Float64(image.width)
        var h = height if height > 0.0 else Float64(image.height)
        self._add_rect(x, y, w, h)

    def draw_text(
        mut self,
        x: Float64,
        y: Float64,
        text: String,
        color: Color,
        size: Float64,
        family: String = "Sans",
        slant: FontSlant = FontSlant.NORMAL,
        weight: FontWeight = FontWeight.NORMAL,
        rotation: Float64 = 0.0,
        align: TextAlign = TextAlign.LEFT,
        *,
        mut cache: FontCache,
    ) raises:
        """The block `draw_text` would lay out, from `measure_text_block`
        with the same font, alignment and rotation, then mapped through
        the transform. Exact up to a canvas rotation, which maps the
        block's box corner by corner.

        Args:
            x: Anchor x.
            y: Anchor y.
            text: The text, newline-separated lines.
            color: Ignored.
            size: Font size in points.
            family: Font family name or generic alias.
            slant: Requested style.
            weight: Requested weight.
            rotation: Radians about the anchor.
            align: Horizontal alignment of each line.
            cache: Font cache to resolve and measure through.

        Raises:
            Error: No font resolves for `family`.
        """
        if text == "":
            return
        var block = measure_text_block(
            text, size, family, slant, weight, rotation, align, cache=cache
        )
        if block.width <= 0.0 or block.height <= 0.0:
            return
        var x0 = x + block.x
        var y0 = y + block.y
        self._add(
            _corners_box(
                self._transform, x0, y0, x0 + block.width, y0 + block.height
            )
        )

    # --- The trait: clips, groups, batches --------------------------------

    def push_clip(mut self, x: Int, y: Int, width: Int, height: Int):
        """Confine what follows to a rectangle of pixels, under the
        transform, intersected with the clip already in force. A shape
        wholly outside contributes nothing until `pop_clip`.

        Args:
            x: First column.
            y: First row.
            width: Columns.
            height: Rows.
        """
        var x0 = Float64(x) - _PIXEL_HALF
        var y0 = Float64(y) - _PIXEL_HALF
        var box = _corners_box(
            self._transform, x0, y0, x0 + Float64(width), y0 + Float64(height)
        )
        self._clips.append(box.intersect(self._clip()))

    def pop_clip(mut self):
        """Undo the innermost `push_clip`; a no-op with none pushed."""
        if len(self._clips) > 0:
            _ = self._clips.pop()

    def begin_annotated_group(mut self, title: String):
        """A label, which draws nothing here.

        Args:
            title: Ignored.
        """
        pass

    def end_annotated_group(mut self):
        """Ends a label; nothing to do."""
        pass

    def begin_batch(mut self):
        """Nothing is deferred here, so nothing to begin."""
        pass

    def end_batch(mut self):
        """Nothing was deferred, so nothing to draw."""
        pass

    # --- The trait: state -------------------------------------------------

    def save(mut self):
        """Record the transform, blend mode, color space and clip depth
        for `restore`."""
        self._saved.append(
            _BoundsState(
                self._transform,
                self._transformed,
                self._blend,
                self._space,
                len(self._clips),
            )
        )

    def restore(mut self):
        """Put back what the matching `save` recorded, popping any clip
        pushed since. A no-op with nothing saved."""
        if len(self._saved) == 0:
            return
        var state = self._saved.pop()
        while len(self._clips) > state.clip_depth:
            _ = self._clips.pop()
        self._transform = state.transform
        self._transformed = state.transformed
        self._blend = state.blend
        self._space = state.space

    def _set_transform(mut self, matrix: Matrix2D):
        self._transform = matrix
        self._transformed = not matrix.is_identity()

    def translate(mut self, tx: Float64, ty: Float64):
        """Shift user space.

        Args:
            tx: Horizontal shift.
            ty: Vertical shift.
        """
        self.transform(Matrix2D.translation(tx, ty))

    def rotate(mut self, angle: Float64):
        """Rotate user space about its origin.

        Args:
            angle: Radians.
        """
        self.transform(Matrix2D.rotation(angle))

    def scale(mut self, sx: Float64, sy: Float64):
        """Scale user space.

        Args:
            sx: Horizontal factor.
            sy: Vertical factor.
        """
        self.transform(Matrix2D.scaling(sx, sy))

    def transform(mut self, matrix: Matrix2D):
        """Compose `matrix` before the current transform, the order
        `Canvas.transform` composes in.

        Args:
            matrix: The map to apply first.
        """
        self._set_transform(matrix.then(self._transform))

    def set_transform(mut self, matrix: Matrix2D):
        """Replace the transform.

        Args:
            matrix: The new map from user space to page pixels.
        """
        self._set_transform(matrix)

    def reset_transform(mut self):
        """Back to the identity."""
        self._set_transform(Matrix2D.identity())

    def current_transform(self) -> Matrix2D:
        """The transform in force.

        Returns:
            The current transform; the identity if none is set.
        """
        return self._transform

    def has_transform(self) -> Bool:
        """Whether the transform is anything but the identity.

        Returns:
            True if a transform is in force.
        """
        return self._transformed

    def set_blend_mode(mut self, mode: BlendMode):
        """Carried for `save`/`restore`; every mode counts as ink.

        Args:
            mode: The mode to record.
        """
        self._blend = mode

    def blend_mode(self) -> BlendMode:
        """The recorded blend mode.

        Returns:
            The mode last set, SOURCE_OVER by default.
        """
        return self._blend

    def set_color_space(mut self, space: ColorSpace):
        """Carried for `save`/`restore`; the space changes no extent.

        Args:
            space: The space to record.
        """
        self._space = space

    def color_space(self) -> ColorSpace:
        """The recorded color space.

        Returns:
            The space last set, SRGB by default.
        """
        return self._space
