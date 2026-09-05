"""Tests for canvas/shapes/ellipses.mojo: exact pixel sets for
known inputs, verified against hand-traced runs of the same
algorithms.
"""

from std.testing import assert_equal, TestSuite, assert_true

from canvas.color import Color
from canvas.buffer import Canvas
from canvas.shapes.ellipses import (
    draw_ellipse,
    fill_ellipse,
    fill_ellipse_aa,
    draw_ellipse_aa,
)

comptime BG = Color(0, 0, 0)
comptime FG = Color(255, 255, 255)


def _assert_pixel(
    c: Canvas, x: Int, y: Int, expected: Color, label: String
) raises:
    var p = c.get_pixel(x, y)
    assert_equal(p.r, expected.r, label + " (r)")
    assert_equal(p.g, expected.g, label + " (g)")
    assert_equal(p.b, expected.b, label + " (b)")


def test_draw_ellipse_degenerate_radius_plots_center() raises:
    var c = Canvas(3, 3, BG)
    draw_ellipse(c, 1, 1, 0, 5, FG)
    _assert_pixel(c, 1, 1, FG, "rx=0 falls back to a single pixel")

    var c2 = Canvas(3, 3, BG)
    draw_ellipse(c2, 1, 1, 5, 0, FG)
    _assert_pixel(c2, 1, 1, FG, "ry=0 falls back to a single pixel")


def test_draw_ellipse_matches_hand_traced_points() raises:
    # Hand-derived midpoint-ellipse run for rx=3, ry=2 at (5,4) on an
    # 11x9 canvas: decision-parameter update formulas re-derived from
    # the ellipse equation rather than recalled, then both regions
    # traced step by step for these 12 points.
    var c = Canvas(11, 9, BG)
    draw_ellipse(c, 5, 4, 3, 2, FG)

    var xs: List[Int] = [4, 5, 6, 3, 7, 2, 8, 3, 7, 4, 5, 6]
    var ys: List[Int] = [2, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 6]
    for i in range(len(xs)):
        _assert_pixel(c, xs[i], ys[i], FG, "on the ellipse boundary")

    var count = 0
    for y in range(9):
        for x in range(11):
            var p = c.get_pixel(x, y)
            if p.r == FG.r and p.g == FG.g and p.b == FG.b:
                count += 1
    assert_equal(count, 12)

    _assert_pixel(c, 5, 4, BG, "center untouched -- outline only")


def test_draw_ellipse_does_not_double_blend_degenerate_points() raises:
    # The degenerate-symmetry property draw_circle's test covers:
    # region 1 starts at x==0 and region 2 ends at y==0, both reachable
    # here, where two of the 4 symmetric points collapse onto one
    # pixel. All 4 axis extremes must give the single-blend value 100,
    # not a double-blended 150.
    var c = Canvas(21, 15, Color(0, 0, 0))
    draw_ellipse(c, 10, 7, 9, 6, Color(200, 0, 0, 128))

    var top = c.get_pixel(10, 1)
    assert_equal(top.r, 100)
    var bottom = c.get_pixel(10, 13)
    assert_equal(bottom.r, 100)
    var left = c.get_pixel(1, 7)
    assert_equal(left.r, 100)
    var right = c.get_pixel(19, 7)
    assert_equal(right.r, 100)


def test_fill_ellipse_degenerate_radius_plots_center() raises:
    var c = Canvas(3, 3, BG)
    fill_ellipse(c, 1, 1, 0, 5, FG)
    _assert_pixel(c, 1, 1, FG, "rx=0 falls back to a single pixel")

    var c2 = Canvas(3, 3, BG)
    fill_ellipse(c2, 1, 1, 5, 0, FG)
    _assert_pixel(c2, 1, 1, FG, "ry=0 falls back to a single pixel")


def test_fill_ellipse_matches_hand_traced_spans() raises:
    # Row half-widths for rx=5, ry=3 from the integer inequality the
    # code uses (dx^2*ry^2 + dy^2*rx^2 <= rx^2*ry^2): dy=0 -> dx=5,
    # dy=1 -> dx=4, dy=2 -> dx=3, dy=3 -> dx=0.
    # Row widths (2*dx+1): 11, 9, 9, 7, 7, 1, 1 top to bottom ->
    # 11 + 2*9 + 2*7 + 2*1 = 45 pixels total.
    var c = Canvas(13, 9, BG)
    fill_ellipse(c, 6, 4, 5, 3, FG)

    _assert_pixel(c, 6, 4, FG, "center is filled")
    _assert_pixel(c, 1, 4, FG, "left point")
    _assert_pixel(c, 11, 4, FG, "right point")
    _assert_pixel(c, 6, 1, FG, "top point")
    _assert_pixel(c, 6, 7, FG, "bottom point")
    _assert_pixel(c, 6, 8, BG, "just past the bottom point")
    _assert_pixel(c, 0, 0, BG, "corner, well outside")

    var count = 0
    for y in range(9):
        for x in range(13):
            var p = c.get_pixel(x, y)
            if p.r == FG.r and p.g == FG.g and p.b == FG.b:
                count += 1
    assert_equal(count, 45)


def test_fill_ellipse_blends_translucent_color_correctly() raises:
    var c = Canvas(13, 9, Color(0, 0, 0))
    fill_ellipse(c, 6, 4, 5, 3, Color(200, 0, 0, 128))
    var center = c.get_pixel(6, 4)
    assert_equal(center.r, 100)
    assert_equal(center.g, 0)
    assert_equal(center.b, 0)


def test_fill_ellipse_aa_center_is_fully_opaque() raises:
    var c = Canvas(11, 7, BG)
    fill_ellipse_aa(c, 5, 3, 4, 2, FG)
    _assert_pixel(c, 5, 3, FG, "center, fully covered")


def test_fill_ellipse_aa_far_pixel_is_untouched() raises:
    var c = Canvas(11, 7, BG)
    fill_ellipse_aa(c, 5, 3, 4, 2, FG)
    _assert_pixel(c, 0, 0, BG, "outside the bounding box, never sampled")


def test_fill_ellipse_aa_partial_coverage_matches_hand_computed_values() raises:
    # Hand-summed 4x4 sub-sample grids for rx=4, ry=2 at cx=5, cy=3,
    # each pixel centered AT (px,py): pixel (5,1), above center at the
    # top of the minor axis, has 8/16 sub-samples inside the true
    # ellipse; (3,1) has 3/16; and (1,3), left of center at the end of
    # the major axis, also has 8/16 -- so both radii are honored, not
    # just one.
    var c = Canvas(11, 7, BG)
    fill_ellipse_aa(c, 5, 3, 4, 2, FG)

    var top_mid = c.get_pixel(5, 1)  # 8/16 covered -> alpha 128
    assert_equal(top_mid.r, 128)
    assert_equal(top_mid.g, 128)
    assert_equal(top_mid.b, 128)

    var top_corner = c.get_pixel(3, 1)  # 3/16 covered -> alpha 48
    assert_equal(top_corner.r, 48)
    assert_equal(top_corner.g, 48)
    assert_equal(top_corner.b, 48)

    var side_mid = c.get_pixel(1, 3)  # 8/16 covered -> alpha 128
    assert_equal(side_mid.r, 128)
    assert_equal(side_mid.g, 128)
    assert_equal(side_mid.b, 128)


def test_fill_ellipse_aa_agrees_with_hard_edged_on_interior_pixels() raises:
    # fill_circle_aa's property: deep-interior pixels must agree
    # exactly with the hard-edged fill_ellipse given identical
    # arguments, which holds only under the pixel-centered-at-(px,py)
    # convention. Not the extreme boundary points, whose centers sit on
    # the true boundary and correctly get partial coverage.
    var c = Canvas(11, 7, BG)
    fill_ellipse_aa(c, 5, 3, 4, 2, FG)
    _assert_pixel(c, 5, 3, FG, "center")
    _assert_pixel(c, 5, 2, FG, "interior, above center")
    _assert_pixel(c, 3, 3, FG, "interior, left of center")
    _assert_pixel(c, 7, 3, FG, "interior, right of center")


def test_canvas_method_matches_the_free_function() raises:
    # Canvas.fill_ellipse_aa is the DrawTarget method; fill_ellipse_aa
    # is the free function it delegates to. They must put down
    # byte-identical pixels, including antialiased edges -- a caller
    # rendering generically through the trait gets exactly what a
    # caller reaching for the free function does.
    var via_method = Canvas(31, 21, BG)
    via_method.fill_ellipse_aa(15, 10, 12, 7, FG)

    var via_function = Canvas(31, 21, BG)
    fill_ellipse_aa(via_function, 15, 10, 12, 7, FG)

    for y in range(21):
        for x in range(31):
            var a = via_method.get_pixel(x, y)
            var b = via_function.get_pixel(x, y)
            assert_equal(a.r, b.r)
            assert_equal(a.g, b.g)
            assert_equal(a.b, b.b)


def test_canvas_outline_method_matches_the_free_function() raises:
    # Same delegation check as the fill above, for the outline half.
    var via_method = Canvas(31, 21, BG)
    via_method.draw_ellipse_aa(15, 10, 12, 7, FG)

    var via_function = Canvas(31, 21, BG)
    draw_ellipse_aa(via_function, 15, 10, 12, 7, FG)

    for y in range(21):
        for x in range(31):
            var a = via_method.get_pixel(x, y)
            var b = via_function.get_pixel(x, y)
            assert_equal(a.r, b.r)
            assert_equal(a.g, b.g)
            assert_equal(a.b, b.b)


def test_canvas_sub_pixel_outline_method_matches_the_free_function() raises:
    # The Float64/width overload of Canvas.draw_ellipse_aa against the
    # free-function overload it delegates to.
    var via_method = Canvas(31, 21, BG)
    via_method.draw_ellipse_aa(15.0, 10.0, 12.0, 7.0, FG, width=3.0)

    var via_function = Canvas(31, 21, BG)
    draw_ellipse_aa(via_function, 15.0, 10.0, 12.0, 7.0, FG, width=3.0)

    for y in range(21):
        for x in range(31):
            var a = via_method.get_pixel(x, y)
            var b = via_function.get_pixel(x, y)
            assert_equal(a.r, b.r)
            assert_equal(a.g, b.g)
            assert_equal(a.b, b.b)


def test_fill_ellipse_aa_respects_translucent_input_color() raises:
    var c = Canvas(11, 7, Color(0, 0, 0))
    fill_ellipse_aa(c, 5, 3, 4, 2, Color(200, 0, 0, 128))
    var center = c.get_pixel(5, 3)  # fully covered
    assert_equal(center.r, 100)
    assert_equal(center.g, 0)
    assert_equal(center.b, 0)


def test_draw_ellipse_aa_center_stays_background() raises:
    var c = Canvas(13, 9, BG)
    draw_ellipse_aa(c, 6, 4, 5, 3, FG)
    _assert_pixel(c, 6, 4, BG, "ring outline, not filled")


def test_draw_ellipse_aa_partial_coverage_matches_hand_computed_value() raises:
    # Hand-summed for rx=5, ry=3 at cx=6, cy=4, each sample tested
    # against the outer (rx+0.5, ry+0.5) and inner (rx-0.5, ry-0.5)
    # ellipses in their own normalized space -- see draw_ellipse_aa for
    # why one shared distance doesn't work here. Pixel (3,1) has 7/16
    # sub-samples inside the ring; (6,1) above center and (11,4) at the
    # major-axis extreme are both fully inside at 16/16, covering each
    # axis.
    var c = Canvas(13, 9, BG)
    draw_ellipse_aa(c, 6, 4, 5, 3, FG)

    var p = c.get_pixel(3, 1)  # 7/16 covered -> alpha 112
    assert_equal(p.r, 112)
    assert_equal(p.g, 112)
    assert_equal(p.b, 112)

    _assert_pixel(c, 6, 1, FG, "fully inside the ring, top of minor axis")
    _assert_pixel(c, 11, 4, FG, "fully inside the ring, end of major axis")
    _assert_pixel(c, 0, 0, BG, "corner, well outside the ring")


def test_draw_ellipse_aa_respects_translucent_input_color() raises:
    var c = Canvas(13, 9, Color(0, 0, 0))
    draw_ellipse_aa(c, 6, 4, 5, 3, Color(200, 0, 0, 128))
    var p = c.get_pixel(6, 1)  # fully inside the ring
    assert_equal(p.r, 100)
    assert_equal(p.g, 0)
    assert_equal(p.b, 0)


def test_draw_ellipse_aa_width_widens_the_ring() raises:
    var thin = Canvas(60, 60, Color(0, 0, 0))
    draw_ellipse_aa(thin, 30, 30, 20, 12, Color(255, 255, 255))
    var thick = Canvas(60, 60, Color(0, 0, 0))
    draw_ellipse_aa(thick, 30, 30, 20, 12, Color(255, 255, 255), width=4.0)
    var thin_ink = 0
    var thick_ink = 0
    for y in range(60):
        for x in range(60):
            thin_ink += Int(thin.get_pixel(x, y).r)
            thick_ink += Int(thick.get_pixel(x, y).r)
    assert_true(thick_ink > thin_ink, "a wider ring is more ink")
    # The axis extremes sit on the stroke's centre line.
    assert_equal(thick.get_pixel(50, 30).r, 255)
    assert_equal(thick.get_pixel(30, 42).r, 255)
    assert_equal(thick.get_pixel(30, 30).r, 0, "the hole is untouched")


def test_draw_ellipse_aa_wider_than_the_short_axis_fills_the_hole() raises:
    # width 30 on ry=12 leaves no inner ellipse: the centre is inked.
    var c = Canvas(60, 60, Color(0, 0, 0))
    draw_ellipse_aa(c, 30, 30, 20, 12, Color(255, 255, 255), width=30.0)
    assert_equal(c.get_pixel(30, 30).r, 255)


def test_draw_ellipse_aa_sub_pixel_center_moves_the_ring() raises:
    var a = Canvas(60, 60, Color(0, 0, 0))
    draw_ellipse_aa(a, 30.0, 30.0, 20.0, 12.0, Color(255, 255, 255))
    var b = Canvas(60, 60, Color(0, 0, 0))
    draw_ellipse_aa(b, 30.0, 30.5, 20.0, 12.0, Color(255, 255, 255))
    var differing = 0
    for y in range(60):
        for x in range(60):
            if a.get_pixel(x, y).r != b.get_pixel(x, y).r:
                differing += 1
    assert_true(differing > 20, "half a pixel of centre shifts the ring")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
