"""Tests for canvas/shapes/lines.mojo: exact pixel sets for known
inputs, verified against hand-traced runs of the same algorithms.
"""

from std.testing import assert_equal, assert_true, TestSuite
from std.math import sqrt

from canvas.color import Color
from canvas.buffer import Canvas
from canvas.geometry import Point
from canvas.shapes.dash import _is_dash_on
from canvas.shapes.lines import (
    draw_line,
    draw_line_aa,
    draw_polyline,
    draw_polygon,
    draw_polyline_aa,
    draw_polygon_aa,
)

comptime BG = Color(0, 0, 0)
comptime FG = Color(255, 255, 255)


def _assert_pixel(
    c: Canvas, x: Int, y: Int, expected: Color, label: String
) raises:
    var p = c.get_pixel(x, y)
    assert_equal(p.r, expected.r, label + " (r)")
    assert_equal(p.g, expected.g, label + " (g)")
    assert_equal(p.b, expected.b, label + " (b)")


def test_draw_line_horizontal() raises:
    var c = Canvas(5, 3, BG)
    draw_line(c, 0, 1, 4, 1, FG)
    for x in range(5):
        _assert_pixel(c, x, 1, FG, "row y=1")
    for x in range(5):
        _assert_pixel(c, x, 0, BG, "row y=0 untouched")
        _assert_pixel(c, x, 2, BG, "row y=2 untouched")


def test_draw_line_vertical() raises:
    var c = Canvas(3, 5, BG)
    draw_line(c, 1, 0, 1, 4, FG)
    for y in range(5):
        _assert_pixel(c, 1, y, FG, "col x=1")
    for y in range(5):
        _assert_pixel(c, 0, y, BG, "col x=0 untouched")
        _assert_pixel(c, 2, y, BG, "col x=2 untouched")


def test_draw_line_45_degree_diagonal() raises:
    var c = Canvas(5, 5, BG)
    draw_line(c, 0, 0, 4, 4, FG)
    for i in range(5):
        _assert_pixel(c, i, i, FG, "diagonal")
    # a representative off-diagonal point stays background
    _assert_pixel(c, 0, 4, BG, "off-diagonal untouched")


def test_draw_line_general_slope() raises:
    # (0,0) -> (4,2): hand-traced Bresenham stepping gives exactly
    # this staircase, not the naive nearest-integer-y guess.
    var c = Canvas(5, 3, BG)
    draw_line(c, 0, 0, 4, 2, FG)
    _assert_pixel(c, 0, 0, FG, "step 1")
    _assert_pixel(c, 1, 1, FG, "step 2")
    _assert_pixel(c, 2, 1, FG, "step 3")
    _assert_pixel(c, 3, 2, FG, "step 4")
    _assert_pixel(c, 4, 2, FG, "step 5")
    # points that were never on the traced path
    _assert_pixel(c, 1, 0, BG, "not on the line")
    _assert_pixel(c, 4, 0, BG, "not on the line")
    _assert_pixel(c, 0, 2, BG, "not on the line")


def test_draw_line_aa_horizontal_interior_is_fully_opaque() raises:
    var c = Canvas(9, 3, BG)
    draw_line_aa(c, 1, 1, 7, 1, FG)
    for x in range(2, 7):
        _assert_pixel(c, x, 1, FG, "deep interior, fully opaque")
    for x in range(9):
        _assert_pixel(c, x, 0, BG, "row above stays background")
        _assert_pixel(c, x, 2, BG, "row below stays background")


def test_draw_line_aa_round_cap_matches_hand_computed_value() raises:
    # By the clamped-projection distance formula, the horizontal line
    # (1,1)-(7,1) puts 14/16 of pixel (1,1)'s sub-samples inside the
    # round cap.
    var c = Canvas(9, 3, BG)
    draw_line_aa(c, 1, 1, 7, 1, FG)
    var cap = c.get_pixel(1, 1)
    assert_equal(cap.r, 223)
    assert_equal(cap.g, 223)
    assert_equal(cap.b, 223)
    # the round cap doesn't bulge far enough to reach the next column
    _assert_pixel(c, 0, 1, BG, "just past the cap")


def test_draw_line_aa_diagonal_matches_hand_computed_value() raises:
    # Hand-verified the same way for a non-axis-aligned segment:
    # (1,1)-(8,6), pixel (1,1) has 13/16 sub-samples covered.
    var c = Canvas(10, 10, BG)
    draw_line_aa(c, 1, 1, 8, 6, FG)
    var p = c.get_pixel(1, 1)
    assert_equal(p.r, 207)
    assert_equal(p.g, 207)
    assert_equal(p.b, 207)


def test_draw_line_aa_agrees_with_hard_edged_on_interior_pixels() raises:
    # fill_circle_aa's consistency check, for lines: deep-interior
    # pixels must land at the same coordinates in both versions. Not
    # the endpoints, which legitimately differ -- Bresenham's idealized
    # single pixel against the AA version's round cap.
    var hard = Canvas(9, 3, BG)
    draw_line(hard, 1, 1, 7, 1, FG)
    var aa = Canvas(9, 3, BG)
    draw_line_aa(aa, 1, 1, 7, 1, FG)
    for x in range(2, 7):
        var hard_pixel = hard.get_pixel(x, 1)
        if (
            hard_pixel.r == FG.r
            and hard_pixel.g == FG.g
            and hard_pixel.b == FG.b
        ):
            _assert_pixel(
                aa, x, 1, FG, "hard-edged interior pixel must match in AA"
            )


def test_draw_line_aa_respects_translucent_input_color() raises:
    # A fully-covered pixel must scale coverage by the caller's
    # color.a, not by a hardcoded 255: with alpha=128 it has to blend,
    # not render as the raw opaque color. Opaque-color tests can't
    # catch this at all -- coverage*255 == coverage*color.a there.
    var c = Canvas(9, 3, Color(0, 0, 0))
    draw_line_aa(c, 1, 1, 7, 1, Color(200, 0, 0, 128))
    # deep interior, fully covered -> single-blend value, not raw 200
    var p = c.get_pixel(4, 1)
    assert_equal(p.r, 100)
    assert_equal(p.g, 0)
    assert_equal(p.b, 0)


def test_draw_polyline_connects_segments() raises:
    # An "L": (1,1) -> (1,4) -> (4,4)
    var c = Canvas(6, 6, BG)
    var pts = List[Point]()
    pts.append(Point(1, 1))
    pts.append(Point(1, 4))
    pts.append(Point(4, 4))
    draw_polyline(c, pts, FG)

    for y in range(1, 5):
        _assert_pixel(c, 1, y, FG, "vertical segment")
    for x in range(1, 5):
        _assert_pixel(c, x, 4, FG, "horizontal segment")
    _assert_pixel(c, 4, 1, BG, "not on either segment")


def test_draw_polyline_does_not_double_blend_joints() raises:
    # Hand-verified: at the shared corner (1,4), a naive segment-by-
    # segment draw would blend the translucent color twice (once as
    # segment 1's endpoint, once as segment 2's start). Single-blend
    # value: r = (200*128 + 0*127) // 255 = 100.
    var c = Canvas(6, 6, Color(0, 0, 0))
    var pts = List[Point]()
    pts.append(Point(1, 1))
    pts.append(Point(1, 4))
    pts.append(Point(4, 4))
    draw_polyline(c, pts, Color(200, 0, 0, 128))

    var corner = c.get_pixel(1, 4)
    assert_equal(corner.r, 100)
    assert_equal(corner.g, 0)
    assert_equal(corner.b, 0)


def test_draw_polyline_single_and_empty() raises:
    var c = Canvas(3, 3, BG)
    var one = List[Point]()
    one.append(Point(1, 1))
    draw_polyline(c, one, FG)
    _assert_pixel(c, 1, 1, FG, "single point still plots")

    var c2 = Canvas(3, 3, BG)
    var empty = List[Point]()
    draw_polyline(c2, empty, FG)
    _assert_pixel(c2, 1, 1, BG, "empty list draws nothing")


def test_draw_polygon_closes_the_shape() raises:
    # A right triangle: (1,1) -> (4,1) -> (1,4) -> back to (1,1)
    var c = Canvas(6, 6, BG)
    var tri = List[Point]()
    tri.append(Point(1, 1))
    tri.append(Point(4, 1))
    tri.append(Point(1, 4))
    draw_polygon(c, tri, FG)

    for x in range(1, 5):
        _assert_pixel(c, x, 1, FG, "top edge")
    for y in range(1, 5):
        _assert_pixel(c, 1, y, FG, "closing edge (left side)")
    _assert_pixel(c, 3, 2, FG, "diagonal edge")
    _assert_pixel(c, 2, 3, FG, "diagonal edge")
    _assert_pixel(c, 4, 4, BG, "interior, unfilled -- outline only")


def test_draw_polygon_does_not_double_blend_any_vertex() raises:
    # Both joint categories, which are different code paths: (1,1) is
    # the closing vertex, shared between the first segment's start and
    # the closing segment's end, while (4,1) is an ordinary interior
    # joint between consecutive segments in the main loop.
    var c = Canvas(6, 6, Color(0, 0, 0))
    var tri = List[Point]()
    tri.append(Point(1, 1))
    tri.append(Point(4, 1))
    tri.append(Point(1, 4))
    draw_polygon(c, tri, Color(200, 0, 0, 128))

    var closing_vertex = c.get_pixel(1, 1)
    assert_equal(closing_vertex.r, 100)
    assert_equal(closing_vertex.g, 0)
    assert_equal(closing_vertex.b, 0)

    var interior_joint = c.get_pixel(4, 1)
    assert_equal(interior_joint.r, 100)
    assert_equal(interior_joint.g, 0)
    assert_equal(interior_joint.b, 0)


def test_draw_polyline_aa_joint_has_no_double_blend_hazard() raises:
    # An L-shape, same shape as the hard-edged joint test but through
    # the AA multi-segment coverage path. Two properties at once:
    #   1. Deep-interior, fully-covered points must show the
    #      single-blend value (100) -- also the check that coverage is
    #      scaled by color.a rather than a hardcoded 255, which would
    #      show up here as raw, unblended 200.
    #   2. The joint pixel (2,5), hand-verified via a 16-sample trace
    #      of the minimum-distance-to-either-segment test: 15/16
    #      covered -> alpha 120 -> single-blend value 94. A naive
    #      per-segment draw_line_aa loop would double-blend here.
    var c = Canvas(8, 8, Color(0, 0, 0))
    var pts = List[Point]()
    pts.append(Point(2, 2))
    pts.append(Point(2, 5))
    pts.append(Point(5, 5))
    draw_polyline_aa(c, pts, Color(200, 0, 0, 128))

    var interior_v = c.get_pixel(2, 3)
    assert_equal(interior_v.r, 100)
    var interior_h = c.get_pixel(4, 5)
    assert_equal(interior_h.r, 100)

    var joint = c.get_pixel(2, 5)
    assert_equal(joint.r, 94)
    assert_equal(joint.g, 0)
    assert_equal(joint.b, 0)

    _assert_pixel(c, 0, 0, BG, "far corner untouched")


def test_draw_polygon_aa_closing_vertex_has_no_double_blend_hazard() raises:
    # Same two properties as the polyline AA test, for the closing
    # vertex specifically: (2,2) hand-verified via the same
    # minimum-distance trace to 94.
    var c = Canvas(8, 8, Color(0, 0, 0))
    var tri = List[Point]()
    tri.append(Point(2, 2))
    tri.append(Point(5, 2))
    tri.append(Point(2, 5))
    draw_polygon_aa(c, tri, Color(200, 0, 0, 128))

    var interior_edge = c.get_pixel(3, 2)
    assert_equal(interior_edge.r, 100)

    var closing_vertex = c.get_pixel(2, 2)
    assert_equal(closing_vertex.r, 94)
    assert_equal(closing_vertex.g, 0)
    assert_equal(closing_vertex.b, 0)

    _assert_pixel(c, 7, 7, BG, "far corner untouched")


def test_draw_line_dashed_matches_hand_traced_on_off_pixels() raises:
    # Horizontal line: each Bresenham step is a pure x step (distance
    # +1.0 per pixel), so pixel x's distance is exactly x -- no
    # diagonal sqrt(2) steps to complicate hand-tracing. Pattern
    # [3, 2] over x=0..9: on 0,1,2, off 3,4, on 5,6,7, off 8,9.
    var dashes: List[Float64] = [3.0, 2.0]
    var c = Canvas(10, 1, BG)
    draw_line(c, 0, 0, 9, 0, FG, dashes)

    var on_xs: List[Int] = [0, 1, 2, 5, 6, 7]
    var off_xs: List[Int] = [3, 4, 8, 9]
    for x in on_xs:
        _assert_pixel(c, x, 0, FG, "expected on")
    for x in off_xs:
        _assert_pixel(c, x, 0, BG, "expected off")


def test_draw_line_no_dashes_is_unaffected() raises:
    # The default (empty dashes) must draw a fully solid line -- the
    # dash machinery inside _draw_line_core has to be a complete no-op
    # when no pattern is passed.
    var c = Canvas(10, 1, BG)
    draw_line(c, 0, 0, 9, 0, FG)
    for x in range(10):
        _assert_pixel(c, x, 0, FG, "solid line, no gaps")


def test_draw_polyline_dash_phase_carries_across_the_joint() raises:
    # An L-shape, (0,0)->(4,0)->(4,4), pattern [3,2] (period 5).
    # Segment 0 ends at (4,0) with accumulated distance 4, an off pixel
    # since 4 is in [3,5). Segment 1 must carry that 4 forward rather
    # than restart at 0, and the two diverge at exactly (4,3): carried,
    # distance is 4+3=7, wrapping to 2 and on; reset, it's 3 and off.
    # That one pixel is what distinguishes carry-forward from a
    # per-segment reset.
    var dashes: List[Float64] = [3.0, 2.0]
    var points: List[Point] = [Point(0, 0), Point(4, 0), Point(4, 4)]
    var c = Canvas(10, 10, BG)
    draw_polyline(c, points, FG, dashes)

    _assert_pixel(c, 4, 3, FG, "on if phase carried, off if reset per segment")
    _assert_pixel(
        c, 4, 4, BG, "distance 8 -> off, confirms the carry continues correctly"
    )


def test_draw_line_aa_dashed_has_background_gaps() raises:
    # Qualitative, unlike the hand-computed-coverage tests above: that
    # dashing creates gaps in an AA stroke at all. width=1 keeps this
    # close enough to the hard-edged case that a point well inside an
    # off span is unambiguously background.
    var dashes: List[Float64] = [3.0, 2.0]
    var c = Canvas(10, 3, BG)
    draw_line_aa(c, 0, 1, 9, 1, FG, dashes=dashes)

    _assert_pixel(c, 1, 1, FG, "well inside an on-run")
    _assert_pixel(c, 4, 1, BG, "well inside an off-run")


def test_draw_polyline_aa_dashed_has_background_gaps() raises:
    var dashes: List[Float64] = [3.0, 2.0]
    var points: List[Point] = [Point(0, 1), Point(9, 1)]
    var c = Canvas(10, 3, BG)
    draw_polyline_aa(c, points, FG, dashes=dashes)

    _assert_pixel(c, 1, 1, FG, "well inside an on-run")
    _assert_pixel(c, 4, 1, BG, "well inside an off-run")


def _brute_force_stroke_polyline_aa(
    mut canvas: Canvas,
    points: List[Point],
    color: Color,
    width: Float64,
    supersample: Int,
    closed: Bool,
    dashes: List[Float64],
    dash_offset: Float64,
) raises:
    """Naive reference for _draw_polyline_core_aa's column-bucket
    optimization: for every pixel and sample, tests distance to EVERY
    segment, with no row- or column-level pre-filtering. Same
    per-sample "minimum distance across every on-dash candidate" math
    and the same coverage-to-alpha blend, without the bucket
    bookkeeping -- so a divergence means the optimization changed a
    result, not just the speed.
    """
    var count = len(points)
    if count == 0:
        return
    if count == 1:
        canvas.set_pixel(points[0].x, points[0].y, color)
        return

    var num_segments = count if closed else count - 1
    var half_width = width / 2.0
    var hw2 = half_width * half_width
    var n = supersample
    var total_samples = n * n
    var step = 1.0 / Float64(n)
    var pad = Int(half_width) + 2

    var seg_start_distance = List[Float64](capacity=num_segments)
    var seg_length = List[Float64](capacity=num_segments)
    var running_distance = 0.0
    for seg in range(num_segments):
        var sa = points[seg]
        var sb = points[(seg + 1) % count]
        var sdx = Float64(sb.x - sa.x)
        var sdy = Float64(sb.y - sa.y)
        var slen = sqrt(sdx * sdx + sdy * sdy)
        seg_start_distance.append(running_distance)
        seg_length.append(slen)
        running_distance += slen

    var min_x = points[0].x
    var max_x = points[0].x
    var min_y = points[0].y
    var max_y = points[0].y
    for i in range(1, count):
        if points[i].x < min_x:
            min_x = points[i].x
        if points[i].x > max_x:
            max_x = points[i].x
        if points[i].y < min_y:
            min_y = points[i].y
        if points[i].y > max_y:
            max_y = points[i].y
    min_x -= pad
    max_x += pad
    min_y -= pad
    max_y += pad

    for py in range(min_y, max_y + 1):
        for px in range(min_x, max_x + 1):
            var covered = 0
            for sy in range(n):
                var sample_y = Float64(py) + (Float64(sy) + 0.5) * step - 0.5
                for sx in range(n):
                    var sample_x = (
                        Float64(px) + (Float64(sx) + 0.5) * step - 0.5
                    )
                    var min_dist2 = -1.0
                    for seg in range(num_segments):
                        var a = points[seg]
                        var b = points[(seg + 1) % count]
                        var fx0 = Float64(a.x)
                        var fy0 = Float64(a.y)
                        var fx1 = Float64(b.x)
                        var fy1 = Float64(b.y)
                        var ldx = fx1 - fx0
                        var ldy = fy1 - fy0
                        var len2 = ldx * ldx + ldy * ldy
                        var t: Float64
                        if len2 == 0.0:
                            t = 0.0
                        else:
                            t = (
                                (sample_x - fx0) * ldx + (sample_y - fy0) * ldy
                            ) / len2
                            if t < 0.0:
                                t = 0.0
                            elif t > 1.0:
                                t = 1.0
                        var closest_x = fx0 + t * ldx
                        var closest_y = fy0 + t * ldy
                        var ddx = sample_x - closest_x
                        var ddy = sample_y - closest_y
                        var d2 = ddx * ddx + ddy * ddy
                        if d2 <= hw2:
                            var sample_distance = (
                                seg_start_distance[seg] + t * seg_length[seg]
                            )
                            if _is_dash_on(
                                sample_distance, dashes, dash_offset
                            ):
                                if min_dist2 < 0.0 or d2 < min_dist2:
                                    min_dist2 = d2
                    if min_dist2 >= 0.0:
                        covered += 1
            if covered > 0:
                var alpha = UInt8(
                    Int(
                        Float64(covered)
                        / Float64(total_samples)
                        * Float64(color.a)
                        + 0.5
                    )
                )
                canvas.set_pixel(
                    px, py, Color(color.r, color.g, color.b, alpha)
                )


def _jagged_stress_points() -> List[Point]:
    # An adversarial shape: consecutive points jump a large fraction of
    # the y-range every step (i*37 mod 101, a period-101 sequence that
    # looks random but keeps this deterministic). That's what makes a
    # row's candidate list span most of its column range, where a
    # bucket-indexing bug shows up -- a smooth monotonic polyline would
    # hide one.
    var points = List[Point](capacity=97)
    for i in range(97):
        var x = Int(Float64(i) / 96.0 * 90.0)
        var y = 50 + Int(180.0 * ((Float64((i * 37) % 101) / 101.0) - 0.5))
        points.append(Point(x, y))
    return points^


def test_draw_polyline_aa_matches_a_brute_force_reference_on_a_jagged_stress_path() raises:
    var points = _jagged_stress_points()
    var canvas = Canvas(100, 140, Color(255, 255, 255))
    draw_polyline_aa(canvas, points, Color(0, 0, 0), width=2.0)

    var reference = Canvas(100, 140, Color(255, 255, 255))
    _brute_force_stroke_polyline_aa(
        reference, points, Color(0, 0, 0), 2.0, 4, False, List[Float64](), 0.0
    )

    for i in range(len(canvas.pixels)):
        assert_equal(canvas.pixels[i], reference.pixels[i])


def test_draw_polygon_aa_matches_a_brute_force_reference_on_a_jagged_stress_path() raises:
    # The same stress shape closed, so the wraparound segment
    # (points[96] -> points[0]) runs through both paths.
    var points = _jagged_stress_points()
    var canvas = Canvas(100, 140, Color(255, 255, 255))
    draw_polygon_aa(canvas, points, Color(0, 0, 0), width=2.0)

    var reference = Canvas(100, 140, Color(255, 255, 255))
    _brute_force_stroke_polyline_aa(
        reference, points, Color(0, 0, 0), 2.0, 4, True, List[Float64](), 0.0
    )

    for i in range(len(canvas.pixels)):
        assert_equal(canvas.pixels[i], reference.pixels[i])


def test_draw_polyline_aa_dashed_matches_a_brute_force_reference_on_a_jagged_stress_path() raises:
    # The stress shape dashed, so per-candidate, per-sample dash state
    # still agrees with the reference once buckets skip most
    # segments.
    var points = _jagged_stress_points()
    var dashes: List[Float64] = [4.0, 3.0]
    var canvas = Canvas(100, 140, Color(255, 255, 255))
    draw_polyline_aa(canvas, points, Color(0, 0, 0), width=2.0, dashes=dashes)

    var reference = Canvas(100, 140, Color(255, 255, 255))
    _brute_force_stroke_polyline_aa(
        reference, points, Color(0, 0, 0), 2.0, 4, False, dashes, 0.0
    )

    for i in range(len(canvas.pixels)):
        assert_equal(canvas.pixels[i], reference.pixels[i])


def test_dashed_stroke_has_butt_ends_not_round_ones() raises:
    # A dash piece is a rectangle, not a stadium. The coverage test is
    # on the *projection* of a sample onto the segment, so a point past
    # a dash's end is not drawn however close it is to the last drawn
    # point -- dash ends are butt, and only the segment's own endpoints
    # round off.
    #
    # Rounding every dash end instead extends each piece by half a
    # width at both ends, which for a [5, 3] pattern at width 2 closes
    # the gaps almost entirely. That is what this pins: the gap has to
    # survive.
    var dashes: List[Float64] = [5.0, 3.0]
    var c = Canvas(40, 9, BG)
    draw_line_aa(c, 2.0, 4.0, 34.0, 4.0, FG, 2.0, 4, dashes, 0.0)

    # First dash runs from x=2; the gap that follows must contain at
    # least one completely undrawn column.
    var blank = 0
    for x in range(7, 11):
        if c.get_pixel(x, 4).r == BG.r:
            blank += 1
    assert_true(
        blank > 0,
        "the gap between dashes must contain an undrawn column",
    )


def test_stroke_matches_brute_force_on_short_segments() raises:
    # The jagged stress paths above use long segments. A flattened
    # curve does not -- it is hundreds of segments shorter than the
    # stroke is wide, and that is a different case: a joint's round
    # disk is only covered by its two adjoining quads when both of them
    # reach at least half a width back from it. Skipping the disk
    # without checking that leaves a notch on every tight joint, which
    # no long-segment test can see.
    var points = List[Point](capacity=120)
    for i in range(120):
        var t = Float64(i) / 119.0
        var x = 6 + Int(t * 88.0)
        var y = 70 + Int(45.0 * (1.0 - 2.0 * t) * (1.0 - 2.0 * t))
        points.append(Point(x, y))

    var canvas = Canvas(100, 140, Color(255, 255, 255))
    draw_polyline_aa(canvas, points, Color(0, 0, 0), width=3.0)

    var reference = Canvas(100, 140, Color(255, 255, 255))
    _brute_force_stroke_polyline_aa(
        reference, points, Color(0, 0, 0), 3.0, 4, False, List[Float64](), 0.0
    )
    for i in range(len(canvas.pixels)):
        assert_equal(canvas.pixels[i], reference.pixels[i])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
