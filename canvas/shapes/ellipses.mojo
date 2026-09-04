"""Ellipse drawing: midpoint-algorithm hard-edged outline/fill
(draw_ellipse/fill_ellipse, independent-x/y-radii generalizations of
canvas.shapes.circles' draw_circle/fill_circle) and supersampled
analytic-coverage anti-aliased variants (draw_ellipse_aa/
fill_ellipse_aa) -- see canvas.shapes.lines for the hard-edged
vs. `_aa` naming convention this follows.
"""

from std.math import ceil, floor, sqrt

from canvas.color import Color
from canvas.buffer import Canvas
from canvas.geometry import _round_to_int
from canvas.aa_crossing import _CoverageAlpha


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
    (region 1 shallow, stepping x; region 2 steep, stepping y), each with
    its own decision parameter, since unequal radii leave no single
    symmetric stepping rule for the whole curve. 4-way symmetry, not the
    circle's 8-way: swapping x and y preserves the ellipse equation only
    when rx == ry.

    Integer-only. The decision parameters are scaled by 4 throughout to
    absorb the 0.25 term from evaluating the ellipse equation at a
    half-pixel-offset midpoint.

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
    radii, one span per row, each pixel set exactly once. The half-width
    per row shrinks monotonically as |dy| grows, so `dx` only decreases.
    The per-row bound is the ellipse equation multiplied through by
    rx^2 * ry^2 to stay integer-exact instead of taking a sqrt:
    `dx^2*ry^2 + dy^2*rx^2 <= rx^2*ry^2`.

    Hard-edged; fill_ellipse_aa has a smooth edge.

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

    Each sample's offset is normalized by (rx, ry) before testing
    against the unit circle: `(dx/rx)^2 + (dy/ry)^2 <= 1`, which reduces
    to fill_circle_aa's `dx^2 + dy^2 <= r^2` when rx == ry. The
    provably-inside/outside fast path works in that normalized space,
    where a pixel square's nearest and farthest normalized corners are
    its raw ones divided by rx/ry.

    Args:
        canvas: Canvas to fill into.
        cx: Center x.
        cy: Center y.
        rx: Horizontal radius in pixels.
        ry: Vertical radius in pixels.
        color: Fill color.
        supersample: Sub-pixel grid side length per pixel (N -> N*N samples).
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


# Below this horizontal radius the interior span is not worth solving
# for -- same value, same reasoning and same caveat as
# fill_circle_aa's, set by benchmark (#84).
comptime _MIN_SPAN_RADIUS = 8.0


def _pixel_inside(
    px: Int, cx: Float64, far_y_term: Float64, ry2: Float64, limit: Float64
) -> Bool:
    """Whether the pixel square centred at `px`, on a row whose
    `far_y^2 * rx^2` term is `far_y_term`, lies entirely within the
    ellipse.
    """
    var far_x = abs(Float64(px) - cx) + 0.5
    return far_x * far_x * ry2 + far_y_term <= limit


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
    converts and calls it. `draw_ellipse_aa` stays whole-pixel, since it
    draws a fixed ~1px stroke.

    Args:
        canvas: Canvas to fill into.
        cx: Center x, sub-pixel.
        cy: Center y, sub-pixel.
        rx: Horizontal radius in pixels, sub-pixel.
        ry: Vertical radius in pixels, sub-pixel.
        color: Fill color.
        supersample: Sub-pixel grid side length per pixel (N -> N*N samples).
    """
    if rx <= 0.0 or ry <= 0.0:
        canvas.set_pixel(_round_to_int(cx), _round_to_int(cy), color)
        return

    var rx_f = rx
    var ry_f = ry
    var n = supersample
    var coverage_alpha = _CoverageAlpha(n * n, color.a)
    var step = 1.0 / Float64(n)

    # The membership test is (x/rx)^2 + (y/ry)^2 <= 1, multiplied
    # through by (rx*ry)^2 to give x^2*ry^2 + y^2*rx^2 <= (rx*ry)^2:
    # the divided form runs four divisions per pixel in the bounds test
    # and two more per sub-sample. With whole-pixel radii every term is
    # exact in Float64; with sub-pixel radii the multiplied form rounds
    # no more than the divided one would.
    var rx2 = rx_f * rx_f
    var ry2 = ry_f * ry_f
    var limit = rx2 * ry2

    # Widened outward to whole pixels, so a pixel the ellipse only
    # partly covers is still visited.
    var lo_x = Int(floor(cx - rx)) - 1
    var hi_x = Int(ceil(cx + rx)) + 2
    var lo_y = Int(floor(cy - ry)) - 1
    var hi_y = Int(ceil(cy + ry)) + 2

    # Solving the interior span costs a sqrt and some endpoint nudging
    # per row, which only pays off once a row's interior run is long
    # enough to matter -- and run length is governed by the horizontal
    # radius. Same threshold and same reasoning as fill_circle_aa.
    var solve_span = rx >= _MIN_SPAN_RADIUS

    for py in range(lo_y, hi_y):
        var dy = abs(Float64(py) - cy)
        var near_y = max(0.0, dy - 0.5)
        var far_y = dy + 0.5
        var far_y_term = far_y * far_y * rx2
        var near_y_term = near_y * near_y * rx2

        # The run of provably-interior pixels on this row, in closed
        # form. A pixel is wholly inside when its farthest corner is:
        #
        #   far_x^2 * ry^2 + far_y^2 * rx^2 <= (rx*ry)^2
        #
        # which for a fixed row rearranges to
        #
        #   |dx| <= sqrt(limit - far_y^2 * rx^2) / ry - 0.5
        #
        # so the whole interior is one bulk fill and only the pixels at
        # the two ends need sampling. This is fill_circle_aa's span
        # solve generalized to independent radii; see there for the
        # measurements that motivated it.
        var span_lo = 1
        var span_hi = 0  # empty unless this row reaches the interior
        if solve_span:
            var interior = limit - far_y_term
            if interior > 0.0:
                var half = sqrt(interior) / ry_f - 0.5
                if half >= 0.0:
                    span_lo = Int(ceil(cx - half))
                    span_hi = Int(floor(cx + half))

                    # sqrt/ceil/floor on a float expression can land a
                    # step either side of the true boundary, so both
                    # ends are nudged against the exact test the
                    # per-pixel path below applies -- what keeps the two
                    # routes bit-for-bit identical rather than close.
                    while span_lo <= span_hi and not _pixel_inside(
                        span_lo, cx, far_y_term, ry2, limit
                    ):
                        span_lo += 1
                    while span_lo > lo_x and _pixel_inside(
                        span_lo - 1, cx, far_y_term, ry2, limit
                    ):
                        span_lo -= 1
                    while span_hi >= span_lo and not _pixel_inside(
                        span_hi, cx, far_y_term, ry2, limit
                    ):
                        span_hi -= 1
                    while span_hi < hi_x - 1 and _pixel_inside(
                        span_hi + 1, cx, far_y_term, ry2, limit
                    ):
                        span_hi += 1

                    if span_lo < lo_x:
                        span_lo = lo_x
                    if span_hi > hi_x - 1:
                        span_hi = hi_x - 1

        var edge_end = hi_x
        var edge_resume = hi_x
        if span_lo <= span_hi:
            var region = canvas.effective_fill_rect(
                span_lo, py, span_hi - span_lo + 1, 1
            )
            canvas._fill_region(
                region[0], region[1], region[2], region[3], color
            )
            edge_end = span_lo
            edge_resume = span_hi + 1

        # Everything the run did not cover, as two explicit ranges
        # rather than a per-pixel skip test -- see fill_circle_aa for
        # why, including why the body is inline rather than a helper.
        for seg in range(2):
            var seg_lo = lo_x if seg == 0 else edge_resume
            var seg_hi = edge_end if seg == 0 else hi_x
            for px in range(seg_lo, seg_hi):
                var dx = abs(Float64(px) - cx)
                var near_x = max(0.0, dx - 0.5)
                if near_x * near_x * ry2 + near_y_term > limit:
                    continue  # whole pixel square is outside the ellipse

                var far_x = dx + 0.5
                if far_x * far_x * ry2 + far_y_term <= limit:
                    canvas.set_pixel(px, py, color)  # wholly inside
                    continue

                var covered = 0
                for sy in range(n):
                    var fy = Float64(py) - cy + (Float64(sy) + 0.5) * step - 0.5
                    var fy_term = fy * fy * rx2
                    for sx in range(n):
                        var fx = (
                            Float64(px) - cx + (Float64(sx) + 0.5) * step - 0.5
                        )
                        if fx * fx * ry2 + fy_term <= limit:
                            covered += 1
                if covered > 0:
                    canvas.set_pixel(
                        px,
                        py,
                        Color(
                            color.r, color.g, color.b, coverage_alpha[covered]
                        ),
                    )


def draw_ellipse_aa(
    mut canvas: Canvas,
    cx: Int,
    cy: Int,
    rx: Int,
    ry: Int,
    color: Color,
    supersample: Int = 4,
    width: Float64 = 1.0,
):
    """Anti-aliased ellipse outline, `width` pixels wide (default 1) --
    draw_circle_aa's generalization to independent x/y radii.

    Args:
        canvas: Canvas to draw into.
        cx: Center x.
        cy: Center y.
        rx: Horizontal radius in pixels, to the middle of the stroke.
        ry: Vertical radius in pixels, to the middle of the stroke.
        color: Outline color.
        supersample: Sub-pixel grid side length per pixel (N -> N*N samples).
        width: Stroke width in pixels.
    """
    if rx <= 0 or ry <= 0:
        canvas.set_pixel(cx, cy, color)
        return
    draw_ellipse_aa(
        canvas,
        Float64(cx),
        Float64(cy),
        Float64(rx),
        Float64(ry),
        color,
        supersample,
        width,
    )


def draw_ellipse_aa(
    mut canvas: Canvas,
    cx: Float64,
    cy: Float64,
    rx: Float64,
    ry: Float64,
    color: Color,
    supersample: Int = 4,
    width: Float64 = 1.0,
):
    """`draw_ellipse_aa` at a sub-pixel center and radii; the
    whole-pixel overload above converts and calls this.

    No single distance value serves both boundaries here: an ellipse's
    `(rx-w/2, ry-w/2)` and `(rx+w/2, ry+w/2)` rings are two different
    ellipses, where a circle's are concentric offsets of one curve. Each
    sample is tested against both in their own normalized space:

        (dx/outer_rx)^2 + (dy/outer_ry)^2 <  1   (strictly inside outer)
        (dx/inner_rx)^2 + (dy/inner_ry)^2 >= 1   (on or outside inner)

    Applying +/-w/2 to rx and ry independently, rather than offsetting
    along the ellipse's normal, makes the ring's width vary around the
    ellipse: exactly `width` at the four axis extremes, narrower
    elsewhere. A normal-offset ring would need the perimeter
    parameterization. A stroke wider than the shorter diameter leaves
    no hole and draws the filled ellipse.

    Args:
        canvas: Canvas to draw into.
        cx: Center x, sub-pixel.
        cy: Center y, sub-pixel.
        rx: Horizontal radius in pixels, to the middle of the stroke.
        ry: Vertical radius in pixels, to the middle of the stroke.
        color: Outline color.
        supersample: Sub-pixel grid side length per pixel (N -> N*N samples).
        width: Stroke width in pixels.
    """
    if rx <= 0.0 or ry <= 0.0:
        canvas.set_pixel(_round_to_int(cx), _round_to_int(cy), color)
        return

    var half = width / 2.0
    var outer_rx = rx + half
    var outer_ry = ry + half
    var inner_rx = rx - half
    var inner_ry = ry - half
    var has_hole = inner_rx > 0.0 and inner_ry > 0.0
    var n = supersample
    var coverage_alpha = _CoverageAlpha(n * n, color.a)
    var step = 1.0 / Float64(n)

    for py in range(Int(floor(cy - outer_ry)), Int(ceil(cy + outer_ry)) + 1):
        for px in range(
            Int(floor(cx - outer_rx)), Int(ceil(cx + outer_rx)) + 1
        ):
            var dx = abs(Float64(px) - cx)
            var dy = abs(Float64(py) - cy)

            # draw_circle_aa's "provably fully outside the ring band"
            # skip, generalized to the two independent normalized-space
            # tests above: no shared distance here either, so each
            # direction gets its own nearest/farthest check.
            var near_onx = max(0.0, dx - 0.5) / outer_rx
            var near_ony = max(0.0, dy - 0.5) / outer_ry
            if near_onx * near_onx + near_ony * near_ony >= 1.0:
                continue  # whole pixel square is outside the outer ellipse

            if has_hole:
                var far_inx = (dx + 0.5) / inner_rx
                var far_iny = (dy + 0.5) / inner_ry
                if far_inx * far_inx + far_iny * far_iny < 1.0:
                    continue  # whole pixel square is inside the inner ellipse

            var covered = 0
            for sy in range(n):
                var fy = Float64(py) - cy + (Float64(sy) + 0.5) * step - 0.5
                for sx in range(n):
                    var fx = Float64(px) - cx + (Float64(sx) + 0.5) * step - 0.5
                    var onx = fx / outer_rx
                    var ony = fy / outer_ry
                    var inside_outer = onx * onx + ony * ony < 1.0
                    var inside_inner = False
                    if has_hole:
                        var inx = fx / inner_rx
                        var iny = fy / inner_ry
                        inside_inner = inx * inx + iny * iny < 1.0
                    if inside_outer and not inside_inner:
                        covered += 1
            if covered > 0:
                canvas.set_pixel(
                    px,
                    py,
                    color.with_alpha(coverage_alpha[covered]),
                )
