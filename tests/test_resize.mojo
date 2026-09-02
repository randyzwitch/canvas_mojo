"""Tests for resize.mojo: downsample()'s box-filter averaging and its
error paths. Every expected pixel is computed independently, with the
arithmetic given per case below.
"""

from std.testing import assert_equal, assert_raises, TestSuite

from canvas.buffer import Canvas
from canvas.color import Color
from canvas.resize import downsample

comptime BG = Color(0, 0, 0)


def _assert_color(
    c: Canvas, x: Int, y: Int, expected: Color, label: String
) raises:
    var p = c.get_pixel(x, y)
    assert_equal(p.r, expected.r, label)
    assert_equal(p.g, expected.g, label)
    assert_equal(p.b, expected.b, label)


def test_downsample_by_2_averages_each_2x2_block() raises:
    # A 4x4 source at factor=2 gives a 2x2 output: four blocks, each
    # computed via `(sum + n // 2) // n` with n=4, downsample()'s own
    # round-to-nearest formula:
    #   block (0,0): four Color(100,100,100) -- an exact average, no
    #     rounding ambiguity to worry about: (100,100,100).
    #   block (1,0): two Color(0,0,0) + two Color(1,1,1) -- sum=2, n=4,
    #     avg exactly 0.5, (2+2)//4 = 1 -- rounds UP, confirming this
    #     isn't truncating floor division.
    #   block (0,1): three Color(0,0,0) + one Color(1,1,1) -- sum=1,
    #     avg 0.25, (1+2)//4 = 0 -- rounds DOWN.
    #   block (1,1): four distinct colors (50,60,70)/(51,61,71)/
    #     (52,62,72)/(53,63,73) -- r sum=206 (avg 51.5, rounds to 52),
    #     g sum=246 (avg 61.5, rounds to 62), b sum=286 (avg 71.5,
    #     rounds to 72) -- confirmed via python3, not assumed.
    var c = Canvas(4, 4, BG)
    c.set_pixel(0, 0, Color(100, 100, 100))
    c.set_pixel(1, 0, Color(100, 100, 100))
    c.set_pixel(0, 1, Color(100, 100, 100))
    c.set_pixel(1, 1, Color(100, 100, 100))

    c.set_pixel(2, 0, Color(0, 0, 0))
    c.set_pixel(3, 0, Color(0, 0, 0))
    c.set_pixel(2, 1, Color(1, 1, 1))
    c.set_pixel(3, 1, Color(1, 1, 1))

    c.set_pixel(0, 2, Color(0, 0, 0))
    c.set_pixel(1, 2, Color(0, 0, 0))
    c.set_pixel(0, 3, Color(0, 0, 0))
    c.set_pixel(1, 3, Color(1, 1, 1))

    c.set_pixel(2, 2, Color(50, 60, 70))
    c.set_pixel(3, 2, Color(51, 61, 71))
    c.set_pixel(2, 3, Color(52, 62, 72))
    c.set_pixel(3, 3, Color(53, 63, 73))

    var out = downsample(c, 2)
    assert_equal(out.width, 2)
    assert_equal(out.height, 2)
    _assert_color(out, 0, 0, Color(100, 100, 100), "block (0,0): exact average")
    _assert_color(
        out, 1, 0, Color(1, 1, 1), "block (1,0): 0.5 average rounds up"
    )
    _assert_color(
        out, 0, 1, Color(0, 0, 0), "block (0,1): 0.25 average rounds down"
    )
    _assert_color(
        out,
        1,
        1,
        Color(52, 62, 72),
        "block (1,1): four distinct colors, each channel independently rounded",
    )


def test_downsample_by_1_is_a_noop_copy() raises:
    var c = Canvas(3, 2, BG)
    c.set_pixel(0, 0, Color(10, 20, 30))
    c.set_pixel(2, 1, Color(200, 150, 90))
    var out = downsample(c, 1)
    assert_equal(out.width, 3)
    assert_equal(out.height, 2)
    _assert_color(
        out, 0, 0, Color(10, 20, 30), "factor=1 leaves this pixel unchanged"
    )
    _assert_color(
        out, 2, 1, Color(200, 150, 90), "factor=1 leaves this pixel unchanged"
    )
    _assert_color(
        out, 1, 0, BG, "factor=1 leaves untouched pixels at the fill color"
    )


def test_downsample_raises_on_non_positive_factor() raises:
    var c = Canvas(4, 4, BG)
    with assert_raises():
        _ = downsample(c, 0)
    with assert_raises():
        _ = downsample(c, -1)


def test_downsample_raises_when_factor_does_not_evenly_divide_dimensions() raises:
    var c = Canvas(4, 5, BG)
    with assert_raises():
        _ = downsample(c, 2)  # 5 % 2 != 0


def test_large_downsample_matches_a_hand_computed_block_average() raises:
    # Every other test here uses a canvas of a few pixels, which stays
    # under the threshold that splits the work across cores -- so none
    # of them exercise the banded path at all. This one is big enough
    # to be banded, and checks the result against block averages
    # computed independently of the implementation.
    #
    # The source is a deterministic gradient rather than a solid fill,
    # so a band that read or wrote the wrong rows would produce visibly
    # wrong values rather than the same colour by luck.
    var factor = 2
    var out_w = 160
    var out_h = 120
    # Built as a raw buffer rather than through set_pixel, which
    # *composites*: a pixel written with alpha 0 would leave the
    # background showing instead of storing the value this test then
    # expects to read back. The (w, h, pixels) constructor stores exact
    # bytes, which is what lets alpha carry a varying value here at all.
    var sw = out_w * factor
    var sh = out_h * factor
    var raw = List[UInt8](capacity=sw * sh * 4)
    for y in range(sh):
        for x in range(sw):
            raw.append(UInt8(x % 256))
            raw.append(UInt8(y % 256))
            raw.append(UInt8((x + y) % 256))
            raw.append(UInt8((x * 2 + y) % 256))
    var src = Canvas(sw, sh, raw^)

    var small = downsample(src, factor)
    assert_equal(small.width, out_w)
    assert_equal(small.height, out_h)

    var n = factor * factor
    for oy in range(out_h):
        for ox in range(out_w):
            var r = 0
            var g = 0
            var b = 0
            var a = 0
            for dy in range(factor):
                for dx in range(factor):
                    var sx = ox * factor + dx
                    var sy = oy * factor + dy
                    r += sx % 256
                    g += sy % 256
                    b += (sx + sy) % 256
                    a += (sx * 2 + sy) % 256
            var got = small.get_pixel(ox, oy)
            assert_equal(
                Int(got.r),
                (r + n // 2) // n,
                "red block average at (" + String(ox) + ", " + String(oy) + ")",
            )
            assert_equal(Int(got.g), (g + n // 2) // n, "green block average")
            assert_equal(Int(got.b), (b + n // 2) // n, "blue block average")
            assert_equal(Int(got.a), (a + n // 2) // n, "alpha block average")


def test_large_downsample_is_deterministic() raises:
    # Banding makes this concurrent, and a race here would show as the
    # same input producing different output run to run -- which no
    # assertion about a single render can catch.
    # Raw buffer, not set_pixel -- see the block-average test above.
    var raw = List[UInt8](capacity=600 * 400 * 4)
    for y in range(400):
        for x in range(600):
            raw.append(UInt8(x % 251))
            raw.append(UInt8(y % 241))
            raw.append(UInt8((x ^ y) % 239))
            raw.append(UInt8((x + 3 * y) % 253))
    var src = Canvas(600, 400, raw^)

    var first = downsample(src, 2)
    for _ in range(8):
        var again = downsample(src, 2)
        for y in range(first.height):
            for x in range(first.width):
                var a = first.get_pixel(x, y)
                var b = again.get_pixel(x, y)
                assert_equal(a.r, b.r, "repeat downsample matches")
                assert_equal(a.g, b.g)
                assert_equal(a.b, b.b)
                assert_equal(a.a, b.a)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
