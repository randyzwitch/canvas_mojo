"""Tests for push_clip_path: clipping to an arbitrary shape.

Two properties carry most of the weight. The clip must be
*anti-aliased* -- a pixel the clip path half covers lets half the
drawing through, which is what distinguishes this from a hard in/out
stencil. And nesting must only ever restrict, never widen, which is the
rule the rectangle clip already follows.
"""

from std.testing import assert_equal, assert_true, TestSuite

from canvas.buffer import Canvas
from canvas.color import Color
from canvas.fill_rule import FillRule
from canvas.path import Path
from canvas.gradient import LinearGradient, RadialGradient
from canvas.shapes.rects import (
    fill_rect,
    fill_rect_gradient,
    fill_rect_radial_gradient,
)

comptime BG = Color(0, 0, 0)
comptime FG = Color(255, 255, 255)


def _square(
    mut p: Path, x0: Float64, y0: Float64, x1: Float64, y1: Float64
) raises:
    p.move_to(x0, y0)
    p.line_to(x1, y0)
    p.line_to(x1, y1)
    p.line_to(x0, y1)
    p.close()


def _ink(c: Canvas) -> Int:
    var total = 0
    for y in range(c.height):
        for x in range(c.width):
            total += Int(c.get_pixel(x, y).r)
    return total


def test_no_clip_path_lets_everything_through() raises:
    var c = Canvas(20, 20, BG)
    assert_equal(c.clip_coverage(5, 5), 255, "no mask means full coverage")
    fill_rect(c, 0, 0, 20, 20, FG)
    assert_equal(c.get_pixel(10, 10).r, 255)


def test_fill_is_confined_to_the_clip_path() raises:
    var c = Canvas(40, 40, BG)
    var p = Path()
    _square(p, 10.0, 10.0, 30.0, 30.0)
    c.push_clip_path(p)
    fill_rect(c, 0, 0, 40, 40, FG)
    c.pop_clip_path()

    assert_equal(c.get_pixel(20, 20).r, 255, "inside the clip path")
    assert_equal(c.get_pixel(2, 2).r, 0, "outside it stays background")
    assert_equal(c.get_pixel(35, 20).r, 0, "past its right edge")


def test_pop_restores_unclipped_drawing() raises:
    var c = Canvas(30, 30, BG)
    var p = Path()
    _square(p, 5.0, 5.0, 10.0, 10.0)
    c.push_clip_path(p)
    c.pop_clip_path()
    fill_rect(c, 0, 0, 30, 30, FG)
    assert_equal(c.get_pixel(25, 25).r, 255, "clip no longer applies")


def test_pop_on_empty_stack_is_a_noop() raises:
    var c = Canvas(8, 8, BG)
    c.pop_clip_path()
    fill_rect(c, 0, 0, 8, 8, FG)
    assert_equal(c.get_pixel(4, 4).r, 255)


def test_clip_edge_is_antialiased_not_a_hard_stencil() raises:
    # The clip path's left edge sits at x = 10.25, which is a quarter
    # of the way into the pixel centred at x=10 (that pixel spans
    # [9.5, 10.5]). At the default 4x supersample its columns sit at
    # 9.625, 9.875, 10.125 and 10.375, of which one is inside -- so the
    # pixel lets a quarter through, and an opaque white fill lands at
    # round(0.25 * 255) = 64.
    #
    # A hard in/out clip could only ever produce 0 or 255 here. That is
    # the whole distinction this test exists for.
    var c = Canvas(40, 40, BG)
    var p = Path()
    _square(p, 10.25, 5.0, 30.0, 35.0)
    c.push_clip_path(p)
    fill_rect(c, 0, 0, 40, 40, FG)
    c.pop_clip_path()

    assert_equal(
        Int(c.get_pixel(10, 20).r), 64, "hand-derived partial clip coverage"
    )
    assert_equal(Int(c.get_pixel(11, 20).r), 255, "fully inside")
    assert_equal(Int(c.get_pixel(9, 20).r), 0, "fully outside")


def test_clip_coverage_reports_the_mask() raises:
    var c = Canvas(40, 40, BG)
    var p = Path()
    _square(p, 10.25, 5.0, 30.0, 35.0)
    c.push_clip_path(p)
    assert_equal(c.clip_coverage(10, 20), 64, "partial coverage on the edge")
    assert_equal(c.clip_coverage(20, 20), 255, "fully inside")
    assert_equal(c.clip_coverage(2, 20), 0, "fully outside")
    c.pop_clip_path()


def test_nested_clip_paths_only_ever_restrict() raises:
    var c = Canvas(60, 60, BG)
    var outer = Path()
    _square(outer, 10.0, 10.0, 40.0, 40.0)
    var inner = Path()
    # Deliberately extends past the outer clip on the right: a nested
    # clip must not be able to widen its parent.
    _square(inner, 20.0, 20.0, 55.0, 30.0)

    c.push_clip_path(outer)
    c.push_clip_path(inner)
    fill_rect(c, 0, 0, 60, 60, FG)
    c.pop_clip_path()
    c.pop_clip_path()

    assert_equal(c.get_pixel(25, 25).r, 255, "inside both")
    assert_equal(c.get_pixel(15, 15).r, 0, "outside the inner one")
    assert_equal(
        c.get_pixel(50, 25).r, 0, "the inner clip cannot escape the outer"
    )


def test_popping_an_inner_clip_restores_the_outer() raises:
    var c = Canvas(60, 60, BG)
    var outer = Path()
    _square(outer, 10.0, 10.0, 40.0, 40.0)
    var inner = Path()
    _square(inner, 20.0, 20.0, 30.0, 30.0)

    c.push_clip_path(outer)
    c.push_clip_path(inner)
    c.pop_clip_path()
    fill_rect(c, 0, 0, 60, 60, FG)
    c.pop_clip_path()

    assert_equal(c.get_pixel(15, 15).r, 255, "the outer clip is back")
    assert_equal(c.get_pixel(50, 50).r, 0, "but still restricts")


def test_clip_path_composes_with_a_rectangle_clip() raises:
    # The two clip mechanisms are independent and both apply.
    var c = Canvas(60, 60, BG)
    var p = Path()
    _square(p, 10.0, 10.0, 50.0, 50.0)
    c.push_clip_path(p)
    c.push_clip(30, 0, 60, 60)  # right half only
    fill_rect(c, 0, 0, 60, 60, FG)
    c.pop_clip()
    c.pop_clip_path()

    assert_equal(c.get_pixel(40, 30).r, 255, "inside both clips")
    assert_equal(c.get_pixel(20, 30).r, 0, "excluded by the rectangle clip")
    assert_equal(c.get_pixel(40, 55).r, 0, "excluded by the clip path")


def test_clip_path_honours_the_fill_rule() raises:
    # Two overlapping same-direction squares. Under EVEN_ODD the
    # overlap is a hole in the clip; under NONZERO it is solid -- the
    # same divergence fill_path shows, since the mask is built by the
    # same sweep.
    var even_odd = Canvas(60, 60, BG)
    var nonzero = Canvas(60, 60, BG)
    for i in range(2):
        var p = Path()
        _square(p, 5.0, 5.0, 35.0, 35.0)
        _square(p, 20.0, 20.0, 50.0, 50.0)
        if i == 0:
            even_odd.push_clip_path(p, FillRule.EVEN_ODD)
            fill_rect(even_odd, 0, 0, 60, 60, FG)
            even_odd.pop_clip_path()
        else:
            nonzero.push_clip_path(p, FillRule.NONZERO)
            fill_rect(nonzero, 0, 0, 60, 60, FG)
            nonzero.pop_clip_path()

    assert_equal(
        even_odd.get_pixel(27, 27).r, 0, "even-odd leaves a hole in the overlap"
    )
    assert_equal(
        nonzero.get_pixel(27, 27).r, 255, "nonzero fills the overlap solid"
    )
    assert_true(
        _ink(nonzero) > _ink(even_odd), "and so passes strictly more through"
    )


def test_clip_path_applies_to_translucent_drawing() raises:
    # Clip coverage multiplies the drawn colour's own alpha rather than
    # replacing it: half coverage of a half-alpha fill is a quarter.
    var c = Canvas(40, 40, BG)
    var p = Path()
    _square(p, 10.5, 5.0, 30.0, 35.0)
    c.push_clip_path(p)
    fill_rect(c, 0, 0, 40, 40, Color(255, 255, 255, 128))
    c.pop_clip_path()

    # Pixel 10 spans [9.5, 10.5], so the clip's edge at 10.5 leaves it
    # entirely outside; pixel 11 is fully inside and gets the plain
    # half-alpha value.
    assert_equal(Int(c.get_pixel(10, 20).r), 0, "outside the clip")
    assert_equal(
        Int(c.get_pixel(11, 20).r), 128, "inside: the fill's own alpha"
    )


def test_gradient_fills_respect_the_clip_path() raises:
    # Regression: `fill_rect_gradient` and `fill_rect_radial_gradient`
    # write through `write_pixel`, which deliberately skips every
    # per-pixel check -- so they ignored the clip mask entirely and
    # painted the whole rectangle. Caught by looking at the rendered
    # example, not by any test that existed at the time.
    var linear = Canvas(60, 60, BG)
    var p = Path()
    _square(p, 10.0, 10.0, 30.0, 30.0)
    var lg = LinearGradient(0.0, 0.0, 60.0, 60.0)
    lg.add_stop(0.0, FG)
    lg.add_stop(1.0, FG)

    linear.push_clip_path(p)
    fill_rect_gradient(linear, 0, 0, 60, 60, lg)
    linear.pop_clip_path()
    assert_true(
        Int(linear.get_pixel(20, 20).r) > 0, "inside the clip is painted"
    )
    assert_equal(Int(linear.get_pixel(45, 45).r), 0, "outside the clip is not")

    var radial = Canvas(60, 60, BG)
    var p2 = Path()
    _square(p2, 10.0, 10.0, 30.0, 30.0)
    var rg = RadialGradient(30.0, 30.0, 40.0)
    rg.add_stop(0.0, FG)
    rg.add_stop(1.0, FG)

    radial.push_clip_path(p2)
    fill_rect_radial_gradient(radial, 0, 0, 60, 60, rg)
    radial.pop_clip_path()
    assert_true(
        Int(radial.get_pixel(20, 20).r) > 0, "inside the clip is painted"
    )
    assert_equal(Int(radial.get_pixel(45, 45).r), 0, "outside the clip is not")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
