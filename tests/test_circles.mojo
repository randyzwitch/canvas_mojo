"""Tests for canvas_mojo/shapes/circles.mojo: exact pixel sets for
known inputs, verified against hand-traced runs of the same
algorithms. Split out of the original monolithic test_primitives.mojo
along with canvas_mojo/primitives.mojo's own split into
canvas_mojo/shapes/ -- see that subpackage's own module docstrings for
why.
"""

from std.testing import assert_equal, TestSuite

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas
from canvas_mojo.shapes.circles import draw_circle, fill_circle, fill_circle_aa, draw_circle_aa

comptime BG = Color(0, 0, 0)
comptime FG = Color(255, 255, 255)


def _assert_pixel(c: Canvas, x: Int, y: Int, expected: Color, label: String) raises:
    var p = c.get_pixel(x, y)
    assert_equal(p.r, expected.r, label + " (r)")
    assert_equal(p.g, expected.g, label + " (g)")
    assert_equal(p.b, expected.b, label + " (b)")


def test_draw_circle_radius_zero_plots_center() raises:
    var c = Canvas(3, 3, BG)
    draw_circle(c, 1, 1, 0, FG)
    _assert_pixel(c, 1, 1, FG, "single center pixel")


def test_draw_circle_radius_three_matches_traced_points() raises:
    # Hand-traced midpoint-circle run for radius=3, centered at (5,5)
    # on an 11x11 canvas -- see the derivation in the PR/commit notes.
    var c = Canvas(11, 11, BG)
    draw_circle(c, 5, 5, 3, FG)

    var xs: List[Int] = [8, 2, 5, 5, 8, 6, 4, 2, 2, 4, 6, 8, 7, 3, 3, 7]
    var ys: List[Int] = [5, 5, 8, 2, 6, 8, 8, 6, 4, 2, 2, 4, 7, 7, 3, 3]
    for i in range(len(xs)):
        _assert_pixel(c, xs[i], ys[i], FG, "on the circle boundary")

    # exactly 16 pixels should be colored -- no extras, none missing
    var count = 0
    for y in range(11):
        for x in range(11):
            var p = c.get_pixel(x, y)
            if p.r == FG.r and p.g == FG.g and p.b == FG.b:
                count += 1
    assert_equal(count, 16)

    # outline only -- the center stays background
    _assert_pixel(c, 5, 5, BG, "center untouched")


def test_draw_circle_does_not_double_blend_degenerate_symmetry_points() raises:
    # Regression test for a real bug caught while designing
    # draw_ellipse: at y==0 (loop start) and x==y (wherever the loop
    # crosses the diagonal), several of the 8 symmetric expressions
    # collapse onto the same pixel. Plotting all 8 unconditionally
    # blends a translucent color multiple times at exactly those 8
    # points (4 axis, 4 diagonal) on a radius=4 circle. Confirmed via
    # probe: the bug produced 150 (blending 200,0,0,alpha=128 TWICE
    # over black) instead of the correct single-blend value 100.
    var c = Canvas(11, 11, Color(0, 0, 0))
    draw_circle(c, 5, 5, 4, Color(200, 0, 0, 128))

    # the 4 axis points (y==0 in the loop)
    var axis_xs: List[Int] = [9, 1, 5, 5]
    var axis_ys: List[Int] = [5, 5, 9, 1]
    for i in range(len(axis_xs)):
        var p = c.get_pixel(axis_xs[i], axis_ys[i])
        assert_equal(p.r, 100)

    # the 4 diagonal points (x==y in the loop, at offset 3,3)
    var diag_xs: List[Int] = [8, 2, 8, 2]
    var diag_ys: List[Int] = [8, 8, 2, 2]
    for i in range(len(diag_xs)):
        var p = c.get_pixel(diag_xs[i], diag_ys[i])
        assert_equal(p.r, 100)


def test_fill_circle_radius_zero_plots_center() raises:
    var c = Canvas(3, 3, BG)
    fill_circle(c, 1, 1, 0, FG)
    _assert_pixel(c, 1, 1, FG, "single center pixel")


def test_fill_circle_radius_three_matches_hand_traced_disk() raises:
    # Hand-traced span-fill run for radius=3, centered at (4,4) on a
    # 9x9 canvas -- row widths 1,5,5,7,5,5,1 top to bottom (see the
    # derivation in conversation notes).
    var c = Canvas(9, 9, BG)
    fill_circle(c, 4, 4, 3, FG)

    # unlike the stroke version, the disk is solid: center is filled
    _assert_pixel(c, 4, 4, FG, "center is filled")
    _assert_pixel(c, 4, 1, FG, "top point")
    _assert_pixel(c, 4, 7, FG, "bottom point")
    _assert_pixel(c, 1, 4, FG, "left point")
    _assert_pixel(c, 7, 4, FG, "right point")

    _assert_pixel(c, 4, 0, BG, "just past the top point")
    _assert_pixel(c, 0, 0, BG, "corner, well outside")
    _assert_pixel(c, 8, 8, BG, "corner, well outside")

    # 1+5+5+7+5+5+1 = 29 pixels total
    var count = 0
    for y in range(9):
        for x in range(9):
            var p = c.get_pixel(x, y)
            if p.r == FG.r and p.g == FG.g and p.b == FG.b:
                count += 1
    assert_equal(count, 29)


def test_fill_circle_blends_translucent_color_correctly() raises:
    var c = Canvas(7, 7, Color(0, 0, 0))
    fill_circle(c, 3, 3, 2, Color(200, 0, 0, 128))
    # single-blend arithmetic (same formula used throughout this suite)
    var center = c.get_pixel(3, 3)
    assert_equal(center.r, 100)
    assert_equal(center.g, 0)
    assert_equal(center.b, 0)


def test_fill_circle_aa_center_is_fully_opaque() raises:
    var c = Canvas(7, 7, BG)
    fill_circle_aa(c, 3, 3, 2, FG)
    # the 2x2 block at the center is fully inside the disk (16/16
    # sub-samples covered), so it's written directly, no blending
    _assert_pixel(c, 2, 2, FG, "fully covered")
    _assert_pixel(c, 3, 2, FG, "fully covered")
    _assert_pixel(c, 2, 3, FG, "fully covered")
    _assert_pixel(c, 3, 3, FG, "fully covered")


def test_fill_circle_aa_far_pixel_is_untouched() raises:
    var c = Canvas(7, 7, BG)
    fill_circle_aa(c, 3, 3, 2, FG)
    _assert_pixel(c, 0, 0, BG, "outside the bounding box, never sampled")


def test_fill_circle_aa_partial_coverage_matches_hand_computed_values() raises:
    # Hand-verified by independently summing the 4x4 sub-sample grid
    # for radius=2 at cx=cy=3 (pixel (px,py) sampled as centered AT
    # (px,py), matching the hard-edged convention): pixel (3,1) has
    # 8/16 sub-samples inside the true circle, pixel (2,1) has 4/16.
    # White-on-black makes the resulting gray value equal the
    # coverage fraction exactly: round(n/16 * 255).
    var c = Canvas(7, 7, BG)
    fill_circle_aa(c, 3, 3, 2, FG)

    var edge_mid = c.get_pixel(3, 1)  # 8/16 covered -> alpha 128
    assert_equal(edge_mid.r, 128)
    assert_equal(edge_mid.g, 128)
    assert_equal(edge_mid.b, 128)

    var corner = c.get_pixel(2, 1)  # 4/16 covered -> alpha 64
    assert_equal(corner.r, 64)
    assert_equal(corner.g, 64)
    assert_equal(corner.b, 64)


def test_fill_circle_aa_agrees_with_hard_edged_on_interior_pixels() raises:
    # Regression test for a real bug caught during development: the
    # AA sampling originally treated pixel (px,py) as a unit square
    # with (px,py) at its TOP-LEFT CORNER, not centered AT (px,py) --
    # so fill_circle_aa(c, cx, cy, r, ...) drew a circle shifted half
    # a pixel from fill_circle(c, cx, cy, r, ...) given the exact same
    # arguments.
    #
    # This checks only pixels deep in the interior, not the hard
    # disk's extreme boundary points (like (3,1), the exact top of
    # the circle) -- those legitimately get partial AA coverage, since
    # their pixel *center* sits exactly on the true boundary while
    # half their *area* falls outside it. That's correct
    # antialiasing, not a bug; asserting full opacity there would be
    # asserting something false about area coverage.
    var c = Canvas(7, 7, BG)
    fill_circle_aa(c, 3, 3, 2, FG)
    _assert_pixel(c, 3, 3, FG, "center")
    _assert_pixel(c, 2, 2, FG, "interior")
    _assert_pixel(c, 4, 2, FG, "interior")
    _assert_pixel(c, 2, 4, FG, "interior")
    _assert_pixel(c, 4, 4, FG, "interior")


def test_fill_circle_aa_respects_translucent_input_color() raises:
    # Regression test for a real bug caught during development: the
    # coverage-to-alpha formula used a hardcoded 255 instead of the
    # caller's color.a, so a fully-covered pixel with e.g. alpha=128
    # rendered fully OPAQUE (raw color.r, no blending) instead of the
    # requested translucency. Invisible in every prior test because
    # they all used opaque colors, where coverage*255 == coverage*a.
    var c = Canvas(7, 7, Color(0, 0, 0))
    fill_circle_aa(c, 3, 3, 2, Color(200, 0, 0, 128))
    var center = c.get_pixel(3, 3)  # fully covered
    assert_equal(center.r, 100)
    assert_equal(center.g, 0)
    assert_equal(center.b, 0)


def test_draw_circle_aa_center_stays_background() raises:
    var c = Canvas(9, 9, BG)
    draw_circle_aa(c, 4, 4, 3, FG)
    _assert_pixel(c, 4, 4, BG, "ring outline, not filled")


def test_draw_circle_aa_partial_coverage_matches_hand_computed_value() raises:
    # Hand-verified (pixel centered AT (px,py), matching the
    # hard-edged convention): for radius=3 at cx=cy=4, pixel (2,1)
    # has 5/16 sub-samples inside the ring [2.5, 3.5), and pixel
    # (4,1) is fully inside (16/16).
    var c = Canvas(9, 9, BG)
    draw_circle_aa(c, 4, 4, 3, FG)

    var p = c.get_pixel(2, 1)  # 5/16 covered -> alpha 80
    assert_equal(p.r, 80)
    assert_equal(p.g, 80)
    assert_equal(p.b, 80)

    _assert_pixel(c, 4, 1, FG, "fully inside the ring")
    _assert_pixel(c, 0, 0, BG, "corner, well outside the ring")


def test_draw_circle_aa_respects_translucent_input_color() raises:
    # Same regression category as fill_circle_aa's: a fully-covered
    # ring pixel with a translucent input color must show the
    # single-blend value, not the raw (unblended) color.
    var c = Canvas(9, 9, Color(0, 0, 0))
    draw_circle_aa(c, 4, 4, 3, Color(200, 0, 0, 128))
    var p = c.get_pixel(4, 1)  # fully inside the ring
    assert_equal(p.r, 100)
    assert_equal(p.g, 0)
    assert_equal(p.b, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
