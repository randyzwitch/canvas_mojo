"""Tests for Color, chiefly the blend_over compositing arithmetic."""

from std.testing import assert_equal, TestSuite

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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
