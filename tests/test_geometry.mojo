"""Tests for geometry.mojo: Point, Transform2D and the pixel snaps."""

from std.math import pi
from std.testing import (
    assert_almost_equal,
    assert_equal,
    assert_raises,
    assert_true,
    TestSuite,
)

from canvas.buffer import Canvas
from canvas.color import Color
from canvas.geometry import (
    Point,
    Transform2D,
    round_to_int,
    snap_to_pixel_center,
    snap_to_pixel_edge,
)


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


def test_snap_to_pixel_edge_finds_the_nearest_boundary() raises:
    assert_equal(snap_to_pixel_edge(2.0), 2.5)
    assert_equal(snap_to_pixel_edge(2.4), 2.5)
    assert_equal(snap_to_pixel_edge(2.6), 2.5)
    assert_equal(snap_to_pixel_edge(2.9), 2.5)
    assert_equal(snap_to_pixel_edge(3.0), 3.5)
    assert_equal(snap_to_pixel_edge(-0.4), -0.5)
    assert_equal(snap_to_pixel_edge(-0.6), -0.5)
    # A boundary stays put.
    assert_equal(snap_to_pixel_edge(2.5), 2.5)


def test_snap_to_pixel_edge_tie_goes_up_and_absorbs_an_ulp() raises:
    # Exactly on a pixel center: the boundary above.
    assert_equal(snap_to_pixel_edge(2.0), 2.5)
    # One ULP under the center, the shape a scale's multiply-add
    # produces, snaps where the center does rather than a pixel lower.
    assert_equal(snap_to_pixel_edge(2.0 - 1e-12), 2.5)
    assert_equal(snap_to_pixel_edge(2.5 - 1e-12), 2.5)
    # A real fraction is far outside the tolerance.
    assert_equal(snap_to_pixel_edge(2.0 - 1e-6), 1.5)


def test_snap_to_pixel_center_rounds_like_round_to_int() raises:
    assert_equal(snap_to_pixel_center(2.4), 2.0)
    assert_equal(snap_to_pixel_center(2.5), 3.0)
    assert_equal(snap_to_pixel_center(2.6), 3.0)
    assert_equal(snap_to_pixel_center(-2.5), -3.0)
    assert_equal(snap_to_pixel_center(-2.4), -2.0)
    for i in range(-20, 21):
        var v = Float64(i) * 0.37
        assert_equal(snap_to_pixel_center(v), Float64(round_to_int(v)))


def _assert_pixel(c: Canvas, x: Int, y: Int, color: Color) raises:
    var p = c.get_pixel(x, y)
    assert_true(
        p.r == color.r and p.g == color.g and p.b == color.b,
        "pixel (" + String(x) + ", " + String(y) + ") is not the color",
    )


def test_a_snapped_edge_stays_hard_under_supersampling() raises:
    """The property the edge snap exists for: a rectangle whose edges
    are snapped in user space downsamples to fully covered columns on
    one side of each edge and empty ones on the other, where the same
    rectangle unsnapped leaves a partially covered column."""
    var bg = Color(255, 255, 255)
    var fg = Color(0, 0, 0)
    # Edges at 10.1 and 30.9 snap to 10.5 and 30.5: pixels 11..30 in.
    var x0 = snap_to_pixel_edge(10.1)
    var x1 = snap_to_pixel_edge(30.9)
    var y0 = snap_to_pixel_edge(5.2)
    var y1 = snap_to_pixel_edge(15.8)
    assert_equal(x0, 10.5)
    assert_equal(x1, 30.5)

    var snapped = Canvas(40, 20, bg)
    snapped.begin_supersampled(2, bg)
    snapped.fill_rect(x0, y0, x1 - x0, y1 - y0, fg)
    snapped.end_supersampled()
    for y in range(6, 16):
        _assert_pixel(snapped, 10, y, bg)
        _assert_pixel(snapped, 11, y, fg)
        _assert_pixel(snapped, 30, y, fg)
        _assert_pixel(snapped, 31, y, bg)
    for x in range(11, 31):
        _assert_pixel(snapped, x, 5, bg)
        _assert_pixel(snapped, x, 6, fg)
        _assert_pixel(snapped, x, 15, fg)
        _assert_pixel(snapped, x, 16, bg)

    # The same rectangle unsnapped: at a factor of 2 an edge whose
    # fraction is within a quarter pixel of a pixel center snaps, in
    # device space, to the middle of a block, so the downsampled
    # column is a mix of the two colors rather than either. That is
    # the soft edge the user-space snap removes.
    var unsnapped = Canvas(40, 20, bg)
    unsnapped.begin_supersampled(2, bg)
    unsnapped.fill_rect(10.1, y0, 30.9 - 10.1, y1 - y0, fg)
    unsnapped.end_supersampled()
    var left = unsnapped.get_pixel(10, 10)
    assert_true(left.r != bg.r and left.r != fg.r)
    var right = unsnapped.get_pixel(31, 10)
    assert_true(right.r != bg.r and right.r != fg.r)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
