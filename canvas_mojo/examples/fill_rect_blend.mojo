"""Demo: fill_rect and alpha blending via an overlapping translucent
fill.

Run with:
    pixi run example
"""

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas
from canvas_mojo.primitives import fill_rect
from canvas_mojo.io.bmp import write_bmp


def main() raises:
    var c = Canvas(160, 160, Color(255, 255, 255))

    # A filled red square...
    fill_rect(c, 10, 10, 100, 100, Color(220, 40, 40))

    # ...with a semi-transparent blue square overlapping it.
    fill_rect(c, 50, 50, 100, 100, Color(40, 80, 220, 128))

    write_bmp(c, "canvas_mojo/examples/out_fill_rect_blend.bmp")
    print("wrote canvas_mojo/examples/out_fill_rect_blend.bmp")
