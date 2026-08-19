"""Demo: fill_rect and alpha blending via an overlapping translucent
fill.

Run with:
    pixi run example
"""

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas
from canvas_mojo.primitives import fill_rect
from canvas_mojo.io.bmp import write_bmp
from canvas_mojo.io.png import write_png


def main() raises:
    var c = Canvas(480, 480, Color(255, 255, 255))

    # A filled red square...
    fill_rect(c, 30, 30, 300, 300, Color(220, 40, 40))

    # ...with a semi-transparent blue square overlapping it.
    fill_rect(c, 150, 150, 300, 300, Color(40, 80, 220, 128))

    write_bmp(c, "examples/out_fill_rect_blend.bmp")
    write_png(c, "examples/out_fill_rect_blend.png")
    print("wrote examples/out_fill_rect_blend.bmp and .png")
