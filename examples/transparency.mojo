"""Demo: a transparent background, and what it is for.

`Canvas` stores per-pixel alpha, so a canvas can start fully
transparent -- `Color(0, 0, 0, 0)` -- rather than on an opaque sheet of
white. Shapes drawn onto it keep their own alpha, and `write_png`
notices and emits a real alpha channel (PNG colour type 6).

That matters for anything meant to sit on top of something else: a
chart dropped into a document whose page colour you do not control, or
one that has to work on both a light and a dark background. Flattened
onto white it would carry a white box with it.

Writes two files from the same drawing so the difference is visible:

  out_transparency.png  -- transparent background, colour type 6
  out_transparency.bmp  -- the same thing flattened onto white, since
                           24-bit BMP has nowhere to put alpha
"""

from std.math import pi

from canvas.buffer import Canvas
from canvas.color import Color
from canvas.io.bmp import write_bmp
from canvas.io.png import write_png
from canvas.path import Path
from canvas.shapes.arcs import fill_ring_sector_aa
from canvas.shapes.circles import fill_circle_aa
from canvas.text.render import draw_text


def main() raises:
    # Fully transparent, not white: every pixel starts at alpha 0.
    var c = Canvas(480, 260, Color(0, 0, 0, 0))

    # Three overlapping translucent disks. Where they overlap, alpha
    # accumulates rather than saturating -- the middle of the stack is
    # more opaque than any single disk, which is what src-over against
    # a translucent destination means.
    fill_circle_aa(c, 150.0, 130.0, 70.0, Color(220, 60, 70, 140))
    fill_circle_aa(c, 210.0, 130.0, 70.0, Color(60, 140, 220, 140))
    fill_circle_aa(c, 180.0, 180.0, 70.0, Color(90, 200, 120, 140))

    # An opaque donut segment, for contrast: it writes alpha 255 and
    # punches through whatever it covers.
    fill_ring_sector_aa(
        c, 360.0, 130.0, 42.0, 78.0, -pi / 2.0, pi / 3.0, Color(40, 40, 60)
    )

    draw_text(
        c,
        300.0,
        232.0,
        "alpha 255",
        Color(40, 40, 60),
        size=15.0,
    )
    draw_text(
        c,
        96.0,
        232.0,
        "alpha 140, overlapping",
        Color(40, 40, 60),
        size=15.0,
    )

    write_png(c, "examples/out_transparency.png")
    write_bmp(c, "examples/out_transparency.bmp")
