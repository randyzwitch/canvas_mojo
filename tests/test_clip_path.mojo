"""Tests for push_clip_path: clipping to an arbitrary shape.

Two properties carry most of the weight. The clip must be
*anti-aliased* -- a pixel the clip path half covers lets half the
drawing through, which is what distinguishes this from a hard in/out
stencil. And nesting must only ever restrict, never widen, which is the
rule the rectangle clip already follows.
"""

from std.testing import assert_equal, assert_true, TestSuite

from canvas.buffer import Canvas
from canvas.color import Color
from canvas.fill_rule import FillRule
from canvas.geometry import Matrix2D
from canvas.mask import Mask
from canvas.path import Path, fill_path_gradient_aa
from canvas.gradient import LinearGradient, RadialGradient
from canvas.shapes.rects import (
    fill_rect,
    fill_rect_gradient,
    fill_rect_radial_gradient,
)

comptime BG = Color(0, 0, 0)
comptime FG = Color(255, 255, 255)


def _square(
    mut p: Path, x0: Float64, y0: Float64, x1: Float64, y1: Float64
) raises:
    p.move_to(x0, y0)
    p.line_to(x1, y0)
    p.line_to(x1, y1)
    p.line_to(x0, y1)
    p.close()


def _ink(c: Canvas) -> Int:
    var total = 0
    for y in range(c.height):
        for x in range(c.width):
            total += Int(c.get_pixel(x, y).r)
    return total


def _square_with_midpoint(
    mut p: Path, x0: Float64, y0: Float64, x1: Float64, y1: Float64
) raises:
    """The same rectangle as `_square`, with a collinear vertex added
    on the top edge.

    Identical geometry, five corners, so it does not match the
    rectangle fast path and goes through the general edge sweep. That
    makes it the control: whatever the fast path computes has to equal
    what the sweep computes for the same region.
    """
    p.move_to(x0, y0)
    p.line_to((x0 + x1) / 2.0, y0)
    p.line_to(x1, y0)
    p.line_to(x1, y1)
    p.line_to(x0, y1)
    p.close()


def _assert_same_coverage(a: Mask, b: Mask, what: String) raises:
    assert_equal(len(a.coverage), len(b.coverage), what + ": sizes")
    var differing = 0
    var first = -1
    for i in range(len(a.coverage)):
        if a.coverage[i] != b.coverage[i]:
            differing += 1
            if first < 0:
                first = i
    assert_equal(
        differing,
        0,
        String(
            what,
            ": ",
            differing,
            " bytes differ, first at ",
            first,
        ),
    )


def test_a_rectangle_clip_matches_the_general_sweep() raises:
    """The fast path is only legitimate if it computes what the sweep
    computes. Fractional edges included -- those are the pixels a
    closed form could get wrong.
    """
    var cases: List[List[Float64]] = [
        [10.0, 10.0, 50.0, 40.0],
        [10.5, 10.0, 50.0, 40.0],
        [10.25, 10.75, 50.5, 40.5],
        [3.7, 4.9, 55.6, 45.3],
        [-5.0, -5.0, 25.0, 25.0],
    ]
    for ci in range(len(cases)):
        ref c = cases[ci]
        var fast = Path()
        _square(fast, c[0], c[1], c[2], c[3])
        var control = Path()
        _square_with_midpoint(control, c[0], c[1], c[2], c[3])
        _assert_same_coverage(
            Mask.from_path(fast, 70, 60, FillRule.NONZERO),
            Mask.from_path(control, 70, 60, FillRule.NONZERO),
            String("case ", ci),
        )


def test_a_rectangle_clip_is_the_same_under_both_fill_rules() raises:
    """A rectangle cannot self-intersect, so even-odd and nonzero
    describe the same region and must produce the same coverage. This
    is what lets one fast path serve both rules.
    """
    var cases: List[List[Float64]] = [
        [10.0, 10.0, 50.0, 40.0],
        [10.25, 10.75, 50.5, 40.5],
        [3.7, 4.9, 55.6, 45.3],
    ]
    for ci in range(len(cases)):
        ref c = cases[ci]
        var p = Path()
        _square(p, c[0], c[1], c[2], c[3])
        _assert_same_coverage(
            Mask.from_path(p, 70, 60),
            Mask.from_path(p, 70, 60, FillRule.NONZERO),
            String("case ", ci),
        )


def test_overlapping_subpaths_still_separate_the_fill_rules() raises:
    """Two rectangles wound the same way overlap with winding 2: even-odd
    leaves that a hole, nonzero fills it. Guards that a shape made of
    rectangles does not get routed through the single-rectangle fast
    path, where the rule would stop mattering.
    """
    var two = Path()
    _square(two, 10.0, 10.0, 40.0, 35.0)
    _square(two, 25.0, 20.0, 55.0, 45.0)
    var eo = Mask.from_path(two, 70, 60)
    var nz = Mask.from_path(two, 70, 60, FillRule.NONZERO)
    # A pixel inside both rectangles.
    var idx = 27 * 70 + 32
    assert_equal(Int(eo.coverage[idx]), 0, "even-odd leaves the overlap open")
    assert_equal(Int(nz.coverage[idx]), 255, "nonzero fills the overlap")


def test_a_bowtie_is_not_taken_for_a_rectangle() raises:
    """A bowtie is four points and closed, like a rectangle, but its
    edges do not alternate axis-aligned. If it were mistaken for one
    its coverage would be the filled bounding box; it is not.
    """
    var bow = Path()
    bow.move_to(10.0, 10.0)
    bow.line_to(50.0, 10.0)
    bow.line_to(10.0, 40.0)
    bow.line_to(50.0, 40.0)
    bow.close()
    var m = Mask.from_path(bow, 70, 60, FillRule.NONZERO)
    # Dead centre of the bounding box is on the crossing, covered; the
    # left edge midway down is outside both triangles, and a filled
    # bounding box would have covered it.
    assert_equal(Int(m.coverage[25 * 70 + 11]), 0, "outside the bowtie")

    var box = Path()
    _square(box, 10.0, 10.0, 50.0, 40.0)
    var b = Mask.from_path(box, 70, 60, FillRule.NONZERO)
    assert_equal(Int(b.coverage[25 * 70 + 11]), 255, "inside the box")


def test_a_fractional_rectangle_edge_gets_its_exact_area() raises:
    """An edge at x.5 covers exactly half of that column, so the
    boundary pixel reads 128 -- not a multiple of 1/16, which is all a
    4x4 sample grid could report.
    """
    var p = Path()
    _square(p, 10.5, 10.0, 50.0, 40.0)
    var m = Mask.from_path(p, 70, 60, FillRule.NONZERO)
    # Pixel 10 spans [9.5, 10.5] and the rectangle starts at 10.5, so
    # it is untouched; pixel 11 spans [10.5, 11.5] and is full.
    assert_equal(Int(m.coverage[20 * 70 + 10]), 0, "column 10 outside")
    assert_equal(Int(m.coverage[20 * 70 + 11]), 255, "column 11 inside")
    # Shift by a quarter pixel and the boundary column is a quarter.
    var q = Path()
    _square(q, 10.25, 10.0, 50.0, 40.0)
    var mq = Mask.from_path(q, 70, 60, FillRule.NONZERO)
    assert_equal(Int(mq.coverage[20 * 70 + 10]), 64, "quarter column")


def test_a_rectangle_clip_outside_the_canvas() raises:
    """Wholly outside clips everything; straddling an edge clips only
    what hangs over.
    """
    var outside = Path()
    _square(outside, 200.0, 200.0, 260.0, 260.0)
    var m = Mask.from_path(outside, 70, 60, FillRule.NONZERO)
    var total = 0
    for i in range(len(m.coverage)):
        total += Int(m.coverage[i])
    assert_equal(total, 0, "a rectangle off the canvas covers nothing")

    var straddle = Path()
    _square(straddle, -10.0, -10.0, 20.0, 20.0)
    var ms = Mask.from_path(straddle, 70, 60, FillRule.NONZERO)
    assert_equal(Int(ms.coverage[0]), 255, "inside the overlap")
    assert_equal(Int(ms.coverage[30 * 70 + 40]), 0, "past the rectangle")


def test_a_rotated_rectangle_clip_keeps_the_transform() raises:
    """Under a rotation the path is no longer axis-aligned in device
    space, so it must fall to the general sweep -- and land exactly
    where the same rotated path drawn without a transform lands.
    """
    var rotated = Canvas(70, 60, BG)
    rotated.save()
    rotated.rotate(0.4)
    var p = Path()
    _square(p, 10.0, 10.0, 40.0, 30.0)
    rotated.push_clip_path(p)
    fill_rect(rotated, 0, 0, 70, 60, FG)
    rotated.pop_clip_path()
    rotated.restore()

    var manual = Canvas(70, 60, BG)
    var m = Matrix2D.rotation(0.4)
    var q = Path()
    var c0 = m.apply(10.0, 10.0)
    var c1 = m.apply(40.0, 10.0)
    var c2 = m.apply(40.0, 30.0)
    var c3 = m.apply(10.0, 30.0)
    q.move_to(c0.x, c0.y)
    q.line_to(c1.x, c1.y)
    q.line_to(c2.x, c2.y)
    q.line_to(c3.x, c3.y)
    q.close()
    manual.push_clip_path(q)
    fill_rect(manual, 0, 0, 70, 60, FG)
    manual.pop_clip_path()

    for y in range(60):
        for x in range(70):
            assert_equal(
                Int(rotated.get_pixel(x, y).r),
                Int(manual.get_pixel(x, y).r),
                String("rotated clip at ", x, ",", y),
            )


def test_the_benchmarks_small_clip_scene_actually_paints() raises:
    """Guards the benchmark geometry, not the renderer.

    `benchmarks/bench_canvas.mojo` times a gradient path fill under a
    small clip. Its window sat at (300, 200), which falls in the gap
    between two of the test path's arches, so for two releases that
    row painted nothing and its 51 us was flattening curves and
    finding no coverage -- not what the row's name claimed (#355).

    The scene now uses two windows and this pins both: the low one
    intersects and must paint, the high one must not. If the path's
    shape is ever changed, this fails rather than the benchmark
    quietly going back to measuring rejection.
    """
    var big = Path()
    big.move_to(60.0, 500.0)
    for i in range(1, 40):
        var x = 60.0 + Float64(i) * 18.0
        big.quad_curve_to(x - 9.0, 120.0, x, 500.0)
    big.close()

    var grad = LinearGradient(0.0, 0.0, 800.0, 600.0)
    grad.add_stop(0.0, Color(30, 40, 60))
    grad.add_stop(1.0, Color(220, 90, 60))

    var painted = Canvas(800, 600, BG)
    painted.save()
    painted.push_clip(300, 400, 100, 80)
    fill_path_gradient_aa(painted, big, grad)
    painted.restore()
    var n = 0
    for y in range(600):
        for x in range(800):
            var p = painted.get_pixel(x, y)
            if p.r != BG.r or p.g != BG.g or p.b != BG.b:
                n += 1
    assert_true(
        n > 4000,
        String("the intersecting clip must paint, got ", n, " pixels"),
    )

    var empty = Canvas(800, 600, BG)
    empty.save()
    empty.push_clip(300, 200, 100, 80)
    fill_path_gradient_aa(empty, big, grad)
    empty.restore()
    var m = 0
    for y in range(600):
        for x in range(800):
            var q = empty.get_pixel(x, y)
            if q.r != BG.r or q.g != BG.g or q.b != BG.b:
                m += 1
    assert_equal(m, 0, "the high clip falls between arches and paints nothing")


def test_no_clip_path_lets_everything_through() raises:
    var c = Canvas(20, 20, BG)
    assert_equal(c.clip_coverage(5, 5), 255, "no mask means full coverage")
    fill_rect(c, 0, 0, 20, 20, FG)
    assert_equal(c.get_pixel(10, 10).r, 255)


def test_fill_is_confined_to_the_clip_path() raises:
    var c = Canvas(40, 40, BG)
    var p = Path()
    _square(p, 10.0, 10.0, 30.0, 30.0)
    c.push_clip_path(p)
    fill_rect(c, 0, 0, 40, 40, FG)
    c.pop_clip_path()

    assert_equal(c.get_pixel(20, 20).r, 255, "inside the clip path")
    assert_equal(c.get_pixel(2, 2).r, 0, "outside it stays background")
    assert_equal(c.get_pixel(35, 20).r, 0, "past its right edge")


def test_pop_restores_unclipped_drawing() raises:
    var c = Canvas(30, 30, BG)
    var p = Path()
    _square(p, 5.0, 5.0, 10.0, 10.0)
    c.push_clip_path(p)
    c.pop_clip_path()
    fill_rect(c, 0, 0, 30, 30, FG)
    assert_equal(c.get_pixel(25, 25).r, 255, "clip no longer applies")


def test_pop_on_empty_stack_is_a_noop() raises:
    var c = Canvas(8, 8, BG)
    c.pop_clip_path()
    fill_rect(c, 0, 0, 8, 8, FG)
    assert_equal(c.get_pixel(4, 4).r, 255)


def test_clip_edge_is_antialiased_not_a_hard_stencil() raises:
    # The clip path's left edge sits at x = 10.25, which is a quarter
    # of the way into the pixel centered at x=10 (that pixel spans
    # [9.5, 10.5]). At the default 4x supersample its columns sit at
    # 9.625, 9.875, 10.125 and 10.375, of which one is inside -- so the
    # pixel lets a quarter through, and an opaque white fill lands at
    # round(0.25 * 255) = 64.
    #
    # A hard in/out clip could only ever produce 0 or 255 here. That is
    # the whole distinction this test exists for.
    var c = Canvas(40, 40, BG)
    var p = Path()
    _square(p, 10.25, 5.0, 30.0, 35.0)
    c.push_clip_path(p)
    fill_rect(c, 0, 0, 40, 40, FG)
    c.pop_clip_path()

    assert_equal(
        Int(c.get_pixel(10, 20).r), 64, "hand-derived partial clip coverage"
    )
    assert_equal(Int(c.get_pixel(11, 20).r), 255, "fully inside")
    assert_equal(Int(c.get_pixel(9, 20).r), 0, "fully outside")


def test_clip_coverage_reports_the_mask() raises:
    var c = Canvas(40, 40, BG)
    var p = Path()
    _square(p, 10.25, 5.0, 30.0, 35.0)
    c.push_clip_path(p)
    assert_equal(c.clip_coverage(10, 20), 64, "partial coverage on the edge")
    assert_equal(c.clip_coverage(20, 20), 255, "fully inside")
    assert_equal(c.clip_coverage(2, 20), 0, "fully outside")
    c.pop_clip_path()


def test_nested_clip_paths_only_ever_restrict() raises:
    var c = Canvas(60, 60, BG)
    var outer = Path()
    _square(outer, 10.0, 10.0, 40.0, 40.0)
    var inner = Path()
    # Deliberately extends past the outer clip on the right: a nested
    # clip must not be able to widen its parent.
    _square(inner, 20.0, 20.0, 55.0, 30.0)

    c.push_clip_path(outer)
    c.push_clip_path(inner)
    fill_rect(c, 0, 0, 60, 60, FG)
    c.pop_clip_path()
    c.pop_clip_path()

    assert_equal(c.get_pixel(25, 25).r, 255, "inside both")
    assert_equal(c.get_pixel(15, 15).r, 0, "outside the inner one")
    assert_equal(
        c.get_pixel(50, 25).r, 0, "the inner clip cannot escape the outer"
    )


def test_popping_an_inner_clip_restores_the_outer() raises:
    var c = Canvas(60, 60, BG)
    var outer = Path()
    _square(outer, 10.0, 10.0, 40.0, 40.0)
    var inner = Path()
    _square(inner, 20.0, 20.0, 30.0, 30.0)

    c.push_clip_path(outer)
    c.push_clip_path(inner)
    c.pop_clip_path()
    fill_rect(c, 0, 0, 60, 60, FG)
    c.pop_clip_path()

    assert_equal(c.get_pixel(15, 15).r, 255, "the outer clip is back")
    assert_equal(c.get_pixel(50, 50).r, 0, "but still restricts")


def test_clip_path_composes_with_a_rectangle_clip() raises:
    # The two clip mechanisms are independent and both apply.
    var c = Canvas(60, 60, BG)
    var p = Path()
    _square(p, 10.0, 10.0, 50.0, 50.0)
    c.push_clip_path(p)
    c.push_clip(30, 0, 60, 60)  # right half only
    fill_rect(c, 0, 0, 60, 60, FG)
    c.pop_clip()
    c.pop_clip_path()

    assert_equal(c.get_pixel(40, 30).r, 255, "inside both clips")
    assert_equal(c.get_pixel(20, 30).r, 0, "excluded by the rectangle clip")
    assert_equal(c.get_pixel(40, 55).r, 0, "excluded by the clip path")


def test_clip_path_honours_the_fill_rule() raises:
    # Two overlapping same-direction squares. Under EVEN_ODD the
    # overlap is a hole in the clip; under NONZERO it is solid -- the
    # same divergence fill_path shows, since the mask is built by the
    # same sweep.
    var even_odd = Canvas(60, 60, BG)
    var nonzero = Canvas(60, 60, BG)
    for i in range(2):
        var p = Path()
        _square(p, 5.0, 5.0, 35.0, 35.0)
        _square(p, 20.0, 20.0, 50.0, 50.0)
        if i == 0:
            even_odd.push_clip_path(p, FillRule.EVEN_ODD)
            fill_rect(even_odd, 0, 0, 60, 60, FG)
            even_odd.pop_clip_path()
        else:
            nonzero.push_clip_path(p, FillRule.NONZERO)
            fill_rect(nonzero, 0, 0, 60, 60, FG)
            nonzero.pop_clip_path()

    assert_equal(
        even_odd.get_pixel(27, 27).r, 0, "even-odd leaves a hole in the overlap"
    )
    assert_equal(
        nonzero.get_pixel(27, 27).r, 255, "nonzero fills the overlap solid"
    )
    assert_true(
        _ink(nonzero) > _ink(even_odd), "and so passes strictly more through"
    )


def test_clip_path_applies_to_translucent_drawing() raises:
    # Clip coverage multiplies the drawn color's own alpha rather than
    # replacing it: half coverage of a half-alpha fill is a quarter.
    var c = Canvas(40, 40, BG)
    var p = Path()
    _square(p, 10.5, 5.0, 30.0, 35.0)
    c.push_clip_path(p)
    fill_rect(c, 0, 0, 40, 40, Color(255, 255, 255, 128))
    c.pop_clip_path()

    # Pixel 10 spans [9.5, 10.5], so the clip's edge at 10.5 leaves it
    # entirely outside; pixel 11 is fully inside and gets the plain
    # half-alpha value.
    assert_equal(Int(c.get_pixel(10, 20).r), 0, "outside the clip")
    assert_equal(
        Int(c.get_pixel(11, 20).r), 128, "inside: the fill's own alpha"
    )


def test_gradient_fills_respect_the_clip_path() raises:
    # Regression: `fill_rect_gradient` and `fill_rect_radial_gradient`
    # write through `write_pixel`, which deliberately skips every
    # per-pixel check -- so they ignored the clip mask entirely and
    # painted the whole rectangle. Caught by looking at the rendered
    # example, not by any test that existed at the time.
    var linear = Canvas(60, 60, BG)
    var p = Path()
    _square(p, 10.0, 10.0, 30.0, 30.0)
    var lg = LinearGradient(0.0, 0.0, 60.0, 60.0)
    lg.add_stop(0.0, FG)
    lg.add_stop(1.0, FG)

    linear.push_clip_path(p)
    fill_rect_gradient(linear, 0, 0, 60, 60, lg)
    linear.pop_clip_path()
    assert_true(
        Int(linear.get_pixel(20, 20).r) > 0, "inside the clip is painted"
    )
    assert_equal(Int(linear.get_pixel(45, 45).r), 0, "outside the clip is not")

    var radial = Canvas(60, 60, BG)
    var p2 = Path()
    _square(p2, 10.0, 10.0, 30.0, 30.0)
    var rg = RadialGradient(30.0, 30.0, 40.0)
    rg.add_stop(0.0, FG)
    rg.add_stop(1.0, FG)

    radial.push_clip_path(p2)
    fill_rect_radial_gradient(radial, 0, 0, 60, 60, rg)
    radial.pop_clip_path()
    assert_true(
        Int(radial.get_pixel(20, 20).r) > 0, "inside the clip is painted"
    )
    assert_equal(Int(radial.get_pixel(45, 45).r), 0, "outside the clip is not")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
