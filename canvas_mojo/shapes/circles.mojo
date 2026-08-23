"""Circle drawing: midpoint-algorithm hard-edged outline/fill
(draw_circle/fill_circle) and supersampled analytic-coverage
anti-aliased variants (draw_circle_aa/fill_circle_aa) -- see
canvas_mojo.shapes.lines's own module docstring for the hard-edged
vs. `_aa` naming convention this follows.
"""

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas


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

    A ring this thin (exactly 1 unit wide) never has a pixel square
    that's *provably fully inside* it the way fill_circle_aa's own
    fast path finds for a filled disk -- there's no fill_circle_aa-
    style skip to add here. But most of this loop's own bounding
    square -- everything well inside the hole, or well outside the
    outer edge, both far more area than the thin ring itself for any
    real radius -- *is* provably fully outside, via the same AABB
    nearest/farthest-point test fill_ring_sector_aa's own docstring
    describes; skipping those pixels here is the real win for a large
    circle outline.
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
            var dx = abs(Float64(px - cx))
            var dy = abs(Float64(py - cy))

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
