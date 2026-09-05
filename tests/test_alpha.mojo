"""Tests for per-pixel alpha: transparent-background canvases, the
src-over blend against a translucent destination, and PNG round-trips
that keep an alpha channel.

The property that matters most here is the one that *isn't* new: a
render onto an opaque background must produce exactly what it did
before the canvas had an alpha channel at all. Several of these tests
pin that, alongside the genuinely new behavior.
"""

from std.testing import assert_equal, assert_true, TestSuite

from canvas.buffer import Canvas, BYTES_PER_PIXEL
from canvas.color import Color
from canvas.io.png import write_png, read_png
from canvas.io.bmp import write_bmp
from canvas.resize import downsample
from canvas.shapes.circles import fill_circle_aa
from canvas.shapes.rects import fill_rect

comptime CLEAR = Color(0, 0, 0, 0)
comptime OPAQUE_WHITE = Color(255, 255, 255)
comptime RED = Color(255, 0, 0)
comptime _PNG_PATH = "tests/_test_alpha.png"
comptime _BMP_PATH = "tests/_test_alpha.bmp"


def test_canvas_can_start_fully_transparent() raises:
    var c = Canvas(4, 4, CLEAR)
    var p = c.get_pixel(2, 2)
    assert_equal(p.a, 0, "a cleared canvas has zero alpha")
    assert_equal(len(c.pixels), 4 * 4 * BYTES_PER_PIXEL)


def test_opaque_draw_onto_transparent_becomes_opaque() raises:
    var c = Canvas(8, 8, CLEAR)
    fill_rect(c, 2, 2, 4, 4, RED)
    var inside = c.get_pixel(4, 4)
    assert_equal(inside.r, 255)
    assert_equal(inside.a, 255, "an opaque fill makes the pixel opaque")
    var outside = c.get_pixel(0, 0)
    assert_equal(outside.a, 0, "untouched pixels stay transparent")


def test_translucent_draw_onto_transparent_keeps_its_own_alpha() raises:
    # Source-over onto nothing is the source: the color survives
    # undiluted and the alpha carries straight through. Under the old
    # RGB storage this composited onto the background instead, which is
    # exactly the information that was being thrown away.
    var c = Canvas(8, 8, CLEAR)
    fill_rect(c, 0, 0, 8, 8, Color(200, 100, 50, 128))
    var p = c.get_pixel(4, 4)
    assert_equal(p.r, 200, "color is undiluted over a transparent dst")
    assert_equal(p.g, 100)
    assert_equal(p.b, 50)
    assert_equal(p.a, 128, "alpha carries through")


def test_two_translucent_layers_accumulate_alpha() raises:
    # 128 over 128: out_a = 128 + floor(128 * 127 / 255) = 128 + 63 = 191.
    var c = Canvas(4, 4, CLEAR)
    fill_rect(c, 0, 0, 4, 4, Color(0, 0, 255, 128))
    fill_rect(c, 0, 0, 4, 4, Color(255, 0, 0, 128))
    var p = c.get_pixel(2, 2)
    assert_equal(p.a, 191, "hand-derived accumulated alpha")
    assert_true(p.r > p.b, "the later, redder layer dominates")


def test_blend_onto_opaque_is_unchanged_by_the_alpha_channel() raises:
    # The compatibility guarantee. Drawing translucently onto an opaque
    # background must give the same result it always did, and leave the
    # pixel opaque.
    var c = Canvas(4, 4, OPAQUE_WHITE)
    fill_rect(c, 0, 0, 4, 4, Color(255, 0, 0, 128))
    var p = c.get_pixel(2, 2)
    # (255*128 + 255*127) // 255 = 255 ; (0*128 + 255*127) // 255 = 127
    assert_equal(p.r, 255)
    assert_equal(p.g, 127)
    assert_equal(p.b, 127)
    assert_equal(p.a, 255, "an opaque background stays opaque")


def test_png_round_trips_an_alpha_channel() raises:
    var c = Canvas(16, 16, CLEAR)
    fill_circle_aa(c, 8.0, 8.0, 5.0, Color(20, 120, 220))
    write_png(c, _PNG_PATH)

    var back = read_png(_PNG_PATH)
    assert_equal(back.width, 16)
    assert_equal(back.height, 16)
    for y in range(16):
        for x in range(16):
            var a = c.get_pixel(x, y)
            var b = back.get_pixel(x, y)
            assert_equal(b.r, a.r, "red survives the round trip")
            assert_equal(b.g, a.g, "green survives the round trip")
            assert_equal(b.b, a.b, "blue survives the round trip")
            assert_equal(b.a, a.a, "alpha survives the round trip")


def test_png_uses_color_type_6_only_when_alpha_is_present() raises:
    # The IHDR color-type byte sits at a fixed offset: 8-byte
    # signature + 4-byte length + 4-byte "IHDR" + 4-byte width +
    # 4-byte height + 1-byte bit depth = offset 25.
    var clear_canvas = Canvas(4, 4, CLEAR)
    write_png(clear_canvas, _PNG_PATH)
    var f1 = open(_PNG_PATH, "r")
    var with_alpha = f1.read_bytes()
    f1.close()
    assert_equal(Int(with_alpha[25]), 6, "transparency needs color type 6")

    var opaque = Canvas(4, 4, OPAQUE_WHITE)
    write_png(opaque, _PNG_PATH)
    var f2 = open(_PNG_PATH, "r")
    var no_alpha = f2.read_bytes()
    f2.close()
    assert_equal(
        Int(no_alpha[25]), 2, "a fully opaque image stays color type 2"
    )
    # Deliberately not asserting the type-2 file is *smaller*: at this
    # size DEFLATE's own overhead dominates, and an all-zero RGBA image
    # compresses better than an opaque RGB one. The contract is which
    # color type is emitted, not what it compresses to. What is worth
    # checking is that the narrower file still decodes to fully opaque
    # pixels.
    var reread = read_png(_PNG_PATH)
    for y in range(4):
        for x in range(4):
            assert_equal(
                reread.get_pixel(x, y).a,
                255,
                "a color-type-2 file decodes as fully opaque",
            )


def test_bmp_flattens_transparency_onto_white() raises:
    # 24-bit BMP has nowhere to put alpha. A half-transparent red must
    # land as the same pink an opaque white canvas would have produced,
    # not as raw red and not as black.
    var c = Canvas(2, 2, CLEAR)
    fill_rect(c, 0, 0, 2, 2, Color(255, 0, 0, 128))
    write_bmp(c, _BMP_PATH)
    var f = open(_BMP_PATH, "r")
    var data = f.read_bytes()
    f.close()
    # First pixel of the first stored row, BGR order, after the 54-byte
    # header.
    assert_equal(Int(data[54]), 127, "blue channel flattened onto white")
    assert_equal(Int(data[55]), 127, "green channel flattened onto white")
    assert_equal(Int(data[56]), 255, "red channel")


def test_downsample_averages_alpha() raises:
    # A 2x2 block with one opaque pixel and three transparent ones
    # averages to a quarter alpha -- which is what makes
    # supersample-then-downsample produce a correctly feathered edge on
    # a transparent background.
    var c = Canvas(2, 2, CLEAR)
    c.set_pixel(0, 0, Color(255, 255, 255, 255))
    var small = downsample(c, 2)
    assert_equal(small.width, 1)
    assert_equal(small.get_pixel(0, 0).a, 64, "(255 + 0 + 0 + 0 + 2) // 4")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
