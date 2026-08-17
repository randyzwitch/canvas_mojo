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


def main() raises:
    var c = Canvas(680, 160, Color(255, 255, 255))

    draw_circle(c, 100, 80, 60, Color(150, 40, 180))
    draw_circle_aa(c, 260, 80, 60, Color(150, 40, 180))
    fill_circle(c, 420, 80, 60, Color(150, 40, 180))
    fill_circle_aa(c, 580, 80, 60, Color(150, 40, 180))

    write_bmp(c, "examples/out_circles.bmp")
    print("wrote examples/out_circles.bmp")
