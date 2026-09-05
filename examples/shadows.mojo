"""Demo: blur() and draw_shadowed() -- a card with a drop shadow, and a
glowing marker.

Both are built the same way: the shape is rendered once into its own
transparent layer, then draw_shadowed composites a blurred, tinted,
offset copy of that layer underneath the layer itself. The card's
shadow is offset downward and tinted near-black, the way a raised UI
panel is usually drawn; the glow uses no offset and the shape's own
color, so the blurred copy sits directly behind the shape rather than
below it.

Writes examples/out_shadows.png.
"""

from canvas.blur import draw_shadowed
from canvas.buffer import Canvas
from canvas.color import Color
from canvas.io.png import write_png
from canvas.path import Path, fill_path_aa
from canvas.shapes.circles import fill_circle_aa
from canvas.text.font_cache import FontCache
from canvas.text.render import draw_text

comptime W = 700
comptime H = 380
comptime SHEET = Color(235, 237, 242)
comptime INK = Color(45, 50, 60)
comptime LABEL = Color(90, 95, 105)
comptime CARD = Color(255, 255, 255)
comptime GLOW = Color(60, 140, 230)


def _card_layer(width: Int, height: Int, radius: Float64) raises -> Canvas:
    """A rounded white card, alone on a transparent layer -- the shape
    draw_shadowed tints, blurs and offsets for the drop shadow, then
    draws unchanged on top of it.
    """
    var layer = Canvas(width, height, Color(0, 0, 0, 0))
    var outline = Path()
    outline.round_rect(0.0, 0.0, Float64(width), Float64(height), radius)
    fill_path_aa(layer, outline, CARD)
    return layer^


def main() raises:
    var cache = FontCache()
    var sheet = Canvas(W, H, SHEET)

    draw_text(
        sheet,
        30.0,
        30.0,
        "blur() and draw_shadowed(): a drop shadow and a glow",
        INK,
        size=15.0,
        cache=cache,
    )

    # The card: shadow offset 10px down, tinted near-black at low
    # alpha, blurred with a wide radius for a soft, spread-out shadow.
    var card = _card_layer(280, 180, 18.0)
    draw_shadowed(sheet, card, 70, 90, Color(20, 25, 35, 110), 16.0, 0, 10)
    draw_text(sheet, 110.0, 300.0, "drop shadow", LABEL, size=13.0, cache=cache)

    # The glow: no offset, and the shadow color is the marker's own
    # color rather than black, so the blur reads as a halo around the
    # shape instead of a shadow cast by it.
    var marker = Canvas(90, 90, Color(0, 0, 0, 0))
    fill_circle_aa(marker, 45.0, 45.0, 32.0, GLOW)
    draw_shadowed(sheet, marker, 470, 120, GLOW.with_alpha(160), 22.0, 0, 0)
    draw_text(
        sheet, 460.0, 300.0, "glow (offset 0, 0)", LABEL, size=13.0, cache=cache
    )

    write_png(sheet, "examples/out_shadows.png")
    print("wrote examples/out_shadows.png")
