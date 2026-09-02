"""Demo: draw_rect's stroked (outline-only) rectangle.

Run with:
    pixi run example
"""

from canvas.color import Color
from canvas.buffer import Canvas
from canvas.shapes.rects import draw_rect
from canvas.io.bmp import write_bmp
from canvas.io.png import write_png


def main() raises:
    var c = Canvas(420, 420, Color(255, 255, 255))

    draw_rect(c, 60, 60, 300, 300, Color(40, 160, 60))

    write_bmp(c, "examples/out_rect_stroke.bmp")
    write_png(c, "examples/out_rect_stroke.png")
    print("wrote examples/out_rect_stroke.bmp and .png")
