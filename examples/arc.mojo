"""Demo: the arc primitive family -- draw_arc(_aa) for a bare curved
boundary, fill_arc(_aa) for a solid pie-slice wedge, fill_ring_sector
(_aa) for a donut/ring segment. Exact circle math (cos/sin sampled
directly), not a Bezier approximation -- see
canvas.shapes.arcs._arc_points.

A 3-wedge pie chart and a 2-segment donut chart, plus a wedge spanning
the atan2 +/-pi discontinuity, which makes _angle_in_span's wraparound
handling visible rather than only tested.

Run with:
    pixi run example
"""

from std.math import pi

from canvas.color import Color
from canvas.buffer import Canvas
from canvas.shapes.arcs import (
    draw_arc_aa,
    fill_arc_aa,
    fill_ring_sector_aa,
)
from canvas.io.bmp import write_bmp
from canvas.io.png import write_png


def main() raises:
    var c = Canvas(2100, 780, Color(255, 255, 255))

    # A simple 3-wedge pie chart.
    var pie_cx = 390.0
    var pie_cy = 390.0
    var pie_r = 300.0
    fill_arc_aa(
        c, pie_cx, pie_cy, pie_r, 0.0, 2.0 * pi / 3.0, Color(220, 70, 70)
    )
    fill_arc_aa(
        c,
        pie_cx,
        pie_cy,
        pie_r,
        2.0 * pi / 3.0,
        4.0 * pi / 3.0,
        Color(70, 140, 220),
    )
    fill_arc_aa(
        c, pie_cx, pie_cy, pie_r, 4.0 * pi / 3.0, 2.0 * pi, Color(90, 190, 110)
    )

    # A wedge spanning the atan2 +/-pi discontinuity (centered on
    # angle=-pi/2, i.e. straight up) plus an outline arc around it,
    # showing draw_arc_aa alongside a fill.
    var wedge_cx = 1110.0
    var wedge_cy = 390.0
    fill_arc_aa(
        c,
        wedge_cx,
        wedge_cy,
        270.0,
        5.0 * pi / 4.0,
        7.0 * pi / 4.0,
        Color(150, 60, 200),
    )
    draw_arc_aa(
        c, wedge_cx, wedge_cy, 285.0, 0.0, 2.0 * pi, Color(180, 180, 180)
    )

    # A 2-segment donut chart.
    var donut_cx = 1740.0
    var donut_cy = 390.0
    fill_ring_sector_aa(
        c,
        donut_cx,
        donut_cy,
        150.0,
        285.0,
        -pi / 2.0,
        pi / 2.0,
        Color(230, 150, 40),
    )
    fill_ring_sector_aa(
        c,
        donut_cx,
        donut_cy,
        150.0,
        285.0,
        pi / 2.0,
        3.0 * pi / 2.0,
        Color(60, 130, 190),
    )

    write_bmp(c, "examples/out_arc.bmp")
    write_png(c, "examples/out_arc.png")
    print("wrote examples/out_arc.bmp and .png")
