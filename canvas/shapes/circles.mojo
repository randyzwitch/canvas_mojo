"""Circle drawing: midpoint-algorithm hard-edged outline/fill
(draw_circle/fill_circle) and exact-area anti-aliased variants
(draw_circle_aa/fill_circle_aa) -- see canvas.shapes.lines for the
hard-edged vs. `_aa` naming convention this follows.

The `_aa` fills describe the disk as a path and hand it to
`fill_path_aa` under `FillRule.NONZERO`, so they land on the same
exact-area rasterizer (`canvas.aa_area`) as every other nonzero fill
rather than carrying a sampler of their own (#275).
"""

from std.math import ceil, floor, sqrt

from canvas.color import Color
from canvas.buffer import Canvas
from canvas.geometry import round_to_int
from canvas.fill_rule import FillRule
from canvas.path import (
    fill_path,
    fill_path_aa,
    stroke_path,
    stroke_path_aa,
    _ellipse_path,
)
from canvas.aa_crossing import _CoverageAlpha
from canvas.shapes.arcs import _ellipse_fpoints
from canvas.shapes.polygon_fill import _fill_polygon_aa_device


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
    if canvas.has_transform():
        var m = canvas.current_transform()
        if m.is_similarity():
            var p = m.apply(Float64(cx), Float64(cy))
            _draw_circle_device(
                canvas,
                round_to_int(p.x),
                round_to_int(p.y),
                round_to_int(Float64(radius) * m.scale_factor()),
                color,
            )
            return
        stroke_path(
            canvas,
            _ellipse_path(
                Float64(cx), Float64(cy), Float64(radius), Float64(radius)
            ),
            color,
        )
        return
    _draw_circle_device(canvas, cx, cy, radius, color)


def _draw_circle_device(
    mut canvas: Canvas, cx: Int, cy: Int, radius: Int, color: Color
):
    """`draw_circle` for device-space arguments: the body every
    call lands in. It has no transform check of its own, so its
    loops compile with nothing ahead of them and it never calls
    back into the public function.
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
    if canvas.has_transform():
        var m = canvas.current_transform()
        if m.is_similarity():
            var p = m.apply(Float64(cx), Float64(cy))
            _fill_circle_device(
                canvas,
                round_to_int(p.x),
                round_to_int(p.y),
                round_to_int(Float64(radius) * m.scale_factor()),
                color,
            )
            return
        fill_path(
            canvas,
            _ellipse_path(
                Float64(cx), Float64(cy), Float64(radius), Float64(radius)
            ),
            color,
        )
        return
    _fill_circle_device(canvas, cx, cy, radius, color)


def _fill_circle_device(
    mut canvas: Canvas, cx: Int, cy: Int, radius: Int, color: Color
):
    """`fill_circle` for device-space arguments: the body every
    call lands in. It has no transform check of its own, so its
    loops compile with nothing ahead of them and it never calls
    back into the public function.
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
    if canvas.has_transform():
        var m = canvas.current_transform()
        if m.is_similarity():
            var p = m.apply(Float64(cx), Float64(cy))
            var saved = canvas._take_transform()
            fill_circle_aa(
                canvas,
                p.x,
                p.y,
                Float64(radius) * m.scale_factor(),
                color,
                supersample,
            )
            canvas._set_transform(saved)
            return
        fill_path_aa(
            canvas,
            _ellipse_path(
                Float64(cx), Float64(cy), Float64(radius), Float64(radius)
            ),
            color,
            FillRule.NONZERO,
        )
        return
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
    """Whether the pixel square centered at `px` on a row whose farthest
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
    if canvas.has_transform():
        var m = canvas.current_transform()
        if m.is_similarity():
            var p = m.apply(Float64(cx), Float64(cy))
            _fill_circle_aa_device(
                canvas,
                p.x,
                p.y,
                Float64(radius) * m.scale_factor(),
                color,
                supersample,
            )
            return
        fill_path_aa(
            canvas,
            _ellipse_path(
                Float64(cx), Float64(cy), Float64(radius), Float64(radius)
            ),
            color,
            FillRule.NONZERO,
        )
        return
    _fill_circle_aa_device(canvas, cx, cy, radius, color, supersample)


def _fill_circle_aa_device(
    mut canvas: Canvas,
    cx: Float64,
    cy: Float64,
    radius: Float64,
    color: Color,
    supersample: Int = 4,
):
    """`fill_circle_aa` for device-space arguments: the body every
    call lands in.

    The disk goes to `fill_path_aa` under `FillRule.NONZERO`, which is
    `canvas.aa_area`'s exact-area accumulation -- each pixel's real
    covered fraction in 256 levels. The sampled grid this used to walk
    resolved 17, which measured as up to 15 levels of error against a
    16x reference where the accumulation is within 6 (#275).
    `supersample` is accepted and unused, as it is on every other
    nonzero fill.

    A single closed convex outline winds once, so nonzero and even-odd
    describe the same region here; the rule only picks the rasterizer.
    """
    if radius <= 0.0:
        canvas.set_pixel(round_to_int(cx), round_to_int(cy), color)
        return
    _fill_polygon_aa_device(
        canvas,
        _ellipse_fpoints(cx, cy, radius, radius),
        color,
        FillRule.NONZERO,
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
    if canvas.has_transform():
        var m = canvas.current_transform()
        if m.is_similarity():
            var p = m.apply(Float64(cx), Float64(cy))
            var s = m.scale_factor()
            var saved = canvas._take_transform()
            draw_circle_aa(
                canvas,
                p.x,
                p.y,
                Float64(radius) * s,
                color,
                supersample,
                width * s,
            )
            canvas._set_transform(saved)
            return
        stroke_path_aa(
            canvas,
            _ellipse_path(
                Float64(cx), Float64(cy), Float64(radius), Float64(radius)
            ),
            color,
            width,
            supersample,
        )
        return
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
    if canvas.has_transform():
        var m = canvas.current_transform()
        if m.is_similarity():
            var p = m.apply(Float64(cx), Float64(cy))
            var s = m.scale_factor()
            _draw_circle_aa_device(
                canvas,
                p.x,
                p.y,
                Float64(radius) * s,
                color,
                supersample,
                width * s,
            )
            return
        stroke_path_aa(
            canvas,
            _ellipse_path(
                Float64(cx), Float64(cy), Float64(radius), Float64(radius)
            ),
            color,
            width,
            supersample,
        )
        return
    _draw_circle_aa_device(canvas, cx, cy, radius, color, supersample, width)


def _draw_circle_aa_device(
    mut canvas: Canvas,
    cx: Float64,
    cy: Float64,
    radius: Float64,
    color: Color,
    supersample: Int = 4,
    width: Float64 = 1.0,
):
    """`draw_circle_aa` for device-space arguments: the body every
    call lands in. It has no transform check of its own, so its
    loops compile with nothing ahead of them and it never calls
    back into the public function.
    """
    if radius <= 0.0 or width <= 0.0:
        return
    var half = width / 2.0
    if half >= radius:
        # Every point within `half` of the circle, the center
        # included, so the stroked region is exactly the disk out to
        # `radius + half`. #279 makes the general stroke correct here
        # too, but it gets there by unioning the segment quads, which
        # only the sampled sweep can do -- 17 coverage levels against
        # this fill's 256, measured as a worst pixel of 14 levels
        # against 4. The closed form is both sharper and cheaper.
        _fill_circle_aa_device(canvas, cx, cy, radius + half, color)
        return
    # `stroke_path_aa` is the public entry and re-applies the canvas
    # transform; these arguments are already in device space, so the
    # transform comes off for the call and goes back after.
    var saved = canvas._take_transform()
    stroke_path_aa(canvas, _ellipse_path(cx, cy, radius, radius), color, width)
    canvas._set_transform(saved)
