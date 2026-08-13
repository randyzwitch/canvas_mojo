"""Convenience drawing helpers built on top of `Context`."""

from .cairo_core import Context, Point2D
from .cairo_enums import FontSlant, FontWeight, Operator
from .cairo_types import Color


def rounded_rectangle_path(
    mut ctx: Context,
    x: Float64,
    y: Float64,
    width: Float64,
    height: Float64,
    radius: Float64,
) raises:
    """Create a rounded-rectangle path on `ctx`."""
    var clamped_radius = radius
    if clamped_radius < 0.0:
        clamped_radius = 0.0
    var max_radius = width
    if height < max_radius:
        max_radius = height
    max_radius = max_radius / 2.0
    if clamped_radius > max_radius:
        clamped_radius = max_radius

    ctx.new_path()
    ctx.arc(
        x + width - clamped_radius,
        y + clamped_radius,
        clamped_radius,
        -1.5707963267948966,
        0.0,
    )
    ctx.arc(
        x + width - clamped_radius,
        y + height - clamped_radius,
        clamped_radius,
        0.0,
        1.5707963267948966,
    )
    ctx.arc(
        x + clamped_radius,
        y + height - clamped_radius,
        clamped_radius,
        1.5707963267948966,
        3.141592653589793,
    )
    ctx.arc(
        x + clamped_radius,
        y + clamped_radius,
        clamped_radius,
        3.141592653589793,
        4.71238898038469,
    )
    ctx.close_path()


def circle_path(mut ctx: Context, cx: Float64, cy: Float64, radius: Float64) raises:
    """Create a closed circular path centered at `(cx, cy)`."""
    ctx.new_path()
    ctx.arc(cx, cy, radius, 0.0, 6.283185307179586)
    ctx.close_path()


def fill_circle(mut ctx: Context, cx: Float64, cy: Float64, radius: Float64) raises:
    """Fill a circle using the current source pattern."""
    circle_path(ctx, cx, cy, radius)
    ctx.fill()


def stroke_circle(mut ctx: Context, cx: Float64, cy: Float64, radius: Float64) raises:
    """Stroke a circle using current stroke settings."""
    circle_path(ctx, cx, cy, radius)
    ctx.stroke()


def line_path(
    mut ctx: Context, x1: Float64, y1: Float64, x2: Float64, y2: Float64
) raises:
    """Create a path with a single line segment."""
    ctx.new_path()
    ctx.move_to(x1, y1)
    ctx.line_to(x2, y2)


def stroke_line(
    mut ctx: Context, x1: Float64, y1: Float64, x2: Float64, y2: Float64
) raises:
    """Stroke a single line segment from `(x1, y1)` to `(x2, y2)`."""
    line_path(ctx, x1, y1, x2, y2)
    ctx.stroke()


def polyline_path(mut ctx: Context, ref points: List[Point2D]) raises:
    """Create an open polyline path from `points`."""
    if len(points) == 0:
        ctx.new_path()
        return
    ctx.new_path()
    ctx.move_to(points[0].x, points[0].y)
    for point in points[1:]:
        ctx.line_to(point.x, point.y)


def polygon_path(mut ctx: Context, ref points: List[Point2D]) raises:
    """Create a closed polygon path from `points`."""
    polyline_path(ctx, points)
    if len(points) > 1:
        ctx.close_path()


def stroke_polyline(mut ctx: Context, ref points: List[Point2D]) raises:
    """Stroke an open polyline defined by `points`."""
    polyline_path(ctx, points)
    ctx.stroke()


def fill_polygon(mut ctx: Context, ref points: List[Point2D]) raises:
    """Fill a polygon defined by `points`."""
    polygon_path(ctx, points)
    ctx.fill()


def stroke_polygon(mut ctx: Context, ref points: List[Point2D]) raises:
    """Stroke a polygon defined by `points`."""
    polygon_path(ctx, points)
    ctx.stroke()


def ellipse_path(
    mut ctx: Context, cx: Float64, cy: Float64, rx: Float64, ry: Float64
) raises:
    """Create a closed ellipse path centered at `(cx, cy)`."""
    ctx.new_path()
    ctx.save()
    ctx.translate(cx, cy)
    ctx.scale(rx, ry)
    ctx.arc(0.0, 0.0, 1.0, 0.0, 6.283185307179586)
    ctx.restore()
    ctx.close_path()


def fill_ellipse(
    mut ctx: Context, cx: Float64, cy: Float64, rx: Float64, ry: Float64
) raises:
    """Fill an ellipse centered at `(cx, cy)`."""
    ellipse_path(ctx, cx, cy, rx, ry)
    ctx.fill()


def stroke_ellipse(
    mut ctx: Context, cx: Float64, cy: Float64, rx: Float64, ry: Float64
) raises:
    """Stroke an ellipse centered at `(cx, cy)`."""
    ellipse_path(ctx, cx, cy, rx, ry)
    ctx.stroke()


def fill_rectangle(
    mut ctx: Context, x: Float64, y: Float64, width: Float64, height: Float64
) raises:
    """Fill an axis-aligned rectangle."""
    ctx.rectangle(x, y, width, height)
    ctx.fill()


def stroke_rectangle(
    mut ctx: Context, x: Float64, y: Float64, width: Float64, height: Float64
) raises:
    """Stroke an axis-aligned rectangle."""
    ctx.rectangle(x, y, width, height)
    ctx.stroke()


def fill_rounded_rectangle(
    mut ctx: Context,
    x: Float64,
    y: Float64,
    width: Float64,
    height: Float64,
    radius: Float64,
) raises:
    """Fill a rounded rectangle."""
    rounded_rectangle_path(ctx, x, y, width, height, radius)
    ctx.fill()


def stroke_rounded_rectangle(
    mut ctx: Context,
    x: Float64,
    y: Float64,
    width: Float64,
    height: Float64,
    radius: Float64,
) raises:
    """Stroke a rounded rectangle."""
    rounded_rectangle_path(ctx, x, y, width, height, radius)
    ctx.stroke()


def draw_text(
    mut ctx: Context,
    x: Float64,
    y: Float64,
    text: String,
    family: String = "Sans",
    slant: FontSlant = FontSlant.NORMAL,
    weight: FontWeight = FontWeight.NORMAL,
    size: Float64 = 12.0,
) raises:
    """Draw text at `(x, y)` with optional font styling."""
    ctx.select_font_face(family, slant=slant, weight=weight)
    ctx.set_font_size(size)
    ctx.move_to(x, y)
    ctx.show_text(text)


def clear_rgba(
    mut ctx: Context, r: Float64, g: Float64, b: Float64, a: Float64
) raises:
    """Clear the target with an explicit RGBA color."""
    ctx.save()
    ctx.set_operator(materialize[Operator.SOURCE]())
    ctx.set_source_rgba(r, g, b, a)
    ctx.paint()
    ctx.restore()


def clear(mut ctx: Context, color: Color) raises:
    """Clear the target with a `Color` value."""
    clear_rgba(ctx, color.r, color.g, color.b, color.a)
