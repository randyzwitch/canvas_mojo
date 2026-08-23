"""Tests for canvas_mojo/shapes/dash.mojo."""

from std.testing import assert_true, TestSuite

from canvas_mojo.shapes.dash import _is_dash_on


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
