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


def main() raises:
    var c = Canvas(680, 160, Color(255, 255, 255))

    draw_ellipse(c, 100, 80, 70, 45, Color(150, 40, 180))
    draw_ellipse_aa(c, 260, 80, 70, 45, Color(150, 40, 180))
    fill_ellipse(c, 420, 80, 70, 45, Color(150, 40, 180))
    fill_ellipse_aa(c, 580, 80, 70, 45, Color(150, 40, 180))

    write_bmp(c, "canvas_mojo/examples/out_ellipse.bmp")
    print("wrote canvas_mojo/examples/out_ellipse.bmp")
