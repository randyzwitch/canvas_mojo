"""A general path type: move/line/quadratic-curve/cubic-curve/arc-to/
close, built up through chained calls, then flattened into straight-
line segments and handed to canvas.shapes' polyline/polygon/fill
machinery rather than reimplementing fill or stroke here.

Coordinates are Float64 (FPoint), not Point's integer pixels, and stay
that way end to end: flattening keeps sub-pixel positions rather than
snapping them to the grid, so `fill_path_aa`'s coverage sweep sees
where an edge actually falls. That matters most for text, which
rasterizes through this path -- a glyph at 12px has most of its
outline landing between pixel centers, and rounding first was visible
as uneven stem widths and wobbling spacing. Measured against a 9x
supersampled reference, dropping the rounding cuts a text line's total
per-pixel error by about 78%, with the worst single pixel going from
209/255 wrong to 39.

The hard-edged consumers (`fill_path`, `stroke_path`, `stroke_path_aa`)
address whole pixels and round at the point of use -- see `_Subpath`.

Quad/cubic flattening picks its step count per segment from that
segment's own curvature, so it suits the curve's size rather than
being a fixed guess. Chords over n equal parameter intervals deviate
from a curve by at most (1/(8n^2)) * max|B''(t)|, and requiring that
stay under a tolerance gives a closed form for n -- a bound rather
than an estimate, so the result is never under-sampled. That matters
because the failure mode of guessing low is a visibly faceted curve:
at the fixed count of 16 this used to use, the large cubic in the
`large_curves` golden scene strays 1.61 pixels from the true curve,
against 0.0196 chosen adaptively. See `_auto_steps` for the
derivation. `curve_steps` remains as an override -- a positive value
forces that many segments, and 0, the default, means "choose per
segment". arc_to is the exception: it
reuses canvas.shapes.arcs' `_arc_fpoints` (radius-proportional step
count), the sub-pixel sampler underneath the `_arc_points` that
draw_arc/fill_arc/fill_ring_sector use, since a fixed count doesn't
stretch across a path-drawn arc's much wider radius range.

A path can hold multiple sub-paths (more than one move_to). fill_path
combines every sub-path's scanline crossings (even-odd), so an outer
shape plus an inner sub-path punches a hole the way 'o' or 'A' need.
stroke_path/stroke_path_aa instead draw each sub-path independently,
closed (draw_polygon) or open (draw_polyline) depending on whether
close() was called.
"""

from std.math import ceil, cos, floor, pi, sin, sqrt

from canvas.buffer import Canvas
from canvas.color import Color
from canvas.geometry import Point, FPoint, Transform2D, _round_to_int
from canvas.gradient import LinearGradient, RadialGradient
from canvas.fill_rule import FillRule, _is_inside
from canvas.aa_crossing import (
    _EdgeTable,
    _sweep_edges_aa,
    _sweep_edges_to_mask,
)
from canvas.shapes.lines import (
    draw_polyline,
    draw_polygon,
    draw_polyline_aa,
    draw_polygon_aa,
    LineCap,
    LineJoin,
)
from canvas.shapes.polygon_fill import _Crossing, _spans_from_crossings
from canvas.shapes.arcs import _arc_fpoints

# Control-point offset for approximating a quarter ellipse with one
# cubic Bezier: 4/3 * (sqrt(2) - 1). Maximum radial error is about
# 0.027% of the radius, which at any size this package draws is far
# below one supersample step.
comptime _KAPPA = 0.5522847498307936

comptime _MOVE_TO = 0
comptime _LINE_TO = 1
comptime _QUAD_TO = 2
comptime _CUBIC_TO = 3
comptime _CLOSE = 4
comptime _ARC_TO = 5


struct _PathCommand(ImplicitlyCopyable, Movable):
    """One path command. Which of p1/p2/p3 matter depends on `kind`:
    move_to/line_to use p1 (endpoint); quad_to uses p1 (control) and p2
    (endpoint); cubic_to uses all three (control1, control2, endpoint);
    close uses none; arc_to packs five scalars across the three points
    -- p1 = (cx, cy), p2 = (radius, start_angle), p3.x = end_angle,
    p3.y unused.

    A tagged struct with unused fields zeroed rather than a union,
    which Mojo has no lightweight form of. The wasted space per command
    doesn't matter at the counts a path here reaches.
    """

    var kind: Int
    var p1: FPoint
    var p2: FPoint
    var p3: FPoint

    def __init__(out self, kind: Int, p1: FPoint, p2: FPoint, p3: FPoint):
        self.kind = kind
        self.p1 = p1
        self.p2 = p2
        self.p3 = p3


struct Path(Movable):
    """Build with move_to/line_to/quad_curve_to/cubic_curve_to/arc_to/
    close, then hand to fill_path/stroke_path/stroke_path_aa. No
    chaining: each call is `mut self` returning nothing, like Canvas's
    push_clip/set_pixel.

    All coordinates are absolute. There are no relative-to-current-
    point variants (SVG/Cairo's rel_line_to and friends).
    """

    var commands: List[_PathCommand]
    var _current_x: Float64
    var _current_y: Float64
    var _subpath_start_x: Float64
    var _subpath_start_y: Float64
    var _has_current_point: Bool

    def __init__(out self):
        self.commands = List[_PathCommand]()
        self._current_x = 0.0
        self._current_y = 0.0
        self._subpath_start_x = 0.0
        self._subpath_start_y = 0.0
        self._has_current_point = False

    def move_to(mut self, x: Float64, y: Float64):
        """Start a new sub-path at (x, y). Ends whatever sub-path was
        being built before (if any) without closing it -- call close()
        first if a closed shape was intended.

        Args:
            x: New sub-path's starting point x.
            y: New sub-path's starting point y.
        """
        self.commands.append(
            _PathCommand(
                _MOVE_TO, FPoint(x, y), FPoint(0.0, 0.0), FPoint(0.0, 0.0)
            )
        )
        self._current_x = x
        self._current_y = y
        self._subpath_start_x = x
        self._subpath_start_y = y
        self._has_current_point = True

    def line_to(mut self, x: Float64, y: Float64) raises:
        """A straight segment from the current point to (x, y).

        Args:
            x: Endpoint x.
            y: Endpoint y.

        Raises:
            Error: No move_to() has been called yet on this path.
        """
        if not self._has_current_point:
            raise Error(
                "Path.line_to() called before any move_to() -- a path needs a"
                " starting point first"
            )
        self.commands.append(
            _PathCommand(
                _LINE_TO, FPoint(x, y), FPoint(0.0, 0.0), FPoint(0.0, 0.0)
            )
        )
        self._current_x = x
        self._current_y = y

    def quad_curve_to(
        mut self, cx: Float64, cy: Float64, x: Float64, y: Float64
    ) raises:
        """A quadratic Bezier from the current point to (x, y), pulled
        toward control point (cx, cy).

        Args:
            cx: Control point x.
            cy: Control point y.
            x: Endpoint x.
            y: Endpoint y.

        Raises:
            Error: No move_to() has been called yet on this path.
        """
        if not self._has_current_point:
            raise Error(
                "Path.quad_curve_to() called before any move_to() -- a path"
                " needs a starting point first"
            )
        self.commands.append(
            _PathCommand(
                _QUAD_TO, FPoint(cx, cy), FPoint(x, y), FPoint(0.0, 0.0)
            )
        )
        self._current_x = x
        self._current_y = y

    def cubic_curve_to(
        mut self,
        c1x: Float64,
        c1y: Float64,
        c2x: Float64,
        c2y: Float64,
        x: Float64,
        y: Float64,
    ) raises:
        """A cubic Bezier from the current point to (x, y), pulled
        toward control points (c1x, c1y) and (c2x, c2y).

        Args:
            c1x: First control point x.
            c1y: First control point y.
            c2x: Second control point x.
            c2y: Second control point y.
            x: Endpoint x.
            y: Endpoint y.

        Raises:
            Error: No move_to() has been called yet on this path.
        """
        if not self._has_current_point:
            raise Error(
                "Path.cubic_curve_to() called before any move_to() -- a path"
                " needs a starting point first"
            )
        self.commands.append(
            _PathCommand(
                _CUBIC_TO, FPoint(c1x, c1y), FPoint(c2x, c2y), FPoint(x, y)
            )
        )
        self._current_x = x
        self._current_y = y

    def arc_to(
        mut self,
        cx: Float64,
        cy: Float64,
        radius: Float64,
        start_angle: Float64,
        end_angle: Float64,
    ) raises:
        """A circular arc segment, center (cx, cy), from `start_angle`
        to `end_angle` (radians, start_angle <= end_angle) -- the same
        convention as draw_arc/fill_arc/fill_ring_sector, including
        which way increasing angle sweeps on screen. Flattened at build
        time through that family's `_arc_fpoints`, so a rendered
        arc_to traces the identical curve a direct draw_arc call would.

        Unlike Cairo's `arc()`, this inserts no connecting line from
        the current point to the arc's start. To join without a seam,
        call move_to(cx + radius*cos(start_angle), cy +
        radius*sin(start_angle)) first, or end the previous segment
        exactly there.

        Args:
            cx: Arc's center x.
            cy: Arc's center y.
            radius: Arc's radius in pixels.
            start_angle: Sweep start, radians, 0 pointing along +x.
            end_angle: Sweep end, radians. Must be >= start_angle.

        Raises:
            Error: No move_to() has been called yet on this path.
        """
        if not self._has_current_point:
            raise Error(
                "Path.arc_to() called before any move_to() -- a path needs a"
                " starting point first"
            )
        self.commands.append(
            _PathCommand(
                _ARC_TO,
                FPoint(cx, cy),
                FPoint(radius, start_angle),
                FPoint(end_angle, 0.0),
            )
        )
        self._current_x = cx + radius * cos(end_angle)
        self._current_y = cy + radius * sin(end_angle)

    def rect(
        mut self, x: Float64, y: Float64, width: Float64, height: Float64
    ) raises:
        """Add a closed rectangular sub-path, clockwise from its
        top-left corner.

        Equivalent to the move_to/line_to/line_to/line_to/close it
        expands to, which is the point: a rectangle is the single most
        common shape to want inside a path -- a plot frame, a legend
        box, a clip region -- and writing five calls for it obscures
        what the path is.

        A degenerate rectangle (zero or negative width or height) adds
        nothing, rather than a sub-path that fills as a line or
        backwards. `fill_rect` is the primitive for an axis-aligned
        rectangle on its own; this is for one that has to be part of a
        path, typically to combine with another sub-path or to clip to.

        Worth knowing before reaching for one over the other: this
        describes the geometric rectangle [x, x+width] x [y, y+height],
        and `fill_path`'s X-fill between a row's crossings is
        inclusive, so filling it covers column x+width -- one more than
        `fill_rect(x, y, width, height)`, which stops at x+width-1.
        That is `fill_polygon`'s documented convention (see its
        docstring for the asymmetric corners that reproduce fill_rect
        exactly), not a discrepancy introduced here.

        Args:
            x: Left edge.
            y: Top edge.
            width: Width in pixels.
            height: Height in pixels.

        Raises:
            Error: Never in practice -- the internal line_to calls
                always follow this method's own move_to.
        """
        if width <= 0.0 or height <= 0.0:
            return
        self.move_to(x, y)
        self.line_to(x + width, y)
        self.line_to(x + width, y + height)
        self.line_to(x, y + height)
        self.close()

    def round_rect(
        mut self,
        x: Float64,
        y: Float64,
        width: Float64,
        height: Float64,
        radius: Float64,
    ) raises:
        """Add a closed rectangular sub-path with rounded corners.

        Corners are true circular quarter-arcs through `arc_to`, not
        Bezier approximations, so they sample at the same
        radius-proportional density every other arc in this package
        does.

        `radius` is clamped to half the shorter side. Past that the
        corners would overlap and the shape would self-intersect, which
        under EVEN_ODD would punch holes in its own corners -- a
        surprising result from a value that merely looks too big. A
        radius at exactly half the shorter side gives a stadium (or a
        circle, when the rectangle is square), which is the natural
        limit of the shape rather than a special case.

        Args:
            x: Left edge.
            y: Top edge.
            width: Width in pixels.
            height: Height in pixels.
            radius: Corner radius, clamped to half the shorter side.

        Raises:
            Error: Never in practice -- every internal call follows
                this method's own move_to.
        """
        if width <= 0.0 or height <= 0.0:
            return
        var r = radius
        var half_short = min(width, height) / 2.0
        if r > half_short:
            r = half_short
        if r <= 0.0:
            self.rect(x, y, width, height)
            return

        var right = x + width
        var bottom = y + height

        # Angles are this package's convention throughout: 0 along +x,
        # increasing clockwise on screen because y grows downward. So a
        # top-left corner sweeps from pi to 3*pi/2.
        self.move_to(x + r, y)
        self.line_to(right - r, y)
        self.arc_to(right - r, y + r, r, -pi / 2.0, 0.0)
        self.line_to(right, bottom - r)
        self.arc_to(right - r, bottom - r, r, 0.0, pi / 2.0)
        self.line_to(x + r, bottom)
        self.arc_to(x + r, bottom - r, r, pi / 2.0, pi)
        self.line_to(x, y + r)
        self.arc_to(x + r, y + r, r, pi, 3.0 * pi / 2.0)
        self.close()

    def ellipse(
        mut self, cx: Float64, cy: Float64, rx: Float64, ry: Float64
    ) raises:
        """Add a closed elliptical sub-path.

        Four cubic Beziers, one per quadrant, with control points at
        the standard kappa = 4/3 * (sqrt(2) - 1) offset. That is an
        approximation -- maximum radial error about 0.027% of the
        radius -- where `fill_ellipse_aa` is exact, and the difference
        is why both exist: this is for an ellipse that has to be *part
        of a path*, to combine with other sub-paths, to stroke, or to
        clip to. Reach for `fill_ellipse_aa` for a plain filled one.

        Cubics rather than `arc_to`, which takes a single `radius` and
        so can only build circular arcs. This is the same limitation
        `DrawTarget` documents as the reason `fill_ellipse_aa` is in
        that trait at all.

        Args:
            cx: Centre x.
            cy: Centre y.
            rx: Horizontal radius in pixels.
            ry: Vertical radius in pixels.

        Raises:
            Error: Never in practice -- every internal call follows
                this method's own move_to.
        """
        if rx <= 0.0 or ry <= 0.0:
            return
        var ox = rx * _KAPPA
        var oy = ry * _KAPPA
        self.move_to(cx + rx, cy)
        self.cubic_curve_to(cx + rx, cy + oy, cx + ox, cy + ry, cx, cy + ry)
        self.cubic_curve_to(cx - ox, cy + ry, cx - rx, cy + oy, cx - rx, cy)
        self.cubic_curve_to(cx - rx, cy - oy, cx - ox, cy - ry, cx, cy - ry)
        self.cubic_curve_to(cx + ox, cy - ry, cx + rx, cy - oy, cx + rx, cy)
        self.close()

    def transformed(self, transform: Transform2D) raises -> Path:
        """This path mapped through `transform`, as a new path.

        Returns a new path rather than mutating in place, unlike every
        other method here. That is deliberate: `Path` is not copyable,
        so a mutating version would give a caller no way to draw one
        shape at several positions -- which is the main reason to want
        this at all.

        Bezier control points map directly: an affine transform of a
        Bezier is the Bezier of the transformed control points, so
        `quad_curve_to` and `cubic_curve_to` come through exactly.

        `arc_to` is the one that cannot always. It describes a
        *circular* arc by centre, radius and angles, and only a
        transform that maps circles to circles can be folded back into
        those five numbers:

        - Equal scale magnitudes, same sign: exact. The centre maps,
          the radius scales, and the angles shift by the transform's
          rotation.
        - A reflection (the axis scales differing in sign, as a y-flip
          does): flattened. The image is still a circular arc, but the
          sweep runs backwards, and `arc_to` only expresses increasing
          angles -- so re-emitting it as an arc would silently reverse
          its endpoints and detach it from the current point.
        - Unequal magnitudes: flattened. The arc becomes an
          *elliptical* arc, which `arc_to` cannot express and no
          primitive here draws.

        Flattening goes through the same `_arc_fpoints` the renderer
        would have used anyway, so the drawn result is unchanged. What
        is lost is the ability to transform the result again exactly,
        not fidelity.

        Args:
            transform: Mapping applied to every point.

        Returns:
            A new path in the transformed space.

        Raises:
            Error: Never in practice -- every call below follows this
                path's own commands, which were already well-formed.
        """
        var out = Path()

        # Equal magnitudes mean circles stay circles; the sign
        # difference is a reflection, handled by mirroring the angles.
        var sx = abs(transform.scale_x)
        var sy = abs(transform.scale_y)
        var uniform = sx == sy
        var reflected = (transform.scale_x < 0.0) != (transform.scale_y < 0.0)

        for cmd in self.commands:
            if cmd.kind == _MOVE_TO:
                var p = transform.to_point(cmd.p1.x, cmd.p1.y)
                out.move_to(p.x, p.y)
            elif cmd.kind == _LINE_TO:
                var p = transform.to_point(cmd.p1.x, cmd.p1.y)
                out.line_to(p.x, p.y)
            elif cmd.kind == _QUAD_TO:
                var c = transform.to_point(cmd.p1.x, cmd.p1.y)
                var e = transform.to_point(cmd.p2.x, cmd.p2.y)
                out.quad_curve_to(c.x, c.y, e.x, e.y)
            elif cmd.kind == _CUBIC_TO:
                var c1 = transform.to_point(cmd.p1.x, cmd.p1.y)
                var c2 = transform.to_point(cmd.p2.x, cmd.p2.y)
                var e = transform.to_point(cmd.p3.x, cmd.p3.y)
                out.cubic_curve_to(c1.x, c1.y, c2.x, c2.y, e.x, e.y)
            elif cmd.kind == _ARC_TO:
                # p1 = (cx, cy), p2 = (radius, start_angle),
                # p3.x = end_angle -- see _PathCommand.
                if uniform and not reflected:
                    var centre = transform.to_point(cmd.p1.x, cmd.p1.y)
                    out.arc_to(
                        centre.x,
                        centre.y,
                        cmd.p2.x * sx,
                        cmd.p2.y + transform.rotation,
                        cmd.p3.x + transform.rotation,
                    )
                else:
                    var arc = _arc_fpoints(
                        cmd.p1.x, cmd.p1.y, cmd.p2.x, cmd.p2.y, cmd.p3.x
                    )
                    # From index 1, matching `_flatten`: index 0 is the
                    # arc's own start, which arc_to's contract already
                    # places at the current point.
                    for i in range(1, len(arc)):
                        var p = transform.to_point(arc[i].x, arc[i].y)
                        out.line_to(p.x, p.y)
            else:  # _CLOSE
                out.close()
        return out^

    def close(mut self) raises:
        """Draw a straight segment back to this sub-path's move_to and
        mark it closed. stroke_path/stroke_path_aa then draw it as a
        polygon rather than an open polyline. No effect on fill_path,
        which treats every sub-path as implicitly closed.
        """
        if not self._has_current_point:
            raise Error(
                "Path.close() called before any move_to() -- a path needs a"
                " starting point first"
            )
        self.commands.append(
            _PathCommand(
                _CLOSE, FPoint(0.0, 0.0), FPoint(0.0, 0.0), FPoint(0.0, 0.0)
            )
        )
        self._current_x = self._subpath_start_x
        self._current_y = self._subpath_start_y


# How far a flattened curve may stray from the true curve, in pixels,
# when the step count is chosen automatically.
#
# 1/50 of a pixel. The coverage sweep samples a 4x4 grid per pixel, so
# a boundary displaced by this much moves a pixel's alpha by at most
# about five levels out of 255 -- below what the supersampling itself
# can resolve, and far below the ~16-level step a single flipped
# sub-sample already produces.
comptime _FLATTEN_TOLERANCE = 0.02

# Bounds on the automatic step count. The floor keeps a
# nearly-straight segment from degenerating to a single chord across a
# long span; the ceiling stops a pathological control polygon from
# generating tens of thousands of edges for one segment.
comptime _MIN_AUTO_STEPS = 3
comptime _MAX_AUTO_STEPS = 400


def _auto_steps(second_diff: Float64, scale: Float64) -> Int:
    """Segments needed to flatten a Bezier within
    `_FLATTEN_TOLERANCE`.

    Chords over n equal parameter intervals deviate from a curve by at
    most (1/(8n^2)) * max|B''(t)|, so requiring that to stay under the
    tolerance gives n >= sqrt(scale * second_diff / (8 * tolerance)),
    where `scale` folds in the constant from B'' for the degree in
    question (2 for a quadratic, 6 for a cubic) and `second_diff` is
    the largest second difference of the control points.

    That is a bound, not an estimate, so the result is never
    under-sampled -- which matters because the failure mode of guessing
    low is a visibly faceted curve.
    """
    var bound = scale * second_diff / (8.0 * _FLATTEN_TOLERANCE)
    if bound <= 0.0:
        return _MIN_AUTO_STEPS
    var n = Int(ceil(sqrt(bound)))
    if n < _MIN_AUTO_STEPS:
        return _MIN_AUTO_STEPS
    if n > _MAX_AUTO_STEPS:
        return _MAX_AUTO_STEPS
    return n


def _hypot(x: Float64, y: Float64) -> Float64:
    return sqrt(x * x + y * y)


def _quad_steps(p0: FPoint, c: FPoint, p1: FPoint) -> Int:
    """Automatic step count for a quadratic. B''(t) is the constant
    2 * (P0 - 2*C + P1), so the second difference is that vector's
    length.
    """
    return _auto_steps(
        _hypot(p0.x - 2.0 * c.x + p1.x, p0.y - 2.0 * c.y + p1.y), 2.0
    )


def _cubic_steps(p0: FPoint, c1: FPoint, c2: FPoint, p1: FPoint) -> Int:
    """Automatic step count for a cubic. B''(t) interpolates between
    6*(P0 - 2*C1 + C2) and 6*(C1 - 2*C2 + P1), so the larger of those
    two second differences bounds it over the whole segment.
    """
    var d1 = _hypot(p0.x - 2.0 * c1.x + c2.x, p0.y - 2.0 * c1.y + c2.y)
    var d2 = _hypot(c1.x - 2.0 * c2.x + p1.x, c1.y - 2.0 * c2.y + p1.y)
    return _auto_steps(max(d1, d2), 6.0)


def _quad_point(p0: FPoint, control: FPoint, p1: FPoint, t: Float64) -> FPoint:
    var mt = 1.0 - t
    var a = mt * mt
    var b = 2.0 * mt * t
    var c = t * t
    return FPoint(
        a * p0.x + b * control.x + c * p1.x, a * p0.y + b * control.y + c * p1.y
    )


def _cubic_point(
    p0: FPoint, c1: FPoint, c2: FPoint, p1: FPoint, t: Float64
) -> FPoint:
    var mt = 1.0 - t
    var a = mt * mt * mt
    var b = 3.0 * mt * mt * t
    var c = 3.0 * mt * t * t
    var d = t * t * t
    return FPoint(
        a * p0.x + b * c1.x + c * c2.x + d * p1.x,
        a * p0.y + b * c1.y + c * c2.y + d * p1.y,
    )


struct _Subpath(Movable):
    """One flattened sub-path: its points, and whether it was close()d.

    Points are `FPoint`, not `Point`: flattening is where a curve's
    real shape is decided, and rounding there would throw away the
    sub-pixel detail `fill_path_aa`'s coverage sweep exists to
    resolve -- a glyph outline at 12px has most of its control points
    landing between pixel centers, and snapping them first is visible
    as uneven stem widths and wobbling spacing.

    The hard-edged consumers (`fill_path`, `stroke_path`,
    `stroke_path_aa`) round these to whole pixels at the point of use,
    which reproduces exactly what flattening used to hand them.
    """

    var points: List[FPoint]
    var closed: Bool

    def __init__(out self, var points: List[FPoint], closed: Bool):
        self.points = points^
        self.closed = closed


def _round_point(p: FPoint) -> Point:
    """One sub-pixel point snapped to the pixel grid."""
    return Point(_round_to_int(p.x), _round_to_int(p.y))


def _rounded_points(sp: _Subpath) -> List[Point]:
    """A sub-path's points snapped to whole pixels, for the primitives
    that address pixels rather than sub-pixel positions. Identical to
    what `_flatten` itself used to return.
    """
    var points = List[Point](capacity=len(sp.points))
    for i in range(len(sp.points)):
        points.append(
            Point(_round_to_int(sp.points[i].x), _round_to_int(sp.points[i].y))
        )
    return points^


def _flatten(path: Path, curve_steps: Int = 0) -> List[_Subpath]:
    """Walk a Path's commands, flattening curves into straight-line
    steps and splitting into one List[FPoint] per sub-path (a new one
    starting at each move_to after the first).

    `curve_steps` of 0 or less -- the default -- chooses the count per
    segment from the segment's own curvature, so it is enough for the
    curve's size rather than a fixed guess. A positive value forces
    that many steps for every quad/cubic, which is what it always did.

    Sub-pixel throughout -- see `_Subpath` on why nothing is rounded
    here, and `_rounded_points` for what the hard-edged callers use
    instead.
    """
    var subpaths = List[_Subpath]()
    var current = List[FPoint]()
    var current_closed = False
    var cur_x = 0.0
    var cur_y = 0.0
    var start_x = 0.0
    var start_y = 0.0

    for cmd in path.commands:
        if cmd.kind == _MOVE_TO:
            if len(current) > 0:
                subpaths.append(_Subpath(current^, current_closed))
                current = List[FPoint]()
                current_closed = False
            cur_x = cmd.p1.x
            cur_y = cmd.p1.y
            start_x = cur_x
            start_y = cur_y
            current.append(FPoint(cur_x, cur_y))
        elif cmd.kind == _LINE_TO:
            cur_x = cmd.p1.x
            cur_y = cmd.p1.y
            current.append(FPoint(cur_x, cur_y))
        elif cmd.kind == _QUAD_TO:
            var p0 = FPoint(cur_x, cur_y)
            var steps = curve_steps if curve_steps > 0 else _quad_steps(
                p0, cmd.p1, cmd.p2
            )
            for step in range(1, steps + 1):
                var t = Float64(step) / Float64(steps)
                var p = _quad_point(p0, cmd.p1, cmd.p2, t)
                current.append(p)
            cur_x = cmd.p2.x
            cur_y = cmd.p2.y
        elif cmd.kind == _CUBIC_TO:
            var p0 = FPoint(cur_x, cur_y)
            var steps = curve_steps if curve_steps > 0 else _cubic_steps(
                p0, cmd.p1, cmd.p2, cmd.p3
            )
            for step in range(1, steps + 1):
                var t = Float64(step) / Float64(steps)
                var p = _cubic_point(p0, cmd.p1, cmd.p2, cmd.p3, t)
                current.append(p)
            cur_x = cmd.p3.x
            cur_y = cmd.p3.y
        elif cmd.kind == _ARC_TO:
            # cmd.p1 = (cx, cy), cmd.p2 = (radius, start_angle),
            # cmd.p3.x = end_angle (see _PathCommand). _arc_fpoints
            # includes the arc's start point at index 0, which arc_to's
            # contract puts at (cur_x, cur_y) already, so it's skipped
            # the way the quad/cubic branches skip t=0.
            var arc_points = _arc_fpoints(
                cmd.p1.x, cmd.p1.y, cmd.p2.x, cmd.p2.y, cmd.p3.x
            )
            for i in range(1, len(arc_points)):
                current.append(arc_points[i])
            cur_x = cmd.p1.x + cmd.p2.x * cos(cmd.p3.x)
            cur_y = cmd.p1.y + cmd.p2.x * sin(cmd.p3.x)
        else:  # _CLOSE
            cur_x = start_x
            cur_y = start_y
            current_closed = True

    if len(current) > 0:
        subpaths.append(_Subpath(current^, current_closed))

    return subpaths^


def _row_crossings(subpaths: List[_Subpath], y: Int) -> List[_Crossing]:
    """Every sub-path's edge crossings of row y, combined into one
    list; shared by fill_path/fill_path_gradient. The multi-sub-path
    analog of the crossing collection fill_polygon does inline.
    Combining across all sub-paths, rather than resetting per sub-path,
    is what makes hole-punching and NONZERO union-filling work.
    """
    var crossings = List[_Crossing]()
    for sp_idx in range(len(subpaths)):
        ref sp = subpaths[sp_idx]
        var n = len(sp.points)
        if n < 2:
            continue
        for i in range(n):
            # Rounded here rather than at flatten time (see _Subpath).
            # This is a hard-edged fill addressing whole pixels, so it
            # wants the same snapped geometry flattening used to hand
            # it, and rounding at the point of use keeps it bit-for-bit
            # identical while the AA fill reads the same sub-paths
            # unrounded.
            var p0 = _round_point(sp.points[i])
            var p1 = _round_point(sp.points[(i + 1) % n])
            if p0.y == p1.y:
                continue
            var lo = min(p0.y, p1.y)
            var hi = max(p0.y, p1.y)
            if y >= lo and y < hi:
                var t = Float64(y - p0.y) / Float64(p1.y - p0.y)
                var x = Float64(p0.x) + t * Float64(p1.x - p0.x)
                var direction = 1 if p1.y > p0.y else -1
                crossings.append(_Crossing(Int(x + 0.5), direction))
    return crossings^


def fill_path(
    mut canvas: Canvas,
    path: Path,
    color: Color,
    fill_rule: FillRule = FillRule.EVEN_ODD,
    curve_steps: Int = 0,
):
    """Fill a path's interior with the scanline algorithm, combining
    every sub-path's crossings per scanline into a signed winding
    number (via polygon_fill's `_spans_from_crossings`, shared with
    fill_polygon). With `fill_rule` at its EVEN_ODD default, overlapping
    sub-paths leave a hole where they overlap; with FillRule.NONZERO,
    two sub-paths wound the same direction fill as one solid union.

    `curve_steps` is how many straight-line segments each quad/cubic
    Bezier in the path flattens into (see _flatten) -- raise it for an
    unusually large or highly curved path where 16 segments start to
    look faceted.

    Separate from fill_polygon rather than a generalization of it:
    fill_polygon's single-polygon contract is an API guarantee.

    Same half-open Y-extent convention as fill_polygon
    ([min(y0,y1), max(y0,y1))), which makes a vertex shared by two
    opposite-direction edges count once rather than twice, while a
    local extremum contributes zero net crossings rather than two.

    Args:
        canvas: Canvas to fill into.
        path: Path to fill.
        color: Fill color.
        fill_rule: EVEN_ODD (default) or NONZERO -- see FillRule.
        curve_steps: Straight-line segments per quad/cubic Bezier.
            0 (the default) picks a count per segment from its own
            curvature; a positive value forces that many.
    """
    var subpaths = _flatten(path, curve_steps)
    if len(subpaths) == 0:
        return

    # Integer bounds over the rounded points, matching the rounding
    # _row_crossings does -- this is the hard-edged scanline fill.
    var min_y = _round_to_int(subpaths[0].points[0].y)
    var max_y = min_y
    for sp_idx in range(len(subpaths)):
        ref sp = subpaths[sp_idx]
        for p in sp.points:
            var py = _round_to_int(p.y)
            if py < min_y:
                min_y = py
            if py > max_y:
                max_y = py

    for y in range(min_y, max_y):
        var crossings = _row_crossings(subpaths, y)
        var spans = _spans_from_crossings(crossings, fill_rule)
        for span_idx in range(len(spans)):
            ref span = spans[span_idx]
            for x in range(span.start_x, span.end_x + 1):
                canvas.set_pixel(x, y, color)


def _point_in_subpaths(
    subpaths: List[_Subpath], fx: Float64, fy: Float64, fill_rule: FillRule
) -> Bool:
    """The continuous-point analog of _row_crossings + _is_inside:
    every sub-path's edges combined into one signed winding number at
    an arbitrary real-valued point, which is what fill_path_aa's
    supersampling needs.

    Reads the sub-paths' points unrounded, as fill_path_aa does -- this
    is the reference implementation that fill's output has to match, so
    it has to see the same geometry. The hard-edged `_row_crossings`
    rounds instead; the two therefore agree on a boundary only to
    within the rounding, which is inherent to one of them addressing
    whole pixels.
    """
    var winding = 0
    for sp_idx in range(len(subpaths)):
        ref sp = subpaths[sp_idx]
        var n = len(sp.points)
        if n < 2:
            continue
        for i in range(n):
            var p0 = sp.points[i]
            var p1 = sp.points[(i + 1) % n]
            if p0.y == p1.y:
                continue
            var lo = min(p0.y, p1.y)
            var hi = max(p0.y, p1.y)
            if fy >= lo and fy < hi:
                var t = (fy - p0.y) / (p1.y - p0.y)
                var x = p0.x + t * (p1.x - p0.x)
                if x > fx:
                    winding += 1 if p1.y > p0.y else -1
    return _is_inside(winding, fill_rule)


def fill_path_aa(
    mut canvas: Canvas,
    path: Path,
    color: Color,
    fill_rule: FillRule = FillRule.EVEN_ODD,
    supersample: Int = 4,
    curve_steps: Int = 0,
):
    """Anti-aliased fill_path -- fill_path's counterpart the same way
    fill_polygon_aa is fill_polygon's (see that function in
    canvas.shapes.polygon_fill): for every pixel
    near the path's flattened outline, samples an NxN sub-pixel grid
    and turns the coverage fraction into that pixel's alpha. Each
    output pixel is visited exactly once.

    Same multi-sub-path hole-punching (and, with FillRule.NONZERO,
    union-filling) fill_path itself has -- every sub-path's winding
    contribution is combined before either fill rule is applied, not
    per-sub-path independently, for the identical reason fill_path's
    own docstring gives.

    The sweep itself is `canvas.aa_crossing`'s `_sweep_edges_aa`,
    shared with `fill_polygon_aa` -- see there for why it works per
    sub-scanline rather than per sub-pixel sample, and what that buys
    over the naive membership test. All this function contributes is
    the flattened path's bounding box and its edges.
    `_point_in_subpaths` remains the reference implementation that
    sweep's output must match pixel for pixel, and is still tested
    directly.

    Not fused with fill_path behind an `antialias: Bool`, for the
    reason canvas.shapes.lines gives: a complexity-class jump per
    pixel, not a free toggle.

    `curve_steps` is fill_path's same per-segment flattening knob --
    see its docstring.

    Args:
        canvas: Canvas to fill into.
        path: Path to fill.
        color: Fill color.
        fill_rule: EVEN_ODD (default) or NONZERO -- see FillRule.
        supersample: Sub-pixel grid side length per pixel (N -> N*N
            samples).
        curve_steps: Straight-line segments per quad/cubic Bezier.
            0 (the default) picks a count per segment from its own
            curvature; a positive value forces that many.
    """
    var subpaths = _flatten(path, curve_steps)
    if len(subpaths) == 0:
        return

    var min_x = subpaths[0].points[0].x
    var max_x = min_x
    var min_y = subpaths[0].points[0].y
    var max_y = min_y
    for sp_idx in range(len(subpaths)):
        ref sp = subpaths[sp_idx]
        for p in sp.points:
            if p.x < min_x:
                min_x = p.x
            if p.x > max_x:
                max_x = p.x
            if p.y < min_y:
                min_y = p.y
            if p.y > max_y:
                max_y = p.y

    # Every sub-path's edges go into one table, so their winding
    # contributions combine before the fill rule is applied -- which is
    # what makes an inner sub-path punch a hole rather than fill solid.
    #
    # Handed over unrounded. This is the whole point of `_Subpath`
    # carrying FPoint: an edge running from x = 10.4 to x = 13.7 covers
    # a genuinely different set of sub-samples than one snapped to
    # 10 -> 14, and it is that difference the coverage sweep turns into
    # alpha.
    var edges = _EdgeTable()
    for sp_idx in range(len(subpaths)):
        ref sp = subpaths[sp_idx]
        var pn = len(sp.points)
        if pn < 2:
            continue
        for i in range(pn):
            var a = sp.points[i]
            var b = sp.points[(i + 1) % pn]
            edges.add_edge(a.x, a.y, b.x, b.y)

    # The sweep works in whole pixels, so the real-valued bounds widen
    # outward to the pixels that contain them (floor/ceil, not round):
    # an edge at x = 10.2 has to have pixel 10 swept for it to pick up
    # any partial coverage there. The sweep pads by a further pixel on
    # each side on top of this.
    _sweep_edges_aa(
        canvas,
        edges,
        Int(floor(min_x)),
        Int(floor(min_y)),
        Int(ceil(max_x)),
        Int(ceil(max_y)),
        color,
        fill_rule,
        supersample,
    )


def _path_coverage_mask(
    path: Path,
    width: Int,
    height: Int,
    fill_rule: FillRule,
    supersample: Int,
    curve_steps: Int,
) -> List[UInt8]:
    """`path`'s anti-aliased coverage over a width x height grid, as
    one 0-255 byte per pixel -- what `Canvas.push_clip_path` stores as
    a clip mask.

    The same flatten-and-sweep `fill_path_aa` runs, with the coverage
    kept as a number instead of being turned into a colour's alpha, so
    a clip boundary and a fill boundary of the same path fall in
    exactly the same places.

    Lives here rather than in buffer.mojo because it needs `_flatten`,
    which is this module's; `buffer.mojo` already imports from here.
    """
    var mask = List[UInt8](length=width * height, fill=0)
    var subpaths = _flatten(path, curve_steps)
    if len(subpaths) == 0:
        return mask^

    var min_x = subpaths[0].points[0].x
    var max_x = min_x
    var min_y = subpaths[0].points[0].y
    var max_y = min_y
    for sp_idx in range(len(subpaths)):
        ref sp = subpaths[sp_idx]
        for p in sp.points:
            if p.x < min_x:
                min_x = p.x
            if p.x > max_x:
                max_x = p.x
            if p.y < min_y:
                min_y = p.y
            if p.y > max_y:
                max_y = p.y

    var edges = _EdgeTable()
    for sp_idx in range(len(subpaths)):
        ref sp = subpaths[sp_idx]
        var pn = len(sp.points)
        if pn < 2:
            continue
        for i in range(pn):
            var a = sp.points[i]
            var b = sp.points[(i + 1) % pn]
            edges.add_edge(a.x, a.y, b.x, b.y)

    _sweep_edges_to_mask(
        mask,
        width,
        height,
        edges,
        Int(floor(min_x)),
        Int(floor(min_y)),
        Int(ceil(max_x)),
        Int(ceil(max_y)),
        fill_rule,
        supersample,
    )
    return mask^


def fill_path_gradient(
    mut canvas: Canvas,
    path: Path,
    gradient: LinearGradient,
    fill_rule: FillRule = FillRule.EVEN_ODD,
    curve_steps: Int = 0,
):
    """Fill a path's interior as fill_path does, but sourcing each
    pixel's color from `gradient` (gradient.mojo) rather than one flat
    Color. Same scanline structure, duplicated rather than factored
    behind a "how to get a color" parameter for two call sites.

    `curve_steps` is fill_path's same per-segment flattening knob --
    see its docstring.

    Args:
        canvas: Canvas to fill into.
        path: Path to fill.
        gradient: Fill source, queried per pixel.
        fill_rule: EVEN_ODD (default) or NONZERO -- see FillRule.
        curve_steps: Straight-line segments per quad/cubic Bezier.
            0 (the default) picks a count per segment from its own
            curvature; a positive value forces that many.
    """
    var subpaths = _flatten(path, curve_steps)
    if len(subpaths) == 0:
        return

    # Integer bounds over the rounded points, matching the rounding
    # _row_crossings does -- this is the hard-edged scanline fill.
    var min_y = _round_to_int(subpaths[0].points[0].y)
    var max_y = min_y
    for sp_idx in range(len(subpaths)):
        ref sp = subpaths[sp_idx]
        for p in sp.points:
            var py = _round_to_int(p.y)
            if py < min_y:
                min_y = py
            if py > max_y:
                max_y = py

    for y in range(min_y, max_y):
        var crossings = _row_crossings(subpaths, y)
        var spans = _spans_from_crossings(crossings, fill_rule)
        for span_idx in range(len(spans)):
            ref span = spans[span_idx]
            for x in range(span.start_x, span.end_x + 1):
                canvas.set_pixel(
                    x, y, gradient.color_at(Float64(x), Float64(y))
                )


def fill_path_radial_gradient(
    mut canvas: Canvas,
    path: Path,
    gradient: RadialGradient,
    fill_rule: FillRule = FillRule.EVEN_ODD,
    curve_steps: Int = 0,
):
    """Like fill_path_gradient, but for a RadialGradient (gradient.mojo).

    Args:
        canvas: Canvas to fill into.
        path: Path to fill.
        gradient: Fill source, queried per pixel.
        fill_rule: EVEN_ODD (default) or NONZERO -- see FillRule.
        curve_steps: Straight-line segments per quad/cubic Bezier.
            0 (the default) picks a count per segment from its own
            curvature; a positive value forces that many.
    """
    var subpaths = _flatten(path, curve_steps)
    if len(subpaths) == 0:
        return

    # Integer bounds over the rounded points, matching the rounding
    # _row_crossings does -- this is the hard-edged scanline fill.
    var min_y = _round_to_int(subpaths[0].points[0].y)
    var max_y = min_y
    for sp_idx in range(len(subpaths)):
        ref sp = subpaths[sp_idx]
        for p in sp.points:
            var py = _round_to_int(p.y)
            if py < min_y:
                min_y = py
            if py > max_y:
                max_y = py

    for y in range(min_y, max_y):
        var crossings = _row_crossings(subpaths, y)
        var spans = _spans_from_crossings(crossings, fill_rule)
        for span_idx in range(len(spans)):
            ref span = spans[span_idx]
            for x in range(span.start_x, span.end_x + 1):
                canvas.set_pixel(
                    x, y, gradient.color_at(Float64(x), Float64(y))
                )


def stroke_path(
    mut canvas: Canvas,
    path: Path,
    color: Color,
    curve_steps: Int = 0,
    dashes: List[Float64] = List[Float64](),
    dash_offset: Float64 = 0.0,
):
    """Stroke every sub-path, hard-edged 1px: closed ones (close() was
    called) via draw_polygon, open ones via draw_polyline.

    `curve_steps` is fill_path's same per-segment flattening knob --
    see its docstring.

    Args:
        canvas: Canvas to stroke into.
        path: Path to stroke.
        color: Stroke color.
        curve_steps: Straight-line segments per quad/cubic Bezier.
            0 (the default) picks a count per segment from its own
            curvature; a positive value forces that many.
        dashes: On/off segment lengths in pixels, cycled along the
            stroke. Empty (default) draws a solid line.
        dash_offset: Distance into the dash pattern the stroke starts
            at.
    """
    var subpaths = _flatten(path, curve_steps)
    for sp_idx in range(len(subpaths)):
        ref sp = subpaths[sp_idx]
        var points = _rounded_points(sp)
        if sp.closed:
            draw_polygon(canvas, points, color, dashes, dash_offset)
        else:
            draw_polyline(canvas, points, color, dashes, dash_offset)


def stroke_path_aa(
    mut canvas: Canvas,
    path: Path,
    color: Color,
    width: Float64 = 1.0,
    supersample: Int = 4,
    curve_steps: Int = 0,
    dashes: List[Float64] = List[Float64](),
    dash_offset: Float64 = 0.0,
    cap: LineCap = LineCap.ROUND,
    join: LineJoin = LineJoin.ROUND,
    miter_limit: Float64 = 4.0,
):
    """Anti-aliased version of stroke_path -- see draw_polyline_aa/
    draw_polygon_aa.

    `curve_steps` is fill_path's same per-segment flattening knob --
    see its docstring.

    Args:
        canvas: Canvas to stroke into.
        path: Path to stroke.
        color: Stroke color.
        width: Stroke width in pixels.
        supersample: Sub-pixel grid side length per pixel (N -> N*N
            samples).
        curve_steps: Straight-line segments per quad/cubic Bezier.
            0 (the default) picks a count per segment from its own
            curvature; a positive value forces that many.
        dashes: On/off segment lengths in pixels, cycled along the
            stroke. Empty (default) draws a solid line.
        dash_offset: Distance into the dash pattern the stroke starts
            at.
        cap: How an *open* sub-path's two ends are finished -- see
            LineCap. A closed sub-path has no ends and ignores it.
        join: How corners are turned -- see LineJoin. A flattened
            curve's corners are shallow enough that the three styles
            are hard to tell apart; the difference shows on a polygon
            or a sharply-kinked path.
        miter_limit: Ratio past which a MITER join falls back to
            BEVEL, as a multiple of half the stroke width.
    """
    var subpaths = _flatten(path, curve_steps)
    for sp_idx in range(len(subpaths)):
        ref sp = subpaths[sp_idx]
        # Unrounded: draw_polyline_aa/draw_polygon_aa take sub-pixel
        # vertices, so a stroked curve follows the flattened path
        # exactly rather than a grid-snapped copy of it.
        ref points = sp.points
        if sp.closed:
            # No `cap`: a closed sub-path has no ends to finish.
            draw_polygon_aa(
                canvas,
                points,
                color,
                width,
                supersample,
                dashes,
                dash_offset,
                join,
                miter_limit,
            )
        else:
            draw_polyline_aa(
                canvas,
                points,
                color,
                width,
                supersample,
                dashes,
                dash_offset,
                cap,
                join,
                miter_limit,
            )
