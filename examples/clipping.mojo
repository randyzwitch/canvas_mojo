"""Demo: push_clip/pop_clip restrict drawing to a sub-rectangle, with no
changes to any primitive -- they all write through Canvas.set_pixel
already. Content that would normally spill past the boundary (a big
circle, a full-width diagonal line) is cut off cleanly at the clip edge.

Also demonstrates nesting: a second, oversized clip pushed inside the
first still cannot draw outside the parent's region, because push_clip
intersects with whatever is already active rather than replacing it --
what a stack gives over a single settable rect (see canvas/buffer.mojo's
push_clip).

Run with:
    pixi run example
"""

from canvas.color import Color
from canvas.buffer import Canvas
from canvas.shapes.rects import draw_rect
from canvas.shapes.lines import draw_line
from canvas.shapes.circles import fill_circle_aa
from canvas.io.bmp import write_bmp
from canvas.io.png import write_png


def main() raises:
    var c = Canvas(900, 600, Color(255, 255, 255))

    # mark the plot area's boundary before clipping anything; drawn
    # unclipped, so it stays a crisp full rectangle
    draw_rect(c, 150, 150, 600, 300, Color(180, 180, 180))

    c.push_clip(150, 150, 600, 300)

    # both of these are sized/positioned to spill well past the clip
    # boundary on every side
    fill_circle_aa(c, 450, 300, 270, Color(40, 100, 200))
    draw_line(c, 0, 0, 899, 599, Color(220, 60, 40))

    # a nested clip, deliberately larger than its parent on every side
    # -- still confined to the parent's region, not its own
    c.push_clip(0, 0, 900, 600)
    fill_circle_aa(c, 300, 180, 105, Color(230, 200, 40))
    c.pop_clip()  # back to just the outer clip

    c.pop_clip()  # back to no clip

    write_bmp(c, "examples/out_clipping.bmp")
    write_png(c, "examples/out_clipping.png")
    print("wrote examples/out_clipping.bmp and .png")
