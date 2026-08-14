"""Demo: draw_text() rendering real system-font text -- font matching
via fontconfig, glyph outlines/metrics via FreeType, rasterization via
this package's own fill_path_aa (see canvas_mojo/text.mojo's module
docstring) -- composited onto a Canvas the same way every other
primitive is: through set_pixel.

Run with:
    pixi run example
"""

from std.math import pi

from canvas_mojo.font_discovery import FontSlant, FontWeight

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas
from canvas_mojo.text import draw_text, measure_text_block, TextAlign
from canvas_mojo.primitives import draw_rect
from canvas_mojo.io.bmp import write_bmp


def main() raises:
    var c = Canvas(600, 480, Color(250, 250, 248))

    draw_text(c, 20, 50, "The quick brown fox", Color(20, 24, 32), 28.0)
    draw_text(c, 20, 90, "jumps over the lazy dog", Color(60, 70, 90), 22.0)

    # Translucent color, over a non-white background further down --
    # exercises the same unpremultiply + set_pixel blend path as any
    # other translucent primitive, not just the common opaque case.
    draw_text(c, 20, 140, "translucent overlay text", Color(200, 30, 30, 140), 26.0)
    draw_text(
        c,
        20,
        180,
        "bold italic",
        Color(30, 90, 40),
        26.0,
        weight=FontWeight.BOLD,
        slant=FontSlant.ITALIC,
    )

    # Multi-line: one draw_text call, "\n"-separated -- line-break
    # handling this module does itself (see _layout_block).
    draw_text(c, 20, 230, "first line\nsecond line\nthird line", Color(20, 24, 32), 20.0)

    # Rotation: tilted axis-tick-label-style text, and a fully
    # vertical y-axis-label-style one -- both rotate around their own
    # (x, y) anchor, marked here with a small dot for reference.
    draw_text(c, 250, 250, "tilted 20deg", Color(120, 40, 150), 20.0, rotation=pi / 9.0)
    c.set_pixel(250, 250, Color(255, 0, 0))
    draw_text(c, 250, 350, "vertical label", Color(120, 40, 150), 20.0, rotation=-pi / 2.0)
    c.set_pixel(250, 350, Color(255, 0, 0))

    # Alignment: left/center/right all anchored on the same x -- a
    # guide line marks that shared anchor so the three relationships
    # (starts at, straddles, ends at) are visible directly.
    var guide_x = 480
    for yy in range(200, 340):
        c.set_pixel(guide_x, yy, Color(210, 210, 210))
    draw_text(c, guide_x, 220, "left", Color(20, 90, 180), 22.0, align=TextAlign.LEFT)
    draw_text(c, guide_x, 260, "centered", Color(20, 140, 60), 22.0, align=TextAlign.CENTER)
    draw_text(c, guide_x, 300, "right", Color(180, 40, 40), 22.0, align=TextAlign.RIGHT)

    # measure_text_block: the axis-label-layout use case -- know a
    # rotated block's footprint (e.g. to reserve chart margin, or
    # check for overlap with a neighboring label) before drawing it.
    # Draw the same rotated, multi-line block twice: once for real,
    # once as an outline rect built purely from measure_text_block's
    # predicted box, anchor-relative offsets added onto the same
    # (x, y) -- if the outline hugs the rendered ink, the prediction
    # and the render agree, not just in theory.
    var label_x = 120
    var label_y = 400
    var label_text = "y-axis\nlabel"
    var label_rotation = -pi / 2.0
    draw_text(c, label_x, label_y, label_text, Color(20, 24, 32), 20.0, rotation=label_rotation)
    c.set_pixel(label_x, label_y, Color(255, 0, 0))
    var bounds = measure_text_block(label_text, 20.0, rotation=label_rotation)
    draw_rect(
        c,
        label_x + Int(bounds.x),
        label_y + Int(bounds.y),
        Int(bounds.width),
        Int(bounds.height),
        Color(180, 180, 180),
    )

    write_bmp(c, "canvas_mojo/examples/out_text.bmp")
    print("wrote canvas_mojo/examples/out_text.bmp")
