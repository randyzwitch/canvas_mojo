"""Tests for color bitmap glyphs: a `CBLC`/`CBDT` strike (Noto Color
Emoji on Linux) drawn through `draw_text` as a scaled image. Every
test skips, with a note, on a machine with no color-bitmap font that
covers U+1F525, since the fallback resolver then hands back a plain
outline font.
"""

from std.testing import assert_equal, assert_true, TestSuite

from canvas.buffer import Canvas
from canvas.color import Color
from canvas.text.font_cache import FontCache
from canvas.text.font_discovery import (
    FontSlant,
    FontWeight,
    resolve_font_file_for_char,
)
from canvas.text.render import draw_text, measure_text
from canvas.text.ttf import TTFFace

comptime BG = Color(255, 255, 255)
comptime INK = Color(0, 0, 0)
comptime FIRE = 0x1F525


def _emoji_face() raises -> Optional[TTFFace]:
    var path = resolve_font_file_for_char(
        "Sans", FontSlant.NORMAL, FontWeight.NORMAL, FIRE
    )
    try:
        var face = TTFFace(path)
        if not face.has_color_bitmaps():
            return None
        face.set_pixel_size(24)
        return face^
    except e:
        return None


def _skip(name: String):
    print("  skip: no color-bitmap emoji font installed --", name)


def _colored_bbox(c: Canvas) -> Tuple[Int, Int, Int, Int]:
    """The box of pixels that are neither white nor gray: a color
    bitmap's own colors, which no outline fill in INK produces."""
    var min_x = c.width
    var max_x = -1
    var min_y = c.height
    var max_y = -1
    for y in range(c.height):
        for x in range(c.width):
            var p = c.get_pixel(x, y)
            var r = Int(p.r)
            var g = Int(p.g)
            var b = Int(p.b)
            if abs(r - g) > 30 or abs(g - b) > 30:
                min_x = min(min_x, x)
                max_x = max(max_x, x)
                min_y = min(min_y, y)
                max_y = max(max_y, y)
    return (min_x, min_y, max_x, max_y)


def test_strike_metrics_and_decoded_bitmap_agree() raises:
    var maybe = _emoji_face()
    if not maybe:
        _skip("strike metrics")
        return
    var face = maybe.take()
    var gid = face.glyph_index_for_codepoint(FIRE)
    assert_true(gid != 0, "the font maps U+1F525")
    var bm = face.color_bitmap_metrics(gid)
    assert_true(bm.found, "and has a bitmap for it")
    assert_true(bm.ppem > 0 and bm.width > 0 and bm.height > 0)
    var image = face.color_bitmap(gid)
    assert_equal(image[].width, bm.width, "decoded width is the metric")
    assert_equal(image[].height, bm.height)
    # Decoded again: the cache hands back the same image.
    var again = face.color_bitmap(gid)
    assert_equal(again[].width, bm.width)


def test_draw_text_renders_a_color_emoji_after_the_letters() raises:
    var maybe = _emoji_face()
    if not maybe:
        _skip("draw_text")
        return
    var cache = FontCache()
    var c = Canvas(160, 60, BG)
    draw_text(c, 5, 40, "Hi \U0001F525", INK, 24.0, cache=cache)
    var box = _colored_bbox(c)
    assert_true(box[2] >= 0, "colored pixels were drawn")
    var hi = measure_text("Hi ", 24.0, cache=cache).advance
    assert_true(
        Float64(box[0]) >= 5.0 + hi - 2.0,
        "the emoji starts after the letters: " + String(box[0]),
    )
    var width = box[2] - box[0] + 1
    assert_true(
        width >= 18 and width <= 30, "about an em wide: " + String(width)
    )
    # The emoji advances the pen: measuring with it is wider than without.
    var with_emoji = measure_text("Hi \U0001F525", 24.0, cache=cache).advance
    assert_true(with_emoji > hi + 15.0, "advance includes the emoji")


def test_emoji_scales_with_the_size_and_under_a_transform() raises:
    var maybe = _emoji_face()
    if not maybe:
        _skip("scaling")
        return
    var cache = FontCache()
    var small = Canvas(200, 120, BG)
    draw_text(small, 5, 60, "\U0001F525", INK, 24.0, cache=cache)
    var big = Canvas(200, 120, BG)
    draw_text(big, 5, 100, "\U0001F525", INK, 48.0, cache=cache)
    var ws = _colored_bbox(small)[2] - _colored_bbox(small)[0] + 1
    var wb = _colored_bbox(big)[2] - _colored_bbox(big)[0] + 1
    assert_true(
        wb >= 2 * ws - 4 and wb <= 2 * ws + 4,
        "twice the size: " + String(ws) + " -> " + String(wb),
    )
    var scaled = Canvas(200, 120, BG)
    scaled.scale(2.0, 2.0)
    draw_text(scaled, 2.5, 50.0, "\U0001F525", INK, 24.0, cache=cache)
    var wt = _colored_bbox(scaled)[2] - _colored_bbox(scaled)[0] + 1
    assert_true(
        wt >= wb - 4 and wt <= wb + 4,
        "scale(2) at 24 is 48: " + String(wb) + " vs " + String(wt),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
