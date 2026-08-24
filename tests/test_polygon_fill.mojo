"""Tests for canvas_mojo/shapes/polygon_fill.mojo: exact pixel sets for
known inputs, verified against hand-traced runs of the same algorithms.
"""

from std.testing import assert_equal, assert_true, TestSuite

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas
from canvas_mojo.geometry import Point
from canvas_mojo.fill_rule import FillRule
from canvas_mojo.shapes.rects import fill_rect
from canvas_mojo.shapes.polygon_fill import (
    fill_polygon,
    fill_polygon_aa,
    _point_in_polygon,
    _Crossing,
    _spans_from_crossings,
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


def test_fill_polygon_matches_fill_rect_with_asymmetric_corners() raises:
    # fill_rect(x=1, y=1, width=4, height=2) fills columns 1..4 and
    # rows 1..2. Matching it exactly needs asymmetric polygon corners:
    # inclusive on the last column (x+width-1), one-past on the last
    # row (y+height) -- see fill_polygon's half-open Y-extent.
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
            assert_equal(
                p.r, h.r, "mismatch at (" + String(x) + "," + String(y) + ")"
            )


def test_fill_polygon_triangle_matches_hand_traced_rows() raises:
    # Hand-traced scanline crossings for triangle (1,1),(4,1),(1,4):
    # row widths 4,3,2 at y=1,2,3, with y=4 excluded, where the bottom
    # vertex is a single zero-width point.
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


def test_spans_from_crossings_merges_touching_spans() raises:
    # Four crossings at x=[10,15,15,20] with directions [+1,-1,+1,-1]
    # -- two unrelated edges crossing one row at the same rounded x=15,
    # reachable in any self-intersecting shape. The winding scan alone
    # gives spans (10,15) and (15,20), both of which include x=15 under
    # the inclusive X-fill convention, double-blending a translucent
    # color there. The merge step collapses them to (10,20), covering
    # x=15 once.
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
    # fill x=[5,15]. A genuine pinch rather than an overlap, so
    # EVEN_ODD and NONZERO agree here -- see the fill_path tests for a
    # case where they don't.
    var pts: List[Point] = [
        Point(0, 0),
        Point(20, 0),
        Point(0, 20),
        Point(20, 20),
    ]
    var c = Canvas(21, 21, BG)
    fill_polygon(c, pts, FG)

    for x in range(5, 16):
        _assert_pixel(c, x, 5, FG, "upper triangle at y=5")
        _assert_pixel(c, x, 15, FG, "lower triangle at y=15")
    _assert_pixel(c, 2, 5, BG, "outside the upper triangle")
    _assert_pixel(c, 2, 15, BG, "outside the lower triangle")


def test_fill_polygon_nonzero_agrees_with_even_odd_for_a_simple_polygon() raises:
    # The two rules diverge only where winding reaches 2 or more, which
    # never happens in a simple polygon, so a triangle must fill
    # identically under both.
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
    # Right triangle (0,0),(20,0),(0,20): the hypotenuse is x+y=20, so
    # membership is exactly "x>=0 and y>=0 and x+y<20".
    var tri: List[Point] = [Point(0, 0), Point(20, 0), Point(0, 20)]
    assert_true(_point_in_polygon(tri, 5.0, 5.0, FillRule.EVEN_ODD))  # 10 < 20
    assert_true(
        not _point_in_polygon(tri, 15.0, 15.0, FillRule.EVEN_ODD)
    )  # 30 > 20
    assert_true(
        _point_in_polygon(tri, 9.9, 9.9, FillRule.EVEN_ODD)
    )  # 19.8 < 20
    assert_true(
        not _point_in_polygon(tri, 10.1, 10.1, FillRule.EVEN_ODD)
    )  # 20.2 > 20
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
    # (15,15) sits inside the bounding box but has zero sub-samples
    # inside the shape (15+15=30, past the hypotenuse) -- a case a
    # naive "touch every pixel in the box" implementation gets wrong
    # and the far-outside case wouldn't catch.
    var tri: List[Point] = [Point(0, 0), Point(20, 0), Point(0, 20)]
    var c = Canvas(21, 21, BG)
    fill_polygon_aa(c, tri, FG)
    _assert_pixel(c, 15, 15, BG, "inside the bounding box, zero coverage")


def test_fill_polygon_aa_partial_coverage_matches_hand_computed_values() raises:
    # Hand-summed 4x4 sub-sample grids, white-on-black so the gray
    # value equals the coverage fraction exactly (round(n/16 * 255)):
    # pixel (10,10) straddles the hypotenuse at 6/16 -> alpha 96, and
    # (0,10) straddles the left edge at 8/16 -> alpha 128.
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
    # fill_polygon has no sub-paths, and a bowtie's single pinch point
    # can't make EVEN_ODD and NONZERO diverge, so showing divergence on
    # one closed polygon needs a shape whose winding reaches 2: two
    # same-direction squares, A=(0,0)-(20,20) and B=(10,10)-(30,30),
    # joined into one boundary by a zero-width bridge walked out and
    # back -- (0,0)->(20,0)->(20,20)->(0,20)->(0,0)->(10,10)->
    # (30,10)->(30,30)->(10,30)->(10,10)->[closes to (0,0)].
    #
    # The bridge's two coincident opposite-direction traversals cancel
    # everywhere except on that segment, never sampled below, so away
    # from it this behaves as the two squares would independently:
    # EVEN_ODD sees the overlap crossed twice (a hole), NONZERO sees
    # winding reach 2 (solid), and both agree on each square's
    # non-overlapping interior.
    var poly: List[Point] = [
        Point(0, 0),
        Point(20, 0),
        Point(20, 20),
        Point(0, 20),
        Point(0, 0),
        Point(10, 10),
        Point(30, 10),
        Point(30, 30),
        Point(10, 30),
        Point(10, 10),
    ]
    assert_true(_point_in_polygon(poly, 5.0, 5.0, FillRule.EVEN_ODD))
    assert_true(_point_in_polygon(poly, 5.0, 5.0, FillRule.NONZERO))
    assert_true(_point_in_polygon(poly, 25.0, 25.0, FillRule.EVEN_ODD))
    assert_true(_point_in_polygon(poly, 25.0, 25.0, FillRule.NONZERO))
    assert_true(
        not _point_in_polygon(poly, 15.0, 15.0, FillRule.EVEN_ODD)
    )  # hole
    assert_true(_point_in_polygon(poly, 15.0, 15.0, FillRule.NONZERO))  # solid
    assert_true(not _point_in_polygon(poly, 35.0, 35.0, FillRule.EVEN_ODD))
    assert_true(not _point_in_polygon(poly, 35.0, 35.0, FillRule.NONZERO))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
