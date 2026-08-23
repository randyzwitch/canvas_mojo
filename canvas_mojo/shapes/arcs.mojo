"""Arc/pie-wedge/ring-sector drawing: outline (draw_arc/draw_arc_aa,
built by sampling the arc into points and handing them to
canvas_mojo.shapes.lines' draw_polyline/draw_polyline_aa), solid
wedge/ring fill (fill_arc/fill_ring_sector, built the same way via
canvas_mojo.shapes.polygon_fill's fill_polygon), and their
supersampled analytic-coverage AA counterparts (fill_arc_aa/
fill_ring_sector_aa) -- see canvas_mojo.shapes.lines's own module
docstring for the hard-edged vs. `_aa` naming convention this follows.

Also home to the shared angle/bounding-box math (_arc_points,
_angle_in_span, _arc_bounds, _union_bounds, _extend_bounds) every
function above builds on.
"""

from std.math import atan2, cos, sin

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas
from canvas_mojo.geometry import Point, _round_to_int
from canvas_mojo.shapes.lines import draw_polyline, draw_polyline_aa
from canvas_mojo.shapes.polygon_fill import fill_polygon

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

    `include_center` covers fill_arc_aa's own difference from a plain
    arc: its wedge is bounded by two straight radii back to (cx, cy),
    so the center itself can be the shape's own leftmost/rightmost/etc.
    point (e.g. a thin slice near angle 0, whose two arc endpoints are
    both near x = cx + radius, but whose straight edges still reach
    back to x = cx).

    fill_ring_sector_aa has no center point in its shape at all
    (inner_radius > 0 there) but does have two straight radial edges
    of its own, from the outer endpoint at each of start_angle/
    end_angle back to the inner endpoint at that same angle -- and
    this function, called with `radius` = the outer radius alone,
    knows nothing about where those inner endpoints are. A straight
    line's own bounding box is exactly the bounds of its two
    endpoints, so as long as *both* endpoints are already covered by
    *some* bounds this function returns, the connecting edge is too --
    which is why fill_ring_sector_aa below calls this twice (once per
    radius, both with `include_center=False`) and unions the two
    results, rather than calling it once with the outer radius alone.
    That second part used to be a documented shortcut here ("the inner
    arc's own bounds are always a subset of the outer arc's") --
    false in general, not just an edge case: whenever [start_angle,
    end_angle] doesn't reach a cardinal angle, the *inner* arc's own
    extreme point (closest to the center, at whichever endpoint angle
    is nearest a cardinal angle) sits *closer to (cx, cy)* than
    anything on the outer arc reaches at that same extreme -- past the
    outer arc's own bound in that direction, not inside it. Confirmed
    both by direct counterexample (cx=270, cy=185, start_angle=-pi/2,
    end_angle=-pi/6, outer_radius=148.5, inner_radius=74.25: the outer
    arc's own y-range over that span is [36.5, 110.75], but the inner
    endpoint at end_angle alone already sits at y=147.875, past that
    range's own max) and by rendering a real ring sector with the old
    single-radius bounds, which left exactly the rectangular notch
    that counterexample predicts -- see this repo's issue #33.
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


def _union_bounds(
    a: Tuple[Float64, Float64, Float64, Float64], b: Tuple[Float64, Float64, Float64, Float64]
) -> Tuple[Float64, Float64, Float64, Float64]:
    """The smallest box containing both `a` and `b` (each an
    (min_x, min_y, max_x, max_y) box, `_arc_bounds`'s own return
    shape) -- fill_ring_sector_aa's own way of combining the outer and
    inner arcs' individually-rigorous bounds into one rigorous bound
    for the whole ring sector; see `_arc_bounds`'s own docstring for
    why neither radius's bounds alone are enough.
    """
    return (min(a[0], b[0]), min(a[1], b[1]), max(a[2], b[2]), max(a[3], b[3]))


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

    Scans the union of `_arc_bounds`' own tight bounding boxes for the
    outer and inner radii (both with no center point -- see that
    function's own docstring for exactly why *both* radii need their
    own call, not just the outer one), the same dominant fix
    fill_arc_aa's own docstring explains, just applied twice and
    combined via `_union_bounds`.
    """
    if outer_radius <= 0.0 or inner_radius < 0.0 or inner_radius >= outer_radius:
        return

    var outer_r2 = outer_radius * outer_radius
    var inner_r2 = inner_radius * inner_radius
    var n = supersample
    var total_samples = n * n
    var step = 1.0 / Float64(n)

    var outer_bounds = _arc_bounds(cx, cy, outer_radius, start_angle, end_angle, False)
    var inner_bounds = _arc_bounds(cx, cy, inner_radius, start_angle, end_angle, False)
    var bounds = _union_bounds(outer_bounds, inner_bounds)
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
