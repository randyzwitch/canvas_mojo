"""Tests for Color, chiefly the blend_over compositing arithmetic."""

from std.testing import assert_equal, assert_raises, assert_true, TestSuite

from canvas.color import Color, _div255


def test_opaque_blend_passes_src_through() raises:
    var result = Color(10, 20, 30, 255).blend_over(Color(1, 2, 3))
    assert_equal(result.r, 10)
    assert_equal(result.g, 20)
    assert_equal(result.b, 30)
    assert_equal(result.a, 255)


def test_transparent_blend_passes_bg_through() raises:
    var result = Color(10, 20, 30, 0).blend_over(Color(1, 2, 3, 255))
    assert_equal(result.r, 1)
    assert_equal(result.g, 2)
    assert_equal(result.b, 3)
    assert_equal(result.a, 255)


def test_partial_blend_matches_src_over_formula() raises:
    # sa=128, inv=127
    #   r = (200*128 +   0*127) // 255 = 100
    #   g = (  0*128 + 200*127) // 255 =  99
    #   b = (  0*128 +   0*127) // 255 =   0
    #   a = 128 + (255*127) // 255     = 255
    var result = Color(200, 0, 0, 128).blend_over(Color(0, 200, 0, 255))
    assert_equal(result.r, 100)
    assert_equal(result.g, 99)
    assert_equal(result.b, 0)
    assert_equal(result.a, 255)


def test_div255_is_exact_over_every_numerator_blend_over_forms() raises:
    # blend_over's per-channel numerator is a channel times an alpha
    # plus another channel times the complementary alpha, so it is
    # bounded by 255*255 = 65025. _div255 replaces a real division with
    # a multiply-shift, and the whole point is that it is exact rather
    # than close -- a single off-by-one would shift rendered pixels
    # across the entire package. So this checks every value in range,
    # not a sample.
    for t in range(255 * 255 + 1):
        assert_equal(_div255(t), t // 255, "exact floor division by 255")


def test_blend_over_opaque_matches_blend_over() raises:
    # The specialized path skips the alpha division on the grounds that
    # a Canvas pixel is always opaque, so the result's alpha is always
    # 255. Checked against the general function across the alpha range
    # rather than argued for.
    var bg = Color(17, 200, 90)
    for a in range(256):
        var src = Color(240, 30, 130, UInt8(a))
        var general = src.blend_over(bg)
        var specialized = src.blend_over_opaque(bg.r, bg.g, bg.b)
        assert_equal(specialized.r, general.r, "red matches blend_over")
        assert_equal(specialized.g, general.g, "green matches blend_over")
        assert_equal(specialized.b, general.b, "blue matches blend_over")
        assert_equal(specialized.a, 255, "opaque background stays opaque")


def test_with_alpha_keeps_the_channels() raises:
    var faded = Color(10, 20, 30, 255).with_alpha(128)
    assert_equal(faded.r, 10)
    assert_equal(faded.g, 20)
    assert_equal(faded.b, 30)
    assert_equal(faded.a, 128)


def test_hex_parses_six_digits_as_opaque() raises:
    # 0xff = 255, 0x88 = 8*16 + 8 = 136, 0x00 = 0.
    var c = Color("#ff8800")
    assert_equal(c.r, 255)
    assert_equal(c.g, 136)
    assert_equal(c.b, 0)
    assert_equal(c.a, 255, "six digits carry no alpha, so it is opaque")


def test_hex_parses_eight_digits_with_alpha() raises:
    # 0x40 = 4*16 = 64.
    var c = Color("#0a141e40")
    assert_equal(c.r, 10)
    assert_equal(c.g, 20)
    assert_equal(c.b, 30)
    assert_equal(c.a, 64)


def test_hex_accepts_upper_case_and_a_missing_hash() raises:
    var hashed = Color("#AbCdEf")
    var bare = Color("abcdef")
    assert_equal(hashed.r, bare.r)
    assert_equal(hashed.g, bare.g)
    assert_equal(hashed.b, bare.b)
    # 0xAb = 10*16 + 11 = 171, 0xCd = 12*16 + 13 = 205,
    # 0xEf = 14*16 + 15 = 239.
    assert_equal(hashed.r, 171)
    assert_equal(hashed.g, 205)
    assert_equal(hashed.b, 239)


def test_hex_rejects_a_bad_length_or_digit() raises:
    with assert_raises():
        _ = Color("#fff")  # the 3-digit shorthand is out of scope
    with assert_raises():
        _ = Color("#ff88000")  # seven digits
    with assert_raises():
        _ = Color("#ff88zz")  # 'z' is not a hex digit


def test_to_hex_round_trips_an_opaque_color() raises:
    assert_equal(Color(255, 136, 0).to_hex(), "#ff8800")
    assert_equal(Color(0, 0, 0).to_hex(), "#000000")
    var round_tripped = Color(Color(17, 34, 51).to_hex())
    assert_equal(round_tripped.r, 17)
    assert_equal(round_tripped.g, 34)
    assert_equal(round_tripped.b, 51)


def test_to_hex_leaves_alpha_out() raises:
    # Documented: SVG and CSS both carry opacity separately, and
    # svg.mojo writes `.a` into its own attribute.
    assert_equal(Color(255, 136, 0, 64).to_hex(), "#ff8800")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
