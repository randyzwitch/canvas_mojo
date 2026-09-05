"""Line, polyline, and polygon-*outline* drawing: Bresenham hard-edged
(draw_line/draw_polyline/draw_polygon), supersampled analytic-coverage
anti-aliased (draw_line_aa/draw_polyline_aa/draw_polygon_aa), and the
dash-aware cores they share (_draw_line_core, _draw_polyline_core_aa).

`draw_polygon`/`draw_polygon_aa` here draw the *outline* only. The
*interior* fills, `fill_polygon`/`fill_polygon_aa`, are a different
scanline algorithm in canvas.shapes.polygon_fill.

Naming convention across canvas.shapes/: hard-edged and anti-aliased
variants are separate functions (draw_circle vs. draw_circle_aa), never
one function behind an `antialias: Bool`. The two differ in complexity
class -- hard-edged circle drawing is O(radius), AA is
O(radius^2 * supersample^2) -- and in which parameters apply, since
Bresenham is definitionally 1px and takes no `width`.
"""

from std.math import atan2, ceil, cos, floor, pi, sin, sqrt

from canvas.color import Color
from canvas.buffer import Canvas
from canvas.geometry import (
    Matrix2D,
    Point,
    FPoint,
    _mapped_points,
    round_to_int,
    _scaled_lengths,
)
from canvas.aa_area import _area_edges_aa
from canvas.aa_crossing import _EdgeTable, _sweep_edges_sampled_aa
from canvas.fill_rule import FillRule
from canvas.shapes.dash import _DashPattern

comptime _SQRT2 = 1.4142135623730951


struct LineCap(Copyable, ImplicitlyCopyable, Movable):
    """How an open stroke ends.

    ROUND, the default, caps with a half-disk of the stroke's radius, so
    a stroke extends half its width past each endpoint -- a 4px round cap
    on a rule from x=40 to x=560 spans 38 to 562. BUTT stops exactly at
    the endpoint. SQUARE stops half a width past it, flat.

    Caps apply only to the two ends of an *open* stroke; a closed polygon
    has no ends and ignores them.
    """

    var _value: Int

    comptime ROUND = Self(0)
    comptime BUTT = Self(1)
    comptime SQUARE = Self(2)

    def __init__(out self, value: Int):
        """Prefer the ROUND/BUTT/SQUARE comptime constants over
        constructing one directly.

        Args:
            value: 0 for ROUND, 1 for BUTT, 2 for SQUARE.
        """
        self._value = value

    def __eq__(self, other: Self) -> Bool:
        return self._value == other._value

    def __ne__(self, other: Self) -> Bool:
        return self._value != other._value


def _draw_line_core(
    mut canvas: Canvas,
    x0: Int,
    y0: Int,
    x1: Int,
    y1: Int,
    color: Color,
    skip_first: Bool,
    skip_last: Bool,
    pattern: _DashPattern,
    dash_start_distance: Float64 = 0.0,
) -> Float64:
    """Bresenham's line algorithm -- integer-only, works for any slope
    or direction. skip_first/skip_last let draw_polyline/draw_polygon
    omit a segment's shared endpoint with its neighbor, so a
    translucent color doesn't get blended twice at every joint.

    Returns the total distance traveled -- the sum of per-step Euclidean
    lengths, 1.0 for an axis step and sqrt(2) for a diagonal one -- so
    draw_polyline/draw_polygon can carry a dash pattern's phase across a
    joint. That is the accumulated raster-walk distance, not the
    idealized sqrt(dx^2+dy^2); the two are close but not bit-identical.
    """
    var dx = abs(x1 - x0)
    var dy = -abs(y1 - y0)
    var sx = 1 if x0 < x1 else -1
    var sy = 1 if y0 < y1 else -1
    var err = dx + dy
    var x = x0
    var y = y0
    var first = True
    var distance = dash_start_distance
    # Hoisted: a solid stroke is every caller that doesn't pass
    # `dashes`, and `is_on` would otherwise be a call per pixel to
    # answer the same True.
    var solid = pattern.solid

    while True:
        var is_last = x == x1 and y == y1
        var on_dash = solid or pattern.is_on(distance)
        if on_dash and not ((first and skip_first) or (is_last and skip_last)):
            canvas.set_pixel(x, y, color)
        first = False
        if is_last:
            break
        var e2 = 2 * err
        var stepped_x = False
        var stepped_y = False
        if e2 >= dy:
            err += dy
            x += sx
            stepped_x = True
        if e2 <= dx:
            err += dx
            y += sy
            stepped_y = True
        distance += _SQRT2 if (stepped_x and stepped_y) else 1.0

    return distance


def draw_line(
    mut canvas: Canvas,
    x0: Int,
    y0: Int,
    x1: Int,
    y1: Int,
    color: Color,
    dashes: List[Float64] = List[Float64](),
    dash_offset: Float64 = 0.0,
):
    """Bresenham's line algorithm -- integer-only, works for any slope
    or direction.

    `dashes` is an optional alternating on/off length pattern (see
    _is_dash_on); empty by default, drawing solid. Measured in the
    accumulated-raster-step distance _draw_line_core describes, not an
    idealized straight-line one.

    Args:
        canvas: Canvas to draw into.
        x0: Start point x.
        y0: Start point y.
        x1: End point x.
        y1: End point y.
        color: Line color.
        dashes: On/off segment lengths in pixels, cycled along the
            line. Empty (default) draws a solid line.
        dash_offset: Distance into the dash pattern the line starts at.
    """
    if canvas.has_transform():
        var m = canvas.current_transform()
        var p0 = m.apply(Float64(x0), Float64(y0))
        var p1 = m.apply(Float64(x1), Float64(y1))
        var s = m.scale_factor()
        _draw_line_device(
            canvas,
            round_to_int(p0.x),
            round_to_int(p0.y),
            round_to_int(p1.x),
            round_to_int(p1.y),
            color,
            _scaled_lengths(dashes, s),
            dash_offset * s,
        )
        return
    _draw_line_device(canvas, x0, y0, x1, y1, color, dashes, dash_offset)


def _draw_line_device(
    mut canvas: Canvas,
    x0: Int,
    y0: Int,
    x1: Int,
    y1: Int,
    color: Color,
    dashes: List[Float64] = List[Float64](),
    dash_offset: Float64 = 0.0,
):
    """`draw_line` for device-space arguments: the body every
    call lands in. It has no transform check of its own, so its
    loops compile with nothing ahead of them and it never calls
    back into the public function.
    """
    var pattern = _DashPattern(dashes, dash_offset)
    _ = _draw_line_core(canvas, x0, y0, x1, y1, color, False, False, pattern)


def draw_line_aa(
    mut canvas: Canvas,
    x0: Int,
    y0: Int,
    x1: Int,
    y1: Int,
    color: Color,
    width: Float64 = 1.0,
    supersample: Int = 4,
    dashes: List[Float64] = List[Float64](),
    dash_offset: Float64 = 0.0,
    cap: LineCap = LineCap.ROUND,
    join: LineJoin = LineJoin.ROUND,
    miter_limit: Float64 = 4.0,
):
    """Anti-aliased line, `width` pixels wide (default 1), finished
    with `cap` at each end.

    A one-segment polyline, and drawn as one: `_draw_polyline_core_aa`
    turns the stroke into an outline and fills it, so the cost follows
    the stroke's area rather than its bounding box.

    Args:
        canvas: Canvas to draw into.
        x0: Start point x.
        y0: Start point y.
        x1: End point x.
        y1: End point y.
        color: Line color.
        width: Stroke width in pixels.
        supersample: Sub-pixel grid side length per pixel (N -> N*N
            samples) for a stroke whose outline is not simple (a
            hairpin, a reversal); a simple outline rasterizes by
            exact area and ignores it. See `_stroke_edges`.
        dashes: On/off segment lengths in pixels, cycled along the
            line. Empty (default) draws a solid line.
        dash_offset: Distance into the dash pattern the line starts at.
        cap: How the two ends are finished -- see LineCap.
        join: Unused for a single segment, which has no corners.
        miter_limit: Unused for a single segment.
    """
    draw_line_aa(
        canvas,
        Float64(x0),
        Float64(y0),
        Float64(x1),
        Float64(y1),
        color,
        width,
        supersample,
        dashes,
        dash_offset,
        cap,
        join,
        miter_limit,
    )


def draw_line_aa(
    mut canvas: Canvas,
    x0: Float64,
    y0: Float64,
    x1: Float64,
    y1: Float64,
    color: Color,
    width: Float64 = 1.0,
    supersample: Int = 4,
    dashes: List[Float64] = List[Float64](),
    dash_offset: Float64 = 0.0,
    cap: LineCap = LineCap.ROUND,
    join: LineJoin = LineJoin.ROUND,
    miter_limit: Float64 = 4.0,
):
    """`draw_line_aa` at sub-pixel endpoints -- the same line, placed
    to a fraction of a pixel rather than snapped to the pixel grid.

    This is the real implementation; the whole-pixel overload above
    converts and calls it. Placing a value at x = 103.7 rather than
    rounding to 104 shifts the line by a third of a pixel, which at a 1px
    stroke width is visible.

    Args:
        canvas: Canvas to draw into.
        x0: Start point x.
        y0: Start point y.
        x1: End point x.
        y1: End point y.
        color: Line color.
        width: Stroke width in pixels.
        supersample: Sub-pixel grid side length per pixel (N -> N*N
            samples) for a stroke whose outline is not simple (a
            hairpin, a reversal); a simple outline rasterizes by
            exact area and ignores it. See `_stroke_edges`.
        dashes: On/off segment lengths in pixels, cycled along the
            line. Empty (default) draws a solid line.
        dash_offset: Distance into the dash pattern the line starts at.
        cap: How the two ends are finished -- see LineCap.
        join: Unused for a single segment, which has no corners.
        miter_limit: Unused for a single segment.
    """
    var points: List[FPoint] = [FPoint(x0, y0), FPoint(x1, y1)]
    _draw_polyline_core_aa(
        canvas,
        points,
        color,
        width,
        supersample,
        False,
        dashes,
        dash_offset,
        cap,
        join,
        miter_limit,
    )


def draw_polyline(
    mut canvas: Canvas,
    points: List[Point],
    color: Color,
    dashes: List[Float64] = List[Float64](),
    dash_offset: Float64 = 0.0,
):
    """Connect consecutive points with line segments (Bresenham).

    Not closed; draw_polygon closes. Each interior joint is drawn by
    exactly one segment (the next skips its shared start point), so a
    translucent color is not blended twice where segments meet. Dash
    phase carries across joints rather than resetting at a corner.

    Args:
        canvas: Canvas to draw into.
        points: Vertices to connect, in order.
        color: Line color.
        dashes: On/off segment lengths in pixels, cycled along the
            whole polyline. Empty (default) draws a solid line.
        dash_offset: Distance into the dash pattern the polyline
            starts at.
    """
    if canvas.has_transform():
        var m = canvas.current_transform()
        var s = m.scale_factor()
        _draw_polyline_device(
            canvas,
            _mapped_points(m, points),
            color,
            _scaled_lengths(dashes, s),
            dash_offset * s,
        )
        return
    _draw_polyline_device(canvas, points, color, dashes, dash_offset)


def _draw_polyline_device(
    mut canvas: Canvas,
    points: List[Point],
    color: Color,
    dashes: List[Float64] = List[Float64](),
    dash_offset: Float64 = 0.0,
):
    """`draw_polyline` for device-space arguments: the body every
    call lands in. It has no transform check of its own, so its
    loops compile with nothing ahead of them and it never calls
    back into the public function.
    """
    if len(points) == 0:
        return
    if len(points) == 1:
        canvas.set_pixel(points[0].x, points[0].y, color)
        return

    var pattern = _DashPattern(dashes, dash_offset)
    var distance = 0.0
    for i in range(len(points) - 1):
        var a = points[i]
        var b = points[i + 1]
        distance = _draw_line_core(
            canvas, a.x, a.y, b.x, b.y, color, i > 0, False, pattern, distance
        )


def draw_polygon(
    mut canvas: Canvas,
    points: List[Point],
    color: Color,
    dashes: List[Float64] = List[Float64](),
    dash_offset: Float64 = 0.0,
):
    """Like draw_polyline, but closes the shape by connecting the
    last point back to the first.

    The closing segment skips both its shared start point (drawn by
    the previous segment) and its shared end point (drawn as the
    polygon's first pixel), so every vertex is drawn exactly once. Dash
    phase carries all the way around, closing segment included.

    Args:
        canvas: Canvas to draw into.
        points: Vertices to connect, in order.
        color: Line color.
        dashes: On/off segment lengths in pixels, cycled all the way
            around the polygon. Empty (default) draws a solid line.
        dash_offset: Distance into the dash pattern the polygon starts
            at.
    """
    if canvas.has_transform():
        var m = canvas.current_transform()
        var s = m.scale_factor()
        _draw_polygon_device(
            canvas,
            _mapped_points(m, points),
            color,
            _scaled_lengths(dashes, s),
            dash_offset * s,
        )
        return
    _draw_polygon_device(canvas, points, color, dashes, dash_offset)


def _draw_polygon_device(
    mut canvas: Canvas,
    points: List[Point],
    color: Color,
    dashes: List[Float64] = List[Float64](),
    dash_offset: Float64 = 0.0,
):
    """`draw_polygon` for device-space arguments: the body every
    call lands in. It has no transform check of its own, so its
    loops compile with nothing ahead of them and it never calls
    back into the public function.
    """
    var n = len(points)
    if n == 0:
        return
    if n == 1:
        canvas.set_pixel(points[0].x, points[0].y, color)
        return
    if n == 2:
        _draw_line_device(
            canvas,
            points[0].x,
            points[0].y,
            points[1].x,
            points[1].y,
            color,
            dashes,
            dash_offset,
        )
        return

    var pattern = _DashPattern(dashes, dash_offset)
    var distance = 0.0
    for i in range(n - 1):
        var a = points[i]
        var b = points[i + 1]
        distance = _draw_line_core(
            canvas, a.x, a.y, b.x, b.y, color, i > 0, False, pattern, distance
        )

    var last = points[n - 1]
    var first = points[0]
    _ = _draw_line_core(
        canvas,
        last.x,
        last.y,
        first.x,
        first.y,
        color,
        True,
        True,
        pattern,
        distance,
    )


def _draw_polyline_core_aa(
    mut canvas: Canvas,
    points: List[FPoint],
    color: Color,
    width: Float64,
    supersample: Int,
    closed: Bool,
    dashes: List[Float64] = List[Float64](),
    dash_offset: Float64 = 0.0,
    cap: LineCap = LineCap.ROUND,
    join: LineJoin = LineJoin.ROUND,
    miter_limit: Float64 = 4.0,
):
    """Shared implementation for draw_polyline_aa/draw_polygon_aa.

    The whole stroke -- every segment, its caps and its joins -- becomes
    one closed outline via `_stroke_edges` and is filled once with
    FillRule.NONZERO, so a pixel under two overlapping segments is
    written exactly once.
    """
    if canvas.has_transform():
        _stroke_transformed(
            canvas,
            points,
            color,
            width,
            supersample,
            closed,
            dashes,
            dash_offset,
            cap,
            join,
            miter_limit,
        )
        return
    var count = len(points)
    if count == 0:
        return
    if count == 1:
        canvas.set_pixel(
            round_to_int(points[0].x), round_to_int(points[0].y), color
        )
        return

    # Every stroke, dashed or not, goes through the path fill --
    # exact area for a simple outline, the sampled sweep otherwise;
    # see `_stroke_edges`. Both are parallel across cores.
    var shape = _stroke_edges(
        points,
        closed,
        width / 2.0,
        cap,
        dashes,
        dash_offset,
        join,
        miter_limit,
        Matrix2D.identity(),
    )
    _rasterize_stroke(canvas, shape, color, supersample)


def _stroke_transformed(
    mut canvas: Canvas,
    points: List[FPoint],
    color: Color,
    width: Float64,
    supersample: Int,
    closed: Bool,
    dashes: List[Float64],
    dash_offset: Float64,
    cap: LineCap,
    join: LineJoin,
    miter_limit: Float64,
):
    """`_draw_polyline_core_aa` under a canvas transform. The stroke is
    built in user space -- its width, dashes, caps and joins are what
    the caller asked for in the coordinates it drew in, as Cairo and
    the HTML5 canvas define them -- and every edge of its outline is
    mapped to device space as it is added (`_EdgeTable.set_map`), so a
    non-uniform scale makes a vertical stroke wider than a horizontal
    one exactly as it stretches the shapes around it.
    """
    var count = len(points)
    if count == 0:
        return
    var matrix = canvas.current_transform()
    if count == 1:
        var p = matrix.apply(points[0].x, points[0].y)
        canvas.set_pixel(round_to_int(p.x), round_to_int(p.y), color)
        return

    var shape = _stroke_edges(
        points,
        closed,
        width / 2.0,
        cap,
        dashes,
        dash_offset,
        join,
        miter_limit,
        matrix,
    )
    _rasterize_stroke(canvas, shape, color, supersample)


struct LineJoin(Copyable, ImplicitlyCopyable, Movable):
    """How a stroke turns a corner.

    ROUND, the default, fills the corner with a disk of the stroke's
    radius. BEVEL cuts it off flat, joining the two outer corners. MITER
    extends both outer edges until they meet, giving a sharp point.

    MITER needs a limit: as a corner tightens its apex runs away towards
    infinity, sticking out more than eleven times the half-width at 10
    degrees, so past `miter_limit` the join falls back to BEVEL. That is
    SVG's rule, and its default of 4 trips at about 29 degrees.

    Joins apply only where a stroke turns; the ends of an open stroke are
    a cap.
    """

    var _value: Int

    comptime ROUND = Self(0)
    comptime BEVEL = Self(1)
    comptime MITER = Self(2)

    def __init__(out self, value: Int):
        """Prefer the ROUND/BEVEL/MITER comptime constants over
        constructing one directly.

        Args:
            value: 0 for ROUND, 1 for BEVEL, 2 for MITER.
        """
        self._value = value

    def __eq__(self, other: Self) -> Bool:
        return self._value == other._value

    def __ne__(self, other: Self) -> Bool:
        return self._value != other._value


def _add_round_dot(
    mut edges: _EdgeTable, cx: Float64, cy: Float64, radius: Float64
):
    """A lone point's round cap, or a closed path collapsed to a point:
    a polygon approximating the disk of `radius` at (cx, cy), at the
    same vertex density `_arc_points` uses.
    """
    if radius <= 0.0:
        return
    var steps = _arc_steps(radius, 2.0 * pi)
    var px = cx + radius
    var py = cy
    for i in range(1, steps + 1):
        var t = Float64(i) / Float64(steps) * (2.0 * pi)
        var qx = cx + radius * cos(t)
        var qy = cy + radius * sin(t)
        edges.add_edge(px, py, qx, qy)
        px = qx
        py = qy


# How deep a notch a joint may leave before it needs a round disk to
# fill it, in pixels. A fiftieth of a pixel is a fifth of a sub-sample
# at the default supersample, so a skipped joint cannot move a
# coverage count.
comptime _JOIN_DISK_TOLERANCE = 0.02


def _rasterize_stroke(
    mut canvas: Canvas,
    mut shape: _StrokeShape,
    color: Color,
    supersample: Int,
):
    """Fill a stroke's edges by the rasterizer its shape calls for:
    exact area for a simple outline, the sampled sweep under nonzero
    for overlapping pieces.
    """
    if len(shape.edges.y_lo) == 0:
        return
    var b = shape.edges.bounds()
    if shape.exact:
        _area_edges_aa(canvas, shape.edges, b[0], b[1], b[2], b[3], color)
        return
    _sweep_edges_sampled_aa(
        canvas,
        shape.edges,
        b[0],
        b[1],
        b[2],
        b[3],
        color,
        FillRule.NONZERO,
        supersample,
    )


def _add_polygon(mut edges: _EdgeTable, xs: List[Float64], ys: List[Float64]):
    """A closed polygon, wound to match `_add_quad`.

    The winding is checked rather than assumed: a join's corner order
    depends on which way the path turns, and handing NONZERO a polygon
    of the wrong orientation makes it *cancel* against the quads it
    should be filling in -- a hole exactly where the join was meant to
    be.
    """
    var n = len(xs)
    if n < 3:
        return
    var area2 = 0.0
    for i in range(n):
        var j = (i + 1) % n
        area2 += xs[i] * ys[j] - xs[j] * ys[i]
    if area2 < 0.0:
        for i in range(n):
            var j = (i + 1) % n
            edges.add_edge(xs[i], ys[i], xs[j], ys[j])
    else:
        for i in range(n - 1, -1, -1):
            var j = (i - 1 + n) % n
            edges.add_edge(xs[i], ys[i], xs[j], ys[j])


def _add_join(
    mut edges: _EdgeTable,
    vx: Float64,
    vy: Float64,
    ux: Float64,
    uy: Float64,
    wx: Float64,
    wy: Float64,
    half_width: Float64,
    join: LineJoin,
    miter_limit: Float64,
):
    """The wedge a stroke leaves on the outside of a corner at (vx, vy),
    arriving along unit (ux, uy) and leaving along unit (wx, wy).

    BEVEL and MITER need to know which side is outside: the side away
    from the turn, found from the cross product of the two directions.
    Getting it backwards fills the *inner* corner, which both quads
    already cover, so nothing appears to change until a wide stroke makes
    the missing outer wedge obvious.
    """
    if join == LineJoin.ROUND:
        _add_disk(edges, vx, vy, half_width)
        return

    var cross = ux * wy - uy * wx
    if cross == 0.0:
        # Straight through, or a perfect reversal. Nothing to fill in
        # the first case; in the second there is no outer side at all
        # and a disk is the only sensible answer.
        if ux * wx + uy * wy < 0.0:
            _add_disk(edges, vx, vy, half_width)
        return
    var side = -1.0 if cross > 0.0 else 1.0

    # Outer corner of each adjoining quad.
    var ax = vx + side * -uy * half_width
    var ay = vy + side * ux * half_width
    var bx = vx + side * -wy * half_width
    var by = vy + side * wx * half_width

    if join == LineJoin.MITER:
        var dot = ux * wx + uy * wy
        var denom = 1.0 + dot
        if denom > 1.0e-12:
            # Apex at V + h * (n_in + n_out) / (1 + n_in . n_out), the
            # standard miter point; its distance from V is
            # half_width / cos(theta/2), which is what the limit caps.
            var mx = vx + (ax - vx + bx - vx) / denom
            var my = vy + (ay - vy + by - vy) / denom
            var dx = mx - vx
            var dy = my - vy
            if sqrt(dx * dx + dy * dy) <= miter_limit * half_width:
                var xs: List[Float64] = [vx, ax, mx, bx]
                var ys: List[Float64] = [vy, ay, my, by]
                _add_polygon(edges, xs, ys)
                return
        # Past the limit (or a near-reversal): fall back to bevel,
        # which is what SVG specifies rather than dropping the join.

    var xs: List[Float64] = [vx, ax, bx]
    var ys: List[Float64] = [vy, ay, by]
    _add_polygon(edges, xs, ys)


def _add_quad(
    mut edges: _EdgeTable,
    ax: Float64,
    ay: Float64,
    bx: Float64,
    by: Float64,
    nx: Float64,
    ny: Float64,
):
    """One segment's body: the rectangle of half-width |n| centred on
    a->b, with (nx, ny) its offset normal.

    Wound consistently with `_add_disk` below, which is what lets
    NONZERO treat the union of every quad and disk as one solid shape
    -- overlapping pieces reinforce rather than cancel, and every pixel
    is still written exactly once.
    """
    edges.add_edge(ax + nx, ay + ny, bx + nx, by + ny)
    edges.add_edge(bx + nx, by + ny, bx - nx, by - ny)
    edges.add_edge(bx - nx, by - ny, ax - nx, ay - ny)
    edges.add_edge(ax - nx, ay - ny, ax + nx, ay + ny)


def _add_disk(mut edges: _EdgeTable, cx: Float64, cy: Float64, radius: Float64):
    """A round join or cap: a polygon approximating the disk of
    `radius` at (cx, cy).

    Sampled at two points per pixel of circumference with a floor of
    16, so a hairline stroke's joins cost a handful of edges and a thick
    one's cost enough to stay smooth.
    """
    if radius <= 0.0:
        return
    # The floor is what matters at the hairline widths a chart actually
    # uses: at radius 1 an inscribed 8-gon sits up to 0.076px inside the
    # true circle, which is a third of a sub-sample and shows up as tens
    # of alpha levels on a boundary pixel.
    var steps = Int(4.0 * pi * radius)
    if steps < 16:
        steps = 16

    # Vertices pushed out to the mid-radius rather than sitting on the
    # circle. An inscribed polygon only ever under-covers; splitting
    # the difference centres the error instead of biasing every join
    # and cap thin.
    var r = radius * (1.0 + 1.0 / cos(pi / Float64(steps))) * 0.5
    # Wound the same way `_add_quad` winds, which for a segment along
    # +x comes out negative (clockwise in the standard orientation, y
    # running down the screen here). Sampling the disk the other way
    # round makes NONZERO *cancel* the overlap between a joint's disk
    # and the quads meeting there rather than union it -- which is a
    # hole at every joint, not a rounding difference.
    var px = cx + r
    var py = cy
    for i in range(1, steps + 1):
        var t = -Float64(i) / Float64(steps) * (2.0 * pi)
        var qx = cx + r * cos(t)
        var qy = cy + r * sin(t)
        edges.add_edge(px, py, qx, qy)
        px = qx
        py = qy


def _stroke_pieces(
    points: List[FPoint],
    closed: Bool,
    half_width: Float64,
    cap: LineCap,
    dashes: List[Float64],
    dash_offset: Float64,
    join: LineJoin,
    miter_limit: Float64,
    matrix: Matrix2D,
) -> _EdgeTable:
    """A stroke as the union of pieces, for the sampled sweep: what
    `_stroke_edges` falls back to when the outline it would rather
    build is not simple (see there).

    A stroke is every point within `half_width` of some *drawn* part of
    the path, which is the union of one rectangle per drawn stretch and
    one disk per vertex it turns through. The sweep's per-sample
    winding test takes that union exactly, overlaps and all.

    Dashing is geometric: each segment is split at its dash boundaries
    once and only the drawn pieces are emitted.

    A drawn piece is a stadium -- a quad plus a disk at each end. Those
    end disks make a dash's ends round regardless of `cap`, which
    describes the two ends of the *stroke*, not of every dash.
    """
    var count = len(points)
    if count == 0 or half_width <= 0.0:
        return _EdgeTable()

    var pattern = _DashPattern(dashes, dash_offset)
    if count == 1:
        var single = _EdgeTable()
        single.set_map(matrix)
        if pattern.is_on(0.0) and (closed or cap == LineCap.ROUND):
            _add_disk(single, points[0].x, points[0].y, half_width)
        return single^

    var num_segments = count if closed else count - 1
    var capped = (not closed) and cap != LineCap.ROUND
    # 4 edges per segment's quad body is the guaranteed lower bound;
    # joins and caps add more only where a join isn't skipped by the
    # sagitta test below, which for a flattened curve is most of them.
    # Reserving the guaranteed part turns what would otherwise be
    # several doubling reallocations per list, across tens of
    # thousands of edges for a long stroked series, into at most one.
    var edges = _EdgeTable(4 * num_segments)
    edges.set_map(matrix)
    # The notch tolerance is in device pixels and the sagitta below is
    # measured in user space, so it shrinks by the map's scale.
    var tolerance = _JOIN_DISK_TOLERANCE
    var map_scale = matrix.scale_factor()
    if map_scale > 0.0:
        tolerance = _JOIN_DISK_TOLERANCE / map_scale

    # Endpoints per segment, with SQUARE's extension already folded in
    # so distances below are measured along the geometry actually
    # drawn.
    var ax = List[Float64](capacity=num_segments)
    var ay = List[Float64](capacity=num_segments)
    var bx = List[Float64](capacity=num_segments)
    var by = List[Float64](capacity=num_segments)
    var seg_len = List[Float64](capacity=num_segments)
    var seg_start = List[Float64](capacity=num_segments)
    var running = 0.0
    for seg in range(num_segments):
        var a = points[seg]
        var b = points[(seg + 1) % count]
        var dx = b.x - a.x
        var dy = b.y - a.y
        var length = sqrt(dx * dx + dy * dy)
        if length > 0.0 and cap == LineCap.SQUARE and capped:
            var ux = dx / length
            var uy = dy / length
            if seg == 0:
                a = FPoint(a.x - ux * half_width, a.y - uy * half_width)
            if seg == num_segments - 1:
                b = FPoint(b.x + ux * half_width, b.y + uy * half_width)
            dx = b.x - a.x
            dy = b.y - a.y
            length = sqrt(dx * dx + dy * dy)
        ax.append(a.x)
        ay.append(a.y)
        bx.append(b.x)
        by.append(b.y)
        seg_len.append(length)
        seg_start.append(running)
        running += length

    # Walk the path, emitting the drawn stretches.
    #
    # A dash piece is a plain rectangle, not a stadium: dash ends are
    # butt, and the only round ends in a dashed stroke are at the
    # segments' own endpoints. Rounding every dash end would extend
    # each piece by half a width at both ends and close the gaps -- a
    # [5, 3] pattern at width 2 would render as an almost-solid line.
    for seg in range(num_segments):
        var length = seg_len[seg]
        if length == 0.0:
            # A repeated point still contributes a disk: anything
            # within half_width of it is covered when that distance is
            # drawn.
            if pattern.is_on(seg_start[seg]):
                _add_disk(edges, ax[seg], ay[seg], half_width)
            continue

        var ux = (bx[seg] - ax[seg]) / length
        var uy = (by[seg] - ay[seg]) / length
        var nx = -uy * half_width
        var ny = ux * half_width
        var seg_end_d = seg_start[seg] + length

        var reached_end = False
        var last_piece_start = seg_start[seg]
        var d = seg_start[seg]
        while d < seg_end_d:
            var on = pattern.is_on(d)
            var next_d = pattern.next_boundary(d)
            if next_d > seg_end_d:
                next_d = seg_end_d
            if on:
                var t0 = (d - seg_start[seg]) / length
                var t1 = (next_d - seg_start[seg]) / length
                _add_quad(
                    edges,
                    ax[seg] + (bx[seg] - ax[seg]) * t0,
                    ay[seg] + (by[seg] - ay[seg]) * t0,
                    ax[seg] + (bx[seg] - ax[seg]) * t1,
                    ay[seg] + (by[seg] - ay[seg]) * t1,
                    nx,
                    ny,
                )
                last_piece_start = d
                reached_end = next_d == seg_end_d
            else:
                reached_end = False
            d = next_d

        # The open stroke's start cap, on the first segment only.
        if seg == 0 and not closed:
            if (not capped) and pattern.is_on(seg_start[0]):
                _add_disk(edges, ax[0], ay[0], half_width)

        # ...and the segment's far endpoint.
        if not pattern.is_on(seg_end_d):
            continue  # nothing is drawn at this endpoint

        var is_last = seg == num_segments - 1
        if is_last and not closed:
            if not capped:
                _add_disk(edges, bx[seg], by[seg], half_width)
            continue

        # A joint. Two quads meeting at a turn of angle theta leave a
        # wedge of depth half_width * (1 - cos(theta/2)), so a
        # nearly-straight joint that is drawn on both sides is already
        # covered and needs no disk. That test is not a micro-
        # optimisation: a flattened curve is thousands of
        # nearly-collinear segments, and a disk at every one of them
        # buries the sweep in edges it gains nothing from.
        var nxt = (seg + 1) % num_segments
        if not reached_end or seg_len[nxt] == 0.0:
            _add_disk(edges, bx[seg], by[seg], half_width)
            continue
        var jvx = (bx[nxt] - ax[nxt]) / seg_len[nxt]
        var jvy = (by[nxt] - ay[nxt]) / seg_len[nxt]

        # The wedge argument below assumes both quads reach at least
        # half_width back from the joint -- otherwise the disk pokes
        # out past a quad's far end, where nothing covers it. A short
        # dash piece is exactly that case, so the drawn run on each
        # side has to be long enough before the disk can be skipped.
        var before = seg_end_d - last_piece_start
        var after_end = pattern.next_boundary(seg_end_d)
        var next_seg_end = seg_end_d + seg_len[nxt]
        if after_end > next_seg_end:
            after_end = next_seg_end
        var after = after_end - seg_end_d
        if before < half_width or after < half_width:
            _add_join(
                edges,
                bx[seg],
                by[seg],
                ux,
                uy,
                jvx,
                jvy,
                half_width,
                join,
                miter_limit,
            )
            continue

        var dot = ux * jvx + uy * jvy
        if dot > 1.0:
            dot = 1.0
        elif dot < -1.0:
            dot = -1.0
        # half_width * (1 - cos(theta/2)), using
        # cos(theta/2) = sqrt((1 + cos theta) / 2).
        var sagitta = half_width * (1.0 - sqrt((1.0 + dot) * 0.5))
        if sagitta > tolerance:
            _add_join(
                edges,
                bx[seg],
                by[seg],
                ux,
                uy,
                jvx,
                jvy,
                half_width,
                join,
                miter_limit,
            )

    return edges^


def _arc_steps(radius: Float64, sweep: Float64) -> Int:
    """How many straight pieces an arc of `radius` through `sweep`
    radians is drawn with: two per pixel of circumference with a floor
    of sixteen per full turn, so a hairline's caps cost a handful of
    edges and a thick stroke's stay smooth. The floor is what matters
    at chart widths: an inscribed 8-gon at radius 1 sits 0.076 px
    inside the true circle, which is visible on a boundary pixel.
    """
    var full = Int(4.0 * pi * radius)
    if full < 16:
        full = 16
    var steps = Int(ceil(Float64(full) * abs(sweep) / (2.0 * pi)))
    if steps < 1:
        steps = 1
    return steps


def _arc_points(
    mut xs: List[Float64],
    mut ys: List[Float64],
    cx: Float64,
    cy: Float64,
    from_x: Float64,
    from_y: Float64,
    sweep: Float64,
    radius: Float64,
):
    """Append the interior vertices of the arc about (cx, cy) that
    starts in the direction of (from_x, from_y) and turns through
    `sweep` radians (signed). Neither endpoint is appended: the caller
    places both exactly, on the offset lines they join.
    """
    var steps = _arc_steps(radius, sweep)
    var a0 = atan2(from_y, from_x)
    for k in range(1, steps):
        var t = a0 + sweep * Float64(k) / Float64(steps)
        xs.append(cx + radius * cos(t))
        ys.append(cy + radius * sin(t))


def _signed_angle(
    ax: Float64, ay: Float64, bx: Float64, by: Float64
) -> Float64:
    """The angle that turns direction a onto direction b, in
    (-pi, pi]; positive turns +x toward +y."""
    return atan2(ax * by - ay * bx, ax * bx + ay * by)


def _emit_ring(mut edges: _EdgeTable, xs: List[Float64], ys: List[Float64]):
    """One closed outline into the edge table."""
    var n = len(xs)
    if n < 2:
        return
    for i in range(n):
        var j = (i + 1) % n
        edges.add_edge(xs[i], ys[i], xs[j], ys[j])


def _inner_crossing(
    px: Float64,
    py: Float64,
    prev_x: Float64,
    prev_y: Float64,
    next_x: Float64,
    next_y: Float64,
    ux: Float64,
    uy: Float64,
    vx: Float64,
    vy: Float64,
    sign: Float64,
    half_width: Float64,
) -> Tuple[Bool, Float64, Float64]:
    """Where the offset lines on one side of the corner (px, py) meet:
    the arriving segment's, prev + n0 -> p + n0, and the leaving
    segment's, p + n1 -> next + n1, with n0/n1 the side's normals.
    True with the point when the crossing lies within both segments,
    which is when the outline can turn the inner corner at that one
    point; False when a segment is too short to reach it, or the two
    directions are parallel.
    """
    var n0x = -uy * half_width * sign
    var n0y = ux * half_width * sign
    var n1x = -vy * half_width * sign
    var n1y = vx * half_width * sign
    var cross = ux * vy - uy * vx
    if abs(cross) < 1.0e-9:
        return (False, 0.0, 0.0)
    var a1x = prev_x + n0x
    var a1y = prev_y + n0y
    var wx = (px + n1x) - a1x
    var wy = (py + n1y) - a1y
    var t = (wx * vy - wy * vx) / cross
    var s_along = (wx * uy - wy * ux) / cross
    var la = sqrt((px - prev_x) * (px - prev_x) + (py - prev_y) * (py - prev_y))
    var lb = sqrt((next_x - px) * (next_x - px) + (next_y - py) * (next_y - py))
    if t >= 0.0 and t <= la and s_along >= 0.0 and s_along <= lb:
        return (True, a1x + ux * t, a1y + uy * t)
    return (False, 0.0, 0.0)


def _corner_is_simple(
    px: Float64,
    py: Float64,
    prev_x: Float64,
    prev_y: Float64,
    next_x: Float64,
    next_y: Float64,
    half_width: Float64,
) -> Bool:
    """Whether the outline through the corner (px, py) stays simple:
    a straight-through corner does, a reversal does not, and a turn
    does when its inner side reaches the offset lines' crossing -- the
    same tests `_side_at_vertex` makes, without building anything.
    """
    var dx = px - prev_x
    var dy = py - prev_y
    var la = sqrt(dx * dx + dy * dy)
    var ex = next_x - px
    var ey = next_y - py
    var lb = sqrt(ex * ex + ey * ey)
    if la == 0.0 or lb == 0.0:
        return True
    var ux = dx / la
    var uy = dy / la
    var vx = ex / lb
    var vy = ey / lb
    var cross = ux * vy - uy * vx
    if abs(cross) < 1.0e-9:
        return ux * vx + uy * vy > 0.0
    # The path turns toward the left normal when u x v > 0, so that is
    # the inner side then.
    var inner = 1.0 if cross > 0.0 else -1.0
    return _inner_crossing(
        px,
        py,
        prev_x,
        prev_y,
        next_x,
        next_y,
        ux,
        uy,
        vx,
        vy,
        inner,
        half_width,
    )[0]


def _run_is_simple(
    xs: List[Float64],
    ys: List[Float64],
    closed: Bool,
    half_width: Float64,
) -> Bool:
    """Whether every corner of the run (xs, ys), whose consecutive
    points are distinct, is simple; a closed run has a corner at every
    point, an open one at every interior point.
    """
    var n = len(xs)
    if n < 3:
        if closed and n == 2:
            return False  # out and straight back: a reversal
        return True
    var first = 0 if closed else 1
    var last = n if closed else n - 1
    for i in range(first, last):
        var prev = (i + n - 1) % n
        var nxt = (i + 1) % n
        if not _corner_is_simple(
            xs[i], ys[i], xs[prev], ys[prev], xs[nxt], ys[nxt], half_width
        ):
            return False
    return True


def _side_at_vertex(
    mut xs: List[Float64],
    mut ys: List[Float64],
    px: Float64,
    py: Float64,
    prev_x: Float64,
    prev_y: Float64,
    next_x: Float64,
    next_y: Float64,
    ux: Float64,
    uy: Float64,
    vx: Float64,
    vy: Float64,
    sign: Float64,
    half_width: Float64,
    join: LineJoin,
    miter_limit: Float64,
) -> Bool:
    """Append one side's outline vertices at the corner (px, py),
    arrived at along unit direction u from (prev_x, prev_y) and left
    along unit direction v toward (next_x, next_y). `sign` picks the
    side: +1 is the left offset (-u.y, u.x) * half_width, -1 the right.

    On the outer side of the turn the two offset lines leave a wedge,
    filled by the join: an arc for ROUND, the miter point for MITER
    within `miter_limit` (otherwise, as for BEVEL, nothing -- the
    straight cut between the two offset ends). On the inner side the
    two offset lines cross; where they cross within both segments the
    outline takes that one point, which keeps the polygon simple. When
    a segment is too short to reach the crossing the outline goes
    through the corner itself instead -- the pivot, Skia's rule -- a
    self-overlap that the sampled sweep's nonzero fills correctly but
    an accumulation does not, so the return value says False and the
    caller falls back to the sweep.

    A straight-through corner needs one vertex. A reversal (v = -u)
    is treated as outer on both sides, so ROUND turns a half-circle
    about the corner through the direction the path arrived along and
    the other joins cut straight across; the two segments' bodies then
    overlap, which is again a self-overlap, so a reversal returns
    False too.

    Returns True when the vertices appended keep the outline simple.
    """
    var n0x = -uy * half_width * sign
    var n0y = ux * half_width * sign
    var n1x = -vy * half_width * sign
    var n1y = vx * half_width * sign
    var ax = px + n0x
    var ay = py + n0y
    var bx = px + n1x
    var by = py + n1y
    var cross = ux * vy - uy * vx
    var dot = ux * vx + uy * vy
    var straight = abs(cross) < 1.0e-9
    if straight and dot > 0.0:
        xs.append(bx)
        ys.append(by)
        return True
    var reversal = straight
    # The path turns toward the left normal when u x v > 0, so the left
    # side (sign +1) is then the inner one.
    var outer = reversal or (cross < 0.0) == (sign > 0.0)
    if outer:
        xs.append(ax)
        ys.append(ay)
        if join == LineJoin.ROUND:
            var sweep = _signed_angle(n0x, n0y, n1x, n1y)
            if reversal:
                # Both ways round are a half-turn; the one through the
                # arriving direction is the far side of the reversal.
                sweep = 2.0 * _signed_angle(n0x, n0y, ux, uy)
            _arc_points(xs, ys, px, py, n0x, n0y, sweep, half_width)
        elif join == LineJoin.MITER and not reversal:
            var denom = 1.0 + dot
            if denom > 1.0e-12:
                # Apex at V + (n_in + n_out) / (1 + n_in . n_out): its
                # distance from V is half_width / cos(theta / 2), which
                # is what the limit caps.
                var mx = px + (n0x + n1x) / denom
                var my = py + (n0y + n1y) / denom
                var dx = mx - px
                var dy = my - py
                if sqrt(dx * dx + dy * dy) <= miter_limit * half_width:
                    xs.append(mx)
                    ys.append(my)
        xs.append(bx)
        ys.append(by)
        return not reversal
    var crossing = _inner_crossing(
        px,
        py,
        prev_x,
        prev_y,
        next_x,
        next_y,
        ux,
        uy,
        vx,
        vy,
        sign,
        half_width,
    )
    if crossing[0]:
        xs.append(crossing[1])
        ys.append(crossing[2])
        return True
    xs.append(ax)
    ys.append(ay)
    xs.append(px)
    ys.append(py)
    xs.append(bx)
    ys.append(by)
    return False


def _append_cap(
    mut xs: List[Float64],
    mut ys: List[Float64],
    px: Float64,
    py: Float64,
    from_nx: Float64,
    from_ny: Float64,
    out_x: Float64,
    out_y: Float64,
    half_width: Float64,
    cap: LineCap,
):
    """The vertices between the two offset ends at an open end
    (px, py): from the offset (from_nx, from_ny) round to its opposite,
    bulging in the direction (out_x, out_y) away from the stroke. BUTT
    adds nothing, SQUARE the two corners of a half-width box, ROUND the
    half-circle.
    """
    if cap == LineCap.SQUARE:
        xs.append(px + from_nx + out_x * half_width)
        ys.append(py + from_ny + out_y * half_width)
        xs.append(px - from_nx + out_x * half_width)
        ys.append(py - from_ny + out_y * half_width)
    elif cap == LineCap.ROUND:
        var sweep = 2.0 * _signed_angle(from_nx, from_ny, out_x, out_y)
        _arc_points(xs, ys, px, py, from_nx, from_ny, sweep, half_width)


def _outline_open(
    mut edges: _EdgeTable,
    xs: List[Float64],
    ys: List[Float64],
    half_width: Float64,
    cap_start: LineCap,
    cap_end: LineCap,
    join: LineJoin,
    miter_limit: Float64,
) -> Bool:
    """One polygon around the open polyline (xs, ys), whose
    consecutive points are distinct: the left offset forward, the end
    cap, the right offset backward, the start cap. Returns whether it
    is simple -- see `_side_at_vertex`.
    """
    var n = len(xs)
    if n == 1:
        if cap_start == LineCap.ROUND or cap_end == LineCap.ROUND:
            _add_round_dot(edges, xs[0], ys[0], half_width)
        return True
    var simple = True
    var left_x = List[Float64](capacity=2 * n + 8)
    var left_y = List[Float64](capacity=2 * n + 8)
    var right_x = List[Float64](capacity=2 * n + 8)
    var right_y = List[Float64](capacity=2 * n + 8)

    var dx = xs[1] - xs[0]
    var dy = ys[1] - ys[0]
    var length = sqrt(dx * dx + dy * dy)
    var ux = dx / length
    var uy = dy / length
    var first_ux = ux
    var first_uy = uy
    left_x.append(xs[0] - uy * half_width)
    left_y.append(ys[0] + ux * half_width)
    right_x.append(xs[0] + uy * half_width)
    right_y.append(ys[0] - ux * half_width)

    for i in range(1, n - 1):
        var ex = xs[i + 1] - xs[i]
        var ey = ys[i + 1] - ys[i]
        var elen = sqrt(ex * ex + ey * ey)
        var vx = ex / elen
        var vy = ey / elen
        var left_ok = _side_at_vertex(
            left_x,
            left_y,
            xs[i],
            ys[i],
            xs[i - 1],
            ys[i - 1],
            xs[i + 1],
            ys[i + 1],
            ux,
            uy,
            vx,
            vy,
            1.0,
            half_width,
            join,
            miter_limit,
        )
        var right_ok = _side_at_vertex(
            right_x,
            right_y,
            xs[i],
            ys[i],
            xs[i - 1],
            ys[i - 1],
            xs[i + 1],
            ys[i + 1],
            ux,
            uy,
            vx,
            vy,
            -1.0,
            half_width,
            join,
            miter_limit,
        )
        simple = simple and left_ok and right_ok
        ux = vx
        uy = vy

    var last = n - 1
    left_x.append(xs[last] - uy * half_width)
    left_y.append(ys[last] + ux * half_width)
    right_x.append(xs[last] + uy * half_width)
    right_y.append(ys[last] - ux * half_width)

    var poly_x = List[Float64](capacity=len(left_x) + len(right_x) + 40)
    var poly_y = List[Float64](capacity=len(left_x) + len(right_x) + 40)
    for i in range(len(left_x)):
        poly_x.append(left_x[i])
        poly_y.append(left_y[i])
    _append_cap(
        poly_x,
        poly_y,
        xs[last],
        ys[last],
        -uy * half_width,
        ux * half_width,
        ux,
        uy,
        half_width,
        cap_end,
    )
    for i in range(len(right_x) - 1, -1, -1):
        poly_x.append(right_x[i])
        poly_y.append(right_y[i])
    _append_cap(
        poly_x,
        poly_y,
        xs[0],
        ys[0],
        first_uy * half_width,
        -first_ux * half_width,
        -first_ux,
        -first_uy,
        half_width,
        cap_start,
    )
    _emit_ring(edges, poly_x, poly_y)
    return simple


def _outline_closed(
    mut edges: _EdgeTable,
    xs: List[Float64],
    ys: List[Float64],
    half_width: Float64,
    join: LineJoin,
    miter_limit: Float64,
) -> Bool:
    """Two rings around the closed polyline (xs, ys), whose consecutive
    points are distinct and whose last point is not its first: the
    left offset forward and the right offset backward, wound opposite
    ways so nonzero leaves the gap between them empty. Returns whether
    both are simple -- see `_side_at_vertex`.
    """
    var n = len(xs)
    if n == 1:
        _add_round_dot(edges, xs[0], ys[0], half_width)
        return True
    var simple = True
    var left_x = List[Float64](capacity=2 * n + 8)
    var left_y = List[Float64](capacity=2 * n + 8)
    var right_x = List[Float64](capacity=2 * n + 8)
    var right_y = List[Float64](capacity=2 * n + 8)
    for i in range(n):
        var prev = (i + n - 1) % n
        var nxt = (i + 1) % n
        var dx = xs[i] - xs[prev]
        var dy = ys[i] - ys[prev]
        var la = sqrt(dx * dx + dy * dy)
        var ux = dx / la
        var uy = dy / la
        var ex = xs[nxt] - xs[i]
        var ey = ys[nxt] - ys[i]
        var lb = sqrt(ex * ex + ey * ey)
        var vx = ex / lb
        var vy = ey / lb
        var left_ok = _side_at_vertex(
            left_x,
            left_y,
            xs[i],
            ys[i],
            xs[prev],
            ys[prev],
            xs[nxt],
            ys[nxt],
            ux,
            uy,
            vx,
            vy,
            1.0,
            half_width,
            join,
            miter_limit,
        )
        var right_ok = _side_at_vertex(
            right_x,
            right_y,
            xs[i],
            ys[i],
            xs[prev],
            ys[prev],
            xs[nxt],
            ys[nxt],
            ux,
            uy,
            vx,
            vy,
            -1.0,
            half_width,
            join,
            miter_limit,
        )
        simple = simple and left_ok and right_ok
    _emit_ring(edges, left_x, left_y)
    var rev_x = List[Float64](capacity=len(right_x))
    var rev_y = List[Float64](capacity=len(right_x))
    for i in range(len(right_x) - 1, -1, -1):
        rev_x.append(right_x[i])
        rev_y.append(right_y[i])
    _emit_ring(edges, rev_x, rev_y)
    return simple


struct _StrokeShape(Movable):
    """What `_stroke_edges` hands the rasterizer: the edges, and
    whether they are simple outlines to fill by exact area or
    overlapping pieces to sweep with sampled nonzero.
    """

    var edges: _EdgeTable
    var exact: Bool

    def __init__(out self, var edges: _EdgeTable, exact: Bool):
        self.edges = edges^
        self.exact = exact


def _stroke_edges(
    points: List[FPoint],
    closed: Bool,
    half_width: Float64,
    cap: LineCap,
    dashes: List[Float64],
    dash_offset: Float64,
    join: LineJoin,
    miter_limit: Float64,
    matrix: Matrix2D,
) -> _StrokeShape:
    """A stroke as the outline of a filled region: one simple polygon
    per drawn run of the path (`_outline_open`), or two rings for a
    closed solid path (`_outline_closed`), for `_area_edges_aa` to fill
    under nonzero -- when every outline is simple. Each run is checked
    first (`_run_is_simple`, arithmetic only), and the dash walk checks
    each corner as a run gains it; when a corner fails (a reversal, or
    a turn too sharp for its segments to reach the inner offset lines'
    crossing: a hairpin in a noisy series) the stroke is built as
    `_stroke_pieces` instead and marked for the sampled
    sweep, whose per-sample winding takes the union of overlapping
    bodies exactly. Both are the same shape; they differ in how the
    coverage of an edge pixel is computed.

    It is an outline where it can be because the exact-area rasterizer
    adds the coverages of overlapping pieces where they share an edge
    pixel instead of taking their union: a joint disk's sliver on top
    of the quad's 0.2 makes 0.26 at every vertex, and a dense series
    reads wider than drawn. An outline has no overlaps to add; a
    self-overlapping outline has the same problem back, which is why
    the fallback exists.

    Dashing is geometric: the path is walked once with its pattern and
    each drawn stretch becomes a run, vertices and all. A run's ends at
    a dash boundary are butt; the path's own two ends take `cap`. A
    closed path has no ends, so its dashes are all butt, and a dash
    that runs across its starting vertex is one run. Repeated points
    are dropped from a run, and a closed path's closing point too.
    """
    var count = len(points)
    if count == 0 or half_width <= 0.0:
        return _StrokeShape(_EdgeTable(), True)
    var pattern = _DashPattern(dashes, dash_offset)
    if count == 1:
        var edges = _EdgeTable()
        edges.set_map(matrix)
        if pattern.is_on(0.0) and (closed or cap == LineCap.ROUND):
            _add_round_dot(edges, points[0].x, points[0].y, half_width)
        return _StrokeShape(edges^, True)

    # SQUARE extends the stroke's two ends by half a width before the
    # dash distances are measured, so the pattern lands where it would
    # on the drawn geometry.
    var num_segments = count if closed else count - 1
    var px = List[Float64](capacity=count)
    var py = List[Float64](capacity=count)
    for i in range(count):
        px.append(points[i].x)
        py.append(points[i].y)
    if not closed and cap == LineCap.SQUARE:
        var dx = px[1] - px[0]
        var dy = py[1] - py[0]
        var l0 = sqrt(dx * dx + dy * dy)
        if l0 > 0.0:
            px[0] -= dx / l0 * half_width
            py[0] -= dy / l0 * half_width
        var ex = px[count - 1] - px[count - 2]
        var ey = py[count - 1] - py[count - 2]
        var l1 = sqrt(ex * ex + ey * ey)
        if l1 > 0.0:
            px[count - 1] += ex / l1 * half_width
            py[count - 1] += ey / l1 * half_width
    # Once extended, a SQUARE cap is a BUTT end on the longer geometry.
    var end_cap = LineCap.BUTT if cap == LineCap.SQUARE else cap

    var simple = True
    if pattern.solid:
        var xs = List[Float64](capacity=count)
        var ys = List[Float64](capacity=count)
        _append_distinct(xs, ys, px, py, 0, count, closed)
        if not _run_is_simple(xs, ys, closed, half_width):
            return _StrokeShape(
                _stroke_pieces(
                    points,
                    closed,
                    half_width,
                    cap,
                    dashes,
                    dash_offset,
                    join,
                    miter_limit,
                    matrix,
                ),
                False,
            )
        # Reserved only once the outline is known to be simple: the
        # fallback builds its own table, so a table reserved before the
        # check is thrown away on every hairpin.
        var edges = _EdgeTable(8 * count + 32)
        edges.set_map(matrix)
        if closed:
            simple = _outline_closed(
                edges, xs, ys, half_width, join, miter_limit
            )
        elif len(xs) > 0:
            simple = _outline_open(
                edges, xs, ys, half_width, end_cap, end_cap, join, miter_limit
            )
        return _finish_stroke(
            edges^,
            simple,
            points,
            closed,
            half_width,
            cap,
            dashes,
            dash_offset,
            join,
            miter_limit,
            matrix,
        )

    # Dashed: walk the segments, collecting runs. Each run is a slice
    # of run_x/run_y; run_starts_path/run_ends_path say whether it
    # begins at the path's start or finishes at its end.
    var run_x = List[Float64]()
    var run_y = List[Float64]()
    var run_first = List[Int]()
    var run_starts_path = List[Bool]()
    var run_ends_path = List[Bool]()
    var in_run = False
    var distance = 0.0
    for seg in range(num_segments):
        var ax = px[seg]
        var ay = py[seg]
        var bx = px[(seg + 1) % count]
        var by = py[(seg + 1) % count]
        var dx = bx - ax
        var dy = by - ay
        var length = sqrt(dx * dx + dy * dy)
        if length == 0.0:
            continue
        var seg_end = distance + length
        var d = distance
        while d < seg_end:
            var on = pattern.is_on(d)
            var boundary = pattern.next_boundary(d)
            if boundary > seg_end:
                boundary = seg_end
            if on:
                var t0 = (d - distance) / length
                var t1 = (boundary - distance) / length
                if not in_run:
                    run_first.append(len(run_x))
                    run_starts_path.append(seg == 0 and d == 0.0)
                    run_x.append(ax + dx * t0)
                    run_y.append(ay + dy * t0)
                    in_run = True
                var nx = ax + dx * t1
                var ny = ay + dy * t1
                # The run's last point becomes an interior corner when
                # this one lands, so a hairpin stops the walk here
                # rather than after the whole path has been divided
                # into runs; `_run_is_simple` below remains the
                # authority on the runs that are built.
                var n = len(run_x)
                if n - run_first[len(run_first) - 1] >= 2:
                    if not _corner_is_simple(
                        run_x[n - 1],
                        run_y[n - 1],
                        run_x[n - 2],
                        run_y[n - 2],
                        nx,
                        ny,
                        half_width,
                    ):
                        return _StrokeShape(
                            _stroke_pieces(
                                points,
                                closed,
                                half_width,
                                cap,
                                dashes,
                                dash_offset,
                                join,
                                miter_limit,
                                matrix,
                            ),
                            False,
                        )
                run_x.append(nx)
                run_y.append(ny)
                if boundary < seg_end:
                    run_ends_path.append(False)
                    in_run = False
            elif in_run:
                run_ends_path.append(False)
                in_run = False
            d = boundary
        distance = seg_end
    if in_run:
        run_ends_path.append(not closed)
    var runs = len(run_first)
    if runs == 0:
        return _StrokeShape(_EdgeTable(), True)
    # A closed path drawn all the way round is a solid ring after all.
    if closed and runs == 1 and run_starts_path[0] and pattern.is_on(distance):
        var xs = List[Float64]()
        var ys = List[Float64]()
        _append_distinct(xs, ys, run_x, run_y, 0, len(run_x), True)
        if not _run_is_simple(xs, ys, True, half_width):
            return _StrokeShape(
                _stroke_pieces(
                    points,
                    closed,
                    half_width,
                    cap,
                    dashes,
                    dash_offset,
                    join,
                    miter_limit,
                    matrix,
                ),
                False,
            )
        var edges = _EdgeTable(8 * count + 32)
        edges.set_map(matrix)
        simple = _outline_closed(edges, xs, ys, half_width, join, miter_limit)
        return _finish_stroke(
            edges^,
            simple,
            points,
            closed,
            half_width,
            cap,
            dashes,
            dash_offset,
            join,
            miter_limit,
            matrix,
        )
    # A closed path whose pattern is on across its starting vertex:
    # the last run continues into the first.
    var merge_last = closed and runs >= 2 and run_starts_path[0] and in_run
    var edges = _EdgeTable(8 * count + 32)
    edges.set_map(matrix)
    for r in range(runs):
        if merge_last and r == 0:
            continue
        var first = run_first[r]
        var last = len(run_x) if r == runs - 1 else run_first[r + 1]
        var xs = List[Float64]()
        var ys = List[Float64]()
        _append_distinct(xs, ys, run_x, run_y, first, last, False)
        var starts_path = run_starts_path[r] and not closed
        if merge_last and r == runs - 1:
            _append_distinct(
                xs, ys, run_x, run_y, run_first[0], run_first[1], False
            )
        if not _run_is_simple(xs, ys, False, half_width):
            return _StrokeShape(
                _stroke_pieces(
                    points,
                    closed,
                    half_width,
                    cap,
                    dashes,
                    dash_offset,
                    join,
                    miter_limit,
                    matrix,
                ),
                False,
            )
        var cap_s = end_cap if starts_path else LineCap.BUTT
        var cap_e = end_cap if (
            run_ends_path[r] and not closed
        ) else LineCap.BUTT
        if len(xs) > 0:
            var ok = _outline_open(
                edges, xs, ys, half_width, cap_s, cap_e, join, miter_limit
            )
            simple = simple and ok
    return _finish_stroke(
        edges^,
        simple,
        points,
        closed,
        half_width,
        cap,
        dashes,
        dash_offset,
        join,
        miter_limit,
        matrix,
    )


def _finish_stroke(
    var edges: _EdgeTable,
    simple: Bool,
    points: List[FPoint],
    closed: Bool,
    half_width: Float64,
    cap: LineCap,
    dashes: List[Float64],
    dash_offset: Float64,
    join: LineJoin,
    miter_limit: Float64,
    matrix: Matrix2D,
) -> _StrokeShape:
    """The outline if it is simple, otherwise the pieces."""
    if simple:
        return _StrokeShape(edges^, True)
    return _StrokeShape(
        _stroke_pieces(
            points,
            closed,
            half_width,
            cap,
            dashes,
            dash_offset,
            join,
            miter_limit,
            matrix,
        ),
        False,
    )


def _append_distinct(
    mut xs: List[Float64],
    mut ys: List[Float64],
    src_x: List[Float64],
    src_y: List[Float64],
    first: Int,
    last: Int,
    closed: Bool,
):
    """Copy src[first:last] into xs/ys, dropping each point equal to
    the one before it and, for a closed run, a final point equal to
    the first.
    """
    for i in range(first, last):
        var n = len(xs)
        if n > 0 and xs[n - 1] == src_x[i] and ys[n - 1] == src_y[i]:
            continue
        xs.append(src_x[i])
        ys.append(src_y[i])
    if closed:
        var n = len(xs)
        if n > 1 and xs[n - 1] == xs[0] and ys[n - 1] == ys[0]:
            _ = xs.pop()
            _ = ys.pop()


def draw_polyline_aa(
    mut canvas: Canvas,
    points: List[Point],
    color: Color,
    width: Float64 = 1.0,
    supersample: Int = 4,
    dashes: List[Float64] = List[Float64](),
    dash_offset: Float64 = 0.0,
    cap: LineCap = LineCap.ROUND,
    join: LineJoin = LineJoin.ROUND,
    miter_limit: Float64 = 4.0,
):
    """Anti-aliased polyline; draw_polyline is the hard-edged version.

    Args:
        canvas: Canvas to draw into.
        points: Vertices to connect, in order.
        color: Line color.
        width: Stroke width in pixels.
        supersample: Sub-pixel grid side length per pixel (N -> N*N
            samples) for a stroke whose outline is not simple (a
            hairpin, a reversal); a simple outline rasterizes by
            exact area and ignores it. See `_stroke_edges`.
        dashes: On/off segment lengths in pixels, cycled along the
            whole polyline. Empty (default) draws a solid line.
        dash_offset: Distance into the dash pattern the polyline
            starts at.
        cap: How the two open ends are finished -- see LineCap.
        join: How corners are turned -- see LineJoin.
        miter_limit: Ratio past which a MITER join falls back to
            BEVEL, as a multiple of half the stroke width.
    """
    var fpoints = List[FPoint](capacity=len(points))
    for i in range(len(points)):
        fpoints.append(FPoint(Float64(points[i].x), Float64(points[i].y)))
    draw_polyline_aa(
        canvas,
        fpoints,
        color,
        width,
        supersample,
        dashes,
        dash_offset,
        cap,
        join,
        miter_limit,
    )


def draw_polyline_aa(
    mut canvas: Canvas,
    points: List[FPoint],
    color: Color,
    width: Float64 = 1.0,
    supersample: Int = 4,
    dashes: List[Float64] = List[Float64](),
    dash_offset: Float64 = 0.0,
    cap: LineCap = LineCap.ROUND,
    join: LineJoin = LineJoin.ROUND,
    miter_limit: Float64 = 4.0,
):
    """`draw_polyline_aa` at sub-pixel vertices -- the same polyline,
    placed to a fraction of a pixel rather than snapped to the pixel
    grid.

    This is the real implementation; the whole-pixel overload above
    converts and calls it.

    Args:
        canvas: Canvas to draw into.
        points: Vertices to connect, in order, at sub-pixel positions.
        color: Line color.
        width: Stroke width in pixels.
        supersample: Sub-pixel grid side length per pixel (N -> N*N
            samples) for a stroke whose outline is not simple (a
            hairpin, a reversal); a simple outline rasterizes by
            exact area and ignores it. See `_stroke_edges`.
        dashes: On/off segment lengths in pixels. Empty (default) draws
            a solid line.
        dash_offset: Distance into the dash pattern to start at.
        cap: How the two open ends are finished -- see LineCap.
        join: How corners are turned -- see LineJoin.
        miter_limit: Ratio past which a MITER join falls back to
            BEVEL, as a multiple of half the stroke width.
    """
    _draw_polyline_core_aa(
        canvas,
        points,
        color,
        width,
        supersample,
        False,
        dashes,
        dash_offset,
        cap,
        join,
        miter_limit,
    )


def draw_polygon_aa(
    mut canvas: Canvas,
    points: List[Point],
    color: Color,
    width: Float64 = 1.0,
    supersample: Int = 4,
    dashes: List[Float64] = List[Float64](),
    dash_offset: Float64 = 0.0,
    join: LineJoin = LineJoin.ROUND,
    miter_limit: Float64 = 4.0,
):
    """Anti-aliased polygon outline; draw_polygon is the hard-edged
    version. The closing segment is stroked like any other, so dash
    phase carries across the closing vertex.

    Args:
        canvas: Canvas to draw into.
        points: Vertices to connect, in order.
        color: Line color.
        width: Stroke width in pixels.
        supersample: Sub-pixel grid side length per pixel (N -> N*N
            samples) for a stroke whose outline is not simple (a
            hairpin, a reversal); a simple outline rasterizes by
            exact area and ignores it. See `_stroke_edges`.
        dashes: On/off segment lengths in pixels, cycled all the way
            around the polygon. Empty (default) draws a solid line.
        dash_offset: Distance into the dash pattern the polygon starts
            at.
        join: How corners are turned -- see LineJoin.
        miter_limit: Ratio past which a MITER join falls back to
            BEVEL, as a multiple of half the stroke width.
    """
    var fpoints = List[FPoint](capacity=len(points))
    for i in range(len(points)):
        fpoints.append(FPoint(Float64(points[i].x), Float64(points[i].y)))
    draw_polygon_aa(
        canvas,
        fpoints,
        color,
        width,
        supersample,
        dashes,
        dash_offset,
        join,
        miter_limit,
    )


def draw_polygon_aa(
    mut canvas: Canvas,
    points: List[FPoint],
    color: Color,
    width: Float64 = 1.0,
    supersample: Int = 4,
    dashes: List[Float64] = List[Float64](),
    dash_offset: Float64 = 0.0,
    join: LineJoin = LineJoin.ROUND,
    miter_limit: Float64 = 4.0,
):
    """`draw_polygon_aa` at sub-pixel vertices -- the same polygon
    outline, placed to a fraction of a pixel rather than snapped to the
    pixel grid.

    This is the real implementation; the whole-pixel overload above
    converts and calls it.

    Args:
        canvas: Canvas to draw into.
        points: Vertices to connect, in order, at sub-pixel positions.
        color: Line color.
        width: Stroke width in pixels.
        supersample: Sub-pixel grid side length per pixel (N -> N*N
            samples) for a stroke whose outline is not simple (a
            hairpin, a reversal); a simple outline rasterizes by
            exact area and ignores it. See `_stroke_edges`.
        dashes: On/off segment lengths in pixels. Empty (default) draws
            a solid line.
        dash_offset: Distance into the dash pattern to start at.
        join: How corners are turned -- see LineJoin.
        miter_limit: Ratio past which a MITER join falls back to
            BEVEL, as a multiple of half the stroke width.
    """
    _draw_polyline_core_aa(
        canvas,
        points,
        color,
        width,
        supersample,
        True,
        dashes,
        dash_offset,
        LineCap.ROUND,  # a closed shape has no ends to cap
        join,
        miter_limit,
    )
