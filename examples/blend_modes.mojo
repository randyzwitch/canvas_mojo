"""Demo: blend and composite modes -- what a fill does to the pixels
already there, beyond the default source-over.

Six panels of the same three overlapping translucent disks, each drawn
inside a save/restore pair with a different mode set:

- source-over: the default, each disk laid over the last
- multiply: the overlaps darken, so density reads as density -- what
  a scatter of translucent markers usually wants
- screen: the complementary lightening
- darken: each channel takes the darker of the two, with no blending
  between them
- difference: the overlaps invert against what is under them
- destination-out: the disks cut holes in a solid block rather than
  drawing anything, which is what carves a knockout

The last panel writes transparent pixels, so the PNG shows the page
through them and the BMP, having no alpha channel, shows white.

Run with:
    pixi run example
"""

from canvas.blend import BlendMode
from canvas.buffer import Canvas
from canvas.color import Color
from canvas.io.bmp import write_bmp
from canvas.io.png import write_png
from canvas.shapes.circles import fill_circle_aa
from canvas.shapes.rects import fill_rect
from canvas.text.font_cache import FontCache
from canvas.text.render import draw_text

comptime PAGE = Color(255, 255, 255)
# A mid-tone panel rather than a near-white one: multiply and screen
# move a colour in opposite directions, and neither shows against a
# backdrop already at one end of the range.
comptime PANEL = Color(176, 178, 184)
comptime INK = Color(45, 45, 55)
comptime BLOCK = Color(70, 90, 130)

# Alpha 150 rather than opaque: the modes that differ only in how two
# colours combine need something to combine with.
comptime RED = Color(220, 70, 60, 150)
comptime BLUE = Color(60, 120, 210, 150)
comptime GREEN = Color(80, 180, 110, 150)

comptime PANEL_W = 200
comptime PANEL_H = 180


def _disks(mut c: Canvas, x: Int, y: Int):
    """The three overlapping disks a panel shows, at panel-relative
    positions so every panel draws the same figure.
    """
    fill_circle_aa(c, Float64(x + 78), Float64(y + 68), 44.0, RED)
    fill_circle_aa(c, Float64(x + 128), Float64(y + 68), 44.0, BLUE)
    fill_circle_aa(c, Float64(x + 103), Float64(y + 112), 44.0, GREEN)


def _panel(
    mut c: Canvas,
    x: Int,
    y: Int,
    mode: BlendMode,
    label: String,
    mut cache: FontCache,
) raises:
    """One labelled panel: the backdrop, then the disks under
    `mode`. The mode is set inside a save/restore pair, so the label
    below is drawn source-over whatever the panel used.
    """
    fill_rect(c, x, y, PANEL_W, PANEL_H, PANEL)
    c.save()
    c.set_blend_mode(mode)
    _disks(c, x, y)
    c.restore()
    draw_text(c, x + 4, y + PANEL_H + 18, label, INK, 14.0, cache=cache)


def _cutout_panel(
    mut c: Canvas, x: Int, y: Int, label: String, mut cache: FontCache
) raises:
    """The destination-out panel. The disks carry no colour into the
    result: an opaque source under destination-out drives the pixel's
    alpha to zero, so the block they are drawn over is left with three
    holes in it.
    """
    fill_rect(c, x, y, PANEL_W, PANEL_H, PANEL)
    fill_rect(c, x + 20, y + 20, PANEL_W - 40, PANEL_H - 40, BLOCK)
    c.save()
    c.set_blend_mode(BlendMode.DESTINATION_OUT)
    fill_circle_aa(c, Float64(x + 78), Float64(y + 68), 34.0, Color(0, 0, 0))
    fill_circle_aa(c, Float64(x + 128), Float64(y + 68), 34.0, Color(0, 0, 0))
    fill_circle_aa(c, Float64(x + 103), Float64(y + 112), 34.0, Color(0, 0, 0))
    c.restore()
    draw_text(c, x + 4, y + PANEL_H + 18, label, INK, 14.0, cache=cache)


def main() raises:
    var c = Canvas(3 * PANEL_W + 60, 2 * PANEL_H + 120, PAGE)
    var cache = FontCache()

    draw_text(c, 15, 28, "Blend and composite modes", INK, 18.0, cache=cache)

    var left = 15
    var top = 44
    var step_x = PANEL_W + 15
    var step_y = PANEL_H + 40

    _panel(c, left, top, BlendMode.SOURCE_OVER, "source-over", cache)
    _panel(c, left + step_x, top, BlendMode.MULTIPLY, "multiply", cache)
    _panel(c, left + 2 * step_x, top, BlendMode.SCREEN, "screen", cache)
    _panel(c, left, top + step_y, BlendMode.DARKEN, "darken", cache)
    _panel(
        c,
        left + step_x,
        top + step_y,
        BlendMode.DIFFERENCE,
        "difference",
        cache,
    )
    _cutout_panel(c, left + 2 * step_x, top + step_y, "destination-out", cache)

    write_bmp(c, "examples/out_blend_modes.bmp")
    write_png(c, "examples/out_blend_modes.png")
    print("wrote examples/out_blend_modes.bmp and .png")
