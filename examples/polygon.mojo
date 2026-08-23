"""Demo: draw_polygon (hard-edged outline) vs. draw_polygon_aa
(anti-aliased outline) vs. fill_polygon (solid, hard-edged interior)
vs. fill_polygon_aa (solid, anti-aliased interior), same pentagon,
side by side -- the fourth is fill_polygon's own AA companion, the
same pairing every other filled primitive here (circle/ellipse/arc)
has.

Run with:
    pixi run example
"""

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas
from canvas_mojo.geometry import Point
from canvas_mojo.shapes.lines import draw_polygon, draw_polygon_aa
from canvas_mojo.shapes.polygon_fill import fill_polygon, fill_polygon_aa
from canvas_mojo.io.bmp import write_bmp
from canvas_mojo.io.png import write_png


def main() raises:
    var c = Canvas(3600, 900, Color(255, 255, 255))

    var pentagon = List[Point]()
    pentagon.append(Point(450, 216))
    pentagon.append(Point(666, 378))
    pentagon.append(Point(576, 648))
    pentagon.append(Point(324, 648))
    pentagon.append(Point(234, 378))
    draw_polygon(c, pentagon, Color(20, 130, 150))

    var pentagon_aa = List[Point]()
    pentagon_aa.append(Point(1350, 216))
    pentagon_aa.append(Point(1566, 378))
    pentagon_aa.append(Point(1476, 648))
    pentagon_aa.append(Point(1224, 648))
    pentagon_aa.append(Point(1134, 378))
    draw_polygon_aa(c, pentagon_aa, Color(20, 130, 150))

    var pentagon_fill = List[Point]()
    pentagon_fill.append(Point(2250, 216))
    pentagon_fill.append(Point(2466, 378))
    pentagon_fill.append(Point(2376, 648))
    pentagon_fill.append(Point(2124, 648))
    pentagon_fill.append(Point(2034, 378))
    fill_polygon(c, pentagon_fill, Color(20, 130, 150))

    var pentagon_fill_aa = List[Point]()
    pentagon_fill_aa.append(Point(3150, 216))
    pentagon_fill_aa.append(Point(3366, 378))
    pentagon_fill_aa.append(Point(3276, 648))
    pentagon_fill_aa.append(Point(3024, 648))
    pentagon_fill_aa.append(Point(2934, 378))
    fill_polygon_aa(c, pentagon_fill_aa, Color(20, 130, 150))

    write_bmp(c, "examples/out_polygon.bmp")
    write_png(c, "examples/out_polygon.png")
    print("wrote examples/out_polygon.bmp and .png")
