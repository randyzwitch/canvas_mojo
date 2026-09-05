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
from canvas.geometry import Point, FPoint, Transform2D
from canvas.gradient import LinearGradient, RadialGradient
from canvas.fill_rule import FillRule
from canvas.shapes.arcs import fill_arc
from canvas.shapes.ellipses import fill_ellipse_aa
from canvas.shapes.rects import fill_rect
from canvas.shapes.polygon_fill import fill_polygon, fill_polygon_aa
from canvas.shapes.lines import LineCap, LineJoin
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


def _flat_points(p: Path) raises -> List[FPoint]:
    var subs = _flatten(p)
    var out = List[FPoint]()
    for i in range(len(subs)):
        for q in subs[i].points:
            out.append(q)
    return out^


def test_transformed_maps_lines_like_to_point_does() raises:
    # The straightforward case: a transformed path's points must equal
    # the transform applied to the original's points.
    var t = Transform2D(2.0, -1.5, 40.0, 90.0, rotation=0.4)
    var p = Path()
    p.move_to(3.0, 5.0)
    p.line_to(11.0, -2.0)
    p.line_to(7.0, 8.0)

    var moved = p.transformed(t)
    var got = _flat_points(moved)
    var src: List[FPoint] = [
        FPoint(3.0, 5.0),
        FPoint(11.0, -2.0),
        FPoint(7.0, 8.0),
    ]
    assert_equal(len(got), 3)
    for i in range(3):
        var want = t.to_point(src[i].x, src[i].y)
        assert_equal(got[i].x, want.x, "transformed x matches to_point")
        assert_equal(got[i].y, want.y, "transformed y matches to_point")


def test_transformed_maps_curves_by_their_control_points() raises:
    # An affine transform of a Bezier is the Bezier of the transformed
    # control points, so this checks the emitted command directly.
    #
    # Deliberately not by comparing flattened points: flattening picks
    # its step count from curvature (see _auto_steps), so a scaled-up
    # curve is sampled more finely and the two point lists do not even
    # have the same length. That is correct behaviour, and it is why
    # the contract lives at the control points rather than the samples.
    var t = Transform2D(1.7, 2.3, -12.0, 30.0, rotation=-0.9)
    var p = Path()
    p.move_to(0.0, 0.0)
    p.cubic_curve_to(4.0, 10.0, 16.0, -6.0, 20.0, 3.0)

    var moved = p.transformed(t)
    assert_equal(len(moved.commands), 2, "move_to then cubic_curve_to")

    var c1 = t.to_point(4.0, 10.0)
    var c2 = t.to_point(16.0, -6.0)
    var end = t.to_point(20.0, 3.0)
    # A tolerance rather than exact equality: the same expression
    # evaluated at two call sites can differ in the last bit or two
    # when the compiler contracts a multiply-add at one and not the
    # other. 1e-12 is far below anything geometrically meaningful and
    # far above that noise.
    ref cmd = moved.commands[1]
    assert_almost_equal(cmd.p1.x, c1.x, atol=1e-12, msg="control 1 x")
    assert_almost_equal(cmd.p1.y, c1.y, atol=1e-12, msg="control 1 y")
    assert_almost_equal(cmd.p2.x, c2.x, atol=1e-12, msg="control 2 x")
    assert_almost_equal(cmd.p2.y, c2.y, atol=1e-12, msg="control 2 y")
    assert_almost_equal(cmd.p3.x, end.x, atol=1e-12, msg="endpoint x")
    assert_almost_equal(cmd.p3.y, end.y, atol=1e-12, msg="endpoint y")


def test_transformed_keeps_a_uniformly_scaled_arc_exact() raises:
    # Equal scale magnitudes map a circle to a circle, so the arc stays
    # an arc: same point count as the original, every point on the new
    # circle at the new radius.
    var t = Transform2D(3.0, 3.0, 25.0, 40.0, rotation=0.3)
    var p = Path()
    p.move_to(10.0, 0.0)
    p.arc_to(0.0, 0.0, 10.0, 0.0, pi / 2.0)

    var moved = p.transformed(t)
    var pts = _flat_points(moved)
    var centre = t.to_point(0.0, 0.0)
    for i in range(len(pts)):
        var dx = pts[i].x - centre.x
        var dy = pts[i].y - centre.y
        assert_true(
            abs(sqrt(dx * dx + dy * dy) - 30.0) < 1.0e-9,
            "every point sits on the scaled circle of radius 30",
        )


def test_transformed_flattens_an_arc_under_unequal_scales() raises:
    # Unequal magnitudes turn a circular arc into an elliptical one,
    # which arc_to cannot express -- so it is flattened instead. The
    # drawn shape must still be right: every point on the ellipse the
    # transform implies.
    var t = Transform2D(3.0, 1.0, 25.0, 40.0)
    var p = Path()
    p.move_to(10.0, 0.0)
    p.arc_to(0.0, 0.0, 10.0, 0.0, pi / 2.0)

    var pts = _flat_points(p.transformed(t))
    assert_true(len(pts) > 4, "the arc was flattened, not dropped")
    for i in range(len(pts)):
        var dx = (pts[i].x - 25.0) / 30.0
        var dy = (pts[i].y - 40.0) / 10.0
        assert_true(
            abs(dx * dx + dy * dy - 1.0) < 1.0e-9,
            "every point lies on the implied ellipse",
        )


def test_flatten_arc_to_sweeps_backwards_when_end_is_below_start() raises:
    # From angle 0 down to -pi/2: the quarter above the centre (y is
    # down), traversed from (10, 0) to (0, -10). Every sample stays on
    # the circle and in that quarter, in that order.
    var p = Path()
    p.move_to(10.0, 0.0)
    p.arc_to(0.0, 0.0, 10.0, 0.0, -pi / 2.0)
    var pts = _flat_points(p)
    assert_true(len(pts) > 4, "the arc was sampled, not dropped")
    assert_true(
        abs(pts[0].x - 10.0) < 1.0e-9 and abs(pts[0].y) < 1.0e-9,
        "starts at angle 0",
    )
    var last = pts[len(pts) - 1]
    assert_true(
        abs(last.x) < 1.0e-9 and abs(last.y + 10.0) < 1.0e-9,
        "ends at angle -pi/2",
    )
    for i in range(len(pts)):
        assert_true(
            abs(sqrt(pts[i].x * pts[i].x + pts[i].y * pts[i].y) - 10.0)
            < 1.0e-9,
            "on the circle",
        )
        assert_true(
            pts[i].x >= -1.0e-9 and pts[i].y <= 1.0e-9,
            "in the upper-right quarter",
        )


def test_transformed_keeps_a_half_turn_arc_exact() raises:
    # Both scales negative is a half turn, not a reflection: the arc
    # stays an arc_to (two commands: the move and the arc), its angles
    # shifted by pi. The original quarter from (10, 0) to (0, 10) maps
    # to (-10, 0) to (0, -10) about the origin.
    var t = Transform2D(-1.0, -1.0, 0.0, 0.0)
    var p = Path()
    p.move_to(10.0, 0.0)
    p.arc_to(0.0, 0.0, 10.0, 0.0, pi / 2.0)
    var moved = p.transformed(t)
    assert_equal(len(moved.commands), 2, "still a move_to and an arc_to")
    var pts = _flat_points(moved)
    var first = pts[0]
    var last = pts[len(pts) - 1]
    assert_true(abs(first.x + 10.0) < 1.0e-9 and abs(first.y) < 1.0e-9)
    assert_true(abs(last.x) < 1.0e-9 and abs(last.y + 10.0) < 1.0e-9)
    for i in range(len(pts)):
        assert_true(pts[i].x <= 1.0e-9 and pts[i].y <= 1.0e-9, "third quarter")


def test_transformed_arc_survives_a_y_flip() raises:
    # A y-flip is the transform a chart actually uses, and it reflects:
    # the sweep runs backwards, so the angles have to be negated and
    # swapped or the arc comes out as its complement.
    var t = Transform2D(2.0, -2.0, 50.0, 50.0)
    var p = Path()
    p.move_to(10.0, 0.0)
    p.arc_to(0.0, 0.0, 10.0, 0.0, pi / 2.0)

    var moved = p.transformed(t)
    assert_equal(
        len(moved.commands), 2, "a reflected arc stays an arc_to, not lines"
    )
    var pts = _flat_points(moved)
    # The original quarter sweeps from (10, 0) to (0, 10). Flipped and
    # scaled about (50, 50) that is (70, 50) to (50, 30) -- and it must
    # come out in that order: the reflection runs the sweep the other
    # way, which the re-emitted arc_to carries as a decreasing angle.
    var first = pts[0]
    var last = pts[len(pts) - 1]
    assert_true(
        abs(first.x - 70.0) < 1.0e-9 and abs(first.y - 50.0) < 1.0e-9,
        "the flipped arc starts where the original's start maps to",
    )
    assert_true(
        abs(last.x - 50.0) < 1.0e-9 and abs(last.y - 30.0) < 1.0e-9,
        "...and ends where its end maps to",
    )
    # ...and stays on the circle throughout, rather than sweeping the
    # other three quarters.
    for i in range(len(pts)):
        var dx = pts[i].x - 50.0
        var dy = pts[i].y - 50.0
        assert_true(
            abs(sqrt(dx * dx + dy * dy) - 20.0) < 1.0e-9,
            "on the flipped circle",
        )
        assert_true(
            pts[i].x >= 49.999 and pts[i].y <= 50.001,
            "and confined to the quarter the original covered",
        )


def test_bounds_follow_the_flattened_curve_not_the_control_point() raises:
    # A quadratic from (0, 0) to (20, 0) pulled toward (10, 20) peaks
    # at t=0.5, where y = 0.25*0 + 0.5*20 + 0.25*0 = 10: half the
    # control point's height. The box must reach that apex (within
    # the flattening's step) and stop well short of the control point.
    var p = Path()
    p.move_to(0.0, 0.0)
    p.quad_curve_to(10.0, 20.0, 20.0, 0.0)
    var b = p.bounds()
    assert_equal(b[0], 0.0, "min_x is the start point")
    assert_equal(b[1], 0.0, "min_y is the baseline")
    assert_equal(b[2], 20.0, "max_x is the end point")
    assert_true(b[3] > 9.9 and b[3] <= 10.0, "max_y is the apex, not 20")


def test_bounds_span_every_sub_path() raises:
    var p = Path()
    p.rect(5.0, 5.0, 10.0, 10.0)
    p.rect(-3.0, 40.0, 2.0, 2.0)
    var b = p.bounds()
    assert_equal(b[0], -3.0)
    assert_equal(b[1], 5.0)
    assert_equal(b[2], 15.0)
    assert_equal(b[3], 42.0)


def test_bounds_of_an_empty_path_are_zero() raises:
    var b = Path().bounds()
    assert_equal(b[0], 0.0)
    assert_equal(b[2], 0.0)


def _assert_box(
    got: Tuple[Float64, Float64, Float64, Float64],
    min_x: Float64,
    min_y: Float64,
    max_x: Float64,
    max_y: Float64,
    tol: Float64,
    msg: String,
) raises:
    assert_true(
        abs(got[0] - min_x) <= tol, msg + " (min_x " + String(got[0]) + ")"
    )
    assert_true(
        abs(got[1] - min_y) <= tol, msg + " (min_y " + String(got[1]) + ")"
    )
    assert_true(
        abs(got[2] - max_x) <= tol, msg + " (max_x " + String(got[2]) + ")"
    )
    assert_true(
        abs(got[3] - max_y) <= tol, msg + " (max_y " + String(got[3]) + ")"
    )


def _horizontal_line() raises -> Path:
    var p = Path()
    p.move_to(10.0, 20.0)
    p.line_to(50.0, 20.0)
    return p^


def test_stroke_bounds_of_a_line_follow_the_cap() raises:
    # Width 4 on y = 20 spans y 18..22 under every cap; the caps decide
    # x. BUTT stops at the endpoints; SQUARE and ROUND overhang each by
    # half the width, 2.
    var p = _horizontal_line()
    _assert_box(
        p.stroke_bounds(4.0, cap=LineCap.BUTT),
        10.0,
        18.0,
        50.0,
        22.0,
        1e-9,
        "butt",
    )
    _assert_box(
        p.stroke_bounds(4.0, cap=LineCap.SQUARE),
        8.0,
        18.0,
        52.0,
        22.0,
        1e-9,
        "square",
    )
    # A round cap is a polygonised disk, so its extent is the disk's to
    # within the polygon's sag.
    _assert_box(
        p.stroke_bounds(4.0, cap=LineCap.ROUND),
        8.0,
        18.0,
        52.0,
        22.0,
        0.05,
        "round",
    )


def _v_shape() raises -> Path:
    # Apex at (30, 10), arms down to (10, 40) and (50, 40).
    var p = Path()
    p.move_to(10.0, 40.0)
    p.line_to(30.0, 10.0)
    p.line_to(50.0, 40.0)
    return p^


def test_stroke_bounds_of_a_sharp_corner_follow_the_join() raises:
    # The arms are (20, 30) and (-20, 30) from the apex, so the angle
    # between them has cos = (-400 + 900) / 1300 = 5/13 and
    # sin(half) = sqrt((1 - 5/13) / 2) = 2 / sqrt(13). Half the width
    # is 2.
    # MITER: the spike reaches 2 / sin(half) = sqrt(13) = 3.6056 past
    # the apex, so min_y = 10 - sqrt(13) = 6.3944.
    var p = _v_shape()
    var miter_top = 10.0 - sqrt(13.0)
    var b = p.stroke_bounds(4.0, cap=LineCap.BUTT, join=LineJoin.MITER)
    assert_true(abs(b[1] - miter_top) < 1e-6, "miter spike: " + String(b[1]))
    # BEVEL: the corner is cut at the two outer offset points, each
    # 2 * sin(half) = 4 / sqrt(13) = 1.1094 above the apex, so
    # min_y = 8.8906.
    var bevel_top = 10.0 - 4.0 / sqrt(13.0)
    b = p.stroke_bounds(4.0, cap=LineCap.BUTT, join=LineJoin.BEVEL)
    assert_true(abs(b[1] - bevel_top) < 1e-6, "bevel cut: " + String(b[1]))
    # ROUND: the join disk reaches exactly half the width above the
    # apex, to within the polygon's sag.
    b = p.stroke_bounds(4.0, cap=LineCap.BUTT, join=LineJoin.ROUND)
    assert_true(abs(b[1] - 8.0) < 0.05, "round join: " + String(b[1]))
    # The miter ratio here is 1 / sin(half) = sqrt(13) / 2 = 1.803. A
    # limit below that falls back to the bevel; one above keeps the
    # spike.
    b = p.stroke_bounds(
        4.0, cap=LineCap.BUTT, join=LineJoin.MITER, miter_limit=1.5
    )
    assert_true(abs(b[1] - bevel_top) < 1e-6, "limit 1.5 falls back")
    b = p.stroke_bounds(
        4.0, cap=LineCap.BUTT, join=LineJoin.MITER, miter_limit=2.0
    )
    assert_true(abs(b[1] - miter_top) < 1e-6, "limit 2.0 keeps the spike")


def test_stroke_bounds_of_a_curve_use_the_same_flattening() raises:
    # The curve's apex is horizontal, so a stroke of width 2 reaches
    # exactly 1 past the fill extent there -- provided the stroke and
    # bounds() flatten the curve the same way.
    var p = Path()
    p.move_to(0.0, 0.0)
    p.quad_curve_to(10.0, 20.0, 20.0, 0.0)
    var fill = p.bounds()
    var stroke = p.stroke_bounds(2.0, cap=LineCap.BUTT, join=LineJoin.MITER)
    assert_true(
        abs(stroke[3] - (fill[3] + 1.0)) < 0.01,
        "apex plus half the width: " + String(stroke[3]),
    )
    assert_true(stroke[0] < fill[0] and stroke[2] > fill[2], "and wider")


def test_stroke_bounds_stop_where_the_dashes_do() raises:
    # A 10-on/10-off pattern along x 10..50 draws 10..20 and 30..40,
    # so the box ends at 40 rather than 50.
    var p = _horizontal_line()
    var dashes: List[Float64] = [10.0, 10.0]
    _assert_box(
        p.stroke_bounds(4.0, dashes=dashes, cap=LineCap.BUTT),
        10.0,
        18.0,
        40.0,
        22.0,
        1e-9,
        "dashed butt",
    )
    # The path's own start takes the cap; a dash boundary is always
    # butt, so a round cap overhangs the start by 2 and nothing at 40.
    var b = p.stroke_bounds(4.0, dashes=dashes, cap=LineCap.ROUND)
    assert_true(abs(b[0] - 8.0) < 0.05, "capped start: " + String(b[0]))
    assert_true(abs(b[2] - 40.0) < 1e-9, "butt dash end: " + String(b[2]))


def test_stroke_bounds_of_a_closed_shape_and_several_sub_paths() raises:
    # A closed rectangle has no caps; width 2 with miter corners pads
    # each side by exactly 1. A second sub-path extends the box.
    var p = Path()
    p.rect(10.0, 10.0, 20.0, 20.0)
    _assert_box(
        p.stroke_bounds(2.0, join=LineJoin.MITER),
        9.0,
        9.0,
        31.0,
        31.0,
        1e-9,
        "rect",
    )
    p.move_to(60.0, 5.0)
    p.line_to(60.0, 50.0)
    _assert_box(
        p.stroke_bounds(2.0, cap=LineCap.BUTT, join=LineJoin.MITER),
        9.0,
        5.0,
        61.0,
        50.0,
        1e-9,
        "rect plus a line",
    )


def test_in_fill_of_a_convex_polygon() raises:
    # A right triangle with the hypotenuse x + y = 20.
    var p = Path()
    p.move_to(0.0, 0.0)
    p.line_to(20.0, 0.0)
    p.line_to(0.0, 20.0)
    p.close()
    assert_true(p.in_fill(5.0, 5.0), "inside")
    assert_true(not p.in_fill(15.0, 15.0), "outside, past the hypotenuse")
    assert_true(not p.in_fill(-1.0, 5.0), "outside, left")
    assert_true(not p.in_fill(5.0, 25.0), "outside, below")
    # The boundary is half-open: left and top edges are in, the
    # hypotenuse (a right edge here) is out.
    assert_true(p.in_fill(0.0, 5.0), "on the left edge")
    assert_true(p.in_fill(5.0, 0.0), "on the top edge")
    assert_true(not p.in_fill(10.0, 10.0), "on the hypotenuse")


def test_in_fill_of_a_rect_uses_the_half_open_boundary() raises:
    var p = Path()
    p.rect(10.0, 10.0, 20.0, 20.0)
    assert_true(p.in_fill(10.0, 20.0), "left edge is in")
    assert_true(p.in_fill(20.0, 10.0), "top edge is in")
    assert_true(not p.in_fill(30.0, 20.0), "right edge is out")
    assert_true(not p.in_fill(20.0, 30.0), "bottom edge is out")


def _pentagram(cx: Float64, cy: Float64, r: Float64) raises -> Path:
    # Five points around the circle, connected every second one, so
    # the center is wound twice.
    var p = Path()
    for i in range(5):
        var a = -pi / 2.0 + Float64(i) * 4.0 * pi / 5.0
        var x = cx + r * cos(a)
        var y = cy + r * sin(a)
        if i == 0:
            p.move_to(x, y)
        else:
            p.line_to(x, y)
    p.close()
    return p^


def test_in_fill_of_a_self_intersecting_star_depends_on_the_rule() raises:
    var p = _pentagram(50.0, 50.0, 40.0)
    # The center's winding number is 2: a hole under even-odd, solid
    # under nonzero.
    assert_true(not p.in_fill(50.0, 50.0, FillRule.EVEN_ODD), "even-odd hole")
    assert_true(p.in_fill(50.0, 50.0, FillRule.NONZERO), "nonzero solid")
    # A point inside the top tip is wound once, inside under both.
    assert_true(p.in_fill(50.0, 15.0, FillRule.EVEN_ODD), "tip, even-odd")
    assert_true(p.in_fill(50.0, 15.0, FillRule.NONZERO), "tip, nonzero")
    assert_true(not p.in_fill(50.0, 95.0, FillRule.NONZERO), "outside")


def test_in_stroke_of_a_line_and_its_caps() raises:
    # Width 4 on y = 20 from x 10 to 50: the band y 18..22.
    var p = _horizontal_line()
    assert_true(p.in_stroke(30.0, 21.0, 4.0, cap=LineCap.BUTT), "in the band")
    assert_true(
        not p.in_stroke(30.0, 23.0, 4.0, cap=LineCap.BUTT), "past the band"
    )
    # An open two-point path encloses nothing, so the same point is
    # not in the fill.
    assert_true(not p.in_fill(30.0, 21.0), "a line has no fill")
    # One pixel past the endpoint: only the overhanging caps reach it.
    assert_true(not p.in_stroke(51.0, 20.0, 4.0, cap=LineCap.BUTT), "butt")
    assert_true(p.in_stroke(51.0, 20.0, 4.0, cap=LineCap.SQUARE), "square")
    assert_true(p.in_stroke(51.0, 20.0, 4.0, cap=LineCap.ROUND), "round")
    # The cap's corner: 1.5 out and 1.5 down is inside the square cap
    # but sqrt(4.5) = 2.12 from the endpoint, past the round cap's 2.
    assert_true(
        p.in_stroke(51.5, 21.5, 4.0, cap=LineCap.SQUARE), "square corner"
    )
    assert_true(
        not p.in_stroke(51.5, 21.5, 4.0, cap=LineCap.ROUND), "round corner"
    )


def test_in_stroke_and_in_fill_of_a_rect_are_different_regions() raises:
    var p = Path()
    p.rect(10.0, 10.0, 20.0, 20.0)
    assert_true(p.in_fill(20.0, 20.0), "center is filled")
    assert_true(not p.in_stroke(20.0, 20.0, 2.0), "center is not stroked")
    assert_true(p.in_fill(10.5, 20.0), "just inside the edge: filled")
    assert_true(p.in_stroke(10.5, 20.0, 2.0), "and stroked")
    assert_true(not p.in_fill(9.5, 20.0), "just outside: not filled")
    assert_true(p.in_stroke(9.5, 20.0, 2.0), "but stroked")
    assert_true(not p.in_stroke(8.5, 20.0, 2.0), "past the stroke")


def test_in_stroke_of_a_dashed_line_misses_the_gaps() raises:
    var p = _horizontal_line()
    var dashes: List[Float64] = [10.0, 10.0]
    assert_true(p.in_stroke(15.0, 20.0, 4.0, dashes=dashes), "first dash")
    assert_true(not p.in_stroke(25.0, 20.0, 4.0, dashes=dashes), "gap")
    assert_true(p.in_stroke(35.0, 20.0, 4.0, dashes=dashes), "second dash")
    assert_true(not p.in_stroke(45.0, 20.0, 4.0, dashes=dashes), "last gap")


def test_in_stroke_of_a_corner_follows_the_join() raises:
    # The V from the stroke_bounds tests: the miter spike reaches
    # y = 6.39 above the apex, the bevel cut stops at 8.89, the round
    # join at 8.0. A point at y = 7.5 is inside only the miter.
    var p = _v_shape()
    assert_true(p.in_stroke(30.0, 7.5, 4.0, join=LineJoin.MITER), "miter")
    assert_true(not p.in_stroke(30.0, 7.5, 4.0, join=LineJoin.BEVEL), "bevel")
    assert_true(not p.in_stroke(30.0, 7.5, 4.0, join=LineJoin.ROUND), "round")
    # At y = 8.5 the round join reaches it (its top is 8.0) but the
    # bevel cut, at 8.89, does not; at 9.0 all three do.
    assert_true(p.in_stroke(30.0, 8.5, 4.0, join=LineJoin.ROUND), "round 8.5")
    assert_true(
        not p.in_stroke(30.0, 8.5, 4.0, join=LineJoin.BEVEL), "bevel 8.5"
    )
    assert_true(p.in_stroke(30.0, 9.0, 4.0, join=LineJoin.BEVEL), "bevel 9.0")
    assert_true(p.in_stroke(30.0, 9.0, 4.0, join=LineJoin.ROUND), "round 9.0")


def test_in_stroke_of_a_curve_follows_the_curve() raises:
    # The quad from the bounds test peaks at y = 10 (from bounds());
    # a width-2 stroke covers y 9..11 at x = 10 and nothing near the
    # control point at y = 20.
    var p = Path()
    p.move_to(0.0, 0.0)
    p.quad_curve_to(10.0, 20.0, 20.0, 0.0)
    assert_true(p.in_stroke(10.0, 10.5, 2.0), "on the apex")
    assert_true(not p.in_stroke(10.0, 12.0, 2.0), "past the apex")
    assert_true(not p.in_stroke(10.0, 20.0, 2.0), "the control point")


def test_in_stroke_of_degenerate_paths() raises:
    assert_true(not Path().in_stroke(5.0, 5.0, 4.0), "empty path")
    assert_true(not Path().in_fill(5.0, 5.0), "empty path fill")
    # A lone move_to is the one pixel the stroke sets there.
    var p = Path()
    p.move_to(5.0, 7.0)
    assert_true(p.in_stroke(5.2, 6.8, 4.0), "rounds to the pixel")
    assert_true(not p.in_stroke(6.0, 7.0, 4.0), "the next pixel over")


def test_stroke_bounds_of_degenerate_paths() raises:
    var b = Path().stroke_bounds(4.0)
    assert_equal(b[0], 0.0)
    assert_equal(b[3], 0.0)
    # A lone move_to strokes as one pixel; its box is the point.
    var p = Path()
    p.move_to(5.0, 7.0)
    _assert_box(p.stroke_bounds(4.0), 5.0, 7.0, 5.0, 7.0, 1e-9, "point")


def test_transformed_leaves_the_original_alone() raises:
    # It returns a new path precisely so the source can be reused.
    var t = Transform2D(2.0, 2.0, 10.0, 10.0)
    var p = Path()
    p.move_to(1.0, 1.0)
    p.line_to(5.0, 1.0)
    var moved = p.transformed(t)
    var original = _flat_points(p)
    assert_equal(original[0].x, 1.0, "the source path is unchanged")
    assert_equal(original[1].x, 5.0)
    var got = _flat_points(moved)
    assert_equal(got[0].x, 12.0, "while the copy is transformed")


def _assert_clipped_fill_matches_reference(
    clip_x: Int, clip_y: Int, clip_w: Int, clip_h: Int
) raises:
    """fill_path_aa under push_clip(clip rect) against the same fill
    unclipped: inside the clip every pixel matches, outside it every
    pixel is still the background.
    """
    var shape = Path()
    shape.move_to(10.0, 30.0)
    shape.cubic_curve_to(30.0, -10.0, 70.0, 70.0, 90.0, 30.0)
    shape.line_to(50.0, 58.0)
    shape.close()

    var reference = Canvas(100, 60, BG)
    fill_path_aa(reference, shape, FG)

    var clipped = Canvas(100, 60, BG)
    clipped.push_clip(clip_x, clip_y, clip_w, clip_h)
    fill_path_aa(clipped, shape, FG)
    clipped.pop_clip()

    for y in range(60):
        for x in range(100):
            var inside = (
                x >= clip_x
                and x < clip_x + clip_w
                and y >= clip_y
                and y < clip_y + clip_h
            )
            var want = reference.get_pixel(x, y) if inside else BG
            var got = clipped.get_pixel(x, y)
            if got.r != want.r or got.g != want.g or got.b != want.b:
                var at = "pixel " + String(x) + "," + String(y)
                assert_equal(got.r, want.r, at)
                assert_equal(got.g, want.g, at)
                assert_equal(got.b, want.b, at)


def test_fill_path_aa_under_a_clip_that_cuts_rows() raises:
    # Rows above and below the clip are skipped before their crossings
    # are swept, so the active edge list has to catch up when the
    # clip's first row arrives, mid-shape.
    _assert_clipped_fill_matches_reference(0, 20, 100, 20)


def test_fill_path_aa_under_a_clip_that_cuts_columns() raises:
    _assert_clipped_fill_matches_reference(30, 0, 40, 60)


def test_fill_path_aa_under_a_clip_past_the_canvas_edge() raises:
    # A clip rectangle that starts left of the canvas and runs past its
    # bottom: the per-row range is clamped to the canvas as well.
    _assert_clipped_fill_matches_reference(-10, 25, 50, 100)


def test_fill_path_aa_under_a_clip_missing_the_shape() raises:
    _assert_clipped_fill_matches_reference(0, 0, 100, 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
