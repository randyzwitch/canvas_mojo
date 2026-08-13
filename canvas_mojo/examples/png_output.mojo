"""Demo: write_png -- a second, stdlib-only output format alongside
BMP (see canvas_mojo/io/png.mojo's module docstring for why PNG earns its
place despite writing uncompressed DEFLATE "stored" blocks: same
"trivial to verify byte-by-byte" tradeoff BMP made, but PNG previews
well in essentially every viewer, not just ones with raw BMP support).

One scene, written out through both encoders from the same canvas, so
comparing out_png_output.bmp against out_png_output.png (once
decoded) is a real cross-encoder consistency check, not just "it ran".

Run with:
    pixi run example
"""

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas
from canvas_mojo.primitives import fill_ellipse_aa, draw_circle_aa, draw_line_aa
from canvas_mojo.io.bmp import write_bmp
from canvas_mojo.io.png import write_png


def main() raises:
    var c = Canvas(300, 200, Color(250, 250, 248))

    fill_ellipse_aa(c, 150, 100, 110, 70, Color(40, 100, 200))
    draw_circle_aa(c, 150, 100, 40, Color(230, 230, 230))
    draw_line_aa(c, 20, 20, 280, 180, Color(220, 60, 40), width=3.0)

    write_bmp(c, "canvas_mojo/examples/out_png_output.bmp")
    write_png(c, "canvas_mojo/examples/out_png_output.png")
    print("wrote canvas_mojo/examples/out_png_output.bmp and .png")
