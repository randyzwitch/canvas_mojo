"""Demo: ColorSpace.LINEAR against the sRGB default, on the two things
it changes. Top: a red-to-green ramp interpolated by byte value (it
sags through a dark middle) and the same ramp interpolated in linear
light. Bottom: a half-transparent white square over black blended by
byte value (a 50% gray of 128) and in linear light (188, the gray that
reflects half the light), with a translucent disc over each to show
anti-aliased edges take the space too.

Run with:
    pixi run example
"""

from canvas.buffer import Canvas
from canvas.color import Color, ColorSpace
from canvas.gradient import LinearGradient
from canvas.io.png import write_png
from canvas.shapes.circles import fill_circle_aa
from canvas.shapes.rects import fill_rect, fill_rect_gradient
from canvas.text.render import draw_text


def ramp(space: ColorSpace) raises -> LinearGradient:
    var g = LinearGradient(100.0, 0.0, 1820.0, 0.0)
    g.add_stop(0.0, Color(230, 30, 30))
    g.add_stop(1.0, Color(30, 200, 60))
    g.set_color_space(space)
    return g^


def main() raises:
    var c = Canvas(1920, 780, Color(255, 255, 255))
    var ink = Color(40, 40, 40)

    draw_text(
        c, 100, 60, "Gradient interpolated in sRGB (by byte value)", ink, 26.0
    )
    fill_rect_gradient(c, 100, 80, 1720, 110, ramp(ColorSpace.SRGB))
    draw_text(
        c, 100, 240, "The same gradient interpolated in linear light", ink, 26.0
    )
    fill_rect_gradient(c, 100, 260, 1720, 110, ramp(ColorSpace.LINEAR))

    # Two black panels; the right one blends in linear light.
    draw_text(c, 100, 430, "50% white over black: sRGB blend", ink, 26.0)
    draw_text(
        c, 1000, 430, "50% white over black: linear-light blend", ink, 26.0
    )
    var half_white = Color(255, 255, 255, 128)
    var tint = Color(60, 140, 255, 160)
    for i in range(2):
        var x = 100 + i * 900
        c.save()
        if i == 1:
            c.set_color_space(ColorSpace.LINEAR)
        fill_rect(c, x, 450, 820, 280, Color(0, 0, 0))
        fill_rect(c, x + 60, 490, 320, 200, half_white)
        fill_circle_aa(c, Float64(x + 580), 590.0, 110.0, tint)
        c.restore()

    write_png(c, "examples/out_color_space.png")
