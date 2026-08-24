"""Line, polyline, and polygon-*outline* drawing: Bresenham hard-edged
(draw_line/draw_polyline/draw_polygon), supersampled analytic-coverage
anti-aliased (draw_line_aa/draw_polyline_aa/draw_polygon_aa), and the
dash-aware cores they share (_draw_line_core, _draw_polyline_core_aa).

`draw_polygon`/`draw_polygon_aa` here draw the *outline* only -- this
file's line machinery closed into a loop. `fill_polygon`/
`fill_polygon_aa` in canvas_mojo.shapes.polygon_fill fill the
*interior* by an entirely different scanline algorithm. Two different
operations sharing half a name, kept in separate files so the module
layout says so.

Naming convention, followed by every file in canvas_mojo.shapes/:
hard-edged and anti-aliased variants stay separate functions
(draw_circle vs. draw_circle_aa), never one function behind an
`antialias: Bool`. A shared name invites parameters meaningful in only
one branch (draw_line_aa's `width` has no hard-edged equivalent --
Bresenham is definitionally 1px) and hides a complexity jump
(hard-edged circle drawing is O(radius); AA is O(radius^2 *
supersample^2)) behind what looks like a toggle.
"""

from std.math import ceil, floor, sqrt

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas
from canvas_mojo.geometry import Point
from canvas_mojo.shapes.dash import _is_dash_on

comptime _SQRT2 = 1.4142135623730951


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

    Returns the total distance traveled -- the sum of per-step
    Euclidean lengths, 1.0 for an axis step and sqrt(2) for a diagonal
    one, since Bresenham moves exactly one pixel in x and/or y per step
    -- so draw_polyline/draw_polygon can carry a dash pattern's phase
    across a joint into the next segment's dash_start_distance instead
    of restarting it at every corner. This is the accumulated
    raster-walk distance, not the idealized sqrt(dx^2+dy^2): the two
    are close but not bit-identical, and the accumulated one is
    consistent with the pixels this call actually drew.
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
    """
    _ = _draw_line_core(canvas, x0, y0, x1, y1, color, False, False, dashes, dash_offset, 0.0)


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
):
    """Anti-aliased line, `width` pixels wide (default 1), with round
    end caps.

    Same supersampled analytic-coverage technique as fill_circle_aa /
    draw_circle_aa, including the pixel-centered-at-(px,py) sampling
    convention: for every pixel near the segment, samples an NxN
    sub-pixel grid and tests each sub-sample's distance to the
    segment (clamping the projection onto the line to [0, 1], so
    samples past either endpoint measure distance to that endpoint
    directly) against width/2.

    That endpoint clamping is what gives round caps rather than flat
    (butt) caps -- a sample just past x1 is tested against a circle
    centered on the endpoint, not rejected outright. For width=1 the
    difference is barely visible; it matters more at larger widths,
    and round caps have the added benefit of not leaving a notch
    where two line segments meet at an angle (relevant once polylines
    build on this).

    `dashes` (see _is_dash_on) is measured along this segment's
    idealized straight-line length, not _draw_line_core's raster-step
    distance: a supersampled algorithm has no pixel walk to count, and
    `t` -- the already-clamped projection fraction -- times the true
    length is the distance available at each sample. A sample past
    either endpoint (t clamped to 0 or 1) measures as if it sat exactly
    at that endpoint, as the round-cap test already treats it.
    """
    var half_width = width / 2.0
    var fx0 = Float64(x0)
    var fy0 = Float64(y0)
    var fx1 = Float64(x1)
    var fy1 = Float64(y1)
    var ldx = fx1 - fx0
    var ldy = fy1 - fy0
    var len2 = ldx * ldx + ldy * ldy
    var seg_length = sqrt(len2)

    var pad = Int(half_width) + 2
    var min_x = min(x0, x1) - pad
    var max_x = max(x0, x1) + pad
    var min_y = min(y0, y1) - pad
    var max_y = max(y0, y1) + pad

    var n = supersample
    var total_samples = n * n
    var step = 1.0 / Float64(n)
    var hw2 = half_width * half_width

    for py in range(min_y, max_y + 1):
        for px in range(min_x, max_x + 1):
            var covered = 0
            for sy in range(n):
                var sample_y = Float64(py) + (Float64(sy) + 0.5) * step - 0.5
                for sx in range(n):
                    var sample_x = Float64(px) + (Float64(sx) + 0.5) * step - 0.5
                    var t: Float64
                    if len2 == 0.0:
                        t = 0.0
                    else:
                        t = ((sample_x - fx0) * ldx + (sample_y - fy0) * ldy) / len2
                        if t < 0.0:
                            t = 0.0
                        elif t > 1.0:
                            t = 1.0
                    var closest_x = fx0 + t * ldx
                    var closest_y = fy0 + t * ldy
                    var ddx = sample_x - closest_x
                    var ddy = sample_y - closest_y
                    if ddx * ddx + ddy * ddy <= hw2:
                        if _is_dash_on(t * seg_length, dashes, dash_offset):
                            covered += 1
            if covered > 0:
                var alpha = UInt8(
                    Int(Float64(covered) / Float64(total_samples) * Float64(color.a) + 0.5)
                )
                canvas.set_pixel(px, py, Color(color.r, color.g, color.b, alpha))


def draw_polyline(
    mut canvas: Canvas,
    points: List[Point],
    color: Color,
    dashes: List[Float64] = List[Float64](),
    dash_offset: Float64 = 0.0,
):
    """Connect consecutive points with line segments (Bresenham).

    Not closed -- see draw_polygon for that. Each interior joint is
    drawn by exactly one segment (the next segment skips its shared
    start point), so a translucent color doesn't get blended twice
    where segments meet.

    A dash pattern's phase carries across joints: each segment starts
    where the previous one's accumulated distance left off, so dashes
    don't reset at a corner.
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
            canvas, a.x, a.y, b.x, b.y, color, i > 0, False, dashes, dash_offset, distance
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
    """
    var n = len(points)
    if n == 0:
        return
    if n == 1:
        canvas.set_pixel(points[0].x, points[0].y, color)
        return
    if n == 2:
        draw_line(canvas, points[0].x, points[0].y, points[1].x, points[1].y, color, dashes, dash_offset)
        return

    var distance = 0.0
    for i in range(n - 1):
        var a = points[i]
        var b = points[i + 1]
        distance = _draw_line_core(
            canvas, a.x, a.y, b.x, b.y, color, i > 0, False, dashes, dash_offset, distance
        )

    var last = points[n - 1]
    var first = points[0]
    _ = _draw_line_core(
        canvas, last.x, last.y, first.x, first.y, color, True, True, dashes, dash_offset, distance
    )


def _draw_polyline_core_aa(
    mut canvas: Canvas,
    points: List[Point],
    color: Color,
    width: Float64,
    supersample: Int,
    closed: Bool,
    dashes: List[Float64] = List[Float64](),
    dash_offset: Float64 = 0.0,
):
    """Shared implementation for draw_polyline_aa/draw_polygon_aa.

    Calling draw_line_aa per segment would double-blend at every
    joint, and the hard-edged "skip a pixel" fix doesn't apply, since
    AA coverage comes from sampling. Instead every sample tests its
    distance to *every* segment and keeps the minimum, so overlapping
    round-cap regions at a joint still yield one coverage value, and
    one set_pixel call, per pixel.

    Dashing composes with that minimum: a segment counts as a coverage
    candidate only if the sample's projected point on it is within
    half_width *and* inside an "on" region for that segment's
    precomputed, joint-continuous start distance. Evaluating dash state
    per segment before taking the minimum -- rather than dashing an
    already-collapsed "closest segment" -- is what correctly covers a
    sample where one segment is off but its neighbor is on.
    """
    var count = len(points)
    if count == 0:
        return
    if count == 1:
        canvas.set_pixel(points[0].x, points[0].y, color)
        return

    var num_segments = count if closed else count - 1
    var half_width = width / 2.0
    var hw2 = half_width * half_width
    var n = supersample
    var total_samples = n * n
    var step = 1.0 / Float64(n)
    var pad = Int(half_width) + 2

    # Each segment's start distance (cumulative length of everything
    # before it) and length, precomputed so dash phase carries across
    # joints. draw_polyline keeps the same running total, but this
    # loop iterates samples rather than segments in path order.
    var seg_start_distance = List[Float64](capacity=num_segments)
    var seg_length = List[Float64](capacity=num_segments)
    var running_distance = 0.0
    for seg in range(num_segments):
        var sa = points[seg]
        var sb = points[(seg + 1) % count]
        var sdx = Float64(sb.x - sa.x)
        var sdy = Float64(sb.y - sa.y)
        var slen = sqrt(sdx * sdx + sdy * sdy)
        seg_start_distance.append(running_distance)
        seg_length.append(slen)
        running_distance += slen

    var min_x = points[0].x
    var max_x = points[0].x
    var min_y = points[0].y
    var max_y = points[0].y
    for i in range(1, count):
        if points[i].x < min_x:
            min_x = points[i].x
        if points[i].x > max_x:
            max_x = points[i].x
        if points[i].y < min_y:
            min_y = points[i].y
        if points[i].y > max_y:
            max_y = points[i].y
    min_x -= pad
    max_x += pad
    min_y -= pad
    max_y += pad

    # Each segment's bounding box, expanded by half_width -- a sample
    # outside it can't be within half_width of the segment, since its
    # closest point lies on the segment, inside the box -- plus a flat
    # 1.0 margin, since a pixel's samples land up to 0.5 from its
    # center in either axis. Precomputed so a whole pixel can skip a
    # segment without visiting any of its samples. Without this the
    # sweep is O(pixels * supersample^2 * segments) even for an
    # ordinary line chart spread across the canvas, where most
    # segments are nowhere near most pixels.
    var seg_min_x = List[Float64](capacity=num_segments)
    var seg_max_x = List[Float64](capacity=num_segments)
    var seg_min_y = List[Float64](capacity=num_segments)
    var seg_max_y = List[Float64](capacity=num_segments)
    for seg in range(num_segments):
        var a = points[seg]
        var b = points[(seg + 1) % count]
        var ax = Float64(a.x)
        var ay = Float64(a.y)
        var bx = Float64(b.x)
        var by = Float64(b.y)
        seg_min_x.append(min(ax, bx) - half_width - 1.0)
        seg_max_x.append(max(ax, bx) + half_width + 1.0)
        seg_min_y.append(min(ay, by) - half_width - 1.0)
        seg_max_y.append(max(ay, by) + half_width + 1.0)

    # Per-column candidate buckets, indexed by `px - min_x`, cleared
    # and reused across rows rather than reallocated. One-time O(width)
    # setup, outside the row loop.
    var col_candidates = List[List[Int]](capacity=max_x - min_x + 1)
    for _ in range(max_x - min_x + 1):
        col_candidates.append(List[Int]())

    var row_candidates = List[Int](capacity=num_segments)
    for py in range(min_y, max_y + 1):
        var fpy = Float64(py)

        # Row-level pre-filter by y alone, before the per-pixel x
        # check: the y test is identical for every pixel in the row, so
        # computing it per row rather than per (row, pixel) makes this
        # part O(rows * segments) instead of O(pixels * segments).
        row_candidates.clear()
        for seg in range(num_segments):
            if fpy >= seg_min_y[seg] and fpy <= seg_max_y[seg]:
                row_candidates.append(seg)

        if len(row_candidates) == 0:
            continue  # no segment reaches this row at all

        # Bucket each row candidate into the columns its
        # half-width-expanded x-range covers, rather than rescanning
        # the whole row_candidates list per pixel column. The rescan
        # costs O(row_width * row_candidates) on a dense row -- many
        # near-vertical segments, an ordinary noisy line series sampled
        # denser than the canvas is wide. Bucketing costs
        # O(row_candidates * each segment's column footprint) to fill
        # plus O(row_width) to sweep, and a segment spanning under a
        # pixel in x lands in one or two buckets. Measured on a
        # 3200-segment stroke: ~844ms down to a small fraction of it.
        var row_min_px = max_x + 1
        var row_max_px = min_x - 1
        for ri in range(len(row_candidates)):
            var seg = row_candidates[ri]
            var lo = Int(ceil(seg_min_x[seg]))
            var hi = Int(floor(seg_max_x[seg]))
            if lo < min_x:
                lo = min_x
            if hi > max_x:
                hi = max_x
            if lo > hi:
                continue  # this segment's x-range is entirely outside the visible columns
            if lo < row_min_px:
                row_min_px = lo
            if hi > row_max_px:
                row_max_px = hi
            for px in range(lo, hi + 1):
                col_candidates[px - min_x].append(seg)

        if row_min_px > row_max_px:
            continue  # every candidate's x-range clipped away; nothing to sweep

        for px in range(row_min_px, row_max_px + 1):
            ref candidates = col_candidates[px - min_x]
            if len(candidates) == 0:
                continue  # no segment comes anywhere near this pixel

            var covered = 0
            for sy in range(n):
                var sample_y = Float64(py) + (Float64(sy) + 0.5) * step - 0.5
                for sx in range(n):
                    var sample_x = Float64(px) + (Float64(sx) + 0.5) * step - 0.5
                    var min_dist2 = -1.0
                    for ci in range(len(candidates)):
                        var seg = candidates[ci]
                        var a = points[seg]
                        var b = points[(seg + 1) % count]
                        var fx0 = Float64(a.x)
                        var fy0 = Float64(a.y)
                        var fx1 = Float64(b.x)
                        var fy1 = Float64(b.y)
                        var ldx = fx1 - fx0
                        var ldy = fy1 - fy0
                        var len2 = ldx * ldx + ldy * ldy
                        var t: Float64
                        if len2 == 0.0:
                            t = 0.0
                        else:
                            t = ((sample_x - fx0) * ldx + (sample_y - fy0) * ldy) / len2
                            if t < 0.0:
                                t = 0.0
                            elif t > 1.0:
                                t = 1.0
                        var closest_x = fx0 + t * ldx
                        var closest_y = fy0 + t * ldy
                        var ddx = sample_x - closest_x
                        var ddy = sample_y - closest_y
                        var d2 = ddx * ddx + ddy * ddy
                        # A segment only becomes a candidate once it's
                        # both close enough AND on-dash at this exact
                        # projected point -- with no dash pattern every
                        # segment is always on-dash, so this reduces to
                        # a plain nearest-segment-within-hw2 test,
                        # since a global min <= hw2 can only come from
                        # a segment that itself has d2 <= hw2.
                        if d2 <= hw2:
                            var sample_distance = seg_start_distance[seg] + t * seg_length[seg]
                            if _is_dash_on(sample_distance, dashes, dash_offset):
                                if min_dist2 < 0.0 or d2 < min_dist2:
                                    min_dist2 = d2
                    if min_dist2 >= 0.0:
                        covered += 1
            if covered > 0:
                var alpha = UInt8(
                    Int(Float64(covered) / Float64(total_samples) * Float64(color.a) + 0.5)
                )
                canvas.set_pixel(px, py, Color(color.r, color.g, color.b, alpha))

        # Empty every bucket this row touched, ready for the next row:
        # the outer List is never reallocated, only the small
        # List[Int]s inside it get cleared.
        for px in range(row_min_px, row_max_px + 1):
            col_candidates[px - min_x].clear()


def draw_polyline_aa(
    mut canvas: Canvas,
    points: List[Point],
    color: Color,
    width: Float64 = 1.0,
    supersample: Int = 4,
    dashes: List[Float64] = List[Float64](),
    dash_offset: Float64 = 0.0,
):
    """Anti-aliased polyline. See draw_polyline for the hard-edged
    version, and _draw_polyline_core_aa for how joints avoid
    double-blending and how dash phase carries across them.
    """
    _draw_polyline_core_aa(canvas, points, color, width, supersample, False, dashes, dash_offset)


def draw_polygon_aa(
    mut canvas: Canvas,
    points: List[Point],
    color: Color,
    width: Float64 = 1.0,
    supersample: Int = 4,
    dashes: List[Float64] = List[Float64](),
    dash_offset: Float64 = 0.0,
):
    """Anti-aliased polygon outline; see draw_polygon for the
    hard-edged version. The closing segment joins every sample's
    minimum-distance test like any other, so the closing vertex needs
    no special case (unlike draw_polygon's skip_first/skip_last), and
    dash phase carries across it too.
    """
    _draw_polyline_core_aa(canvas, points, color, width, supersample, True, dashes, dash_offset)
