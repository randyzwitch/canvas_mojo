"""Tests for draw_canvas: compositing one canvas onto another.

The interesting cases are the ones that only exist because the canvas
carries alpha -- a transparent source leaving the destination alone, a
translucent one blending rather than replacing, and layer opacity
compounding with a source pixel's own alpha.
"""

from std.testing import assert_equal, assert_true, TestSuite

from canvas.buffer import Canvas
from canvas.color import Color
from canvas.compose import draw_canvas
from canvas.shapes.rects import fill_rect

comptime CLEAR = Color(0, 0, 0, 0)
comptime WHITE = Color(255, 255, 255)
comptime RED = Color(255, 0, 0)
comptime BLUE = Color(0, 0, 255)


def _assert_rgb(c: Canvas, x: Int, y: Int, e: Color, label: String) raises:
    var p = c.get_pixel(x, y)
    assert_equal(p.r, e.r, label + " (r)")
    assert_equal(p.g, e.g, label + " (g)")
    assert_equal(p.b, e.b, label + " (b)")


def test_opaque_source_replaces_destination() raises:
    var dst = Canvas(10, 10, WHITE)
    var src = Canvas(4, 4, RED)
    draw_canvas(dst, src, 3, 3)
    _assert_rgb(dst, 4, 4, RED, "inside the pasted region")
    _assert_rgb(dst, 0, 0, WHITE, "outside it")
    _assert_rgb(dst, 7, 7, WHITE, "just past the bottom-right corner")


def test_transparent_source_leaves_destination_untouched() raises:
    var dst = Canvas(8, 8, RED)
    var src = Canvas(8, 8, CLEAR)
    draw_canvas(dst, src, 0, 0)
    for y in range(8):
        for x in range(8):
            _assert_rgb(dst, x, y, RED, "fully transparent source is a no-op")
            assert_equal(dst.get_pixel(x, y).a, 255, "alpha untouched too")


def test_translucent_source_blends() raises:
    # Half-alpha red over opaque white: the same value fill_rect would
    # produce drawing that colour directly, which is the point -- a
    # composited layer must match a directly drawn one.
    var dst = Canvas(4, 4, WHITE)
    var src = Canvas(4, 4, Color(255, 0, 0, 128))
    draw_canvas(dst, src, 0, 0)

    var reference = Canvas(4, 4, WHITE)
    fill_rect(reference, 0, 0, 4, 4, Color(255, 0, 0, 128))

    for y in range(4):
        for x in range(4):
            var a = dst.get_pixel(x, y)
            var b = reference.get_pixel(x, y)
            assert_equal(a.r, b.r, "composite matches a direct draw")
            assert_equal(a.g, b.g)
            assert_equal(a.b, b.b)
            assert_equal(a.a, b.a)


def test_partial_overlap_is_clipped_not_wrapped() raises:
    # A source hanging off the top-left: only its visible part lands,
    # and nothing wraps around to the far edge.
    var dst = Canvas(8, 8, WHITE)
    var src = Canvas(4, 4, RED)
    draw_canvas(dst, src, -2, -2)
    _assert_rgb(dst, 0, 0, RED, "the visible corner is drawn")
    _assert_rgb(dst, 1, 1, RED, "...and the rest of the overlap")
    _assert_rgb(dst, 2, 2, WHITE, "past the source's extent")
    _assert_rgb(dst, 7, 7, WHITE, "nothing wrapped to the far corner")


def test_fully_offscreen_source_is_a_noop() raises:
    var dst = Canvas(8, 8, WHITE)
    var src = Canvas(4, 4, RED)
    draw_canvas(dst, src, 100, 100)
    draw_canvas(dst, src, -50, 0)
    for y in range(8):
        for x in range(8):
            _assert_rgb(dst, x, y, WHITE, "offscreen paste changes nothing")


def test_respects_the_active_clip() raises:
    var dst = Canvas(10, 10, WHITE)
    var src = Canvas(10, 10, RED)
    dst.push_clip(2, 2, 3, 3)
    draw_canvas(dst, src, 0, 0)
    dst.pop_clip()
    _assert_rgb(dst, 3, 3, RED, "inside the clip")
    _assert_rgb(dst, 1, 1, WHITE, "outside the clip is untouched")
    _assert_rgb(dst, 6, 6, WHITE, "past the clip's far edge too")


def test_opacity_scales_the_whole_layer() raises:
    # An opaque red layer at half opacity must equal drawing red at
    # alpha 128 directly.
    var dst = Canvas(4, 4, WHITE)
    var src = Canvas(4, 4, RED)
    draw_canvas(dst, src, 0, 0, 128)

    var reference = Canvas(4, 4, WHITE)
    fill_rect(reference, 0, 0, 4, 4, Color(255, 0, 0, 128))
    _assert_rgb(dst, 2, 2, reference.get_pixel(2, 2), "half-opacity layer")


def test_opacity_compounds_with_source_alpha() raises:
    # A source already at alpha 128, drawn at opacity 128, ends up at
    # floor(128 * 128 / 255) = 64.
    var dst = Canvas(4, 4, CLEAR)
    var src = Canvas(4, 4, Color(10, 20, 30, 128))
    draw_canvas(dst, src, 0, 0, 128)
    assert_equal(dst.get_pixel(2, 2).a, 64, "alphas compound")


def test_zero_opacity_is_a_noop() raises:
    var dst = Canvas(4, 4, WHITE)
    var src = Canvas(4, 4, RED)
    draw_canvas(dst, src, 0, 0, 0)
    _assert_rgb(dst, 2, 2, WHITE, "opacity 0 draws nothing")


def test_layers_compose_in_order() raises:
    # Two transparent layers, each holding one opaque square, composed
    # onto a white sheet: the later layer wins where they overlap. This
    # is the workflow the module exists for.
    var grid = Canvas(12, 12, CLEAR)
    fill_rect(grid, 0, 0, 8, 8, BLUE)
    var series = Canvas(12, 12, CLEAR)
    fill_rect(series, 4, 4, 8, 8, RED)

    var sheet = Canvas(12, 12, WHITE)
    draw_canvas(sheet, grid, 0, 0)
    draw_canvas(sheet, series, 0, 0)

    _assert_rgb(sheet, 1, 1, BLUE, "lower layer only")
    _assert_rgb(sheet, 10, 10, RED, "upper layer only")
    _assert_rgb(sheet, 5, 5, RED, "upper layer wins the overlap")
    _assert_rgb(sheet, 11, 0, WHITE, "neither layer covers this")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
