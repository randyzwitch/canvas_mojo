"""Tests for geometry.mojo: Point and Transform2D."""

from std.math import pi
from std.testing import assert_equal, TestSuite

from canvas_mojo.geometry import Point, Transform2D


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
