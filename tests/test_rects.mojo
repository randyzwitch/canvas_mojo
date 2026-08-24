"""Tests for canvas_mojo/shapes/rects.mojo: exact pixel sets for known
inputs, verified against hand-traced runs of the same algorithms.
"""

from std.testing import assert_equal, TestSuite

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas
from canvas_mojo.gradient import LinearGradient, RadialGradient
from canvas_mojo.shapes.rects import (
    draw_rect,
    fill_rect,
    fill_rect_gradient,
    fill_rect_radial_gradient,
)

comptime BG = Color(0, 0, 0)
comptime FG = Color(255, 255, 255)


def _assert_pixel(c: Canvas, x: Int, y: Int, expected: Color, label: String) raises:
    var p = c.get_pixel(x, y)
    assert_equal(p.r, expected.r, label + " (r)")
    assert_equal(p.g, expected.g, label + " (g)")
    assert_equal(p.b, expected.b, label + " (b)")


def test_draw_rect_stroke_outline_only() raises:
    var c = Canvas(5, 5, BG)
    draw_rect(c, 1, 1, 3, 3, FG)
    # the 8 border pixels of the 3x3 box at (1,1)-(3,3)
    _assert_pixel(c, 1, 1, FG, "top-left corner")
    _assert_pixel(c, 2, 1, FG, "top edge")
    _assert_pixel(c, 3, 1, FG, "top-right corner")
    _assert_pixel(c, 1, 2, FG, "left edge")
    _assert_pixel(c, 3, 2, FG, "right edge")
    _assert_pixel(c, 1, 3, FG, "bottom-left corner")
    _assert_pixel(c, 2, 3, FG, "bottom edge")
    _assert_pixel(c, 3, 3, FG, "bottom-right corner")
    # stroke only -- the interior stays background
    _assert_pixel(c, 2, 2, BG, "interior untouched by stroke")


def test_draw_rect_stroke_does_not_double_blend_corners() raises:
    # Canvas starts pure black. A translucent stroke color blended
    # once gives a known result; if a corner got drawn twice (e.g. by
    # the top and left edges both touching it), the second blend
    # would compound and produce a visibly different value.
    var c = Canvas(5, 5, Color(0, 0, 0))
    var translucent = Color(200, 0, 0, 128)
    draw_rect(c, 1, 1, 3, 3, translucent)

    # single-blend arithmetic (same formula as test_color.mojo):
    #   sa=128, inv=127
    #   r = (200*128 + 0*127) // 255 = 100
    var corner = c.get_pixel(1, 1)
    assert_equal(corner.r, 100)
    assert_equal(corner.g, 0)
    assert_equal(corner.b, 0)


def test_fill_rect_fills_solid_block() raises:
    var c = Canvas(5, 5, BG)
    fill_rect(c, 1, 1, 3, 3, FG)
    for y in range(1, 4):
        for x in range(1, 4):
            _assert_pixel(c, x, y, FG, "filled interior")
    _assert_pixel(c, 0, 0, BG, "outside the fill")
    _assert_pixel(c, 4, 4, BG, "outside the fill")


def test_fill_rect_gradient_matches_gradient_color_at_per_pixel() raises:
    # The gradient and midpoint value from test_gradient.mojo's
    # test_color_at_midpoint_interpolates_linearly, so fill_rect_gradient
    # queries color_at per pixel rather than averaging one color for
    # the whole rect.
    var g = LinearGradient(0.0, 0.0, 100.0, 0.0)
    g.add_stop(0.0, Color(0, 0, 0, 255))
    g.add_stop(1.0, Color(255, 255, 255, 255))

    var c = Canvas(100, 10, Color(50, 50, 50))
    fill_rect_gradient(c, 0, 0, 100, 10, g)

    _assert_pixel(c, 0, 5, Color(0, 0, 0), "left edge -> first stop's color")
    _assert_pixel(c, 50, 5, Color(128, 128, 128), "midpoint -> interpolated")
    # x=99, not 100 (out of the 0..99 pixel range for a 100-wide rect)
    # -> t=0.99, not 1.0 -- 0 + 0.99*255 = 252.45, rounds to 252, not
    # the last stop's exact 255 (that's only reached at x=100, off
    # the rect entirely).
    _assert_pixel(c, 99, 5, Color(252, 252, 252), "near right edge -> close to, not exactly, the last stop's color")


def test_fill_rect_gradient_zero_size_is_a_noop() raises:
    var g = LinearGradient(0.0, 0.0, 10.0, 0.0)
    g.add_stop(0.0, Color(255, 0, 0))
    var c = Canvas(10, 10, BG)
    fill_rect_gradient(c, 2, 2, 0, 5, g)
    fill_rect_gradient(c, 2, 2, 5, 0, g)
    _assert_pixel(c, 2, 2, BG, "zero width/height draws nothing")


def test_fill_rect_radial_gradient_matches_gradient_color_at_per_pixel() raises:
    # center (0,0), radius 10: (6,8) is exactly distance 10 (a 6-8-10
    # triangle, 3-4-5 doubled), so its color lands exactly on the last
    # stop rather than near it -- fill_rect_radial_gradient queries
    # color_at per pixel.
    var g = RadialGradient(0.0, 0.0, 10.0)
    g.add_stop(0.0, Color(0, 0, 0, 255))
    g.add_stop(1.0, Color(255, 255, 255, 255))

    var c = Canvas(11, 11, Color(50, 50, 50))
    fill_rect_radial_gradient(c, 0, 0, 11, 11, g)

    _assert_pixel(c, 0, 0, Color(0, 0, 0), "center -> first stop's color")
    _assert_pixel(c, 6, 8, Color(255, 255, 255), "exact radius -> last stop's color")


def test_fill_rect_radial_gradient_zero_size_is_a_noop() raises:
    var g = RadialGradient(0.0, 0.0, 10.0)
    g.add_stop(0.0, Color(255, 0, 0))
    var c = Canvas(10, 10, BG)
    fill_rect_radial_gradient(c, 2, 2, 0, 5, g)
    fill_rect_radial_gradient(c, 2, 2, 5, 0, g)
    _assert_pixel(c, 2, 2, BG, "zero width/height draws nothing")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
