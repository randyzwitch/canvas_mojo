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

from std.math import ceil, cos, floor, pi, sin, sqrt

from canvas.color import Color
from canvas.buffer import Canvas
from canvas.geometry import Point, FPoint, _round_to_int
from canvas.aa_crossing import _EdgeTable, _sweep_edges_aa
from canvas.fill_rule import FillRule
from canvas.shapes.dash import _is_dash_on, _dash_next_boundary

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
    dashes: List[Float64] = List[Float64](),
    dash_offset: Float64 = 0.0,
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

    while True:
        var is_last = x == x1 and y == y1
        var on_dash = _is_dash_on(distance, dashes, dash_offset)
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
    _ = _draw_line_core(
        canvas, x0, y0, x1, y1, color, False, False, dashes, dash_offset, 0.0
    )


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
        supersample: Sub-pixel grid side length per pixel (N -> N*N samples).
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
        supersample: Sub-pixel grid side length per pixel (N -> N*N samples).
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
    if len(points) == 0:
        return
    if len(points) == 1:
        canvas.set_pixel(points[0].x, points[0].y, color)
        return

    var distance = 0.0
    for i in range(len(points) - 1):
        var a = points[i]
        var b = points[i + 1]
        distance = _draw_line_core(
            canvas,
            a.x,
            a.y,
            b.x,
            b.y,
            color,
            i > 0,
            False,
            dashes,
            dash_offset,
            distance,
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
    var n = len(points)
    if n == 0:
        return
    if n == 1:
        canvas.set_pixel(points[0].x, points[0].y, color)
        return
    if n == 2:
        draw_line(
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

    var distance = 0.0
    for i in range(n - 1):
        var a = points[i]
        var b = points[i + 1]
        distance = _draw_line_core(
            canvas,
            a.x,
            a.y,
            b.x,
            b.y,
            color,
            i > 0,
            False,
            dashes,
            dash_offset,
            distance,
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
        dashes,
        dash_offset,
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
    var count = len(points)
    if count == 0:
        return
    if count == 1:
        canvas.set_pixel(
            _round_to_int(points[0].x), _round_to_int(points[0].y), color
        )
        return

    var half_width = width / 2.0
    var pad = Int(half_width) + 2

    # Real-valued extent, then widened outward to the pixels that
    # contain it (floor/ceil, not round) before the flat `pad` -- a
    # vertex at x = 10.2 has to have pixel 10 swept for it to pick up
    # any partial coverage there.
    var fmin_x = points[0].x
    var fmax_x = points[0].x
    var fmin_y = points[0].y
    var fmax_y = points[0].y
    for i in range(1, count):
        if points[i].x < fmin_x:
            fmin_x = points[i].x
        if points[i].x > fmax_x:
            fmax_x = points[i].x
        if points[i].y < fmin_y:
            fmin_y = points[i].y
        if points[i].y > fmax_y:
            fmax_y = points[i].y
    var min_x = Int(floor(fmin_x)) - pad
    var max_x = Int(ceil(fmax_x)) + pad
    var min_y = Int(floor(fmin_y)) - pad
    var max_y = Int(ceil(fmax_y)) + pad

    # Every stroke, dashed or not, goes through the ordinary path fill:
    # the stroke's own outline is handed to `_sweep_edges_aa`, which is
    # parallel across cores. See `_stroke_edges` for why the two
    # formulations describe the same shape.
    var edges = _stroke_edges(
        points,
        closed,
        half_width,
        cap,
        dashes,
        dash_offset,
        join,
        miter_limit,
    )
    _sweep_edges_aa(
        canvas,
        edges,
        min_x,
        min_y,
        max_x,
        max_y,
        color,
        FillRule.NONZERO,
        supersample,
    )


# How deep a notch a joint may leave before it needs a round disk to
# fill it, in pixels. A fiftieth of a pixel is a fifth of a sub-sample
# at the default supersample, so a skipped joint cannot move a
# coverage count.
comptime _JOIN_DISK_TOLERANCE = 0.02


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


def _stroke_edges(
    points: List[FPoint],
    closed: Bool,
    half_width: Float64,
    cap: LineCap,
    dashes: List[Float64],
    dash_offset: Float64,
    join: LineJoin,
    miter_limit: Float64,
) -> _EdgeTable:
    """A stroke expressed as the outline of a filled region.

    A stroke is every point within `half_width` of some *drawn* part of
    the path, which is the union of one rectangle per drawn stretch and
    one disk per vertex it turns through. Emitting that as edges lets the
    ordinary path fill rasterize it.

    Dashing is geometric: each segment is split at its dash boundaries
    once and only the drawn pieces are emitted.

    A drawn piece is a stadium -- a quad plus a disk at each end. Those
    end disks make a dash's ends round regardless of `cap`, which
    describes the two ends of the *stroke*, not of every dash.
    """
    var edges = _EdgeTable()
    var count = len(points)
    if count == 0 or half_width <= 0.0:
        return edges^

    if count == 1:
        if _is_dash_on(0.0, dashes, dash_offset) and (
            closed or cap == LineCap.ROUND
        ):
            _add_disk(edges, points[0].x, points[0].y, half_width)
        return edges^

    var num_segments = count if closed else count - 1
    var capped = (not closed) and cap != LineCap.ROUND

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
            if _is_dash_on(seg_start[seg], dashes, dash_offset):
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
            var on = _is_dash_on(d, dashes, dash_offset)
            var next_d = _dash_next_boundary(d, dashes, dash_offset)
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
            if (not capped) and _is_dash_on(seg_start[0], dashes, dash_offset):
                _add_disk(edges, ax[0], ay[0], half_width)

        # ...and the segment's far endpoint.
        if not _is_dash_on(seg_end_d, dashes, dash_offset):
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
        var after_end = _dash_next_boundary(seg_end_d, dashes, dash_offset)
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
        if sagitta > _JOIN_DISK_TOLERANCE:
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
        supersample: Sub-pixel grid side length per pixel (N -> N*N samples).
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
        supersample: Sub-pixel grid side length per pixel (N -> N*N samples).
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
        supersample: Sub-pixel grid side length per pixel (N -> N*N samples).
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
        supersample: Sub-pixel grid side length per pixel (N -> N*N samples).
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
