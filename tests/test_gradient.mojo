"""Tests for gradient.mojo: LinearGradient.color_at and
RadialGradient.color_at, with every expected value hand-computed.
"""

from std.testing import assert_equal, TestSuite

from canvas.color import Color
from canvas.gradient import LinearGradient, RadialGradient


def test_color_at_midpoint_interpolates_linearly() raises:
    # Horizontal axis (0,0)-(100,0), black at 0.0, white at 1.0.
    # (50,0) projects to t=0.5 -> r=g=b = 0 + 0.5*(255-0) = 127.5,
    # rounds to 128 (standard round-to-nearest, values here are never
    # negative so no away-from-zero subtlety applies).
    var g = LinearGradient(0.0, 0.0, 100.0, 0.0)
    g.add_stop(0.0, Color(0, 0, 0, 255))
    g.add_stop(1.0, Color(255, 255, 255, 255))

    var mid = g.color_at(50.0, 0.0)
    assert_equal(mid.r, 128)
    assert_equal(mid.g, 128)
    assert_equal(mid.b, 128)
    assert_equal(mid.a, 255)


def test_color_at_clamps_before_and_after_the_axis() raises:
    # "Pad" extend: a point projecting before offset 0.0 or after 1.0
    # takes that endpoint's exact color, not an extrapolated or wrapped
    # one.
    var g = LinearGradient(0.0, 0.0, 100.0, 0.0)
    g.add_stop(0.0, Color(0, 0, 0, 255))
    g.add_stop(1.0, Color(255, 255, 255, 255))

    var before = g.color_at(-10.0, 0.0)
    assert_equal(before.r, 0)
    assert_equal(before.g, 0)
    assert_equal(before.b, 0)

    var after = g.color_at(150.0, 0.0)
    assert_equal(after.r, 255)
    assert_equal(after.g, 255)
    assert_equal(after.b, 255)


def test_color_at_finds_the_bracketing_pair_among_three_stops() raises:
    # red(0.0) -> green(0.5) -> blue(1.0). (25,0) projects to t=0.25,
    # which brackets between the first two stops, not all three --
    # local_t = (0.25-0.0)/(0.5-0.0) = 0.5, halfway from red to green:
    # r = 255 + 0.5*(0-255) = 127.5 -> 128, g = 0 + 0.5*(255-0) = 127.5
    # -> 128, b stays 0 (blue never enters this interpolation at all).
    var g = LinearGradient(0.0, 0.0, 100.0, 0.0)
    g.add_stop(0.0, Color(255, 0, 0))
    g.add_stop(0.5, Color(0, 255, 0))
    g.add_stop(1.0, Color(0, 0, 255))

    var quarter = g.color_at(25.0, 0.0)
    assert_equal(quarter.r, 128)
    assert_equal(quarter.g, 128)
    assert_equal(quarter.b, 0)


def test_color_at_stops_need_not_be_added_in_order() raises:
    # The same 3-stop gradient added blue-green-red instead of
    # red-green-blue: color_at brackets by value, not insertion order,
    # so the result must be identical.
    var g = LinearGradient(0.0, 0.0, 100.0, 0.0)
    g.add_stop(1.0, Color(0, 0, 255))
    g.add_stop(0.5, Color(0, 255, 0))
    g.add_stop(0.0, Color(255, 0, 0))

    var quarter = g.color_at(25.0, 0.0)
    assert_equal(quarter.r, 128)
    assert_equal(quarter.g, 128)
    assert_equal(quarter.b, 0)


def test_color_at_single_stop_is_constant() raises:
    var g = LinearGradient(0.0, 0.0, 100.0, 0.0)
    g.add_stop(0.5, Color(10, 20, 30))

    var a = g.color_at(-500.0, 0.0)
    var b = g.color_at(500.0, 0.0)
    assert_equal(a.r, 10)
    assert_equal(a.g, 20)
    assert_equal(a.b, 30)
    assert_equal(b.r, 10)
    assert_equal(b.g, 20)
    assert_equal(b.b, 30)


def test_color_at_no_stops_is_fully_transparent() raises:
    var g = LinearGradient(0.0, 0.0, 100.0, 0.0)
    var c = g.color_at(0.0, 0.0)
    assert_equal(c.a, 0)


def test_color_at_projects_onto_a_diagonal_axis() raises:
    # Axis (0,0)-(10,10): a point on the axis at its midpoint (5,5)
    # lands at t=0.5, so the projection math -- not just the
    # interpolation -- handles a non-axis-aligned gradient.
    var g = LinearGradient(0.0, 0.0, 10.0, 10.0)
    g.add_stop(0.0, Color(0, 0, 0))
    g.add_stop(1.0, Color(200, 200, 200))

    var mid = g.color_at(5.0, 5.0)
    assert_equal(mid.r, 100)
    assert_equal(mid.g, 100)
    assert_equal(mid.b, 100)


def test_radial_color_at_exact_distance_via_pythagorean_triple() raises:
    # center (0,0), radius 5, point (3,4): dist = sqrt(3^2+4^2) = 5.0
    # exactly, a 3-4-5 triangle with no rounding in the distance, so t
    # lands on exactly 1.0 and the last stop's color.
    var g = RadialGradient(0.0, 0.0, 5.0)
    g.add_stop(0.0, Color(0, 0, 0, 255))
    g.add_stop(1.0, Color(255, 255, 255, 255))

    var edge = g.color_at(3.0, 4.0)
    assert_equal(edge.r, 255)
    assert_equal(edge.g, 255)
    assert_equal(edge.b, 255)


def test_radial_color_at_center_is_the_first_stop() raises:
    var g = RadialGradient(50.0, 50.0, 50.0)
    g.add_stop(0.0, Color(10, 20, 30))
    g.add_stop(1.0, Color(200, 200, 200))

    var center = g.color_at(50.0, 50.0)
    assert_equal(center.r, 10)
    assert_equal(center.g, 20)
    assert_equal(center.b, 30)


def test_radial_color_at_beyond_radius_clamps_to_the_last_stop() raises:
    # "Pad" extend, as in LinearGradient: a point outside the radius
    # takes the outermost stop's exact color.
    var g = RadialGradient(0.0, 0.0, 5.0)
    g.add_stop(0.0, Color(0, 0, 0))
    g.add_stop(1.0, Color(255, 255, 255))

    var far = g.color_at(30.0, 40.0)  # dist = 50, well past radius=5
    assert_equal(far.r, 255)
    assert_equal(far.g, 255)
    assert_equal(far.b, 255)


def test_radial_color_at_half_radius_interpolates_regardless_of_direction() raises:
    # center (50,50), radius 50: (75,50) and (50,75) are both distance
    # 25 from center in different directions, so both must land on the
    # same color -- t=0.5 -> 0 + 0.5*(255-0) = 127.5 -> 128. That's
    # what makes the projection circular rather than secretly
    # axis-aligned like LinearGradient's.
    var g = RadialGradient(50.0, 50.0, 50.0)
    g.add_stop(0.0, Color(0, 0, 0, 255))
    g.add_stop(1.0, Color(255, 255, 255, 255))

    var right = g.color_at(75.0, 50.0)
    var down = g.color_at(50.0, 75.0)
    assert_equal(right.r, 128)
    assert_equal(right.g, 128)
    assert_equal(right.b, 128)
    assert_equal(down.r, 128)
    assert_equal(down.g, 128)
    assert_equal(down.b, 128)


def test_radial_zero_radius_is_a_solid_fill_of_the_last_stop() raises:
    # radius=0.0 collapses every offset's circle to one point,
    # resolving to t=1.0 rather than dividing by zero -- the
    # highest-offset stop's color everywhere, not the first's.
    var g = RadialGradient(10.0, 10.0, 0.0)
    g.add_stop(0.0, Color(0, 0, 255))
    g.add_stop(1.0, Color(255, 0, 0))

    var at_center = g.color_at(10.0, 10.0)
    var far_away = g.color_at(1000.0, 1000.0)
    assert_equal(at_center.r, 255)
    assert_equal(at_center.b, 0)
    assert_equal(far_away.r, 255)
    assert_equal(far_away.b, 0)


def test_radial_color_at_single_stop_is_constant() raises:
    var g = RadialGradient(0.0, 0.0, 100.0)
    g.add_stop(0.5, Color(10, 20, 30))

    var center = g.color_at(0.0, 0.0)
    var edge = g.color_at(500.0, 0.0)
    assert_equal(center.r, 10)
    assert_equal(center.g, 20)
    assert_equal(center.b, 30)
    assert_equal(edge.r, 10)
    assert_equal(edge.g, 20)
    assert_equal(edge.b, 30)


def test_radial_color_at_no_stops_is_fully_transparent() raises:
    var g = RadialGradient(0.0, 0.0, 100.0)
    var c = g.color_at(0.0, 0.0)
    assert_equal(c.a, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
