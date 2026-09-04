"""A polygon's *interior* fill: the scanline/winding-number machinery
(`_Crossing`, `_Span`, `_spans_from_crossings`), its two consumers
here (`fill_polygon`, `fill_polygon_aa`), and `_point_in_polygon`, the
real-valued membership test the anti-aliased sweep is checked against.

The *outline* strokes, `draw_polygon`/`draw_polygon_aa`, are a
different algorithm in canvas.shapes.lines.

`fill_polygon_aa` describes its geometry as an `_EdgeTable` and hands it
to `canvas.aa_crossing`'s `_sweep_edges_aa`, shared with `fill_path_aa`.
path.mojo imports `_Crossing`/`_spans_from_crossings` for its own
hard-edged fills. In both cases the callers differ in how they collect
edges or crossings, not in what happens after. `_is_inside` lives in
`canvas.fill_rule`, which both can see.
"""

from std.math import ceil, floor

from canvas.color import Color
from canvas.buffer import Canvas
from canvas.geometry import (
    Point,
    FPoint,
    _mapped_fpoints,
    _mapped_points,
    _mapped_points_to_fpoints,
)
from canvas.fill_rule import FillRule, _is_inside
from canvas.aa_crossing import _EdgeTable, _sweep_edges_aa


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


def _spans_from_crossings(
    mut crossings: List[_Crossing], fill_rule: FillRule
) -> List[_Span]:
    """Given one row's crossings (unsorted, x position + direction),
    sort by x and scan left to right accumulating a signed winding
    number, returning the resulting filled spans under `fill_rule`.

    Under EVEN_ODD this matches plain sort-and-pair (1st-2nd, 3rd-4th,
    ...) for any non-self-intersecting polygon, since winding parity
    flips once per crossing regardless of sign.

    Beyond the plain winding scan, adjacent spans merge wherever one's
    end_x touches or overlaps the next one's start_x. In a
    self-intersecting shape two unrelated edges can cross one scanline at
    the same rounded x, dipping winding to outside and straight back;
    unmerged that yields two spans both including that x, which
    double-blends a translucent color.
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

    Y-extent per edge is half-open, [min(y0,y1), max(y0,y1)), the rule
    real rasterizers use (OpenGL/DirectX's "top-left fill rule"), so
    adjacent shapes sharing an edge tile without a gap or a
    double-covered seam. Without it a vertex shared by two edges running
    in opposite y-directions counts twice, and a local extremum such as
    a triangle's apex has to contribute zero net crossings.

    One consequence: a polygon's bottom-most row, when it is a
    horizontal edge (as in any axis-aligned rectangle), is not filled --
    both adjacent edges have that y as their excluded "max" endpoint.
    Matching fill_rect(x, y, width, height) exactly therefore needs
    *asymmetric* corners: (x, y), (x+width-1, y), (x+width-1, y+height),
    (x, y+height) -- inclusive on the last column, one-past on the last
    row. The X-fill between a row's crossing pair is fully inclusive;
    only the Y-extent is half-open.

    Under either fill rule every pixel gets exactly one set_pixel call
    per row, including at a self-intersection.

    Args:
        canvas: Canvas to fill into.
        points: Polygon vertices, in order. Implicitly closed.
        color: Fill color.
        fill_rule: EVEN_ODD (default) or NONZERO -- see FillRule.
    """
    if canvas.has_transform():
        var m = canvas.current_transform()
        _fill_polygon_device(
            canvas, _mapped_points(m, points), color, fill_rule
        )
        return
    _fill_polygon_device(canvas, points, color, fill_rule)


def _fill_polygon_device(
    mut canvas: Canvas,
    points: List[Point],
    color: Color,
    fill_rule: FillRule = FillRule.EVEN_ODD,
):
    """`fill_polygon` for device-space arguments: the body every
    call lands in. It has no transform check of its own, so its
    loops compile with nothing ahead of them and it never calls
    back into the public function.
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


def fill_polygon_aa(
    mut canvas: Canvas,
    points: List[Point],
    color: Color,
    fill_rule: FillRule = FillRule.EVEN_ODD,
    supersample: Int = 4,
):
    """Anti-aliased filled polygon: for every pixel near the polygon,
    samples an NxN sub-pixel grid and turns the coverage fraction into
    that pixel's alpha. Each output pixel is visited exactly once, so a
    translucent color cannot double-blend. `draw_polygon_aa` is the AA
    *outline*.

    Pixels are centered at their integer coordinate, as in every other AA
    primitive here, and `fill_rule` shares `_is_inside` with fill_polygon
    so the two agree on the boundary.

    Args:
        canvas: Canvas to fill into.
        points: Polygon vertices, in order. Implicitly closed.
        color: Fill color.
        fill_rule: EVEN_ODD (default) or NONZERO -- see FillRule.
        supersample: Sub-pixel grid side length per pixel (N -> N*N
            samples) under EVEN_ODD. A NONZERO fill rasterizes by
            exact area (`canvas.aa_area`) and ignores it.
    """
    if canvas.has_transform():
        var m = canvas._take_transform()
        fill_polygon_aa(
            canvas,
            _mapped_points_to_fpoints(m, points),
            color,
            fill_rule,
            supersample,
        )
        canvas._set_transform(m)
        return
    var n = len(points)
    if n < 3:
        return

    var fpoints = List[FPoint](capacity=n)
    for i in range(n):
        fpoints.append(FPoint(Float64(points[i].x), Float64(points[i].y)))
    fill_polygon_aa(canvas, fpoints, color, fill_rule, supersample)


def fill_polygon_aa(
    mut canvas: Canvas,
    points: List[FPoint],
    color: Color,
    fill_rule: FillRule = FillRule.EVEN_ODD,
    supersample: Int = 4,
):
    """`fill_polygon_aa` at sub-pixel vertices -- the same fill, with
    its outline placed to a fraction of a pixel rather than snapped to
    the pixel grid.

    This is the real implementation; the whole-pixel overload above
    converts and calls it.

    Args:
        canvas: Canvas to fill into.
        points: Polygon vertices, in order, at sub-pixel positions.
            Implicitly closed.
        color: Fill color.
        fill_rule: EVEN_ODD (default) or NONZERO -- see FillRule.
        supersample: Sub-pixel grid side length per pixel (N -> N*N
            samples) under EVEN_ODD. A NONZERO fill rasterizes by
            exact area (`canvas.aa_area`) and ignores it.
    """
    if canvas.has_transform():
        var m = canvas.current_transform()
        _fill_polygon_aa_device(
            canvas, _mapped_fpoints(m, points), color, fill_rule, supersample
        )
        return
    _fill_polygon_aa_device(canvas, points, color, fill_rule, supersample)


def _fill_polygon_aa_device(
    mut canvas: Canvas,
    points: List[FPoint],
    color: Color,
    fill_rule: FillRule = FillRule.EVEN_ODD,
    supersample: Int = 4,
):
    """`fill_polygon_aa` for device-space arguments: the body every
    call lands in. It has no transform check of its own, so its
    loops compile with nothing ahead of them and it never calls
    back into the public function.
    """
    var n = len(points)
    if n < 3:
        return

    var min_x = points[0].x
    var max_x = min_x
    var min_y = points[0].y
    var max_y = min_y
    for i in range(1, n):
        if points[i].x < min_x:
            min_x = points[i].x
        if points[i].x > max_x:
            max_x = points[i].x
        if points[i].y < min_y:
            min_y = points[i].y
        if points[i].y > max_y:
            max_y = points[i].y

    var edges = _EdgeTable(n)
    for i in range(n):
        var a = points[i]
        var b = points[(i + 1) % n]
        edges.add_edge(a.x, a.y, b.x, b.y)

    # Widened outward to whole pixels (floor/ceil, not round) so a
    # pixel an edge only partly covers is still swept -- see
    # fill_path_aa, which does the same.
    _sweep_edges_aa(
        canvas,
        edges,
        Int(floor(min_x)),
        Int(floor(min_y)),
        Int(ceil(max_x)),
        Int(ceil(max_y)),
        color,
        fill_rule,
        supersample,
    )
