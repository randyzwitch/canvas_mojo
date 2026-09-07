"""Circle drawing: midpoint-algorithm hard-edged outline/fill
(draw_circle/fill_circle) and exact-area anti-aliased variants
(draw_circle_aa/fill_circle_aa) -- see canvas.shapes.lines for the
hard-edged vs. `_aa` naming convention this follows.

The `_aa` fills describe the disk as a path and hand it to
`fill_path_aa` under `FillRule.NONZERO`, so they land on the same
exact-area rasterizer (`canvas.aa_area`) as every other nonzero fill
rather than carrying a sampler of their own (#275).
"""

from std.math import asin, ceil, floor, sqrt

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


# --- Exact pixel coverage for a disk -------------------------------------

# Everything below works on the unit disk, and callers divide their
# coordinates by the radius on the way in. That takes a division and a
# `t/r` per arc evaluation out of the pixel loop, worth about 8% of a
# small marker's fill measured against the radius-space form the two
# agree with to 7e-15.
#
# The `asin` here is the single most expensive operation in a small
# fill, about 40% of it, but glibc's is hard to beat: a degree-five
# minimax fit of the usual `pi/2 - sqrt(1-x)*P(x)` shape, accurate to
# 1.3e-6 and well inside the half-a-level budget, measured 1.75x
# slower than the library call. It vectorizes and the library call
# does not, so it wins in a synthetic loop, but nothing here is
# vectorized -- the chain is latency-bound, and its `sqrt` plus five
# dependent multiply-adds is a longer chain than glibc needs.


@always_inline
def _unit_arc_integral(x: Float64) -> Float64:
    """The antiderivative of `sqrt(1 - x^2)`, clamped to the unit
    disk's domain: `(x*sqrt(1-x^2) + asin(x)) / 2`.
    """
    var t = x
    if t < -1.0:
        t = -1.0
    elif t > 1.0:
        t = 1.0
    var rem = 1.0 - t * t
    if rem < 0.0:
        rem = 0.0
    return 0.5 * (t * sqrt(rem) + asin(t))


def _unit_upper_area(x0: Float64, x1: Float64, y: Float64) -> Float64:
    """The integral over [x0, x1] of `min(y, sqrt(1 - x^2))`, the area
    under the unit disk's upper arc capped at height `y >= 0`.

    Split where the arc crosses that cap, at `|x| = sqrt(1 - y^2)`:
    between those the slice is the flat `y`, outside them it is the
    arc, which `_unit_arc_integral` gives in closed form.
    """
    if x1 <= x0 or y <= 0.0:
        return 0.0
    var a = x0
    var b = x1
    if a < -1.0:
        a = -1.0
    if b > 1.0:
        b = 1.0
    if b <= a:
        return 0.0
    var rem = 1.0 - y * y
    var xc = sqrt(rem) if rem > 0.0 else 0.0
    var total = 0.0
    var fa = max(a, -xc)
    var fb = min(b, xc)
    if fb > fa:
        total += y * (fb - fa)
    var lb = min(b, -xc)
    if lb > a:
        total += _unit_arc_integral(lb) - _unit_arc_integral(a)
    var ra = max(a, xc)
    if b > ra:
        total += _unit_arc_integral(b) - _unit_arc_integral(ra)
    return total


def _unit_disk_rect_area(
    x0: Float64, x1: Float64, y0: Float64, y1: Float64
) -> Float64:
    """The exact area shared by the unit disk at the origin and the
    axis-aligned rectangle [x0, x1] x [y0, y1].

    Each horizontal edge contributes the area under the arc down to
    it, signed by which side of the center it falls on, so the four
    terms leave exactly the band between y0 and y1. Everything else
    here scales into this: a disk of radius `r` by dividing the
    rectangle by `r` and multiplying the area by `r^2`, an ellipse by
    dividing each axis by its own radius. Working on the unit disk is
    what keeps a division out of the inner loop.
    """
    var total = 0.0
    if y1 > 0.0:
        total += _unit_upper_area(x0, x1, y1)
    if y0 > 0.0:
        total -= _unit_upper_area(x0, x1, y0)
    if y0 < 0.0:
        total += _unit_upper_area(x0, x1, -y0)
    if y1 < 0.0:
        total -= _unit_upper_area(x0, x1, -y1)
    return total


# Above this radius a circle goes back to the general exact-area
# rasterizer. Both routes give the same 256 levels; they differ in
# what they spend to get there. The closed form pays a `sqrt`/`asin`
# pair per pixel edge and allocates nothing, which wins while the
# shape is small; the polygon pays an edge table and an accumulator
# once and then only arithmetic per pixel, which wins once there are
# enough pixels to amortize it. Timed against each other over 8,000
# calls (#281): the closed form is 0.91x the polygon's time at r=6,
# 1.14x at r=8, 1.35x at r=10 and 1.94x at r=18, so they cross just
# under seven.
comptime _CLOSED_FORM_MAX_RADIUS = 7.0


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

    Every pixel gets the disk's exact covered area, 256 levels, by one
    of two routes that agree to within a level. A circle up to
    `_CLOSED_FORM_MAX_RADIUS` takes it from the circle's own equation
    (`_unit_disk_rect_area`), which allocates nothing; a larger one
    flattens to a polygon and takes the general rasterizer, which
    allocates once and amortizes it over more pixels.

    #276 sent every circle down the polygon route, which for a marker
    a few pixels across cost about ten allocations and 4.8x the
    sampler it replaced (#281). A small circle needs none of that.

    `supersample` is accepted and unused, as it is on every other
    exact-area fill.
    """
    if radius <= 0.0:
        canvas.set_pixel(round_to_int(cx), round_to_int(cy), color)
        return
    if radius > _CLOSED_FORM_MAX_RADIUS:
        _fill_polygon_aa_device(
            canvas,
            _ellipse_fpoints(cx, cy, radius, radius),
            color,
            FillRule.NONZERO,
        )
        return
    var r2 = radius * radius
    var inv_r = 1.0 / radius
    var alpha_scale = Float64(color.a)
    # Widened outward to whole pixels, so a pixel the disk only partly
    # covers is still visited.
    var lo_x = Int(floor(cx - radius)) - 1
    var hi_x = Int(ceil(cx + radius)) + 2
    var lo_y = Int(floor(cy - radius)) - 1
    var hi_y = Int(ceil(cy + radius)) + 2
    # The loop walks unit-disk space, where the exact-area math lives:
    # `u` is a coordinate divided by the radius, so the disk is the
    # unit circle and a pixel is a square of side `inv_r`. Stepping
    # `u` by `inv_r` per pixel keeps the division and the four scaling
    # multiplies a per-pixel conversion would need out of the loop,
    # and the inside/outside tests come along for free -- they just
    # compare against 1 instead of `r2`. A closed-form circle is at
    # most fifteen pixels across, so stepping rather than recomputing
    # cannot drift anywhere near a level of alpha.
    var half = 0.5 * inv_r
    var uy = (Float64(lo_y) - cy) * inv_r
    for py in range(lo_y, hi_y):
        var ady = abs(uy)
        var near_dy = max(0.0, ady - half)
        var far_dy = ady + half
        var near_dy2 = near_dy * near_dy
        var far_dy2 = far_dy * far_dy
        var ux = (Float64(lo_x) - cx) * inv_r
        for px in range(lo_x, hi_x):
            var adx = abs(ux)
            var near_dx = max(0.0, adx - half)
            if near_dx * near_dx + near_dy2 > 1.0:
                ux += inv_r
                continue  # whole pixel square is outside the disk
            var far_dx = adx + half
            if far_dx * far_dx + far_dy2 <= 1.0:
                canvas.set_pixel(px, py, color)  # wholly inside
                ux += inv_r
                continue
            var area = (
                _unit_disk_rect_area(ux - half, ux + half, uy - half, uy + half)
                * r2
            )
            if area > 0.0:
                if area > 1.0:
                    area = 1.0
                var alpha = Int(area * alpha_scale + 0.5)
                if alpha > 0:
                    canvas.set_pixel(px, py, color.with_alpha(UInt8(alpha)))
            ux += inv_r
        uy += inv_r


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
