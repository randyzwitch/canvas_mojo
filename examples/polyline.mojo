"""Demo: draw_polyline (hard-edged) vs. draw_polyline_aa (anti-
aliased), same zigzag shape, stacked so the joint handling is
directly comparable. Each joint -- hard or AA -- is drawn without
double-blending, even where segments overlap.

Run with:
    pixi run example
"""

from canvas.color import Color
from canvas.buffer import Canvas
from canvas.geometry import Point
from canvas.shapes.lines import draw_polyline, draw_polyline_aa
from canvas.io.bmp import write_bmp
from canvas.io.png import write_png


def main() raises:
    var c = Canvas(660, 1080, Color(255, 255, 255))

    var zigzag = List[Point]()
    zigzag.append(Point(60, 480))
    zigzag.append(Point(195, 60))
    zigzag.append(Point(330, 480))
    zigzag.append(Point(465, 60))
    zigzag.append(Point(600, 480))
    draw_polyline(c, zigzag, Color(210, 130, 20))

    var zigzag_aa = List[Point]()
    zigzag_aa.append(Point(60, 1020))
    zigzag_aa.append(Point(195, 600))
    zigzag_aa.append(Point(330, 1020))
    zigzag_aa.append(Point(465, 600))
    zigzag_aa.append(Point(600, 1020))
    draw_polyline_aa(c, zigzag_aa, Color(210, 130, 20))

    write_bmp(c, "examples/out_polyline.bmp")
    write_png(c, "examples/out_polyline.png")
    print("wrote examples/out_polyline.bmp and .png")
