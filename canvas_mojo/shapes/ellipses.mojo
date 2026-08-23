"""Ellipse drawing: midpoint-algorithm hard-edged outline/fill
(draw_ellipse/fill_ellipse, independent-x/y-radii generalizations of
canvas_mojo.shapes.circles' draw_circle/fill_circle) and supersampled
analytic-coverage anti-aliased variants (draw_ellipse_aa/
fill_ellipse_aa) -- see canvas_mojo.shapes.lines's own module
docstring for the hard-edged vs. `_aa` naming convention this follows.
"""

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas


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
            var dx = abs(Float64(px - cx))
            var dy = abs(Float64(py - cy))

            # Same "provably fully outside the ring band" skip
            # draw_circle_aa's own docstring describes, generalized to
            # the two independent outer-/inner-ellipse normalized-space
            # tests this function already uses -- no single shared
            # distance to test against here either, so both directions
            # get their own nearest/farthest check.
            var near_onx = max(0.0, dx - 0.5) / outer_rx
            var near_ony = max(0.0, dy - 0.5) / outer_ry
            if near_onx * near_onx + near_ony * near_ony >= 1.0:
                continue  # whole pixel square is outside the outer ellipse

            var far_inx = (dx + 0.5) / inner_rx
            var far_iny = (dy + 0.5) / inner_ry
            if far_inx * far_inx + far_iny * far_iny < 1.0:
                continue  # whole pixel square is inside the inner ellipse

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
