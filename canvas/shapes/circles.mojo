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
from std.runtime.asyncrt import TaskGroup

from canvas.color import Color
from canvas.buffer import Canvas
from canvas.geometry import FPoint, round_to_int
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
from canvas.shapes.polygon_fill import (
    _fill_polygon_aa_device,
    _fill_polygon_aa_rows,
)
from canvas.workers import _bands_for


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


# Below this radius, test each pixel rather than solving an interior span.
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

# Calculations use a unit disk; callers normalize coordinates by radius.


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


# Larger circles use the general exact-area rasterizer.
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


def _fill_circle_aa_rows(
    mut canvas: Canvas,
    cx: Float64,
    cy: Float64,
    radius: Float64,
    color: Color,
    row_lo: Int,
    row_hi: Int,
):
    """`_fill_circle_aa_device`'s closed-form body, restricted to rows
    [row_lo, row_hi).

    The row clamp is what lets a batch of markers split across cores:
    each band owns a disjoint set of rows, so two bands never write
    the same pixel, and a marker straddling a boundary is visited by
    both -- each doing only its own rows. `uy` is derived from the
    clamped first row, so the unit-space walk starts in the right
    place rather than being stepped into it.

    Only the closed form is here. A radius past
    `_CLOSED_FORM_MAX_RADIUS` has none, and `_circles_band` sends
    those to `_fill_polygon_aa_rows` instead -- decided once for the
    batch, since every marker shares the radius.
    """
    var r2 = radius * radius
    var inv_r = 1.0 / radius
    var alpha_scale = Float64(color.a)
    var lo_x = Int(floor(cx - radius)) - 1
    var hi_x = Int(ceil(cx + radius)) + 2
    var lo_y = max(Int(floor(cy - radius)) - 1, row_lo)
    var hi_y = min(Int(ceil(cy + radius)) + 2, row_hi)
    if lo_y >= hi_y:
        return
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
                continue
            var far_dx = adx + half
            if far_dx * far_dx + far_dy2 <= 1.0:
                canvas.set_pixel(px, py, color)
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


def _circles_band(
    mut canvas: Canvas,
    centers: List[FPoint],
    colors: List[Color],
    radius: Float64,
    color: Color,
    row_lo: Int,
    row_hi: Int,
):
    """Every marker reaching rows [row_lo, row_hi), in submission
    order.

    Order is the whole correctness argument for overlapping
    translucent markers: a pixel's value depends on the marker being
    drawn and on what is already under it, so walking the batch in
    order within each band reproduces exactly what drawing them one at
    a time produces. Bands own disjoint rows, so they never race and
    need no ordering between them.
    """
    var uniform = len(colors) == 0
    # The radius is shared by the batch, so which coverage route to
    # take is decided once rather than per marker.
    var closed_form = radius <= _CLOSED_FORM_MAX_RADIUS
    for i in range(len(centers)):
        ref p = centers[i]
        # Cheap reject, before the fill re-derives the same bounds.
        if p.y + radius + 2.0 < Float64(row_lo):
            continue
        if p.y - radius - 1.0 >= Float64(row_hi):
            continue
        var c = color if uniform else colors[i]
        if closed_form:
            _fill_circle_aa_rows(canvas, p.x, p.y, radius, c, row_lo, row_hi)
        else:
            _fill_polygon_aa_rows(
                canvas,
                _ellipse_fpoints(p.x, p.y, radius, radius),
                c,
                FillRule.NONZERO,
                row_lo,
                row_hi,
            )


async def _circles_band_async(
    mut canvas: Canvas,
    centers: List[FPoint],
    colors: List[Color],
    radius: Float64,
    color: Color,
    row_lo: Int,
    row_hi: Int,
):
    """`_circles_band` as a task. `centers` and `colors` are borrowed,
    never owned: a heap-backed aggregate handed to `create_task` by
    value is canvas_mojo#97.
    """
    _circles_band(canvas, centers, colors, radius, color, row_lo, row_hi)


def _fill_circles_sequential(
    mut canvas: Canvas,
    centers: List[FPoint],
    colors: List[Color],
    radius: Float64,
    color: Color,
) raises:
    """One `fill_circle_aa` per center, the definition every batched
    path has to agree with."""
    var uniform = len(colors) == 0
    for i in range(len(centers)):
        ref p = centers[i]
        fill_circle_aa(
            canvas, p.x, p.y, radius, color if uniform else colors[i]
        )


def _fill_circles_aa_impl(
    mut canvas: Canvas,
    centers: List[FPoint],
    colors: List[Color],
    radius: Float64,
    color: Color,
) raises:
    """The body both `fill_circles_aa` overloads land in. An empty
    `colors` means every marker takes `color`."""
    if len(centers) == 0:
        return
    if radius <= 0.0:
        _fill_circles_sequential(canvas, centers, colors, radius, color)
        return

    if canvas.has_transform():
        var m = canvas.current_transform()
        if not m.is_similarity():
            # A non-similarity turns each disk into an ellipse, so
            # there is nothing uniform left to batch.
            _fill_circles_sequential(canvas, centers, colors, radius, color)
            return
        # A similarity keeps every disk a disk, so mapping the centers
        # and scaling the radius once leaves a device-space batch.
        var mapped = List[FPoint](capacity=len(centers))
        for i in range(len(centers)):
            ref p = centers[i]
            var q = m.apply(p.x, p.y)
            mapped.append(FPoint(q.x, q.y))
        var scaled = radius * m.scale_factor()
        var saved = canvas._take_transform()
        try:
            _fill_circles_aa_impl(canvas, mapped, colors, scaled, color)
        except e:
            canvas._set_transform(saved)
            raise e
        canvas._set_transform(saved)
        return

    # Roughly the covered area, the figure `_bands_for` weighs against
    # its parallel threshold.
    var per_marker = Int(3.15 * (radius + 1.0) * (radius + 1.0)) + 1
    var bands = _bands_for(
        len(centers) * per_marker, canvas.height, canvas.max_workers()
    )
    if bands <= 1:
        _circles_band(canvas, centers, colors, radius, color, 0, canvas.height)
        return

    var per_band = (canvas.height + bands - 1) // bands
    var tg = TaskGroup()
    for b in range(bands):
        var row_lo = b * per_band
        var row_hi = min(row_lo + per_band, canvas.height)
        if row_lo >= row_hi:
            continue
        tg.create_task(
            _circles_band_async(
                canvas, centers, colors, radius, color, row_lo, row_hi
            )
        )
    tg.wait()
    # Named past the tasks: a task's borrow is not a use the compiler
    # counts, so without this the lists are freed while bands still
    # read them.
    _ = len(centers)
    _ = len(colors)


def fill_circles_aa(
    mut canvas: Canvas,
    centers: List[FPoint],
    radius: Float64,
    color: Color,
) raises:
    """Fill many equal-radius anti-aliased disks in one call.

    Output is identical to calling `fill_circle_aa` once per center in
    the same order, including where translucent markers overlap: each
    band walks the batch in submission order, and bands own disjoint
    rows.

    A radius past the closed-form limit, a canvas transform that is
    not a similarity, or too little total work each fall back to
    per-marker calls.

    Args:
        canvas: Canvas to fill into.
        centers: Sub-pixel center of each marker, in draw order.
        radius: Radius shared by every marker, in pixels.
        color: Fill color shared by every marker.
    """
    _fill_circles_aa_impl(canvas, centers, List[Color](), radius, color)


def fill_circles_aa(
    mut canvas: Canvas,
    centers: List[FPoint],
    radius: Float64,
    colors: List[Color],
) raises:
    """`fill_circles_aa` with a color per marker -- a scatter whose
    points carry a color scale.

    Args:
        canvas: Canvas to fill into.
        centers: Sub-pixel center of each marker, in draw order.
        radius: Radius shared by every marker, in pixels.
        colors: One color per center, same length as `centers`.

    Raises:
        Error: If `colors` is not the same length as `centers`.
    """
    if len(colors) != len(centers):
        raise Error(
            String(
                "fill_circles_aa: ",
                len(colors),
                " colors for ",
                len(centers),
                " centers",
            )
        )
    _fill_circles_aa_impl(canvas, centers, colors, radius, Color(0, 0, 0))


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
        # When the half-width reaches the center, the stroked region is
        # exactly the disk out to `radius + half`.
        _fill_circle_aa_device(canvas, cx, cy, radius + half, color)
        return
    # `stroke_path_aa` is the public entry and re-applies the canvas
    # transform; these arguments are already in device space, so the
    # transform comes off for the call and goes back after.
    var saved = canvas._take_transform()
    stroke_path_aa(canvas, _ellipse_path(cx, cy, radius, radius), color, width)
    canvas._set_transform(saved)
