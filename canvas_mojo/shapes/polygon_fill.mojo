"""A polygon's *interior* fill -- the scanline/winding-number
machinery (`_Crossing`, `_Span`, `_is_inside`, `_spans_from_crossings`)
and its two consumers here (`fill_polygon`, `fill_polygon_aa`), plus
`_point_in_polygon`/`_polygon_row_crossings_aa`, the real-valued
membership tests `fill_polygon_aa`'s own supersampling needs.

Not to be confused with `draw_polygon`/`draw_polygon_aa` in
canvas_mojo.shapes.lines, which stroke a polygon's *outline* via an
entirely different (Bresenham/supersampled-line) algorithm -- two
genuinely different operations that happen to share half a name; see
that module's own docstring for why they're kept in separate files.

`_Crossing`/`_spans_from_crossings`/`_is_inside` are also imported
directly by path.mojo (see that module's own import list) -- shared
with fill_path/fill_path_aa's own scanline fill there, since the two
differ only in how they collect a row's crossings, not in how a row of
crossings becomes filled spans; see _spans_from_crossings's own
docstring.
"""

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas
from canvas_mojo.geometry import Point
from canvas_mojo.fill_rule import FillRule
from canvas_mojo.aa_crossing import _AACrossing, _sort_aa_crossings_by_x


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

    A self-intersecting polygon is fully supported -- under either
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

    The AA companion to `fill_polygon` itself, the way every other
    filled primitive here (circle/ellipse/arc/ring) has one -- an
    arbitrary filled shape, the general case an area chart's region or
    a custom marker boundary actually is, renders with smooth edges
    rather than only hard-edged. Distinct from `draw_polygon_aa`,
    which is an AA *outline*, not a fill.

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
    canvas_mojo.shapes.lines's own module docstring for why that split
    is kept visible everywhere else (a real complexity-class jump per
    pixel), the same reasoning applies here.
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
