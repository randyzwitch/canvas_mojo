"""Tests for gradient.mojo: LinearGradient.color_at and
RadialGradient.color_at, with every expected value hand-computed, plus
the path fills in canvas.path that take a gradient as their fill
source.
"""

from std.testing import assert_equal, assert_true, TestSuite

from canvas.buffer import Canvas
from canvas.color import Color
from canvas.fill_rule import FillRule
from canvas.gradient import LinearGradient, RadialGradient
from canvas.path import (
    Path,
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
    # diagonal the hard-edged fill can only write "gradient colour" or
    # "background"; the AA fill must produce at least one pixel that is
    # neither, i.e. a real partial blend.
    var hard = Canvas(80, 80, Color(255, 255, 255))
    var soft = Canvas(80, 80, Color(255, 255, 255))
    var p = _diamond(40.0, 40.0, 30.0)

    # A flat "gradient" (both stops the same colour) so any pixel that
    # is neither that colour nor the background is edge coverage
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
    # fill uses, so with a gradient whose stops are all one colour the
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
    # Coverage scales the source colour's own alpha rather than
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
    # colour source rather than merely a similar one.
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
    # same source, so any difference at the centre is the fill rule.
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

    # Centre: left untouched by EVEN_ODD (still background), filled by
    # NONZERO.
    assert_equal(eo.get_pixel(40, 40).r, 255)
    assert_equal(eo.get_pixel(40, 40).g, 255)
    var centre = nz.get_pixel(40, 40)
    assert_true(
        centre.r != 255 or centre.g != 255 or centre.b != 255,
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
    # back its own colour, and each midpoint the average of its
    # neighbours -- which pins the bracketing pair at every position
    # in the list, not just the ends.
    var g = LinearGradient(0.0, 0.0, 100.0, 0.0)
    var order: List[Int] = [5, 0, 9, 3, 10, 1, 7, 2, 8, 4, 6]
    for i in order:
        g.add_stop(Float64(i) / 10.0, Color(UInt8(i * 10), 0, 0))

    for i in range(11):
        assert_equal(
            g.color_at(Float64(i) * 10.0, 0.0).r,
            UInt8(i * 10),
            "stop " + String(i) + " reads back its own colour",
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
