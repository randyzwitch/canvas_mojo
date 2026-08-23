"""Rectangle drawing: stroked outline (draw_rect, via
canvas_mojo.shapes.lines.draw_line), solid fill (fill_rect), and
gradient-sourced fill (fill_rect_gradient/fill_rect_radial_gradient --
see gradient.mojo).
"""

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas
from canvas_mojo.gradient import LinearGradient, RadialGradient
from canvas_mojo.shapes.lines import draw_line


def draw_rect(mut canvas: Canvas, x: Int, y: Int, width: Int, height: Int, color: Color):
    """Stroke a rectangle's outline (x, y is the top-left corner).

    Draws each edge exactly once -- the left/right edges stop short of
    the corners already covered by the top/bottom edges, so a
    translucent color doesn't get blended twice at any pixel.
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
        draw_line(canvas, x1, y + 1, x1, y1 - 1, color)  # right, corners excluded


def fill_rect(mut canvas: Canvas, x: Int, y: Int, width: Int, height: Int, color: Color):
    """Fill a solid rectangle (x, y is the top-left corner).

    Clamps to the canvas's own bounds and the active clip *once*, up
    front, via effective_fill_rect -- not per pixel through set_pixel
    -- since every pixel in this loop shares the identical, unchanging
    bounds check; see that method's own docstring on buffer.mojo's
    Canvas.
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
    mut canvas: Canvas, x: Int, y: Int, width: Int, height: Int, gradient: LinearGradient
):
    """Fill a solid rectangle the same way fill_rect does, but
    sourcing each pixel's color from `gradient` (see gradient.mojo)
    instead of one flat Color. Same once-up-front clamp as fill_rect,
    for the same reason -- see that function's own docstring.
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
            canvas.write_pixel(xx, yy, gradient.color_at(Float64(xx), Float64(yy)))


def fill_rect_radial_gradient(
    mut canvas: Canvas, x: Int, y: Int, width: Int, height: Int, gradient: RadialGradient
):
    """Fill a solid rectangle the same way fill_rect does, but
    sourcing each pixel's color from `gradient` (a RadialGradient --
    see gradient.mojo) instead of one flat Color. A rectangle isn't
    the shape a radial gradient is usually reached for (a circle/ring
    is), but it's the same "concrete case that exists" reasoning as
    fill_rect_gradient: a rectangular legend swatch or background panel
    wanting a radial highlight doesn't need a circle primitive
    involved at all. Same once-up-front clamp as fill_rect, for the
    same reason -- see that function's own docstring.
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
            canvas.write_pixel(xx, yy, gradient.color_at(Float64(xx), Float64(yy)))
