"""Tests for canvas/aa_area.mojo, the exact-area rasterizer behind
every `FillRule.NONZERO` anti-aliased fill and clip mask.

The sweep's 4x4 sampling can only report coverage in sixteenths, so
the checks here are shapes whose exact coverage is known and is not a
multiple of 1/16 (a half-pixel triangle, a rectangle with quarter-pixel
edges), a shallow edge that has to produce more than 17 distinct
levels, and the nonzero union/cancellation semantics the sweep already
defines, which the accumulation has to reproduce.
"""

from std.testing import assert_equal, assert_true, TestSuite

from canvas.buffer import Canvas
from canvas.color import Color
from canvas.fill_rule import FillRule
from canvas.geometry import FPoint
from canvas.path import Path, fill_path_aa
from canvas.shapes.lines import draw_line_aa
from canvas.shapes.polygon_fill import fill_polygon_aa

comptime BG = Color(255, 255, 255)
comptime INK = Color(0, 0, 0)


def _alpha_of(c: Canvas, x: Int, y: Int) -> Int:
    """The effective alpha black ink landed with, from the red channel
    of a pixel blended onto white: 255 - r."""
    return 255 - Int(c.get_pixel(x, y).r)


def _assert_near(got: Int, want: Int, tol: Int, label: String) raises:
    var d = got - want
    if d < 0:
        d = -d
    assert_true(
        d <= tol,
        label + ": got " + String(got) + ", want " + String(want),
    )


def test_half_pixel_triangle_is_half_covered() raises:
    # The triangle (0,0)-(1,0)-(0,1) inside pixel (0, 0) covers exactly
    # half of it. The sweep's 4x4 grid reports 6/16; exact area says
    # 128.
    var c = Canvas(4, 4, BG)
    var p = Path()
    p.move_to(0.0, 0.0)
    p.line_to(1.0, 0.0)
    p.line_to(0.0, 1.0)
    p.close()
    fill_path_aa(c, p, INK, FillRule.NONZERO)
    _assert_near(_alpha_of(c, 0, 0), 128, 1, "half pixel")
    assert_equal(_alpha_of(c, 1, 0), 0)
    assert_equal(_alpha_of(c, 0, 1), 0)
    assert_equal(_alpha_of(c, 1, 1), 0)


def test_quarter_pixel_rectangle_edges() raises:
    # x from 10.25 to 20.75, y from 5.5 to 9.5: the left and right
    # columns are 3/4 covered, the top and bottom rows 1/2, the corners
    # 3/8, the interior whole.
    var c = Canvas(32, 16, BG)
    var p = Path()
    p.rect(10.25, 5.5, 10.5, 4.0)
    fill_path_aa(c, p, INK, FillRule.NONZERO)
    assert_equal(_alpha_of(c, 15, 7), 255, "interior")
    _assert_near(_alpha_of(c, 10, 7), 191, 1, "left column")
    _assert_near(_alpha_of(c, 20, 7), 191, 1, "right column")
    _assert_near(_alpha_of(c, 15, 5), 128, 1, "top row")
    _assert_near(_alpha_of(c, 15, 9), 128, 1, "bottom row")
    _assert_near(_alpha_of(c, 10, 5), 96, 1, "top-left corner")
    _assert_near(_alpha_of(c, 20, 9), 96, 1, "bottom-right corner")
    assert_equal(_alpha_of(c, 9, 7), 0, "outside left")
    assert_equal(_alpha_of(c, 21, 7), 0, "outside right")
    assert_equal(_alpha_of(c, 15, 4), 0, "outside top")
    assert_equal(_alpha_of(c, 15, 10), 0, "outside bottom")


def test_shallow_edge_has_more_than_seventeen_levels() raises:
    # A long thin wedge whose top edge climbs one pixel over 200: the
    # coverage along the row it crosses steps by ~1/200 per pixel, which
    # exact area resolves and 16 samples cannot.
    var c = Canvas(220, 12, BG)
    var p = Path()
    p.move_to(5.0, 6.0)
    p.line_to(205.0, 5.0)
    p.line_to(205.0, 9.0)
    p.line_to(5.0, 9.0)
    p.close()
    fill_path_aa(c, p, INK, FillRule.NONZERO)
    var seen = List[Bool](length=256, fill=False)
    var distinct = 0
    for x in range(6, 204):
        var a = _alpha_of(c, x, 5)
        if not seen[a]:
            seen[a] = True
            distinct += 1
    assert_true(distinct > 17, String(distinct) + " distinct levels")
    # And monotone: the wedge gets thicker to the right.
    var previous = -1
    for x in range(6, 204):
        var a = _alpha_of(c, x, 5)
        assert_true(a >= previous, "coverage climbs along the edge")
        previous = a


def test_even_odd_still_samples() raises:
    # The same half-pixel triangle under EVEN_ODD goes through the
    # sweep, whose coverage is a count of 16 samples: the alpha is a
    # multiple of 255/16 and, with the samples that fall inside a
    # diagonal, not the exact 128 -- the two rules are different
    # rasterizers.
    var c = Canvas(4, 4, BG)
    var p = Path()
    p.move_to(0.0, 0.0)
    p.line_to(1.0, 0.0)
    p.line_to(0.0, 1.0)
    p.close()
    fill_path_aa(c, p, INK, FillRule.EVEN_ODD)
    var a = _alpha_of(c, 0, 0)
    var sixteenths = Int(Float64(a) / 255.0 * 16.0 + 0.5)
    _assert_near(a, Int(Float64(sixteenths) / 16.0 * 255.0 + 0.5), 1, "sampled")
    assert_true(a != 128 and a > 0, "sampled, not exact: " + String(a))


def test_nonzero_union_and_cancellation() raises:
    # Two same-direction squares overlapping: their union, solid where
    # they overlap. The same squares wound opposite ways cancel there.
    var same = Canvas(40, 40, BG)
    var p = Path()
    p.rect(5.0, 5.0, 20.0, 20.0)
    p.rect(15.0, 15.0, 20.0, 20.0)
    fill_path_aa(same, p, INK, FillRule.NONZERO)
    assert_equal(_alpha_of(same, 20, 20), 255, "overlap is solid")
    assert_equal(_alpha_of(same, 10, 10), 255)
    assert_equal(_alpha_of(same, 30, 30), 255)

    var opposite = Canvas(40, 40, BG)
    var q = Path()
    q.rect(5.0, 5.0, 20.0, 20.0)
    q.move_to(15.0, 15.0)
    q.line_to(15.0, 35.0)
    q.line_to(35.0, 35.0)
    q.line_to(35.0, 15.0)
    q.close()
    fill_path_aa(opposite, q, INK, FillRule.NONZERO)
    assert_equal(_alpha_of(opposite, 20, 20), 0, "opposite windings cancel")
    assert_equal(_alpha_of(opposite, 10, 10), 255)
    assert_equal(_alpha_of(opposite, 30, 30), 255)


def test_polygon_goes_through_area_and_strokes_stay_sampled() raises:
    var tri: List[FPoint] = [
        FPoint(0.0, 0.0),
        FPoint(1.0, 0.0),
        FPoint(0.0, 1.0),
    ]
    var c = Canvas(4, 4, BG)
    fill_polygon_aa(c, tri, INK, FillRule.NONZERO)
    _assert_near(_alpha_of(c, 0, 0), 128, 1, "polygon half pixel")

    # A stroke is overlapping pieces, which accumulation over-covers at
    # their shared edge pixels (see aa_area's docstring), so strokes
    # keep the sampled sweep: a shallow 1px line's edge coverage is
    # still counted in sixteenths.
    var s = Canvas(220, 12, BG)
    draw_line_aa(s, 5.0, 5.2, 205.0, 6.8, INK, width=1.0)
    for x in range(10, 200):
        var a = _alpha_of(s, x, 5)
        var sixteenths = Int(Float64(a) / 255.0 * 16.0 + 0.5)
        _assert_near(
            a, Int(Float64(sixteenths) / 16.0 * 255.0 + 0.5), 1, "sampled"
        )


def test_shape_past_the_canvas_edges() raises:
    # A rectangle hanging off every edge fills the whole canvas and
    # nothing crashes on the rows and columns outside it.
    var c = Canvas(16, 12, BG)
    var p = Path()
    p.rect(-30.0, -30.0, 100.0, 100.0)
    fill_path_aa(c, p, INK, FillRule.NONZERO)
    for y in range(12):
        for x in range(16):
            assert_equal(_alpha_of(c, x, y), 255)

    # And one straddling only the left edge keeps its fractional right
    # column.
    var d = Canvas(16, 12, BG)
    var q = Path()
    q.rect(-5.0, 2.0, 10.5, 5.0)
    fill_path_aa(d, q, INK, FillRule.NONZERO)
    assert_equal(_alpha_of(d, 0, 4), 255)
    assert_equal(_alpha_of(d, 4, 4), 255)
    _assert_near(_alpha_of(d, 5, 4), 128, 1, "half column")
    assert_equal(_alpha_of(d, 6, 4), 0)


def test_clip_path_mask_has_fine_levels() raises:
    # push_clip_path under NONZERO builds its mask by area too: a
    # shallow-edged clip lets through more than 17 distinct amounts.
    var c = Canvas(220, 12, BG)
    var p = Path()
    p.move_to(5.0, 6.0)
    p.line_to(205.0, 5.0)
    p.line_to(205.0, 9.0)
    p.line_to(5.0, 9.0)
    p.close()
    c.push_clip_path(p, FillRule.NONZERO)
    var seen = List[Bool](length=256, fill=False)
    var distinct = 0
    for x in range(6, 204):
        var v = Int(c.clip_coverage(x, 5))
        if not seen[v]:
            seen[v] = True
            distinct += 1
    assert_true(distinct > 17, String(distinct) + " mask levels")
    c.pop_clip_path()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
