"""A general path type -- move/line/quadratic-curve/cubic-curve/
arc-to/close, built up via chained calls, then flattened into
straight-line segments and handed off to canvas_mojo.shapes' already-
tested polyline/polygon/fill machinery, rather than reimplementing
fill or stroke logic here.

Coordinates are Float64 (FPoint), not Point's integer pixels: a curve
control point off by a fraction of a pixel changes the flattened
curve's visible shape, unlike a straight line's endpoints, which only
ever needed whole pixels. Quad/cubic curve flattening uses a fixed
step count per segment, not adaptive subdivision -- the same choice,
for the same reason, fonts/raster.mojo made for TrueType's quadratic
curves before this package had its own general path type (see the
wiki for that history): good enough at the sizes this exists for, and
adaptive subdivision is real, deferrable complexity with no concrete
need yet. arc_to is the one exception: it reuses canvas_mojo.shapes.
arcs' own _arc_points helper (radius-proportional step count), the
same exact circle-math sampling draw_arc/fill_arc/fill_ring_sector
already use -- a fixed step count doesn't generalize across a
path-drawn arc's own much wider practical radius range the way it does
for a Bezier control-point-driven curve, see _arc_points's own
docstring.

A path can hold multiple sub-paths (more than one move_to). fill_path
combines every sub-path's scanline crossings together (even-odd),
exactly the multi-contour technique fonts/raster.mojo used for
TrueType glyphs' counters -- so an outer shape plus an inner "hole"
sub-path correctly punches a hole, the same way 'o' or 'A' need their
inner contour to combine with the outer one. stroke_path/stroke_path_aa
instead draw each sub-path independently, closed (draw_polygon) or
open (draw_polyline) depending on whether that sub-path's own close()
was called.
"""

from std.math import cos, sin

from canvas_mojo.buffer import Canvas
from canvas_mojo.color import Color
from canvas_mojo.geometry import Point, _round_to_int
from canvas_mojo.gradient import LinearGradient, RadialGradient
from canvas_mojo.fill_rule import FillRule
from canvas_mojo.aa_crossing import _AACrossing, _sort_aa_crossings_by_x
from canvas_mojo.shapes.lines import draw_polyline, draw_polygon, draw_polyline_aa, draw_polygon_aa
from canvas_mojo.shapes.polygon_fill import _Crossing, _spans_from_crossings, _is_inside
from canvas_mojo.shapes.arcs import _arc_points

comptime _MOVE_TO = 0
comptime _LINE_TO = 1
comptime _QUAD_TO = 2
comptime _CUBIC_TO = 3
comptime _CLOSE = 4
comptime _ARC_TO = 5

# Fixed subdivision steps per curve segment when flattening -- see
# this module's own docstring for why fixed, not adaptive.
comptime _CURVE_STEPS = 16


struct FPoint(ImplicitlyCopyable, Movable):
    """A floating-point 2D coordinate -- Path's own point type, kept
    separate from geometry.Point (integer pixels only) for the reason
    given in this module's docstring.
    """

    var x: Float64
    var y: Float64

    def __init__(out self, x: Float64, y: Float64):
        self.x = x
        self.y = y


struct _PathCommand(ImplicitlyCopyable, Movable):
    """One path command. Which of p1/p2/p3 are meaningful depends on
    `kind`: move_to/line_to use only p1 (the endpoint); quad_to uses
    p1 (control) and p2 (endpoint); cubic_to uses all three (control1,
    control2, endpoint); close uses none; arc_to packs its five plain
    scalars (cx, cy, radius, start_angle, end_angle) across all three
    points instead of a fourth field -- p1 = (cx, cy), p2 = (radius,
    start_angle), p3.x = end_angle (p3.y unused). A tagged struct with
    unused fields left zeroed, not a real union (Mojo doesn't have a
    lightweight one) -- wastes a little space per command, irrelevant
    at the command counts a chart-label-sized path ever reaches.
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
    close, then hand to fill_path/stroke_path/stroke_path_aa. No chaining
    (each call is `mut self` returning nothing) -- matches Canvas's
    own builder-style methods (push_clip, set_pixel) rather than
    inventing a fluent style just for this type.

    All coordinates are absolute, not relative-to-current-point (no
    SVG/Cairo-style rel_line_to equivalents) -- narrower than either
    of those APIs on purpose; relative variants are a thin convenience
    layer that's easy to add later if something concrete needs it, not
    load-bearing for anything this exists for yet.
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
        """
        self.commands.append(_PathCommand(_MOVE_TO, FPoint(x, y), FPoint(0.0, 0.0), FPoint(0.0, 0.0)))
        self._current_x = x
        self._current_y = y
        self._subpath_start_x = x
        self._subpath_start_y = y
        self._has_current_point = True

    def line_to(mut self, x: Float64, y: Float64) raises:
        """A straight segment from the current point to (x, y)."""
        if not self._has_current_point:
            raise Error("Path.line_to() called before any move_to() -- a path needs a starting point first")
        self.commands.append(_PathCommand(_LINE_TO, FPoint(x, y), FPoint(0.0, 0.0), FPoint(0.0, 0.0)))
        self._current_x = x
        self._current_y = y

    def quad_curve_to(mut self, cx: Float64, cy: Float64, x: Float64, y: Float64) raises:
        """A quadratic Bezier from the current point to (x, y), pulled
        toward control point (cx, cy).
        """
        if not self._has_current_point:
            raise Error("Path.quad_curve_to() called before any move_to() -- a path needs a starting point first")
        self.commands.append(_PathCommand(_QUAD_TO, FPoint(cx, cy), FPoint(x, y), FPoint(0.0, 0.0)))
        self._current_x = x
        self._current_y = y

    def cubic_curve_to(
        mut self, c1x: Float64, c1y: Float64, c2x: Float64, c2y: Float64, x: Float64, y: Float64
    ) raises:
        """A cubic Bezier from the current point to (x, y), pulled
        toward control points (c1x, c1y) and (c2x, c2y).
        """
        if not self._has_current_point:
            raise Error("Path.cubic_curve_to() called before any move_to() -- a path needs a starting point first")
        self.commands.append(_PathCommand(_CUBIC_TO, FPoint(c1x, c1y), FPoint(c2x, c2y), FPoint(x, y)))
        self._current_x = x
        self._current_y = y

    def arc_to(
        mut self, cx: Float64, cy: Float64, radius: Float64, start_angle: Float64, end_angle: Float64
    ) raises:
        """A circular arc segment, center (cx, cy), from `start_angle`
        to `end_angle` (radians, start_angle <= end_angle expected --
        same convention as canvas_mojo.shapes.arcs' own draw_arc/
        fill_arc/fill_ring_sector family, including which way increasing angle
        sweeps on screen: see _arc_points's own docstring). Flattened
        via that same _arc_points helper at build time (not Path's own
        fixed-step quad/cubic subdivision, see this module's own
        docstring for why fixed-step curve flattening is fine for
        those but wouldn't be here) -- radius-proportional step count,
        so a raster fill_path_aa/stroke_path_aa render of an arc_to
        traces the identical curve a direct draw_arc/fill_arc call
        would, not just a visually-similar one.

        Unlike Cairo's `arc()`, this does *not* insert a connecting
        line from wherever the current point already is to the arc's
        own start point -- matches every other Path method's absolute,
        no-implicit-magic contract (see this struct's own docstring):
        call move_to(cx + radius*cos(start_angle), cy +
        radius*sin(start_angle)) first (or arrange the previous
        segment to already end exactly there) if the two need to
        connect with no seam.
        """
        if not self._has_current_point:
            raise Error("Path.arc_to() called before any move_to() -- a path needs a starting point first")
        self.commands.append(
            _PathCommand(_ARC_TO, FPoint(cx, cy), FPoint(radius, start_angle), FPoint(end_angle, 0.0))
        )
        self._current_x = cx + radius * cos(end_angle)
        self._current_y = cy + radius * sin(end_angle)

    def close(mut self) raises:
        """Draw a straight segment back to this sub-path's own
        move_to and mark it closed -- stroke_path/stroke_path_aa draw
        a closed sub-path as a polygon (draw_polygon), an unclosed one
        as an open polyline (draw_polyline). Doesn't affect fill_path,
        which treats every sub-path as implicitly closed regardless
        (matching fill_polygon's own existing behavior).
        """
        if not self._has_current_point:
            raise Error("Path.close() called before any move_to() -- a path needs a starting point first")
        self.commands.append(_PathCommand(_CLOSE, FPoint(0.0, 0.0), FPoint(0.0, 0.0), FPoint(0.0, 0.0)))
        self._current_x = self._subpath_start_x
        self._current_y = self._subpath_start_y


def _quad_point(p0: FPoint, control: FPoint, p1: FPoint, t: Float64) -> FPoint:
    var mt = 1.0 - t
    var a = mt * mt
    var b = 2.0 * mt * t
    var c = t * t
    return FPoint(a * p0.x + b * control.x + c * p1.x, a * p0.y + b * control.y + c * p1.y)


def _cubic_point(p0: FPoint, c1: FPoint, c2: FPoint, p1: FPoint, t: Float64) -> FPoint:
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
    """One flattened sub-path: its points, and whether it was close()d
    -- a small struct instead of a second, parallel List[Bool] (see
    geometry.mojo's own docstring for why parallel lists are avoided
    here on principle, not just in that one file).
    """

    var points: List[Point]
    var closed: Bool

    def __init__(out self, var points: List[Point], closed: Bool):
        self.points = points^
        self.closed = closed


def _flatten(path: Path) -> List[_Subpath]:
    """Walk a Path's commands, flattening curves into straight-line
    steps, and split into one List[Point] per sub-path (a new one
    starting at each move_to after the first).
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
            for step in range(1, _CURVE_STEPS + 1):
                var t = Float64(step) / Float64(_CURVE_STEPS)
                var p = _quad_point(p0, cmd.p1, cmd.p2, t)
                current.append(Point(_round_to_int(p.x), _round_to_int(p.y)))
            cur_x = cmd.p2.x
            cur_y = cmd.p2.y
        elif cmd.kind == _CUBIC_TO:
            var p0 = FPoint(cur_x, cur_y)
            for step in range(1, _CURVE_STEPS + 1):
                var t = Float64(step) / Float64(_CURVE_STEPS)
                var p = _cubic_point(p0, cmd.p1, cmd.p2, cmd.p3, t)
                current.append(Point(_round_to_int(p.x), _round_to_int(p.y)))
            cur_x = cmd.p3.x
            cur_y = cmd.p3.y
        elif cmd.kind == _ARC_TO:
            # cmd.p1 = (cx, cy), cmd.p2 = (radius, start_angle),
            # cmd.p3.x = end_angle -- see _PathCommand's own docstring
            # for this packing. _arc_points includes the arc's own
            # start point (index 0), which should already equal
            # (cur_x, cur_y) per arc_to's own contract -- skipped here
            # the same way the quad/cubic branches above skip t=0.
            var arc_points = _arc_points(cmd.p1.x, cmd.p1.y, cmd.p2.x, cmd.p2.y, cmd.p3.x)
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
    """Every sub-path's edges' crossings of row y, combined into one
    list -- shared by fill_path/fill_path_gradient. This is the
    multi-sub-path analog of the single-loop crossing collection
    fill_polygon does inline (see canvas_mojo.shapes.polygon_fill); combining across
    ALL sub-paths here (not resetting per sub-path) is what makes
    hole-punching and (with FillRule.NONZERO) union-filling work --
    the same multi-contour technique fonts/raster.mojo used for
    TrueType glyphs' counters, before this package had its own general
    path type (see the wiki for that history).
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
    mut canvas: Canvas, path: Path, color: Color, fill_rule: FillRule = FillRule.EVEN_ODD
):
    """Fill a path's interior with the scanline algorithm, combining
    every sub-path's crossings per scanline into a signed winding
    number (see canvas_mojo.shapes.polygon_fill's _spans_from_crossings, shared with
    fill_polygon) -- see this module's own docstring for why combining
    across sub-paths matters (hole-punching), and fill_rule.mojo for
    what `fill_rule` (default EVEN_ODD, matching this function's
    original and still-unchanged behavior when unspecified) actually
    changes: with FillRule.NONZERO, two overlapping sub-paths wound
    the same rotational direction fill as one solid union instead of
    leaving a hole where they overlap.

    Not fill_polygon generalized to take multiple sub-paths -- a new,
    independent function, since fill_polygon's own single-polygon
    contract is a real API guarantee, not something to silently
    reinterpret.

    Same half-open Y-extent convention as fill_polygon
    ([min(y0,y1), max(y0,y1))), for the identical reason: it's what
    makes a vertex shared by two opposite-direction edges count once,
    not twice, while a genuine local extremum counts zero net
    crossings, not two.
    """
    var subpaths = _flatten(path)
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
    """The continuous-point analog of _row_crossings + _is_inside,
    combining every sub-path's edges into one signed winding number at
    an arbitrary real-valued point -- the same relationship
    canvas_mojo.shapes.polygon_fill's _point_in_polygon has to fill_polygon's own
    integer-row crossing scan, generalized here to multiple sub-paths
    the identical way _row_crossings already generalizes the discrete
    version. This is what fill_path_aa's supersampling needs, and
    (like _point_in_polygon) shares _is_inside with the discrete
    fill_path, so a hard-edged and AA fill of the same path agree on
    where the boundary is.
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


def _row_crossings_aa(subpaths: List[_Subpath], fy: Float64) -> List[_AACrossing]:
    """_point_in_subpaths's own per-sample ray-cast, factored out to
    run once per sub-scanline instead of once per sub-pixel sample --
    every edge crossing y=fy, in no particular order (sorted separately,
    see _sort_aa_crossings_by_x). See fill_path_aa's own docstring for
    why this split is what makes the whole sweep sub-quadratic.
    """
    var crossings = List[_AACrossing]()
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
                var direction = 1 if y1 > y0 else -1
                crossings.append(_AACrossing(x, direction))
    return crossings^


def fill_path_aa(
    mut canvas: Canvas,
    path: Path,
    color: Color,
    fill_rule: FillRule = FillRule.EVEN_ODD,
    supersample: Int = 4,
):
    """Anti-aliased fill_path -- fill_path's counterpart the same way
    fill_polygon_aa is fill_polygon's (see that function's own
    docstring in canvas_mojo.shapes.polygon_fill, the model this originally followed):
    for every pixel near the path's flattened outline, samples an NxN
    sub-pixel grid and turns the coverage fraction into that pixel's
    alpha. Each output pixel is visited exactly once.

    Same multi-sub-path hole-punching (and, with FillRule.NONZERO,
    union-filling) fill_path itself has -- every sub-path's winding
    contribution is combined before either fill rule is applied, not
    per-sub-path independently, for the identical reason fill_path's
    own docstring gives.

    Swept per sub-scanline, not per sub-pixel sample: _point_in_subpaths
    (this module's own naive per-sample membership test, still used
    directly by _point_in_subpaths' own tests, and kept as a plain
    reference implementation) would re-scan every one of a path's edges
    for every one of a pixel's supersample^2 sub-samples -- O(pixels *
    supersample^2 * edges) overall, fine for a small hand-drawn shape
    but a genuine problem for a large, edge-dense one (a big arc_to-
    built wedge or ribbon, say: arc_to's own point count scales with
    radius, see its own docstring, so a large enough one starts costing
    real seconds). Collecting a sub-scanline's crossings once (like
    fill_path's own _row_crossings, generalized here to sub-pixel y)
    instead of once per sample removes the `* edges` factor from the
    per-sample cost entirely: sort the crossings by x once (
    _sort_aa_crossings_by_x), precompute each one's own suffix winding
    sum, then sweep every sub-sample's x -- strictly increasing across
    the whole row, the same left-to-right pixel order the loop already
    visits -- against that sorted list with a single forward-only
    pointer, an O(1) amortized lookup per sample instead of O(edges).
    Same math as _point_in_subpaths' own ray cast at every sample
    point, just computed via a sweep instead of a fresh scan: every
    existing fill_path_aa/stroke_path_aa/text-rendering test (this
    package's own text rendering rasterizes through fill_path_aa, see
    canvas_mojo/text/render.mojo) still passes byte-identical after
    this rewrite, which is the real correctness bar here, not just the
    complexity argument.

    Not fused with fill_path behind an `antialias: Bool` -- same
    reasoning as every other hard/AA split in this codebase (see
    canvas_mojo.shapes.lines's own module docstring): a real complexity-class
    jump per pixel, not a free toggle.
    """
    var subpaths = _flatten(path)
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

    var s = supersample
    var total_samples = s * s
    var step = 1.0 / Float64(s)
    var row_first_px = min_x - 1
    var row_width = (max_x + 2) - row_first_px  # px range length, see the loop below

    for py in range(min_y - 1, max_y + 2):
        var row_covered = List[Int](capacity=row_width)
        for _ in range(row_width):
            row_covered.append(0)

        for sy in range(s):
            var fy = Float64(py) + (Float64(sy) + 0.5) * step - 0.5
            var crossings = _row_crossings_aa(subpaths, fy)
            _sort_aa_crossings_by_x(crossings)
            var k = len(crossings)

            # suffix[i] == the signed winding contributed by every
            # crossing from index i to the end -- crossings[idx:]'s own
            # combined direction, exactly what _point_in_subpaths' own
            # `x > fx` ray cast sums fresh per sample; see this
            # function's own docstring for why precomputing it here
            # (once per sub-scanline) instead removes the `* edges`
            # factor from the sweep below.
            var suffix = List[Int](capacity=k + 1)
            for _ in range(k + 1):
                suffix.append(0)
            for i in range(k - 1, -1, -1):
                suffix[i] = suffix[i + 1] + crossings[i].direction

            # fx is strictly increasing across this whole sweep (px
            # ascending, and each px's own sx sub-samples span a
            # narrower range than the gap to the next px -- see this
            # function's own docstring), so `idx` only ever moves
            # forward: an amortized O(1) lookup per sample, not a fresh
            # O(k) rescan.
            var idx = 0
            for pxi in range(row_width):
                var px = row_first_px + pxi
                for sx in range(s):
                    var fx = Float64(px) + (Float64(sx) + 0.5) * step - 0.5
                    while idx < k and crossings[idx].x <= fx:
                        idx += 1
                    if _is_inside(suffix[idx], fill_rule):
                        row_covered[pxi] += 1

        for pxi in range(row_width):
            var covered = row_covered[pxi]
            if covered > 0:
                var px = row_first_px + pxi
                var alpha = UInt8(
                    Int(Float64(covered) / Float64(total_samples) * Float64(color.a) + 0.5)
                )
                canvas.set_pixel(px, py, Color(color.r, color.g, color.b, alpha))


def fill_path_gradient(
    mut canvas: Canvas,
    path: Path,
    gradient: LinearGradient,
    fill_rule: FillRule = FillRule.EVEN_ODD,
):
    """Fill a path's interior the same way fill_path does, but
    sourcing each pixel's color from `gradient` (see gradient.mojo)
    instead of one flat Color. Same scanline structure as fill_path,
    kept as its own function rather than a shared core parameterized
    over "how to get a color" -- matches this codebase's general
    tolerance for a bit of duplication between near-identical
    primitive pairs (e.g. fill_circle_aa/draw_circle_aa) over forcing
    a premature shared abstraction for two call sites.
    """
    var subpaths = _flatten(path)
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
                canvas.set_pixel(x, y, gradient.color_at(Float64(x), Float64(y)))


def fill_path_radial_gradient(
    mut canvas: Canvas,
    path: Path,
    gradient: RadialGradient,
    fill_rule: FillRule = FillRule.EVEN_ODD,
):
    """Fill a path's interior the same way fill_path does, but
    sourcing each pixel's color from `gradient` (a RadialGradient --
    see gradient.mojo) instead of one flat Color. Same reasoning as
    fill_path_gradient for staying its own function rather than a
    shared core parameterized over "how to get a color".
    """
    var subpaths = _flatten(path)
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
                canvas.set_pixel(x, y, gradient.color_at(Float64(x), Float64(y)))


def stroke_path(
    mut canvas: Canvas,
    path: Path,
    color: Color,
    dashes: List[Float64] = List[Float64](),
    dash_offset: Float64 = 0.0,
):
    """Stroke every sub-path, hard-edged 1px -- closed ones
    (close() was called) via draw_polygon, open ones via draw_polyline.
    """
    var subpaths = _flatten(path)
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
    dashes: List[Float64] = List[Float64](),
    dash_offset: Float64 = 0.0,
):
    """Anti-aliased version of stroke_path -- see draw_polyline_aa/
    draw_polygon_aa.
    """
    var subpaths = _flatten(path)
    for sp_idx in range(len(subpaths)):
        ref sp = subpaths[sp_idx]
        if sp.closed:
            draw_polygon_aa(canvas, sp.points, color, width, supersample, dashes, dash_offset)
        else:
            draw_polyline_aa(canvas, sp.points, color, width, supersample, dashes, dash_offset)
