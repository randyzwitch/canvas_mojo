"""Demo: pattern fills -- three of hatch_tile's kinds (canvas.pattern)
used as hatched, print-friendly bar fills via fill_rect_pattern, plus a
small rendered "image" tile sampled under Extend.REPEAT and
Extend.REFLECT side by side, so the two extend modes' seams (or lack
of one) are visible directly.

Run with:
    pixi run example
"""

from canvas.color import Color
from canvas.buffer import Canvas
from canvas.pattern import Extend, Hatch, PatternSource, hatch_tile
from canvas.shapes.circles import fill_circle_aa
from canvas.shapes.rects import fill_rect_pattern
from canvas.io.bmp import write_bmp
from canvas.io.png import write_png


def _image_tile() raises -> Canvas:
    """A small hand-drawn tile standing in for a loaded photo or logo:
    a warm background with an off-center dot, so REPEAT's hard seam at
    every tile edge and REFLECT's seamless mirrored copies are both
    easy to tell apart once tiled across a rectangle.
    """
    var tile = Canvas(48, 48, Color(235, 205, 130))
    fill_circle_aa(tile, 14.0, 14.0, 10.0, Color(180, 60, 50))
    return tile^


def main() raises:
    var width = 1900
    var height = 700
    var c = Canvas(width, height, Color(255, 255, 255))

    var panel_w = 320
    var panel_h = 500
    var gap = 40
    var margin_x = 60
    var top = (height - panel_h) // 2

    var ink = Color(40, 40, 40)
    var bg = Color(245, 245, 245)

    # Three hatched bars -- the print-friendly, colorless alternative
    # to distinguishing bars by hue alone.
    var kinds: List[Hatch] = [Hatch.DIAGONAL, Hatch.CROSS, Hatch.DOTS]
    for i in range(3):
        var x = margin_x + i * (panel_w + gap)
        var tile = hatch_tile(24, 3.0, ink, bg, kinds[i])
        var pattern = PatternSource(tile, Extend.REPEAT)
        fill_rect_pattern(c, x, top, panel_w, panel_h, pattern)

    # A small rendered tile, sampled under REPEAT and REFLECT. REPEAT
    # butts identical copies edge to edge, a hard seam at every tile
    # boundary since the tile's own edges don't already match each
    # other. REFLECT mirrors alternate copies, so every seam meets its
    # own mirror image and the boundary disappears.
    var image = _image_tile()
    var repeat_x = margin_x + 3 * (panel_w + gap)
    var reflect_x = margin_x + 4 * (panel_w + gap)
    fill_rect_pattern(
        c,
        repeat_x,
        top,
        panel_w,
        panel_h,
        PatternSource(image, Extend.REPEAT),
    )
    fill_rect_pattern(
        c,
        reflect_x,
        top,
        panel_w,
        panel_h,
        PatternSource(image, Extend.REFLECT),
    )

    write_bmp(c, "examples/out_patterns.bmp")
    write_png(c, "examples/out_patterns.png")
    print("wrote examples/out_patterns.bmp and .png")
