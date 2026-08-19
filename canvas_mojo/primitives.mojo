"""Shape-drawing algorithms built entirely on Canvas's public API
(set_pixel/in_bounds) -- no knowledge of the pixel buffer's internals.

Naming convention, decided deliberately rather than by default: hard-
edged and anti-aliased variants stay separate functions (draw_circle
vs. draw_circle_aa), never merged behind an `antialias: Bool` flag on
one function. A shared name with a hidden branch would also invite
parameters that only mean something in one branch (draw_line_aa's
`width` has no hard-edged equivalent -- Bresenham is definitionally
1px), and would hide a real algorithmic-complexity jump (hard-edged
circle drawing is O(radius); AA is O(radius^2 * supersample^2)) behind
what looks like a boolean toggle. The `_aa` suffix keeps that visible
at the call site. Apply the same split to future primitives (ellipse,
AA polyline, ...) rather than reopening this per shape.
"""

from std.math import atan2, cos, floor, sin, sqrt

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas
from canvas_mojo.geometry import Point, _round_to_int
from canvas_mojo.gradient import LinearGradient, RadialGradient
from canvas_mojo.fill_rule import FillRule

comptime _SQRT2 = 1.4142135623730951


def _is_dash_on(distance: Float64, dashes: List[Float64], offset: Float64) -> Bool:
    """Is `distance` (measured along a path from wherever its dash
    phase starts) inside an "on" (drawn) segment of `dashes`, an
    alternating on/off/on/off/... list of lengths (index 0 is "on"),
    repeating indefinitely and shifted by `offset`?

    An empty `dashes` list -- the default everywhere this is called
    from -- means "no dash pattern," always on: every draw_line/
    draw_polyline/etc. call that doesn't pass dashes= behaves exactly
    as it did before this parameter existed.

    An odd-length list is doubled (Cairo's own convention, matched
    here for anyone porting a pattern from it): [5, 2, 1] means the
    same as [5, 2, 1, 5, 2, 1] -- an odd count otherwise couldn't
    alternate on/off evenly around the repeat.
    """
    if len(dashes) == 0:
        return True

    var odd = len(dashes) % 2 == 1
    var pattern = List[Float64]()
    for d in dashes:
        pattern.append(d)
    if odd:
        for d in dashes:
            pattern.append(d)

    var total = 0.0
    for d in pattern:
        total += d
    if total <= 0.0:
        return True

    # floor-based modulo (not `%`/truncating remainder) so a negative
    # offset wraps correctly instead of landing outside [0, total).
    var raw = distance + offset
    var wrapped = raw - floor(raw / total) * total

    var cursor = 0.0
    for i in range(len(pattern)):
        cursor += pattern[i]
        if wrapped < cursor:
            return i % 2 == 0
    return True  # unreachable given wrapped < total by construction


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

    Returns the total distance traveled (sum of per-step Euclidean
    lengths -- 1.0 for an axis step, sqrt(2) for a diagonal one, since
    Bresenham always moves by exactly one pixel in x and/or y per
    step) so draw_polyline/draw_polygon can carry a dash pattern's
    phase continuously across a joint into the next segment's
    dash_start_distance, rather than each segment restarting the
    pattern from 0 and creating a visible discontinuity at every
    corner. This is the actual accumulated raster-walk distance, not
    the segment's idealized straight-line length (sqrt(dx^2+dy^2)) --
    the two are extremely close but not always bit-identical, and
    using the real accumulated value keeps a dash pattern's phase
    exactly consistent with what this function itself just drew,
    rather than consistent with a slightly different idealized number.
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
    _is_dash_on) -- empty by default, a solid line, exactly the
    original behavior. Measured in the same accumulated-raster-step
    distance _draw_line_core's own docstring describes, not an
    idealized straight-line distance.
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

    `dashes` (see _is_dash_on) is measured along this segment's own
    idealized straight-line length here, not the raster-step distance
    _draw_line_core's hard-edged version uses -- there's no pixel walk
    to measure steps along in a supersampled algorithm, and `t` (the
    already-computed, already-clamped projection fraction along the
    segment) times the segment's true length is the natural distance
    measure available at each sample. A sample beyond either endpoint
    (t clamped to 0 or 1) is measured as if it were exactly at that
    endpoint, consistent with how the round-cap distance test already
    treats those samples.
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

    A dash pattern's phase carries continuously across joints -- each
    segment starts where the previous one's accumulated distance left
    off (see _draw_line_core's own docstring), not restarted at 0, so
    dashes don't visibly reset or jump at a corner.
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

    The closing segment skips both its shared start point (already
    drawn by the previous segment) and its shared end point (already
    drawn as the very first pixel of the whole polygon), so every
    vertex -- including the one where the shape closes -- is drawn
    exactly once. A dash pattern's phase carries continuously all the
    way around, including across the closing segment -- same as
    draw_polyline's own joints.
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

    Calling draw_line_aa once per segment would double-blend at every
    joint -- unlike the hard-edged version, there's no "skip a pixel"
    fix, since AA coverage isn't computed pixel-by-pixel-skip but by
    sampling. The actual fix: for every sample, test its distance to
    EVERY segment and keep the minimum, so a joint where two segments'
    round-cap regions overlap still produces exactly one coverage
    value -- and one set_pixel call -- per pixel.

    Dashing composes with that same per-sample minimum, restructured
    slightly to fit: a segment only counts as a coverage candidate at
    all if the sample's projected point on it is both within
    half_width AND inside an "on" dash region for that segment's own
    (precomputed, joint-continuous) start distance. A sample near a
    joint where one segment's dash state is "off" but a neighboring
    segment's is "on" at that same physical point still gets covered,
    correctly, because each segment's dash state is evaluated
    independently before taking the minimum -- not by dashing some
    single, already-collapsed "closest segment" answer.
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

    # Each segment's start distance (cumulative length of every
    # segment before it) and own length, precomputed once -- what
    # lets a dash pattern's phase carry continuously across joints,
    # the same idea as draw_polyline's own running `distance`, just
    # precomputed here since this function's main loop iterates
    # samples, not segments in path order.
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

    for py in range(min_y, max_y + 1):
        for px in range(min_x, max_x + 1):
            var covered = 0
            for sy in range(n):
                var sample_y = Float64(py) + (Float64(sy) + 0.5) * step - 0.5
                for sx in range(n):
                    var sample_x = Float64(px) + (Float64(sx) + 0.5) * step - 0.5
                    var min_dist2 = -1.0
                    for seg in range(num_segments):
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
                        # projected point -- equivalent to the old
                        # unconditional-min-then-compare-to-hw2 when
                        # dashes is empty (every segment is always
                        # on-dash then), since a global min <= hw2 can
                        # only come from a segment that itself has
                        # d2 <= hw2.
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


def draw_polyline_aa(
    mut canvas: Canvas,
    points: List[Point],
    color: Color,
    width: Float64 = 1.0,
    supersample: Int = 4,
    dashes: List[Float64] = List[Float64](),
    dash_offset: Float64 = 0.0,
):
    """Anti-aliased polyline -- see draw_polyline for the hard-edged
    version and _draw_polyline_core_aa for how joints avoid the
    double-blend hazard, and (separately) how a dash pattern's phase
    carries continuously across them.
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
    """Anti-aliased polygon outline -- see draw_polygon for the
    hard-edged version. The closing segment is included in every
    sample's minimum-distance test, same as any other segment, so the
    closing vertex gets no special-case handling here (unlike
    draw_polygon's skip_first/skip_last) -- and a dash pattern's phase
    carries continuously across it too, same as every other joint.
    """
    _draw_polyline_core_aa(canvas, points, color, width, supersample, True, dashes, dash_offset)


struct _Crossing(ImplicitlyCopyable, Movable):
    """One scanline crossing: where an edge crosses row y, and which
    way it's going (+1 for an edge stepping from lower y to higher y,
    -1 the other way) -- the signed direction is what nonzero winding
    needs; even-odd only needs the count, but a signed +/-1 per
    crossing still flips parity exactly once per crossing regardless
    of sign, so one representation serves both rules (see
    _is_inside).
    """

    var x: Int
    var direction: Int

    def __init__(out self, x: Int, direction: Int):
        self.x = x
        self.direction = direction


struct _Span(ImplicitlyCopyable, Movable):
    var start_x: Int
    var end_x: Int

    def __init__(out self, start_x: Int, end_x: Int):
        self.start_x = start_x
        self.end_x = end_x


def _is_inside(winding: Int, fill_rule: FillRule) -> Bool:
    if fill_rule == FillRule.NONZERO:
        return winding != 0
    var w = winding
    if w < 0:
        w = -w
    return w % 2 == 1


def _spans_from_crossings(mut crossings: List[_Crossing], fill_rule: FillRule) -> List[_Span]:
    """Given one row's crossings (unsorted, x position + direction),
    sort by x and scan left to right accumulating a signed winding
    number, returning the resulting filled spans under `fill_rule`.

    Shared by fill_polygon and fill_path (and their gradient variants,
    see path.mojo) -- they differ only in how they collect a row's
    crossings (one polygon's edges vs. every sub-path's edges
    combined) and what they do with each resulting span (set_pixel one
    flat color, or query a gradient per pixel), not in this scan.

    For EVEN_ODD specifically, this produces byte-identical spans to
    the simpler "sort plain x values, pair them up (1st-2nd, 3rd-4th,
    ...)" approach this replaced, for any simple (non-self-
    intersecting) polygon -- verified directly against every existing
    fill_polygon test, not just argued: a signed winding number's
    parity flips exactly once per crossing regardless of that
    crossing's sign, which is exactly what alternating in/out pairing
    already assumed.

    One more step beyond the plain winding scan: adjacent spans get
    merged wherever one's end_x touches or overlaps the next one's
    start_x. This matters for a genuinely self-intersecting shape
    where two unrelated edges happen to cross the same scanline at the
    same rounded integer x -- winding can dip back to "outside" and
    immediately back to "inside" at that exact x, which without
    merging would produce two spans that both (correctly, given the
    X-fill's own inclusive-inclusive convention -- see fill_polygon's
    docstring) include that shared x, double-blending a translucent
    color there. Confirmed this is a real, reachable case (not just a
    theoretical one) and that merging fixes it: synthetic touching
    crossings run directly through this function
    (test_spans_from_crossings_merges_touching_spans) and a self-
    intersecting bowtie polygon run through fill_polygon itself
    (test_fill_polygon_self_intersecting_bowtie_matches_hand_derived_spans).
    """
    for i in range(1, len(crossings)):
        var key = crossings[i]
        var j = i - 1
        while j >= 0 and crossings[j].x > key.x:
            crossings[j + 1] = crossings[j]
            j -= 1
        crossings[j + 1] = key

    var raw_spans = List[_Span]()
    var winding = 0
    var span_start = 0
    for i in range(len(crossings)):
        var was_inside = _is_inside(winding, fill_rule)
        winding += crossings[i].direction
        var now_inside = _is_inside(winding, fill_rule)
        if not was_inside and now_inside:
            span_start = crossings[i].x
        elif was_inside and not now_inside:
            raw_spans.append(_Span(span_start, crossings[i].x))

    var spans = List[_Span]()
    for i in range(len(raw_spans)):
        if len(spans) > 0:
            ref last = spans[len(spans) - 1]
            if raw_spans[i].start_x <= last.end_x + 1:
                if raw_spans[i].end_x > last.end_x:
                    last.end_x = raw_spans[i].end_x
                continue
        spans.append(raw_spans[i])

    return spans^


def fill_polygon(
    mut canvas: Canvas, points: List[Point], color: Color, fill_rule: FillRule = FillRule.EVEN_ODD
):
    """Fill a polygon's interior with the scanline algorithm.

    For each row, find where every edge crosses it and accumulate a
    signed winding number left to right (see _spans_from_crossings);
    `fill_rule` (default EVEN_ODD, matching this function's original
    and still-unchanged behavior when unspecified) decides which
    resulting regions count as "inside" -- see fill_rule.mojo for what
    the two rules actually mean and why NONZERO exists.

    Y-extent per edge uses the standard half-open [min(y0,y1),
    max(y0,y1)) convention -- required for correctness, not just a
    style choice: without it, a vertex shared by two edges going in
    opposite y-directions would be counted as a crossing by both
    edges (double-counted), while a vertex that's a genuine local
    extremum (a triangle's apex, say) needs to contribute *zero* net
    crossings, not two. This asymmetric rule is what makes both cases
    come out right, and it's the same convention real rasterizers use
    (OpenGL/DirectX's "top-left fill rule") so adjacent shapes sharing
    an edge tile without a gap or double-covered seam.

    One concrete, surprising-if-undocumented consequence: a polygon's
    bottom-most row, when it's a horizontal edge (as in any axis-
    aligned rectangle), does not get filled -- both adjacent edges
    have that y as their excluded "max" endpoint. This means matching
    fill_rect(x, y, width, height) exactly requires *asymmetric*
    polygon corners: (x, y), (x+width-1, y), (x+width-1, y+height),
    (x, y+height) -- inclusive on the last column, one-past on the
    last row. (The X-fill between a row's crossing pair is fully
    inclusive; only the Y-extent per edge is half-open. Verified
    exactly against fill_rect with those corners.)

    A self-intersecting polygon is fully supported now (this
    function's own docstring used to warn it wasn't) -- under either
    fill rule, every pixel gets exactly one set_pixel call per row,
    never two, including right at a self-intersection: see
    _spans_from_crossings' own docstring for the specific case (two
    unrelated edges crossing the same row at the same rounded x) that
    needed an explicit span-merge step, not just the winding scan
    alone, to guarantee this.
    """
    var n = len(points)
    if n < 3:
        return

    var min_y = points[0].y
    var max_y = points[0].y
    for i in range(1, n):
        if points[i].y < min_y:
            min_y = points[i].y
        if points[i].y > max_y:
            max_y = points[i].y

    for y in range(min_y, max_y):
        var crossings = List[_Crossing]()
        for i in range(n):
            var p0 = points[i]
            var p1 = points[(i + 1) % n]
            if p0.y == p1.y:
                continue
            var lo = min(p0.y, p1.y)
            var hi = max(p0.y, p1.y)
            if y >= lo and y < hi:
                var t = Float64(y - p0.y) / Float64(p1.y - p0.y)
                var x = Float64(p0.x) + t * Float64(p1.x - p0.x)
                var direction = 1 if p1.y > p0.y else -1
                crossings.append(_Crossing(Int(x + 0.5), direction))

        var spans = _spans_from_crossings(crossings, fill_rule)
        for span_idx in range(len(spans)):
            ref span = spans[span_idx]
            for x in range(span.start_x, span.end_x + 1):
                canvas.set_pixel(x, y, color)


def _point_in_polygon(points: List[Point], fx: Float64, fy: Float64, fill_rule: FillRule) -> Bool:
    """The same winding-number membership test fill_polygon's per-row
    crossing scan uses, generalized from an integer scanline to one
    arbitrary real-valued point -- the analytic coverage test
    fill_polygon_aa's supersampling needs (the same relationship
    fill_circle's integer distance test has to fill_circle_aa's
    real-valued one).

    A horizontal ray from (fx, fy) extended in the +x direction:
    every edge crossing the line y=fy at an x strictly greater than
    fx contributes its signed direction to a running winding number,
    same half-open Y-extent convention ([min(y0,y1), max(y0,y1)))
    fill_polygon's own row scan uses and for the identical reason (a
    shared vertex between opposite-direction edges must count once,
    not twice). `_is_inside(winding, fill_rule)` decides membership --
    the same function fill_polygon's spans already use, so a hard-
    edged and AA fill agree on where a shape's boundary is, not just
    approximately.
    """
    var winding = 0
    var n = len(points)
    for i in range(n):
        var p0 = points[i]
        var p1 = points[(i + 1) % n]
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


struct _AACrossing(ImplicitlyCopyable, Movable):
    """One sub-scanline crossing at a real-valued x -- _Crossing's own
    fractional-y counterpart, for fill_polygon_aa's sweep below (same
    struct shape, and same role, as path.mojo's own _AACrossing; kept
    as a separate local definition rather than imported from there to
    avoid a new primitives.mojo -> path.mojo dependency for one small
    struct -- path.mojo already imports *from* primitives.mojo, so the
    reverse edge would be a real cycle, not just an inconvenience).
    """

    var x: Float64
    var direction: Int

    def __init__(out self, x: Float64, direction: Int):
        self.x = x
        self.direction = direction


def _polygon_row_crossings_aa(points: List[Point], fy: Float64) -> List[_AACrossing]:
    """_point_in_polygon's own per-sample ray-cast, factored out to run
    once per sub-scanline instead of once per sub-pixel sample -- see
    fill_polygon_aa's own docstring for why this is what makes its
    sweep sub-quadratic (the identical technique, and the identical
    reasoning, as path.mojo's fill_path_aa/_row_crossings_aa).
    """
    var crossings = List[_AACrossing]()
    var n = len(points)
    for i in range(n):
        var p0 = points[i]
        var p1 = points[(i + 1) % n]
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


def _sort_aa_crossings_by_x(mut crossings: List[_AACrossing]):
    """Insertion sort -- one sub-scanline's own crossing count is
    always small (a handful, not the polygon's full point count), the
    same reasoning _spans_from_crossings' own identical insertion sort
    already relies on."""
    for i in range(1, len(crossings)):
        var key = crossings[i]
        var j = i - 1
        while j >= 0 and crossings[j].x > key.x:
            crossings[j + 1] = crossings[j]
            j -= 1
        crossings[j + 1] = key


def fill_polygon_aa(
    mut canvas: Canvas,
    points: List[Point],
    color: Color,
    fill_rule: FillRule = FillRule.EVEN_ODD,
    supersample: Int = 4,
):
    """Anti-aliased filled polygon -- fill_polygon's counterpart the
    same way fill_circle_aa is fill_circle's: for every pixel near the
    polygon, samples an NxN sub-pixel grid and turns the coverage
    fraction directly into that pixel's alpha. Each output pixel is
    visited exactly once, so there's no double-blend hazard the way a
    naive per-edge fill would have.

    Closes the one inconsistency left once every other filled
    primitive (circle/ellipse/arc/ring) already had an AA companion:
    an arbitrary filled shape -- the general case an area chart's
    region or a custom marker boundary actually is -- could only ever
    render hard-edged. `draw_polygon_aa` already existed, but only as
    an AA *outline*; this is the fill fill_polygon itself never had.

    Same pixel-centered-AT-its-integer-coordinate convention every
    other AA primitive here uses (not a unit square with the pixel at
    its corner), and the same `fill_rule` parameter fill_polygon
    itself takes, sharing `_is_inside` so the hard-edged and AA fills
    of the identical shape agree on where the boundary is.

    Swept per sub-scanline (_polygon_row_crossings_aa), not per
    sub-pixel sample via a fresh _point_in_polygon ray-cast -- the
    identical rewrite, for the identical reason, path.mojo's own
    fill_path_aa already went through (see that function's own
    docstring for the full complexity argument: O(pixels *
    supersample^2 * edges) collapses to O(pixels * supersample) once a
    sub-scanline's crossings are collected once and swept left-to-right
    with a single forward-only pointer instead of re-scanned per
    sample). `_point_in_polygon` itself is untouched -- still the
    tested, from-scratch reference implementation this sweep's own
    output must agree with pixel-for-pixel.

    Not fused with fill_polygon behind an `antialias: Bool` -- see
    this module's own docstring for why that split is kept visible
    everywhere else (a real complexity-class jump per pixel), the same
    reasoning applies here.
    """
    var n = len(points)
    if n < 3:
        return

    var min_x = points[0].x
    var max_x = points[0].x
    var min_y = points[0].y
    var max_y = points[0].y
    for i in range(1, n):
        if points[i].x < min_x:
            min_x = points[i].x
        if points[i].x > max_x:
            max_x = points[i].x
        if points[i].y < min_y:
            min_y = points[i].y
        if points[i].y > max_y:
            max_y = points[i].y

    var s = supersample
    var total_samples = s * s
    var step = 1.0 / Float64(s)
    var row_first_px = min_x - 1
    var row_width = (max_x + 2) - row_first_px

    for py in range(min_y - 1, max_y + 2):
        var row_covered = List[Int](capacity=row_width)
        for _ in range(row_width):
            row_covered.append(0)

        for sy in range(s):
            var fy = Float64(py) + (Float64(sy) + 0.5) * step - 0.5
            var crossings = _polygon_row_crossings_aa(points, fy)
            _sort_aa_crossings_by_x(crossings)
            var k = len(crossings)

            var suffix = List[Int](capacity=k + 1)
            for _ in range(k + 1):
                suffix.append(0)
            for i in range(k - 1, -1, -1):
                suffix[i] = suffix[i + 1] + crossings[i].direction

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


def draw_rect(mut canvas: Canvas, x: Int, y: Int, width: Int, height: Int, color: Color):
    """Stroke a rectangle's outline (x, y is the top-left corner).

    Draws each edge exactly once -- the left/right edges stop short of
    the corners already covered by the top/bottom edges, so a
    translucent color doesn't get blended twice at any pixel.
    """
    if width <= 0 or height <= 0:
        return

    var x1 = x + width - 1
    var y1 = y + height - 1

    draw_line(canvas, x, y, x1, y, color)  # top, full width
    if height > 1:
        draw_line(canvas, x, y1, x1, y1, color)  # bottom, full width
    if height > 2:
        draw_line(canvas, x, y + 1, x, y1 - 1, color)  # left, corners excluded
        draw_line(canvas, x1, y + 1, x1, y1 - 1, color)  # right, corners excluded


def fill_rect(mut canvas: Canvas, x: Int, y: Int, width: Int, height: Int, color: Color):
    """Fill a solid rectangle (x, y is the top-left corner).

    Clamps to the canvas's own bounds and the active clip *once*, up
    front, via effective_fill_rect -- not per pixel through set_pixel
    -- since every pixel in this loop shares the identical, unchanging
    bounds check; see that method's own docstring on buffer.mojo's
    Canvas.
    """
    if width <= 0 or height <= 0:
        return

    var region = canvas.effective_fill_rect(x, y, width, height)
    var rx = region[0]
    var ry = region[1]
    var rw = region[2]
    var rh = region[3]
    for yy in range(ry, ry + rh):
        for xx in range(rx, rx + rw):
            canvas.write_pixel(xx, yy, color)


def fill_rect_gradient(
    mut canvas: Canvas, x: Int, y: Int, width: Int, height: Int, gradient: LinearGradient
):
    """Fill a solid rectangle the same way fill_rect does, but
    sourcing each pixel's color from `gradient` (see gradient.mojo)
    instead of one flat Color. Same once-up-front clamp as fill_rect,
    for the same reason -- see that function's own docstring.
    """
    if width <= 0 or height <= 0:
        return

    var region = canvas.effective_fill_rect(x, y, width, height)
    var rx = region[0]
    var ry = region[1]
    var rw = region[2]
    var rh = region[3]
    for yy in range(ry, ry + rh):
        for xx in range(rx, rx + rw):
            canvas.write_pixel(xx, yy, gradient.color_at(Float64(xx), Float64(yy)))


def fill_rect_radial_gradient(
    mut canvas: Canvas, x: Int, y: Int, width: Int, height: Int, gradient: RadialGradient
):
    """Fill a solid rectangle the same way fill_rect does, but
    sourcing each pixel's color from `gradient` (a RadialGradient --
    see gradient.mojo) instead of one flat Color. A rectangle isn't
    the shape a radial gradient is usually reached for (a circle/ring
    is), but it's the same "concrete case that exists" reasoning as
    fill_rect_gradient: a rectangular legend swatch or background panel
    wanting a radial highlight doesn't need a circle primitive
    involved at all. Same once-up-front clamp as fill_rect, for the
    same reason -- see that function's own docstring.
    """
    if width <= 0 or height <= 0:
        return

    var region = canvas.effective_fill_rect(x, y, width, height)
    var rx = region[0]
    var ry = region[1]
    var rw = region[2]
    var rh = region[3]
    for yy in range(ry, ry + rh):
        for xx in range(rx, rx + rw):
            canvas.write_pixel(xx, yy, gradient.color_at(Float64(xx), Float64(yy)))


def draw_circle(mut canvas: Canvas, cx: Int, cy: Int, radius: Int, color: Color):
    """The midpoint circle algorithm -- integer-only, plots via 8-way
    symmetry around the center.

    At y==0 (the loop's first iteration) and x==y (wherever the loop
    crosses the diagonal), several of the 8 symmetric expressions
    collapse onto the same pixel -- e.g. (cx+y,cy+x) and (cx-y,cy+x)
    both become (cx,cy+x) when y==0. Plotting all 8 unconditionally
    would call set_pixel on that pixel more than once, double- (or
    quadruple-) blending a translucent color. Found by tracing through
    exactly this hazard while designing draw_ellipse's symmetry.
    """
    if radius <= 0:
        canvas.set_pixel(cx, cy, color)
        return

    var x = radius
    var y = 0
    var err = 1 - radius

    while x >= y:
        if y == 0:
            canvas.set_pixel(cx + x, cy, color)
            canvas.set_pixel(cx - x, cy, color)
            canvas.set_pixel(cx, cy + x, color)
            canvas.set_pixel(cx, cy - x, color)
        elif x == y:
            canvas.set_pixel(cx + x, cy + x, color)
            canvas.set_pixel(cx - x, cy + x, color)
            canvas.set_pixel(cx + x, cy - x, color)
            canvas.set_pixel(cx - x, cy - x, color)
        else:
            canvas.set_pixel(cx + x, cy + y, color)
            canvas.set_pixel(cx + y, cy + x, color)
            canvas.set_pixel(cx - y, cy + x, color)
            canvas.set_pixel(cx - x, cy + y, color)
            canvas.set_pixel(cx - x, cy - y, color)
            canvas.set_pixel(cx - y, cy - x, color)
            canvas.set_pixel(cx + y, cy - x, color)
            canvas.set_pixel(cx + x, cy - y, color)

        y += 1
        if err < 0:
            err += 2 * y + 1
        else:
            x -= 1
            err += 2 * (y - x) + 1


def fill_circle(mut canvas: Canvas, cx: Int, cy: Int, radius: Int, color: Color):
    """Fill a solid disk. One horizontal span per row -- each pixel is
    set exactly once, so a translucent color never gets double-blended
    (unlike a naive reuse of draw_circle's 8-way symmetry across rows,
    which touches some rows twice near the diagonal octant boundary).

    Hard-edged, like draw_circle -- see fill_circle_aa for a smooth
    edge.
    """
    if radius <= 0:
        canvas.set_pixel(cx, cy, color)
        return

    var r2 = radius * radius
    var dx = radius
    for dy in range(0, radius + 1):
        while dx * dx + dy * dy > r2:
            dx -= 1
        for xx in range(cx - dx, cx + dx + 1):
            canvas.set_pixel(xx, cy + dy, color)
            if dy != 0:
                canvas.set_pixel(xx, cy - dy, color)


def fill_circle_aa(
    mut canvas: Canvas,
    cx: Int,
    cy: Int,
    radius: Int,
    color: Color,
    supersample: Int = 4,
):
    """Anti-aliased filled disk.

    For every pixel near the circle, samples an NxN sub-pixel grid and
    tests each sub-sample analytically against the true (real-valued)
    disk -- no temp canvas or rendered supersampling involved, just a
    coverage fraction turned directly into that pixel's alpha. Each
    output pixel is visited exactly once, so there's no double-blend
    hazard the way there was with a naive fill via draw_circle's
    symmetry.

    Pixel (px, py) is treated as centered AT the point (px, py) --
    same convention the hard-edged draw_circle/fill_circle use for
    their integer distance test -- not as a unit square with (px, py)
    at its corner. That's what makes supersample=1 degenerate to
    exactly the same decision the hard-edged algorithms make, pixel
    for pixel, and what keeps this circle centered on the same point
    as draw_circle/fill_circle given identical (cx, cy, radius).

    Before sampling a pixel at all, checks whether its own square
    ([px-0.5, px+0.5] x [py-0.5, py+0.5], the same square every sample
    point above is drawn from) is *provably* entirely inside or
    entirely outside the disk, via the nearest/farthest point in that
    square from the center -- standard point-to-AABB min/max distance.
    Entirely outside means every one of the n*n samples would land
    outside regardless of n (coverage 0, already skipped exactly like
    this before); entirely inside means every sample would land inside
    regardless of n (coverage total_samples, i.e. the pixel's full
    alpha) -- both are the *same result* sampling would already reach,
    computed without actually visiting the n*n grid to reach it. This
    matters because most of a large circle's own bounding box is
    interior pixels, not boundary ones: the expensive per-sample loop
    now only ever runs for the O(radius) pixels actually straddling
    the edge, not all O(radius^2) of them.
    """
    if radius <= 0:
        canvas.set_pixel(cx, cy, color)
        return

    var r2 = Float64(radius * radius)
    var n = supersample
    var total_samples = n * n
    var step = 1.0 / Float64(n)

    for py in range(cy - radius - 1, cy + radius + 2):
        for px in range(cx - radius - 1, cx + radius + 2):
            var dx = abs(Float64(px - cx))
            var dy = abs(Float64(py - cy))

            var near_dx = max(0.0, dx - 0.5)
            var near_dy = max(0.0, dy - 0.5)
            if near_dx * near_dx + near_dy * near_dy > r2:
                continue  # whole pixel square is outside the disk

            var far_dx = dx + 0.5
            var far_dy = dy + 0.5
            if far_dx * far_dx + far_dy * far_dy <= r2:
                # Whole pixel square is inside the disk -- the exact
                # coverage/alpha every sample point would agree on.
                canvas.set_pixel(px, py, color)
                continue

            var covered = 0
            for sy in range(n):
                var fy = Float64(py - cy) + (Float64(sy) + 0.5) * step - 0.5
                for sx in range(n):
                    var fx = Float64(px - cx) + (Float64(sx) + 0.5) * step - 0.5
                    if fx * fx + fy * fy <= r2:
                        covered += 1
            if covered > 0:
                var alpha = UInt8(
                    Int(Float64(covered) / Float64(total_samples) * Float64(color.a) + 0.5)
                )
                canvas.set_pixel(px, py, Color(color.r, color.g, color.b, alpha))


def draw_circle_aa(
    mut canvas: Canvas,
    cx: Int,
    cy: Int,
    radius: Int,
    color: Color,
    supersample: Int = 4,
):
    """Anti-aliased circle outline, ~1px wide.

    Same supersampled analytic-coverage technique as fill_circle_aa
    (including the pixel-centered-at-(px,py) sampling convention that
    keeps this centered on the same point as draw_circle given
    identical cx, cy, radius), but tests each sub-sample against a
    thin ring (radius +/- 0.5) instead of the filled disk.
    """
    if radius <= 0:
        canvas.set_pixel(cx, cy, color)
        return

    var inner = Float64(radius) - 0.5
    var outer = Float64(radius) + 0.5
    var inner2 = inner * inner
    var outer2 = outer * outer
    var n = supersample
    var total_samples = n * n
    var step = 1.0 / Float64(n)

    for py in range(cy - radius - 1, cy + radius + 2):
        for px in range(cx - radius - 1, cx + radius + 2):
            var covered = 0
            for sy in range(n):
                var fy = Float64(py - cy) + (Float64(sy) + 0.5) * step - 0.5
                for sx in range(n):
                    var fx = Float64(px - cx) + (Float64(sx) + 0.5) * step - 0.5
                    var d2 = fx * fx + fy * fy
                    if d2 >= inner2 and d2 < outer2:
                        covered += 1
            if covered > 0:
                var alpha = UInt8(
                    Int(Float64(covered) / Float64(total_samples) * Float64(color.a) + 0.5)
                )
                canvas.set_pixel(px, py, Color(color.r, color.g, color.b, alpha))


def _plot_ellipse_points(mut canvas: Canvas, cx: Int, cy: Int, x: Int, y: Int, color: Color):
    """Plot draw_ellipse's 4-way symmetric points at offset (x, y),
    guarding the two cases where mirrored points collapse onto the
    same pixel: x==0 (top/bottom, where left and right mirrors
    coincide) and y==0 (left/right, where top and bottom mirrors
    coincide). Both are real, reachable cases here -- unlike
    draw_circle's loop, which starts at x==radius and never returns
    to x==0, draw_ellipse's region 1 *starts* at x==0, and region 2
    ends at y==0. Without this guard a translucent color would get
    blended twice at all 4 of the ellipse's axis extremes -- the same
    category of bug draw_circle had at its own degenerate points.
    """
    if x == 0 and y == 0:
        canvas.set_pixel(cx, cy, color)
    elif x == 0:
        canvas.set_pixel(cx, cy + y, color)
        canvas.set_pixel(cx, cy - y, color)
    elif y == 0:
        canvas.set_pixel(cx + x, cy, color)
        canvas.set_pixel(cx - x, cy, color)
    else:
        canvas.set_pixel(cx + x, cy + y, color)
        canvas.set_pixel(cx - x, cy + y, color)
        canvas.set_pixel(cx + x, cy - y, color)
        canvas.set_pixel(cx - x, cy - y, color)


def draw_ellipse(mut canvas: Canvas, cx: Int, cy: Int, rx: Int, ry: Int, color: Color):
    """The midpoint ellipse algorithm -- draw_circle's generalization
    to independent x/y radii.

    Two regions, split where the boundary's slope magnitude crosses 1
    (region 1: shallow, steps x; region 2: steep, steps y), each with
    its own decision parameter -- unlike the circle, unequal radii
    mean there's no single symmetric stepping rule that covers the
    whole curve. 4-way symmetry, not the circle's 8-way: swapping x
    and y doesn't preserve the ellipse equation unless rx == ry.

    Integer-only: the decision parameters are scaled by 4 throughout
    to absorb the 0.25 fractional term the derivation produces
    (evaluating the ellipse equation at a half-pixel-offset midpoint),
    the same way circle/line algorithms stay in Int by construction
    rather than rounding floats.
    """
    if rx <= 0 or ry <= 0:
        canvas.set_pixel(cx, cy, color)
        return

    var rx2 = rx * rx
    var ry2 = ry * ry

    var x = 0
    var y = ry

    # Region 1: shallow slope, step x.
    var q1 = 4 * ry2 - 4 * rx2 * ry + rx2
    while 2 * ry2 * x <= 2 * rx2 * y:
        _plot_ellipse_points(canvas, cx, cy, x, y, color)
        x += 1
        if q1 < 0:
            q1 += 8 * ry2 * x + 4 * ry2
        else:
            y -= 1
            q1 += 8 * ry2 * x - 8 * rx2 * y + 4 * ry2

    # Region 2: steep slope, step y. Decision parameter is
    # re-evaluated fresh at the (x, y) region 1 left off at, not
    # carried over incrementally -- it's a different function of x, y.
    var q2 = (
        4 * ry2 * (x * x)
        + 4 * ry2 * x
        + ry2
        + 4 * rx2 * (y - 1) * (y - 1)
        - 4 * rx2 * ry2
    )
    while y >= 0:
        _plot_ellipse_points(canvas, cx, cy, x, y, color)
        y -= 1
        if q2 > 0:
            q2 += -8 * rx2 * y + 4 * rx2
        else:
            x += 1
            q2 += 8 * ry2 * x - 8 * rx2 * y + 4 * rx2


def fill_ellipse(mut canvas: Canvas, cx: Int, cy: Int, rx: Int, ry: Int, color: Color):
    """Fill a solid ellipse -- fill_circle's generalization to
    independent x/y radii, same span-fill-per-row technique (each
    pixel set exactly once, so a translucent color is never double-
    blended). The half-width per row shrinks monotonically as |dy|
    grows from 0 to ry, so `dx` only ever needs to decrease, never
    reset -- same trick fill_circle uses. The per-row bound is the
    ellipse equation multiplied through by rx^2 * ry^2 to stay
    integer-exact rather than involve a sqrt: `dx^2*ry^2 + dy^2*rx^2
    <= rx^2*ry^2`.

    Hard-edged, like draw_ellipse -- see fill_ellipse_aa for a smooth
    edge.
    """
    if rx <= 0 or ry <= 0:
        canvas.set_pixel(cx, cy, color)
        return

    var rx2 = rx * rx
    var ry2 = ry * ry
    var bound = rx2 * ry2
    var dx = rx
    for dy in range(0, ry + 1):
        while dx * dx * ry2 + dy * dy * rx2 > bound:
            dx -= 1
        for xx in range(cx - dx, cx + dx + 1):
            canvas.set_pixel(xx, cy + dy, color)
            if dy != 0:
                canvas.set_pixel(xx, cy - dy, color)


def fill_ellipse_aa(
    mut canvas: Canvas,
    cx: Int,
    cy: Int,
    rx: Int,
    ry: Int,
    color: Color,
    supersample: Int = 4,
):
    """Anti-aliased filled ellipse -- fill_circle_aa's generalization
    to independent x/y radii, same per-pixel supersampled analytic
    coverage technique (each output pixel visited exactly once, no
    double-blend hazard).

    Generalized by normalizing each sample's offset by (rx, ry) before
    testing against the unit circle: `(dx/rx)^2 + (dy/ry)^2 <= 1` is
    the ellipse equation in normalized form, exactly equivalent to
    testing against the true ellipse boundary -- and reduces to
    fill_circle_aa's own `dx^2 + dy^2 <= r^2` test when rx == ry
    (dividing both terms by the same r first).

    Same provably-inside/provably-outside fast path fill_circle_aa's
    own docstring describes -- here in the identical normalized (rx,
    ry) space the sample test itself uses, so a pixel square's nearest
    and farthest normalized corners are just its raw nearest/farthest
    corners (the same 0.5-away-from-center AABB fill_circle_aa
    computes) each divided by rx/ry before squaring.
    """
    if rx <= 0 or ry <= 0:
        canvas.set_pixel(cx, cy, color)
        return

    var rx_f = Float64(rx)
    var ry_f = Float64(ry)
    var n = supersample
    var total_samples = n * n
    var step = 1.0 / Float64(n)

    for py in range(cy - ry - 1, cy + ry + 2):
        for px in range(cx - rx - 1, cx + rx + 2):
            var dx = abs(Float64(px - cx))
            var dy = abs(Float64(py - cy))

            var near_nx = max(0.0, dx - 0.5) / rx_f
            var near_ny = max(0.0, dy - 0.5) / ry_f
            if near_nx * near_nx + near_ny * near_ny > 1.0:
                continue  # whole pixel square is outside the ellipse

            var far_nx = (dx + 0.5) / rx_f
            var far_ny = (dy + 0.5) / ry_f
            if far_nx * far_nx + far_ny * far_ny <= 1.0:
                canvas.set_pixel(px, py, color)  # whole pixel square is inside
                continue

            var covered = 0
            for sy in range(n):
                var fy = Float64(py - cy) + (Float64(sy) + 0.5) * step - 0.5
                for sx in range(n):
                    var fx = Float64(px - cx) + (Float64(sx) + 0.5) * step - 0.5
                    var nx = fx / rx_f
                    var ny = fy / ry_f
                    if nx * nx + ny * ny <= 1.0:
                        covered += 1
            if covered > 0:
                var alpha = UInt8(
                    Int(Float64(covered) / Float64(total_samples) * Float64(color.a) + 0.5)
                )
                canvas.set_pixel(px, py, Color(color.r, color.g, color.b, alpha))


def draw_ellipse_aa(
    mut canvas: Canvas,
    cx: Int,
    cy: Int,
    rx: Int,
    ry: Int,
    color: Color,
    supersample: Int = 4,
):
    """Anti-aliased ellipse outline, ~1px wide -- draw_circle_aa's
    generalization to independent x/y radii.

    Unlike the circle case, there's no single distance value an inner
    and outer boundary can both be compared against: draw_circle_aa
    tests one `d2` against `inner2`/`outer2` because a circle's inner
    and outer rings are concentric offsets of the *same* curve, but an
    ellipse's `(rx-0.5, ry-0.5)` and `(rx+0.5, ry+0.5)` rings are two
    genuinely different ellipses. So this tests each sample against
    both independently, in their own normalized space -- strictly
    inside the outer ellipse and not strictly inside the inner one:

        (dx/outer_rx)^2 + (dy/outer_ry)^2 <  1   (strictly inside outer)
        (dx/inner_rx)^2 + (dy/inner_ry)^2 >= 1   (on or outside inner)

    the same half-open intent as draw_circle_aa's `d2 >= inner2 and d2
    < outer2`, just as two independent tests since a shared distance
    doesn't exist here. `rx, ry >= 1` by the time this runs (`rx <= 0
    or ry <= 0` is handled above), so `inner_rx`/`inner_ry` are always
    positive -- no degenerate-inner-ellipse case to guard, same as
    draw_circle_aa never needing one either.

    Known, accepted imprecision: applying +/-0.5 to rx and ry
    independently, rather than offsetting along the ellipse's true
    normal direction, means the resulting ring's actual physical width
    varies slightly around the ellipse (exactly 1px at the four axis
    extremes, narrower elsewhere) instead of being uniformly 1px like
    the circle's ring. Good enough for a ~1px hairline outline; a
    normal-offset ring would need the ellipse's actual perimeter
    parameterization, unjustified complexity for what this is for.
    """
    if rx <= 0 or ry <= 0:
        canvas.set_pixel(cx, cy, color)
        return

    var outer_rx = Float64(rx) + 0.5
    var outer_ry = Float64(ry) + 0.5
    var inner_rx = Float64(rx) - 0.5
    var inner_ry = Float64(ry) - 0.5
    var n = supersample
    var total_samples = n * n
    var step = 1.0 / Float64(n)

    for py in range(cy - ry - 1, cy + ry + 2):
        for px in range(cx - rx - 1, cx + rx + 2):
            var covered = 0
            for sy in range(n):
                var fy = Float64(py - cy) + (Float64(sy) + 0.5) * step - 0.5
                for sx in range(n):
                    var fx = Float64(px - cx) + (Float64(sx) + 0.5) * step - 0.5
                    var onx = fx / outer_rx
                    var ony = fy / outer_ry
                    var inx = fx / inner_rx
                    var iny = fy / inner_ry
                    var inside_outer = onx * onx + ony * ony < 1.0
                    var inside_inner = inx * inx + iny * iny < 1.0
                    if inside_outer and not inside_inner:
                        covered += 1
            if covered > 0:
                var alpha = UInt8(
                    Int(Float64(covered) / Float64(total_samples) * Float64(color.a) + 0.5)
                )
                canvas.set_pixel(px, py, Color(color.r, color.g, color.b, alpha))


comptime _TWO_PI = 6.283185307179586
comptime _HALF_PI = 1.5707963267948966
comptime _PI = 3.141592653589793
comptime _THREE_HALF_PI = 4.71238898038469


def _extend_bounds(
    mut min_x: Float64, mut min_y: Float64, mut max_x: Float64, mut max_y: Float64, x: Float64, y: Float64
):
    if x < min_x:
        min_x = x
    if x > max_x:
        max_x = x
    if y < min_y:
        min_y = y
    if y > max_y:
        max_y = y


def _arc_bounds(
    cx: Float64,
    cy: Float64,
    radius: Float64,
    start_angle: Float64,
    end_angle: Float64,
    include_center: Bool,
) -> Tuple[Float64, Float64, Float64, Float64]:
    """The tight axis-aligned bounding box (min_x, min_y, max_x, max_y)
    the arc/wedge (cx, cy, radius, start_angle, end_angle) actually
    occupies -- used by fill_arc_aa/fill_ring_sector_aa (below) to
    shrink their own pixel-scan range down from the full circumscribing
    square (a large overestimate for anything short of a near-full
    circle -- a thin 10-degree pie slice's true extent is a small
    sliver of that square) to the shape's real footprint, with no
    change to which pixels end up covered: every pixel this excludes is
    one the existing per-pixel angle/radius tests would already have
    found zero coverage in, derived here from the shape's own math
    instead of sampled per pixel to discover the same thing.

    Rigorous, not a heuristic: a circular arc's x and y coordinates are
    each monotonic in angle *between* the four cardinal angles (0,
    pi/2, pi, 3*pi/2 -- where cos/sin's own derivative is zero), the
    only points where either coordinate can reach a local extreme.
    So the arc's own bounds are exactly the bounds of its two endpoints
    plus whichever cardinal-angle points actually fall inside
    [start_angle, end_angle].

    `include_center` covers the one difference between the two
    callers: fill_arc_aa's wedge is bounded by two straight radii back
    to (cx, cy), so the center itself can be the shape's own leftmost/
    rightmost/etc. point (e.g. a thin slice near angle 0, whose two arc
    endpoints are both near x = cx + radius, but whose straight edges
    still reach back to x = cx). fill_ring_sector_aa's ring has no
    center point in it at all (inner_radius > 0 there), and its inner
    arc's own bounds are always a subset of the outer arc's (identical
    angles, strictly smaller radius) -- so bounding via `radius` alone
    (the outer one, from that caller) already covers the whole ring.
    """
    var start_x = cx + radius * cos(start_angle)
    var start_y = cy + radius * sin(start_angle)
    var min_x = start_x
    var max_x = start_x
    var min_y = start_y
    var max_y = start_y
    if include_center:
        _extend_bounds(min_x, min_y, max_x, max_y, cx, cy)

    var end_x = cx + radius * cos(end_angle)
    var end_y = cy + radius * sin(end_angle)
    _extend_bounds(min_x, min_y, max_x, max_y, end_x, end_y)

    if _angle_in_span(0.0, start_angle, end_angle):
        _extend_bounds(min_x, min_y, max_x, max_y, cx + radius, cy)
    if _angle_in_span(_HALF_PI, start_angle, end_angle):
        _extend_bounds(min_x, min_y, max_x, max_y, cx, cy + radius)
    if _angle_in_span(_PI, start_angle, end_angle):
        _extend_bounds(min_x, min_y, max_x, max_y, cx - radius, cy)
    if _angle_in_span(_THREE_HALF_PI, start_angle, end_angle):
        _extend_bounds(min_x, min_y, max_x, max_y, cx, cy - radius)

    return (min_x, min_y, max_x, max_y)


def _arc_points(cx: Float64, cy: Float64, radius: Float64, start_angle: Float64, end_angle: Float64) -> List[Point]:
    """Sample points along a circular arc (radians, start_angle <=
    end_angle expected -- pass end_angle = start_angle + 2*pi for a
    full circle) at roughly 1-pixel arc-length spacing: step count is
    proportional to radius * angle span, so a tiny pie-chart wedge and
    a huge full-page donut both get smooth, gap-free sampling, unlike
    a fixed step count (Path's own choice for curve flattening, see
    path.mojo) that would facet a large arc or waste work on a tiny
    one -- arc radii vary far more widely in practice than a Path's
    typical curve size does.

    Exact circle math (cx + r*cos(theta), cy + r*sin(theta)) sampled
    directly, not a cubic-Bezier approximation -- matches draw_circle/
    draw_ellipse's own independently-derived exact math over an
    approximation, and avoids needing to separately justify a curve-
    fitting error bound the way a Bezier arc approximation would.
    """
    var span = end_angle - start_angle
    var steps = max(4, Int(radius * abs(span)))
    var points = List[Point](capacity=steps + 1)
    for i in range(steps + 1):
        var t = Float64(i) / Float64(steps)
        var angle = start_angle + t * span
        var x = cx + radius * cos(angle)
        var y = cy + radius * sin(angle)
        points.append(Point(_round_to_int(x), _round_to_int(y)))
    return points^


def _angle_in_span(angle: Float64, start_angle: Float64, end_angle: Float64) -> Bool:
    """Is `angle` within [start_angle, end_angle] once normalized into
    the same 2*pi-wide window starting at start_angle? atan2's own
    range is (-pi, pi], which won't line up with an arbitrary
    start_angle/end_angle pair on its own -- e.g. a wedge spanning the
    atan2 discontinuity at +/-pi needs a sample's raw angle shifted by
    a full turn before the plain <= / >= comparison means anything.
    """
    var a = angle
    while a < start_angle:
        a += _TWO_PI
    while a >= start_angle + _TWO_PI:
        a -= _TWO_PI
    return a <= end_angle


def draw_arc(mut canvas: Canvas, cx: Float64, cy: Float64, radius: Float64, start_angle: Float64, end_angle: Float64, color: Color):
    """The arc's own curved boundary only (no radii back to center) --
    hard-edged, ~1px, via draw_polyline over exact-math sampled points
    (see _arc_points). For a solid pie-slice wedge instead, see
    fill_arc; for a ring/donut segment, see fill_ring_sector.
    """
    if radius <= 0.0:
        canvas.set_pixel(_round_to_int(cx), _round_to_int(cy), color)
        return
    var points = _arc_points(cx, cy, radius, start_angle, end_angle)
    draw_polyline(canvas, points, color)


def draw_arc_aa(
    mut canvas: Canvas,
    cx: Float64,
    cy: Float64,
    radius: Float64,
    start_angle: Float64,
    end_angle: Float64,
    color: Color,
    width: Float64 = 1.0,
    supersample: Int = 4,
):
    """Anti-aliased version of draw_arc -- see draw_polyline_aa."""
    if radius <= 0.0:
        canvas.set_pixel(_round_to_int(cx), _round_to_int(cy), color)
        return
    var points = _arc_points(cx, cy, radius, start_angle, end_angle)
    draw_polyline_aa(canvas, points, color, width, supersample)


def fill_arc(mut canvas: Canvas, cx: Float64, cy: Float64, radius: Float64, start_angle: Float64, end_angle: Float64, color: Color):
    """A solid pie-slice wedge: the arc plus two straight radii back
    to the center, filled -- what a pie chart's own slice needs.
    Built by sampling the arc (see _arc_points), appending the center
    point to close the wedge shape, and handing the result to
    fill_polygon -- the same "sample a curve into a polygon, reuse
    already-tested fill machinery" approach path.mojo uses for
    Bezier curves.
    """
    if radius <= 0.0:
        return
    var points = _arc_points(cx, cy, radius, start_angle, end_angle)
    points.append(Point(_round_to_int(cx), _round_to_int(cy)))
    fill_polygon(canvas, points, color)


def fill_arc_aa(
    mut canvas: Canvas,
    cx: Float64,
    cy: Float64,
    radius: Float64,
    start_angle: Float64,
    end_angle: Float64,
    color: Color,
    supersample: Int = 4,
):
    """Anti-aliased pie-slice wedge -- supersampled analytic coverage,
    testing each sub-sample against the wedge's exact definition
    (within `radius` of center AND within the angle span), the same
    technique fill_circle_aa uses for a plain disk, generalized with
    an angular membership test (_angle_in_span). Not built by
    rasterizing a flattened polygon through a generic AA fill -- no
    such thing exists in this codebase (fill_polygon is hard-edged
    only; draw_polygon_aa is an AA *outline*, not a fill) -- and a
    wedge's membership test is clean enough analytically that
    inventing one wasn't needed here.

    Scans only `_arc_bounds`' own tight bounding box (expanded by 1px
    for the AA sampling margin at its own edge), not the full
    circumscribing square of `radius` -- see that function's own
    docstring. This is the dominant cost for anything but a near-full
    pie: a thin slice's true footprint can be a small fraction of its
    own circumscribing circle's bounding square, and every pixel
    outside that footprint would have scored zero coverage anyway.
    """
    if radius <= 0.0:
        return

    var r2 = radius * radius
    var n = supersample
    var total_samples = n * n
    var step = 1.0 / Float64(n)

    var bounds = _arc_bounds(cx, cy, radius, start_angle, end_angle, True)
    var min_px = _round_to_int(bounds[0]) - 1
    var max_px = _round_to_int(bounds[2]) + 1
    var min_py = _round_to_int(bounds[1]) - 1
    var max_py = _round_to_int(bounds[3]) + 1

    for py in range(min_py, max_py + 1):
        for px in range(min_px, max_px + 1):
            # A wedge's angular boundary makes a rigorous "whole pixel
            # square is provably *inside*" test fiddly (angle
            # wraparound, a pixel straddling the center where angle is
            # undefined) -- not attempted here. But "provably *outside*
            # the radius entirely, regardless of angle" is cheap and
            # unconditionally valid (same AABB-vs-circle nearest-point
            # test as fill_circle_aa's own fast path): most of this
            # wedge's own square bounding box is actually outside its
            # circumscribing circle already for anything but a full
            # pie, so this alone skips a real fraction of the box
            # without needing the angle math at all.
            var dx = abs(Float64(px) - cx)
            var dy = abs(Float64(py) - cy)
            var near_dx = max(0.0, dx - 0.5)
            var near_dy = max(0.0, dy - 0.5)
            if near_dx * near_dx + near_dy * near_dy > r2:
                continue

            var covered = 0
            for sy in range(n):
                var fy = Float64(py) - cy + (Float64(sy) + 0.5) * step - 0.5
                for sx in range(n):
                    var fx = Float64(px) - cx + (Float64(sx) + 0.5) * step - 0.5
                    if fx * fx + fy * fy <= r2:
                        var angle = atan2(fy, fx)
                        if _angle_in_span(angle, start_angle, end_angle):
                            covered += 1
            if covered > 0:
                var alpha = UInt8(
                    Int(Float64(covered) / Float64(total_samples) * Float64(color.a) + 0.5)
                )
                canvas.set_pixel(px, py, Color(color.r, color.g, color.b, alpha))


def fill_ring_sector(
    mut canvas: Canvas,
    cx: Float64,
    cy: Float64,
    inner_radius: Float64,
    outer_radius: Float64,
    start_angle: Float64,
    end_angle: Float64,
    color: Color,
):
    """A solid ring/donut segment: the region between inner_radius and
    outer_radius, within the given angle span -- what a donut chart's
    own segment needs. Built the same way fill_arc is: sample the
    outer arc forward and the inner arc backward (so the combined
    point sequence traces the ring's boundary in one continuous loop,
    not two disconnected arcs) into one polygon, then fill_polygon.
    """
    if outer_radius <= 0.0 or inner_radius < 0.0 or inner_radius >= outer_radius:
        return
    var points = _arc_points(cx, cy, outer_radius, start_angle, end_angle)
    var inner_points = _arc_points(cx, cy, inner_radius, end_angle, start_angle)
    for p in inner_points:
        points.append(p)
    fill_polygon(canvas, points, color)


def fill_ring_sector_aa(
    mut canvas: Canvas,
    cx: Float64,
    cy: Float64,
    inner_radius: Float64,
    outer_radius: Float64,
    start_angle: Float64,
    end_angle: Float64,
    color: Color,
    supersample: Int = 4,
):
    """Anti-aliased version of fill_ring_sector -- same analytic
    per-sample technique as fill_arc_aa, with a second radius test
    (see draw_ellipse_aa's own inner/outer ring test for the closest
    precedent: a fixed-width ring rather than an angular wedge, but
    the same "two independent boundary tests, both must pass" shape).

    Scans only `_arc_bounds`' own tight bounding box (via outer_radius,
    no center point -- see that function's own docstring for why the
    outer arc's bounds already cover the whole ring), the same
    dominant fix fill_arc_aa's own docstring explains.
    """
    if outer_radius <= 0.0 or inner_radius < 0.0 or inner_radius >= outer_radius:
        return

    var outer_r2 = outer_radius * outer_radius
    var inner_r2 = inner_radius * inner_radius
    var n = supersample
    var total_samples = n * n
    var step = 1.0 / Float64(n)

    var bounds = _arc_bounds(cx, cy, outer_radius, start_angle, end_angle, False)
    var min_px = _round_to_int(bounds[0]) - 1
    var max_px = _round_to_int(bounds[2]) + 1
    var min_py = _round_to_int(bounds[1]) - 1
    var max_py = _round_to_int(bounds[3]) + 1

    for py in range(min_py, max_py + 1):
        for px in range(min_px, max_px + 1):
            # Same radius-only (angle-independent) fast-outside skip
            # fill_arc_aa's own docstring explains -- valid here too,
            # for both the outer edge (pixel square entirely beyond
            # outer_radius) and the inner hole (pixel square's
            # farthest point from center still inside inner_radius,
            # so even the *closest-to-the-ring* corner never reaches
            # it).
            var dx = abs(Float64(px) - cx)
            var dy = abs(Float64(py) - cy)
            var near_dx = max(0.0, dx - 0.5)
            var near_dy = max(0.0, dy - 0.5)
            if near_dx * near_dx + near_dy * near_dy > outer_r2:
                continue
            var far_dx = dx + 0.5
            var far_dy = dy + 0.5
            if far_dx * far_dx + far_dy * far_dy < inner_r2:
                continue

            var covered = 0
            for sy in range(n):
                var fy = Float64(py) - cy + (Float64(sy) + 0.5) * step - 0.5
                for sx in range(n):
                    var fx = Float64(px) - cx + (Float64(sx) + 0.5) * step - 0.5
                    var d2 = fx * fx + fy * fy
                    if d2 <= outer_r2 and d2 >= inner_r2:
                        var angle = atan2(fy, fx)
                        if _angle_in_span(angle, start_angle, end_angle):
                            covered += 1
            if covered > 0:
                var alpha = UInt8(
                    Int(Float64(covered) / Float64(total_samples) * Float64(color.a) + 0.5)
                )
                canvas.set_pixel(px, py, Color(color.r, color.g, color.b, alpha))
