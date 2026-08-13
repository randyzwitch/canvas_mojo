"""Demo: draw_rect's stroked (outline-only) rectangle.

Run with:
    pixi run example
"""

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas
from canvas_mojo.primitives import draw_rect
from canvas_mojo.io.bmp import write_bmp


def main() raises:
    var c = Canvas(140, 140, Color(255, 255, 255))

    draw_rect(c, 20, 20, 100, 100, Color(40, 160, 60))

    write_bmp(c, "canvas_mojo/examples/out_rect_stroke.bmp")
    print("wrote canvas_mojo/examples/out_rect_stroke.bmp")
