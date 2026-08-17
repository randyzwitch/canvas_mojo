"""Demo: the arc primitive family -- draw_arc(_aa) for a bare curved
boundary, fill_arc(_aa) for a solid pie-slice wedge, fill_ring_sector
(_aa) for a donut/ring segment. Exact circle math (cos/sin sampled
directly), not a Bezier approximation -- see primitives.mojo's own
_arc_points docstring.

A 3-wedge pie chart and a 2-segment donut chart, the two concrete
shapes this exists for, plus a wedge deliberately spanning the
atan2 +/-pi discontinuity to make _angle_in_span's wraparound handling
visible, not just passing in a test.

Run with:
    pixi run example
"""

from std.math import pi

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas
from canvas_mojo.primitives import draw_arc_aa, fill_arc_aa, fill_ring_sector_aa
from canvas_mojo.io.bmp import write_bmp


def main() raises:
    var c = Canvas(700, 260, Color(255, 255, 255))

    # A simple 3-wedge pie chart.
    var pie_cx = 130.0
    var pie_cy = 130.0
    var pie_r = 100.0
    fill_arc_aa(c, pie_cx, pie_cy, pie_r, 0.0, 2.0 * pi / 3.0, Color(220, 70, 70))
    fill_arc_aa(c, pie_cx, pie_cy, pie_r, 2.0 * pi / 3.0, 4.0 * pi / 3.0, Color(70, 140, 220))
    fill_arc_aa(c, pie_cx, pie_cy, pie_r, 4.0 * pi / 3.0, 2.0 * pi, Color(90, 190, 110))

    # A wedge spanning the atan2 +/-pi discontinuity (centered on
    # angle=-pi/2, i.e. straight up) plus an outline arc around it,
    # showing draw_arc_aa alongside a fill.
    var wedge_cx = 370.0
    var wedge_cy = 130.0
    fill_arc_aa(c, wedge_cx, wedge_cy, 90.0, 5.0 * pi / 4.0, 7.0 * pi / 4.0, Color(150, 60, 200))
    draw_arc_aa(c, wedge_cx, wedge_cy, 95.0, 0.0, 2.0 * pi, Color(180, 180, 180))

    # A 2-segment donut chart.
    var donut_cx = 580.0
    var donut_cy = 130.0
    fill_ring_sector_aa(c, donut_cx, donut_cy, 50.0, 95.0, -pi / 2.0, pi / 2.0, Color(230, 150, 40))
    fill_ring_sector_aa(c, donut_cx, donut_cy, 50.0, 95.0, pi / 2.0, 3.0 * pi / 2.0, Color(60, 130, 190))

    write_bmp(c, "examples/out_arc.bmp")
    print("wrote examples/out_arc.bmp")
