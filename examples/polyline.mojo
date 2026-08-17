"""Demo: draw_polyline (hard-edged) vs. draw_polyline_aa (anti-
aliased), same zigzag shape, stacked so the joint handling is
directly comparable. Each joint -- hard or AA -- is drawn without
double-blending, even where segments overlap.

Run with:
    pixi run example
"""

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas
from canvas_mojo.geometry import Point
from canvas_mojo.primitives import draw_polyline, draw_polyline_aa
from canvas_mojo.io.bmp import write_bmp


def main() raises:
    var c = Canvas(220, 360, Color(255, 255, 255))

    var zigzag = List[Point]()
    zigzag.append(Point(20, 160))
    zigzag.append(Point(65, 20))
    zigzag.append(Point(110, 160))
    zigzag.append(Point(155, 20))
    zigzag.append(Point(200, 160))
    draw_polyline(c, zigzag, Color(210, 130, 20))

    var zigzag_aa = List[Point]()
    zigzag_aa.append(Point(20, 340))
    zigzag_aa.append(Point(65, 200))
    zigzag_aa.append(Point(110, 340))
    zigzag_aa.append(Point(155, 200))
    zigzag_aa.append(Point(200, 340))
    draw_polyline_aa(c, zigzag_aa, Color(210, 130, 20))

    write_bmp(c, "examples/out_polyline.bmp")
    print("wrote examples/out_polyline.bmp")
