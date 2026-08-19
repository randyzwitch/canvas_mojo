"""Demo: all four circle variants side by side, same radius, at a
large enough scale that the jaggedness is a real algorithm property
and not just an artifact of too few pixels to represent the curve --
outline hard-edged vs. AA, and fill hard-edged vs. AA, so the
aliasing difference is visible for both, not just outlines.

Run with:
    pixi run example
"""

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas
from canvas_mojo.primitives import draw_circle, draw_circle_aa, fill_circle, fill_circle_aa
from canvas_mojo.io.bmp import write_bmp
from canvas_mojo.io.png import write_png


def main() raises:
    var c = Canvas(2040, 480, Color(255, 255, 255))

    draw_circle(c, 300, 240, 180, Color(150, 40, 180))
    draw_circle_aa(c, 780, 240, 180, Color(150, 40, 180))
    fill_circle(c, 1260, 240, 180, Color(150, 40, 180))
    fill_circle_aa(c, 1740, 240, 180, Color(150, 40, 180))

    write_bmp(c, "examples/out_circles.bmp")
    write_png(c, "examples/out_circles.png")
    print("wrote examples/out_circles.bmp and .png")
