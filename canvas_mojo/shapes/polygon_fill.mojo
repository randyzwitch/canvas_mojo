"""A polygon's *interior* fill: the scanline/winding-number machinery
(`_Crossing`, `_Span`, `_is_inside`, `_spans_from_crossings`), its two
consumers here (`fill_polygon`, `fill_polygon_aa`), and
`_point_in_polygon`/`_polygon_row_crossings_aa`, the real-valued
membership tests `fill_polygon_aa`'s supersampling needs.

Not `draw_polygon`/`draw_polygon_aa` in canvas_mojo.shapes.lines, which
stroke a polygon's *outline* through a different algorithm entirely.

path.mojo imports `_Crossing`/`_spans_from_crossings`/`_is_inside` for
fill_path/fill_path_aa: the two fills differ in how they collect a
row's crossings, not in how those crossings become spans.
"""

from std.math import ceil

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas
from canvas_mojo.geometry import Point
from canvas_mojo.fill_rule import FillRule
from canvas_mojo.aa_crossing import (
    _AACrossing,
    _EdgeTable,
    _sample_x,
    _sort_aa_crossings_by_x,
)


struct _Crossing(ImplicitlyCopyable, Movable):
    """One scanline crossing: where an edge crosses row y, and which
    way it goes (+1 stepping from lower y to higher, -1 the other way).
    Nonzero winding needs the sign; even-odd needs only the count, but
    a signed +/-1 flips parity once per crossing either way, so one
    representation serves both rules (see _is_inside).
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


def _spans_from_crossings(
    mut crossings: List[_Crossing], fill_rule: FillRule
) -> List[_Span]:
    """Given one row's crossings (unsorted, x position + direction),
    sort by x and scan left to right accumulating a signed winding
    number, returning the resulting filled spans under `fill_rule`.

    Shared by fill_polygon and fill_path (and their gradient variants,
    see path.mojo) -- they differ only in how they collect a row's
    crossings (one polygon's edges vs. every sub-path's edges
    combined) and what they do with each resulting span (set_pixel one
    flat color, or query a gradient per pixel), not in this scan.

    Under EVEN_ODD this gives byte-identical spans to plain
    sort-and-pair (1st-2nd, 3rd-4th, ...) for any non-self-intersecting
    polygon: winding parity flips once per crossing regardless of sign,
    which is what alternating in/out pairing assumes.

    One step beyond the plain winding scan: adjacent spans merge
    wherever one's end_x touches or overlaps the next one's start_x.
    In a self-intersecting shape, two unrelated edges can cross one
    scanline at the same rounded x, dipping winding to "outside" and
    straight back to "inside" there. Unmerged, that yields two spans
    both including that x -- correct under the inclusive X-fill
    convention, but a double blend for a translucent color.
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
    mut canvas: Canvas,
    points: List[Point],
    color: Color,
    fill_rule: FillRule = FillRule.EVEN_ODD,
):
    """Fill a polygon's interior with the scanline algorithm.

    For each row, find where every edge crosses it and accumulate a
    signed winding number left to right (see _spans_from_crossings).
    `fill_rule` (EVEN_ODD by default) decides which regions count as
    inside -- see fill_rule.mojo.

    Y-extent per edge uses the half-open [min(y0,y1), max(y0,y1))
    convention, which correctness depends on: without it a vertex
    shared by two edges running in opposite y-directions counts as a
    crossing twice, while a local extremum such as a triangle's apex
    must contribute zero net crossings rather than two. This is the
    same rule real rasterizers use (OpenGL/DirectX's "top-left fill
    rule"), so adjacent shapes sharing an edge tile without a gap or a
    double-covered seam.

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

    A self-intersecting polygon is fully supported: under either fill
    rule every pixel gets exactly one set_pixel call per row, including
    at the intersection itself -- see _spans_from_crossings on the
    span-merge step that guarantees it.
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


def _point_in_polygon(
    points: List[Point], fx: Float64, fy: Float64, fill_rule: FillRule
) -> Bool:
    """fill_polygon's winding-number membership test generalized from
    an integer scanline to one arbitrary real-valued point, which is
    what fill_polygon_aa's supersampling needs.

    A horizontal ray from (fx, fy) in the +x direction: every edge
    crossing y=fy at an x strictly greater than fx contributes its
    signed direction to a running winding number, under the same
    half-open Y-extent convention and for the same reason.
    `_is_inside(winding, fill_rule)` decides membership -- the function
    fill_polygon's spans use, so hard-edged and AA fills agree exactly
    on where a boundary is.
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


def _polygon_row_crossings_aa(
    points: List[Point], fy: Float64
) -> List[_AACrossing]:
    """_point_in_polygon's per-sample ray-cast, hoisted to run once per
    sub-scanline -- the technique path.mojo's fill_path_aa uses, and
    what keeps fill_polygon_aa's sweep sub-quadratic.
    """
    var crossings = List[_AACrossing]()
    _polygon_row_crossings_aa_into(points, fy, crossings)
    return crossings^


def _polygon_row_crossings_aa_into(
    points: List[Point], fy: Float64, mut crossings: List[_AACrossing]
) -> None:
    """`_polygon_row_crossings_aa` writing into a caller-owned list,
    so the sweep allocates once rather than once per sub-scanline --
    see `fill_path_aa` (path.mojo), which this mirrors.
    """
    crossings.clear()

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

    Distinct from `draw_polygon_aa`, which is an AA *outline*.

    Same pixel-centered-at-its-integer-coordinate convention as every
    other AA primitive here, and the same `fill_rule` fill_polygon
    takes, sharing `_is_inside` so the two agree on the boundary.

    Swept per sub-scanline (_polygon_row_crossings_aa) rather than per
    sub-pixel sample: see fill_path_aa for the complexity argument.
    `_point_in_polygon` remains the reference implementation this
    sweep's output must match pixel for pixel.

    Not fused with fill_polygon behind an `antialias: Bool`, for the
    reason canvas_mojo.shapes.lines gives.
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

    # Allocated once for the whole sweep rather than per row and per
    # sub-scanline -- see fill_path_aa (path.mojo) for the measurement
    # that motivated it.
    var row_covered = List[Int](capacity=row_width)
    for _ in range(row_width):
        row_covered.append(0)
    var crossings = List[_AACrossing]()
    var suffix = List[Int]()
    var edges = _EdgeTable()
    var pn = len(points)
    for i in range(pn):
        var a = points[i]
        var b = points[(i + 1) % pn]
        edges.add_edge(Float64(a.x), Float64(a.y), Float64(b.x), Float64(b.y))

    for py in range(min_y - 1, max_y + 2):
        for pxi in range(row_width):
            row_covered[pxi] = 0

        for sy in range(s):
            var fy = Float64(py) + (Float64(sy) + 0.5) * step - 0.5
            edges.crossings_at(fy, crossings)
            _sort_aa_crossings_by_x(crossings)
            var k = len(crossings)

            while len(suffix) < k + 1:
                suffix.append(0)
            suffix[k] = 0
            for i in range(k - 1, -1, -1):
                suffix[i] = suffix[i + 1] + crossings[i].direction

            # Counted by interval rather than tested per sample --
            # see fill_path_aa (path.mojo), which this mirrors, for
            # why the counts are identical either way.
            var total_g = row_width * s
            var x0 = Float64(row_first_px) - 0.5
            for i in range(k + 1):
                if not _is_inside(suffix[i], fill_rule):
                    continue

                var g_start = 0
                if i > 0:
                    var lo = crossings[i - 1].x
                    g_start = Int(ceil((lo - x0) * Float64(s) - 0.5))
                    while g_start > 0 and _sample_x(x0, g_start - 1, s) >= lo:
                        g_start -= 1
                    while g_start < total_g and _sample_x(x0, g_start, s) < lo:
                        g_start += 1
                    if g_start < 0:
                        g_start = 0

                var g_end = total_g - 1
                if i < k:
                    var hi = crossings[i].x
                    g_end = Int(ceil((hi - x0) * Float64(s) - 0.5)) - 1
                    while g_end >= 0 and _sample_x(x0, g_end, s) >= hi:
                        g_end -= 1
                    while (
                        g_end + 1 < total_g and _sample_x(x0, g_end + 1, s) < hi
                    ):
                        g_end += 1
                    if g_end > total_g - 1:
                        g_end = total_g - 1

                var g = g_start
                while g <= g_end:
                    var pxi = g // s
                    var upper = (pxi + 1) * s - 1
                    if g_end < upper:
                        upper = g_end
                    row_covered[pxi] += upper - g + 1
                    g = upper + 1

        for pxi in range(row_width):
            var covered = row_covered[pxi]
            if covered > 0:
                var px = row_first_px + pxi
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
