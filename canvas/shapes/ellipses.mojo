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
from canvas.shapes.circles import (
    _CLOSED_FORM_MAX_RADIUS,
    _ellipse_pixel_coverage,
)
from canvas.shapes.polygon_fill import _fill_polygon_aa_device


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
    if canvas.has_transform():
        var m = canvas.current_transform()
        if m.is_axis_aligned():
            var p = m.apply(Float64(cx), Float64(cy))
            _draw_ellipse_device(
                canvas,
                round_to_int(p.x),
                round_to_int(p.y),
                round_to_int(Float64(rx) * abs(m.a)),
                round_to_int(Float64(ry) * abs(m.d)),
                color,
            )
            return
        stroke_path(
            canvas,
            _ellipse_path(Float64(cx), Float64(cy), Float64(rx), Float64(ry)),
            color,
        )
        return
    _draw_ellipse_device(canvas, cx, cy, rx, ry, color)


def _draw_ellipse_device(
    mut canvas: Canvas, cx: Int, cy: Int, rx: Int, ry: Int, color: Color
):
    """`draw_ellipse` for device-space arguments: the body every
    call lands in. It has no transform check of its own, so its
    loops compile with nothing ahead of them and it never calls
    back into the public function.
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
    if canvas.has_transform():
        var m = canvas.current_transform()
        if m.is_axis_aligned():
            var p = m.apply(Float64(cx), Float64(cy))
            _fill_ellipse_device(
                canvas,
                round_to_int(p.x),
                round_to_int(p.y),
                round_to_int(Float64(rx) * abs(m.a)),
                round_to_int(Float64(ry) * abs(m.d)),
                color,
            )
            return
        fill_path(
            canvas,
            _ellipse_path(Float64(cx), Float64(cy), Float64(rx), Float64(ry)),
            color,
        )
        return
    _fill_ellipse_device(canvas, cx, cy, rx, ry, color)


def _fill_ellipse_device(
    mut canvas: Canvas, cx: Int, cy: Int, rx: Int, ry: Int, color: Color
):
    """`fill_ellipse` for device-space arguments: the body every
    call lands in. It has no transform check of its own, so its
    loops compile with nothing ahead of them and it never calls
    back into the public function.
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
    if canvas.has_transform():
        var m = canvas.current_transform()
        if m.is_axis_aligned():
            var p = m.apply(Float64(cx), Float64(cy))
            var saved = canvas._take_transform()
            fill_ellipse_aa(
                canvas,
                p.x,
                p.y,
                Float64(rx) * abs(m.a),
                Float64(ry) * abs(m.d),
                color,
                supersample,
            )
            canvas._set_transform(saved)
            return
        fill_path_aa(
            canvas,
            _ellipse_path(Float64(cx), Float64(cy), Float64(rx), Float64(ry)),
            color,
            FillRule.NONZERO,
        )
        return
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
    """Whether the pixel square centered at `px`, on a row whose
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
    if canvas.has_transform():
        var m = canvas.current_transform()
        if m.is_axis_aligned():
            var p = m.apply(Float64(cx), Float64(cy))
            _fill_ellipse_aa_device(
                canvas,
                p.x,
                p.y,
                Float64(rx) * abs(m.a),
                Float64(ry) * abs(m.d),
                color,
                supersample,
            )
            return
        fill_path_aa(
            canvas,
            _ellipse_path(Float64(cx), Float64(cy), Float64(rx), Float64(ry)),
            color,
            FillRule.NONZERO,
        )
        return
    _fill_ellipse_aa_device(canvas, cx, cy, rx, ry, color, supersample)


def _fill_ellipse_aa_device(
    mut canvas: Canvas,
    cx: Float64,
    cy: Float64,
    rx: Float64,
    ry: Float64,
    color: Color,
    supersample: Int = 4,
):
    """`fill_ellipse_aa` for device-space arguments: the body every
    call lands in.

    Every pixel gets the ellipse's exact covered area, 256 levels, by
    the same two routes `fill_circle_aa` uses and for the same reason
    (#281): a small ellipse from the closed form, which allocates
    nothing, a large one through the general exact-area rasterizer,
    which amortizes its edge table over more pixels. The threshold is
    on the larger radius, since that is what sets how many pixels the
    outline touches.

    `supersample` is accepted and unused, as it is on every other
    exact-area fill.
    """
    if rx <= 0.0 or ry <= 0.0:
        return
    if max(rx, ry) > _CLOSED_FORM_MAX_RADIUS:
        _fill_polygon_aa_device(
            canvas, _ellipse_fpoints(cx, cy, rx, ry), color, FillRule.NONZERO
        )
        return
    var alpha_scale = Float64(color.a)
    var lo_x = Int(floor(cx - rx)) - 1
    var hi_x = Int(ceil(cx + rx)) + 2
    var lo_y = Int(floor(cy - ry)) - 1
    var hi_y = Int(ceil(cy + ry)) + 2
    for py in range(lo_y, hi_y):
        var dy = abs(Float64(py) - cy)
        var near_dy = max(0.0, dy - 0.5) / ry
        var far_dy = (dy + 0.5) / ry
        var near_dy2 = near_dy * near_dy
        var far_dy2 = far_dy * far_dy
        if near_dy2 > 1.0:
            continue
        for px in range(lo_x, hi_x):
            # The same two cheap tests the disk takes, in the space
            # where the ellipse is a unit circle: a pixel whose
            # nearest corner is outside contributes nothing, and one
            # whose farthest corner is inside is whole. Only what is
            # left needs the closed form.
            var dx = abs(Float64(px) - cx)
            var near_dx = max(0.0, dx - 0.5) / rx
            if near_dx * near_dx + near_dy2 > 1.0:
                continue
            var far_dx = (dx + 0.5) / rx
            if far_dx * far_dx + far_dy2 <= 1.0:
                canvas.set_pixel(px, py, color)
                continue
            var coverage = _ellipse_pixel_coverage(px, py, cx, cy, rx, ry)
            if coverage <= 0.0:
                continue
            var alpha = Int(coverage * alpha_scale + 0.5)
            if alpha > 0:
                canvas.set_pixel(px, py, color.with_alpha(UInt8(alpha)))


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
    if canvas.has_transform():
        var m = canvas.current_transform()
        # The outline's width is one number, so the fast path needs
        # both axes scaled alike; anything else strokes the path.
        if m.is_axis_aligned() and abs(m.a) == abs(m.d):
            var p = m.apply(Float64(cx), Float64(cy))
            var saved = canvas._take_transform()
            draw_ellipse_aa(
                canvas,
                p.x,
                p.y,
                Float64(rx) * abs(m.a),
                Float64(ry) * abs(m.d),
                color,
                supersample,
                width * abs(m.a),
            )
            canvas._set_transform(saved)
            return
        stroke_path_aa(
            canvas,
            _ellipse_path(Float64(cx), Float64(cy), Float64(rx), Float64(ry)),
            color,
            width,
            supersample,
        )
        return
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
    if canvas.has_transform():
        var m = canvas.current_transform()
        # The outline's width is one number, so the fast path needs
        # both axes scaled alike; anything else strokes the path.
        if m.is_axis_aligned() and abs(m.a) == abs(m.d):
            var p = m.apply(Float64(cx), Float64(cy))
            _draw_ellipse_aa_device(
                canvas,
                p.x,
                p.y,
                Float64(rx) * abs(m.a),
                Float64(ry) * abs(m.d),
                color,
                supersample,
                width * abs(m.a),
            )
            return
        stroke_path_aa(
            canvas,
            _ellipse_path(Float64(cx), Float64(cy), Float64(rx), Float64(ry)),
            color,
            width,
            supersample,
        )
        return
    _draw_ellipse_aa_device(canvas, cx, cy, rx, ry, color, supersample, width)


def _draw_ellipse_aa_device(
    mut canvas: Canvas,
    cx: Float64,
    cy: Float64,
    rx: Float64,
    ry: Float64,
    color: Color,
    supersample: Int = 4,
    width: Float64 = 1.0,
):
    """`draw_ellipse_aa` for device-space arguments: the body every
    call lands in.

    The outline is a real stroke: `width` pixels wide measured along
    the curve's normal, everywhere, which is what stroking means and
    what `SvgCanvas.draw_ellipse_aa` emits (`<ellipse stroke-width>`).
    `stroke_path_aa` builds that outline and fills it by exact area
    (`canvas.aa_area`) whenever it is simple, giving 256 coverage
    levels; `supersample` is accepted and used only where it is not
    (a stroke wider than the shorter diameter, whose inner offset
    crosses itself).

    Until #275 this sampled a 4x4 grid against the band between the
    concentric ellipses `(rx-w/2, ry-w/2)` and `(rx+w/2, ry+w/2)`.
    That band is `width` wide only at the four axis extremes and
    narrower everywhere else, so a thick outline on an eccentric
    ellipse drew a different shape here than the same call drew
    through `SvgCanvas` -- which the `DrawTarget` trait exists to
    prevent. For a circle the two agree, offsetting along the normal
    and scaling the radius being the same operation there.
    """
    if rx <= 0.0 or ry <= 0.0 or width <= 0.0:
        return
    # `stroke_path_aa` is the public entry and re-applies the canvas
    # transform; these arguments are already in device space, so the
    # transform comes off for the call and goes back after.
    var saved = canvas._take_transform()
    stroke_path_aa(
        canvas, _ellipse_path(cx, cy, rx, ry), color, width, supersample
    )
    canvas._set_transform(saved)
