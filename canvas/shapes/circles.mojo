"""Circle drawing: midpoint-algorithm hard-edged outline/fill
(draw_circle/fill_circle) and supersampled analytic-coverage
anti-aliased variants (draw_circle_aa/fill_circle_aa) -- see
canvas.shapes.lines for the hard-edged
vs. `_aa` naming convention this follows.
"""

from std.math import ceil, floor, sqrt

from canvas.color import Color
from canvas.buffer import Canvas
from canvas.geometry import _round_to_int
from canvas.aa_crossing import _CoverageAlpha


def draw_circle(
    mut canvas: Canvas, cx: Int, cy: Int, radius: Int, color: Color
):
    """The midpoint circle algorithm: integer-only, plotting via 8-way
    symmetry around the center.

    At y==0 and x==y several of the 8 symmetric expressions collapse
    onto one pixel -- (cx+y,cy+x) and (cx-y,cy+x) both become (cx,cy+x)
    when y==0 -- so plotting all 8 unconditionally would set_pixel there
    more than once and multiply-blend a translucent color.

    Args:
        canvas: Canvas to draw into.
        cx: Center x.
        cy: Center y.
        radius: Circle radius in pixels.
        color: Outline color.
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


def fill_circle(
    mut canvas: Canvas, cx: Int, cy: Int, radius: Int, color: Color
):
    """Fill a solid disk, one horizontal span per row, so each pixel is
    set exactly once and a translucent color never double-blends.

    Hard-edged; fill_circle_aa has a smooth edge.

    Args:
        canvas: Canvas to fill into.
        cx: Center x.
        cy: Center y.
        radius: Circle radius in pixels.
        color: Fill color.
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

    Pixel (px, py) is centered AT (px, py), the convention the hard-edged
    draw_circle/fill_circle use, not a unit square with (px, py) at its
    corner. That is what makes supersample=1 degenerate to the hard-edged
    decision pixel for pixel.

    Before sampling, the pixel's square ([px-0.5, px+0.5] x
    [py-0.5, py+0.5]) is tested for being provably wholly inside or
    outside the disk, via its nearest and farthest points from the center
    (point-to-AABB min/max distance). Either way all n*n samples would
    agree, so coverage is 0 or full without visiting the grid, leaving
    the per-sample loop to the O(radius) pixels straddling the edge
    rather than all O(radius^2).

    Args:
        canvas: Canvas to fill into.
        cx: Center x.
        cy: Center y.
        radius: Circle radius in pixels.
        color: Fill color.
        supersample: Sub-pixel grid side length per pixel (N -> N*N samples).
    """
    fill_circle_aa(
        canvas,
        Float64(cx),
        Float64(cy),
        Float64(radius),
        color,
        supersample,
    )


# Below this radius the interior span is not worth solving for: the
# sqrt, the endpoint nudging and the bulk-fill call cost more per row
# than testing the handful of pixels the row contains. Set by benchmark
# (#83, which has the numbers) -- re-benchmark the small-marker and
# large-disk cases before changing it.
comptime _MIN_SPAN_RADIUS = 8.0


def _pixel_inside(px: Int, cx: Float64, far_dy: Float64, r2: Float64) -> Bool:
    """Whether the pixel square centred at `px` on a row whose farthest
    vertical reach is `far_dy` lies entirely within the disk.
    """
    var far_dx = abs(Float64(px) - cx) + 0.5
    return far_dx * far_dx + far_dy * far_dy <= r2


def fill_circle_aa(
    mut canvas: Canvas,
    cx: Float64,
    cy: Float64,
    radius: Float64,
    color: Color,
    supersample: Int = 4,
):
    """`fill_circle_aa` at a sub-pixel center and radius -- the same
    disk, placed and sized to a fraction of a pixel rather than snapped
    to the pixel grid.

    This is the real implementation; the whole-pixel overload above
    converts and calls it.

    Args:
        canvas: Canvas to fill into.
        cx: Center x, sub-pixel.
        cy: Center y, sub-pixel.
        radius: Circle radius in pixels, sub-pixel.
        color: Fill color.
        supersample: Sub-pixel grid side length per pixel (N -> N*N samples).
    """
    if radius <= 0.0:
        canvas.set_pixel(_round_to_int(cx), _round_to_int(cy), color)
        return

    var r2 = radius * radius
    var n = supersample
    var coverage_alpha = _CoverageAlpha(n * n, color.a)
    var step = 1.0 / Float64(n)

    # Widened outward to whole pixels, so a pixel the disk only partly
    # covers is still visited.
    var lo_x = Int(floor(cx - radius)) - 1
    var hi_x = Int(ceil(cx + radius)) + 2
    var lo_y = Int(floor(cy - radius)) - 1
    var hi_y = Int(ceil(cy + radius)) + 2

    var solve_span = radius >= _MIN_SPAN_RADIUS

    for py in range(lo_y, hi_y):
        var dy = abs(Float64(py) - cy)
        var near_dy = max(0.0, dy - 0.5)
        var far_dy = dy + 0.5

        # The run of provably-interior pixels on this row, solved rather
        # than discovered one pixel at a time.
        #
        # A pixel is wholly inside when its farthest corner is within
        # the disk: (|dx| + 0.5)^2 + (|dy| + 0.5)^2 <= r^2. For a fixed
        # row that rearranges to |dx| <= sqrt(r^2 - far_dy^2) - 0.5, a
        # closed-form span -- so the interior is written in one bulk
        # fill and only the ends need testing.
        var span_lo = 1
        var span_hi = 0  # empty unless this row reaches the interior
        if solve_span:
            var interior_r2 = r2 - far_dy * far_dy
            if interior_r2 > 0.0:
                var half = sqrt(interior_r2) - 0.5
                if half >= 0.0:
                    span_lo = Int(ceil(cx - half))
                    span_hi = Int(floor(cx + half))

                    # sqrt/ceil/floor on a float expression can land a
                    # step either side of the true boundary, so both
                    # ends are nudged against the exact test the
                    # per-pixel path below applies. That is what keeps
                    # the two routes bit-for-bit identical rather than
                    # merely close.
                    while span_lo <= span_hi and not _pixel_inside(
                        span_lo, cx, far_dy, r2
                    ):
                        span_lo += 1
                    while span_lo > lo_x and _pixel_inside(
                        span_lo - 1, cx, far_dy, r2
                    ):
                        span_lo -= 1
                    while span_hi >= span_lo and not _pixel_inside(
                        span_hi, cx, far_dy, r2
                    ):
                        span_hi -= 1
                    while span_hi < hi_x - 1 and _pixel_inside(
                        span_hi + 1, cx, far_dy, r2
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

        # Everything the run did not cover: the segment before it and
        # the segment after. Two explicit ranges rather than one scan
        # with a per-pixel "am I in the span" test, and the body inline
        # rather than in a helper called twice -- both benchmarked (#83),
        # both slower the other way. With no run
        # (edge_end == edge_resume == hi_x) the first segment is the
        # whole row and the second is empty.
        for seg in range(2):
            var seg_lo = lo_x if seg == 0 else edge_resume
            var seg_hi = edge_end if seg == 0 else hi_x
            for px in range(seg_lo, seg_hi):
                var dx = abs(Float64(px) - cx)
                var near_dx = max(0.0, dx - 0.5)
                if near_dx * near_dx + near_dy * near_dy > r2:
                    continue  # whole pixel square is outside the disk

                # Wholly inside, so every sample would agree. Reached
                # for real work only below _MIN_SPAN_RADIUS, where the
                # span solve is skipped and this is what keeps a small
                # disk's interior off the sampling grid.
                var far_dx = dx + 0.5
                if far_dx * far_dx + far_dy * far_dy <= r2:
                    canvas.set_pixel(px, py, color)
                    continue

                var covered = 0
                for sy in range(n):
                    var fy = Float64(py) - cy + (Float64(sy) + 0.5) * step - 0.5
                    for sx in range(n):
                        var fx = (
                            Float64(px) - cx + (Float64(sx) + 0.5) * step - 0.5
                        )
                        if fx * fx + fy * fy <= r2:
                            covered += 1
                if covered > 0:
                    canvas.set_pixel(
                        px,
                        py,
                        Color(
                            color.r, color.g, color.b, coverage_alpha[covered]
                        ),
                    )


def draw_circle_aa(
    mut canvas: Canvas,
    cx: Int,
    cy: Int,
    radius: Int,
    color: Color,
    supersample: Int = 4,
    width: Float64 = 1.0,
):
    """Anti-aliased circle outline, `width` pixels wide (default 1).

    fill_circle_aa's supersampled coverage technique, including the
    pixel-centered-at-(px,py) convention, testing each sub-sample against
    a ring (radius +/- width/2) rather than the filled disk.

    Args:
        canvas: Canvas to draw into.
        cx: Center x.
        cy: Center y.
        radius: Circle radius in pixels, to the middle of the stroke.
        color: Outline color.
        supersample: Sub-pixel grid side length per pixel (N -> N*N samples).
        width: Stroke width in pixels.
    """
    if radius <= 0:
        canvas.set_pixel(cx, cy, color)
        return
    draw_circle_aa(
        canvas,
        Float64(cx),
        Float64(cy),
        Float64(radius),
        color,
        supersample,
        width,
    )


def draw_circle_aa(
    mut canvas: Canvas,
    cx: Float64,
    cy: Float64,
    radius: Float64,
    color: Color,
    supersample: Int = 4,
    width: Float64 = 1.0,
):
    """`draw_circle_aa` at a sub-pixel center and radius -- the same
    ring, placed and sized to a fraction of a pixel rather than snapped
    to the pixel grid.

    This is the real implementation; the whole-pixel overload above
    converts and calls it. A stroke wider than the diameter leaves no
    hole and draws a disk. A ring never contains a whole pixel square
    unless it is wide, so the only fast path is the "provably outside"
    AABB nearest/farthest-point test fill_circle_aa uses.

    Args:
        canvas: Canvas to draw into.
        cx: Center x, sub-pixel.
        cy: Center y, sub-pixel.
        radius: Circle radius in pixels, to the middle of the stroke.
        color: Outline color.
        supersample: Sub-pixel grid side length per pixel (N -> N*N samples).
        width: Stroke width in pixels.
    """
    if radius <= 0.0:
        canvas.set_pixel(_round_to_int(cx), _round_to_int(cy), color)
        return

    var half = width / 2.0
    var inner = max(0.0, radius - half)
    var outer = radius + half
    var inner2 = inner * inner
    var outer2 = outer * outer
    var n = supersample
    var coverage_alpha = _CoverageAlpha(n * n, color.a)
    var step = 1.0 / Float64(n)

    for py in range(Int(floor(cy - outer)), Int(ceil(cy + outer)) + 1):
        for px in range(Int(floor(cx - outer)), Int(ceil(cx + outer)) + 1):
            var dx = abs(Float64(px) - cx)
            var dy = abs(Float64(py) - cy)

            var near_dx = max(0.0, dx - 0.5)
            var near_dy = max(0.0, dy - 0.5)
            if near_dx * near_dx + near_dy * near_dy >= outer2:
                continue  # whole pixel square is outside the outer edge

            var far_dx = dx + 0.5
            var far_dy = dy + 0.5
            if far_dx * far_dx + far_dy * far_dy < inner2:
                continue  # whole pixel square is inside the hole

            var covered = 0
            for sy in range(n):
                var fy = Float64(py) - cy + (Float64(sy) + 0.5) * step - 0.5
                for sx in range(n):
                    var fx = Float64(px) - cx + (Float64(sx) + 0.5) * step - 0.5
                    var d2 = fx * fx + fy * fy
                    if d2 >= inner2 and d2 < outer2:
                        covered += 1
            if covered > 0:
                canvas.set_pixel(
                    px,
                    py,
                    Color(color.r, color.g, color.b, coverage_alpha[covered]),
                )
