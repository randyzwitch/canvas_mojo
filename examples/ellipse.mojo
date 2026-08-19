"""Demo: all four ellipse variants side by side, same radii, at a
large enough scale that the jaggedness is a real algorithm property
and not just an artifact of too few pixels to represent the curve --
outline hard-edged vs. AA, and fill hard-edged vs. AA, so the
aliasing difference is visible for both, not just outlines. Mirrors
circles.mojo's layout, generalized to independent x/y radii.

Run with:
    pixi run example
"""

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas
from canvas_mojo.primitives import (
    draw_ellipse,
    draw_ellipse_aa,
    fill_ellipse,
    fill_ellipse_aa,
)
from canvas_mojo.io.bmp import write_bmp
from canvas_mojo.io.png import write_png


def main() raises:
    var c = Canvas(2040, 480, Color(255, 255, 255))

    draw_ellipse(c, 300, 240, 210, 135, Color(150, 40, 180))
    draw_ellipse_aa(c, 780, 240, 210, 135, Color(150, 40, 180))
    fill_ellipse(c, 1260, 240, 210, 135, Color(150, 40, 180))
    fill_ellipse_aa(c, 1740, 240, 210, 135, Color(150, 40, 180))

    write_bmp(c, "examples/out_ellipse.bmp")
    write_png(c, "examples/out_ellipse.png")
    print("wrote examples/out_ellipse.bmp and .png")
