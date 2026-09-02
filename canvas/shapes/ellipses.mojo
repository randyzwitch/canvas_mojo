"""Ellipse drawing: midpoint-algorithm hard-edged outline/fill
(draw_ellipse/fill_ellipse, independent-x/y-radii generalizations of
canvas.shapes.circles' draw_circle/fill_circle) and supersampled
analytic-coverage anti-aliased variants (draw_ellipse_aa/
fill_ellipse_aa) -- see canvas.shapes.lines for the hard-edged
vs. `_aa` naming convention this follows.
"""

from std.math import ceil, floor

from canvas.color import Color
from canvas.buffer import Canvas
from canvas.geometry import _round_to_int


def _plot_ellipse_points(
    mut canvas: Canvas, cx: Int, cy: Int, x: Int, y: Int, color: Color
):
    """Plot draw_ellipse's 4-way symmetric points at offset (x, y),
    guarding the two cases where mirrored points collapse onto one
    pixel: x==0, where the left and right mirrors coincide, and y==0,
    where top and bottom do. Both are reachable here -- region 1
    *starts* at x==0 and region 2 ends at y==0, unlike draw_circle's
    loop, which starts at x==radius and never returns to x==0. Without
    the guard a translucent color blends twice at all 4 axis extremes.
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


def draw_ellipse(
    mut canvas: Canvas, cx: Int, cy: Int, rx: Int, ry: Int, color: Color
):
    """The midpoint ellipse algorithm -- draw_circle's generalization
    to independent x/y radii.

    Two regions, split where the boundary's slope magnitude crosses 1
    (region 1 shallow, stepping x; region 2 steep, stepping y), each
    with its own decision parameter: unequal radii leave no single
    symmetric stepping rule covering the whole curve. 4-way symmetry
    rather than the circle's 8-way, since swapping x and y preserves
    the ellipse equation only when rx == ry.

    Integer-only: the decision parameters are scaled by 4 throughout to
    absorb the 0.25 term the derivation produces when evaluating the
    ellipse equation at a half-pixel-offset midpoint, the way the
    circle and line algorithms stay in Int rather than rounding floats.

    Args:
        canvas: Canvas to draw into.
        cx: Center x.
        cy: Center y.
        rx: Horizontal radius in pixels.
        ry: Vertical radius in pixels.
        color: Outline color.
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

    # Region 2: steep slope, step y. The decision parameter is
    # re-evaluated at the (x, y) region 1 left off at rather than
    # carried over: it's a different function of x, y.
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


def fill_ellipse(
    mut canvas: Canvas, cx: Int, cy: Int, rx: Int, ry: Int, color: Color
):
    """Fill a solid ellipse: fill_circle generalized to independent x/y
    radii, same span-per-row technique, each pixel set exactly once.
    The half-width per row shrinks monotonically as |dy| grows from 0
    to ry, so `dx` only decreases and never resets. The per-row bound
    is the ellipse equation multiplied through by rx^2 * ry^2 to stay
    integer-exact instead of taking a sqrt: `dx^2*ry^2 + dy^2*rx^2 <=
    rx^2*ry^2`.

    Hard-edged; see fill_ellipse_aa for a smooth edge.

    Args:
        canvas: Canvas to fill into.
        cx: Center x.
        cy: Center y.
        rx: Horizontal radius in pixels.
        ry: Vertical radius in pixels.
        color: Fill color.
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
    """Anti-aliased filled ellipse: fill_circle_aa generalized to
    independent x/y radii, same per-pixel supersampled analytic
    coverage, each output pixel visited once.

    Generalized by normalizing each sample's offset by (rx, ry) before
    testing against the unit circle: `(dx/rx)^2 + (dy/ry)^2 <= 1` is
    the ellipse equation in normalized form, and reduces to
    fill_circle_aa's `dx^2 + dy^2 <= r^2` when rx == ry.

    Same provably-inside/provably-outside fast path fill_circle_aa
    uses, in that normalized space: a pixel square's nearest and
    farthest normalized corners are its raw nearest/farthest corners,
    each divided by rx/ry before squaring.

    Args:
        canvas: Canvas to fill into.
        cx: Center x.
        cy: Center y.
        rx: Horizontal radius in pixels.
        ry: Vertical radius in pixels.
        color: Fill color.
        supersample: Sub-pixel grid side length per pixel (N -> N*N
            samples).
    """
    fill_ellipse_aa(
        canvas,
        Float64(cx),
        Float64(cy),
        Float64(rx),
        Float64(ry),
        color,
        supersample,
    )


def fill_ellipse_aa(
    mut canvas: Canvas,
    cx: Float64,
    cy: Float64,
    rx: Float64,
    ry: Float64,
    color: Color,
    supersample: Int = 4,
):
    """`fill_ellipse_aa` at a sub-pixel center and radii -- the same
    ellipse, placed and sized to a fraction of a pixel rather than
    snapped to the pixel grid.

    This is the real implementation; the whole-pixel overload above
    converts and calls it. An error ellipse or confidence region is
    sized from data, so its radii are almost never whole pixels, and
    rounding them changes the region it claims to show.

    `draw_ellipse_aa` (the outline) stays whole-pixel: it draws a fixed
    ~1px stroke, and `DrawTarget` documents it that way.

    Args:
        canvas: Canvas to fill into.
        cx: Center x, sub-pixel.
        cy: Center y, sub-pixel.
        rx: Horizontal radius in pixels, sub-pixel.
        ry: Vertical radius in pixels, sub-pixel.
        color: Fill color.
        supersample: Sub-pixel grid side length per pixel (N -> N*N
            samples).
    """
    if rx <= 0.0 or ry <= 0.0:
        canvas.set_pixel(_round_to_int(cx), _round_to_int(cy), color)
        return

    var rx_f = rx
    var ry_f = ry
    var n = supersample
    var total_samples = n * n
    var step = 1.0 / Float64(n)

    # The membership test is (x/rx)^2 + (y/ry)^2 <= 1, multiplied
    # through by (rx*ry)^2 to give x^2*ry^2 + y^2*rx^2 <= (rx*ry)^2.
    # Speed is the reason that survives sub-pixel radii: the divided
    # form runs four divisions per pixel in the bounds test and two
    # more per sub-sample, and division is an order of magnitude more
    # expensive than multiply.
    #
    # It used to be exact as well, back when radii were necessarily
    # whole pixels: every term was then a product of Float64-exact
    # values staying far below 2^53, so the comparison carried no
    # rounding at all. A sub-pixel radius ends that -- but the
    # multiplied form still rounds no more than the divided one would,
    # so allowing it regressed nothing.
    var rx2 = rx_f * rx_f
    var ry2 = ry_f * ry_f
    var limit = rx2 * ry2

    # Widened outward to whole pixels, so a pixel the ellipse only
    # partly covers is still visited.
    for py in range(Int(floor(cy - ry)) - 1, Int(ceil(cy + ry)) + 2):
        for px in range(Int(floor(cx - rx)) - 1, Int(ceil(cx + rx)) + 2):
            var dx = abs(Float64(px) - cx)
            var dy = abs(Float64(py) - cy)

            var near_x = max(0.0, dx - 0.5)
            var near_y = max(0.0, dy - 0.5)
            if near_x * near_x * ry2 + near_y * near_y * rx2 > limit:
                continue  # whole pixel square is outside the ellipse

            var far_x = dx + 0.5
            var far_y = dy + 0.5
            if far_x * far_x * ry2 + far_y * far_y * rx2 <= limit:
                canvas.set_pixel(px, py, color)  # whole pixel square is inside
                continue

            var covered = 0
            for sy in range(n):
                var fy = Float64(py) - cy + (Float64(sy) + 0.5) * step - 0.5
                var fy_term = fy * fy * rx2
                for sx in range(n):
                    var fx = Float64(px) - cx + (Float64(sx) + 0.5) * step - 0.5
                    if fx * fx * ry2 + fy_term <= limit:
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

    Unlike the circle case, no single distance value serves both
    boundaries: draw_circle_aa tests one `d2` against `inner2`/`outer2`
    because a circle's inner and outer rings are concentric offsets of
    the same curve, but an ellipse's `(rx-0.5, ry-0.5)` and
    `(rx+0.5, ry+0.5)` rings are two different ellipses. So each sample
    is tested against both, in their own normalized space -- strictly
    inside the outer, not strictly inside the inner:

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

    Args:
        canvas: Canvas to draw into.
        cx: Center x.
        cy: Center y.
        rx: Horizontal radius in pixels.
        ry: Vertical radius in pixels.
        color: Outline color.
        supersample: Sub-pixel grid side length per pixel (N -> N*N
            samples).
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

            # draw_circle_aa's "provably fully outside the ring band"
            # skip, generalized to the two independent normalized-space
            # tests above: no shared distance here either, so each
            # direction gets its own nearest/farthest check.
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
