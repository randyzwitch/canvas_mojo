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

from std.math import ceil, cos, floor, sin, sqrt

from canvas.color import Color
from canvas.buffer import Canvas
from canvas.geometry import Point, FPoint, _round_to_int
from canvas.aa_crossing import _EdgeTable, _sweep_edges_aa
from canvas.fill_rule import FillRule
from canvas.shapes.dash import _is_dash_on

comptime _SQRT2 = 1.4142135623730951

# Sub-samples evaluated per SIMD step in the anti-aliased polyline
# core. 4 rather than the widest available vector: the default
# supersample is 4, so one chunk covers a whole row of sub-samples with
# no masked-off lanes, and a wider vector would spend most of its width
# idle at the size this is actually called with.
comptime _AA_LANES = 4


struct LineCap(Copyable, ImplicitlyCopyable, Movable):
    """How an open stroke ends.

    ROUND (the default, and what this package has always drawn) caps
    with a half-disk of the stroke's own radius, so a stroke extends
    half its width past each endpoint. BUTT stops exactly at the
    endpoint. SQUARE stops half a width past it, with a flat end rather
    than a curved one.

    The distinction matters more than it sounds. An axis rule drawn
    from x=40 to x=560 with a 4px round cap actually spans 38 to 562,
    so it overshoots its own tick marks; a bar drawn as a thick line
    ends in a dome rather than flush with the baseline. Neither is
    fixable by shortening the line, because the overshoot scales with
    stroke width.

    Caps apply only to the two ends of an *open* stroke. A closed
    polygon has no ends, and passing a cap for one changes nothing.
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
        cap: How the two ends are finished -- see LineCap.
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
        cap: How the two ends are finished -- see LineCap.
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
):
    """`draw_line_aa` at sub-pixel endpoints -- the same line, placed
    to a fraction of a pixel rather than snapped to the pixel grid.

    This is the real implementation; the whole-pixel overload above
    converts and calls it. A chart plotting a value at x = 103.7 wants
    this one: rounding to 104 first moves the line by a third of a
    pixel, which at a 1px stroke width is a visible shift in where the
    series sits.

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
        cap: How the two ends are finished -- see LineCap.
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


struct _SegmentTable(Movable):
    """Every stroke segment's precomputed geometry, as flat arrays.

    These were thirteen parallel locals in `_draw_polyline_core_aa`.
    Bundling them is what lets the sweep be split into row bands: a
    band worker needs all of this and none of it changes once built, so
    it is passed as one immutable argument rather than threaded through
    a thirteen-parameter signature.

    Grouping also makes the invariant explicit -- every list here is
    `num_segments` long and indexed by the same segment number.
    """

    var start_distance: List[Float64]
    var length: List[Float64]
    var x0: List[Float64]
    var y0: List[Float64]
    var dx: List[Float64]
    var dy: List[Float64]
    var len2: List[Float64]
    var min_x: List[Float64]
    var max_x: List[Float64]
    var min_y: List[Float64]
    var max_y: List[Float64]
    # Which segment ends stop dead instead of rounding over -- see
    # LineCap. Only an open stroke's two extremities are ever flagged.
    var clip_start: List[Bool]
    var clip_end: List[Bool]

    def __init__(out self, capacity: Int):
        self.start_distance = List[Float64](capacity=capacity)
        self.length = List[Float64](capacity=capacity)
        self.x0 = List[Float64](capacity=capacity)
        self.y0 = List[Float64](capacity=capacity)
        self.dx = List[Float64](capacity=capacity)
        self.dy = List[Float64](capacity=capacity)
        self.len2 = List[Float64](capacity=capacity)
        self.min_x = List[Float64](capacity=capacity)
        self.max_x = List[Float64](capacity=capacity)
        self.min_y = List[Float64](capacity=capacity)
        self.max_y = List[Float64](capacity=capacity)
        self.clip_start = List[Bool](capacity=capacity)
        self.clip_end = List[Bool](capacity=capacity)


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
        canvas.set_pixel(
            _round_to_int(points[0].x), _round_to_int(points[0].y), color
        )
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
    var segs = _SegmentTable(num_segments)
    # Only an open stroke's two extremities are ever capped: every
    # interior joint keeps its round overlap, which is what stops a
    # joint double-blending (see this function's docstring).
    var capped = (not closed) and cap != LineCap.ROUND
    for seg in range(num_segments):
        segs.clip_start.append(capped and seg == 0)
        segs.clip_end.append(capped and seg == num_segments - 1)

    var running_distance = 0.0
    for seg in range(num_segments):
        var sa = points[seg]
        var sb = points[(seg + 1) % count]
        var sdx = sb.x - sa.x
        var sdy = sb.y - sa.y

        # SQUARE is BUTT with the end pushed out by half a width, so
        # only one rejection rule is needed below. Done here, on the
        # geometry, rather than as a second case in the sample loop.
        if cap == LineCap.SQUARE and (
            segs.clip_start[seg] or segs.clip_end[seg]
        ):
            var seg_len = sqrt(sdx * sdx + sdy * sdy)
            if seg_len > 0.0:
                var ux = sdx / seg_len
                var uy = sdy / seg_len
                if segs.clip_start[seg]:
                    sa = FPoint(sa.x - ux * half_width, sa.y - uy * half_width)
                if segs.clip_end[seg]:
                    sb = FPoint(sb.x + ux * half_width, sb.y + uy * half_width)
                sdx = sb.x - sa.x
                sdy = sb.y - sa.y
        var slen2 = sdx * sdx + sdy * sdy
        var slen = sqrt(slen2)
        segs.start_distance.append(running_distance)
        segs.length.append(slen)
        segs.x0.append(sa.x)
        segs.y0.append(sa.y)
        segs.dx.append(sdx)
        segs.dy.append(sdy)
        segs.len2.append(slen2)
        running_distance += slen

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

    # Each segment's bounding box, expanded by half_width -- a sample
    # outside it can't be within half_width of the segment, since its
    # closest point lies on the segment, inside the box -- plus a flat
    # 1.0 margin, since a pixel's samples land up to 0.5 from its
    # center in either axis. Precomputed so a whole pixel can skip a
    # segment without visiting any of its samples. Without this the
    # sweep is O(pixels * supersample^2 * segments) even for an
    # ordinary line chart spread across the canvas, where most
    # segments are nowhere near most pixels.
    for seg in range(num_segments):
        var a = points[seg]
        var b = points[(seg + 1) % count]
        var ax = a.x
        var ay = a.y
        var bx = b.x
        var by = b.y
        segs.min_x.append(min(ax, bx) - half_width - 1.0)
        segs.max_x.append(max(ax, bx) + half_width + 1.0)
        segs.min_y.append(min(ay, by) - half_width - 1.0)
        segs.max_y.append(max(ay, by) + half_width + 1.0)

    # Undashed strokes go through the ordinary path fill: the stroke's
    # own outline is handed to `_sweep_edges_aa`, which is parallel
    # across cores. See `_stroke_edges` for why the two formulations
    # describe the same shape.
    #
    # Dashed strokes stay on the sampling core below for now: dashing a
    # fill means splitting each segment into its on-intervals
    # geometrically, which is a separate piece of work.
    if len(dashes) == 0:
        var edges = _stroke_edges(points, closed, half_width, cap)
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
        return

    # Extracted into `_stroke_band` rather than inlined here, with its
    # scratch buffers local to the call. That is the shape a banded,
    # multi-core sweep needs, and the fill sweep in
    # `canvas.aa_crossing` already runs that way to good effect.
    #
    # This one does not, yet. Splitting it across tasks produced a
    # reliable nondeterministic result -- 19 of 20 repeat renders
    # differing -- that I could not track down, and a renderer that
    # returns a different image each run is far worse than a slow one.
    # See the issue this file's history references for the
    # reproduction and for what was ruled out. Kept as a single call
    # until that is understood.
    var row_count = max_y - min_y + 1
    if row_count <= 0 or max_x - min_x + 1 <= 0:
        return
    _stroke_band(
        canvas,
        segs,
        num_segments,
        min_x,
        max_x,
        min_y,
        max_y + 1,
        half_width,
        hw2,
        n,
        step,
        total_samples,
        color,
        dashes,
        dash_offset,
    )


def _stroke_band(
    mut canvas: Canvas,
    segs: _SegmentTable,
    num_segments: Int,
    min_x: Int,
    max_x: Int,
    first_row: Int,
    last_row: Int,
    half_width: Float64,
    hw2: Float64,
    n: Int,
    step: Float64,
    total_samples: Int,
    color: Color,
    dashes: List[Float64],
    dash_offset: Float64,
):
    """Sweep rows [first_row, last_row) of a stroke onto `canvas`.

    Currently always called once, for the whole row range. It takes a
    range, and keeps its scratch buffers local rather than shared with
    the caller, so that splitting the sweep across cores becomes a
    change to the caller alone -- see the note there on why that is not
    done yet.
    """
    # Per-column candidate buckets, indexed by `px - min_x`, cleared
    # and reused across this band's rows rather than reallocated.
    var col_candidates = List[List[Int]](capacity=max_x - min_x + 1)
    for _ in range(max_x - min_x + 1):
        col_candidates.append(List[Int]())

    var row_candidates = List[Int](capacity=num_segments)
    for py in range(first_row, last_row):
        var fpy = Float64(py)

        # Row-level pre-filter by y alone, before the per-pixel x
        # check: the y test is identical for every pixel in the row, so
        # computing it per row rather than per (row, pixel) makes this
        # part O(rows * segments) instead of O(pixels * segments).
        row_candidates.clear()
        for seg in range(num_segments):
            if fpy >= segs.min_y[seg] and fpy <= segs.max_y[seg]:
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
            var ay = segs.y0[seg]
            var dy = segs.dy[seg]
            if dy == 0.0:
                # Horizontal: the row filter already established that
                # this row is in range, and the whole segment is.
                sx_lo = segs.min_x[seg]
                sx_hi = segs.max_x[seg]
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
                var ax = segs.x0[seg]
                var ddx = segs.dx[seg]
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
                            var fx0 = segs.x0[seg]
                            var fy0 = segs.y0[seg]
                            var ldx = segs.dx[seg]
                            var ldy = segs.dy[seg]
                            # A zero-length segment has inv_len2 == 0,
                            # so t falls out as 0 and the closest point
                            # is the segment's own endpoint -- the same
                            # answer the scalar path's explicit
                            # zero-length branch gives.
                            var len2 = segs.len2[seg]
                            var raw_t = SIMD[DType.float64, _AA_LANES](0.0)
                            if len2 != 0.0:
                                raw_t = (
                                    (sxv - fx0) * ldx + (syv - fy0) * ldy
                                ) / len2
                            var tv = raw_t.clamp(0.0, 1.0)
                            var ddx = sxv - (fx0 + tv * ldx)
                            var ddy = syv - (fy0 + tv * ldy)
                            var d2v = ddx * ddx + ddy * ddy

                            # A capped end contributes nothing beyond
                            # its own endpoint. Testing the *unclamped*
                            # projection is what distinguishes "past the
                            # end" from "beside it": clamping first
                            # turns both into a distance to the
                            # endpoint, which is precisely the round
                            # cap. The two guards are scalar per
                            # segment, so an uncapped stroke -- every
                            # closed shape, and the default -- runs the
                            # identical lane arithmetic it always did.
                            if segs.clip_start[seg] or segs.clip_end[seg]:
                                # Per lane rather than a vector mask:
                                # comparing two SIMDs reduces to a
                                # single Bool in this Mojo, so there is
                                # no lane mask to select on. At most two
                                # segments of a stroke are ever capped,
                                # so this runs for those and never for
                                # the interior.
                                for lane in range(_AA_LANES):
                                    var rt = raw_t[lane]
                                    if segs.clip_start[seg] and rt < 0.0:
                                        d2v[lane] = 1.0e30
                                    elif segs.clip_end[seg] and rt > 1.0:
                                        d2v[lane] = 1.0e30
                            minv = min(minv, d2v)
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
                            var fx0 = segs.x0[seg]
                            var fy0 = segs.y0[seg]
                            var ldx = segs.dx[seg]
                            var ldy = segs.dy[seg]
                            var len2 = segs.len2[seg]
                            var t: Float64
                            if len2 == 0.0:
                                t = 0.0
                            else:
                                var raw_t = (
                                    (sample_x - fx0) * ldx
                                    + (sample_y - fy0) * ldy
                                ) / len2
                                # See the vectorized path above on why
                                # this tests the unclamped projection.
                                if segs.clip_start[seg] and raw_t < 0.0:
                                    continue
                                if segs.clip_end[seg] and raw_t > 1.0:
                                    continue
                                t = raw_t
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
                                    segs.start_distance[seg]
                                    + t * segs.length[seg]
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


# How deep a notch a joint may leave before it needs a round disk to
# fill it, in pixels. A fiftieth of a pixel is a fifth of a sub-sample
# at the default supersample, so a skipped joint cannot move a
# coverage count.
comptime _JOIN_DISK_TOLERANCE = 0.02


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

    Sampled at roughly one point per pixel of circumference, the same
    radius-proportional rule `canvas.shapes.arcs` uses -- a hairline
    stroke's joins cost eight edges, a thick one's cost enough to stay
    smooth. The floor of 8 matters: a 4-gon inscribed in the disk would
    cut visibly inside the segment quads it is meant to round off.
    """
    if radius <= 0.0:
        return
    # Two points per pixel of circumference, floor 16. The floor is
    # what matters at the hairline widths a chart actually uses: at
    # radius 1 an inscribed 8-gon sits up to 0.076px inside the true
    # circle, which is a third of a sub-sample and shows up as tens of
    # alpha levels on a boundary pixel.
    var steps = Int(12.566370614359172 * radius)
    if steps < 16:
        steps = 16

    # Vertices pushed out to the mid-radius rather than sitting on the
    # circle. An inscribed polygon only ever under-covers; splitting
    # the difference centres the error instead of biasing every join
    # and cap thin.
    var r = radius * (1.0 + 1.0 / cos(3.141592653589793 / Float64(steps))) * 0.5
    # Wound the same way `_add_quad` winds, which for a segment along
    # +x comes out negative (clockwise in the standard orientation, y
    # running down the screen here). Sampling the disk the other way
    # round makes NONZERO *cancel* the overlap between a joint's disk
    # and the quads meeting there rather than union it -- which is a
    # hole at every joint, not a rounding difference.
    var px = cx + r
    var py = cy
    for i in range(1, steps + 1):
        var t = -Float64(i) / Float64(steps) * 6.283185307179586
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
) -> _EdgeTable:
    """A stroke expressed as the outline of a filled region.

    The min-distance formulation `_draw_polyline_core_aa` uses defines
    a stroke as every point within `half_width` of some segment. That
    is exactly the union of one rectangle per segment and one disk per
    vertex -- so the same shape can be handed to the ordinary path fill
    instead of being sampled against segments per pixel.

    Which is the point: `_sweep_edges_aa` is already parallel across
    cores and already correct, where the stroke sweep's own banding is
    blocked by a Mojo defect in how tasks receive aggregate arguments.
    Expressing strokes as fills gets the speedup by deleting the
    stroke-specific parallel path rather than trying to make it safe.

    Round joins and caps fall out of the vertex disks, which is what
    the min-distance form produced too. BUTT and SQUARE differ only at
    the two open ends: BUTT omits their disks, SQUARE omits them and
    instead extends the end segments by half a width -- the same trick
    the sampling core used.
    """
    var edges = _EdgeTable()
    var count = len(points)
    if count == 0 or half_width <= 0.0:
        return edges^

    if count == 1:
        if closed or cap == LineCap.ROUND:
            _add_disk(edges, points[0].x, points[0].y, half_width)
        return edges^

    var num_segments = count if closed else count - 1
    var capped = (not closed) and cap != LineCap.ROUND

    for seg in range(num_segments):
        var a = points[seg]
        var b = points[(seg + 1) % count]
        var dx = b.x - a.x
        var dy = b.y - a.y
        var length = sqrt(dx * dx + dy * dy)
        if length == 0.0:
            continue  # a vertex disk covers a zero-length segment

        var ux = dx / length
        var uy = dy / length
        if cap == LineCap.SQUARE and capped:
            if seg == 0:
                a = FPoint(a.x - ux * half_width, a.y - uy * half_width)
            if seg == num_segments - 1:
                b = FPoint(b.x + ux * half_width, b.y + uy * half_width)
        _add_quad(edges, a.x, a.y, b.x, b.y, -uy * half_width, ux * half_width)

    # Vertex disks. An open stroke's two ends get one only under a
    # round cap; every joint gets one only if it actually needs it.
    #
    # Two quads meeting at a turn of angle theta leave a wedge on the
    # outer side, and the disk exists to fill it. The wedge's depth is
    # half_width * (1 - cos(theta/2)), so a nearly-straight joint needs
    # no disk at all -- the quads already overlap across it.
    #
    # That is not a micro-optimisation here. A flattened curve is
    # thousands of nearly-collinear segments, and giving every one of
    # its joints a 16-point disk buries the sweep in edges it gains
    # nothing from: `stroke_path_aa` on a 39-curve path measured 9064us
    # with disks everywhere against 3222us with this test, for
    # byte-identical output.
    var first_joint = 1
    var last_joint = count - 1
    if closed:
        first_joint = 0
        last_joint = count
    if (not closed) and cap == LineCap.ROUND:
        # Round caps are disks at the two ends, always.
        _add_disk(edges, points[0].x, points[0].y, half_width)
        _add_disk(edges, points[count - 1].x, points[count - 1].y, half_width)

    for i in range(first_joint, last_joint):
        var prev = points[(i - 1 + count) % count]
        var here = points[i]
        var next = points[(i + 1) % count]
        var inx = here.x - prev.x
        var iny = here.y - prev.y
        var outx = next.x - here.x
        var outy = next.y - here.y
        var in_len = sqrt(inx * inx + iny * iny)
        var out_len = sqrt(outx * outx + outy * outy)
        if in_len == 0.0 or out_len == 0.0:
            _add_disk(edges, here.x, here.y, half_width)
            continue
        var dot = (inx * outx + iny * outy) / (in_len * out_len)
        if dot > 1.0:
            dot = 1.0
        elif dot < -1.0:
            dot = -1.0
        # half_width * (1 - cos(theta/2)), with
        # cos(theta/2) = sqrt((1 + cos theta) / 2).
        var sagitta = half_width * (1.0 - sqrt((1.0 + dot) * 0.5))
        if sagitta > _JOIN_DISK_TOLERANCE:
            _add_disk(edges, here.x, here.y, half_width)

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
):
    """`draw_polyline_aa` at sub-pixel vertices -- the same polyline, placed
    to a fraction of a pixel rather than snapped to the pixel grid.

    This is the real implementation; the whole-pixel overload above
    converts and calls it. See `draw_line_aa`'s sub-pixel overload for
    why a chart wants this one.

    Args:
        canvas: Canvas to draw into.
        points: Vertices to connect, in order, at sub-pixel positions.
        color: Line color.
        width: Stroke width in pixels.
        supersample: Sub-pixel grid side length per pixel (N -> N*N
            samples).
        dashes: On/off segment lengths in pixels. Empty (default) draws
            a solid line.
        dash_offset: Distance into the dash pattern to start at.
        cap: How the two open ends are finished -- see LineCap.
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
    var fpoints = List[FPoint](capacity=len(points))
    for i in range(len(points)):
        fpoints.append(FPoint(Float64(points[i].x), Float64(points[i].y)))
    draw_polygon_aa(
        canvas, fpoints, color, width, supersample, dashes, dash_offset
    )


def draw_polygon_aa(
    mut canvas: Canvas,
    points: List[FPoint],
    color: Color,
    width: Float64 = 1.0,
    supersample: Int = 4,
    dashes: List[Float64] = List[Float64](),
    dash_offset: Float64 = 0.0,
):
    """`draw_polygon_aa` at sub-pixel vertices -- the same polygon outline, placed
    to a fraction of a pixel rather than snapped to the pixel grid.

    This is the real implementation; the whole-pixel overload above
    converts and calls it. See `draw_line_aa`'s sub-pixel overload for
    why a chart wants this one.

    Args:
        canvas: Canvas to draw into.
        points: Vertices to connect, in order, at sub-pixel positions.
        color: Line color.
        width: Stroke width in pixels.
        supersample: Sub-pixel grid side length per pixel (N -> N*N
            samples).
        dashes: On/off segment lengths in pixels. Empty (default) draws
            a solid line.
        dash_offset: Distance into the dash pattern to start at.
    """
    _draw_polyline_core_aa(
        canvas, points, color, width, supersample, True, dashes, dash_offset
    )
