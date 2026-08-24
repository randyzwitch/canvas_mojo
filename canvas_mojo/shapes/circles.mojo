"""Circle drawing: midpoint-algorithm hard-edged outline/fill
(draw_circle/fill_circle) and supersampled analytic-coverage
anti-aliased variants (draw_circle_aa/fill_circle_aa) -- see
canvas_mojo.shapes.lines for the hard-edged
vs. `_aa` naming convention this follows.
"""

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas


def draw_circle(mut canvas: Canvas, cx: Int, cy: Int, radius: Int, color: Color):
    """The midpoint circle algorithm: integer-only, plotting via 8-way
    symmetry around the center.

    At y==0 (the first iteration) and x==y (the diagonal crossing),
    several of the 8 symmetric expressions collapse onto one pixel --
    (cx+y,cy+x) and (cx-y,cy+x) both become (cx,cy+x) when y==0.
    Plotting all 8 unconditionally would set_pixel there more than
    once, double- or quadruple-blending a translucent color.
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
    """Fill a solid disk, one horizontal span per row, so each pixel is
    set exactly once and a translucent color never double-blends --
    unlike reusing draw_circle's 8-way symmetry across rows, which
    touches some rows twice near the diagonal octant boundary.

    Hard-edged; see fill_circle_aa for a smooth edge.
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
    tests each sub-sample analytically against the true real-valued
    disk -- no temp canvas, just a coverage fraction turned into that
    pixel's alpha. Each output pixel is visited exactly once.

    Pixel (px, py) is treated as centered AT (px, py), the convention
    the hard-edged draw_circle/fill_circle use, not as a unit square
    with (px, py) at its corner. That's what makes supersample=1
    degenerate to the hard-edged decision pixel for pixel, and keeps
    this circle centered on the same point given identical
    (cx, cy, radius).

    Before sampling, checks whether the pixel's square
    ([px-0.5, px+0.5] x [py-0.5, py+0.5]) is provably entirely inside
    or outside the disk, via that square's nearest and farthest points
    from the center -- standard point-to-AABB min/max distance. Either
    way every one of the n*n samples would agree, giving coverage 0 or
    full alpha without visiting the grid. Most of a large circle's
    bounding box is interior, so the per-sample loop then runs only for
    the O(radius) pixels straddling the edge, not all O(radius^2).
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
                # Whole pixel square is inside the disk: the coverage
                # every sample would agree on.
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

    fill_circle_aa's supersampled analytic-coverage technique,
    including the pixel-centered-at-(px,py) convention, but testing
    each sub-sample against a thin ring (radius +/- 0.5) rather than
    the filled disk.

    A 1-unit-wide ring never has a pixel square provably fully
    *inside* it, so fill_circle_aa's inside fast path has no analog
    here. Most of the bounding square -- well inside the hole or well
    outside the outer edge, both far larger than the ring itself at any
    real radius -- is provably outside, through the same AABB
    nearest/farthest-point test, and skipping those is the win for a
    large outline.
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
