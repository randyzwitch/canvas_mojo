"""Tests for resize.mojo: downsample()'s box-filter averaging and its
error paths. Every expected pixel is computed independently, with the
arithmetic given per case below.
"""

from std.testing import (
    assert_equal,
    assert_raises,
    assert_true,
    TestSuite,
)

from canvas.buffer import Canvas
from canvas.color import Color
from canvas.resize import (
    _read_local_bands,
    _L3_SLICE_BYTES,
    _MAX_LOCAL_BANDS,
    _resize_general,
    downsample,
    resize,
)

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
    # computed from the source pattern, weighting each color by its
    # alpha before averaging. Alpha itself is the ordinary mean.
    #
    # The source is a deterministic gradient rather than a solid fill,
    # so a band that read or wrote the wrong rows would produce visibly
    # wrong values rather than the same color by luck.
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
                    var weight = (sx * 2 + sy) % 256
                    r += (sx % 256) * weight
                    g += (sy % 256) * weight
                    b += ((sx + sy) % 256) * weight
                    a += weight
            var got = small.get_pixel(ox, oy)
            assert_equal(
                Int(got.r),
                (r + a // 2) // a if (a + n // 2) // n != 0 else 0,
                "red block average at (" + String(ox) + ", " + String(oy) + ")",
            )
            assert_equal(
                Int(got.g),
                (g + a // 2) // a if (a + n // 2) // n != 0 else 0,
                "green weighted average",
            )
            assert_equal(
                Int(got.b),
                (b + a // 2) // a if (a + n // 2) // n != 0 else 0,
                "blue weighted average",
            )
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


def test_transparent_samples_do_not_darken_red() raises:
    # One of four samples is opaque red: coverage is 1/4, while the
    # straight color stays red. Hidden blue/green must contribute zero.
    for hidden in range(2):
        var c = Canvas(
            2, 2, Color(0, 255, 255, 0) if hidden else Color(0, 0, 0, 0)
        )
        c.set_pixel(0, 0, Color(255, 0, 0))
        var result = downsample(c, 2)
        _assert_color(result, 0, 0, Color(255, 0, 0, 64), "red keeps its color")
        assert_equal(result.get_pixel(0, 0).a, 64)
        var on_black = result.get_pixel(0, 0).blend_over(Color(0, 0, 0))
        var on_white = result.get_pixel(0, 0).blend_over(Color(255, 255, 255))
        assert_equal(on_black.r, 64)
        assert_equal(on_white.r, 255)
        assert_equal(on_white.g, 191)
        assert_equal(on_white.b, 191)


def test_partial_alpha_uses_unrounded_weights() raises:
    # Red contributes 128*255 and blue 64*255. Their 2:1 ratio gives
    # (170, 0, 85), with alpha (128+64)/4 = 48.
    var raw: List[UInt8] = [
        255,
        0,
        0,
        128,
        0,
        0,
        255,
        64,
        0,
        255,
        0,
        0,
        255,
        255,
        255,
        0,
    ]
    var src = Canvas(2, 2, raw^)
    var result = downsample(src, 2)
    _assert_color(result, 0, 0, Color(170, 0, 85, 48), "weighted red and blue")
    assert_equal(result.get_pixel(0, 0).a, 48)


def test_zero_output_alpha_is_transparent_black() raises:
    for alpha in range(2):
        # A total alpha of either 0 or 1 rounds to zero across four
        # samples, so the result is canonical transparent black.
        var raw: List[UInt8] = [
            255,
            0,
            0,
            UInt8(alpha),
            0,
            255,
            0,
            0,
            0,
            0,
            255,
            0,
            255,
            255,
            255,
            0,
        ]
        var src = Canvas(2, 2, raw^)
        var result = downsample(src, 2)
        for channel in range(4):
            assert_equal(result.pixels[channel], 0)


def test_factor_one_preserves_hidden_rgb_and_copies_storage() raises:
    var raw: List[UInt8] = [29, 71, 193, 0, 5, 17, 23, 1]
    var src = Canvas(2, 1, raw^)
    var result = downsample(src, 1)
    for i in range(len(src.pixels)):
        assert_equal(result.pixels[i], src.pixels[i])
    result.pixels[0] = 100
    assert_equal(src.pixels[0], 29)


def test_factor_three_alpha_weighting_and_empty_dimensions() raises:
    # One opaque red sample out of nine gives alpha 255/9 -> 28.
    var src = Canvas(3, 3, Color(0, 255, 0, 0))
    src.set_pixel(1, 1, Color(255, 0, 0))
    var result = downsample(src, 3)
    _assert_color(result, 0, 0, Color(255, 0, 0, 28), "factor three")
    assert_equal(result.get_pixel(0, 0).a, 28)
    var empty = Canvas(0, 6)
    var small = downsample(empty, 3)
    assert_equal(small.width, 0)
    assert_equal(small.height, 2)
    assert_equal(len(small.pixels), 0)


# --- arbitrary-size resize (#298) ----------------------------------
# `resize` generalizes `downsample` to any target size. The property
# that pins it down is that it must still *be* `downsample` wherever
# downsample applies: an integer ratio dividing both dimensions has
# to come back byte for byte, or the two entry points would quietly
# disagree about what averaging means.


def _scene(w: Int, h: Int) raises -> Canvas:
    """Varied color and alpha, including fully transparent pixels
    carrying color -- the case alpha weighting exists for."""
    var c = Canvas(w, h, Color(0, 0, 0, 0))
    for y in range(h):
        for x in range(w):
            var a = (x * 7 + y * 13) % 256
            c.write_pixel(
                x,
                y,
                Color(
                    UInt8((x * 11) % 256),
                    UInt8((y * 17) % 256),
                    UInt8((x * y) % 256),
                    UInt8(a),
                ),
            )
    return c^


def _assert_same(a: Canvas, b: Canvas, label: String) raises:
    assert_equal(a.width, b.width, label + " width")
    assert_equal(a.height, b.height, label + " height")
    for y in range(a.height):
        for x in range(a.width):
            var p = a.get_pixel(x, y)
            var q = b.get_pixel(x, y)
            var at = String(label, " at (", x, ", ", y, ")")
            assert_equal(p.r, q.r, at + " r")
            assert_equal(p.g, q.g, at + " g")
            assert_equal(p.b, q.b, at + " b")
            assert_equal(p.a, q.a, at + " a")


def test_resize_matches_downsample_at_integer_ratios() raises:
    """The equivalence the whole design rests on. Every weight is
    exactly 1 at an integer ratio and the count is exactly the factor,
    so the weighted mean reduces to downsample's block mean."""
    # 60 is divisible by every factor below, so downsample accepts
    # each one; a non-square scene would rule most of them out.
    var factors: List[Int] = [1, 2, 3, 4, 5, 6, 10]
    for fi in range(len(factors)):
        var f = factors[fi]
        var src = _scene(60, 60)
        var want = downsample(src, f)
        var got = resize(src, 60 // f, 60 // f)
        _assert_same(got, want, String("factor ", f))


def test_the_general_filter_still_agrees_with_downsample() raises:
    """`resize` dispatches an integer ratio straight to `downsample`,
    so the row above now compares downsample against itself. This
    reaches past the dispatch and checks the two-pass filter still
    computes the same bytes -- if it ever stops, the dispatch is
    changing output rather than just saving time."""
    var factors: List[Int] = [2, 3, 4, 5, 6, 10]
    for fi in range(len(factors)):
        var f = factors[fi]
        var src = _scene(60, 60)
        var want = downsample(src, f)
        var got = _resize_general(src, 60 // f, 60 // f)
        _assert_same(got, want, String("general filter, factor ", f))


def test_integer_ratio_dispatch_is_not_taken_off_the_grid() raises:
    """Only a single factor shared by both axes may dispatch. An
    anisotropic or non-dividing ratio has to stay on the general
    filter, where downsample would raise or answer a different
    question."""
    var src = _scene(60, 60)
    # 60 % 40 != 0 on either axis.
    var odd = resize(src, 40, 40)
    _assert_same(odd, _resize_general(src, 40, 40), "non-dividing")
    # Divides on both axes, but by different factors.
    var aniso = resize(src, 30, 20)
    _assert_same(aniso, _resize_general(src, 30, 20), "anisotropic")
    # Divides on one axis only.
    var one = resize(src, 30, 41)
    _assert_same(one, _resize_general(src, 30, 41), "one axis")


def test_resize_to_the_same_size_copies_every_byte() raises:
    """Including color under zero alpha, which a filtered round trip
    would flatten -- the same promise downsample makes at factor 1."""
    var src = _scene(17, 11)
    var got = resize(src, 17, 11)
    _assert_same(got, src, "identity")


def test_fractional_and_anisotropic_ratios() raises:
    """Neither axis an integer ratio, and one axis growing while the
    other shrinks -- what downsample cannot express at all."""
    var src = _scene(37, 29)
    var got = resize(src, 13, 41)
    assert_equal(got.width, 13)
    assert_equal(got.height, 41)
    var opaque = Canvas(37, 29, Color(200, 100, 50, 255))
    var flat = resize(opaque, 13, 41)
    for y in range(41):
        for x in range(13):
            var p = flat.get_pixel(x, y)
            var at = String("flat at (", x, ", ", y, ")")
            assert_equal(p.a, 255, at + " a")
            assert_equal(p.r, 200, at + " r")
            assert_equal(p.g, 100, at + " g")
            assert_equal(p.b, 50, at + " b")


def test_transparent_border_does_not_darken_the_edge() raises:
    """A red square on a transparent field, reduced. Alpha weighting
    is what keeps the surviving color red rather than dragging it to
    black, which is the bug #283 fixed for downsample."""
    var src = Canvas(40, 40, Color(0, 0, 0, 0))
    for y in range(10, 30):
        for x in range(10, 30):
            src.write_pixel(x, y, Color(255, 0, 0, 255))
    var got = resize(src, 9, 9)
    for y in range(9):
        for x in range(9):
            var p = got.get_pixel(x, y)
            if p.a > 0:
                assert_equal(
                    p.r, 255, String("edge color at (", x, ", ", y, ")")
                )
                assert_equal(p.g, 0, String("edge g at (", x, ", ", y, ")"))
                assert_equal(p.b, 0, String("edge b at (", x, ", ", y, ")"))


def test_a_checkerboard_reduces_to_its_mean_rather_than_aliasing() raises:
    """The point of an area filter. Point sampling a 1px checkerboard
    down by 8 returns all-black or all-white depending on phase; area
    averaging returns the mean everywhere."""
    var src = Canvas(64, 64, Color(0, 0, 0))
    for y in range(64):
        for x in range(64):
            var v = 255 if (x + y) % 2 == 0 else 0
            src.write_pixel(x, y, Color(UInt8(v), UInt8(v), UInt8(v)))
    var got = resize(src, 8, 8)
    for y in range(8):
        for x in range(8):
            var p = got.get_pixel(x, y)
            var at = String("checker at (", x, ", ", y, ")")
            assert_true(
                Int(p.r) >= 125 and Int(p.r) <= 130,
                at + String(" expected ~128, got ", Int(p.r)),
            )


def test_enlarging_interpolates_rather_than_repeating() raises:
    """A growing axis takes a triangle filter, so a two-pixel ramp
    grows into a gradient. An area filter would collapse to
    nearest-neighbor and give two flat halves."""
    var src = Canvas(2, 1, Color(0, 0, 0))
    src.write_pixel(0, 0, Color(0, 0, 0))
    src.write_pixel(1, 0, Color(255, 255, 255))
    var got = resize(src, 16, 1)
    var distinct = 0
    var seen = List[Bool](length=256, fill=False)
    for x in range(16):
        var v = Int(got.get_pixel(x, 0).r)
        if not seen[v]:
            seen[v] = True
            distinct += 1
    assert_true(
        distinct >= 8,
        String("expected a ramp, got ", distinct, " distinct levels"),
    )
    assert_true(
        Int(got.get_pixel(0, 0).r) < Int(got.get_pixel(15, 0).r),
        "the ramp must run dark to light",
    )


def test_one_pixel_inputs_and_outputs() raises:
    var one = Canvas(1, 1, Color(70, 140, 210, 190))
    var grown = resize(one, 5, 4)
    for y in range(4):
        for x in range(5):
            var p = grown.get_pixel(x, y)
            assert_equal(p.r, 70, "grown r")
            assert_equal(p.g, 140, "grown g")
            assert_equal(p.b, 210, "grown b")
            assert_equal(p.a, 190, "grown a")
    var src = _scene(9, 7)
    var tiny = resize(src, 1, 1)
    assert_equal(tiny.width, 1)
    assert_equal(tiny.height, 1)


def test_resize_is_identical_at_every_worker_count() raises:
    """Both passes are banded, so the split must not change the
    picture -- including one band, which takes the serial path."""
    var src = _scene(200, 150)
    var reference = resize(src, 83, 61)
    var caps: List[Int] = [1, 2, 3, 8, 64]
    for ci in range(len(caps)):
        var s = _scene(200, 150)
        s.set_max_workers(caps[ci])
        var got = resize(s, 83, 61)
        _assert_same(got, reference, String("workers ", caps[ci]))


def test_resize_rejects_a_degenerate_target() raises:
    var src = _scene(8, 8)
    with assert_raises():
        _ = resize(src, 0, 4)
    with assert_raises():
        _ = resize(src, 4, -1)


def test_read_local_bands_caps_a_source_inside_one_l3_slice() raises:
    # Below the slice the source is already in one CCX's L3, and
    # spreading the read further costs more in cross-CCX traffic than
    # it buys -- 64 bands measured slower than 16 on a 7.7 MB source.
    var small = _L3_SLICE_BYTES - 1
    assert_equal(_read_local_bands(small, 64), _MAX_LOCAL_BANDS)
    assert_equal(_read_local_bands(small, 8), 8)
    assert_equal(_read_local_bands(small, 1), 1)


def test_read_local_bands_leaves_a_source_past_the_slice_alone() raises:
    # Past the slice the read is going to DRAM whatever happens, and
    # more bands keep helping.
    var big = _L3_SLICE_BYTES
    assert_equal(_read_local_bands(big, 64), 64)
    assert_equal(_read_local_bands(big, 8), 8)


def test_capped_downsample_matches_an_uncapped_one_byte_for_byte() raises:
    # The cap changes only how the work is divided.
    var src = Canvas(200, 160, Color(200, 100, 50))
    for y in range(0, 160, 7):
        src.fill_rect(0, y, 200, 3, Color(10, 220, 90, 180))

    src.set_max_workers(64)
    var many = downsample(src, 2)
    src.set_max_workers(1)
    var one = downsample(src, 2)

    assert_equal(len(many.pixels), len(one.pixels))
    for i in range(len(many.pixels)):
        assert_equal(many.pixels[i], one.pixels[i])


def test_every_downsample_kernel_writes_every_output_byte() raises:
    # The output buffer is allocated without being cleared, on the
    # grounds that every byte is written before anything reads it. That
    # is only true if each kernel covers its whole band, so this walks
    # the factors that select different kernels -- 2, 3 and 4 are
    # compile-time block sizes, 5 and 7 take the general path -- and
    # checks the result against the block average computed here.
    var factors: List[Int] = [2, 3, 4, 5, 7]
    for fi in range(len(factors)):
        var f = factors[fi]
        var w = f * 5
        var h = f * 3
        var src = Canvas(w, h, Color(0, 0, 0))
        for y in range(h):
            for x in range(w):
                src.set_pixel(
                    x, y, Color(UInt8((x * 7 + y * 13) % 256), 90, 40, 255)
                )
        var out = downsample(src, f)
        assert_equal(out.width, 5)
        assert_equal(out.height, 3)
        for oy in range(3):
            for ox in range(5):
                var total = 0
                for dy in range(f):
                    for dx in range(f):
                        total += Int(src.get_pixel(ox * f + dx, oy * f + dy).r)
                var want = (total + (f * f) // 2) // (f * f)
                var got = Int(out.get_pixel(ox, oy).r)
                if got != want:
                    raise Error(
                        "factor "
                        + String(f)
                        + " at ("
                        + String(ox)
                        + ","
                        + String(oy)
                        + "): got "
                        + String(got)
                        + ", want "
                        + String(want)
                    )
                assert_equal(out.get_pixel(ox, oy).a, 255)


def test_fully_transparent_blocks_downsample_to_transparent_black() raises:
    # The zero-alpha branch writes all four channels explicitly rather
    # than relying on the buffer arriving cleared, which matters now
    # that it does not.
    var factors: List[Int] = [2, 3, 5]
    for fi in range(len(factors)):
        var f = factors[fi]
        var src = Canvas(f * 4, f * 2, Color(200, 100, 50, 0))
        var out = downsample(src, f)
        for oy in range(2):
            for ox in range(4):
                var p = out.get_pixel(ox, oy)
                assert_equal(p.r, 0)
                assert_equal(p.g, 0)
                assert_equal(p.b, 0)
                assert_equal(p.a, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
