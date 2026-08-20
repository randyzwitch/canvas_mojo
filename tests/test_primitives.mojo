"""Tests for the shape-drawing primitives: exact pixel sets for known
inputs, verified against hand-traced runs of the same algorithms.
"""

from std.testing import assert_equal, assert_true, TestSuite

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas
from canvas_mojo.geometry import Point
from canvas_mojo.gradient import LinearGradient, RadialGradient
from canvas_mojo.primitives import (
    draw_line,
    draw_line_aa,
    draw_polyline,
    draw_polygon,
    draw_polyline_aa,
    draw_polygon_aa,
    fill_polygon,
    fill_polygon_aa,
    _point_in_polygon,
    draw_rect,
    fill_rect,
    fill_rect_gradient,
    fill_rect_radial_gradient,
    draw_circle,
    fill_circle,
    fill_circle_aa,
    draw_circle_aa,
    draw_ellipse,
    fill_ellipse,
    fill_ellipse_aa,
    draw_ellipse_aa,
    draw_arc,
    draw_arc_aa,
    fill_arc,
    fill_arc_aa,
    fill_ring_sector,
    fill_ring_sector_aa,
    _is_dash_on,
    _arc_points,
    _angle_in_span,
    _Crossing,
    _spans_from_crossings,
)
from canvas_mojo.fill_rule import FillRule

from std.math import pi

comptime BG = Color(0, 0, 0)
comptime FG = Color(255, 255, 255)


def _assert_pixel(c: Canvas, x: Int, y: Int, expected: Color, label: String) raises:
    var p = c.get_pixel(x, y)
    assert_equal(p.r, expected.r, label + " (r)")
    assert_equal(p.g, expected.g, label + " (g)")
    assert_equal(p.b, expected.b, label + " (b)")


def test_draw_line_horizontal() raises:
    var c = Canvas(5, 3, BG)
    draw_line(c, 0, 1, 4, 1, FG)
    for x in range(5):
        _assert_pixel(c, x, 1, FG, "row y=1")
    for x in range(5):
        _assert_pixel(c, x, 0, BG, "row y=0 untouched")
        _assert_pixel(c, x, 2, BG, "row y=2 untouched")


def test_draw_line_vertical() raises:
    var c = Canvas(3, 5, BG)
    draw_line(c, 1, 0, 1, 4, FG)
    for y in range(5):
        _assert_pixel(c, 1, y, FG, "col x=1")
    for y in range(5):
        _assert_pixel(c, 0, y, BG, "col x=0 untouched")
        _assert_pixel(c, 2, y, BG, "col x=2 untouched")


def test_draw_line_45_degree_diagonal() raises:
    var c = Canvas(5, 5, BG)
    draw_line(c, 0, 0, 4, 4, FG)
    for i in range(5):
        _assert_pixel(c, i, i, FG, "diagonal")
    # a representative off-diagonal point stays background
    _assert_pixel(c, 0, 4, BG, "off-diagonal untouched")


def test_draw_line_general_slope() raises:
    # (0,0) -> (4,2): hand-traced Bresenham stepping gives exactly
    # this staircase, not the naive nearest-integer-y guess.
    var c = Canvas(5, 3, BG)
    draw_line(c, 0, 0, 4, 2, FG)
    _assert_pixel(c, 0, 0, FG, "step 1")
    _assert_pixel(c, 1, 1, FG, "step 2")
    _assert_pixel(c, 2, 1, FG, "step 3")
    _assert_pixel(c, 3, 2, FG, "step 4")
    _assert_pixel(c, 4, 2, FG, "step 5")
    # points that were never on the traced path
    _assert_pixel(c, 1, 0, BG, "not on the line")
    _assert_pixel(c, 4, 0, BG, "not on the line")
    _assert_pixel(c, 0, 2, BG, "not on the line")


def test_draw_line_aa_horizontal_interior_is_fully_opaque() raises:
    var c = Canvas(9, 3, BG)
    draw_line_aa(c, 1, 1, 7, 1, FG)
    for x in range(2, 7):
        _assert_pixel(c, x, 1, FG, "deep interior, fully opaque")
    for x in range(9):
        _assert_pixel(c, x, 0, BG, "row above stays background")
        _assert_pixel(c, x, 2, BG, "row below stays background")


def test_draw_line_aa_round_cap_matches_hand_computed_value() raises:
    # Hand-verified via the clamped-projection distance formula: for
    # the horizontal line (1,1)-(7,1), pixel (1,1) -- the exact start
    # point -- has 14/16 sub-samples within the round cap.
    var c = Canvas(9, 3, BG)
    draw_line_aa(c, 1, 1, 7, 1, FG)
    var cap = c.get_pixel(1, 1)
    assert_equal(cap.r, 223)
    assert_equal(cap.g, 223)
    assert_equal(cap.b, 223)
    # the round cap doesn't bulge far enough to reach the next column
    _assert_pixel(c, 0, 1, BG, "just past the cap")


def test_draw_line_aa_diagonal_matches_hand_computed_value() raises:
    # Hand-verified the same way for a non-axis-aligned segment:
    # (1,1)-(8,6), pixel (1,1) has 13/16 sub-samples covered.
    var c = Canvas(10, 10, BG)
    draw_line_aa(c, 1, 1, 8, 6, FG)
    var p = c.get_pixel(1, 1)
    assert_equal(p.r, 207)
    assert_equal(p.g, 207)
    assert_equal(p.b, 207)


def test_draw_line_aa_agrees_with_hard_edged_on_interior_pixels() raises:
    # Same category of check as fill_circle_aa's consistency test:
    # deep-interior pixels (not the exact endpoints, which legitimately
    # differ -- Bresenham's idealized single-pixel endpoint vs. the AA
    # version's round cap) must land at the same coordinates in both.
    var hard = Canvas(9, 3, BG)
    draw_line(hard, 1, 1, 7, 1, FG)
    var aa = Canvas(9, 3, BG)
    draw_line_aa(aa, 1, 1, 7, 1, FG)
    for x in range(2, 7):
        var hard_pixel = hard.get_pixel(x, 1)
        if hard_pixel.r == FG.r and hard_pixel.g == FG.g and hard_pixel.b == FG.b:
            _assert_pixel(aa, x, 1, FG, "hard-edged interior pixel must match in AA")


def test_draw_line_aa_respects_translucent_input_color() raises:
    # Regression test for a real bug caught during development: the
    # coverage-to-alpha formula used a hardcoded 255 instead of the
    # caller's color.a, so a fully-covered pixel with e.g. alpha=128
    # rendered fully OPAQUE (raw color.r, no blending at all) instead
    # of respecting the requested translucency. Invisible in every
    # prior test because they all happened to use opaque colors,
    # where coverage*255 == coverage*color.a by coincidence.
    var c = Canvas(9, 3, Color(0, 0, 0))
    draw_line_aa(c, 1, 1, 7, 1, Color(200, 0, 0, 128))
    # deep interior, fully covered -> single-blend value, not raw 200
    var p = c.get_pixel(4, 1)
    assert_equal(p.r, 100)
    assert_equal(p.g, 0)
    assert_equal(p.b, 0)


def test_draw_polyline_connects_segments() raises:
    # An "L": (1,1) -> (1,4) -> (4,4)
    var c = Canvas(6, 6, BG)
    var pts = List[Point]()
    pts.append(Point(1, 1))
    pts.append(Point(1, 4))
    pts.append(Point(4, 4))
    draw_polyline(c, pts, FG)

    for y in range(1, 5):
        _assert_pixel(c, 1, y, FG, "vertical segment")
    for x in range(1, 5):
        _assert_pixel(c, x, 4, FG, "horizontal segment")
    _assert_pixel(c, 4, 1, BG, "not on either segment")


def test_draw_polyline_does_not_double_blend_joints() raises:
    # Hand-verified: at the shared corner (1,4), a naive segment-by-
    # segment draw would blend the translucent color twice (once as
    # segment 1's endpoint, once as segment 2's start). Single-blend
    # value: r = (200*128 + 0*127) // 255 = 100.
    var c = Canvas(6, 6, Color(0, 0, 0))
    var pts = List[Point]()
    pts.append(Point(1, 1))
    pts.append(Point(1, 4))
    pts.append(Point(4, 4))
    draw_polyline(c, pts, Color(200, 0, 0, 128))

    var corner = c.get_pixel(1, 4)
    assert_equal(corner.r, 100)
    assert_equal(corner.g, 0)
    assert_equal(corner.b, 0)


def test_draw_polyline_single_and_empty() raises:
    var c = Canvas(3, 3, BG)
    var one = List[Point]()
    one.append(Point(1, 1))
    draw_polyline(c, one, FG)
    _assert_pixel(c, 1, 1, FG, "single point still plots")

    var c2 = Canvas(3, 3, BG)
    var empty = List[Point]()
    draw_polyline(c2, empty, FG)
    _assert_pixel(c2, 1, 1, BG, "empty list draws nothing")


def test_draw_polygon_closes_the_shape() raises:
    # A right triangle: (1,1) -> (4,1) -> (1,4) -> back to (1,1)
    var c = Canvas(6, 6, BG)
    var tri = List[Point]()
    tri.append(Point(1, 1))
    tri.append(Point(4, 1))
    tri.append(Point(1, 4))
    draw_polygon(c, tri, FG)

    for x in range(1, 5):
        _assert_pixel(c, x, 1, FG, "top edge")
    for y in range(1, 5):
        _assert_pixel(c, 1, y, FG, "closing edge (left side)")
    _assert_pixel(c, 3, 2, FG, "diagonal edge")
    _assert_pixel(c, 2, 3, FG, "diagonal edge")
    _assert_pixel(c, 4, 4, BG, "interior, unfilled -- outline only")


def test_draw_polygon_does_not_double_blend_any_vertex() raises:
    # Covers both joint categories a polygon has, since they're
    # different code paths: (1,1) is the CLOSING vertex, shared
    # between the first segment (as its start) and the closing
    # segment (as its end). (4,1) is an ordinary INTERIOR joint,
    # shared between two consecutive segments in the main loop --
    # same mechanism the polyline joint test already covers, but
    # worth asserting directly here too rather than only inferring it
    # from the loop being identical code.
    var c = Canvas(6, 6, Color(0, 0, 0))
    var tri = List[Point]()
    tri.append(Point(1, 1))
    tri.append(Point(4, 1))
    tri.append(Point(1, 4))
    draw_polygon(c, tri, Color(200, 0, 0, 128))

    var closing_vertex = c.get_pixel(1, 1)
    assert_equal(closing_vertex.r, 100)
    assert_equal(closing_vertex.g, 0)
    assert_equal(closing_vertex.b, 0)

    var interior_joint = c.get_pixel(4, 1)
    assert_equal(interior_joint.r, 100)
    assert_equal(interior_joint.g, 0)
    assert_equal(interior_joint.b, 0)


def test_draw_polyline_aa_joint_has_no_double_blend_hazard() raises:
    # An L-shape, same shape as the hard-edged joint test but through
    # the AA multi-segment coverage path. Two properties at once:
    #   1. Deep-interior, fully-covered points must show the
    #      single-blend value (100) -- this is also the regression
    #      check for the alpha bug: before the fix, a fully-covered
    #      pixel used a hardcoded 255 instead of color.a and rendered
    #      as raw, unblended 200.
    #   2. The joint pixel (2,5), hand-verified via a 16-sample trace
    #      of the minimum-distance-to-either-segment test: 15/16
    #      covered -> alpha 120 -> single-blend value 94. A naive
    #      per-segment draw_line_aa loop would double-blend here.
    var c = Canvas(8, 8, Color(0, 0, 0))
    var pts = List[Point]()
    pts.append(Point(2, 2))
    pts.append(Point(2, 5))
    pts.append(Point(5, 5))
    draw_polyline_aa(c, pts, Color(200, 0, 0, 128))

    var interior_v = c.get_pixel(2, 3)
    assert_equal(interior_v.r, 100)
    var interior_h = c.get_pixel(4, 5)
    assert_equal(interior_h.r, 100)

    var joint = c.get_pixel(2, 5)
    assert_equal(joint.r, 94)
    assert_equal(joint.g, 0)
    assert_equal(joint.b, 0)

    _assert_pixel(c, 0, 0, BG, "far corner untouched")


def test_draw_polygon_aa_closing_vertex_has_no_double_blend_hazard() raises:
    # Same two properties as the polyline AA test, for the closing
    # vertex specifically: (2,2) hand-verified via the same
    # minimum-distance trace to 94.
    var c = Canvas(8, 8, Color(0, 0, 0))
    var tri = List[Point]()
    tri.append(Point(2, 2))
    tri.append(Point(5, 2))
    tri.append(Point(2, 5))
    draw_polygon_aa(c, tri, Color(200, 0, 0, 128))

    var interior_edge = c.get_pixel(3, 2)
    assert_equal(interior_edge.r, 100)

    var closing_vertex = c.get_pixel(2, 2)
    assert_equal(closing_vertex.r, 94)
    assert_equal(closing_vertex.g, 0)
    assert_equal(closing_vertex.b, 0)

    _assert_pixel(c, 7, 7, BG, "far corner untouched")


def test_fill_polygon_matches_fill_rect_with_asymmetric_corners() raises:
    # fill_rect(x=1, y=1, width=4, height=2) fills columns 1..4
    # (inclusive) and rows 1..2. To match exactly, fill_polygon's
    # corners must be asymmetric: inclusive on the last column
    # (x+width-1) but one-past on the last row (y+height) -- see the
    # Y-extent-is-half-open explanation in fill_polygon's docstring.
    # Verified by direct pixel comparison, not just by trusting the
    # derivation.
    var hard = Canvas(8, 6, BG)
    fill_rect(hard, 1, 1, 4, 2, FG)

    var poly = Canvas(8, 6, BG)
    var rect_pts = List[Point]()
    rect_pts.append(Point(1, 1))
    rect_pts.append(Point(4, 1))
    rect_pts.append(Point(4, 3))
    rect_pts.append(Point(1, 3))
    fill_polygon(poly, rect_pts, FG)

    for y in range(6):
        for x in range(8):
            var h = hard.get_pixel(x, y)
            var p = poly.get_pixel(x, y)
            assert_equal(p.r, h.r, "mismatch at (" + String(x) + "," + String(y) + ")")


def test_fill_polygon_triangle_matches_hand_traced_rows() raises:
    # Hand-traced scanline crossings for triangle (1,1),(4,1),(1,4):
    # row widths 4,3,2 for y=1,2,3 (y=4 excluded -- the polygon's
    # bottom vertex is a single point there, correctly zero-width).
    # Unlike draw_polygon's stroke-only test on this same triangle,
    # the interior is now filled too.
    var c = Canvas(6, 6, BG)
    var tri = List[Point]()
    tri.append(Point(1, 1))
    tri.append(Point(4, 1))
    tri.append(Point(1, 4))
    fill_polygon(c, tri, FG)

    for x in range(1, 5):
        _assert_pixel(c, x, 1, FG, "row y=1, width 4")
    for x in range(1, 4):
        _assert_pixel(c, x, 2, FG, "row y=2, width 3")
    for x in range(1, 3):
        _assert_pixel(c, x, 3, FG, "row y=3, width 2")
    _assert_pixel(c, 1, 4, BG, "apex row, zero width")

    var count = 0
    for y in range(6):
        for x in range(6):
            var p = c.get_pixel(x, y)
            if p.r == FG.r and p.g == FG.g and p.b == FG.b:
                count += 1
    assert_equal(count, 9)


def test_fill_polygon_too_few_points_is_a_noop() raises:
    var c = Canvas(4, 4, BG)
    var one = List[Point]()
    one.append(Point(1, 1))
    fill_polygon(c, one, FG)
    var two = List[Point]()
    two.append(Point(1, 1))
    two.append(Point(2, 2))
    fill_polygon(c, two, FG)
    for y in range(4):
        for x in range(4):
            _assert_pixel(c, x, y, BG, "fewer than 3 points draws nothing")


def test_fill_polygon_blends_translucent_color_correctly() raises:
    var c = Canvas(6, 6, Color(0, 0, 0))
    var tri = List[Point]()
    tri.append(Point(1, 1))
    tri.append(Point(4, 1))
    tri.append(Point(1, 4))
    fill_polygon(c, tri, Color(200, 0, 0, 128))

    var p = c.get_pixel(2, 1)
    assert_equal(p.r, 100)
    assert_equal(p.g, 0)
    assert_equal(p.b, 0)


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


def test_draw_ellipse_degenerate_radius_plots_center() raises:
    var c = Canvas(3, 3, BG)
    draw_ellipse(c, 1, 1, 0, 5, FG)
    _assert_pixel(c, 1, 1, FG, "rx=0 falls back to a single pixel")

    var c2 = Canvas(3, 3, BG)
    draw_ellipse(c2, 1, 1, 5, 0, FG)
    _assert_pixel(c2, 1, 1, FG, "ry=0 falls back to a single pixel")


def test_draw_ellipse_matches_hand_traced_points() raises:
    # Hand-derived midpoint-ellipse run for rx=3, ry=2, centered at
    # (5,4) on an 11x9 canvas -- independently re-derived the decision
    # parameter update formulas from the ellipse equation rather than
    # trusting a remembered textbook version, then traced both regions
    # step by step. The resulting 12-point set matched the actual
    # code's output exactly on first run.
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
    # Regression test for the same category of bug just fixed in
    # draw_circle: draw_ellipse's region 1 starts at x==0 and region 2
    # ends at y==0, both real (not just theoretical) cases here, where
    # two of the 4 symmetric points collapse onto the same pixel.
    # Hand-verified via probe: all 4 axis extremes give the
    # single-blend value 100, not a double-blended 150.
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
    # Independently computed row half-widths for rx=5, ry=3 via the
    # same integer inequality the code uses (dx^2*ry^2 + dy^2*rx^2 <=
    # rx^2*ry^2): dy=0 -> dx=5, dy=1 -> dx=4, dy=2 -> dx=3, dy=3 -> dx=0.
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
    # Hand-verified by independently summing the 4x4 sub-sample grid
    # for rx=4, ry=2 at cx=5, cy=3 (pixel (px,py) sampled as centered
    # AT (px,py)): pixel (5,1) -- directly above center, at the top of
    # the minor axis -- has 8/16 sub-samples inside the true ellipse.
    # Pixel (3,1) has 3/16. Pixel (1,3) -- directly left of center, at
    # the end of the major axis -- also has 8/16, independently
    # confirming both axes' radii are honored, not just one.
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
    # Same regression category as fill_circle_aa's: confirms the
    # pixel-centered-at-(px,py) sampling convention (not a unit square
    # with (px,py) at its corner) by checking deep-interior pixels
    # agree exactly with the hard-edged fill_ellipse given identical
    # arguments -- not the extreme boundary points, which legitimately
    # get partial coverage since their pixel *center* sits on the true
    # boundary.
    var c = Canvas(11, 7, BG)
    fill_ellipse_aa(c, 5, 3, 4, 2, FG)
    _assert_pixel(c, 5, 3, FG, "center")
    _assert_pixel(c, 5, 2, FG, "interior, above center")
    _assert_pixel(c, 3, 3, FG, "interior, left of center")
    _assert_pixel(c, 7, 3, FG, "interior, right of center")


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
    # Hand-verified (each sample tested independently against the
    # outer ellipse (rx+0.5, ry+0.5) and inner ellipse (rx-0.5,
    # ry-0.5) in their own normalized space -- see draw_ellipse_aa's
    # docstring for why a single shared distance, like the circle
    # case uses, doesn't work here) for rx=5, ry=3 at cx=6, cy=4:
    # pixel (3,1) -- 3 pixels left, 3 up from center -- has 7/16
    # sub-samples inside the ring. Pixel (6,1), directly above center
    # at the top of the ellipse, is fully inside the ring (16/16).
    # Pixel (11,4), at the opposite (major) axis extreme, is also
    # fully inside (16/16), confirming both axes independently.
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


def test_is_dash_on_empty_pattern_is_always_on() raises:
    var no_dashes = List[Float64]()
    assert_true(_is_dash_on(0.0, no_dashes, 0.0))
    assert_true(_is_dash_on(1000.0, no_dashes, 0.0))
    assert_true(_is_dash_on(-5.0, no_dashes, 0.0))


def test_is_dash_on_matches_hand_traced_cycle() raises:
    # Pattern [3, 2]: on for distance in [0,3), off in [3,5), repeating
    # every 5 units. Hand-traced every boundary, not just interior
    # points -- the cycle wraps at exactly distance=5 back to on.
    var dashes: List[Float64] = [3.0, 2.0]
    assert_true(_is_dash_on(0.0, dashes, 0.0))
    assert_true(_is_dash_on(2.9, dashes, 0.0))
    assert_true(not _is_dash_on(3.0, dashes, 0.0))
    assert_true(not _is_dash_on(4.9, dashes, 0.0))
    assert_true(_is_dash_on(5.0, dashes, 0.0))  # wraps
    assert_true(_is_dash_on(10.0, dashes, 0.0))  # two full cycles


def test_is_dash_on_offset_shifts_the_pattern() raises:
    # distance=0 with offset=1 must behave like distance=1 with
    # offset=0 -- both "on" here (1 < 3), but this specifically
    # exercises the shift, not just another on point.
    var dashes: List[Float64] = [3.0, 2.0]
    assert_true(_is_dash_on(0.0, dashes, 1.0))
    assert_true(not _is_dash_on(2.0, dashes, 1.0))  # 2+1=3 -> off


def test_is_dash_on_negative_distance_wraps_correctly() raises:
    # Hand-traced and independently cross-checked twice over: the
    # cycle extends backward too -- [..., [-5,-2)=on, [-2,0)=off,
    # [0,3)=on, ...]. distance=-1 and -2 both fall in [-2,0) -> off
    # (a boundary point belongs to the segment it's the *start* of, so
    # -2.0 itself is the first off point, not the last on one).
    # distance=-4 falls in [-5,-2) -> on. A truncating (not
    # floor-based) modulo would get all of this wrong, since -1 / 5
    # truncates toward zero in most languages, landing outside
    # [0, total) instead of wrapping.
    var dashes: List[Float64] = [3.0, 2.0]
    assert_true(not _is_dash_on(-1.0, dashes, 0.0))
    assert_true(not _is_dash_on(-2.0, dashes, 0.0))
    assert_true(_is_dash_on(-4.0, dashes, 0.0))


def test_is_dash_on_odd_length_pattern_is_doubled() raises:
    # [5, 2, 1] doubles to [5, 2, 1, 5, 2, 1] (Cairo's own convention),
    # total period 16 (not 20 -- 5+2+1 = 8 per half, not 10): on
    # [0,5), off [5,7), on [7,8), off [8,13), on [13,15), off [15,16).
    # Every boundary here independently cross-checked before being
    # trusted, not just hand-arithmetic'd once.
    var dashes: List[Float64] = [5.0, 2.0, 1.0]
    assert_true(_is_dash_on(4.0, dashes, 0.0))  # in the first "on"
    assert_true(not _is_dash_on(6.0, dashes, 0.0))  # in the first "off"
    assert_true(_is_dash_on(7.5, dashes, 0.0))  # the short second "on"
    assert_true(not _is_dash_on(10.0, dashes, 0.0))  # second "off"
    assert_true(_is_dash_on(14.0, dashes, 0.0))  # third "on" (doubled half)
    assert_true(not _is_dash_on(15.5, dashes, 0.0))  # third "off", wraps next at 16


def test_draw_line_dashed_matches_hand_traced_on_off_pixels() raises:
    # Horizontal line: each Bresenham step is a pure x step (distance
    # +1.0 per pixel), so pixel x's distance is exactly x -- no
    # diagonal sqrt(2) steps to complicate hand-tracing. Pattern
    # [3, 2] over x=0..9: on 0,1,2, off 3,4, on 5,6,7, off 8,9.
    var dashes: List[Float64] = [3.0, 2.0]
    var c = Canvas(10, 1, BG)
    draw_line(c, 0, 0, 9, 0, FG, dashes)

    var on_xs: List[Int] = [0, 1, 2, 5, 6, 7]
    var off_xs: List[Int] = [3, 4, 8, 9]
    for x in on_xs:
        _assert_pixel(c, x, 0, FG, "expected on")
    for x in off_xs:
        _assert_pixel(c, x, 0, BG, "expected off")


def test_draw_line_no_dashes_is_unaffected() raises:
    # The default (empty dashes) must draw a fully solid line, same
    # as before this parameter existed -- a real regression risk given
    # how much of _draw_line_core's internals changed to support this.
    var c = Canvas(10, 1, BG)
    draw_line(c, 0, 0, 9, 0, FG)
    for x in range(10):
        _assert_pixel(c, x, 0, FG, "solid line, no gaps")


def test_draw_polyline_dash_phase_carries_across_the_joint() raises:
    # An L-shape, (0,0)->(4,0)->(4,4), pattern [3,2] (period 5).
    # Segment 0 (horizontal) ends at (4,0) with accumulated distance
    # 4 -- an off pixel (4 is in [3,5)), matching the previous test's
    # own trace. Segment 1 (vertical) must carry that 4 forward, not
    # restart its own distance at 0 -- the two behaviors diverge
    # specifically at (4,3): carried, its distance is 4+3=7 (wraps to
    # 2 -> on); reset-to-0, its distance would be 3 (-> off). This is
    # the one pixel that actually distinguishes correct carry-forward
    # from a per-segment reset, not just another on/off check.
    var dashes: List[Float64] = [3.0, 2.0]
    var points: List[Point] = [Point(0, 0), Point(4, 0), Point(4, 4)]
    var c = Canvas(10, 10, BG)
    draw_polyline(c, points, FG, dashes)

    _assert_pixel(c, 4, 3, FG, "on if phase carried, off if reset per segment")
    _assert_pixel(c, 4, 4, BG, "distance 8 -> off, confirms the carry continues correctly")


def test_draw_line_aa_dashed_has_background_gaps() raises:
    # Not a hand-computed-coverage test like the AA tests above --
    # just confirms dashing actually creates gaps in an AA stroke, the
    # same qualitative property the hard-edged test checks exactly.
    # width=1 keeps this close enough to the hard-edged case that a
    # generously-off-pattern point is unambiguously background.
    var dashes: List[Float64] = [3.0, 2.0]
    var c = Canvas(10, 3, BG)
    draw_line_aa(c, 0, 1, 9, 1, FG, dashes=dashes)

    _assert_pixel(c, 1, 1, FG, "well inside an on-run")
    _assert_pixel(c, 4, 1, BG, "well inside an off-run")


def test_draw_polyline_aa_dashed_has_background_gaps() raises:
    var dashes: List[Float64] = [3.0, 2.0]
    var points: List[Point] = [Point(0, 1), Point(9, 1)]
    var c = Canvas(10, 3, BG)
    draw_polyline_aa(c, points, FG, dashes=dashes)

    _assert_pixel(c, 1, 1, FG, "well inside an on-run")
    _assert_pixel(c, 4, 1, BG, "well inside an off-run")


def test_fill_rect_gradient_matches_gradient_color_at_per_pixel() raises:
    # Same gradient and hand-derived midpoint value as
    # test_gradient.mojo's own test_color_at_midpoint_interpolates_
    # linearly -- confirms fill_rect_gradient actually queries
    # color_at per pixel rather than, say, using one averaged color
    # for the whole rect.
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
    # center (0,0), radius 10 -- (6,8) is exactly distance 10 (a
    # 6-8-10 right triangle, the 3-4-5 triple scaled by 2), so its
    # color must land exactly on the last stop, not merely close to
    # it. Confirms fill_rect_radial_gradient queries color_at per
    # pixel, same as fill_rect_gradient's own equivalent test.
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


def test_arc_points_matches_hand_derived_quarter_circle() raises:
    # Independently computed by hand before trusting the code's own
    # output: radius=10, angle 0 -> pi/2 gives steps=max(4,int(10*
    # pi/2))=15 (16 points), start point exactly (10,0), end point
    # (0,10) (cos(pi/2) is ~6e-16, not exactly 0, but rounds to 0).
    var pts = _arc_points(0.0, 0.0, 10.0, 0.0, pi / 2.0)
    assert_equal(len(pts), 16)
    assert_equal(pts[0].x, 10)
    assert_equal(pts[0].y, 0)
    assert_equal(pts[15].x, 0)
    assert_equal(pts[15].y, 10)


def test_angle_in_span_matches_hand_traced_cases() raises:
    assert_true(_angle_in_span(pi / 4.0, 0.0, pi / 2.0))
    assert_true(not _angle_in_span(pi, 0.0, pi / 2.0))
    # A span crossing the atan2 discontinuity at +/-pi: a raw sample
    # angle of -3*pi/4 (atan2's own range) is equivalent to 5*pi/4,
    # which IS inside [5*pi/4, 7*pi/4] -- this is exactly the
    # wraparound case _angle_in_span exists to get right.
    assert_true(_angle_in_span(-3.0 * pi / 4.0, 5.0 * pi / 4.0, 7.0 * pi / 4.0))
    assert_true(not _angle_in_span(0.0, 5.0 * pi / 4.0, 7.0 * pi / 4.0))


def test_draw_arc_degenerate_radius_plots_center() raises:
    var c = Canvas(5, 5, BG)
    draw_arc(c, 2.0, 2.0, 0.0, 0.0, pi, FG)
    _assert_pixel(c, 2, 2, FG, "radius<=0 falls back to a single pixel")


def test_fill_arc_degenerate_radius_is_a_noop() raises:
    var c = Canvas(5, 5, BG)
    fill_arc(c, 2.0, 2.0, 0.0, 0.0, pi, FG)
    _assert_pixel(c, 2, 2, BG, "radius<=0 draws nothing (unlike draw_arc's single pixel)")


def test_fill_arc_wedge_covers_only_its_own_angle_span() raises:
    # A quarter-circle wedge from angle 0 to pi/2 (screen: right to
    # down) -- a point along that span's own bisector (angle pi/4)
    # must be filled; a point in the opposite direction (angle
    # 5*pi/4, i.e. up-left) must stay background.
    var c = Canvas(60, 60, BG)
    fill_arc(c, 30.0, 30.0, 20.0, 0.0, pi / 2.0, FG)
    _assert_pixel(c, 30 + 10, 30 + 10, FG, "inside the wedge's own bisector")
    _assert_pixel(c, 30 - 10, 30 - 10, BG, "opposite direction, outside the wedge")
    _assert_pixel(c, 30, 30, FG, "center is part of every wedge (the two radii meet there)")


def test_fill_arc_three_wedges_tile_a_full_circle_without_gaps() raises:
    # Three 120-degree wedges, same center/radius, covering a full
    # circle between them -- every point strictly inside the radius
    # must be covered by exactly one wedge's color, none left
    # background (a gap) and none showing a blended double-cover
    # (translucent color would reveal overlap; opaque colors can't
    # distinguish overlap from coverage, so this checks "not
    # background" everywhere inside, which a gap would fail).
    var c = Canvas(80, 80, BG)
    var cx = 40.0
    var cy = 40.0
    var r = 30.0
    var third = 2.0 * pi / 3.0
    fill_arc(c, cx, cy, r, 0.0, third, Color(255, 0, 0))
    fill_arc(c, cx, cy, r, third, 2.0 * third, Color(0, 255, 0))
    fill_arc(c, cx, cy, r, 2.0 * third, 3.0 * third, Color(0, 0, 255))

    var gaps = 0
    for dy in range(-20, 21):
        for dx in range(-20, 21):
            if dx * dx + dy * dy <= 15 * 15:  # comfortably inside the radius
                var p = c.get_pixel(40 + dx, 40 + dy)
                if p.r == BG.r and p.g == BG.g and p.b == BG.b:
                    gaps += 1
    assert_equal(gaps, 0)


def test_fill_arc_aa_respects_translucent_input_color() raises:
    var c = Canvas(60, 60, Color(0, 0, 0))
    fill_arc_aa(c, 30.0, 30.0, 20.0, 0.0, pi / 2.0, Color(200, 0, 0, 128))
    var p = c.get_pixel(40, 40)  # inside the wedge, well clear of any AA edge
    assert_equal(p.r, 100)
    assert_equal(p.g, 0)
    assert_equal(p.b, 0)


def test_fill_ring_sector_only_fills_between_the_two_radii() raises:
    var c = Canvas(80, 80, BG)
    fill_ring_sector(c, 40.0, 40.0, 15.0, 30.0, 0.0, 2.0 * pi, FG)
    _assert_pixel(c, 40, 40, BG, "inner hole stays background")
    _assert_pixel(c, 40 + 22, 40, FG, "the ring itself is filled")
    _assert_pixel(c, 40 + 45, 40, BG, "well outside the outer radius stays background")


def test_fill_ring_sector_degenerate_radii_is_a_noop() raises:
    var c = Canvas(10, 10, BG)
    fill_ring_sector(c, 5.0, 5.0, 3.0, 3.0, 0.0, 2.0 * pi, FG)  # inner == outer
    fill_ring_sector(c, 5.0, 5.0, 5.0, 3.0, 0.0, 2.0 * pi, FG)  # inner > outer
    fill_ring_sector(c, 5.0, 5.0, -1.0, 0.0, 0.0, 2.0 * pi, FG)  # outer <= 0
    _assert_pixel(c, 5, 5, BG, "every degenerate radius combination draws nothing")


def test_fill_ring_sector_aa_respects_translucent_input_color() raises:
    var c = Canvas(80, 80, Color(0, 0, 0))
    fill_ring_sector_aa(c, 40.0, 40.0, 15.0, 30.0, 0.0, 2.0 * pi, Color(200, 0, 0, 128))
    var p = c.get_pixel(40 + 22, 40)  # deep in the ring, clear of any AA edge
    assert_equal(p.r, 100)
    assert_equal(p.g, 0)
    assert_equal(p.b, 0)


def test_fill_ring_sector_aa_fills_past_the_outer_arcs_own_bounding_box() raises:
    """Regression test for canvas_mojo issue #33: a wedge whose
    [start_angle, end_angle] span doesn't cross a cardinal angle (0,
    pi/2, pi, 3*pi/2) has an inner-arc extreme that reaches *closer to
    the center* than anything on the outer arc does over that same
    span -- past the outer arc's own bounding box, not inside it (see
    _arc_bounds's own docstring for the full reasoning). Before the
    fix, `fill_ring_sector_aa` scanned only the outer arc's own
    bounding box and never visited pixels beyond it, leaving a
    rectangular notch cut into the ring instead of a clean angular gap.

    cx=cy=100, outer_radius=100, inner_radius=50, start_angle=pi/6
    (30deg), end_angle=pi/3 (60deg) -- deliberately round angles so the
    geometry is exact, not approximated. Independently computed (not
    just trusted from this file's own code, and not from
    canvas_mojo's own `_arc_bounds`/`cos`/`sin` either) via Python's
    `math` module:

    - The outer arc's own y-range over that span is exactly
      [150, 186.60...] (both endpoints; no cardinal angle falls in
      [30deg, 60deg], so no crossing point adds to that range).
    - The straight edge from the outer endpoint at 30deg,
      (186.60..., 150), back to the inner endpoint at 30deg,
      (143.30..., 125), passes through y=125 -- 25 below the outer
      arc's own min_y=150, i.e. past its bounding box, not inside it.
    - A point deep inside the ring sector, well clear of every edge
      (angle=35deg, 5deg in from the 30deg boundary; radius=60, 10
      units in from inner_radius=50 and 40 from outer_radius=100),
      rounds to pixel (149, 134): y=134 is inside the *old* buggy
      py-scan range (~[149, 188], i.e. never visited -- 134 < 149,
      confirmed with the pre-fix code actually producing background
      there) but well inside the *fixed* range (~[124, 188]).
    """
    var c = Canvas(200, 200, BG)
    fill_ring_sector_aa(c, 100.0, 100.0, 50.0, 100.0, pi / 6.0, pi / 3.0, FG)
    _assert_pixel(c, 149, 134, FG, "deep in the ring, past the outer arc's own bounding box")


def test_spans_from_crossings_merges_touching_spans() raises:
    # Independently traced by hand before trusting the code: four
    # crossings at x=[10,15,15,20] with directions [+1,-1,+1,-1] (two
    # unrelated edges happening to cross the same row at the same
    # rounded x=15, a real, reachable pattern for a self-intersecting
    # shape, not a contrived one) produce, from the winding scan
    # alone, two spans (10,15) and (15,20) that both -- correctly,
    # given X-fill's own inclusive-inclusive convention -- include
    # x=15, which would double-blend a translucent color there without
    # the merge step. Confirmed the merge collapses them into one
    # span (10,20), covering x=15 exactly once.
    var crossings: List[_Crossing] = [
        _Crossing(10, 1),
        _Crossing(15, -1),
        _Crossing(15, 1),
        _Crossing(20, -1),
    ]
    var spans = _spans_from_crossings(crossings, FillRule.EVEN_ODD)
    assert_equal(len(spans), 1)
    assert_equal(spans[0].start_x, 10)
    assert_equal(spans[0].end_x, 20)


def test_fill_polygon_self_intersecting_bowtie_matches_hand_derived_spans() raises:
    # A "bowtie": (0,0),(20,0),(0,20),(20,20) in this vertex order
    # crosses itself at (10,10) -- independently traced by hand:
    # both y=5 (upper triangle) and y=15 (lower triangle, symmetric)
    # fill x=[5,15]. This is the case fill_polygon's own docstring
    # used to warn wasn't supported; it's just a self-intersecting
    # simple case (a genuine pinch, not an overlap) where EVEN_ODD and
    # NONZERO happen to agree -- see the fill_path tests for a case
    # where they don't.
    var pts: List[Point] = [Point(0, 0), Point(20, 0), Point(0, 20), Point(20, 20)]
    var c = Canvas(21, 21, BG)
    fill_polygon(c, pts, FG)

    for x in range(5, 16):
        _assert_pixel(c, x, 5, FG, "upper triangle at y=5")
        _assert_pixel(c, x, 15, FG, "lower triangle at y=15")
    _assert_pixel(c, 2, 5, BG, "outside the upper triangle")
    _assert_pixel(c, 2, 15, BG, "outside the lower triangle")


def test_fill_polygon_nonzero_agrees_with_even_odd_for_a_simple_polygon() raises:
    # The two fill rules only ever diverge where a shape's own winding
    # number reaches 2 or more (an overlap) -- for any simple polygon,
    # nowhere does, so they must always agree. A real property to
    # check, not just "both compile": a triangle, both rules.
    var pts: List[Point] = [Point(10, 10), Point(50, 10), Point(30, 50)]
    var c1 = Canvas(60, 60, BG)
    fill_polygon(c1, pts, FG, fill_rule=FillRule.EVEN_ODD)
    var c2 = Canvas(60, 60, BG)
    fill_polygon(c2, pts, FG, fill_rule=FillRule.NONZERO)

    for y in range(60):
        for x in range(60):
            var p1 = c1.get_pixel(x, y)
            var p2 = c2.get_pixel(x, y)
            assert_equal(p1.r, p2.r)
            assert_equal(p1.g, p2.g)
            assert_equal(p1.b, p2.b)


def test_point_in_polygon_matches_hand_derived_membership() raises:
    # Right triangle (0,0),(20,0),(0,20) -- hypotenuse is the line
    # x+y=20, so membership is exactly "x>=0 and y>=0 and x+y<20".
    # Independently confirmed by hand before trusting this.
    var tri: List[Point] = [Point(0, 0), Point(20, 0), Point(0, 20)]
    assert_true(_point_in_polygon(tri, 5.0, 5.0, FillRule.EVEN_ODD))  # 10 < 20
    assert_true(not _point_in_polygon(tri, 15.0, 15.0, FillRule.EVEN_ODD))  # 30 > 20
    assert_true(_point_in_polygon(tri, 9.9, 9.9, FillRule.EVEN_ODD))  # 19.8 < 20
    assert_true(not _point_in_polygon(tri, 10.1, 10.1, FillRule.EVEN_ODD))  # 20.2 > 20
    assert_true(not _point_in_polygon(tri, -5.0, -5.0, FillRule.EVEN_ODD))


def test_fill_polygon_aa_fully_covered_pixel_is_written_directly() raises:
    var tri: List[Point] = [Point(0, 0), Point(20, 0), Point(0, 20)]
    var c = Canvas(21, 21, BG)
    fill_polygon_aa(c, tri, FG)
    # (5,5): all 16 sub-samples inside (5+5=10 well under 20) -- full
    # coverage, written directly, no blending.
    _assert_pixel(c, 5, 5, FG, "fully covered")


def test_fill_polygon_aa_pixel_outside_bounding_box_is_untouched() raises:
    var tri: List[Point] = [Point(0, 0), Point(20, 0), Point(0, 20)]
    var c = Canvas(30, 30, BG)
    fill_polygon_aa(c, tri, FG)
    _assert_pixel(c, 25, 25, BG, "outside the bounding box, never sampled")


def test_fill_polygon_aa_zero_coverage_pixel_inside_bounding_box_is_untouched() raises:
    # (15,15) is inside the triangle's bounding box (0..20 both axes)
    # but has zero sub-samples inside the actual shape (15+15=30, well
    # past the hypotenuse) -- distinct from being outside the box
    # entirely, and worth its own test: a naive "touch every pixel in
    # the box" implementation could get this wrong in a way the
    # far-outside case wouldn't catch.
    var tri: List[Point] = [Point(0, 0), Point(20, 0), Point(0, 20)]
    var c = Canvas(21, 21, BG)
    fill_polygon_aa(c, tri, FG)
    _assert_pixel(c, 15, 15, BG, "inside the bounding box, zero coverage")


def test_fill_polygon_aa_partial_coverage_matches_hand_computed_values() raises:
    # Hand-verified by independently summing the 4x4 sub-sample grid
    # (same methodology as fill_circle_aa's own equivalent test, same
    # white-on-black setup so the resulting gray value equals the
    # coverage fraction exactly: round(n/16 * 255)): pixel (10,10)
    # (straddling the hypotenuse) has 6/16 covered -> alpha 96; pixel
    # (0,10) (straddling the left edge, x=0) has 8/16 -> alpha 128.
    var tri: List[Point] = [Point(0, 0), Point(20, 0), Point(0, 20)]
    var c = Canvas(21, 21, BG)
    fill_polygon_aa(c, tri, FG)

    var hyp = c.get_pixel(10, 10)
    assert_equal(hyp.r, 96)
    assert_equal(hyp.g, 96)
    assert_equal(hyp.b, 96)

    var edge = c.get_pixel(0, 10)
    assert_equal(edge.r, 128)
    assert_equal(edge.g, 128)
    assert_equal(edge.b, 128)


def test_fill_polygon_aa_respects_translucent_input_color() raises:
    var tri: List[Point] = [Point(0, 0), Point(20, 0), Point(0, 20)]
    var c = Canvas(21, 21, Color(0, 0, 0))
    fill_polygon_aa(c, tri, Color(200, 0, 0, 128))
    var p = c.get_pixel(5, 5)  # deep interior, fully covered
    assert_equal(p.r, 100)
    assert_equal(p.g, 0)
    assert_equal(p.b, 0)


def test_point_in_polygon_nonzero_fills_the_overlap_of_a_bridge_connected_double_square() raises:
    # fill_polygon (unlike fill_path) has no multiple-sub-path notion
    # -- a bowtie's single pinch point isn't enough to show EVEN_ODD
    # vs. NONZERO actually diverge (see fill_rule.mojo's own example
    # docstring for why), so demonstrating real divergence on ONE
    # closed polygon needs a shape whose winding genuinely reaches 2
    # somewhere: two same-direction squares, A=(0,0)-(20,20) and
    # B=(10,10)-(30,30), connected into a single closed boundary by a
    # zero-width "bridge" edge walked out and back --
    # (0,0)->(20,0)->(20,20)->(0,20)->(0,0)->(10,10)->(30,10)->
    # (30,30)->(10,30)->(10,10)->[closes back to (0,0)]. The bridge's
    # two coincident opposite-direction traversals cancel each other's
    # winding contribution everywhere except exactly on that segment
    # (never sampled by the test points below), so away from it this
    # behaves exactly like the two squares independently -- confirmed
    # by hand before trusting this: EVEN_ODD sees the overlap
    # crossed twice (a hole), NONZERO sees the same-direction winding
    # reach 2 there (solid), each square's own non-overlapping
    # interior agreeing under both rules.
    var poly: List[Point] = [
        Point(0, 0), Point(20, 0), Point(20, 20), Point(0, 20), Point(0, 0),
        Point(10, 10), Point(30, 10), Point(30, 30), Point(10, 30), Point(10, 10),
    ]
    assert_true(_point_in_polygon(poly, 5.0, 5.0, FillRule.EVEN_ODD))
    assert_true(_point_in_polygon(poly, 5.0, 5.0, FillRule.NONZERO))
    assert_true(_point_in_polygon(poly, 25.0, 25.0, FillRule.EVEN_ODD))
    assert_true(_point_in_polygon(poly, 25.0, 25.0, FillRule.NONZERO))
    assert_true(not _point_in_polygon(poly, 15.0, 15.0, FillRule.EVEN_ODD))  # hole
    assert_true(_point_in_polygon(poly, 15.0, 15.0, FillRule.NONZERO))  # solid
    assert_true(not _point_in_polygon(poly, 35.0, 35.0, FillRule.EVEN_ODD))
    assert_true(not _point_in_polygon(poly, 35.0, 35.0, FillRule.NONZERO))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
