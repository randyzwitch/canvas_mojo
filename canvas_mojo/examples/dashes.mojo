"""Demo: dash patterns on both a hard-edged and an AA line, plus a
dashed polygon outline -- proving the dash phase actually carries
across joints rather than resetting at each corner (see
draw_polyline's own docstring). Long enough dash/gap lengths at this
scale to count individual dashes by eye, not just see "a dotted-ish
line".

Run with:
    pixi run example
"""

from std.math import cos, pi, sin

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas
from canvas_mojo.geometry import Point
from canvas_mojo.primitives import draw_line, draw_line_aa, draw_polygon, draw_polygon_aa
from canvas_mojo.io.bmp import write_bmp


def main() raises:
    var c = Canvas(360, 300, Color(255, 255, 255))
    var dashes: List[Float64] = [16.0, 8.0]

    draw_line(c, 20, 40, 340, 40, Color(120, 120, 120), dashes)
    draw_line_aa(c, 20, 70, 340, 70, Color(120, 120, 120), dashes=dashes)

    # A pentagon outline -- large enough, with a dash period short
    # enough relative to each edge's length, that a phase reset at any
    # vertex would be visible as two dashes landing back-to-back
    # (or a gap doubling) right at that corner instead of the pattern
    # just continuing through it.
    var cx = 180.0
    var cy = 195.0
    var r = 110.0
    var points = List[Point]()
    for i in range(5):
        var angle = -pi / 2.0 + Float64(i) * (2.0 * pi / 5.0)
        var x = cx + r * cos(angle)
        var y = cy + r * sin(angle)
        points.append(Point(Int(x), Int(y)))
    draw_polygon_aa(c, points, Color(40, 100, 200), dashes=dashes)

    write_bmp(c, "canvas_mojo/examples/out_dashes.bmp")
    print("wrote canvas_mojo/examples/out_dashes.bmp")
