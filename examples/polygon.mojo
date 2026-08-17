"""Demo: draw_polygon (hard-edged outline) vs. draw_polygon_aa
(anti-aliased outline) vs. fill_polygon (solid, hard-edged interior)
vs. fill_polygon_aa (solid, anti-aliased interior), same pentagon,
side by side -- the fourth is fill_polygon's own AA companion, closing
the one inconsistency every other filled primitive (circle/ellipse/
arc) had already closed.

Run with:
    pixi run example
"""

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas
from canvas_mojo.geometry import Point
from canvas_mojo.primitives import draw_polygon, draw_polygon_aa, fill_polygon, fill_polygon_aa
from canvas_mojo.io.bmp import write_bmp


def main() raises:
    var c = Canvas(1200, 300, Color(255, 255, 255))

    var pentagon = List[Point]()
    pentagon.append(Point(150, 72))
    pentagon.append(Point(222, 126))
    pentagon.append(Point(192, 216))
    pentagon.append(Point(108, 216))
    pentagon.append(Point(78, 126))
    draw_polygon(c, pentagon, Color(20, 130, 150))

    var pentagon_aa = List[Point]()
    pentagon_aa.append(Point(450, 72))
    pentagon_aa.append(Point(522, 126))
    pentagon_aa.append(Point(492, 216))
    pentagon_aa.append(Point(408, 216))
    pentagon_aa.append(Point(378, 126))
    draw_polygon_aa(c, pentagon_aa, Color(20, 130, 150))

    var pentagon_fill = List[Point]()
    pentagon_fill.append(Point(750, 72))
    pentagon_fill.append(Point(822, 126))
    pentagon_fill.append(Point(792, 216))
    pentagon_fill.append(Point(708, 216))
    pentagon_fill.append(Point(678, 126))
    fill_polygon(c, pentagon_fill, Color(20, 130, 150))

    var pentagon_fill_aa = List[Point]()
    pentagon_fill_aa.append(Point(1050, 72))
    pentagon_fill_aa.append(Point(1122, 126))
    pentagon_fill_aa.append(Point(1092, 216))
    pentagon_fill_aa.append(Point(1008, 216))
    pentagon_fill_aa.append(Point(978, 126))
    fill_polygon_aa(c, pentagon_fill_aa, Color(20, 130, 150))

    write_bmp(c, "examples/out_polygon.bmp")
    print("wrote examples/out_polygon.bmp")
