"""Demo: draw_line (hard-edged) vs. draw_line_aa (anti-aliased),
same slope, so the staircase-vs-smooth difference is directly
comparable at a scale where it's actually easy to see.

Run with:
    pixi run example
"""

from canvas.color import Color
from canvas.buffer import Canvas
from canvas.shapes.lines import draw_line, draw_line_aa
from canvas.io.bmp import write_bmp
from canvas.io.png import write_png


def main() raises:
    var c = Canvas(900, 540, Color(255, 255, 255))

    draw_line(c, 60, 480, 840, 60, Color(120, 120, 120))
    draw_line_aa(c, 60, 525, 840, 105, Color(120, 120, 120))

    write_bmp(c, "examples/out_lines.bmp")
    write_png(c, "examples/out_lines.png")
    print("wrote examples/out_lines.bmp and .png")
