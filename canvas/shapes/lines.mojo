"""Line, polyline, and polygon-*outline* drawing: Bresenham hard-edged
(draw_line/draw_polyline/draw_polygon), supersampled analytic-coverage
anti-aliased (draw_line_aa/draw_polyline_aa/draw_polygon_aa), and the
dash-aware cores they share (_draw_line_core, _draw_polyline_core_aa).

`draw_polygon`/`draw_polygon_aa` here draw the *outline* only -- this
file's line machinery closed into a loop. `fill_polygon`/
`fill_polygon_aa` in canvas.shapes.polygon_fill fill the
*interior* by an entirely different scanline algorithm. Two different
operations sharing half a name, kept in separate files so the module
layout says so.

Naming convention, followed by every file in canvas.shapes/:
hard-edged and anti-aliased variants stay separate functions
(draw_circle vs. draw_circle_aa), never one function behind an
`antialias: Bool`. A shared name invites parameters meaningful in only
one branch (draw_line_aa's `width` has no hard-edged equivalent --
Bresenham is definitionally 1px) and hides a complexity jump
(hard-edged circle drawing is O(radius); AA is O(radius^2 *
supersample^2)) behind what looks like a toggle.
"""

from std.math import ceil, floor, sqrt

from canvas.color import Color
from canvas.buffer import Canvas
from canvas.geometry import Point
from canvas.shapes.dash import _is_dash_on

comptime _SQRT2 = 1.4142135623730951

# Sub-samples evaluated per SIMD step in the anti-aliased polyline
# core. 4 rather than the widest available vector: the default
# supersample is 4, so one chunk covers a whole row of sub-samples with
# no masked-off lanes, and a wider vector would spend most of its width
# idle at the size this is actually called with.
comptime _AA_LANES = 4


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
):
    """Anti-aliased line, `width` pixels wide (default 1), with round
    end caps.

    A one-segment polyline, and drawn as one: `_draw_polyline_core_aa`
    already carries the row- and column-level filtering that keeps a
    long diagonal from scanning its whole bounding box, and the
    vectorized sample loop. Scanning the bounding box directly, as this
    used to, costs the same for a 1-pixel line as for the rectangle it
    spans -- a full-width diagonal covers a few thousand pixels inside
    a box of nearly a million.

    Confirmed byte-identical to the previous implementation across
    horizontal, vertical, diagonal, thick and dashed cases before the
    switch: the coverage test is the same minimum-distance-to-segment
    with the same round caps, since a single segment has no joint for
    the core's minimum to do anything different with.

    Args:
        canvas: Canvas to draw into.
        x0: Start point x.
        y0: Start point y.
        x1: End point x.
        y1: End point y.
        color: Line color.
        width: Stroke width in pixels.
        supersample: Sub-pixel grid side length per pixel (N -> N*N
            samples).
        dashes: On/off segment lengths in pixels, cycled along the
            line. Empty (default) draws a solid line.
        dash_offset: Distance into the dash pattern the line starts at.
    """
    var points: List[Point] = [Point(x0, y0), Point(x1, y1)]
    _draw_polyline_core_aa(
        canvas, points, color, width, supersample, False, dashes, dash_offset
    )


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
    #
    # The same pass also keeps each segment's endpoint, direction and
    # 1/|d|^2, which the per-sample distance test below needs. Those
    # are fixed per segment, so computing them here rather than inside
    # the sample loops is the difference between once per segment and
    # once per (pixel, sample, segment) -- supersample^2 times more
    # often, for a value that cannot change.
    var seg_start_distance = List[Float64](capacity=num_segments)
    var seg_length = List[Float64](capacity=num_segments)
    var seg_x0 = List[Float64](capacity=num_segments)
    var seg_y0 = List[Float64](capacity=num_segments)
    var seg_dx = List[Float64](capacity=num_segments)
    var seg_dy = List[Float64](capacity=num_segments)
    var seg_len2 = List[Float64](capacity=num_segments)
    var running_distance = 0.0
    for seg in range(num_segments):
        var sa = points[seg]
        var sb = points[(seg + 1) % count]
        var sdx = Float64(sb.x - sa.x)
        var sdy = Float64(sb.y - sa.y)
        var slen2 = sdx * sdx + sdy * sdy
        var slen = sqrt(slen2)
        seg_start_distance.append(running_distance)
        seg_length.append(slen)
        seg_x0.append(Float64(sa.x))
        seg_y0.append(Float64(sa.y))
        seg_dx.append(sdx)
        seg_dy.append(sdy)
        seg_len2.append(slen2)
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
        # A segment's columns *at this row*, not over its whole
        # length. A steep segment crosses one row in a narrow x window
        # even though its overall x-range may span the canvas, so
        # bucketing by the overall range makes a full-width diagonal a
        # candidate in every column of every row -- the whole bounding
        # box, which is the cost this filtering exists to avoid.
        #
        # The row band is [py - 0.5, py + 0.5] widened by half_width,
        # since a sample is covered by anything within half_width of
        # it: if the nearest point on the segment is an endpoint, that
        # endpoint is itself within half_width in y, so it falls in the
        # band too. Conservative in both directions, so coverage is
        # unchanged.
        var band_lo = Float64(py) - 0.5 - half_width - 1.0
        var band_hi = Float64(py) + 0.5 + half_width + 1.0
        for ri in range(len(row_candidates)):
            var seg = row_candidates[ri]
            var sx_lo: Float64
            var sx_hi: Float64
            var ay = seg_y0[seg]
            var dy = seg_dy[seg]
            if dy == 0.0:
                # Horizontal: the row filter already established that
                # this row is in range, and the whole segment is.
                sx_lo = seg_min_x[seg]
                sx_hi = seg_max_x[seg]
            else:
                var ta = (band_lo - ay) / dy
                var tb = (band_hi - ay) / dy
                if ta > tb:
                    var swap = ta
                    ta = tb
                    tb = swap
                if ta < 0.0:
                    ta = 0.0
                if tb > 1.0:
                    tb = 1.0
                if ta > tb:
                    continue  # segment does not reach this row's band
                var ax = seg_x0[seg]
                var ddx = seg_dx[seg]
                var xa = ax + ta * ddx
                var xb = ax + tb * ddx
                sx_lo = min(xa, xb) - half_width - 1.0
                sx_hi = max(xa, xb) + half_width + 1.0
            var lo = Int(ceil(sx_lo))
            var hi = Int(floor(sx_hi))
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
            if len(dashes) == 0:
                # No dash pattern means every candidate is always
                # on-dash, so coverage is a pure nearest-segment test
                # and the whole candidate loop vectorizes: the
                # projection and distance math is identical arithmetic
                # on `_AA_LANES` sub-samples at once. Only the final
                # "is the nearest segment within half-width" count stays
                # scalar, and that is `_AA_LANES` comparisons per chunk
                # rather than the per-candidate work.
                #
                # Dashed strokes keep the scalar path below: the dash
                # test needs each sample's own distance along the path
                # through `_is_dash_on`, which is a loop over the
                # pattern and does not vectorize usefully.
                for sy in range(n):
                    var sample_y = (
                        Float64(py) + (Float64(sy) + 0.5) * step - 0.5
                    )
                    var syv = SIMD[DType.float64, _AA_LANES](sample_y)
                    var sx0 = 0
                    while sx0 < n:
                        var lanes = n - sx0
                        if lanes > _AA_LANES:
                            lanes = _AA_LANES
                        var sxv = SIMD[DType.float64, _AA_LANES](0.0)
                        for l in range(lanes):
                            sxv[l] = (
                                Float64(px)
                                + (Float64(sx0 + l) + 0.5) * step
                                - 0.5
                            )
                        var minv = SIMD[DType.float64, _AA_LANES](1.0e30)
                        for ci in range(len(candidates)):
                            var seg = candidates[ci]
                            var fx0 = seg_x0[seg]
                            var fy0 = seg_y0[seg]
                            var ldx = seg_dx[seg]
                            var ldy = seg_dy[seg]
                            # A zero-length segment has inv_len2 == 0,
                            # so t falls out as 0 and the closest point
                            # is the segment's own endpoint -- the same
                            # answer the scalar path's explicit
                            # zero-length branch gives.
                            var len2 = seg_len2[seg]
                            var tv = SIMD[DType.float64, _AA_LANES](0.0)
                            if len2 != 0.0:
                                tv = (
                                    (sxv - fx0) * ldx + (syv - fy0) * ldy
                                ) / len2
                            tv = tv.clamp(0.0, 1.0)
                            var ddx = sxv - (fx0 + tv * ldx)
                            var ddy = syv - (fy0 + tv * ldy)
                            minv = min(minv, ddx * ddx + ddy * ddy)
                        # Lanes past `lanes` hold whatever the zeroed
                        # vector produced and are simply not read.
                        for l in range(lanes):
                            if minv[l] <= hw2:
                                covered += 1
                        sx0 += _AA_LANES
            else:
                for sy in range(n):
                    var sample_y = (
                        Float64(py) + (Float64(sy) + 0.5) * step - 0.5
                    )
                    for sx in range(n):
                        var sample_x = (
                            Float64(px) + (Float64(sx) + 0.5) * step - 0.5
                        )
                        var min_dist2 = -1.0
                        for ci in range(len(candidates)):
                            var seg = candidates[ci]
                            var fx0 = seg_x0[seg]
                            var fy0 = seg_y0[seg]
                            var ldx = seg_dx[seg]
                            var ldy = seg_dy[seg]
                            var len2 = seg_len2[seg]
                            var t: Float64
                            if len2 == 0.0:
                                t = 0.0
                            else:
                                t = (
                                    (sample_x - fx0) * ldx
                                    + (sample_y - fy0) * ldy
                                ) / len2
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
                                var sample_distance = (
                                    seg_start_distance[seg]
                                    + t * seg_length[seg]
                                )
                                if _is_dash_on(
                                    sample_distance, dashes, dash_offset
                                ):
                                    if min_dist2 < 0.0 or d2 < min_dist2:
                                        min_dist2 = d2
                        if min_dist2 >= 0.0:
                            covered += 1
            if covered > 0:
                var alpha = UInt8(
                    Int(
                        Float64(covered)
                        / Float64(total_samples)
                        * Float64(color.a)
                        + 0.5
                    )
                )
                canvas.set_pixel(
                    px, py, Color(color.r, color.g, color.b, alpha)
                )

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

    Args:
        canvas: Canvas to draw into.
        points: Vertices to connect, in order.
        color: Line color.
        width: Stroke width in pixels.
        supersample: Sub-pixel grid side length per pixel (N -> N*N
            samples).
        dashes: On/off segment lengths in pixels, cycled along the
            whole polyline. Empty (default) draws a solid line.
        dash_offset: Distance into the dash pattern the polyline
            starts at.
    """
    _draw_polyline_core_aa(
        canvas, points, color, width, supersample, False, dashes, dash_offset
    )


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

    Args:
        canvas: Canvas to draw into.
        points: Vertices to connect, in order.
        color: Line color.
        width: Stroke width in pixels.
        supersample: Sub-pixel grid side length per pixel (N -> N*N
            samples).
        dashes: On/off segment lengths in pixels, cycled all the way
            around the polygon. Empty (default) draws a solid line.
        dash_offset: Distance into the dash pattern the polygon starts
            at.
    """
    _draw_polyline_core_aa(
        canvas, points, color, width, supersample, True, dashes, dash_offset
    )
