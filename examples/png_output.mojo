"""Demo: write_png/read_png -- a second, stdlib-only image format
alongside BMP (see canvas_mojo/io/png.mojo's module docstring for why
PNG earns its place despite writing uncompressed DEFLATE "stored"
blocks on the write side: same "trivial to verify byte-by-byte"
tradeoff BMP made, but PNG previews well in essentially every viewer,
not just ones with raw BMP support). Reading, by contrast, has to
handle whatever a real encoder produced -- see canvas_mojo/io/deflate.mojo
for the native DEFLATE decoder that makes that possible.

One scene, written out through both encoders from the same canvas, so
comparing out_png_output.bmp against out_png_output.png (once
decoded) is a real cross-encoder consistency check, not just "it ran".
The PNG is then read back in with read_png() and compared pixel-for-
pixel against the original canvas, demonstrating the full write/read
round trip through this package's own code on both ends.

Run with:
    pixi run example
"""

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas
from canvas_mojo.primitives import fill_ellipse_aa, draw_circle_aa, draw_line_aa
from canvas_mojo.io.bmp import write_bmp
from canvas_mojo.io.png import read_png, write_png


def main() raises:
    var c = Canvas(900, 600, Color(250, 250, 248))

    fill_ellipse_aa(c, 450, 300, 330, 210, Color(40, 100, 200))
    draw_circle_aa(c, 450, 300, 120, Color(230, 230, 230))
    draw_line_aa(c, 60, 60, 840, 540, Color(220, 60, 40), width=9.0)

    write_bmp(c, "examples/out_png_output.bmp")
    write_png(c, "examples/out_png_output.png")
    print("wrote examples/out_png_output.bmp and .png")

    var decoded = read_png("examples/out_png_output.png")
    var mismatches = 0
    for y in range(c.height):
        for x in range(c.width):
            var original = c.get_pixel(x, y)
            var round_tripped = decoded.get_pixel(x, y)
            if original.r != round_tripped.r or original.g != round_tripped.g or original.b != round_tripped.b:
                mismatches += 1
    print("read back out_png_output.png:", decoded.width, "x", decoded.height, "--", mismatches, "pixel mismatches")
