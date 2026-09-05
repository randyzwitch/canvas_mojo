"""Rectangle drawing: stroked outline (draw_rect, via
canvas.shapes.lines.draw_line), solid fill (fill_rect), and
gradient-sourced fill (fill_rect_gradient/fill_rect_radial_gradient --
see gradient.mojo) and pattern-sourced fill (fill_rect_pattern -- see
pattern.mojo).
"""

from canvas.color import Color
from canvas.buffer import Canvas
from canvas.geometry import (
    Matrix2D,
    Point,
    _inverse_or_identity,
    _mapped_rect,
    _snap_rect,
)
from canvas.gradient import ColorSource, LinearGradient, RadialGradient
from canvas.pattern import PatternSource
from canvas.path import (
    fill_path,
    fill_path_gradient,
    fill_path_pattern,
    fill_path_radial_gradient,
    _rect_path,
)
from canvas.shapes.lines import draw_line, draw_polygon, _draw_line_device


def draw_rect(
    mut canvas: Canvas, x: Int, y: Int, width: Int, height: Int, color: Color
):
    """Stroke a rectangle's outline (x, y is the top-left corner).

    Draws each edge exactly once: the left/right edges stop short of
    the corners the top/bottom edges already cover, so a translucent
    color never blends twice.

    Args:
        canvas: Canvas to draw into.
        x: Rectangle's left edge.
        y: Rectangle's top edge.
        width: Rectangle's width.
        height: Rectangle's height.
        color: Outline color.
    """
    if canvas.has_transform():
        if canvas.current_transform().is_axis_aligned():
            var m = canvas.current_transform()
            var r = _mapped_rect(m, x, y, width, height)
            _draw_rect_device(canvas, r[0], r[1], r[2], r[3], color)
            return
        if width <= 0 or height <= 0:
            return
        var corners: List[Point] = [
            Point(x, y),
            Point(x + width - 1, y),
            Point(x + width - 1, y + height - 1),
            Point(x, y + height - 1),
        ]
        draw_polygon(canvas, corners, color)
        return
    _draw_rect_device(canvas, x, y, width, height, color)


def _draw_rect_device(
    mut canvas: Canvas, x: Int, y: Int, width: Int, height: Int, color: Color
):
    """`draw_rect` for device-space arguments: the body every
    call lands in. It has no transform check of its own, so its
    loops compile with nothing ahead of them and it never calls
    back into the public function.
    """
    if width <= 0 or height <= 0:
        return

    var x1 = x + width - 1
    var y1 = y + height - 1

    _draw_line_device(canvas, x, y, x1, y, color)  # top, full width
    if height > 1:
        _draw_line_device(canvas, x, y1, x1, y1, color)  # bottom, full width
    if height > 2:
        _draw_line_device(
            canvas, x, y + 1, x, y1 - 1, color
        )  # left, corners excluded
        _draw_line_device(
            canvas, x1, y + 1, x1, y1 - 1, color
        )  # right, corners excluded


def fill_rect(
    mut canvas: Canvas, x: Int, y: Int, width: Int, height: Int, color: Color
):
    """Fill a solid rectangle (x, y is the top-left corner).

    Args:
        canvas: Canvas to fill into.
        x: Rectangle's left edge.
        y: Rectangle's top edge.
        width: Rectangle's width.
        height: Rectangle's height.
        color: Fill color.
    """
    if canvas.has_transform():
        if canvas.current_transform().is_axis_aligned():
            var m = canvas.current_transform()
            var r = _mapped_rect(m, x, y, width, height)
            _fill_rect_device(canvas, r[0], r[1], r[2], r[3], color)
            return
        if width <= 0 or height <= 0:
            return
        fill_path(canvas, _rect_path(x, y, width, height), color)
        return
    _fill_rect_device(canvas, x, y, width, height, color)


def fill_rect(
    mut canvas: Canvas,
    x: Float64,
    y: Float64,
    width: Float64,
    height: Float64,
    color: Color,
):
    """`fill_rect` for a geometric rectangle: the box from (x, y)
    spanning width x height, in the pixel-center convention (pixel k
    spans k - 0.5 to k + 0.5), snapped to whole pixels. Each edge goes
    to the nearest pixel boundary, so `fill_rect(19.5, 4.5, 40.0,
    30.0)` is `fill_rect(20, 5, 40, 30)` exactly and an edge at 20.4
    starts at pixel 21. Hard-edged; for an anti-aliased rectangle fill
    a `Path.rect` with `fill_path_aa`.

    Under a transform the box is mapped first and snapped in device
    space, so a supersampling caller (see `downsample`) gets exact
    blocks.

    Args:
        canvas: Canvas to fill into.
        x: Left edge.
        y: Top edge.
        width: Width.
        height: Height.
        color: Fill color.
    """
    if canvas.has_transform():
        var m = canvas.current_transform()
        if m.is_axis_aligned():
            var r = _mapped_rect(m, x, y, width, height)
            _fill_rect_device(canvas, r[0], r[1], r[2], r[3], color)
            return
        if width <= 0.0 or height <= 0.0:
            return
        fill_path(canvas, _rect_path(x, y, width, height), color)
        return
    var r = _snap_rect(x, y, x + width, y + height)
    _fill_rect_device(canvas, r[0], r[1], r[2], r[3], color)


def _fill_rect_device(
    mut canvas: Canvas, x: Int, y: Int, width: Int, height: Int, color: Color
):
    """`fill_rect` for device-space arguments: the body every
    call lands in. It has no transform check of its own, so its
    loops compile with nothing ahead of them and it never calls
    back into the public function.
    """
    if width <= 0 or height <= 0:
        return

    var region = canvas.effective_fill_rect(x, y, width, height)
    canvas._fill_region(region[0], region[1], region[2], region[3], color)


def _fill_rect_source[
    S: ColorSource
](
    mut canvas: Canvas,
    x: Int,
    y: Int,
    width: Int,
    height: Int,
    source: S,
    to_user: Matrix2D,
):
    """`fill_rect`'s clamp-once-then-sweep, taking each pixel's color
    from `source` instead of one flat Color. Both gradient rect fills
    are this with a different source type. `to_user` takes each device
    pixel back to the space the source was defined in: the inverse of
    the canvas transform, or the identity.
    """
    if width <= 0 or height <= 0:
        return

    var region = canvas.effective_fill_rect(x, y, width, height)
    var rx = region[0]
    var ry = region[1]
    var rw = region[2]
    var rh = region[3]
    # A clip path modulates each pixel by its own coverage, which
    # `write_pixel` deliberately skips -- see its docstring. Nothing
    # pays for this branch until a clip path is actually pushed.
    if canvas.has_clip_mask():
        for yy in range(ry, ry + rh):
            for xx in range(rx, rx + rw):
                var p = to_user.apply(Float64(xx), Float64(yy))
                canvas.set_pixel(xx, yy, source.color_at(p.x, p.y))
        return

    for yy in range(ry, ry + rh):
        for xx in range(rx, rx + rw):
            var p = to_user.apply(Float64(xx), Float64(yy))
            canvas.write_pixel(xx, yy, source.color_at(p.x, p.y))


def fill_rect_gradient(
    mut canvas: Canvas,
    x: Int,
    y: Int,
    width: Int,
    height: Int,
    gradient: LinearGradient,
):
    """Fill a rectangle as fill_rect does, sourcing each pixel's color
    from `gradient` (gradient.mojo) rather than one flat Color. Same
    once-up-front clamp as fill_rect.

    Args:
        canvas: Canvas to fill into.
        x: Rectangle's left edge.
        y: Rectangle's top edge.
        width: Rectangle's width.
        height: Rectangle's height.
        gradient: Fill source, projected across the rectangle.
    """
    if canvas.has_transform():
        var m = canvas.current_transform()
        if m.is_axis_aligned():
            var r = _mapped_rect(m, x, y, width, height)
            _fill_rect_source(
                canvas,
                r[0],
                r[1],
                r[2],
                r[3],
                gradient,
                _inverse_or_identity(m),
            )
            return
        if width <= 0 or height <= 0:
            return
        fill_path_gradient(canvas, _rect_path(x, y, width, height), gradient)
        return
    _fill_rect_source(
        canvas, x, y, width, height, gradient, Matrix2D.identity()
    )


def fill_rect_gradient(
    mut canvas: Canvas,
    x: Float64,
    y: Float64,
    width: Float64,
    height: Float64,
    gradient: LinearGradient,
):
    """`fill_rect_gradient` for a geometric rectangle, snapped to whole
    pixels as the `Float64` `fill_rect` snaps.

    Args:
        canvas: Canvas to fill into.
        x: Left edge.
        y: Top edge.
        width: Width.
        height: Height.
        gradient: Fill source, projected across the rectangle.
    """
    if canvas.has_transform():
        var m = canvas.current_transform()
        if m.is_axis_aligned():
            var r = _mapped_rect(m, x, y, width, height)
            _fill_rect_source(
                canvas,
                r[0],
                r[1],
                r[2],
                r[3],
                gradient,
                _inverse_or_identity(m),
            )
            return
        if width <= 0.0 or height <= 0.0:
            return
        fill_path_gradient(canvas, _rect_path(x, y, width, height), gradient)
        return
    var r = _snap_rect(x, y, x + width, y + height)
    _fill_rect_source(
        canvas, r[0], r[1], r[2], r[3], gradient, Matrix2D.identity()
    )


def fill_rect_radial_gradient(
    mut canvas: Canvas,
    x: Int,
    y: Int,
    width: Int,
    height: Int,
    gradient: RadialGradient,
):
    """Like fill_rect_gradient, but for a RadialGradient. A rectangle
    isn't the usual shape for a radial gradient, but a rectangular
    legend swatch or background panel wanting a radial highlight needs
    no circle primitive involved. Same once-up-front clamp as fill_rect.

    Args:
        canvas: Canvas to fill into.
        x: Rectangle's left edge.
        y: Rectangle's top edge.
        width: Rectangle's width.
        height: Rectangle's height.
        gradient: Fill source, projected across the rectangle.
    """
    if canvas.has_transform():
        var m = canvas.current_transform()
        if m.is_axis_aligned():
            var r = _mapped_rect(m, x, y, width, height)
            _fill_rect_source(
                canvas,
                r[0],
                r[1],
                r[2],
                r[3],
                gradient,
                _inverse_or_identity(m),
            )
            return
        if width <= 0 or height <= 0:
            return
        fill_path_radial_gradient(
            canvas, _rect_path(x, y, width, height), gradient
        )
        return
    _fill_rect_source(
        canvas, x, y, width, height, gradient, Matrix2D.identity()
    )


def fill_rect_pattern(
    mut canvas: Canvas,
    x: Int,
    y: Int,
    width: Int,
    height: Int,
    pattern: PatternSource,
):
    """Like fill_rect_gradient, but for a PatternSource (pattern.mojo):
    each pixel's color comes from a sampled raster tile rather than a
    gradient projection. Same once-up-front clamp as fill_rect.

    Args:
        canvas: Canvas to fill into.
        x: Rectangle's left edge.
        y: Rectangle's top edge.
        width: Rectangle's width.
        height: Rectangle's height.
        pattern: Fill source, sampled across the rectangle.
    """
    if canvas.has_transform():
        var m = canvas.current_transform()
        if m.is_axis_aligned():
            var r = _mapped_rect(m, x, y, width, height)
            _fill_rect_source(
                canvas,
                r[0],
                r[1],
                r[2],
                r[3],
                pattern,
                _inverse_or_identity(m),
            )
            return
        if width <= 0 or height <= 0:
            return
        fill_path_pattern(canvas, _rect_path(x, y, width, height), pattern)
        return
    _fill_rect_source(canvas, x, y, width, height, pattern, Matrix2D.identity())
