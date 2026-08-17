"""Tests for Color, chiefly the blend_over compositing arithmetic."""

from std.testing import assert_equal, TestSuite

from canvas_mojo.color import Color


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
