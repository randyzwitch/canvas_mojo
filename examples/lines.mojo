"""Demo: draw_line (hard-edged) vs. draw_line_aa (anti-aliased),
same slope, so the staircase-vs-smooth difference is directly
comparable at a scale where it's actually easy to see.

Run with:
    pixi run example
"""

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas
from canvas_mojo.primitives import draw_line, draw_line_aa
from canvas_mojo.io.bmp import write_bmp


def main() raises:
    var c = Canvas(300, 180, Color(255, 255, 255))

    draw_line(c, 20, 160, 280, 20, Color(120, 120, 120))
    draw_line_aa(c, 20, 175, 280, 35, Color(120, 120, 120))

    write_bmp(c, "examples/out_lines.bmp")
    print("wrote examples/out_lines.bmp")
