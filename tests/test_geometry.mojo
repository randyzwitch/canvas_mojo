"""Tests for geometry.mojo: Point and Transform2D."""

from std.math import pi
from std.testing import (
    assert_almost_equal,
    assert_equal,
    assert_raises,
    TestSuite,
)

from canvas.geometry import Point, Transform2D, round_to_int


def test_round_to_int_rounds_half_away_from_zero() raises:
    assert_equal(round_to_int(2.4), 2)
    assert_equal(round_to_int(2.5), 3)
    assert_equal(round_to_int(-2.4), -2)
    assert_equal(round_to_int(-2.5), -3)
    assert_equal(round_to_int(0.0), 0)
    assert_equal(round_to_int(-0.49), 0)
    # Not the stdlib's half-to-even: 2.5 and 3.5 round one apart, not
    # two.
    assert_equal(round_to_int(3.5) - round_to_int(2.5), 1)


def test_transform2d_identity_rounds_fractional_input() raises:
    var t = Transform2D(1.0, 1.0, 0.0, 0.0)
    var p = t.to_pixel(5.0, 4.0)
    assert_equal(p.x, 5)
    assert_equal(p.y, 4)

    var rounded = t.to_pixel(5.6, 4.4)
    assert_equal(rounded.x, 6)
    assert_equal(rounded.y, 4)


def test_transform2d_scale_only() raises:
    var t = Transform2D(2.0, 3.0, 0.0, 0.0)
    var p = t.to_pixel(5.0, 4.0)
    assert_equal(p.x, 10)
    assert_equal(p.y, 12)


def test_transform2d_translate_only() raises:
    var t = Transform2D(1.0, 1.0, 10.0, -5.0)
    var p = t.to_pixel(3.0, 3.0)
    assert_equal(p.x, 13)
    assert_equal(p.y, -2)


def test_transform2d_maps_a_data_range_onto_a_pixel_range() raises:
    # data x in [0, 100] -> pixel x in [50, 450]
    var scale_x = (450.0 - 50.0) / (100.0 - 0.0)
    var translate_x = 50.0 - scale_x * 0.0
    var t = Transform2D(scale_x, 1.0, translate_x, 0.0)

    assert_equal(t.to_pixel(0.0, 0.0).x, 50)
    assert_equal(t.to_pixel(100.0, 0.0).x, 450)
    assert_equal(t.to_pixel(50.0, 0.0).x, 250)  # midpoint -> midpoint


def test_transform2d_flips_the_y_axis() raises:
    # The single most common real reason this type exists: pixel-space
    # y increases downward, data-space y conventionally increases
    # upward. data y in [0, 100] -> pixel y in [300, 50] (inverted).
    var scale_y = (50.0 - 300.0) / (100.0 - 0.0)
    var translate_y = 300.0 - scale_y * 0.0
    var t = Transform2D(1.0, scale_y, 0.0, translate_y)

    assert_equal(t.to_pixel(0.0, 0.0).y, 300)  # data min -> pixel bottom
    assert_equal(t.to_pixel(0.0, 100.0).y, 50)  # data max -> pixel top
    assert_equal(t.to_pixel(0.0, 50.0).y, 175)  # midpoint -> midpoint


def test_transform2d_rounds_half_away_from_zero() raises:
    var t = Transform2D(1.0, 1.0, 0.0, 0.0)
    var p = t.to_pixel(2.5, -2.5)
    assert_equal(p.x, 3)
    assert_equal(p.y, -3)


def test_transform2d_default_rotation_matches_pre_rotation_behavior() raises:
    # The 4-positional-arg constructor every existing call site uses
    # must keep meaning exactly what it did before `rotation` existed.
    var t = Transform2D(2.0, 3.0, 10.0, -5.0)
    var p = t.to_pixel(5.0, 4.0)
    assert_equal(p.x, 20)  # 5*2 + 10
    assert_equal(p.y, 7)  # 4*3 + -5


def test_transform2d_90_degree_rotation_matches_hand_derived_values() raises:
    # A quarter turn has exact (not floating-point-approximate) sin/cos
    # values -- cos(90deg)=0, sin(90deg)=1 -- so the rotated result is
    # hand-verifiable exactly: rotating (x, y) by 90 degrees maps it to
    # (-y, x). No translate/scale here, isolating just the rotation.
    var t = Transform2D(1.0, 1.0, 0.0, 0.0, rotation=pi / 2.0)

    var p1 = t.to_pixel(5.0, 0.0)  # (5, 0) -> (0, 5)
    assert_equal(p1.x, 0)
    assert_equal(p1.y, 5)

    var p2 = t.to_pixel(0.0, 3.0)  # (0, 3) -> (-3, 0)
    assert_equal(p2.x, -3)
    assert_equal(p2.y, 0)


def test_transform2d_rotation_applies_after_scale_before_translate() raises:
    # Order matters: scale first (5,0) -> (10,0), THEN rotate 90deg
    # -> (0,10), THEN translate by (100,100) -> (100,110). Getting the
    # order wrong (e.g. rotating the unscaled point, or translating
    # before rotating) would produce a different, hand-distinguishable
    # result -- this specifically wouldn't pass if rotation were
    # applied to the translated point instead of the scaled one.
    var t = Transform2D(2.0, 2.0, 100.0, 100.0, rotation=pi / 2.0)
    var p = t.to_pixel(5.0, 0.0)
    assert_equal(p.x, 100)
    assert_equal(p.y, 110)


def test_inverse_point_undoes_scale_and_translate_exactly() raises:
    # No rotation, and every number here divides evenly, so the round
    # trip is exact in floating point -- no tolerance needed.
    var t = Transform2D(10.0, -10.0, 50.0, 200.0)
    var pixel = t.to_point(3.0, 4.0)
    assert_equal(pixel.x, 80.0)  # 3*10 + 50
    assert_equal(pixel.y, 160.0)  # 4*-10 + 200

    var back = t.inverse_point(pixel.x, pixel.y)
    assert_equal(back.x, 3.0)
    assert_equal(back.y, 4.0)


def test_inverse_point_round_trips_with_rotation() raises:
    # Isotropic scale plus a rotation that isn't a multiple of a
    # quarter turn, so both sin and cos are irrational -- the round
    # trip is what a property this general can be checked against,
    # not a specific hand-computed literal.
    var t = Transform2D(5.0, 5.0, 10.0, -20.0, rotation=0.7)
    var pixel = t.to_point(3.0, -4.5)
    var back = t.inverse_point(pixel.x, pixel.y)
    assert_almost_equal(back.x, 3.0, atol=1e-9)
    assert_almost_equal(back.y, -4.5, atol=1e-9)


def test_inverse_point_round_trips_anisotropic_scale_and_rotation() raises:
    # scale_x != scale_y together with a nonzero rotation is the case
    # where the true inverse is a rotate-then-scale map rather than
    # another scale-then-rotate Transform2D: a matrix that fits the
    # forward pipeline's shape for one direction need not fit it for
    # the other unless the scale is isotropic or the rotation is a
    # multiple of pi. inverse_point still has to recover the original
    # point exactly here, since it computes the inverse directly
    # rather than trying to express it as a Transform2D.
    var t = Transform2D(2.0, 1.0, 30.0, -20.0, rotation=pi / 4.0)
    var pixel = t.to_point(3.0, 4.0)
    var back = t.inverse_point(pixel.x, pixel.y)
    assert_almost_equal(back.x, 3.0, atol=1e-9)
    assert_almost_equal(back.y, 4.0, atol=1e-9)

    # And a second point, so this isn't a coincidence of one input.
    var pixel2 = t.to_point(-7.0, 12.0)
    var back2 = t.inverse_point(pixel2.x, pixel2.y)
    assert_almost_equal(back2.x, -7.0, atol=1e-9)
    assert_almost_equal(back2.y, 12.0, atol=1e-9)


def test_inverse_point_raises_on_zero_scale_x() raises:
    var t = Transform2D(0.0, 2.0, 0.0, 0.0)
    with assert_raises():
        _ = t.inverse_point(0.0, 0.0)


def test_inverse_point_raises_on_zero_scale_y() raises:
    var t = Transform2D(2.0, 0.0, 0.0, 0.0)
    with assert_raises():
        _ = t.inverse_point(0.0, 0.0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
