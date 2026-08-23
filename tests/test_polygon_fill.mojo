"""Tests for canvas_mojo/shapes/polygon_fill.mojo: exact pixel sets for
known inputs, verified against hand-traced runs of the same
algorithms. Split out of the original monolithic test_primitives.mojo
along with canvas_mojo/primitives.mojo's own split into
canvas_mojo/shapes/ -- see that subpackage's own module docstrings for
why.
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


def _assert_pixel(c: Canvas, x: Int, y: Int, expected: Color, label: String) raises:
    var p = c.get_pixel(x, y)
    assert_equal(p.r, expected.r, label + " (r)")
    assert_equal(p.g, expected.g, label + " (g)")
    assert_equal(p.b, expected.b, label + " (b)")


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
    # fill x=[5,15]. A genuine pinch rather than an overlap, so
    # EVEN_ODD and NONZERO agree here -- see the fill_path tests for a
    # case where they don't.
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
