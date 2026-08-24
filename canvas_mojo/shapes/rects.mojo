"""Rectangle drawing: stroked outline (draw_rect, via
canvas_mojo.shapes.lines.draw_line), solid fill (fill_rect), and
gradient-sourced fill (fill_rect_gradient/fill_rect_radial_gradient --
see gradient.mojo).
"""

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas
from canvas_mojo.gradient import LinearGradient, RadialGradient
from canvas_mojo.shapes.lines import draw_line


def draw_rect(
    mut canvas: Canvas, x: Int, y: Int, width: Int, height: Int, color: Color
):
    """Stroke a rectangle's outline (x, y is the top-left corner).

    Draws each edge exactly once: the left/right edges stop short of
    the corners the top/bottom edges already cover, so a translucent
    color never blends twice.
    """
    if width <= 0 or height <= 0:
        return

    var x1 = x + width - 1
    var y1 = y + height - 1

    draw_line(canvas, x, y, x1, y, color)  # top, full width
    if height > 1:
        draw_line(canvas, x, y1, x1, y1, color)  # bottom, full width
    if height > 2:
        draw_line(canvas, x, y + 1, x, y1 - 1, color)  # left, corners excluded
        draw_line(
            canvas, x1, y + 1, x1, y1 - 1, color
        )  # right, corners excluded


def fill_rect(
    mut canvas: Canvas, x: Int, y: Int, width: Int, height: Int, color: Color
):
    """Fill a solid rectangle (x, y is the top-left corner).

    Clamps to the canvas bounds and active clip once up front through
    `Canvas.effective_fill_rect`, rather than per pixel through
    set_pixel: every pixel in the loop shares the same bounds check.
    """
    if width <= 0 or height <= 0:
        return

    var region = canvas.effective_fill_rect(x, y, width, height)
    var rx = region[0]
    var ry = region[1]
    var rw = region[2]
    var rh = region[3]
    for yy in range(ry, ry + rh):
        for xx in range(rx, rx + rw):
            canvas.write_pixel(xx, yy, color)


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
    """
    if width <= 0 or height <= 0:
        return

    var region = canvas.effective_fill_rect(x, y, width, height)
    var rx = region[0]
    var ry = region[1]
    var rw = region[2]
    var rh = region[3]
    for yy in range(ry, ry + rh):
        for xx in range(rx, rx + rw):
            canvas.write_pixel(
                xx, yy, gradient.color_at(Float64(xx), Float64(yy))
            )


def fill_rect_radial_gradient(
    mut canvas: Canvas,
    x: Int,
    y: Int,
    width: Int,
    height: Int,
    gradient: RadialGradient,
):
    """fill_rect_gradient's RadialGradient counterpart. A rectangle
    isn't the usual shape for a radial gradient, but a rectangular
    legend swatch or background panel wanting a radial highlight needs
    no circle primitive involved. Same once-up-front clamp as fill_rect.
    """
    if width <= 0 or height <= 0:
        return

    var region = canvas.effective_fill_rect(x, y, width, height)
    var rx = region[0]
    var ry = region[1]
    var rw = region[2]
    var rh = region[3]
    for yy in range(ry, ry + rh):
        for xx in range(rx, rx + rw):
            canvas.write_pixel(
                xx, yy, gradient.color_at(Float64(xx), Float64(yy))
            )
