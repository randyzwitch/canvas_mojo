"""Tests for canvas/shapes/circles.mojo: exact pixel sets for
known inputs, verified against hand-traced runs of the same
algorithms.
"""

from std.testing import assert_equal, TestSuite, assert_true

from canvas.color import Color
from canvas.buffer import Canvas
from canvas.geometry import FPoint
from canvas.shapes.circles import (
    draw_circle,
    fill_circle,
    fill_circle_aa,
    fill_circles_aa,
    draw_circle_aa,
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


# How far a fill may sit from the shape's true covered area. The
# rasterizer computes the exact area of the *flattened* outline, and
# `canvas.shapes.arcs._CURVE_TOLERANCE` lets a chord sag up to 0.02 px
# from the curve, which biases a boundary pixel inward by a couple of
# levels. Three is that bias with room to spare, and still far under
# the six-to-nine-level error a 4x4 sub-sample grid produces, so a
# regression to sampling fails these.
comptime _AREA_TOLERANCE = 3


def _assert_coverage(
    c: Canvas, x: Int, y: Int, expected: Int, label: String
) raises:
    """White on black, so the gray value is the covered fraction in
    255ths. `expected` is the true area, computed independently."""
    var got = Int(c.get_pixel(x, y).r)
    assert_true(
        abs(got - expected) <= _AREA_TOLERANCE,
        String(
            label,
            ": got ",
            got,
            ", true coverage ",
            expected,
            " (tolerance ",
            _AREA_TOLERANCE,
            ")",
        ),
    )


def test_draw_circle_radius_zero_plots_center() raises:
    var c = Canvas(3, 3, BG)
    draw_circle(c, 1, 1, 0, FG)
    _assert_pixel(c, 1, 1, FG, "single center pixel")


def test_draw_circle_radius_three_matches_traced_points() raises:
    # Hand-traced midpoint-circle run for radius=3 at (5,5) on an
    # 11x11 canvas; the 16 points below are that trace's output, not
    # values read back from this function.
    var c = Canvas(11, 11, BG)
    draw_circle(c, 5, 5, 3, FG)

    var xs: List[Int] = [8, 2, 5, 5, 8, 6, 4, 2, 2, 4, 6, 8, 7, 3, 3, 7]
    var ys: List[Int] = [5, 5, 8, 2, 6, 8, 8, 6, 4, 2, 2, 4, 7, 7, 3, 3]
    for i in range(len(xs)):
        _assert_pixel(c, xs[i], ys[i], FG, "on the circle boundary")

    # exactly 16 pixels should be colored -- no extras, none missing
    var count = 0
    for y in range(11):
        for x in range(11):
            var p = c.get_pixel(x, y)
            if p.r == FG.r and p.g == FG.g and p.b == FG.b:
                count += 1
    assert_equal(count, 16)

    # outline only -- the center stays background
    _assert_pixel(c, 5, 5, BG, "center untouched")


def test_draw_circle_does_not_double_blend_degenerate_symmetry_points() raises:
    # At y==0 and x==y, several of the 8 symmetric expressions collapse
    # onto one pixel. Plotting all 8 unconditionally blends a
    # translucent color twice at those points -- 4 axis, 4 diagonal on
    # a radius=4 circle -- giving 150 instead of the single-blend 100.
    var c = Canvas(11, 11, Color(0, 0, 0))
    draw_circle(c, 5, 5, 4, Color(200, 0, 0, 128))

    # the 4 axis points (y==0 in the loop)
    var axis_xs: List[Int] = [9, 1, 5, 5]
    var axis_ys: List[Int] = [5, 5, 9, 1]
    for i in range(len(axis_xs)):
        var p = c.get_pixel(axis_xs[i], axis_ys[i])
        assert_equal(p.r, 100)

    # the 4 diagonal points (x==y in the loop, at offset 3,3)
    var diag_xs: List[Int] = [8, 2, 8, 2]
    var diag_ys: List[Int] = [8, 8, 2, 2]
    for i in range(len(diag_xs)):
        var p = c.get_pixel(diag_xs[i], diag_ys[i])
        assert_equal(p.r, 100)


def test_fill_circle_radius_zero_plots_center() raises:
    var c = Canvas(3, 3, BG)
    fill_circle(c, 1, 1, 0, FG)
    _assert_pixel(c, 1, 1, FG, "single center pixel")


def test_fill_circle_radius_three_matches_hand_traced_disk() raises:
    # Hand-traced span-fill run for radius=3 at (4,4) on a 9x9 canvas:
    # row widths 1,5,5,7,5,5,1 top to bottom.
    var c = Canvas(9, 9, BG)
    fill_circle(c, 4, 4, 3, FG)

    # unlike the stroke version, the disk is solid: center is filled
    _assert_pixel(c, 4, 4, FG, "center is filled")
    _assert_pixel(c, 4, 1, FG, "top point")
    _assert_pixel(c, 4, 7, FG, "bottom point")
    _assert_pixel(c, 1, 4, FG, "left point")
    _assert_pixel(c, 7, 4, FG, "right point")

    _assert_pixel(c, 4, 0, BG, "just past the top point")
    _assert_pixel(c, 0, 0, BG, "corner, well outside")
    _assert_pixel(c, 8, 8, BG, "corner, well outside")

    # 1+5+5+7+5+5+1 = 29 pixels total
    var count = 0
    for y in range(9):
        for x in range(9):
            var p = c.get_pixel(x, y)
            if p.r == FG.r and p.g == FG.g and p.b == FG.b:
                count += 1
    assert_equal(count, 29)


def test_fill_circle_blends_translucent_color_correctly() raises:
    var c = Canvas(7, 7, Color(0, 0, 0))
    fill_circle(c, 3, 3, 2, Color(200, 0, 0, 128))
    # single-blend arithmetic (same formula used throughout this suite)
    var center = c.get_pixel(3, 3)
    assert_equal(center.r, 100)
    assert_equal(center.g, 0)
    assert_equal(center.b, 0)


def test_fill_circle_aa_center_is_fully_opaque() raises:
    # Pixel (px, py) spans [px - 0.5, px + 0.5] in both axes, so for a
    # radius-2 disk at (3, 3) the pixels sharing an edge with the
    # center are wholly inside -- their farthest corner is at distance
    # sqrt(0.5^2 + 1.5^2) = 1.58 -- while the four diagonal neighbors
    # are not: (2, 2)'s far corner (1.5, 1.5) is at sqrt(4.5) = 2.12,
    # outside the disk, so a sliver of that pixel is uncovered and its
    # true coverage is 98.5%, not 100%.
    #
    # A 4x4 sub-sample grid called that pixel full, because its
    # outermost sample sits at (1.625, 1.625), distance 1.94, inside.
    # Exact area does not, which is the point of #275.
    var c = Canvas(7, 7, BG)
    fill_circle_aa(c, 3, 3, 2, FG)
    _assert_pixel(c, 3, 3, FG, "center")
    _assert_pixel(c, 3, 2, FG, "edge neighbor")
    _assert_pixel(c, 2, 3, FG, "edge neighbor")
    _assert_coverage(c, 2, 2, 251, "diagonal neighbor, corner outside")
    _assert_coverage(c, 4, 4, 251, "diagonal neighbor, corner outside")


def test_fill_circle_aa_far_pixel_is_untouched() raises:
    var c = Canvas(7, 7, BG)
    fill_circle_aa(c, 3, 3, 2, FG)
    _assert_pixel(c, 0, 0, BG, "outside the bounding box, never sampled")


def test_fill_circle_aa_partial_coverage_matches_hand_computed_values() raises:
    # True covered areas for radius=2 at (3, 3), integrated
    # independently rather than read back out of the rasterizer: the
    # circle's half-width at each scanline is sqrt(4 - dy^2), and a
    # pixel's coverage is that chord clipped to the pixel's column,
    # averaged down the pixel's height.
    #
    #   (3, 1): the disk's top, chord centered on the column -> 47.9%
    #   (2, 1): one column left of it, mostly outside          -> 21.4%
    #
    # The 4x4 grid these were written for gave 8/16 and 4/16, i.e. 128
    # and 64, both several levels off the truth.
    var c = Canvas(7, 7, BG)
    fill_circle_aa(c, 3, 3, 2, FG)
    _assert_coverage(c, 3, 1, 122, "top edge, 47.9% covered")
    _assert_coverage(c, 1, 3, 122, "left edge, 47.9% covered")
    _assert_coverage(c, 2, 1, 55, "top-left corner, 21.4% covered")


def test_fill_circle_aa_agrees_with_hard_edged_on_interior_pixels() raises:
    # AA sampling treats pixel (px,py) as centered AT (px,py), not as a
    # unit square with (px,py) at its corner: the corner convention
    # draws a circle shifted half a pixel from fill_circle given
    # identical arguments.
    #
    # Only deep-interior pixels are checked, not extreme boundary
    # points like (3,1) at the exact top: their centers sit on the true
    # boundary while half their area falls outside, so partial coverage
    # there is correct, and asserting full opacity would assert
    # something false about area.
    var c = Canvas(7, 7, BG)
    fill_circle_aa(c, 3, 3, 2, FG)
    # Only the pixels sharing an edge with the center are wholly
    # inside; the four diagonal neighbors each have one corner
    # outside the disk (see the fully-opaque test above), so they are
    # 98.5% covered rather than 100%.
    _assert_pixel(c, 3, 3, FG, "center")
    _assert_pixel(c, 3, 2, FG, "edge neighbor")
    _assert_pixel(c, 2, 3, FG, "edge neighbor")
    _assert_pixel(c, 4, 3, FG, "edge neighbor")
    _assert_pixel(c, 3, 4, FG, "edge neighbor")
    _assert_coverage(c, 4, 2, 251, "diagonal neighbor")
    _assert_coverage(c, 2, 4, 251, "diagonal neighbor")
    _assert_coverage(c, 4, 4, 251, "diagonal neighbor")


def test_fill_circle_aa_respects_translucent_input_color() raises:
    # The coverage-to-alpha formula has to scale by the caller's
    # color.a, not a hardcoded 255: with alpha=128 a fully-covered
    # pixel must blend, not render as the raw opaque color. An
    # opaque-color test can't catch this -- coverage*255 ==
    # coverage*color.a there.
    var c = Canvas(7, 7, Color(0, 0, 0))
    fill_circle_aa(c, 3, 3, 2, Color(200, 0, 0, 128))
    var center = c.get_pixel(3, 3)  # fully covered
    assert_equal(center.r, 100)
    assert_equal(center.g, 0)
    assert_equal(center.b, 0)


def test_draw_circle_aa_center_stays_background() raises:
    var c = Canvas(9, 9, BG)
    draw_circle_aa(c, 4, 4, 3, FG)
    _assert_pixel(c, 4, 4, BG, "ring outline, not filled")


def test_draw_circle_aa_partial_coverage_matches_hand_computed_value() raises:
    # True coverage of the annulus [2.5, 3.5] for radius=3, width=1 at
    # (4, 4), integrated independently: the ring's area inside a pixel
    # is the outer disk's chord minus the inner disk's, clipped to the
    # pixel's column and averaged down its height.
    #
    #   (2, 1): the ring passing diagonally through          -> 35.4%
    #   (4, 1): under the ring's center line                 -> 98.8%
    #
    # (4, 1) is the one worth reading twice. It sits directly above
    # the center at distance 3, the ring's middle, and the 4x4 grid
    # called it 16/16 -- but the pixel spans y in [0.5, 1.5] while the
    # ring only spans [0.5, 1.5] at x = 4 exactly, narrowing away from
    # it, so a little over 1% of the pixel is outside. Exact area sees
    # that; sixteen samples did not.
    var c = Canvas(9, 9, BG)
    draw_circle_aa(c, 4, 4, 3, FG)

    _assert_coverage(c, 2, 1, 90, "ring crossing the pixel diagonally")
    _assert_coverage(c, 4, 1, 252, "under the ring's center line")
    _assert_pixel(c, 0, 0, BG, "corner, well outside the ring")


def test_draw_circle_aa_respects_translucent_input_color() raises:
    # Same property as fill_circle_aa's: a ring pixel drawn with a
    # translucent color must show the single-blend value, not the raw
    # color and not a double blend.
    #
    # (4, 1) is 98.8% covered (see the test above), so over black the
    # red channel is 200 * 128/255 * 0.988 = 98, where a fully covered
    # pixel would be 100.
    var c = Canvas(9, 9, Color(0, 0, 0))
    draw_circle_aa(c, 4, 4, 3, Color(200, 0, 0, 128))
    var p = c.get_pixel(4, 1)
    assert_true(
        abs(Int(p.r) - 98) <= _AREA_TOLERANCE,
        String("blended once, got ", Int(p.r), ", expected about 98"),
    )
    assert_equal(p.g, 0)
    assert_equal(p.b, 0)


def test_draw_circle_aa_width_widens_the_ring() raises:
    # width=4 lays down more ink than width=1, and the ring's middle
    # stays at the radius: the pixel at (cx + r, cy) sits under the
    # stroke's center line and is fully covered either way.
    var thin = Canvas(60, 60, Color(0, 0, 0))
    draw_circle_aa(thin, 30, 30, 20, Color(255, 255, 255))
    var thick = Canvas(60, 60, Color(0, 0, 0))
    draw_circle_aa(thick, 30, 30, 20, Color(255, 255, 255), width=4.0)
    var thin_ink = 0
    var thick_ink = 0
    for y in range(60):
        for x in range(60):
            thin_ink += Int(thin.get_pixel(x, y).r)
            thick_ink += Int(thick.get_pixel(x, y).r)
    assert_true(thick_ink > thin_ink, "a wider ring is more ink")
    # (50, 30) sits on the stroke's center line at radius 20. A 1 px
    # ring leaves a sliver of that pixel uncovered where the ring
    # curves away (true coverage 99.6%); a 4 px ring covers it whole.
    _assert_coverage(thin, 50, 30, 254, "on a 1 px stroke's center")
    assert_equal(thick.get_pixel(50, 30).r, 255, "on a 4 px stroke's center")
    assert_equal(thick.get_pixel(30, 30).r, 0, "the hole is untouched")


def test_canvas_method_matches_the_free_function() raises:
    # Canvas.draw_circle_aa is the DrawTarget method; draw_circle_aa is
    # the free function it delegates to. They must put down
    # byte-identical pixels, including antialiased edges -- a caller
    # rendering generically through the trait gets exactly what a
    # caller reaching for the free function does.
    var via_method = Canvas(31, 21, BG)
    via_method.draw_circle_aa(15.0, 10.0, 8.0, FG, width=3.0)

    var via_function = Canvas(31, 21, BG)
    draw_circle_aa(via_function, 15.0, 10.0, 8.0, FG, width=3.0)

    for y in range(21):
        for x in range(31):
            var a = via_method.get_pixel(x, y)
            var b = via_function.get_pixel(x, y)
            assert_equal(a.r, b.r)
            assert_equal(a.g, b.g)
            assert_equal(a.b, b.b)


def test_draw_circle_aa_sub_pixel_center_moves_the_ring() raises:
    var a = Canvas(60, 60, Color(0, 0, 0))
    draw_circle_aa(a, 30.0, 30.0, 20.0, Color(255, 255, 255))
    var b = Canvas(60, 60, Color(0, 0, 0))
    draw_circle_aa(b, 30.5, 30.0, 20.0, Color(255, 255, 255))
    var differing = 0
    for y in range(60):
        for x in range(60):
            if a.get_pixel(x, y).r != b.get_pixel(x, y).r:
                differing += 1
    assert_true(differing > 20, "half a pixel of center shifts the ring")


# --- batched markers (#290) ----------------------------------------
# `fill_circles_aa` splits the canvas into row bands and hands each
# band the whole batch. Its contract is that the result is
# indistinguishable from calling `fill_circle_aa` once per center in
# the same order, so every test here renders both ways and compares
# every byte. Nothing is asserted about speed: that is the benchmark's
# job, and correctness here is what makes the speed worth having.


def _scatter(n: Int, seedx: Int, seedy: Int) -> List[FPoint]:
    """Fractional positions on purpose. Integer centers would give
    every marker the same sub-pixel phase, which is the one case a
    coverage shortcut cannot get wrong."""
    var pts = List[FPoint](capacity=n)
    for i in range(n):
        var x = 12.0 + Float64((i * seedx) % 2600) * 0.1
        var y = 9.0 + Float64((i * seedy) % 1700) * 0.1
        pts.append(FPoint(x, y))
    return pts^


def _assert_same_canvas(a: Canvas, b: Canvas, label: String) raises:
    assert_equal(a.width, b.width, label + " width")
    assert_equal(a.height, b.height, label + " height")
    var differing = 0
    for y in range(a.height):
        for x in range(a.width):
            var p = a.get_pixel(x, y)
            var q = b.get_pixel(x, y)
            if p.r != q.r or p.g != q.g or p.b != q.b or p.a != q.a:
                differing += 1
    assert_equal(differing, 0, label + ": differing pixels")


def _inked(c: Canvas) -> Int:
    var n = 0
    for y in range(c.height):
        for x in range(c.width):
            var p = c.get_pixel(x, y)
            if p.r != 0 or p.g != 0 or p.b != 0:
                n += 1
    return n


def test_batched_markers_match_individual_calls() raises:
    var pts = _scatter(1200, 37, 53)
    var ink = Color(220, 90, 40)
    var batched = Canvas(280, 190, BG)
    fill_circles_aa(batched, pts, 3.5, ink)
    var one_by_one = Canvas(280, 190, BG)
    for i in range(len(pts)):
        fill_circle_aa(one_by_one, pts[i].x, pts[i].y, 3.5, ink)
    _assert_same_canvas(batched, one_by_one, "opaque batch")
    assert_true(_inked(one_by_one) > 5000, "the scatter must draw ink")


def test_overlapping_translucent_markers_keep_submission_order() raises:
    """The case that fails if a band draws the batch out of order, or
    if two bands both write a pixel. Opaque markers would hide it."""
    var pts = List[FPoint]()
    for i in range(400):
        # Deliberately piled up, so almost every marker overlaps
        # several others and order decides the result.
        pts.append(
            FPoint(40.0 + Float64(i % 20) * 2.3, 30.0 + Float64(i // 20) * 2.7)
        )
    var ink = Color(30, 140, 220, 70)
    var batched = Canvas(160, 120, BG)
    fill_circles_aa(batched, pts, 5.0, ink)
    var one_by_one = Canvas(160, 120, BG)
    for i in range(len(pts)):
        fill_circle_aa(one_by_one, pts[i].x, pts[i].y, 5.0, ink)
    _assert_same_canvas(batched, one_by_one, "translucent pile")
    assert_true(_inked(one_by_one) > 2000, "the pile must draw ink")


def test_per_marker_colors_match_individual_calls() raises:
    var pts = _scatter(600, 41, 29)
    var colors = List[Color](capacity=len(pts))
    for i in range(len(pts)):
        colors.append(
            Color(
                UInt8(20 + i % 200),
                UInt8(90 + i % 120),
                200,
                UInt8(120 + i % 130),
            )
        )
    var batched = Canvas(280, 190, BG)
    fill_circles_aa(batched, pts, 4.0, colors)
    var one_by_one = Canvas(280, 190, BG)
    for i in range(len(pts)):
        fill_circle_aa(one_by_one, pts[i].x, pts[i].y, 4.0, colors[i])
    _assert_same_canvas(batched, one_by_one, "per-marker colors")


def test_markers_straddling_band_boundaries_are_drawn_once() raises:
    """Every marker sits on a row a band boundary is likely to fall
    on. Drawn twice, a translucent marker composites twice and shows
    up immediately."""
    var pts = List[FPoint]()
    var h = 256
    for b in range(1, 64):
        var y = Float64(b * h) / 64.0
        for k in range(6):
            pts.append(FPoint(10.0 + Float64(k) * 30.0 + Float64(b), y))
    var ink = Color(255, 255, 255, 90)
    var batched = Canvas(200, h, BG)
    fill_circles_aa(batched, pts, 4.0, ink)
    var one_by_one = Canvas(200, h, BG)
    for i in range(len(pts)):
        fill_circle_aa(one_by_one, pts[i].x, pts[i].y, 4.0, ink)
    _assert_same_canvas(batched, one_by_one, "band boundaries")


def test_batched_markers_under_a_similarity_transform() raises:
    var pts = _scatter(500, 23, 61)
    var ink = Color(200, 60, 120, 180)
    var batched = Canvas(280, 190, BG)
    batched.save()
    batched.translate(18.0, 7.0)
    batched.rotate(0.4)
    batched.scale(1.3, 1.3)
    fill_circles_aa(batched, pts, 3.0, ink)
    batched.restore()
    var one_by_one = Canvas(280, 190, BG)
    one_by_one.save()
    one_by_one.translate(18.0, 7.0)
    one_by_one.rotate(0.4)
    one_by_one.scale(1.3, 1.3)
    for i in range(len(pts)):
        fill_circle_aa(one_by_one, pts[i].x, pts[i].y, 3.0, ink)
    one_by_one.restore()
    _assert_same_canvas(batched, one_by_one, "similarity")
    assert_true(_inked(one_by_one) > 1000, "the transformed scatter must ink")


def test_batched_markers_under_a_non_similarity_transform() raises:
    """A non-uniform scale makes each disk an ellipse, so the batch
    falls back to per-marker calls. Same pixels either way."""
    var pts = _scatter(300, 17, 43)
    var ink = Color(90, 190, 90)
    var batched = Canvas(280, 190, BG)
    batched.save()
    batched.scale(1.6, 0.7)
    fill_circles_aa(batched, pts, 3.5, ink)
    batched.restore()
    var one_by_one = Canvas(280, 190, BG)
    one_by_one.save()
    one_by_one.scale(1.6, 0.7)
    for i in range(len(pts)):
        fill_circle_aa(one_by_one, pts[i].x, pts[i].y, 3.5, ink)
    one_by_one.restore()
    _assert_same_canvas(batched, one_by_one, "non-similarity")


def test_large_radius_markers_fall_back_and_still_match() raises:
    """Past the closed-form limit the polygon rasterizer takes over,
    which bands each disk itself."""
    var pts = _scatter(60, 31, 47)
    var ink = Color(240, 200, 60, 150)
    var batched = Canvas(280, 190, BG)
    fill_circles_aa(batched, pts, 14.0, ink)
    var one_by_one = Canvas(280, 190, BG)
    for i in range(len(pts)):
        fill_circle_aa(one_by_one, pts[i].x, pts[i].y, 14.0, ink)
    _assert_same_canvas(batched, one_by_one, "large radius")


def test_batched_markers_under_a_clip() raises:
    var pts = _scatter(800, 37, 53)
    var ink = Color(120, 180, 255, 200)
    var batched = Canvas(280, 190, BG)
    batched.save()
    batched.push_clip(60, 40, 90, 70)
    fill_circles_aa(batched, pts, 3.5, ink)
    batched.restore()
    var one_by_one = Canvas(280, 190, BG)
    one_by_one.save()
    one_by_one.push_clip(60, 40, 90, 70)
    for i in range(len(pts)):
        fill_circle_aa(one_by_one, pts[i].x, pts[i].y, 3.5, ink)
    one_by_one.restore()
    _assert_same_canvas(batched, one_by_one, "clipped batch")


def test_batched_markers_are_identical_at_every_worker_count() raises:
    """Banding must not change the picture, whatever it is banded
    into -- including one band, which takes the serial path."""
    var pts = _scatter(900, 37, 53)
    var ink = Color(255, 120, 60, 140)
    var caps: List[Int] = [1, 2, 3, 8, 64]
    var reference = Canvas(240, 170, BG)
    for i in range(len(pts)):
        fill_circle_aa(reference, pts[i].x, pts[i].y, 3.5, ink)
    for ci in range(len(caps)):
        var c = Canvas(240, 170, BG)
        c.set_max_workers(caps[ci])
        fill_circles_aa(c, pts, 3.5, ink)
        _assert_same_canvas(c, reference, String("workers ", caps[ci]))


def test_empty_batch_and_mismatched_colors() raises:
    var c = Canvas(60, 40, BG)
    var none = List[FPoint]()
    fill_circles_aa(c, none, 3.0, Color(255, 255, 255))
    assert_equal(_inked(c), 0, "an empty batch draws nothing")

    var pts = _scatter(4, 13, 19)
    var too_few = List[Color]()
    too_few.append(Color(255, 0, 0))
    var raised = False
    try:
        fill_circles_aa(c, pts, 3.0, too_few)
    except:
        raised = True
    assert_true(raised, "a color per marker is required")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
