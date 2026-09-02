"""Tests for path.mojo: Path building, curve flattening, and the
fill_path/stroke_path/stroke_path_aa entry points.
"""

from std.math import cos, pi, sin, sqrt
from std.testing import (
    assert_almost_equal,
    assert_equal,
    assert_true,
    assert_raises,
    TestSuite,
)

from canvas.color import Color
from canvas.buffer import Canvas
from canvas.geometry import Point
from canvas.gradient import LinearGradient, RadialGradient
from canvas.fill_rule import FillRule
from canvas.shapes.arcs import fill_arc
from canvas.shapes.ellipses import fill_ellipse_aa
from canvas.shapes.rects import fill_rect
from canvas.shapes.polygon_fill import fill_polygon, fill_polygon_aa
from canvas.path import (
    Path,
    FPoint,
    fill_path,
    fill_path_aa,
    fill_path_gradient,
    fill_path_radial_gradient,
    stroke_path,
    stroke_path_aa,
    _flatten,
    _quad_point,
    _cubic_point,
    _point_in_subpaths,
)

comptime BG = Color(0, 0, 0)
comptime FG = Color(255, 255, 255)


def _assert_pixel(
    c: Canvas, x: Int, y: Int, expected: Color, label: String
) raises:
    var p = c.get_pixel(x, y)
    assert_equal(p.r, expected.r, label)
    assert_equal(p.g, expected.g, label)
    assert_equal(p.b, expected.b, label)


def test_line_to_before_move_to_raises() raises:
    var p = Path()
    with assert_raises():
        p.line_to(10.0, 10.0)


def test_quad_curve_to_before_move_to_raises() raises:
    var p = Path()
    with assert_raises():
        p.quad_curve_to(5.0, 5.0, 10.0, 10.0)


def test_cubic_curve_to_before_move_to_raises() raises:
    var p = Path()
    with assert_raises():
        p.cubic_curve_to(2.0, 2.0, 8.0, 8.0, 10.0, 10.0)


def test_close_before_move_to_raises() raises:
    var p = Path()
    with assert_raises():
        p.close()


def test_arc_to_before_move_to_raises() raises:
    var p = Path()
    with assert_raises():
        p.arc_to(0.0, 0.0, 10.0, 0.0, pi / 2.0)


def test_quad_point_matches_hand_derived_values() raises:
    # Computed by hand via De Casteljau / the standard quadratic
    # Bezier formula.
    var p0 = FPoint(0.0, 0.0)
    var control = FPoint(10.0, 0.0)
    var p1 = FPoint(10.0, 10.0)

    var mid = _quad_point(p0, control, p1, 0.5)
    assert_equal(mid.x, 7.5)
    assert_equal(mid.y, 2.5)

    var quarter = _quad_point(p0, control, p1, 0.25)
    assert_equal(quarter.x, 4.375)
    assert_equal(quarter.y, 0.625)


def test_cubic_point_matches_hand_derived_values() raises:
    var p0 = FPoint(0.0, 0.0)
    var c1 = FPoint(0.0, 10.0)
    var c2 = FPoint(10.0, 10.0)
    var p1 = FPoint(10.0, 0.0)

    var mid = _cubic_point(p0, c1, c2, p1, 0.5)
    assert_equal(mid.x, 5.0)
    assert_equal(mid.y, 7.5)

    var quarter = _cubic_point(p0, c1, c2, p1, 0.25)
    assert_equal(quarter.x, 1.5625)
    assert_equal(quarter.y, 5.625)


def test_flatten_quad_curve_passes_through_hand_derived_midpoint() raises:
    # _CURVE_STEPS is 16, so t=0.5 falls exactly on step 8 -- the 8th
    # flattened point after the curve's start (index 7, since the
    # start point itself is index 0 and steps are 1-indexed from
    # there). At t=0.5 the quadratic weights are (0.25, 0.5, 0.25), so
    # x = 0.5*10 + 0.25*10 = 7.5 and y = 0.25*10 = 2.5.
    #
    # 7.5 exactly, not 8: flattening keeps sub-pixel positions rather
    # than snapping to the pixel grid, which is what lets
    # fill_path_aa's coverage sweep see where an edge really falls.
    # This assertion is what pins that.
    var p = Path()
    p.move_to(0.0, 0.0)
    p.quad_curve_to(10.0, 0.0, 10.0, 10.0)
    # 16 steps explicitly: this test is about the Bezier arithmetic at
    # t=0.5, so it pins the step count rather than letting the
    # automatic one pick (which would move where t=0.5 lands).
    var subpaths = _flatten(p, 16)
    assert_equal(len(subpaths), 1)
    ref pts = subpaths[0].points
    assert_equal(len(pts), 17)  # start point + 16 flattened curve steps
    assert_equal(pts[8].x, 7.5)
    assert_equal(pts[8].y, 2.5)
    # curve's actual endpoint must be exact, not just close
    assert_equal(pts[16].x, 10.0)
    assert_equal(pts[16].y, 10.0)


def test_flatten_cubic_curve_passes_through_hand_derived_midpoint() raises:
    var p = Path()
    p.move_to(0.0, 0.0)
    p.cubic_curve_to(0.0, 10.0, 10.0, 10.0, 10.0, 0.0)
    var subpaths = _flatten(p, 16)  # pinned, as in the quad test above
    ref pts = subpaths[0].points
    assert_equal(len(pts), 17)
    # t=0.5 cubic weights are (0.125, 0.375, 0.375, 0.125):
    # x = 0.375*10 + 0.125*10 = 5.0, y = 0.375*10 + 0.375*10 = 7.5.
    # 7.5 is kept, not rounded to 8 -- see the quad test above.
    assert_equal(pts[8].x, 5.0)
    assert_equal(pts[8].y, 7.5)
    assert_equal(pts[16].x, 10.0)
    assert_equal(pts[16].y, 0.0)


def test_flatten_arc_to_matches_hand_derived_quarter_circle() raises:
    # Center (0, 0), radius 10, start_angle=0 -> end_angle=pi/2: a
    # quarter circle from (10, 0) to (0, 10), both endpoints exact
    # (r*cos(0)=10, r*sin(0)=0; r*cos(pi/2) ~= 0, r*sin(pi/2) ~= 10,
    # each rounding cleanly). arc_to flattens through
    # canvas.shapes.arcs' _arc_points, so the arc's start point,
    # already placed by move_to, must not be duplicated.
    var p = Path()
    p.move_to(10.0, 0.0)
    p.arc_to(0.0, 0.0, 10.0, 0.0, pi / 2.0)
    var subpaths = _flatten(p)
    assert_equal(len(subpaths), 1)
    ref pts = subpaths[0].points
    # _arc_points' step count is max(4, Int(radius * span)) ==
    # max(4, Int(10 * pi/2)) == 15, giving 16 sampled points with index
    # 0 at the arc's start. arc_to skips that duplicate, so the
    # sub-path holds move_to's point plus arc_points[1:]: 1 + 15 == 16,
    # not 17. A wrong count means the skip broke.
    assert_equal(len(pts), 16)
    assert_equal(pts[0].x, 10.0)
    assert_equal(pts[0].y, 0.0)
    var last = pts[len(pts) - 1]
    # cos(pi/2) is 6.1e-17 rather than a clean zero in Float64, and
    # flattening no longer rounds that away -- so the endpoint check is
    # a tolerance, not an equality. The tolerance is far tighter than
    # the half-pixel the old rounding hid it behind.
    assert_almost_equal(last.x, 0.0, atol=1e-12)
    assert_almost_equal(last.y, 10.0, atol=1e-12)
    # Every intermediate sample must sit within a pixel of the circle
    # (radius 10, origin-centered): real curved sampling, not a
    # straight line between endpoints, which a start/end check alone
    # would accept.
    for i in range(1, len(pts) - 1):
        var p_i = pts[i]
        var dist = sqrt(p_i.x * p_i.x + p_i.y * p_i.y)
        assert_true(
            abs(dist - 10.0) < 1.0,
            "intermediate arc sample stays on the circle",
        )


def test_arc_to_updates_current_point_to_the_arc_end() raises:
    # A line_to() after arc_to() must start where the arc ended, not
    # at its center or start: arc_to's _current_x/_current_y
    # bookkeeping, the same contract the other segment types have.
    var p = Path()
    p.move_to(10.0, 0.0)
    p.arc_to(0.0, 0.0, 10.0, 0.0, pi / 2.0)
    p.line_to(20.0, 20.0)
    var subpaths = _flatten(p)
    ref pts = subpaths[0].points
    var last = pts[len(pts) - 1]
    assert_equal(last.x, 20.0)
    assert_equal(last.y, 20.0)
    var before_last = pts[len(pts) - 2]
    # The arc's own endpoint, unrounded -- cos(pi/2)'s Float64 noise
    # again, see the quarter-circle test above.
    assert_almost_equal(before_last.x, 0.0, atol=1e-12)
    assert_almost_equal(before_last.y, 10.0, atol=1e-12)


def test_fill_path_arc_to_matches_fill_arc_for_a_wedge() raises:
    # arc_to flattens through the same _arc_points fill_arc samples
    # through, so a move_to(arc start) -> arc_to(...) -> line_to(center)
    # -> close() wedge traces the cyclic edge list fill_arc's
    # fill_polygon call does, entered at a different point around the
    # same loop. fill_path's crossing scan is rotation-invariant, so
    # the two fill byte-identically -- the parity
    # test_fill_path_matches_fill_polygon_for_a_simple_triangle shows
    # for straight edges.
    var cx = 30.0
    var cy = 30.0
    var radius = 20.0
    var start_angle = 0.0
    var end_angle = pi / 2.0

    var c1 = Canvas(60, 60, BG)
    fill_arc(c1, cx, cy, radius, start_angle, end_angle, FG)

    var p = Path()
    p.move_to(cx + radius * cos(start_angle), cy + radius * sin(start_angle))
    p.arc_to(cx, cy, radius, start_angle, end_angle)
    p.line_to(cx, cy)
    p.close()
    var c2 = Canvas(60, 60, BG)
    fill_path(c2, p, FG)

    for y in range(60):
        for x in range(60):
            var a = c1.get_pixel(x, y)
            var b = c2.get_pixel(x, y)
            assert_equal(a.r, b.r)
            assert_equal(a.g, b.g)
            assert_equal(a.b, b.b)


def test_fill_path_aa_arc_to_wedge_has_a_real_antialiased_boundary() raises:
    # The same wedge through fill_path_aa, but not a byte-identical
    # parity test against fill_arc_aa: that samples an analytic "within
    # radius AND within angle span" test, a different algorithm from
    # fill_path_aa's flattened-boundary supersampling, so the two
    # diverge right at the edge where the hard-edged pair doesn't. What
    # must hold: full coverage deep inside the wedge, zero coverage
    # clearly outside, and a blended pixel exactly on the arc boundary,
    # which is the proof AA sampling ran on a curved edge.
    var cx = 30.0
    var cy = 30.0
    var radius = 20.0
    var start_angle = 0.0
    var end_angle = pi / 2.0

    var p = Path()
    p.move_to(cx + radius * cos(start_angle), cy + radius * sin(start_angle))
    p.arc_to(cx, cy, radius, start_angle, end_angle)
    p.line_to(cx, cy)
    p.close()
    var c = Canvas(60, 60, BG)
    fill_path_aa(c, p, FG)

    _assert_pixel(
        c,
        Int(cx) + 5,
        Int(cy) + 5,
        FG,
        "deep inside the wedge -- full coverage",
    )
    _assert_pixel(
        c,
        Int(cx) - 10,
        Int(cy) - 10,
        BG,
        "opposite quadrant -- clearly outside, zero coverage",
    )

    # (cx + r*cos(pi/4), cy + r*sin(pi/4)) sits exactly on the arc
    # boundary, by the same formula _arc_points uses.
    var edge_x = Int(cx + radius * cos(pi / 4.0))
    var edge_y = Int(cy + radius * sin(pi / 4.0))
    var edge = c.get_pixel(edge_x, edge_y)
    assert_true(
        edge.r > 0 and edge.r < 255,
        (
            "on the arc boundary -- real partial coverage, neither pure BG nor"
            " pure FG"
        ),
    )


def test_stroke_path_aa_draws_along_an_open_arc_to_segment() raises:
    # The same quarter-circle left open, so stroke_path_aa
    # (draw_polyline_aa underneath) traces the curved edge itself: the
    # pi/4 boundary point picks up real stroke coverage, while a point
    # near the wedge center, clear of every drawn segment, stays
    # background.
    var cx = 30.0
    var cy = 30.0
    var radius = 20.0

    var p = Path()
    p.move_to(cx + radius * cos(0.0), cy + radius * sin(0.0))
    p.arc_to(cx, cy, radius, 0.0, pi / 2.0)

    var c = Canvas(60, 60, BG)
    stroke_path_aa(c, p, FG, width=3.0)

    var edge_x = Int(cx + radius * cos(pi / 4.0))
    var edge_y = Int(cy + radius * sin(pi / 4.0))
    var edge = c.get_pixel(edge_x, edge_y)
    assert_true(
        edge.r > 0, "on the arc's own curve -- picks up real stroke coverage"
    )
    _assert_pixel(
        c,
        Int(cx),
        Int(cy),
        BG,
        "wedge center -- nowhere near the stroked curve, untouched",
    )


def test_flatten_splits_on_each_move_to() raises:
    var p = Path()
    p.move_to(0.0, 0.0)
    p.line_to(10.0, 0.0)
    p.move_to(20.0, 20.0)
    p.line_to(30.0, 20.0)
    var subpaths = _flatten(p)
    assert_equal(len(subpaths), 2)
    assert_equal(len(subpaths[0].points), 2)
    assert_equal(len(subpaths[1].points), 2)
    assert_true(not subpaths[0].closed)
    assert_true(not subpaths[1].closed)


def test_flatten_marks_closed_subpaths() raises:
    var p = Path()
    p.move_to(0.0, 0.0)
    p.line_to(10.0, 0.0)
    p.line_to(10.0, 10.0)
    p.close()
    var subpaths = _flatten(p)
    assert_equal(len(subpaths), 1)
    assert_true(subpaths[0].closed)


def test_fill_path_matches_fill_polygon_for_a_simple_triangle() raises:
    # fill_path's scanline algorithm generalizes fill_polygon's, so for
    # a single curve-free sub-path the two must be byte-identical.
    var points: List[Point] = [Point(10, 10), Point(50, 10), Point(30, 50)]

    var c1 = Canvas(60, 60, BG)
    fill_polygon(c1, points, FG)

    var p = Path()
    p.move_to(10.0, 10.0)
    p.line_to(50.0, 10.0)
    p.line_to(30.0, 50.0)
    p.close()
    var c2 = Canvas(60, 60, BG)
    fill_path(c2, p, FG)

    for y in range(60):
        for x in range(60):
            var a = c1.get_pixel(x, y)
            var b = c2.get_pixel(x, y)
            assert_equal(a.r, b.r)
            assert_equal(a.g, b.g)
            assert_equal(a.b, b.b)


def test_fill_path_punches_a_hole_with_a_second_subpath() raises:
    var p = Path()
    p.move_to(10.0, 10.0)
    p.line_to(50.0, 10.0)
    p.line_to(50.0, 50.0)
    p.line_to(10.0, 50.0)
    p.close()
    p.move_to(20.0, 20.0)
    p.line_to(40.0, 20.0)
    p.line_to(40.0, 40.0)
    p.line_to(20.0, 40.0)
    p.close()

    var c = Canvas(60, 60, BG)
    fill_path(c, p, FG)

    _assert_pixel(c, 15, 15, FG, "outer ring is filled")
    _assert_pixel(c, 30, 30, BG, "inner hole is punched through")


def test_fill_path_aa_matches_fill_polygon_aa_for_a_simple_triangle() raises:
    # The hard-edged pair's parity relationship, for the AA pair:
    # fill_path_aa's coverage test generalizes fill_polygon_aa's, so a
    # single curve-free sub-path must match byte for byte, antialiased
    # edge pixels included.
    var points: List[Point] = [Point(10, 10), Point(50, 10), Point(30, 50)]

    var c1 = Canvas(60, 60, BG)
    fill_polygon_aa(c1, points, FG)

    var p = Path()
    p.move_to(10.0, 10.0)
    p.line_to(50.0, 10.0)
    p.line_to(30.0, 50.0)
    p.close()
    var c2 = Canvas(60, 60, BG)
    fill_path_aa(c2, p, FG)

    for y in range(60):
        for x in range(60):
            var a = c1.get_pixel(x, y)
            var b = c2.get_pixel(x, y)
            assert_equal(a.r, b.r)
            assert_equal(a.g, b.g)
            assert_equal(a.b, b.b)


def test_fill_path_aa_punches_a_hole_with_a_second_subpath() raises:
    # The same shape through the AA entry point. Both test points sit
    # deep inside their region -- full coverage in the ring, zero in
    # the hole -- so no partial-coverage alpha needs computing:
    # hole-punching must survive _point_in_subpaths combining the
    # sub-paths instead of the discrete _row_crossings.
    var p = Path()
    p.move_to(10.0, 10.0)
    p.line_to(50.0, 10.0)
    p.line_to(50.0, 50.0)
    p.line_to(10.0, 50.0)
    p.close()
    p.move_to(20.0, 20.0)
    p.line_to(40.0, 20.0)
    p.line_to(40.0, 40.0)
    p.line_to(20.0, 40.0)
    p.close()

    var c = Canvas(60, 60, BG)
    fill_path_aa(c, p, FG)

    _assert_pixel(c, 15, 15, FG, "outer ring is filled")
    _assert_pixel(c, 30, 30, BG, "inner hole is punched through")


def test_fill_path_aa_resolves_a_subpixel_edge_shift() raises:
    # The property the sub-pixel pipeline exists for: moving an edge by
    # a fraction of a pixel has to change the rendering. Under the old
    # integer-snapped flattening, 10.0 and 10.25 both became 10 and
    # rendered byte-for-byte identically, so this is a real regression
    # guard rather than a restatement of the implementation.
    #
    # Hand-derived, not merely "different". A pixel centered at x=10
    # spans [9.5, 10.5], and at the default 4x supersample its columns
    # sit at 9.625, 9.875, 10.125 and 10.375. An edge at x=10.0 leaves
    # two of the four inside -> 8 of 16 samples -> alpha
    # round(0.5 * 255) = 128. At 10.25 only 10.375 survives -> 4/16 ->
    # round(0.25 * 255) = 64. At 10.5 none do -> the pixel is never
    # written at all.
    var expected_alpha: List[Int] = [128, 64, 0]
    for step in range(3):
        var left = 10.0 + 0.25 * Float64(step)
        var p = Path()
        p.move_to(left, 5.0)
        p.line_to(25.0, 5.0)
        p.line_to(25.0, 25.0)
        p.line_to(left, 25.0)
        p.close()

        var c = Canvas(40, 40, BG)
        fill_path_aa(c, p, FG)

        assert_equal(
            Int(c.get_pixel(10, 15).r),
            expected_alpha[step],
            "boundary-pixel coverage for a left edge at "
            + String(left)
            + " (a quarter-pixel shift must be visible)",
        )
        # The interior is unaffected by where the boundary sits.
        _assert_pixel(c, 20, 15, FG, "interior stays fully covered")


def test_fill_path_aa_subpixel_coverage_is_monotonic_across_a_pixel() raises:
    # Sweeping the edge a full pixel right, a quarter at a time, must
    # monotonically remove ink -- and strictly so at every step, which
    # is what says all four sub-sample columns are distinguishable
    # rather than two of them collapsing onto the same position.
    #
    # Summed across both columns the boundary passes through (10 and
    # 11), because the boundary itself migrates from one to the other
    # partway through the sweep: 128+255, 64+255, 0+255, 0+191, 0+128.
    var previous = -1
    for step in range(5):
        var left = 10.0 + 0.25 * Float64(step)
        var p = Path()
        p.move_to(left, 5.0)
        p.line_to(25.0, 5.0)
        p.line_to(25.0, 25.0)
        p.line_to(left, 25.0)
        p.close()

        var c = Canvas(40, 40, BG)
        fill_path_aa(c, p, FG)
        var ink = Int(c.get_pixel(10, 15).r) + Int(c.get_pixel(11, 15).r)
        if previous >= 0:
            assert_true(
                ink < previous,
                (
                    "each quarter-pixel step right must strictly reduce ink"
                    " across the boundary columns"
                ),
            )
        previous = ink


def test_point_in_subpaths_nonzero_fills_the_overlap_of_same_direction_subpaths() raises:
    # The continuous-membership analog of the even-odd/nonzero pair
    # above: the same two overlapping same-direction squares, checked
    # against _point_in_subpaths (what fill_path_aa's supersampling
    # calls) rather than rendered pixels, so the fill_rule divergence
    # is confirmed at the continuous level too.
    var p = Path()
    _square_subpath(p, 0.0, 0.0, 20.0, 20.0)
    _square_subpath(p, 10.0, 10.0, 30.0, 30.0)
    var subpaths = _flatten(p)

    assert_true(_point_in_subpaths(subpaths, 5.0, 5.0, FillRule.EVEN_ODD))
    assert_true(_point_in_subpaths(subpaths, 5.0, 5.0, FillRule.NONZERO))
    assert_true(_point_in_subpaths(subpaths, 25.0, 25.0, FillRule.EVEN_ODD))
    assert_true(_point_in_subpaths(subpaths, 25.0, 25.0, FillRule.NONZERO))
    assert_true(
        not _point_in_subpaths(subpaths, 15.0, 15.0, FillRule.EVEN_ODD)
    )  # hole
    assert_true(
        _point_in_subpaths(subpaths, 15.0, 15.0, FillRule.NONZERO)
    )  # solid


def test_stroke_path_draws_open_subpath_as_polyline() raises:
    var p = Path()
    p.move_to(5.0, 5.0)
    p.line_to(15.0, 5.0)
    p.line_to(15.0, 15.0)
    # deliberately not closed

    var c = Canvas(20, 20, BG)
    stroke_path(c, p, FG)

    _assert_pixel(c, 10, 5, FG, "top edge drawn")
    _assert_pixel(c, 15, 10, FG, "right edge drawn")
    # the implicit closing edge (15,15) back to (5,5) must NOT be drawn
    _assert_pixel(c, 10, 10, BG, "no closing edge for an open sub-path")


def test_stroke_path_draws_closed_subpath_as_polygon() raises:
    var p = Path()
    p.move_to(5.0, 5.0)
    p.line_to(15.0, 5.0)
    p.line_to(15.0, 15.0)
    p.line_to(5.0, 15.0)
    p.close()

    var c = Canvas(20, 20, BG)
    stroke_path(c, p, FG)

    _assert_pixel(c, 5, 10, FG, "closing edge IS drawn for a closed sub-path")


def test_stroke_path_aa_respects_translucent_input_color() raises:
    var p = Path()
    p.move_to(5.0, 5.0)
    p.line_to(15.0, 5.0)

    var c = Canvas(20, 10, Color(0, 0, 0))
    stroke_path_aa(c, p, Color(200, 0, 0, 128))
    var mid = c.get_pixel(10, 5)  # deep interior, fully covered
    assert_equal(mid.r, 100)
    assert_equal(mid.g, 0)
    assert_equal(mid.b, 0)


def test_fill_path_gradient_matches_gradient_color_at_per_pixel() raises:
    # The gradient and hand-derived midpoint from test_gradient.mojo's
    # color_at test, confirming fill_path_gradient queries color_at per
    # pixel as fill_rect_gradient does.
    var g = LinearGradient(0.0, 0.0, 100.0, 0.0)
    g.add_stop(0.0, Color(0, 0, 0, 255))
    g.add_stop(1.0, Color(255, 255, 255, 255))

    var p = Path()
    p.move_to(0.0, 0.0)
    p.line_to(100.0, 0.0)
    p.line_to(100.0, 10.0)
    p.line_to(0.0, 10.0)
    p.close()

    var c = Canvas(100, 10, Color(50, 50, 50))
    fill_path_gradient(c, p, g)

    _assert_pixel(c, 0, 5, Color(0, 0, 0), "left edge -> first stop's color")
    _assert_pixel(c, 50, 5, Color(128, 128, 128), "midpoint -> interpolated")


def test_fill_path_radial_gradient_matches_gradient_color_at_per_pixel() raises:
    # The center/radius and exact-distance point from
    # test_gradient.mojo's radial Pythagorean-triple test, confirming
    # fill_path_radial_gradient queries color_at per pixel.
    var g = RadialGradient(0.0, 0.0, 5.0)
    g.add_stop(0.0, Color(0, 0, 0, 255))
    g.add_stop(1.0, Color(255, 255, 255, 255))

    var p = Path()
    p.move_to(0.0, 0.0)
    p.line_to(10.0, 0.0)
    p.line_to(10.0, 10.0)
    p.line_to(0.0, 10.0)
    p.close()

    var c = Canvas(10, 10, Color(50, 50, 50))
    fill_path_radial_gradient(c, p, g)

    _assert_pixel(c, 0, 0, Color(0, 0, 0), "center -> first stop's color")
    _assert_pixel(
        c,
        3,
        4,
        Color(255, 255, 255),
        "exact radius (3-4-5 triangle) -> last stop's color",
    )


def _square_subpath(
    mut p: Path, x0: Float64, y0: Float64, x1: Float64, y1: Float64
) raises:
    p.move_to(x0, y0)
    p.line_to(x1, y0)
    p.line_to(x1, y1)
    p.line_to(x0, y1)
    p.close()


def test_fill_path_even_odd_leaves_a_hole_where_same_direction_subpaths_overlap() raises:
    # Two squares, (0,0)-(20,20) and (10,10)-(30,30), traced the same
    # rotational direction as two sub-paths of ONE path. Under EVEN_ODD
    # the overlap x=[10,20), y=[10,20) has been crossed twice, so it
    # reads as outside and a hole appears there, though either square
    # alone would fill it.
    var p = Path()
    _square_subpath(p, 0.0, 0.0, 20.0, 20.0)
    _square_subpath(p, 10.0, 10.0, 30.0, 30.0)

    var c = Canvas(30, 30, BG)
    fill_path(c, p, FG, fill_rule=FillRule.EVEN_ODD)

    _assert_pixel(c, 5, 5, FG, "square A only")
    _assert_pixel(c, 25, 25, FG, "square B only")
    _assert_pixel(c, 15, 15, BG, "overlap region -- a hole under EVEN_ODD")


def test_fill_path_nonzero_fills_the_overlap_of_same_direction_subpaths_solid() raises:
    # The EVEN_ODD shape with only the fill rule changed, so fill_rule
    # demonstrably changes the result on one input. NONZERO's signed
    # winding reaches 2 in the overlap, since both squares wind the
    # same direction: nonzero, so filled, no hole.
    var p = Path()
    _square_subpath(p, 0.0, 0.0, 20.0, 20.0)
    _square_subpath(p, 10.0, 10.0, 30.0, 30.0)

    var c = Canvas(30, 30, BG)
    fill_path(c, p, FG, fill_rule=FillRule.NONZERO)

    _assert_pixel(c, 5, 5, FG, "square A only")
    _assert_pixel(c, 25, 25, FG, "square B only")
    _assert_pixel(
        c, 15, 15, FG, "overlap region -- solid under NONZERO, no hole"
    )


def test_rect_builds_the_same_subpath_as_the_long_form() raises:
    # The convenience builder must be exactly its expansion, not
    # merely similar -- so this compares flattened points rather than
    # rendering.
    var built = Path()
    built.rect(10.0, 20.0, 30.0, 40.0)

    var manual = Path()
    manual.move_to(10.0, 20.0)
    manual.line_to(40.0, 20.0)
    manual.line_to(40.0, 60.0)
    manual.line_to(10.0, 60.0)
    manual.close()

    var a = _flatten(built)
    var b = _flatten(manual)
    assert_equal(len(a), len(b), "same sub-path count")
    assert_equal(len(a[0].points), len(b[0].points), "same point count")
    assert_true(a[0].closed and b[0].closed, "both closed")
    for i in range(len(a[0].points)):
        assert_equal(a[0].points[i].x, b[0].points[i].x)
        assert_equal(a[0].points[i].y, b[0].points[i].y)


def test_rect_covers_the_geometric_rectangle_not_fill_rects_extent() raises:
    # A gotcha worth pinning rather than papering over. Path.rect
    # describes the geometric rectangle [x, x+width] x [y, y+height],
    # which is what `rect` means everywhere else. fill_path's X-fill
    # between a row's crossing pair is *inclusive*, so filling it
    # covers column x+width as well -- one more than
    # fill_rect(x, y, width, height), which stops at x+width-1.
    #
    # That is fill_polygon's documented convention, not a bug in
    # either: matching fill_rect exactly needs the asymmetric corners
    # its docstring describes. Asserted both ways here so a future
    # change to either cannot quietly diverge.
    var via_path = Canvas(40, 40, BG)
    var p = Path()
    p.rect(8.0, 6.0, 20.0, 24.0)
    fill_path(via_path, p, FG)

    var via_rect = Canvas(40, 40, BG)
    fill_rect(via_rect, 8, 6, 20, 24, FG)

    assert_equal(via_path.get_pixel(27, 15).r, 255, "shared last column")
    assert_equal(via_rect.get_pixel(27, 15).r, 255, "shared last column")
    assert_equal(
        via_path.get_pixel(28, 15).r,
        255,
        "the path fill includes the closing column",
    )
    assert_equal(
        via_rect.get_pixel(28, 15).r,
        0,
        "fill_rect stops one short of it",
    )

    # With the asymmetric corners fill_polygon documents, they agree
    # exactly.
    var matched = Canvas(40, 40, BG)
    var q = Path()
    q.move_to(8.0, 6.0)
    q.line_to(27.0, 6.0)
    q.line_to(27.0, 30.0)
    q.line_to(8.0, 30.0)
    q.close()
    fill_path(matched, q, FG)
    for y in range(40):
        for x in range(40):
            assert_equal(
                matched.get_pixel(x, y).r,
                via_rect.get_pixel(x, y).r,
                "asymmetric corners reproduce fill_rect exactly",
            )


def test_degenerate_rect_adds_nothing() raises:
    var p = Path()
    p.rect(5.0, 5.0, 0.0, 10.0)
    p.rect(5.0, 5.0, 10.0, -3.0)
    assert_equal(len(_flatten(p)), 0, "no sub-path from a degenerate rect")


def test_round_rect_corners_are_inside_the_square_corners() raises:
    # A rounded corner must cut the corner off: the pixel at the
    # rectangle's own corner is outside the shape, while a point well
    # inside is not.
    var c = Canvas(60, 60, BG)
    var p = Path()
    p.round_rect(10.0, 10.0, 40.0, 40.0, 12.0)
    fill_path_aa(c, p, FG)

    assert_equal(c.get_pixel(11, 11).r, 0, "the square corner is cut away")
    assert_equal(c.get_pixel(30, 30).r, 255, "the middle is filled")
    assert_equal(c.get_pixel(30, 11).r, 255, "the straight top edge is filled")
    assert_equal(c.get_pixel(11, 30).r, 255, "the straight left edge too")


def test_round_rect_radius_is_clamped_to_half_the_short_side() raises:
    # An over-large radius must give the stadium/circle limit rather
    # than self-intersecting corners, which under EVEN_ODD would punch
    # holes in the shape.
    var clamped = Canvas(60, 60, BG)
    var p1 = Path()
    p1.round_rect(10.0, 10.0, 40.0, 40.0, 500.0)
    fill_path_aa(clamped, p1, FG)

    var exact = Canvas(60, 60, BG)
    var p2 = Path()
    p2.round_rect(10.0, 10.0, 40.0, 40.0, 20.0)
    fill_path_aa(exact, p2, FG)

    for y in range(60):
        for x in range(60):
            assert_equal(
                clamped.get_pixel(x, y).r,
                exact.get_pixel(x, y).r,
                "an over-large radius equals the half-side limit",
            )
    assert_equal(clamped.get_pixel(30, 30).r, 255, "and it is solid, not holed")


def test_round_rect_with_zero_radius_is_a_plain_rect() raises:
    var rounded = Canvas(40, 40, BG)
    var p1 = Path()
    p1.round_rect(6.0, 6.0, 20.0, 24.0, 0.0)
    fill_path(rounded, p1, FG)

    var plain = Canvas(40, 40, BG)
    var p2 = Path()
    p2.rect(6.0, 6.0, 20.0, 24.0)
    fill_path(plain, p2, FG)

    for y in range(40):
        for x in range(40):
            assert_equal(rounded.get_pixel(x, y).r, plain.get_pixel(x, y).r)


def test_path_ellipse_tracks_the_exact_primitive() raises:
    # Four cubics per ellipse is an approximation where fill_ellipse_aa
    # is exact, so this asserts they agree closely rather than exactly:
    # kappa's worst radial error is ~0.027% of the radius, far under
    # one supersample step. Compared as total ink so a boundary pixel
    # differing by a level or two does not fail it.
    var via_path = Canvas(80, 60, BG)
    var p = Path()
    p.ellipse(40.0, 30.0, 30.0, 20.0)
    fill_path_aa(via_path, p, FG)

    var via_primitive = Canvas(80, 60, BG)
    fill_ellipse_aa(via_primitive, 40.0, 30.0, 30.0, 20.0, FG)

    var ink_path = 0
    var ink_prim = 0
    for y in range(60):
        for x in range(80):
            ink_path += Int(via_path.get_pixel(x, y).r)
            ink_prim += Int(via_primitive.get_pixel(x, y).r)

    var gap = ink_path - ink_prim
    if gap < 0:
        gap = -gap
    assert_true(
        gap * 500 < ink_prim,
        "the cubic approximation is within 0.2% of the exact ellipse's"
        " ink (path "
        + String(ink_path)
        + " vs primitive "
        + String(ink_prim)
        + ")",
    )
    assert_equal(via_path.get_pixel(40, 30).r, 255, "centre is filled")
    assert_equal(via_path.get_pixel(2, 2).r, 0, "the corner is not")


def test_path_ellipse_can_punch_a_hole() raises:
    # The reason this exists at all rather than deferring to
    # fill_ellipse_aa: an ellipse that is one sub-path among several.
    var c = Canvas(80, 60, BG)
    var p = Path()
    p.ellipse(40.0, 30.0, 32.0, 24.0)
    p.ellipse(40.0, 30.0, 16.0, 12.0)
    fill_path_aa(c, p, FG)

    assert_equal(c.get_pixel(40, 30).r, 0, "inner ellipse punches a hole")
    assert_equal(c.get_pixel(40, 12).r, 255, "the ring itself is filled")


def test_degenerate_ellipse_adds_nothing() raises:
    var p = Path()
    p.ellipse(10.0, 10.0, 0.0, 5.0)
    assert_equal(len(_flatten(p)), 0, "no sub-path from a zero radius")


def test_auto_step_count_scales_with_curve_size() raises:
    # The property adaptive flattening exists for: a bigger curve of
    # the same shape needs proportionally more segments, where a fixed
    # count gives the small one too many and the large one too few.
    var small = Path()
    small.move_to(0.0, 0.0)
    small.cubic_curve_to(0.0, 4.0, 4.0, 4.0, 4.0, 0.0)
    var big = Path()
    big.move_to(0.0, 0.0)
    big.cubic_curve_to(0.0, 400.0, 400.0, 400.0, 400.0, 0.0)

    var small_sub = _flatten(small)
    var big_sub = _flatten(big)
    var n_small = len(small_sub[0].points)
    var n_big = len(big_sub[0].points)
    assert_true(
        n_small < n_big,
        "a 100x larger curve must be flattened more finely ("
        + String(n_small)
        + " vs "
        + String(n_big)
        + " points)",
    )
    # The step count follows sqrt of the second difference, so a 100x
    # scale is about a 10x step count -- checked loosely, since the
    # exact value depends on the tolerance constant.
    assert_true(n_big > n_small * 4, "and by roughly the expected factor")


def test_auto_flattening_stays_within_tolerance_of_the_true_curve() raises:
    # Every flattened point must lie on the curve (they are sampled
    # from it), and consecutive points must be close enough that the
    # chord between them cannot stray far. Checked by comparing each
    # chord midpoint against the true curve point at the same
    # parameter -- which is the deviation the step count is chosen to
    # bound.
    var p = Path()
    p.move_to(10.0, 200.0)
    p.cubic_curve_to(60.0, 10.0, 240.0, 390.0, 290.0, 200.0)
    var sub = _flatten(p)
    ref pts = sub[0].points
    var steps = len(pts) - 1

    var p0 = FPoint(10.0, 200.0)
    var c1 = FPoint(60.0, 10.0)
    var c2 = FPoint(240.0, 390.0)
    var p1 = FPoint(290.0, 200.0)

    var worst = 0.0
    for i in range(steps):
        var t_mid = (Float64(i) + 0.5) / Float64(steps)
        var exact = _cubic_point(p0, c1, c2, p1, t_mid)
        var chord_x = (pts[i].x + pts[i + 1].x) / 2.0
        var chord_y = (pts[i].y + pts[i + 1].y) / 2.0
        var dx = chord_x - exact.x
        var dy = chord_y - exact.y
        var d = sqrt(dx * dx + dy * dy)
        if d > worst:
            worst = d
    assert_true(
        worst < 0.02,
        "worst chord deviation "
        + String(worst)
        + " must stay within the flattening tolerance",
    )


def test_explicit_curve_steps_still_overrides() raises:
    var p = Path()
    p.move_to(0.0, 0.0)
    p.cubic_curve_to(0.0, 300.0, 300.0, 300.0, 300.0, 0.0)
    var forced = _flatten(p, 8)
    assert_equal(
        len(forced[0].points),
        9,
        "an explicit count wins over the automatic one",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
