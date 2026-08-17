"""Demo: FillRule.EVEN_ODD vs FillRule.NONZERO on the same
self-overlapping shape -- two same-direction-wound squares as two
sub-paths of one Path.

EVEN_ODD (the default) counts crossings; the overlap region has been
crossed twice, so it's "outside" again -- a hole appears exactly where
the two squares cover each other. NONZERO tracks signed winding
instead; both squares wind the same direction, so the overlap's signed
count is 2 (not 0) -- nonzero, so filled solid, no hole. Same input
shape, only the fill rule differs, to make the divergence obvious
rather than needing two different shapes to compare.

See fill_rule.mojo's own module docstring for why this matters for
chart rendering: overlapping regions (stacked/unioned areas, self-
crossing paths from data with duplicate or looping segments) need
NONZERO to render as one solid region rather than showing a spurious
seam.

Run with:
    pixi run example
"""

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas
from canvas_mojo.path import Path, fill_path
from canvas_mojo.fill_rule import FillRule
from canvas_mojo.io.bmp import write_bmp


def _square(mut p: Path, x0: Float64, y0: Float64, x1: Float64, y1: Float64) raises:
    p.move_to(x0, y0)
    p.line_to(x1, y0)
    p.line_to(x1, y1)
    p.line_to(x0, y1)
    p.close()


def main() raises:
    var c = Canvas(400, 200, Color(255, 255, 255))

    var p1 = Path()
    _square(p1, 20.0, 20.0, 120.0, 120.0)
    _square(p1, 70.0, 70.0, 170.0, 170.0)
    fill_path(c, p1, Color(40, 100, 200), fill_rule=FillRule.EVEN_ODD)

    var p2 = Path()
    _square(p2, 220.0, 20.0, 320.0, 120.0)
    _square(p2, 270.0, 70.0, 370.0, 170.0)
    fill_path(c, p2, Color(40, 100, 200), fill_rule=FillRule.NONZERO)

    write_bmp(c, "examples/out_fill_rule.bmp")
    print("wrote examples/out_fill_rule.bmp")
