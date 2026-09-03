"""Arc/pie-wedge/ring-sector drawing: outline (draw_arc/draw_arc_aa,
built by sampling the arc into points and handing them to
canvas.shapes.lines' draw_polyline/draw_polyline_aa), solid
wedge/ring fill (fill_arc/fill_ring_sector, built the same way via
canvas.shapes.polygon_fill's fill_polygon), and their
supersampled analytic-coverage AA counterparts (fill_arc_aa/
fill_ring_sector_aa) -- see canvas.shapes.lines for the
hard-edged vs. `_aa` naming convention this follows.

Also home to the shared angle/bounding-box math (_arc_points,
_angle_in_span, _arc_bounds, _union_bounds, _extend_bounds) every
function above builds on.
"""

from std.math import atan2, cos, pi, sin
from std.runtime.asyncrt import TaskGroup, parallelism_level

from canvas.color import Color
from canvas.buffer import Canvas
from canvas.geometry import Point, FPoint, _round_to_int
from canvas.shapes.lines import draw_polyline, draw_polyline_aa
from canvas.shapes.polygon_fill import fill_polygon


# Below this many pixels in a shape's bounding box, the fill runs
# inline rather than dispatching tasks. Matches the fill sweep's
# threshold in canvas.aa_crossing; set by benchmark (#102).
comptime _MIN_PARALLEL_PIXELS = 40000


def _extend_bounds(
    mut min_x: Float64,
    mut min_y: Float64,
    mut max_x: Float64,
    mut max_y: Float64,
    x: Float64,
    y: Float64,
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
    the arc/wedge (cx, cy, radius, start_angle, end_angle) occupies.
    fill_arc_aa/fill_ring_sector_aa scan this instead of the
    circumscribing square, which overestimates anything short of a
    near-full circle.

    The bounds are exact. An arc's x and y are each monotonic in angle
    *between* the four cardinal angles (0, pi/2, pi, 3*pi/2), the only
    places either can reach a local extreme, so the bounds are those of
    the two endpoints plus whichever cardinal points fall inside
    [start_angle, end_angle].

    `include_center` covers the wedge case: fill_arc_aa's shape is
    bounded by two straight radii back to (cx, cy), so the center can be
    its extreme point.

    fill_ring_sector_aa has no center point but does have two radial
    edges, which a call given only the outer radius knows nothing about.
    A straight line's bounds are its endpoints' bounds, so it makes two
    calls, one per radius, both `include_center=False`, and unions them.

    Outer-radius bounds alone are not enough -- the inner arc's bounds
    are not in general a subset of the outer arc's. Whenever
    [start_angle, end_angle] reaches no cardinal angle, the inner arc's
    extreme point lies closer to (cx, cy) than anything on the outer arc,
    past the outer bound. Counterexample: cx=270, cy=185,
    start_angle=-pi/2, end_angle=-pi/6, outer_radius=148.5,
    inner_radius=74.25 -- the outer arc's y-range is [36.5, 110.75], but
    the inner endpoint at end_angle sits at y=147.875, so single-radius
    bounds cut a rectangular notch out of the ring.
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
    if _angle_in_span(pi / 2, start_angle, end_angle):
        _extend_bounds(min_x, min_y, max_x, max_y, cx, cy + radius)
    if _angle_in_span(pi, start_angle, end_angle):
        _extend_bounds(min_x, min_y, max_x, max_y, cx - radius, cy)
    if _angle_in_span(3 * pi / 2, start_angle, end_angle):
        _extend_bounds(min_x, min_y, max_x, max_y, cx, cy - radius)

    return (min_x, min_y, max_x, max_y)


def _union_bounds(
    a: Tuple[Float64, Float64, Float64, Float64],
    b: Tuple[Float64, Float64, Float64, Float64],
) -> Tuple[Float64, Float64, Float64, Float64]:
    """The smallest box containing both `a` and `b`, each an
    (min_x, min_y, max_x, max_y) box from `_arc_bounds` -- how
    fill_ring_sector_aa combines its two radii's bounds into one.
    """
    return (min(a[0], b[0]), min(a[1], b[1]), max(a[2], b[2]), max(a[3], b[3]))


def _arc_fpoints(
    cx: Float64,
    cy: Float64,
    radius: Float64,
    start_angle: Float64,
    end_angle: Float64,
) -> List[FPoint]:
    """Sample points along a circular arc (radians, start_angle <=
    end_angle expected; pass end_angle = start_angle + 2*pi for a full
    circle) at roughly 1-pixel arc-length spacing. Step count scales
    with radius * angle span, so a tiny wedge and a full-page donut
    both sample smoothly.

    Step count comes from the radius and sweep directly, since a
    circular arc's geometry is known exactly here; `Path.arc_to`
    flattens through this rather than through its own curvature bound.
    Points are exact circle math (cx + r*cos(theta), cy + r*sin(theta)),
    not a cubic-Bezier approximation.

    Sub-pixel; `_arc_points` below rounds for the hard-edged callers.
    The conversion has to run in that direction, since rounding first
    would discard the detail the coverage sweep resolves.
    """
    var span = end_angle - start_angle
    var steps = max(4, Int(radius * abs(span)))
    var points = List[FPoint](capacity=steps + 1)
    for i in range(steps + 1):
        var t = Float64(i) / Float64(steps)
        var angle = start_angle + t * span
        points.append(
            FPoint(cx + radius * cos(angle), cy + radius * sin(angle))
        )
    return points^


def _arc_points(
    cx: Float64,
    cy: Float64,
    radius: Float64,
    start_angle: Float64,
    end_angle: Float64,
) -> List[Point]:
    """`_arc_fpoints` rounded to whole pixels, for the hard-edged
    primitives (draw_arc, fill_arc, fill_ring_sector) that address
    pixels rather than sub-pixel positions.
    """
    var fpoints = _arc_fpoints(cx, cy, radius, start_angle, end_angle)
    var points = List[Point](capacity=len(fpoints))
    for i in range(len(fpoints)):
        points.append(
            Point(_round_to_int(fpoints[i].x), _round_to_int(fpoints[i].y))
        )
    return points^


def _angle_in_span(
    angle: Float64, start_angle: Float64, end_angle: Float64
) -> Bool:
    """Is `angle` within [start_angle, end_angle] once normalized into
    the 2*pi-wide window starting at start_angle? atan2's range is
    (-pi, pi], which won't line up with an arbitrary start/end pair: a
    wedge spanning the discontinuity at +/-pi needs the sample's raw
    angle shifted a full turn before <= / >= means anything.
    """
    var a = angle
    while a < start_angle:
        a += 2 * pi
    while a >= start_angle + 2 * pi:
        a -= 2 * pi
    return a <= end_angle


struct _AngleSpan(ImplicitlyCopyable, Movable):
    """`_angle_in_span` precomputed for one wedge, so a sample's
    membership is decided by sign tests instead of `atan2`.

    Membership only needs to know which side of the two boundary rays a
    sample falls on, not its angle, so rotating the sample into the frame
    where the span starts at 0 turns the test into cross products. With
    `theta` the sample's angle in that frame, membership is
    `theta <= span`, and:

    - a span of at most pi is the intersection of two half-planes:
      counterclockwise of the start ray (`ry >= 0`) and clockwise of the
      end ray (`cross_span >= 0`);
    - a wider span is the complement of the gap it leaves, which is
      itself narrower than pi, so the same test runs on the gap and the
      answer is negated.
    """

    var cos_start: Float64
    var sin_start: Float64
    var cos_end: Float64
    var sin_end: Float64
    var start_angle: Float64
    var end_angle: Float64
    var near_full_turn: Bool
    var always_inside: Bool
    var always_outside: Bool
    var wide: Bool
    var center_inside: Bool

    def __init__(out self, start_angle: Float64, end_angle: Float64):
        var span = end_angle - start_angle
        self.cos_start = cos(start_angle)
        self.sin_start = sin(start_angle)
        self.cos_end = cos(end_angle)
        self.sin_end = sin(end_angle)
        self.start_angle = start_angle
        self.end_angle = end_angle
        # A span within rounding of a full turn is the one place the
        # cross-product form and the angle form can genuinely disagree:
        # `end - start` can round to exactly 2*pi while `end` itself
        # still sits a few ULP below the sample's own normalized angle,
        # so the angle form excludes a sliver that a "full turn is
        # always inside" shortcut would include. Handed to the exact
        # form rather than reasoned about -- a full-circle wedge is
        # `fill_circle_aa`'s job anyway, so nothing hot pays for it.
        self.near_full_turn = span > 2 * pi - 1.0e-9 and span < 2 * pi + 1.0e-9
        self.always_inside = span >= 2 * pi and not self.near_full_turn
        self.always_outside = span < 0.0
        self.wide = span > pi
        # A sample exactly on the center has no angle to speak of, and
        # `atan2(0, 0)` is 0 -- which is inside this span only for some
        # start/end pairs. Decided once here, by the exact angle form,
        # rather than left to the cross products per sample.
        self.center_inside = _angle_in_span(0.0, start_angle, end_angle)

    def contains(self, fx: Float64, fy: Float64) -> Bool:
        """Is the offset `(fx, fy)` from the wedge's center inside the
        span? `(0, 0)` is answered by `center_inside`.
        """
        if self.near_full_turn:
            return _angle_in_span(
                atan2(fy, fx), self.start_angle, self.end_angle
            )
        if self.always_inside:
            return True
        if self.always_outside:
            return False
        if fx == 0.0 and fy == 0.0:
            return self.center_inside

        # Which side of each boundary ray the sample falls on.
        var cross_start = self.cos_start * fy - self.sin_start * fx
        var cross_end = fx * self.sin_end - fy * self.cos_end

        # A sample sitting exactly on a boundary ray puts a cross
        # product at zero, where the sign that decides membership is
        # whatever the rounding produced. Rare enough to be worth
        # answering exactly rather than approximately: fall back to the
        # angle form for those, so the result matches it everywhere and
        # the fast path carries every sample that is not on an edge.
        var scale = (fx * fx + fy * fy) * 1.0e-12
        if cross_start * cross_start <= scale or cross_end * cross_end <= scale:
            return _angle_in_span(
                atan2(fy, fx), self.start_angle, self.end_angle
            )

        if self.wide:
            return not (cross_start < 0.0 and cross_end < 0.0)
        return cross_start > 0.0 and cross_end > 0.0


def _square_in_cone(span: _AngleSpan, ox: Float64, oy: Float64) -> Bool:
    """Whether the whole pixel square centred at offset (ox, oy) from
    the wedge's own centre lies within the wedge's angular sweep.

    Only sound for a sweep of at most half a turn, which the caller
    checks: a sector is the intersection of two half-planes through the
    centre, convex exactly while the sweep stays within pi, and a convex
    set containing all four corners of a square contains the square. Past
    pi the sector is non-convex and four corners prove nothing, so a
    wider wedge gets no fast path.

    The square straddling the centre is excluded, since the apex has no
    defined angle and no sector narrower than a half turn contains a
    square around it. At most one pixel per wedge falls through to
    sampling.
    """
    var lx = ox - 0.5
    var hx = ox + 0.5
    var ly = oy - 0.5
    var hy = oy + 0.5
    if lx <= 0.0 and hx >= 0.0 and ly <= 0.0 and hy >= 0.0:
        return False
    return (
        span.contains(lx, ly)
        and span.contains(hx, ly)
        and span.contains(lx, hy)
        and span.contains(hx, hy)
    )


def draw_arc(
    mut canvas: Canvas,
    cx: Float64,
    cy: Float64,
    radius: Float64,
    start_angle: Float64,
    end_angle: Float64,
    color: Color,
):
    """The arc's curved boundary only, no radii back to center:
    hard-edged, ~1px, via draw_polyline over _arc_points' samples. For
    a solid wedge see fill_arc; for a ring segment, fill_ring_sector.

    Args:
        canvas: Canvas to draw into.
        cx: Center x.
        cy: Center y.
        radius: Arc radius in pixels.
        start_angle: Sweep start, radians, 0 pointing along +x.
        end_angle: Sweep end, radians. Must be >= start_angle.
        color: Outline color.
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
    """Anti-aliased version of draw_arc -- see draw_polyline_aa.

    Args:
        canvas: Canvas to draw into.
        cx: Center x.
        cy: Center y.
        radius: Arc radius in pixels.
        start_angle: Sweep start, radians, 0 pointing along +x.
        end_angle: Sweep end, radians. Must be >= start_angle.
        color: Outline color.
        width: Stroke width in pixels.
        supersample: Sub-pixel grid side length per pixel (N -> N*N samples).
    """
    if radius <= 0.0:
        canvas.set_pixel(_round_to_int(cx), _round_to_int(cy), color)
        return
    var points = _arc_points(cx, cy, radius, start_angle, end_angle)
    draw_polyline_aa(canvas, points, color, width, supersample)


def fill_arc(
    mut canvas: Canvas,
    cx: Float64,
    cy: Float64,
    radius: Float64,
    start_angle: Float64,
    end_angle: Float64,
    color: Color,
):
    """A solid pie-slice wedge: the arc plus two straight radii back to
    the center, filled. Samples the arc (_arc_points), appends the center
    point to close the shape, and hands it to fill_polygon.

    Args:
        canvas: Canvas to fill into.
        cx: Center x.
        cy: Center y.
        radius: Wedge radius in pixels.
        start_angle: Sweep start, radians, 0 pointing along +x.
        end_angle: Sweep end, radians. Must be >= start_angle.
        color: Fill color.
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
    """Anti-aliased pie-slice wedge: supersampled analytic coverage,
    testing each sub-sample against the wedge's exact definition -- within
    `radius` of center and within the angle span (_angle_in_span) --
    rather than rasterizing a flattened polygon.

    Scans `_arc_bounds`' tight box, expanded 1px for the AA sampling
    margin.

    Args:
        canvas: Canvas to fill into.
        cx: Center x.
        cy: Center y.
        radius: Wedge radius in pixels.
        start_angle: Sweep start, radians, 0 pointing along +x.
        end_angle: Sweep end, radians. Must be >= start_angle.
        color: Fill color.
        supersample: Sub-pixel grid side length per pixel (N -> N*N samples).
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

    # One rotation's worth of trigonometry per wedge, replacing an
    # `atan2` per sub-sample -- see `_AngleSpan`.
    var span = _AngleSpan(start_angle, end_angle)

    # Whether a "whole pixel square is provably inside" test is sound
    # for this wedge. See _square_in_cone: the argument needs the
    # angular cone to be convex, which it is exactly when the sweep is
    # at most half a turn. A wider sweep gets no fast path and is
    # filled one sub-sample grid at a time.
    var can_fast_fill = span.always_inside or not span.wide

    # Rows are independent -- each tests its own pixels against the
    # wedge's equations and writes only its own -- so a large wedge is
    # split into bands, one task per band. Same pattern as the fill
    # sweep in canvas.aa_crossing.
    #
    # Everything a band needs is scalars: centre, radius, the angle
    # span (itself a struct of plain floats and bools) and the colour.
    # That matters here, because the aggregate arguments that corrupt
    # under `create_task` are the heap-backed ones -- see #97. There is
    # no List anywhere in this call.
    var row_count = max_py + 1 - min_py
    var col_count = max_px + 1 - min_px
    if row_count <= 0 or col_count <= 0:
        return

    var bands = 1
    if row_count * col_count >= _MIN_PARALLEL_PIXELS:
        bands = parallelism_level()
        if bands > row_count:
            bands = row_count
        if bands < 1:
            bands = 1

    if bands == 1:
        _fill_arc_band(
            canvas,
            cx,
            cy,
            r2,
            span,
            can_fast_fill,
            min_px,
            max_px,
            min_py,
            max_py + 1,
            n,
            step,
            total_samples,
            color,
        )
        return

    var per_band = (row_count + bands - 1) // bands
    var tg = TaskGroup()
    for b in range(bands):
        var band_start = min_py + b * per_band
        var band_end = band_start + per_band
        if band_end > max_py + 1:
            band_end = max_py + 1
        if band_start >= band_end:
            continue
        tg.create_task(
            _fill_arc_band_async(
                canvas,
                cx,
                cy,
                r2,
                span,
                can_fast_fill,
                min_px,
                max_px,
                band_start,
                band_end,
                n,
                step,
                total_samples,
                color,
            )
        )
    tg.wait()


async def _fill_arc_band_async(
    mut canvas: Canvas,
    cx: Float64,
    cy: Float64,
    r2: Float64,
    span: _AngleSpan,
    can_fast_fill: Bool,
    min_px: Int,
    max_px: Int,
    first_row: Int,
    last_row: Int,
    n: Int,
    step: Float64,
    total_samples: Int,
    color: Color,
):
    """`_fill_arc_band` as a task, so the single-band path stays an
    ordinary call with no coroutine machinery around it.
    """
    _fill_arc_band(
        canvas,
        cx,
        cy,
        r2,
        span,
        can_fast_fill,
        min_px,
        max_px,
        first_row,
        last_row,
        n,
        step,
        total_samples,
        color,
    )


def _fill_arc_band(
    mut canvas: Canvas,
    cx: Float64,
    cy: Float64,
    r2: Float64,
    span: _AngleSpan,
    can_fast_fill: Bool,
    min_px: Int,
    max_px: Int,
    first_row: Int,
    last_row: Int,
    n: Int,
    step: Float64,
    total_samples: Int,
    color: Color,
):
    """Fill rows [first_row, last_row) of a wedge."""
    for py in range(first_row, last_row):
        var oy = Float64(py) - cy
        var dy = abs(oy)
        var near_dy = max(0.0, dy - 0.5)
        var far_dy = dy + 0.5
        for px in range(min_px, max_px + 1):
            # "Provably outside the radius, regardless of angle" is
            # cheap and always valid -- the AABB-vs-circle nearest-point
            # test fill_circle_aa uses.
            var ox = Float64(px) - cx
            var dx = abs(ox)
            var near_dx = max(0.0, dx - 0.5)
            if near_dx * near_dx + near_dy * near_dy > r2:
                continue

            # ...and the converse: a square provably inside both the
            # radius and the cone takes full coverage without visiting
            # the sample grid, which for a large wedge is nearly all of
            # its area.
            if can_fast_fill:
                var far_dx = dx + 0.5
                if far_dx * far_dx + far_dy * far_dy <= r2:
                    if span.always_inside:
                        # The sweep is a full turn, so the wedge is the
                        # disk and the radius test settled it.
                        canvas.set_pixel(px, py, color)
                        continue
                    if _square_in_cone(span, ox, oy):
                        canvas.set_pixel(px, py, color)
                        continue

            var covered = 0
            for sy in range(n):
                var fy = Float64(py) - cy + (Float64(sy) + 0.5) * step - 0.5
                for sx in range(n):
                    var fx = Float64(px) - cx + (Float64(sx) + 0.5) * step - 0.5
                    if fx * fx + fy * fy <= r2:
                        if span.contains(fx, fy):
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
    outer_radius within the angle span. Built like fill_arc -- sample
    the outer arc forward and the inner arc backward, so the combined
    points trace the ring's boundary as one continuous loop, then
    fill_polygon.

    Args:
        canvas: Canvas to fill into.
        cx: Center x.
        cy: Center y.
        inner_radius: Ring's inner edge, in pixels.
        outer_radius: Ring's outer edge, in pixels. Must exceed
            inner_radius.
        start_angle: Sweep start, radians, 0 pointing along +x.
        end_angle: Sweep end, radians. Must be >= start_angle.
        color: Fill color.
    """
    if (
        outer_radius <= 0.0
        or inner_radius < 0.0
        or inner_radius >= outer_radius
    ):
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
    """Anti-aliased fill_ring_sector: fill_arc_aa's per-sample technique
    plus a second radius test, both of which must pass.

    Scans the union of `_arc_bounds`' boxes for the outer and inner
    radii, both with no center point; the outer radius alone is not
    enough.

    Args:
        canvas: Canvas to fill into.
        cx: Center x.
        cy: Center y.
        inner_radius: Ring's inner edge, in pixels.
        outer_radius: Ring's outer edge, in pixels. Must exceed
            inner_radius.
        start_angle: Sweep start, radians, 0 pointing along +x.
        end_angle: Sweep end, radians. Must be >= start_angle.
        color: Fill color.
        supersample: Sub-pixel grid side length per pixel (N -> N*N samples).
    """
    if (
        outer_radius <= 0.0
        or inner_radius < 0.0
        or inner_radius >= outer_radius
    ):
        return

    var outer_r2 = outer_radius * outer_radius
    var inner_r2 = inner_radius * inner_radius
    var n = supersample
    var total_samples = n * n
    var step = 1.0 / Float64(n)

    var outer_bounds = _arc_bounds(
        cx, cy, outer_radius, start_angle, end_angle, False
    )
    var inner_bounds = _arc_bounds(
        cx, cy, inner_radius, start_angle, end_angle, False
    )
    var bounds = _union_bounds(outer_bounds, inner_bounds)
    var min_px = _round_to_int(bounds[0]) - 1
    var max_px = _round_to_int(bounds[2]) + 1
    var min_py = _round_to_int(bounds[1]) - 1
    var max_py = _round_to_int(bounds[3]) + 1

    # One rotation's worth of trigonometry per wedge, replacing an
    # `atan2` per sub-sample -- see `_AngleSpan`.
    var span = _AngleSpan(start_angle, end_angle)

    # Sound only for a sweep of at most half a turn -- see
    # _square_in_cone, and fill_arc_aa which uses the same guard.
    var can_fast_fill = span.always_inside or not span.wide

    # Banded exactly as fill_arc_aa is, and for the same reason: rows
    # are independent and every argument a band needs is a scalar.
    var row_count = max_py + 1 - min_py
    var col_count = max_px + 1 - min_px
    if row_count <= 0 or col_count <= 0:
        return

    var bands = 1
    if row_count * col_count >= _MIN_PARALLEL_PIXELS:
        bands = parallelism_level()
        if bands > row_count:
            bands = row_count
        if bands < 1:
            bands = 1

    if bands == 1:
        _fill_ring_band(
            canvas,
            cx,
            cy,
            inner_r2,
            outer_r2,
            span,
            can_fast_fill,
            min_px,
            max_px,
            min_py,
            max_py + 1,
            n,
            step,
            total_samples,
            color,
        )
        return

    var per_band = (row_count + bands - 1) // bands
    var tg = TaskGroup()
    for b in range(bands):
        var band_start = min_py + b * per_band
        var band_end = band_start + per_band
        if band_end > max_py + 1:
            band_end = max_py + 1
        if band_start >= band_end:
            continue
        tg.create_task(
            _fill_ring_band_async(
                canvas,
                cx,
                cy,
                inner_r2,
                outer_r2,
                span,
                can_fast_fill,
                min_px,
                max_px,
                band_start,
                band_end,
                n,
                step,
                total_samples,
                color,
            )
        )
    tg.wait()


async def _fill_ring_band_async(
    mut canvas: Canvas,
    cx: Float64,
    cy: Float64,
    inner_r2: Float64,
    outer_r2: Float64,
    span: _AngleSpan,
    can_fast_fill: Bool,
    min_px: Int,
    max_px: Int,
    first_row: Int,
    last_row: Int,
    n: Int,
    step: Float64,
    total_samples: Int,
    color: Color,
):
    """`_fill_ring_band` as a task; see fill_arc_aa's equivalent."""
    _fill_ring_band(
        canvas,
        cx,
        cy,
        inner_r2,
        outer_r2,
        span,
        can_fast_fill,
        min_px,
        max_px,
        first_row,
        last_row,
        n,
        step,
        total_samples,
        color,
    )


def _fill_ring_band(
    mut canvas: Canvas,
    cx: Float64,
    cy: Float64,
    inner_r2: Float64,
    outer_r2: Float64,
    span: _AngleSpan,
    can_fast_fill: Bool,
    min_px: Int,
    max_px: Int,
    first_row: Int,
    last_row: Int,
    n: Int,
    step: Float64,
    total_samples: Int,
    color: Color,
):
    """Fill rows [first_row, last_row) of a ring sector."""
    for py in range(first_row, last_row):
        var oy = Float64(py) - cy
        var dy = abs(oy)
        var near_dy = max(0.0, dy - 0.5)
        var far_dy = dy + 0.5
        for px in range(min_px, max_px + 1):
            # fill_arc_aa's radius-only fast-outside skip, applied at
            # both edges: the pixel square entirely beyond
            # outer_radius, or its farthest point from center still
            # within inner_radius, so no corner reaches the ring.
            var ox = Float64(px) - cx
            var dx = abs(ox)
            var near_dx = max(0.0, dx - 0.5)
            var near_d2 = near_dx * near_dx + near_dy * near_dy
            if near_d2 > outer_r2:
                continue
            var far_dx = dx + 0.5
            var far_d2 = far_dx * far_dx + far_dy * far_dy
            if far_d2 < inner_r2:
                continue

            # Provably inside. The square sits within the annulus when
            # its nearest point to
            # the centre already clears the inner radius and its
            # farthest stays inside the outer -- an exact test needing
            # no convexity, since it is a distance range. Combined with
            # the square lying inside the angular cone, that puts it
            # inside the ring sector.
            if can_fast_fill and far_d2 <= outer_r2 and near_d2 >= inner_r2:
                if span.always_inside:
                    canvas.set_pixel(px, py, color)
                    continue
                if _square_in_cone(span, ox, oy):
                    canvas.set_pixel(px, py, color)
                    continue

            var covered = 0
            for sy in range(n):
                var fy = Float64(py) - cy + (Float64(sy) + 0.5) * step - 0.5
                for sx in range(n):
                    var fx = Float64(px) - cx + (Float64(sx) + 0.5) * step - 0.5
                    var d2 = fx * fx + fy * fy
                    if d2 <= outer_r2 and d2 >= inner_r2:
                        if span.contains(fx, fy):
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
