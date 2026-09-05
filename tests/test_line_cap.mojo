"""Tests for LineCap: how an open stroke's two ends are finished.

The numbers here are hand-derived from the geometry rather than read
back from output. A stroke of width W centered on a horizontal segment
from x=a to x=b covers, at its own row:

  BUTT    [a, b]                 -- stops dead at each endpoint
  SQUARE  [a - W/2, b + W/2]     -- flat, half a width past each
  ROUND   [a - W/2, b + W/2]     -- same extent, but curved, so the
                                    corners of that box are outside it

which is what the extent and corner assertions below check.
"""

from std.testing import assert_equal, assert_true, TestSuite

from canvas.buffer import Canvas
from canvas.color import Color
from canvas.geometry import FPoint
from canvas.path import Path, stroke_path_aa
from canvas.shapes.lines import LineCap, draw_line_aa, draw_polyline_aa

comptime BG = Color(0, 0, 0)
comptime FG = Color(255, 255, 255)


def _row_extent(c: Canvas, y: Int) -> Tuple[Int, Int]:
    """First and last column on row `y` carrying any ink, or (-1, -1)."""
    var first = -1
    var last = -1
    for x in range(c.width):
        if c.get_pixel(x, y).r > 0:
            if first < 0:
                first = x
            last = x
    return (first, last)


def test_butt_cap_stops_at_the_endpoint() raises:
    # Width 8 centered on y=20, from x=20 to x=60. A butt cap must not
    # reach x=19 or x=61.
    var c = Canvas(80, 40, BG)
    draw_line_aa(c, 20.0, 20.0, 60.0, 20.0, FG, 8.0, 4, cap=LineCap.BUTT)
    var extent = _row_extent(c, 20)
    assert_equal(extent[0], 20, "butt cap starts exactly at the endpoint")
    assert_equal(extent[1], 60, "and ends exactly at the other")


def test_round_cap_overhangs_by_half_the_width() raises:
    # The default, and the behavior that motivates the others: a
    # width-8 stroke extends 4px past each endpoint.
    var c = Canvas(80, 40, BG)
    draw_line_aa(c, 20.0, 20.0, 60.0, 20.0, FG, 8.0)
    var extent = _row_extent(c, 20)
    assert_equal(extent[0], 16, "round cap reaches half a width back")
    assert_equal(extent[1], 64, "and half a width forward")


def test_square_cap_matches_round_extent_but_fills_the_corners() raises:
    # Same extent as ROUND along the stroke's own axis...
    var square = Canvas(80, 40, BG)
    draw_line_aa(square, 20.0, 20.0, 60.0, 20.0, FG, 8.0, 4, cap=LineCap.SQUARE)
    var extent = _row_extent(square, 20)
    assert_equal(extent[0], 16, "square cap reaches half a width back")
    assert_equal(extent[1], 64, "and half a width forward")

    # ...but the cap is a box, not a disk, so the far corner of that
    # box is inside a square cap and outside a round one. That corner
    # is the only thing distinguishing the two.
    var round_c = Canvas(80, 40, BG)
    draw_line_aa(round_c, 20.0, 20.0, 60.0, 20.0, FG, 8.0)
    assert_true(
        Int(square.get_pixel(17, 17).r) > Int(round_c.get_pixel(17, 17).r),
        "the cap corner is covered by SQUARE and not by ROUND",
    )


def test_butt_cap_is_strictly_less_ink_than_round() raises:
    var butt = Canvas(80, 40, BG)
    var round_c = Canvas(80, 40, BG)
    draw_line_aa(butt, 20.0, 20.0, 60.0, 20.0, FG, 8.0, 4, cap=LineCap.BUTT)
    draw_line_aa(round_c, 20.0, 20.0, 60.0, 20.0, FG, 8.0)

    var ink_butt = 0
    var ink_round = 0
    for y in range(40):
        for x in range(80):
            ink_butt += Int(butt.get_pixel(x, y).r)
            ink_round += Int(round_c.get_pixel(x, y).r)
    assert_true(ink_butt < ink_round, "butt removes both caps' worth of ink")


def test_cap_does_not_affect_interior_joints() raises:
    # Only the two extremities are capped. An interior joint keeps its
    # round overlap, which is what stops it double-blending -- so the
    # corner of an L must still be filled under BUTT.
    var pts: List[FPoint] = [
        FPoint(20.0, 20.0),
        FPoint(50.0, 20.0),
        FPoint(50.0, 50.0),
    ]
    var c = Canvas(80, 80, BG)
    draw_polyline_aa(c, pts, FG, 8.0, 4, cap=LineCap.BUTT)
    assert_equal(
        c.get_pixel(52, 22).r,
        255,
        "the outside of the interior corner is still covered",
    )
    # ...while the two open ends are cut.
    assert_equal(c.get_pixel(15, 20).r, 0, "the start end is cut")
    assert_equal(c.get_pixel(50, 56).r, 0, "the finish end is cut")


def test_closed_polygon_ignores_the_cap() raises:
    # A closed shape has no ends, so every cap must render identically.
    var square_pts: List[FPoint] = [
        FPoint(20.0, 20.0),
        FPoint(60.0, 20.0),
        FPoint(60.0, 60.0),
        FPoint(20.0, 60.0),
    ]
    var a = Canvas(80, 80, BG)
    var b = Canvas(80, 80, BG)
    var p1 = Path()
    var p2 = Path()
    for i in range(len(square_pts)):
        if i == 0:
            p1.move_to(square_pts[i].x, square_pts[i].y)
            p2.move_to(square_pts[i].x, square_pts[i].y)
        else:
            p1.line_to(square_pts[i].x, square_pts[i].y)
            p2.line_to(square_pts[i].x, square_pts[i].y)
    p1.close()
    p2.close()
    stroke_path_aa(a, p1, FG, 6.0)
    stroke_path_aa(b, p2, FG, 6.0, cap=LineCap.BUTT)

    for y in range(80):
        for x in range(80):
            assert_equal(
                a.get_pixel(x, y).r,
                b.get_pixel(x, y).r,
                "a closed sub-path renders the same under any cap",
            )


def test_default_cap_is_unchanged_behaviour() raises:
    # Compatibility: omitting `cap` must be byte-identical to passing
    # ROUND, which is what every existing caller relies on.
    var omitted = Canvas(80, 40, BG)
    var explicit = Canvas(80, 40, BG)
    draw_line_aa(omitted, 12.0, 18.0, 66.0, 26.0, FG, 5.0)
    draw_line_aa(
        explicit, 12.0, 18.0, 66.0, 26.0, FG, 5.0, 4, cap=LineCap.ROUND
    )
    for y in range(40):
        for x in range(80):
            assert_equal(omitted.get_pixel(x, y).r, explicit.get_pixel(x, y).r)


def test_dashed_stroke_honours_the_cap() raises:
    # The dashed path is a separate, scalar sample loop from the
    # vectorized one, so it needs its own coverage.
    var dashes: List[Float64] = [10.0, 6.0]
    var c = Canvas(80, 40, BG)
    draw_line_aa(
        c, 20.0, 20.0, 60.0, 20.0, FG, 8.0, 4, dashes, 0.0, LineCap.BUTT
    )
    var extent = _row_extent(c, 20)
    assert_equal(extent[0], 20, "a dashed butt cap starts at the endpoint")
    assert_true(extent[1] <= 60, "and never reaches past the far one")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
