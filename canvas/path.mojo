"""A general path type: move/line/quadratic-curve/cubic-curve/arc-to/
close, built up through chained calls, then flattened into straight-
line segments and handed to canvas.shapes' polyline/polygon/fill
machinery rather than reimplementing fill or stroke here.

Coordinates are Float64 (FPoint), not Point's integer pixels: a control
point off by a fraction of a pixel changes the flattened curve's shape,
where a straight line's endpoints only need whole pixels. Quad/cubic
flattening uses a fixed step count per segment (`curve_steps`, default
16) rather than adaptive subdivision -- good enough at these sizes for
the default, and callers with an unusually large or highly curved path
can raise it. arc_to is the exception: it
reuses canvas.shapes.arcs' `_arc_points` (radius-proportional step
count), the same sampling draw_arc/fill_arc/fill_ring_sector use, since
a fixed count doesn't stretch across a path-drawn arc's much wider
radius range.

A path can hold multiple sub-paths (more than one move_to). fill_path
combines every sub-path's scanline crossings (even-odd), so an outer
shape plus an inner sub-path punches a hole the way 'o' or 'A' need.
stroke_path/stroke_path_aa instead draw each sub-path independently,
closed (draw_polygon) or open (draw_polyline) depending on whether
close() was called.
"""

from std.math import ceil, cos, sin

from canvas.buffer import Canvas
from canvas.color import Color
from canvas.geometry import Point, _round_to_int
from canvas.gradient import LinearGradient, RadialGradient
from canvas.fill_rule import FillRule, _is_inside
from canvas.aa_crossing import _EdgeTable, _sweep_edges_aa
from canvas.shapes.lines import (
    draw_polyline,
    draw_polygon,
    draw_polyline_aa,
    draw_polygon_aa,
)
from canvas.shapes.polygon_fill import _Crossing, _spans_from_crossings
from canvas.shapes.arcs import _arc_points

comptime _MOVE_TO = 0
comptime _LINE_TO = 1
comptime _QUAD_TO = 2
comptime _CUBIC_TO = 3
comptime _CLOSE = 4
comptime _ARC_TO = 5


struct FPoint(ImplicitlyCopyable, Movable):
    """A floating-point 2D coordinate: Path's point type, separate from
    geometry.Point, which is integer pixels only.
    """

    var x: Float64
    var y: Float64

    def __init__(out self, x: Float64, y: Float64):
        """A floating-point 2D coordinate.

        Args:
            x: Column, sub-pixel precision.
            y: Row, sub-pixel precision.
        """
        self.x = x
        self.y = y


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
        time through that family's `_arc_points`, so a rendered
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
    """One flattened sub-path: its points, and whether it was close()d."""

    var points: List[Point]
    var closed: Bool

    def __init__(out self, var points: List[Point], closed: Bool):
        self.points = points^
        self.closed = closed


def _flatten(path: Path, curve_steps: Int = 16) -> List[_Subpath]:
    """Walk a Path's commands, flattening curves into straight-line
    steps (`curve_steps` per quad/cubic segment), and split into one
    List[Point] per sub-path (a new one starting at each move_to after
    the first).
    """
    var subpaths = List[_Subpath]()
    var current = List[Point]()
    var current_closed = False
    var cur_x = 0.0
    var cur_y = 0.0
    var start_x = 0.0
    var start_y = 0.0

    for cmd in path.commands:
        if cmd.kind == _MOVE_TO:
            if len(current) > 0:
                subpaths.append(_Subpath(current^, current_closed))
                current = List[Point]()
                current_closed = False
            cur_x = cmd.p1.x
            cur_y = cmd.p1.y
            start_x = cur_x
            start_y = cur_y
            current.append(Point(_round_to_int(cur_x), _round_to_int(cur_y)))
        elif cmd.kind == _LINE_TO:
            cur_x = cmd.p1.x
            cur_y = cmd.p1.y
            current.append(Point(_round_to_int(cur_x), _round_to_int(cur_y)))
        elif cmd.kind == _QUAD_TO:
            var p0 = FPoint(cur_x, cur_y)
            for step in range(1, curve_steps + 1):
                var t = Float64(step) / Float64(curve_steps)
                var p = _quad_point(p0, cmd.p1, cmd.p2, t)
                current.append(Point(_round_to_int(p.x), _round_to_int(p.y)))
            cur_x = cmd.p2.x
            cur_y = cmd.p2.y
        elif cmd.kind == _CUBIC_TO:
            var p0 = FPoint(cur_x, cur_y)
            for step in range(1, curve_steps + 1):
                var t = Float64(step) / Float64(curve_steps)
                var p = _cubic_point(p0, cmd.p1, cmd.p2, cmd.p3, t)
                current.append(Point(_round_to_int(p.x), _round_to_int(p.y)))
            cur_x = cmd.p3.x
            cur_y = cmd.p3.y
        elif cmd.kind == _ARC_TO:
            # cmd.p1 = (cx, cy), cmd.p2 = (radius, start_angle),
            # cmd.p3.x = end_angle (see _PathCommand). _arc_points
            # includes the arc's start point at index 0, which arc_to's
            # contract puts at (cur_x, cur_y) already, so it's skipped
            # the way the quad/cubic branches skip t=0.
            var arc_points = _arc_points(
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
            var p0 = sp.points[i]
            var p1 = sp.points[(i + 1) % n]
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
    curve_steps: Int = 16,
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
    """
    var subpaths = _flatten(path, curve_steps)
    if len(subpaths) == 0:
        return

    var min_y = subpaths[0].points[0].y
    var max_y = min_y
    for sp_idx in range(len(subpaths)):
        ref sp = subpaths[sp_idx]
        for p in sp.points:
            if p.y < min_y:
                min_y = p.y
            if p.y > max_y:
                max_y = p.y

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
    supersampling needs. Shares `_is_inside` with the discrete
    fill_path, so hard-edged and AA fills of one path agree on where
    the boundary is.
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
            var y0 = Float64(p0.y)
            var y1 = Float64(p1.y)
            if y0 == y1:
                continue
            var lo = min(y0, y1)
            var hi = max(y0, y1)
            if fy >= lo and fy < hi:
                var t = (fy - y0) / (y1 - y0)
                var x = Float64(p0.x) + t * Float64(p1.x - p0.x)
                if x > fx:
                    winding += 1 if y1 > y0 else -1
    return _is_inside(winding, fill_rule)


def fill_path_aa(
    mut canvas: Canvas,
    path: Path,
    color: Color,
    fill_rule: FillRule = FillRule.EVEN_ODD,
    supersample: Int = 4,
    curve_steps: Int = 16,
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
    var edges = _EdgeTable()
    for sp_idx in range(len(subpaths)):
        ref sp = subpaths[sp_idx]
        var pn = len(sp.points)
        if pn < 2:
            continue
        for i in range(pn):
            var a = sp.points[i]
            var b = sp.points[(i + 1) % pn]
            edges.add_edge(
                Float64(a.x), Float64(a.y), Float64(b.x), Float64(b.y)
            )

    _sweep_edges_aa(
        canvas,
        edges,
        min_x,
        min_y,
        max_x,
        max_y,
        color,
        fill_rule,
        supersample,
    )


def fill_path_gradient(
    mut canvas: Canvas,
    path: Path,
    gradient: LinearGradient,
    fill_rule: FillRule = FillRule.EVEN_ODD,
    curve_steps: Int = 16,
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
    """
    var subpaths = _flatten(path, curve_steps)
    if len(subpaths) == 0:
        return

    var min_y = subpaths[0].points[0].y
    var max_y = min_y
    for sp_idx in range(len(subpaths)):
        ref sp = subpaths[sp_idx]
        for p in sp.points:
            if p.y < min_y:
                min_y = p.y
            if p.y > max_y:
                max_y = p.y

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
    curve_steps: Int = 16,
):
    """Like fill_path_gradient, but for a RadialGradient (gradient.mojo).

    Args:
        canvas: Canvas to fill into.
        path: Path to fill.
        gradient: Fill source, queried per pixel.
        fill_rule: EVEN_ODD (default) or NONZERO -- see FillRule.
        curve_steps: Straight-line segments per quad/cubic Bezier.
    """
    var subpaths = _flatten(path, curve_steps)
    if len(subpaths) == 0:
        return

    var min_y = subpaths[0].points[0].y
    var max_y = min_y
    for sp_idx in range(len(subpaths)):
        ref sp = subpaths[sp_idx]
        for p in sp.points:
            if p.y < min_y:
                min_y = p.y
            if p.y > max_y:
                max_y = p.y

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
    curve_steps: Int = 16,
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
        dashes: On/off segment lengths in pixels, cycled along the
            stroke. Empty (default) draws a solid line.
        dash_offset: Distance into the dash pattern the stroke starts
            at.
    """
    var subpaths = _flatten(path, curve_steps)
    for sp_idx in range(len(subpaths)):
        ref sp = subpaths[sp_idx]
        if sp.closed:
            draw_polygon(canvas, sp.points, color, dashes, dash_offset)
        else:
            draw_polyline(canvas, sp.points, color, dashes, dash_offset)


def stroke_path_aa(
    mut canvas: Canvas,
    path: Path,
    color: Color,
    width: Float64 = 1.0,
    supersample: Int = 4,
    curve_steps: Int = 16,
    dashes: List[Float64] = List[Float64](),
    dash_offset: Float64 = 0.0,
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
        dashes: On/off segment lengths in pixels, cycled along the
            stroke. Empty (default) draws a solid line.
        dash_offset: Distance into the dash pattern the stroke starts
            at.
    """
    var subpaths = _flatten(path, curve_steps)
    for sp_idx in range(len(subpaths)):
        ref sp = subpaths[sp_idx]
        if sp.closed:
            draw_polygon_aa(
                canvas,
                sp.points,
                color,
                width,
                supersample,
                dashes,
                dash_offset,
            )
        else:
            draw_polyline_aa(
                canvas,
                sp.points,
                color,
                width,
                supersample,
                dashes,
                dash_offset,
            )
