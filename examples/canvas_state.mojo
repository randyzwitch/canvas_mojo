"""Demo: the canvas transform state -- save/restore with translate,
rotate and scale, the way Cairo and the HTML5 canvas carry a current
transform. Every primitive maps through it, so a shape drawn at the
origin lands wherever the current frame puts it.

Four panels of the same little scene (a filled rect, a circle, a
stroked path, a label), each drawn with the same coordinates inside a
save/restore pair:

- top left: translated only
- top right: translated and rotated a sixth of a turn
- bottom left: translated and scaled 1.4x -- the stroke width and the
  text scale with it
- bottom right: a y-up frame, translate(...) then scale(1.0, -1.0),
  which is how a chart maps data whose y increases upward; the text
  is drawn after the frame is restored, since a mirrored label reads
  backwards

The rotated panel also clips to its own rectangle: push_clip under a
rotation becomes a rotated clip path, and restore() pops it.

Run with:
    pixi run example
"""

from std.math import pi

from canvas.color import Color
from canvas.buffer import Canvas
from canvas.path import Path, stroke_path_aa
from canvas.shapes.circles import fill_circle_aa
from canvas.shapes.rects import draw_rect, fill_rect
from canvas.text.font_cache import FontCache
from canvas.text.render import draw_text
from canvas.io.bmp import write_bmp
from canvas.io.png import write_png

comptime PANEL = Color(245, 243, 238)
comptime FRAME = Color(190, 185, 175)
comptime FILL = Color(60, 120, 200)
comptime DOT = Color(220, 90, 60)
comptime INK = Color(40, 40, 50)


def scene(mut c: Canvas, mut cache: FontCache, label: Bool) raises:
    """One panel's content, always drawn in the same local coordinates:
    the frame decides where it ends up.
    """
    fill_rect(c, 20, 20, 120, 70, FILL)
    fill_circle_aa(c, 190.0, 55.0, 30.0, DOT)
    var p = Path()
    p.move_to(20.0, 130.0)
    p.cubic_curve_to(80.0, 70.0, 140.0, 190.0, 220.0, 130.0)
    stroke_path_aa(c, p, INK, width=4.0)
    if label:
        draw_text(c, 20, 175, "same coordinates", INK, 16.0, cache=cache)


def main() raises:
    var c = Canvas(900, 600, Color(255, 255, 255))
    var cache = FontCache()

    # Panel outlines, in device space, before any transform.
    draw_rect(c, 30, 30, 400, 260, FRAME)
    draw_rect(c, 470, 30, 400, 260, FRAME)
    draw_rect(c, 30, 320, 400, 260, FRAME)
    draw_rect(c, 470, 320, 400, 260, FRAME)

    # Top left: a translation puts the local origin at the panel's
    # top-left corner.
    c.save()
    c.translate(60.0, 50.0)
    scene(c, cache, True)
    c.restore()

    # Top right: rotated about the panel's centre. The clip is pushed
    # under the rotation, so it is a rotated rectangle too.
    c.save()
    c.translate(670.0, 160.0)
    c.rotate(pi / 6.0)
    c.translate(-120.0, -100.0)
    c.push_clip(0, 0, 240, 200)
    fill_rect(c, 0, 0, 240, 200, PANEL)
    scene(c, cache, True)
    c.restore()

    # Bottom left: scaled 1.5x. Stroke widths and text scale with the
    # shapes, since strokes are built in user space.
    c.save()
    c.translate(50.0, 325.0)
    c.scale(1.4, 1.4)
    scene(c, cache, True)
    c.restore()

    # Bottom right: a y-up frame with the origin at the panel's bottom
    # left, the arrangement a chart's data space wants. Shapes drawn
    # with y increasing upward land right side up; the label is drawn
    # afterwards, outside the frame, so it reads left to right.
    c.save()
    c.translate(500.0, 570.0)
    c.scale(1.0, -1.0)
    scene(c, cache, False)
    c.restore()
    draw_text(c, 500, 350, "y-up frame", INK, 16.0, cache=cache)

    write_bmp(c, "examples/out_canvas_state.bmp")
    write_png(c, "examples/out_canvas_state.png")
    print("wrote examples/out_canvas_state.bmp and .png")
