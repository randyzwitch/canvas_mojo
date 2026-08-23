"""Tests for path.mojo: Path building, curve flattening, and the
fill_path/stroke_path/stroke_path_aa entry points.
"""

from std.math import cos, pi, sin, sqrt
from std.testing import assert_equal, assert_true, assert_raises, TestSuite

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas
from canvas_mojo.geometry import Point
from canvas_mojo.gradient import LinearGradient, RadialGradient
from canvas_mojo.fill_rule import FillRule
from canvas_mojo.shapes.arcs import fill_arc
from canvas_mojo.shapes.polygon_fill import fill_polygon, fill_polygon_aa
from canvas_mojo.path import (
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


def _assert_pixel(c: Canvas, x: Int, y: Int, expected: Color, label: String) raises:
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
    # Independently computed by hand (De Casteljau / the standard
    # quadratic Bezier formula) before trusting the code's own output.
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
    # there). (7.5, 2.5) rounds (half-away-from-zero) to (8, 3).
    var p = Path()
    p.move_to(0.0, 0.0)
    p.quad_curve_to(10.0, 0.0, 10.0, 10.0)
    var subpaths = _flatten(p)
    assert_equal(len(subpaths), 1)
    ref pts = subpaths[0].points
    assert_equal(len(pts), 17)  # start point + 16 flattened curve steps
    assert_equal(pts[8].x, 8)
    assert_equal(pts[8].y, 3)
    # curve's actual endpoint must be exact, not just close
    assert_equal(pts[16].x, 10)
    assert_equal(pts[16].y, 10)


def test_flatten_cubic_curve_passes_through_hand_derived_midpoint() raises:
    var p = Path()
    p.move_to(0.0, 0.0)
    p.cubic_curve_to(0.0, 10.0, 10.0, 10.0, 10.0, 0.0)
    var subpaths = _flatten(p)
    ref pts = subpaths[0].points
    assert_equal(len(pts), 17)
    assert_equal(pts[8].x, 5)
    assert_equal(pts[8].y, 8)  # 7.5 rounds up (half-away-from-zero)
    assert_equal(pts[16].x, 10)
    assert_equal(pts[16].y, 0)


def test_flatten_arc_to_matches_hand_derived_quarter_circle() raises:
    # Center (0, 0), radius 10, start_angle=0 -> end_angle=pi/2: a
    # quarter circle from (10, 0) to (0, 10) -- both endpoints exact,
    # independently hand-derived (r*cos(0)=10, r*sin(0)=0; r*cos(pi/2)
    # ~= 0, r*sin(pi/2) ~= 10, both rounding cleanly). arc_to's own
    # flattening reuses canvas_mojo.shapes.arcs' _arc_points, so the arc's own
    # start point (already present via move_to) must NOT be duplicated
    # -- see arc_to's own docstring.
    var p = Path()
    p.move_to(10.0, 0.0)
    p.arc_to(0.0, 0.0, 10.0, 0.0, pi / 2.0)
    var subpaths = _flatten(p)
    assert_equal(len(subpaths), 1)
    ref pts = subpaths[0].points
    # _arc_points's own step count: max(4, Int(radius * span)) ==
    # max(4, Int(10 * pi/2)) == 15 steps -> 16 sampled points (steps+1,
    # index 0 == the arc's own start). arc_to's flatten branch skips
    # that index-0 duplicate (already present via move_to below), so
    # the sub-path holds move_to's own point plus arc_points[1:] --
    # 1 + 15 == 16, not 17. A wrong count here would mean the
    # duplicate-skip silently broke.
    assert_equal(len(pts), 16)
    assert_equal(pts[0].x, 10)
    assert_equal(pts[0].y, 0)
    var last = pts[len(pts) - 1]
    assert_equal(last.x, 0)
    assert_equal(last.y, 10)
    # every intermediate sample must be within a pixel of the circle
    # itself (radius 10, centered at origin) -- confirms real curved
    # sampling happened, not just "start and end points, straight line
    # between" (which would also pass a start/end-only check).
    for i in range(1, len(pts) - 1):
        var p_i = pts[i]
        var dist = sqrt(Float64(p_i.x * p_i.x + p_i.y * p_i.y))
        assert_true(abs(dist - 10.0) < 1.0, "intermediate arc sample stays on the circle")


def test_arc_to_updates_current_point_to_the_arc_end() raises:
    # A line_to() right after arc_to() must start exactly where the
    # arc left off (its own end point), not the arc's own center or
    # start -- confirms arc_to's own _current_x/_current_y bookkeeping
    # (path.mojo), the same contract line_to/quad_curve_to/
    # cubic_curve_to already have.
    var p = Path()
    p.move_to(10.0, 0.0)
    p.arc_to(0.0, 0.0, 10.0, 0.0, pi / 2.0)
    p.line_to(20.0, 20.0)
    var subpaths = _flatten(p)
    ref pts = subpaths[0].points
    var last = pts[len(pts) - 1]
    assert_equal(last.x, 20)
    assert_equal(last.y, 20)
    var before_last = pts[len(pts) - 2]
    assert_equal(before_last.x, 0)
    assert_equal(before_last.y, 10)


def test_fill_path_arc_to_matches_fill_arc_for_a_wedge() raises:
    # arc_to's own flattening reuses the identical _arc_points helper
    # fill_arc itself samples through, so a move_to(arc start) ->
    # arc_to(...) -> line_to(center) -> close() wedge traces the exact
    # same cyclic edge list fill_arc's own fill_polygon call does
    # (arc_points[0] -> ... -> arc_points[-1] -> center ->
    # arc_points[0]), just starting from a different point around the
    # same loop -- fill_path's crossing scan is rotation-invariant, so
    # the two must fill byte-identical, the same parity relationship
    # test_fill_path_matches_fill_polygon_for_a_simple_triangle above
    # confirms for straight edges.
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
    # Same wedge as test_fill_path_arc_to_matches_fill_arc_for_a_wedge
    # above, through fill_path_aa instead of fill_path -- not a byte-
    # identical parity test against fill_arc_aa this time: fill_arc_aa
    # samples an analytic "within radius AND within angle span" test
    # directly (see its own docstring), a genuinely different algorithm
    # from fill_path_aa's flattened-boundary point-in-polygon
    # supersampling, so the two don't agree pixel-for-pixel right at
    # the edge the way the hard-edged pair does. What must still hold,
    # confirmed directly rather than assumed: full coverage deep
    # inside the wedge, zero coverage clearly outside it, and a real
    # blended (neither pure BG nor pure FG) pixel exactly on the arc's
    # own boundary -- proof AA supersampling actually ran on a curved
    # edge, not just a straight one.
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

    _assert_pixel(c, Int(cx) + 5, Int(cy) + 5, FG, "deep inside the wedge -- full coverage")
    _assert_pixel(c, Int(cx) - 10, Int(cy) - 10, BG, "opposite quadrant -- clearly outside, zero coverage")

    # (cx + r*cos(pi/4), cy + r*sin(pi/4)) sits exactly on the arc's
    # own boundary -- hand-derived via the same formula _arc_points
    # itself uses, not guessed.
    var edge_x = Int(cx + radius * cos(pi / 4.0))
    var edge_y = Int(cy + radius * sin(pi / 4.0))
    var edge = c.get_pixel(edge_x, edge_y)
    assert_true(edge.r > 0 and edge.r < 255, "on the arc boundary -- real partial coverage, neither pure BG nor pure FG")


def test_stroke_path_aa_draws_along_an_open_arc_to_segment() raises:
    # Same quarter-circle as the flatten test above, left open (no
    # close()) -- confirms stroke_path_aa (draw_polyline_aa under the
    # hood, see stroke_path_aa's own docstring) actually traces the
    # curved edge itself: a point exactly on the arc (same pi/4
    # boundary point as the fill_path_aa test above) picks up real
    # stroke coverage, while a point well clear of the curve (near the
    # wedge's own center, nowhere close to any drawn segment) stays
    # untouched background.
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
    assert_true(edge.r > 0, "on the arc's own curve -- picks up real stroke coverage")
    _assert_pixel(c, Int(cx), Int(cy), BG, "wedge center -- nowhere near the stroked curve, untouched")


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
    # fill_path's scanline algorithm is a direct generalization of
    # fill_polygon's own -- for a single simple-line (no-curve)
    # sub-path, the two must produce byte-identical output.
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
    # Same parity relationship test_fill_path_matches_fill_polygon_
    # for_a_simple_triangle above confirms for the hard-edged pair --
    # fill_path_aa's supersampled coverage test is a direct
    # generalization of fill_polygon_aa's own, so for a single
    # simple-line sub-path the two must produce byte-identical output,
    # including the antialiased edge pixels, not just the interior.
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
    # Same shape as test_fill_path_punches_a_hole_with_a_second_
    # subpath above, through the AA entry point instead -- both test
    # points sit deep inside their respective region (full coverage in
    # the ring, zero coverage in the hole), so this holds even without
    # hand-computing partial-coverage alpha values: hole-punching must
    # still work when _point_in_subpaths (not the discrete
    # _row_crossings) is what combines the two sub-paths.
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


def test_point_in_subpaths_nonzero_fills_the_overlap_of_same_direction_subpaths() raises:
    # The continuous-membership analog of test_fill_path_even_odd_
    # leaves_a_hole/test_fill_path_nonzero_fills_the_overlap above --
    # same two overlapping same-direction squares, checked directly
    # against _point_in_subpaths (what fill_path_aa's supersampling
    # actually calls) rather than through rendered pixels, confirming
    # the fill_rule divergence holds at the continuous level too, not
    # only for the discrete per-row scan.
    var p = Path()
    _square_subpath(p, 0.0, 0.0, 20.0, 20.0)
    _square_subpath(p, 10.0, 10.0, 30.0, 30.0)
    var subpaths = _flatten(p)

    assert_true(_point_in_subpaths(subpaths, 5.0, 5.0, FillRule.EVEN_ODD))
    assert_true(_point_in_subpaths(subpaths, 5.0, 5.0, FillRule.NONZERO))
    assert_true(_point_in_subpaths(subpaths, 25.0, 25.0, FillRule.EVEN_ODD))
    assert_true(_point_in_subpaths(subpaths, 25.0, 25.0, FillRule.NONZERO))
    assert_true(not _point_in_subpaths(subpaths, 15.0, 15.0, FillRule.EVEN_ODD))  # hole
    assert_true(_point_in_subpaths(subpaths, 15.0, 15.0, FillRule.NONZERO))  # solid


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
    # Same gradient and hand-derived midpoint value as
    # test_gradient.mojo's own color_at test -- confirms
    # fill_path_gradient queries color_at per pixel, the same as
    # fill_rect_gradient's own equivalent test.
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
    # Same center/radius and hand-derived exact-distance point as
    # test_gradient.mojo's own radial Pythagorean-triple test --
    # confirms fill_path_radial_gradient queries color_at per pixel,
    # the same as fill_path_gradient's own equivalent test above.
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
    _assert_pixel(c, 3, 4, Color(255, 255, 255), "exact radius (3-4-5 triangle) -> last stop's color")


def _square_subpath(mut p: Path, x0: Float64, y0: Float64, x1: Float64, y1: Float64) raises:
    p.move_to(x0, y0)
    p.line_to(x1, y0)
    p.line_to(x1, y1)
    p.line_to(x0, y1)
    p.close()


def test_fill_path_even_odd_leaves_a_hole_where_same_direction_subpaths_overlap() raises:
    # Two squares, (0,0)-(20,20) and (10,10)-(30,30), both traced in
    # the same rotational direction, as two sub-paths of ONE path --
    # independently traced by hand before trusting this: under
    # EVEN_ODD (the default), the overlap region x=[10,20), y=[10,20)
    # has been crossed twice, so it's "outside" again -- a hole
    # appears exactly there, even though both squares individually
    # would fill it.
    var p = Path()
    _square_subpath(p, 0.0, 0.0, 20.0, 20.0)
    _square_subpath(p, 10.0, 10.0, 30.0, 30.0)

    var c = Canvas(30, 30, BG)
    fill_path(c, p, FG, fill_rule=FillRule.EVEN_ODD)

    _assert_pixel(c, 5, 5, FG, "square A only")
    _assert_pixel(c, 25, 25, FG, "square B only")
    _assert_pixel(c, 15, 15, BG, "overlap region -- a hole under EVEN_ODD")


def test_fill_path_nonzero_fills_the_overlap_of_same_direction_subpaths_solid() raises:
    # Identical shape to the EVEN_ODD test above, only the fill rule
    # differs -- confirms fill_rule actually changes the result on the
    # same input, not just that each rule independently seems
    # reasonable. NONZERO's signed winding reaches 2 (not 0) in the
    # overlap, since both squares wind the same direction -- nonzero,
    # so filled, no hole.
    var p = Path()
    _square_subpath(p, 0.0, 0.0, 20.0, 20.0)
    _square_subpath(p, 10.0, 10.0, 30.0, 30.0)

    var c = Canvas(30, 30, BG)
    fill_path(c, p, FG, fill_rule=FillRule.NONZERO)

    _assert_pixel(c, 5, 5, FG, "square A only")
    _assert_pixel(c, 25, 25, FG, "square B only")
    _assert_pixel(c, 15, 15, FG, "overlap region -- solid under NONZERO, no hole")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
