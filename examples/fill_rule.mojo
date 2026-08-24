"""Demo: FillRule.EVEN_ODD vs FillRule.NONZERO on the same
self-overlapping shape -- two same-direction-wound squares as two
sub-paths of one Path.

EVEN_ODD (the default) counts crossings; the overlap region has been
crossed twice, so it's "outside" again -- a hole appears exactly where
the two squares cover each other. NONZERO tracks signed winding
instead; both squares wind the same direction, so the overlap's signed
count is 2 (not 0) -- nonzero, so filled solid, no hole. One input
shape with only the rule changed, so the divergence is visible without
comparing two different shapes.

This matters for chart rendering: overlapping regions -- stacked or
unioned areas, self-crossing paths from data with duplicate or looping
segments -- need NONZERO to render as one solid region rather than
showing a spurious seam.

Run with:
    pixi run example
"""

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas
from canvas_mojo.path import Path, fill_path
from canvas_mojo.fill_rule import FillRule
from canvas_mojo.io.bmp import write_bmp
from canvas_mojo.io.png import write_png


def _square(
    mut p: Path, x0: Float64, y0: Float64, x1: Float64, y1: Float64
) raises:
    p.move_to(x0, y0)
    p.line_to(x1, y0)
    p.line_to(x1, y1)
    p.line_to(x0, y1)
    p.close()


def main() raises:
    var c = Canvas(1200, 600, Color(255, 255, 255))

    var p1 = Path()
    _square(p1, 60.0, 60.0, 360.0, 360.0)
    _square(p1, 210.0, 210.0, 510.0, 510.0)
    fill_path(c, p1, Color(40, 100, 200), fill_rule=FillRule.EVEN_ODD)

    var p2 = Path()
    _square(p2, 660.0, 60.0, 960.0, 360.0)
    _square(p2, 810.0, 210.0, 1110.0, 510.0)
    fill_path(c, p2, Color(40, 100, 200), fill_rule=FillRule.NONZERO)

    write_bmp(c, "examples/out_fill_rule.bmp")
    write_png(c, "examples/out_fill_rule.png")
    print("wrote examples/out_fill_rule.bmp and .png")
