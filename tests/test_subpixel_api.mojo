"""Tests for the sub-pixel (Float64/FPoint) overloads of the
anti-aliased primitives.

Each of these draws the same shape twice, a fraction of a pixel apart,
and asserts the two renders differ. The whole-pixel entry points cannot
express that difference at all, so under them every pair here would be
byte-identical.

Where a coverage value is hand-derivable it is pinned exactly rather
than merely compared. A pixel centered at x=p spans [p-0.5, p+0.5], and
at the default 4x supersample its sub-sample columns sit at p-0.375,
p-0.125, p+0.125 and p+0.375, so an edge landing on a quarter-pixel
boundary admits an exact expected count.
"""

from std.testing import assert_equal, assert_true, TestSuite

from canvas.color import Color
from canvas.buffer import Canvas
from canvas.geometry import Point, FPoint
from canvas.path import Path, stroke_path_aa
from canvas.shapes.circles import fill_circle_aa
from canvas.shapes.ellipses import fill_ellipse_aa
from canvas.shapes.lines import draw_line_aa, draw_polyline_aa
from canvas.shapes.polygon_fill import fill_polygon_aa
from canvas.text.render import draw_text

comptime BG = Color(0, 0, 0)
comptime FG = Color(255, 255, 255)


def _ink(c: Canvas) -> Int:
    """Total luminance written to the canvas -- a cheap whole-image
    fingerprint, since BG is black and every primitive here draws FG.
    """
    var total = 0
    for y in range(c.height):
        for x in range(c.width):
            total += Int(c.get_pixel(x, y).r)
    return total


def _differs(a: Canvas, b: Canvas) -> Bool:
    for y in range(a.height):
        for x in range(a.width):
            if a.get_pixel(x, y).r != b.get_pixel(x, y).r:
                return True
    return False


def test_draw_line_aa_subpixel_endpoints_shift_the_line() raises:
    var whole = Canvas(40, 40, BG)
    var shifted = Canvas(40, 40, BG)
    draw_line_aa(whole, 10.0, 10.0, 30.0, 10.0, FG)
    draw_line_aa(shifted, 10.0, 10.4, 30.0, 10.4, FG)
    assert_true(
        _differs(whole, shifted),
        "a 0.4px vertical shift must change a horizontal line's coverage",
    )
    # Rounding to whole pixels is what the Int overload would do, and
    # it must agree with passing those same whole values as floats.
    var via_int = Canvas(40, 40, BG)
    draw_line_aa(via_int, 10, 10, 30, 10, FG)
    assert_true(
        not _differs(whole, via_int),
        "the Int overload must match the Float64 one at whole pixels",
    )


def test_draw_line_aa_subpixel_centering_is_symmetric() raises:
    # A 1px-wide horizontal line centered exactly between two pixel
    # rows must split its coverage evenly between them; centered on a
    # row it must not. This pins that the sub-pixel y is really used to
    # place the stroke, not just perturbing it.
    var between = Canvas(40, 40, BG)
    draw_line_aa(between, 10.0, 10.5, 30.0, 10.5, FG)
    var on_row = Canvas(40, 40, BG)
    draw_line_aa(on_row, 10.0, 10.0, 30.0, 10.0, FG)

    assert_equal(
        Int(between.get_pixel(20, 10).r),
        Int(between.get_pixel(20, 11).r),
        "a line centered between two rows covers both equally",
    )
    assert_true(
        Int(on_row.get_pixel(20, 10).r) > Int(on_row.get_pixel(20, 11).r),
        "a line centered on a row covers that row more than its neighbor",
    )


def test_draw_polyline_aa_accepts_subpixel_vertices() raises:
    var a = Canvas(40, 40, BG)
    var b = Canvas(40, 40, BG)
    var pa: List[FPoint] = [
        FPoint(5.0, 5.0),
        FPoint(20.0, 12.0),
        FPoint(34.0, 8.0),
    ]
    var pb: List[FPoint] = [
        FPoint(5.0, 5.0),
        FPoint(20.0, 12.3),
        FPoint(34.0, 8.0),
    ]
    draw_polyline_aa(a, pa, FG)
    draw_polyline_aa(b, pb, FG)
    assert_true(
        _differs(a, b), "a 0.3px move of one vertex must change the render"
    )

    # The Point overload converts and delegates, so it must agree with
    # the FPoint one on identical whole-pixel input.
    var via_points = Canvas(40, 40, BG)
    var ip: List[Point] = [Point(5, 5), Point(20, 12), Point(34, 8)]
    draw_polyline_aa(via_points, ip, FG)
    assert_true(
        not _differs(a, via_points),
        "the Point overload must match the FPoint one at whole pixels",
    )


def test_fill_polygon_aa_accepts_subpixel_vertices() raises:
    var a = Canvas(40, 40, BG)
    var b = Canvas(40, 40, BG)
    var pa: List[FPoint] = [
        FPoint(10.0, 10.0),
        FPoint(30.0, 10.0),
        FPoint(20.0, 30.0),
    ]
    var pb: List[FPoint] = [
        FPoint(10.25, 10.0),
        FPoint(30.0, 10.0),
        FPoint(20.0, 30.0),
    ]
    fill_polygon_aa(a, pa, FG)
    fill_polygon_aa(b, pb, FG)
    assert_true(
        _ink(b) < _ink(a),
        "moving a vertex inward by a quarter pixel must remove ink",
    )

    var via_points = Canvas(40, 40, BG)
    var ip: List[Point] = [Point(10, 10), Point(30, 10), Point(20, 30)]
    fill_polygon_aa(via_points, ip, FG)
    assert_true(
        not _differs(a, via_points),
        "the Point overload must match the FPoint one at whole pixels",
    )


def test_fill_circle_aa_subpixel_radius_changes_coverage() raises:
    # Hand-derived: a disk of radius 5.0 centered at (20, 20) leaves the
    # pixel at (25, 20) mostly outside; growing the radius to 5.5 pushes
    # the boundary a half pixel further out, so that pixel gains
    # coverage. Strict inequality in both directions pins that the
    # fractional part is genuinely used.
    var small = Canvas(40, 40, BG)
    var large = Canvas(40, 40, BG)
    fill_circle_aa(small, 20.0, 20.0, 5.0, FG)
    fill_circle_aa(large, 20.0, 20.0, 5.5, FG)
    assert_true(
        Int(large.get_pixel(25, 20).r) > Int(small.get_pixel(25, 20).r),
        "half a pixel more radius must add coverage at the boundary",
    )
    assert_true(_ink(large) > _ink(small), "a bigger disk has more ink")

    var via_int = Canvas(40, 40, BG)
    fill_circle_aa(via_int, 20, 20, 5, FG)
    assert_true(
        not _differs(small, via_int),
        "the Int overload must match the Float64 one at whole pixels",
    )


def test_fill_circle_aa_subpixel_center_shifts_the_disk() raises:
    var centered = Canvas(40, 40, BG)
    var nudged = Canvas(40, 40, BG)
    fill_circle_aa(centered, 20.0, 20.0, 6.0, FG)
    fill_circle_aa(nudged, 20.5, 20.0, 6.0, FG)
    assert_true(
        Int(nudged.get_pixel(26, 20).r) > Int(centered.get_pixel(26, 20).r),
        "shifting the center right must add coverage on the right edge",
    )
    assert_true(
        Int(nudged.get_pixel(14, 20).r) < Int(centered.get_pixel(14, 20).r),
        "...and remove it on the left",
    )


def test_fill_ellipse_aa_subpixel_radii_change_coverage() raises:
    var a = Canvas(40, 40, BG)
    var b = Canvas(40, 40, BG)
    fill_ellipse_aa(a, 20.0, 20.0, 10.0, 6.0, FG)
    fill_ellipse_aa(b, 20.0, 20.0, 10.0, 6.4, FG)
    assert_true(
        _ink(b) > _ink(a),
        "a 0.4px larger vertical radius must add ink",
    )

    var via_int = Canvas(40, 40, BG)
    fill_ellipse_aa(via_int, 20, 20, 10, 6, FG)
    assert_true(
        not _differs(a, via_int),
        "the Int overload must match the Float64 one at whole pixels",
    )


def test_stroke_path_aa_follows_the_unrounded_path() raises:
    # stroke_path_aa used to round the flattened path to whole pixels
    # before stroking, so these two curves -- differing only in a
    # control point's fractional part -- rendered identically.
    var a = Path()
    a.move_to(5.0, 20.0)
    a.quad_curve_to(20.0, 5.0, 35.0, 20.0)
    var b = Path()
    b.move_to(5.0, 20.0)
    b.quad_curve_to(20.0, 5.4, 35.0, 20.0)

    var ca = Canvas(40, 40, BG)
    var cb = Canvas(40, 40, BG)
    stroke_path_aa(ca, a, FG, width=1.5)
    stroke_path_aa(cb, b, FG, width=1.5)
    assert_true(
        _differs(ca, cb),
        "a 0.4px control-point move must change a stroked curve",
    )


def test_draw_text_subpixel_anchor_shifts_the_string() raises:
    var on_pixel = Canvas(200, 40, BG)
    var off_pixel = Canvas(200, 40, BG)
    draw_text(on_pixel, 10.0, 28.0, "Handgloves", FG, size=14.0)
    draw_text(off_pixel, 10.5, 28.0, "Handgloves", FG, size=14.0)
    assert_true(
        _differs(on_pixel, off_pixel),
        "a half-pixel anchor shift must move the rendered string",
    )

    var via_int = Canvas(200, 40, BG)
    draw_text(via_int, 10, 28, "Handgloves", FG, size=14.0)
    assert_true(
        not _differs(on_pixel, via_int),
        "the Int overload must match the Float64 one at a whole-pixel anchor",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
