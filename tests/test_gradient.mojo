"""Tests for gradient.mojo: LinearGradient.color_at,
RadialGradient.color_at and ConicGradient.color_at, with every expected
value hand-computed, plus the path fills in canvas.path that take a
gradient as their fill source.
"""

from std.math import pi
from std.testing import assert_equal, assert_raises, assert_true, TestSuite

from canvas.buffer import Canvas
from canvas.color import Color
from canvas.fill_rule import FillRule
from canvas.gradient import (
    ConicGradient,
    GradientStop,
    GradientStops,
    LinearGradient,
    RadialGradient,
)
from canvas.path import (
    Path,
    fill_path_conic_gradient,
    fill_path_conic_gradient_aa,
    fill_path_gradient,
    fill_path_gradient_aa,
    fill_path_radial_gradient,
    fill_path_radial_gradient_aa,
)


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


def test_radial_focal_at_the_center_matches_the_single_circle_form() raises:
    # fx = cx, fy = cy, fr = 0 is the plain constructor's geometry, so
    # the two must agree everywhere.
    var plain = RadialGradient(50.0, 50.0, 50.0)
    plain.add_stop(0.0, Color(0, 0, 0))
    plain.add_stop(0.4, Color(200, 40, 10))
    plain.add_stop(1.0, Color(255, 255, 255))
    var focal = RadialGradient(50.0, 50.0, 50.0, fx=50.0, fy=50.0)
    focal.add_stop(0.0, Color(0, 0, 0))
    focal.add_stop(0.4, Color(200, 40, 10))
    focal.add_stop(1.0, Color(255, 255, 255))
    for i in range(0, 120, 7):
        for j in range(0, 120, 11):
            var a = plain.color_at(Float64(i), Float64(j))
            var b = focal.color_at(Float64(i), Float64(j))
            assert_equal(a.r, b.r, "r at " + String(i) + "," + String(j))
            assert_equal(a.g, b.g, "g at " + String(i) + "," + String(j))
            assert_equal(a.b, b.b, "b at " + String(i) + "," + String(j))


def test_radial_focal_point_is_offset_zero_and_the_rim_is_one() raises:
    # Outer circle (50,50) r=50, focal point at (20,50).
    var g = RadialGradient(50.0, 50.0, 50.0, fx=20.0, fy=50.0)
    g.add_stop(0.0, Color(255, 0, 0))
    g.add_stop(1.0, Color(0, 0, 255))

    var f = g.color_at(20.0, 50.0)
    assert_equal(f.r, 255, "the focal point is stop 0")
    assert_equal(f.b, 0)
    # Three points on the outer circle, in different directions from
    # the focal point, all resolve to stop 1.
    for p in [(100.0, 50.0), (0.0, 50.0), (50.0, 0.0)]:
        var rim = g.color_at(p[0], p[1])
        assert_equal(rim.r, 0, "rim at " + String(p[0]) + "," + String(p[1]))
        assert_equal(rim.b, 255)


def test_radial_focal_compresses_the_near_side() raises:
    # Same gradient. cd = (30, 0), dr = 50, so a = 900 - 2500 = -1600.
    # Ten pixels toward the near rim, p = (10, 50): pd = (-10, 0),
    # b = -300, k = 100, disc = 90000 + 160000 = 250000, root = 500,
    # t = (-300 - 500) / -1600 = 0.5. Check: c(0.5) = (35, 50),
    # r(0.5) = 25, and (10, 50) is 25 from (35, 50).
    # Ten pixels the other way, p = (30, 50): pd = (10, 0), b = 300,
    # t = (300 - 500) / -1600 = 0.125.
    var g = RadialGradient(50.0, 50.0, 50.0, fx=20.0, fy=50.0)
    g.add_stop(0.0, Color(0, 0, 0))
    g.add_stop(1.0, Color(255, 255, 255))
    # 0.5 -> 128 (the rounding test_radial_color_at_half_radius shows),
    # 0.125 -> 0.125 * 255 = 31.875 -> 32.
    var near = g.color_at(10.0, 50.0)
    var far = g.color_at(30.0, 50.0)
    assert_equal(near.r, 128, "near side at t=0.5")
    assert_equal(far.r, 32, "far side at t=0.125")
    # Forty pixels toward the far rim, p = (60, 50): pd = (40, 0),
    # b = 1200, k = 1600, disc = 1440000 + 2560000 = 4000000,
    # root = 2000, t = (1200 - 2000) / -1600 = 0.5 -- the same circle
    # as (10, 50), which is 25 on the other side of (35, 50).
    var far_half = g.color_at(60.0, 50.0)
    assert_equal(far_half.r, 128, "the t=0.5 circle reaches (60, 50)")


def test_radial_focal_circle_pads_its_interior_to_offset_zero() raises:
    # Concentric, fr = 25, r = 50: t = (dist - 25) / 25, and any point
    # inside the focal circle has both roots negative. At dist = 10:
    # a = -625, b = 625, k = 100 - 625 = -525, disc = 390625 - 328125
    # = 62500, root = 250, roots (625 +- 250) / -625 = -0.6 and -1.4,
    # padded to 0. At dist = 37.5 the larger root is 0.5.
    var g = RadialGradient(50.0, 50.0, 50.0, fx=50.0, fy=50.0, fr=25.0)
    g.add_stop(0.0, Color(0, 0, 0))
    g.add_stop(1.0, Color(255, 255, 255))
    assert_equal(g.color_at(60.0, 50.0).r, 0, "inside the focal circle")
    assert_equal(g.color_at(50.0, 75.0).r, 0, "on the focal circle")
    assert_equal(g.color_at(87.5, 50.0).r, 128, "halfway to the rim")
    assert_equal(g.color_at(50.0, 100.0).r, 255, "on the rim")
    assert_equal(g.color_at(50.0, 400.0).r, 255, "well past it pads to 1")


def test_radial_focal_circle_outside_the_outer_circle_raises() raises:
    # (90, 50) is 40 from the center; a focal radius of 20 reaches to
    # 60, past the outer 50.
    with assert_raises(contains="reaches outside"):
        _ = RadialGradient(50.0, 50.0, 50.0, fx=90.0, fy=50.0, fr=20.0)
    with assert_raises(contains="reaches outside"):
        _ = RadialGradient(50.0, 50.0, 50.0, fx=120.0, fy=50.0)
    with assert_raises(contains="fr must be"):
        _ = RadialGradient(50.0, 50.0, 50.0, fx=50.0, fy=50.0, fr=-1.0)
    # Touching from inside is allowed.
    _ = RadialGradient(50.0, 50.0, 50.0, fx=80.0, fy=50.0, fr=20.0)


def test_radial_focal_touching_the_rim_is_the_linear_case() raises:
    # Focal point on the rim itself: cd = (50, 0), dr = 50, a = 0, so
    # t = k / (2b) with b = pd.cd = 50*pdx and k = pd.pd. Along the
    # diameter, p = (0 + d, 50): t = d^2 / (100 d) = d / 100, so the
    # center (d = 50) is t = 0.5 and the far rim (d = 100) is t = 1.
    var g = RadialGradient(50.0, 50.0, 50.0, fx=0.0, fy=50.0)
    g.add_stop(0.0, Color(0, 0, 0))
    g.add_stop(1.0, Color(255, 255, 255))
    assert_equal(g.color_at(0.0, 50.0).r, 0)
    assert_equal(g.color_at(50.0, 50.0).r, 128)
    assert_equal(g.color_at(100.0, 50.0).r, 255)


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


def _color_wheel(
    cx: Float64, cy: Float64, start_angle: Float64
) -> ConicGradient:
    var g = ConicGradient(cx, cy, start_angle)
    g.add_stop(0.0, Color(255, 0, 0))
    g.add_stop(0.25, Color(0, 255, 0))
    g.add_stop(0.5, Color(0, 0, 255))
    g.add_stop(0.75, Color(255, 255, 0))
    return g^


def test_conic_color_at_the_four_cardinal_directions() raises:
    # start_angle=0.0: offset 0.0 sits along +x, and the sweep
    # increases clockwise -- which in this package's y-down pixel
    # coordinates means toward +y (down), not toward -y as it would in
    # a y-up math frame. So going clockwise from +x: down is a quarter
    # turn (t=0.25), -x is a half turn (t=0.5), up is three quarters
    # (t=0.75). Each point lands exactly on a stop's offset, so the
    # returned color is that stop's exact color, no interpolation.
    var g = _color_wheel(0.0, 0.0, 0.0)

    var east = g.color_at(10.0, 0.0)  # t=0.0
    assert_equal(east.r, 255)
    assert_equal(east.g, 0)
    assert_equal(east.b, 0)

    var south = g.color_at(0.0, 10.0)  # t=0.25 (down, clockwise from +x)
    assert_equal(south.r, 0)
    assert_equal(south.g, 255)
    assert_equal(south.b, 0)

    var west = g.color_at(-10.0, 0.0)  # t=0.5
    assert_equal(west.r, 0)
    assert_equal(west.g, 0)
    assert_equal(west.b, 255)

    var north = g.color_at(0.0, -10.0)  # t=0.75
    assert_equal(north.r, 255)
    assert_equal(north.g, 255)
    assert_equal(north.b, 0)


def test_conic_color_at_the_center_is_the_first_stop_regardless_of_start_angle() raises:
    # (cx, cy) has no angle to measure -- color_at() fixes it at t=0.0
    # rather than letting atan2(0, 0) == 0 tie the center's color to
    # start_angle, so it must read back the first stop even when
    # start_angle is nonzero (which would otherwise put t=0.0
    # somewhere other than the center's raw angle).
    var g = _color_wheel(5.0, 5.0, pi)
    var center = g.color_at(5.0, 5.0)
    assert_equal(center.r, 255)
    assert_equal(center.g, 0)
    assert_equal(center.b, 0)


def test_conic_color_at_a_nonzero_start_angle_rotates_the_wheel() raises:
    # Same wheel as the cardinal-directions test, rotated a quarter
    # turn: start_angle=pi/2 puts offset 0.0 where +y (down) used to
    # be, so every direction reads back the stop a quarter turn
    # earlier in the unrotated wheel. +x, which was t=0.0 before,
    # is now three quarters of a turn *after* the new start_angle:
    # turns = (0 - pi/2) / (2*pi) = -0.25, and color_at() wraps a
    # negative fraction forward by a full turn rather than clamping
    # it, landing on t = -0.25 - floor(-0.25) = 0.75.
    var g = _color_wheel(0.0, 0.0, pi / 2.0)

    var east = g.color_at(10.0, 0.0)  # t=0.75
    assert_equal(east.r, 255)
    assert_equal(east.g, 255)
    assert_equal(east.b, 0)

    var south = g.color_at(0.0, 10.0)  # t=0.0, the new start_angle
    assert_equal(south.r, 255)
    assert_equal(south.g, 0)
    assert_equal(south.b, 0)

    var west = g.color_at(-10.0, 0.0)  # t=0.25
    assert_equal(west.r, 0)
    assert_equal(west.g, 255)
    assert_equal(west.b, 0)

    var north = g.color_at(0.0, -10.0)  # t=0.5
    assert_equal(north.r, 0)
    assert_equal(north.g, 0)
    assert_equal(north.b, 255)


def test_conic_color_at_wraps_across_the_start_angle_rather_than_clamping() raises:
    # A point a hair clockwise of start_angle (t just above 0.0) and a
    # point a hair counterclockwise of it (t just below a full turn)
    # sit on opposite sides of the same ray, one full turn apart --
    # unlike LinearGradient/RadialGradient's "pad" extend, there is no
    # discontinuity here, and both must land near the same stop. Offset
    # 0.98 turns of a full circle is 0.98 * 360 = 352.8 degrees;
    # (1 - 0.98) turns short of start_angle on the other side is
    # equivalent to -0.02 turns, which color_at() must wrap to 0.98,
    # not read as a small negative-and-clamped value.
    var g = ConicGradient(0.0, 0.0, 0.0)
    g.add_stop(0.0, Color(0, 0, 0))
    g.add_stop(1.0, Color(255, 255, 255))

    # angle = -0.02 turns * 2*pi, taken directly rather than via
    # atan2/cos/sin so the test doesn't call the same trig the
    # implementation does: dx = cos(-0.02*2*pi), dy = sin(-0.02*2*pi)
    # would be circular. Instead this constructs the angle from a
    # right triangle: a small negative angle close to 0 rad has
    # (dx, dy) close to (1, -epsilon), i.e. just above the +x axis in
    # this package's y-down frame (negative dy is "up", clockwise-
    # before the start_angle ray at +x).
    var almost_wrapped = g.color_at(1.0, -0.001)
    # Very close to a full turn (t near 1.0), so very close to the
    # last stop's color -- far lighter than the halfway gray a clamp
    # would produce.
    assert_true(
        almost_wrapped.r > 250,
        "a point just before start_angle must wrap near t=1.0, got r="
        + String(almost_wrapped.r),
    )

    var just_after = g.color_at(1.0, 0.001)
    # Just past start_angle in the clockwise direction, t is near 0.0.
    assert_true(
        just_after.r < 5,
        "a point just after start_angle must read near t=0.0, got r="
        + String(just_after.r),
    )


def test_conic_gradient_aa_fill_interior_matches_the_gradient() raises:
    var c = Canvas(80, 80, Color(255, 255, 255))
    var g = _color_wheel(40.0, 40.0, 0.0)
    var p = _diamond(40.0, 40.0, 30.0)
    fill_path_conic_gradient_aa(c, p, g)

    # A point southwest of center, well inside the diamond: dx=-8,
    # dy=8 is exactly 135 degrees clockwise of +x in this y-down frame
    # (atan2(8, -8) = 3*pi/4), i.e. t = (3*pi/4) / (2*pi) = 0.375 --
    # halfway between the green stop (0.25) and the blue stop (0.5):
    # local_t = (0.375-0.25)/(0.5-0.25) = 0.5, so red stays 0, blue
    # rises from 0 to 0.5*255 = 127.5 -> 128, and green falls from 255
    # by the same half-step to 128.
    var expected = g.color_at(32.0, 48.0)
    var got = c.get_pixel(32, 48)
    assert_equal(got.r, expected.r)
    assert_equal(got.g, expected.g)
    assert_equal(got.b, expected.b)
    assert_equal(expected.r, 0)
    assert_equal(expected.g, 128)
    assert_equal(expected.b, 128)


def test_conic_gradient_hard_and_aa_fills_agree_in_the_interior() raises:
    var hard = Canvas(80, 80, Color(255, 255, 255))
    var soft = Canvas(80, 80, Color(255, 255, 255))
    var p = _diamond(40.0, 40.0, 28.0)

    var g1 = _color_wheel(40.0, 40.0, 0.0)
    var g2 = _color_wheel(40.0, 40.0, 0.0)
    fill_path_conic_gradient(hard, p, g1)
    fill_path_conic_gradient_aa(soft, p, g2)

    var a = hard.get_pixel(40, 20)
    var b = soft.get_pixel(40, 20)
    assert_equal(a.r, b.r)
    assert_equal(a.g, b.g)
    assert_equal(a.b, b.b)


def _black_to_white(x0: Float64, x1: Float64) -> LinearGradient:
    var g = LinearGradient(x0, 0.0, x1, 0.0)
    g.add_stop(0.0, Color(0, 0, 0, 255))
    g.add_stop(1.0, Color(255, 255, 255, 255))
    return g^


def _diamond(cx: Float64, cy: Float64, r: Float64) raises -> Path:
    """A diamond, so every edge is diagonal -- the case where a
    hard-edged fill visibly stairsteps and an AA fill must not.
    """
    var p = Path()
    p.move_to(cx, cy - r)
    p.line_to(cx + r, cy)
    p.line_to(cx, cy + r)
    p.line_to(cx - r, cy)
    p.close()
    return p^


def test_gradient_aa_fill_interior_matches_the_gradient_exactly() raises:
    # A pixel well inside the shape is fully covered, so coverage
    # scaling is a no-op there and the pixel must be exactly what
    # color_at says -- the AA fill may soften edges, never the middle.
    var c = Canvas(80, 80, Color(255, 255, 255))
    var g = _black_to_white(0.0, 80.0)
    var p = _diamond(40.0, 40.0, 30.0)
    fill_path_gradient_aa(c, p, g)

    var expected = g.color_at(40.0, 40.0)
    var got = c.get_pixel(40, 40)
    assert_equal(got.r, expected.r)
    assert_equal(got.g, expected.g)
    assert_equal(got.b, expected.b)


def test_gradient_aa_fill_antialiases_a_diagonal_edge() raises:
    # The point of the whole function. Down the diamond's upper-left
    # diagonal the hard-edged fill can only write "gradient color" or
    # "background"; the AA fill must produce at least one pixel that is
    # neither, i.e. a real partial blend.
    var hard = Canvas(80, 80, Color(255, 255, 255))
    var soft = Canvas(80, 80, Color(255, 255, 255))
    var p = _diamond(40.0, 40.0, 30.0)

    # A flat "gradient" (both stops the same color) so any pixel that
    # is neither that color nor the background is edge coverage
    # rather than gradient interpolation.
    var g_hard = LinearGradient(0.0, 0.0, 80.0, 0.0)
    g_hard.add_stop(0.0, Color(0, 0, 0, 255))
    g_hard.add_stop(1.0, Color(0, 0, 0, 255))
    var g_soft = LinearGradient(0.0, 0.0, 80.0, 0.0)
    g_soft.add_stop(0.0, Color(0, 0, 0, 255))
    g_soft.add_stop(1.0, Color(0, 0, 0, 255))

    fill_path_gradient(hard, p, g_hard)
    fill_path_gradient_aa(soft, p, g_soft)

    var hard_partials = 0
    var soft_partials = 0
    for y in range(80):
        for x in range(80):
            var h = hard.get_pixel(x, y).r
            var s = soft.get_pixel(x, y).r
            if h != 0 and h != 255:
                hard_partials += 1
            if s != 0 and s != 255:
                soft_partials += 1
    assert_equal(hard_partials, 0)
    assert_true(
        soft_partials > 40,
        String(
            "the AA gradient fill must blend along the diamond's four"
            " diagonal edges, got "
        )
        + String(soft_partials)
        + " partially covered pixels",
    )


def test_gradient_aa_fill_edge_matches_flat_aa_fill_coverage() raises:
    # The gradient fill's coverage must come from the same sweep a flat
    # fill uses, so with a gradient whose stops are all one color the
    # two must agree pixel for pixel -- including every partially
    # covered edge pixel.
    from canvas.path import fill_path_aa

    var flat = Canvas(80, 80, Color(255, 255, 255))
    var grad = Canvas(80, 80, Color(255, 255, 255))
    var p = _diamond(40.0, 40.0, 30.0)

    var g = LinearGradient(0.0, 0.0, 80.0, 0.0)
    g.add_stop(0.0, Color(20, 40, 60, 255))
    g.add_stop(1.0, Color(20, 40, 60, 255))

    fill_path_aa(flat, p, Color(20, 40, 60, 255))
    fill_path_gradient_aa(grad, p, g)

    for y in range(80):
        for x in range(80):
            var a = flat.get_pixel(x, y)
            var b = grad.get_pixel(x, y)
            assert_equal(a.r, b.r)
            assert_equal(a.g, b.g)
            assert_equal(a.b, b.b)


def test_gradient_aa_fill_scales_a_translucent_stop_by_coverage() raises:
    # Coverage scales the source color's own alpha rather than
    # replacing it: a half-transparent gradient over white must land
    # near white-plus-half-black in the interior, never fully opaque.
    var c = Canvas(80, 80, Color(255, 255, 255))
    var g = LinearGradient(0.0, 0.0, 80.0, 0.0)
    g.add_stop(0.0, Color(0, 0, 0, 128))
    g.add_stop(1.0, Color(0, 0, 0, 128))
    var p = _diamond(40.0, 40.0, 30.0)
    fill_path_gradient_aa(c, p, g)

    # 255 * (1 - 128/255) == 127, the straight src-over result.
    var mid = c.get_pixel(40, 40)
    assert_equal(mid.r, 127)


def test_radial_gradient_aa_fill_interior_matches_the_gradient() raises:
    var c = Canvas(80, 80, Color(255, 255, 255))
    var g = RadialGradient(40.0, 40.0, 30.0)
    g.add_stop(0.0, Color(200, 30, 30, 255))
    g.add_stop(1.0, Color(30, 30, 200, 255))
    var p = _diamond(40.0, 40.0, 25.0)
    fill_path_radial_gradient_aa(c, p, g)

    var expected = g.color_at(40.0, 40.0)
    var got = c.get_pixel(40, 40)
    assert_equal(got.r, expected.r)
    assert_equal(got.g, expected.g)
    assert_equal(got.b, expected.b)


def test_radial_gradient_hard_and_aa_fills_agree_in_the_interior() raises:
    # The two routes differ only at the boundary; a deep interior pixel
    # must be identical, which is what pins the AA variant to the same
    # color source rather than merely a similar one.
    var hard = Canvas(80, 80, Color(255, 255, 255))
    var soft = Canvas(80, 80, Color(255, 255, 255))
    var p = _diamond(40.0, 40.0, 28.0)

    var g1 = RadialGradient(40.0, 40.0, 30.0)
    g1.add_stop(0.0, Color(200, 30, 30, 255))
    g1.add_stop(1.0, Color(30, 30, 200, 255))
    var g2 = RadialGradient(40.0, 40.0, 30.0)
    g2.add_stop(0.0, Color(200, 30, 30, 255))
    g2.add_stop(1.0, Color(30, 30, 200, 255))

    fill_path_radial_gradient(hard, p, g1)
    fill_path_radial_gradient_aa(soft, p, g2)

    var a = hard.get_pixel(40, 40)
    var b = soft.get_pixel(40, 40)
    assert_equal(a.r, b.r)
    assert_equal(a.g, b.g)
    assert_equal(a.b, b.b)


def test_gradient_aa_fill_respects_the_nonzero_fill_rule() raises:
    # Two concentric diamonds wound the same way: EVEN_ODD punches the
    # inner one out, NONZERO fills straight through it. Same geometry,
    # same source, so any difference at the center is the fill rule.
    var eo = Canvas(80, 80, Color(255, 255, 255))
    var nz = Canvas(80, 80, Color(255, 255, 255))

    var p = Path()
    p.move_to(40.0, 10.0)
    p.line_to(70.0, 40.0)
    p.line_to(40.0, 70.0)
    p.line_to(10.0, 40.0)
    p.close()
    p.move_to(40.0, 25.0)
    p.line_to(55.0, 40.0)
    p.line_to(40.0, 55.0)
    p.line_to(25.0, 40.0)
    p.close()

    var g1 = _black_to_white(0.0, 80.0)
    var g2 = _black_to_white(0.0, 80.0)
    fill_path_gradient_aa(eo, p, g1, fill_rule=FillRule.EVEN_ODD)
    fill_path_gradient_aa(nz, p, g2, fill_rule=FillRule.NONZERO)

    # Center: left untouched by EVEN_ODD (still background), filled by
    # NONZERO.
    assert_equal(eo.get_pixel(40, 40).r, 255)
    assert_equal(eo.get_pixel(40, 40).g, 255)
    var center = nz.get_pixel(40, 40)
    assert_true(
        center.r != 255 or center.g != 255 or center.b != 255,
        "NONZERO must fill through the inner sub-path",
    )


def test_gradient_aa_fill_of_an_empty_path_draws_nothing() raises:
    var c = Canvas(20, 20, Color(255, 255, 255))
    var g = _black_to_white(0.0, 20.0)
    var p = Path()
    fill_path_gradient_aa(c, p, g)
    for y in range(20):
        for x in range(20):
            assert_equal(c.get_pixel(x, y).r, 255)


def test_gradient_aa_fill_clips_to_the_canvas() raises:
    # A path mostly off-canvas must still fill the part that is on it,
    # and must not read or write outside the mask.
    var c = Canvas(30, 30, Color(255, 255, 255))
    var g = _black_to_white(-40.0, 40.0)
    var p = _diamond(-5.0, 15.0, 20.0)
    fill_path_gradient_aa(c, p, g)
    assert_true(
        c.get_pixel(2, 15).r != 255,
        "the on-canvas part of an overhanging path must still be filled",
    )


def test_gradient_stops_stand_alone_as_a_ramp() raises:
    # No geometry: a value already in [0, 1] maps straight to a color,
    # with the same pad clamp and midpoint rounding the gradients use.
    var ramp = GradientStops()
    assert_equal(len(ramp), 0)
    assert_equal(ramp.color_at(0.5).a, 0, "no stops is transparent")
    ramp.add_stop(1.0, Color(255, 255, 255))
    ramp.add_stop(0.0, Color(0, 0, 0))
    assert_equal(len(ramp), 2)
    assert_equal(ramp[0].offset, 0.0, "sorted on insert")
    assert_equal(ramp[1].offset, 1.0)
    var seen = 0
    var last = -1.0
    for stop in ramp:
        assert_true(stop.offset > last, "iterates in offset order")
        last = stop.offset
        seen += 1
    assert_equal(seen, 2, "iterates every stop")
    # 0.5 * 255 = 127.5 -> 128.
    assert_equal(ramp.color_at(0.5).r, 128)
    assert_equal(ramp.color_at(-3.0).r, 0, "pads below")
    assert_equal(ramp.color_at(7.0).r, 255, "pads above")
    var stop = GradientStop(0.25, Color(1, 2, 3))
    assert_equal(stop.offset, 0.25)
    assert_equal(stop.color.b, 3)


def test_a_gradient_exposes_its_ramp() raises:
    # The gradient's `stops` is a GradientStops, so a caller can read
    # the ramp back and query it without the geometry.
    var g = LinearGradient(0.0, 0.0, 10.0, 0.0)
    g.add_stop(0.0, Color(0, 0, 0))
    g.add_stop(1.0, Color(255, 255, 255))
    assert_equal(g.stops.color_at(0.5).r, g.color_at(5.0, 0.0).r)


def test_stops_are_sorted_on_insert_whatever_order_they_arrive_in() raises:
    # Same three stops, added ascending and descending. add_stop keeps
    # the list sorted either way, so color_at answers identically and
    # `stops` itself comes out in ascending offset order.
    var ascending = LinearGradient(0.0, 0.0, 100.0, 0.0)
    ascending.add_stop(0.0, Color(0, 0, 0))
    ascending.add_stop(0.5, Color(100, 100, 100))
    ascending.add_stop(1.0, Color(200, 200, 200))

    var descending = LinearGradient(0.0, 0.0, 100.0, 0.0)
    descending.add_stop(1.0, Color(200, 200, 200))
    descending.add_stop(0.5, Color(100, 100, 100))
    descending.add_stop(0.0, Color(0, 0, 0))

    assert_equal(len(descending.stops), 3)
    assert_equal(descending.stops[0].offset, 0.0)
    assert_equal(descending.stops[1].offset, 0.5)
    assert_equal(descending.stops[2].offset, 1.0)

    for x in range(0, 101, 10):
        assert_equal(
            ascending.color_at(Float64(x), 0.0).r,
            descending.color_at(Float64(x), 0.0).r,
            "insertion order does not change the ramp at x=" + String(x),
        )
    # And the midpoint of the first half is the hand-computed average
    # of its two stops: 0 + 0.5*(100 - 0) = 50 at t = 0.25.
    assert_equal(ascending.color_at(25.0, 0.0).r, 50)


def test_two_stops_at_one_offset_are_a_hard_transition() raises:
    # A hard edge: black up to the midpoint, white after it. The first
    # stop at 0.5 ends the run below it and the second begins the run
    # above, the same rule svg.mojo's <stop> ordering follows.
    var g = LinearGradient(0.0, 0.0, 100.0, 0.0)
    g.add_stop(0.0, Color(0, 0, 0))
    g.add_stop(0.5, Color(0, 0, 0))
    g.add_stop(0.5, Color(255, 255, 255))
    g.add_stop(1.0, Color(255, 255, 255))

    # Below the transition the ramp runs black-to-black, so every
    # sample is black rather than part-way to white.
    assert_equal(g.color_at(10.0, 0.0).r, 0)
    assert_equal(g.color_at(49.0, 0.0).r, 0)
    # Above it, white-to-white.
    assert_equal(g.color_at(51.0, 0.0).r, 255)
    assert_equal(g.color_at(90.0, 0.0).r, 255)
    # Exactly on the offset the later stop wins, so the edge belongs to
    # the upper run.
    assert_equal(g.color_at(50.0, 0.0).r, 255)


def test_binary_search_brackets_correctly_across_many_stops() raises:
    # Eleven evenly spaced stops whose red channel is 10 * the stop
    # index, added in a shuffled order. Every stop offset must read
    # back its own color, and each midpoint the average of its
    # neighbors -- which pins the bracketing pair at every position
    # in the list, not just the ends.
    var g = LinearGradient(0.0, 0.0, 100.0, 0.0)
    var order: List[Int] = [5, 0, 9, 3, 10, 1, 7, 2, 8, 4, 6]
    for i in order:
        g.add_stop(Float64(i) / 10.0, Color(UInt8(i * 10), 0, 0))

    for i in range(11):
        assert_equal(
            g.color_at(Float64(i) * 10.0, 0.0).r,
            UInt8(i * 10),
            "stop " + String(i) + " reads back its own color",
        )
    for i in range(10):
        # Midway between stop i and i+1: 10*i + 0.5*10 = 10*i + 5.
        assert_equal(
            g.color_at(Float64(i) * 10.0 + 5.0, 0.0).r,
            UInt8(i * 10 + 5),
            "midpoint after stop " + String(i),
        )


def test_radial_stops_are_sorted_on_insert_too() raises:
    var g = RadialGradient(0.0, 0.0, 100.0)
    g.add_stop(1.0, Color(200, 0, 0))
    g.add_stop(0.0, Color(0, 0, 0))
    assert_equal(g.stops[0].offset, 0.0)
    assert_equal(g.stops[1].offset, 1.0)
    # Half the radius along +x is t = 0.5: 0 + 0.5*(200 - 0) = 100.
    assert_equal(g.color_at(50.0, 0.0).r, 100)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
