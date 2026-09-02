"""Tests for LineJoin: how a stroke turns a corner.

A right-angle corner is the case worth pinning, because the three
styles differ there by amounts that are exactly calculable. A stroke of
half-width h turning 90 degrees reaches:

  BEVEL   h            from the corner -- the flat cut
  ROUND   h            from the corner -- the disk's own radius
  MITER   h * sqrt(2)  from the corner -- h / cos(45 degrees)

so along the diagonal that bisects the corner, MITER covers about 41%
further out than the other two, and that is what the extent
assertions below check.
"""

from std.math import sqrt
from std.testing import assert_equal, assert_true, TestSuite

from canvas.buffer import Canvas
from canvas.color import Color
from canvas.geometry import FPoint
from canvas.shapes.lines import LineJoin, draw_polyline_aa

comptime BG = Color(0, 0, 0)
comptime FG = Color(255, 255, 255)


def _corner(join: LineJoin, miter_limit: Float64 = 4.0) raises -> Canvas:
    # An L: right along y=40, then down at x=60. The outer side of the
    # corner is up-and-right of (60, 40).
    var pts: List[FPoint] = [
        FPoint(20.0, 40.0),
        FPoint(60.0, 40.0),
        FPoint(60.0, 80.0),
    ]
    var c = Canvas(100, 100, BG)
    draw_polyline_aa(c, pts, FG, 12.0, join=join, miter_limit=miter_limit)
    return c^


def _ink(c: Canvas) -> Int:
    var total = 0
    for y in range(c.height):
        for x in range(c.width):
            total += Int(c.get_pixel(x, y).r)
    return total


def test_miter_reaches_further_than_bevel_at_a_right_angle() raises:
    # Hand-derived. Half-width is 6 and the corner is at (60, 40), so
    # the two outer quad corners are (60, 34) and (66, 40), and the
    # miter apex is at (66, 34) -- 6*sqrt(2) ~= 8.49 out along the
    # diagonal, which is h / cos(45 degrees).
    #
    # That makes the miter's join the square [60, 66] x [34, 40], while
    # bevel is the triangle cut across its diagonal and round is the
    # arc at radius 6. The pixel (65, 35) is inside the square, outside
    # the triangle ((65-60) + (40-35) = 10 > 6) and outside the arc
    # (sqrt(50) ~= 7.07 > 6), so it separates all three.
    var bevel = _corner(LineJoin.BEVEL)
    var round_c = _corner(LineJoin.ROUND)
    var miter = _corner(LineJoin.MITER)
    assert_equal(miter.get_pixel(65, 35).r, 255, "miter fills the corner")
    assert_equal(bevel.get_pixel(65, 35).r, 0, "bevel cuts it off")
    assert_equal(round_c.get_pixel(65, 35).r, 0, "round stops at its radius")

    # And beyond the apex, none of them reach.
    assert_equal(miter.get_pixel(70, 30).r, 0, "nothing reaches past the apex")


def test_round_and_bevel_agree_on_the_corner_pixel() raises:
    # Both stop at half-width from the corner, so a point comfortably
    # beyond that is outside either.
    var round_c = _corner(LineJoin.ROUND)
    var bevel = _corner(LineJoin.BEVEL)
    assert_equal(round_c.get_pixel(70, 30).r, 0, "round stops short too")
    assert_equal(bevel.get_pixel(70, 30).r, 0)
    # ...but round bulges past the bevel's flat cut nearer the corner.
    assert_true(
        _ink(round_c) > _ink(bevel),
        "a round join covers more than the flat cut it replaces",
    )


def test_miter_covers_the_most_bevel_the_least() raises:
    var round_ink = _ink(_corner(LineJoin.ROUND))
    var bevel_ink = _ink(_corner(LineJoin.BEVEL))
    var miter_ink = _ink(_corner(LineJoin.MITER))
    assert_true(bevel_ink < round_ink, "bevel is the tightest join")
    assert_true(round_ink < miter_ink, "miter is the loosest")


def test_miter_limit_falls_back_to_bevel_on_a_sharp_corner() raises:
    # A near-reversal: the miter apex would run far past the corner, so
    # the limit has to catch it. With the fallback working, the result
    # is exactly the bevel.
    var pts: List[FPoint] = [
        FPoint(20.0, 50.0),
        FPoint(70.0, 50.0),
        FPoint(22.0, 46.0),
    ]
    var mitered = Canvas(100, 100, BG)
    draw_polyline_aa(
        mitered, pts, FG, 8.0, join=LineJoin.MITER, miter_limit=4.0
    )
    var beveled = Canvas(100, 100, BG)
    draw_polyline_aa(beveled, pts, FG, 8.0, join=LineJoin.BEVEL)
    for y in range(100):
        for x in range(100):
            assert_equal(
                mitered.get_pixel(x, y).r,
                beveled.get_pixel(x, y).r,
                "past the miter limit, MITER renders as BEVEL",
            )


def test_a_generous_miter_limit_keeps_the_spike() raises:
    # The same sharp corner with the limit raised must differ from
    # bevel -- otherwise the previous test would pass for the wrong
    # reason (a miter that never draws at all).
    var pts: List[FPoint] = [
        FPoint(20.0, 50.0),
        FPoint(70.0, 50.0),
        FPoint(22.0, 46.0),
    ]
    var sharp = Canvas(100, 100, BG)
    draw_polyline_aa(sharp, pts, FG, 8.0, join=LineJoin.MITER, miter_limit=60.0)
    var beveled = Canvas(100, 100, BG)
    draw_polyline_aa(beveled, pts, FG, 8.0, join=LineJoin.BEVEL)
    assert_true(
        _ink(sharp) > _ink(beveled),
        "a raised limit lets the miter spike through",
    )


def test_default_join_is_unchanged_behaviour() raises:
    # Compatibility: omitting `join` must match passing ROUND exactly,
    # which is what every existing caller relies on.
    var pts: List[FPoint] = [
        FPoint(20.0, 40.0),
        FPoint(60.0, 40.0),
        FPoint(60.0, 80.0),
    ]
    var omitted = Canvas(100, 100, BG)
    draw_polyline_aa(omitted, pts, FG, 12.0)
    var explicit = _corner(LineJoin.ROUND)
    for y in range(100):
        for x in range(100):
            assert_equal(omitted.get_pixel(x, y).r, explicit.get_pixel(x, y).r)


def test_join_does_not_disturb_the_stroke_ends() raises:
    # A join is a corner, not an end: the two extremities must render
    # identically whatever the join style.
    var round_c = _corner(LineJoin.ROUND)
    var miter = _corner(LineJoin.MITER)
    for y in range(30, 51):
        for x in range(10, 25):
            assert_equal(
                round_c.get_pixel(x, y).r,
                miter.get_pixel(x, y).r,
                "the start cap is unaffected by the join style",
            )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
