"""Tests for the canvas transform state: `Matrix2D`, `Canvas.save`/
`restore`, `translate`/`rotate`/`scale`, and that each primitive
family maps through the current transform.

Most tests draw a shape under a transform and the same shape directly
at the mapped coordinates on a second canvas, then compare the two
pixel for pixel: where a primitive maps its own coordinates and calls
its own rasterizer (a rectangle under an axis-aligned transform, a
circle under a similarity, a path under anything) the two must be
identical. A stroke under a transform is built in user space and its
outline mapped edge by edge, which reorders the floating-point
arithmetic against a stroke built directly at the mapped points, so
those comparisons allow a few pixels to differ by a coverage step.

The two text tests need a "Sans"-resolvable system font, as
test_text.mojo does.
"""

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
from canvas.compose import draw_canvas
from canvas.resize import downsample
from canvas.text.render import (
    _draw_block_direct,
    _layout_block,
)
from canvas.text.font_discovery import FontSlant, FontWeight
from canvas.text.text_align import TextAlign
from canvas.geometry import FPoint, Matrix2D, Point, Transform2D
from canvas.gradient import LinearGradient
from canvas.path import Path, fill_path, fill_path_aa
from canvas.shapes.arcs import fill_arc_aa, fill_ring_sector_aa
from canvas.shapes.circles import fill_circle, fill_circle_aa
from canvas.shapes.ellipses import fill_ellipse_aa
from canvas.shapes.lines import draw_line, draw_line_aa, draw_polyline_aa
from canvas.shapes.polygon_fill import fill_polygon_aa
from canvas.shapes.rects import draw_rect, fill_rect, fill_rect_gradient
from canvas.text.font_cache import FontCache
from canvas.text.render import draw_text

comptime BG = Color(255, 255, 255)
comptime INK = Color(30, 60, 200)
comptime W = 120
comptime H = 90


def _differing(a: Canvas, b: Canvas) -> Int:
    var n = 0
    for y in range(a.height):
        for x in range(a.width):
            var p = a.get_pixel(x, y)
            var q = b.get_pixel(x, y)
            if p.r != q.r or p.g != q.g or p.b != q.b or p.a != q.a:
                n += 1
    return n


def _assert_same(a: Canvas, b: Canvas, label: String) raises:
    assert_equal(a.width, b.width, label)
    assert_equal(a.height, b.height, label)
    var n = _differing(a, b)
    assert_equal(n, 0, label + ": " + String(n) + " pixels differ")


def _assert_nearly_same(
    a: Canvas, b: Canvas, max_differing: Int, label: String
) raises:
    var n = _differing(a, b)
    assert_true(
        n <= max_differing,
        label + ": " + String(n) + " pixels differ",
    )


def _is_ink(c: Canvas, x: Int, y: Int) -> Bool:
    var p = c.get_pixel(x, y)
    return p.r != BG.r or p.g != BG.g or p.b != BG.b


def _ink_span(c: Canvas, y: Int) -> Int:
    """How many pixels of row `y` carry ink."""
    var n = 0
    for x in range(c.width):
        if _is_ink(c, x, y):
            n += 1
    return n


def _ink_column_span(c: Canvas, x: Int) -> Int:
    var n = 0
    for y in range(c.height):
        if _is_ink(c, x, y):
            n += 1
    return n


def _ink_width(c: Canvas) -> Int:
    var min_x = c.width
    var max_x = -1
    for y in range(c.height):
        for x in range(c.width):
            if _is_ink(c, x, y):
                if x < min_x:
                    min_x = x
                if x > max_x:
                    max_x = x
    if max_x < 0:
        return 0
    return max_x - min_x + 1


# --- Matrix2D ---------------------------------------------------------


def test_matrix_composes_in_call_order() raises:
    # then(): the receiver applies first. Translate then scale doubles
    # the shifted point; scale then translate shifts the doubled one.
    var p = (
        Matrix2D.translation(10.0, 5.0)
        .then(Matrix2D.scaling(2.0, 2.0))
        .apply(1.0, 1.0)
    )
    assert_almost_equal(p.x, 22.0)
    assert_almost_equal(p.y, 12.0)
    var q = (
        Matrix2D.scaling(2.0, 2.0)
        .then(Matrix2D.translation(10.0, 5.0))
        .apply(1.0, 1.0)
    )
    assert_almost_equal(q.x, 12.0)
    assert_almost_equal(q.y, 7.0)


def test_matrix_inverse_round_trips() raises:
    var m = (
        Matrix2D.rotation(0.7)
        .then(Matrix2D.scaling(2.0, 3.0))
        .then(Matrix2D.translation(5.0, -4.0))
    )
    var inv = m.inverse()
    var p = m.apply(3.5, -1.25)
    var back = inv.apply(p.x, p.y)
    assert_almost_equal(back.x, 3.5, atol=1e-9)
    assert_almost_equal(back.y, -1.25, atol=1e-9)
    var both = m.then(inv)
    assert_almost_equal(both.a, 1.0, atol=1e-12)
    assert_almost_equal(both.d, 1.0, atol=1e-12)
    assert_almost_equal(both.e, 0.0, atol=1e-9)

    with assert_raises():
        _ = Matrix2D.scaling(0.0, 1.0).inverse()


def test_matrix_from_transform2d_matches_to_point() raises:
    var t = Transform2D(2.0, -3.0, 10.0, 80.0, 0.4)
    var m = Matrix2D(t)
    for i in range(5):
        var x = Float64(i) * 1.7 - 2.0
        var y = Float64(i) * -0.9 + 1.0
        var want = t.to_point(x, y)
        var got = m.apply(x, y)
        assert_almost_equal(got.x, want.x, atol=1e-9)
        assert_almost_equal(got.y, want.y, atol=1e-9)


def test_matrix_predicates() raises:
    var identity = Matrix2D.identity()
    assert_true(identity.is_identity())
    assert_true(identity.is_translation())
    assert_true(identity.is_axis_aligned())
    assert_true(identity.is_similarity())

    var shift = Matrix2D.translation(3.0, 4.0)
    assert_true(not shift.is_identity())
    assert_true(shift.is_translation())

    var stretch = Matrix2D.scaling(2.0, 3.0)
    assert_true(stretch.is_axis_aligned())
    assert_true(not stretch.is_similarity())
    assert_almost_equal(stretch.scale_factor(), 2.449489742783178)

    var turn = Matrix2D.rotation(0.3).then(Matrix2D.scaling(2.0, 2.0))
    assert_true(not turn.is_axis_aligned())
    assert_true(turn.is_similarity())
    assert_almost_equal(turn.scale_factor(), 2.0)
    assert_almost_equal(turn.rotation_angle(), 0.3)

    var mirror = Matrix2D.scaling(1.0, -1.0)
    assert_true(mirror.is_axis_aligned())
    assert_true(not mirror.is_similarity(), "a mirror is not a similarity")
    assert_true(mirror.determinant() < 0.0)


# --- Canvas state -----------------------------------------------------


def test_canvas_starts_at_the_identity() raises:
    var c = Canvas(W, H, BG)
    assert_true(not c.has_transform())
    assert_true(c.current_transform().is_identity())
    c.restore()  # nothing saved: a no-op
    c.reset_transform()
    assert_true(not c.has_transform())


def test_save_restore_unwinds_transform_and_clips() raises:
    var c = Canvas(W, H, BG)
    c.save()
    c.translate(10.0, 10.0)
    c.push_clip(0, 0, 20, 20)
    var hole = Path()
    hole.rect(2.0, 2.0, 10.0, 10.0)
    c.push_clip_path(hole)
    assert_true(c.has_transform())
    assert_true(c.has_clip_mask())
    c.restore()
    assert_true(not c.has_transform(), "the transform is back")
    assert_true(not c.has_clip_mask(), "the clip path is popped")
    # And the rectangle clip: a fill reaches the whole canvas again.
    fill_rect(c, 0, 0, W, H, INK)
    assert_true(_is_ink(c, W - 1, H - 1), "the clip rect is popped")

    # Nested saves restore in order.
    var d = Canvas(W, H, BG)
    d.translate(5.0, 0.0)
    d.save()
    d.translate(7.0, 0.0)
    d.save()
    d.scale(3.0, 3.0)
    d.restore()
    assert_almost_equal(d.current_transform().e, 12.0)
    assert_almost_equal(d.current_transform().a, 1.0)
    d.restore()
    assert_almost_equal(d.current_transform().e, 5.0)


def test_translate_moves_shapes_exactly() raises:
    var c = Canvas(W, H, BG)
    c.translate(20.0, 10.0)
    fill_rect(c, 5, 5, 30, 20, INK)
    draw_rect(c, 40, 5, 20, 20, INK)
    draw_line(c, 5, 60, 80, 70, INK)
    fill_circle(c, 70, 50, 9, INK)
    var want = Canvas(W, H, BG)
    fill_rect(want, 25, 15, 30, 20, INK)
    draw_rect(want, 60, 15, 20, 20, INK)
    draw_line(want, 25, 70, 100, 80, INK)
    fill_circle(want, 90, 60, 9, INK)
    _assert_same(want, c, "translated hard-edged shapes")
    assert_true(c.has_transform(), "the transform stays set afterwards")


def test_scale_maps_rect_circle_and_ellipse_exactly() raises:
    var c = Canvas(W, H, BG)
    c.scale(2.0, 2.0)
    fill_rect(c, 5, 5, 10, 10, INK)
    fill_circle_aa(c, 30.0, 20.0, 8.0, INK)
    var want = Canvas(W, H, BG)
    fill_rect(want, 10, 10, 20, 20, INK)
    fill_circle_aa(want, 60.0, 40.0, 16.0, INK)
    _assert_same(want, c, "uniformly scaled")

    var e = Canvas(W, H, BG)
    e.scale(3.0, 1.5)
    fill_ellipse_aa(e, 20.0, 30.0, 8.0, 10.0, INK)
    var eref = Canvas(W, H, BG)
    fill_ellipse_aa(eref, 60.0, 45.0, 24.0, 15.0, INK)
    _assert_same(eref, e, "an ellipse under an axis-aligned scale")


def test_flip_gives_a_y_up_frame() raises:
    var c = Canvas(W, H, BG)
    c.translate(0.0, Float64(H))
    c.scale(1.0, -1.0)
    fill_rect(c, 10, 10, 20, 15, INK)
    # Rows 10 through 24 reflect to rows H - 10 through H - 24: the
    # pixels' edges at 9.5 and 24.5 map, not their indices, so the
    # reflection is exact rather than one row off.
    var want = Canvas(W, H, BG)
    fill_rect(want, 10, H - 24, 20, 15, INK)
    _assert_same(want, c, "a y-up rect")


def test_int_rect_is_exact_under_the_supersampling_recipe() raises:
    # translate((f - 1) / 2) then scale(f): an Int rect's edges at
    # x - 0.5 land on device pixel boundaries, so the scaled rect is
    # exactly f times the pixels, at every factor -- and shrinking it
    # back gives the scale-1 rect byte for byte.
    for f in [2, 3, 4]:
        var big = Canvas(f * W, f * H, BG)
        big.translate(Float64(f - 1) / 2.0, Float64(f - 1) / 2.0)
        big.scale(Float64(f), Float64(f))
        fill_rect(big, 5, 7, 10, 6, INK)
        var want = Canvas(f * W, f * H, BG)
        fill_rect(want, 5 * f, 7 * f, 10 * f, 6 * f, INK)
        _assert_same(want, big, "factor " + String(f))
        var plain = Canvas(W, H, BG)
        fill_rect(plain, 5, 7, 10, 6, INK)
        _assert_same(plain, downsample(big, f), "shrunk back at " + String(f))


def test_float_rect_snaps_to_pixel_boundaries() raises:
    # Edges at half-integers are pixel boundaries: (19.5, 4.5) with
    # width 40 is exactly the Int rect from pixel 20.
    var a = Canvas(W, H, BG)
    fill_rect(a, 19.5, 4.5, 40.0, 30.0, INK)
    var b = Canvas(W, H, BG)
    fill_rect(b, 20, 5, 40, 30, INK)
    _assert_same(b, a, "half-integer edges are the Int rect")
    # An edge at 20.4 is nearer the boundary at 20.5, so pixel 20 is
    # out and the rect starts at 21; its far edge at 60.4 keeps pixel
    # 60 in.
    var c = Canvas(W, H, BG)
    fill_rect(c, 20.4, 5.0, 40.0, 30.0, INK)
    assert_true(c.get_pixel(20, 10).r == BG.r, "pixel 20 is out")
    assert_true(c.get_pixel(21, 10).r == INK.r, "pixel 21 is in")
    assert_true(c.get_pixel(60, 10).r == INK.r, "pixel 60 is in")
    assert_true(c.get_pixel(61, 10).r == BG.r, "pixel 61 is out")
    # Under scale(2) the float rect maps then snaps in device space:
    # the edge at 19.5 lands on device 39.0, a pixel center, and the
    # tie goes to the higher boundary, 39.5, so the rect starts at 40.
    var d = Canvas(W, H, BG)
    d.scale(2.0, 2.0)
    fill_rect(d, 19.5, 4.5, 20.0, 10.0, INK)
    var e = Canvas(W, H, BG)
    fill_rect(e, 40, 10, 40, 20, INK)
    _assert_same(e, d, "mapped then snapped")


def test_rotation_routes_a_rect_through_the_path_fill() raises:
    var c = Canvas(W, H, BG)
    c.translate(60.0, 45.0)
    c.rotate(pi / 4.0)
    fill_rect(c, -20, -10, 40, 20, INK)
    var m = Matrix2D.rotation(pi / 4.0).then(Matrix2D.translation(60.0, 45.0))
    # The Int rect's pixels span -20.5 to 19.5: those edges rotate.
    var p = Path()
    p.rect(-20.5, -10.5, 40.0, 20.0)
    var want = Canvas(W, H, BG)
    fill_path(want, p.transformed(m), INK)
    _assert_same(want, c, "a rotated rect")
    assert_true(_is_ink(c, 60, 45), "center is inked")
    assert_true(not _is_ink(c, 60 + 25, 45), "the unrotated corner is not")


def test_path_fills_map_through_the_transform() raises:
    var p = Path()
    p.move_to(0.0, 0.0)
    p.cubic_curve_to(10.0, -20.0, 30.0, 20.0, 40.0, 0.0)
    p.line_to(20.0, 15.0)
    p.close()
    var m = (
        Matrix2D.rotation(0.5)
        .then(Matrix2D.scaling(1.5, 1.5))
        .then(Matrix2D.translation(50.0, 40.0))
    )

    var c = Canvas(W, H, BG)
    c.set_transform(m)
    fill_path_aa(c, p, INK)
    var want = Canvas(W, H, BG)
    fill_path_aa(want, p.transformed(m), INK)
    _assert_same(want, c, "fill_path_aa under a transform")


def test_polygon_points_map_exactly() raises:
    var tri: List[FPoint] = [
        FPoint(5.0, 5.0),
        FPoint(45.5, 12.0),
        FPoint(20.0, 40.25),
    ]
    var c = Canvas(W, H, BG)
    c.translate(10.0, 10.0)
    fill_polygon_aa(c, tri, INK)
    var shifted: List[FPoint] = [
        FPoint(15.0, 15.0),
        FPoint(55.5, 22.0),
        FPoint(30.0, 50.25),
    ]
    var want = Canvas(W, H, BG)
    fill_polygon_aa(want, shifted, INK)
    _assert_same(want, c, "a translated polygon")


def test_stroke_under_translation_matches_a_direct_stroke() raises:
    var pts: List[FPoint] = [
        FPoint(5.0, 40.0),
        FPoint(30.0, 10.0),
        FPoint(55.0, 50.0),
        FPoint(80.0, 20.0),
    ]
    var c = Canvas(W, H, BG)
    c.translate(10.0, 5.0)
    draw_polyline_aa(c, pts, INK, width=3.0)
    var moved: List[FPoint] = [
        FPoint(15.0, 45.0),
        FPoint(40.0, 15.0),
        FPoint(65.0, 55.0),
        FPoint(90.0, 25.0),
    ]
    var want = Canvas(W, H, BG)
    draw_polyline_aa(want, moved, INK, width=3.0)
    _assert_nearly_same(want, c, 8, "a translated stroke")


def test_stroke_width_follows_a_non_uniform_scale() raises:
    # Strokes are built in user space, so a 2-wide line stretched 4x
    # horizontally is ~8 pixels across, while the same stroke drawn
    # horizontally is still ~2 pixels tall.
    var v = Canvas(W, H, BG)
    v.scale(4.0, 1.0)
    draw_line_aa(v, 10.0, 10.0, 10.0, 70.0, INK, width=2.0)
    var across = _ink_span(v, 40)
    assert_true(across >= 8 and across <= 10, String(across) + " wide")

    var h = Canvas(W, H, BG)
    h.scale(4.0, 1.0)
    draw_line_aa(h, 5.0, 40.0, 25.0, 40.0, INK, width=2.0)
    var tall = _ink_column_span(h, 60)
    assert_true(tall >= 2 and tall <= 4, String(tall) + " tall")
    var long = _ink_span(h, 40)
    assert_true(long >= 80, String(long) + " long: the length scaled 4x")


def test_gradient_samples_in_user_space() raises:
    var g = LinearGradient(0.0, 0.0, 40.0, 0.0)
    g.add_stop(0.0, Color(255, 0, 0))
    g.add_stop(1.0, Color(0, 0, 255))
    var c = Canvas(W, H, BG)
    c.translate(30.0, 20.0)
    fill_rect_gradient(c, 0, 0, 40, 20, g)

    var gref = LinearGradient(30.0, 20.0, 70.0, 20.0)
    gref.add_stop(0.0, Color(255, 0, 0))
    gref.add_stop(1.0, Color(0, 0, 255))
    var want = Canvas(W, H, BG)
    fill_rect_gradient(want, 30, 20, 40, 20, gref)
    _assert_nearly_same(want, c, 0, "a translated gradient")

    # Under a scale the gradient stretches with the rectangle: the
    # midpoint color sits at the rectangle's middle, not 20 px in.
    var s = Canvas(W, H, BG)
    s.scale(2.0, 1.0)
    fill_rect_gradient(s, 0, 0, 40, 20, g)
    var mid = s.get_pixel(40, 10)
    var quarter = s.get_pixel(20, 10)
    assert_true(mid.b > 100 and mid.r > 100, "mid-rectangle is mid-gradient")
    assert_true(quarter.r > mid.r, "a quarter of the way in is redder")


def test_rotated_clip_rect_becomes_a_clip_path() raises:
    var c = Canvas(W, H, BG)
    c.translate(60.0, 45.0)
    c.rotate(pi / 4.0)
    c.push_clip(-20, -20, 40, 40)
    assert_true(c.has_clip_mask(), "a rotated clip rect is a mask")
    c.reset_transform()
    fill_rect(c, 0, 0, W, H, INK)
    assert_true(_is_ink(c, 60, 45), "inside the diamond")
    assert_true(_is_ink(c, 60 + 24, 45), "inside, along the diagonal")
    assert_true(not _is_ink(c, 60, 45 + 30), "past the diamond's tip")
    assert_true(not _is_ink(c, 5, 5), "the corner is clipped out")
    c.pop_clip()
    assert_true(not c.has_clip_mask(), "pop_clip took the mask with it")

    # An axis-aligned transform keeps a rectangle clip a rectangle.
    var r = Canvas(W, H, BG)
    r.scale(2.0, 2.0)
    r.push_clip(5, 5, 10, 10)
    assert_true(not r.has_clip_mask())
    r.reset_transform()
    fill_rect(r, 0, 0, W, H, INK)
    assert_true(_is_ink(r, 10, 10))
    assert_true(_is_ink(r, 29, 29))
    assert_true(not _is_ink(r, 30, 30))


def test_arc_and_ring_under_a_similarity() raises:
    var c = Canvas(W, H, BG)
    c.translate(60.0, 45.0)
    c.rotate(pi / 2.0)
    c.scale(1.5, 1.5)
    fill_arc_aa(c, 0.0, 0.0, 20.0, 0.0, pi / 2.0, INK)
    fill_ring_sector_aa(c, 0.0, 0.0, 22.0, 26.0, pi, 1.5 * pi, INK)
    var want = Canvas(W, H, BG)
    fill_arc_aa(want, 60.0, 45.0, 30.0, pi / 2.0, pi, INK)
    fill_ring_sector_aa(want, 60.0, 45.0, 33.0, 39.0, 1.5 * pi, 2.0 * pi, INK)
    _assert_nearly_same(want, c, 4, "arc and ring turned a quarter")

    # Under a non-uniform scale the wedge goes through the path fill
    # and comes out stretched: twice as wide as it is tall.
    var s = Canvas(W, H, BG)
    s.translate(60.0, 45.0)
    s.scale(2.0, 1.0)
    fill_arc_aa(s, 0.0, 0.0, 20.0, 0.0, 2.0 * pi, INK)
    assert_true(_is_ink(s, 60 + 38, 45), "38 px right of center is inside")
    assert_true(not _is_ink(s, 60, 45 + 22), "22 px below is not")


def test_draw_canvas_under_translation() raises:
    var src = Canvas(10, 8, INK)
    var dst = Canvas(W, H, BG)
    dst.translate(7.0, 3.0)
    draw_canvas(dst, src, 10, 10)
    var want = Canvas(W, H, BG)
    draw_canvas(want, src, 17, 13)
    _assert_same(want, dst, "a translated blit")


def test_text_under_translation_matches_a_shifted_anchor() raises:
    var cache = FontCache()
    var c = Canvas(W, H, BG)
    c.translate(15.0, 5.0)
    draw_text(c, 10, 40, "Ab", INK, 16.0, cache=cache)
    var want = Canvas(W, H, BG)
    draw_text(want, 25, 45, "Ab", INK, 16.0, cache=cache)
    _assert_same(want, c, "translated text")


def test_text_under_scale_and_rotation() raises:
    var cache = FontCache()
    var plain = Canvas(W, H, BG)
    draw_text(plain, 10, 40, "Abc", INK, 12.0, cache=cache)
    var plain_width = _ink_width(plain)

    var big = Canvas(W, H, BG)
    big.scale(2.0, 2.0)
    draw_text(big, 5, 20, "Abc", INK, 12.0, cache=cache)
    var big_width = _ink_width(big)
    assert_true(
        big_width >= 2 * plain_width - 3 and big_width <= 2 * plain_width + 3,
        String(plain_width) + " -> " + String(big_width),
    )

    # Rotated a quarter turn anticlockwise: the baseline runs up from
    # the anchor and the glyphs extend to its left, so the ink sits in
    # the columns just left of x = 40 and is narrower than upright.
    var up = Canvas(W, H, BG)
    up.translate(40.0, 80.0)
    up.rotate(-pi / 2.0)
    draw_text(up, 0, 0, "Abc", INK, 12.0, cache=cache)
    assert_true(_ink_column_span(up, 37) > 0, "rotated text has ink")
    assert_true(_ink_column_span(up, 45) == 0, "none right of the anchor")
    assert_true(_ink_width(up) < plain_width, "and is narrower than upright")


def _ink_centroid(c: Canvas) -> FPoint:
    """The ink-weighted center of everything drawn, in pixels."""
    var sum_x = 0.0
    var sum_y = 0.0
    var total = 0.0
    for y in range(c.height):
        for x in range(c.width):
            var p = c.get_pixel(x, y)
            var ink = Float64(255 - Int(p.r))
            if ink > 0.0:
                sum_x += ink * Float64(x)
                sum_y += ink * Float64(y)
                total += ink
    if total == 0.0:
        return FPoint(-1.0, -1.0)
    return FPoint(sum_x / total, sum_y / total)


def _max_channel_diff(a: Canvas, b: Canvas) -> Int:
    var worst = 0
    for y in range(a.height):
        for x in range(a.width):
            var pa = a.get_pixel(x, y)
            var pb = b.get_pixel(x, y)
            var d = abs(Int(pa.r) - Int(pb.r))
            if d > worst:
                worst = d
    return worst


def test_scaled_text_through_the_cache_matches_the_direct_fill() raises:
    # Under scale(3) the glyphs come from the mask cache, rasterized
    # at the placed size and composited at a 1/64-px-quantized origin.
    # The direct outline fill of the same placement is the reference:
    # the two must agree to within the quantization's effect on edge
    # pixels, and have the same ink extent.
    var cache = FontCache()
    var cached = Canvas(W, H, BG)
    cached.scale(3.0, 3.0)
    draw_text(cached, 3.4, 20.7, "Abc", INK, 12.0, cache=cache)

    var direct = Canvas(W, H, BG)
    var block = _layout_block(
        "Abc",
        12.0,
        "Sans",
        FontSlant.NORMAL,
        FontWeight.NORMAL,
        0.0,
        TextAlign.LEFT,
        True,
        True,
        cache,
    )
    var placement = Matrix2D.translation(3.4, 20.7).then(
        Matrix2D.scaling(3.0, 3.0)
    )
    _draw_block_direct(
        direct,
        block,
        placement,
        INK,
        12.0,
        "Sans",
        FontSlant.NORMAL,
        FontWeight.NORMAL,
        cache,
    )
    assert_equal(_ink_width(cached), _ink_width(direct), "same ink width")
    var diff = _max_channel_diff(cached, direct)
    assert_true(diff <= 48, "edge pixels within quantization: " + String(diff))
    var cc = _ink_centroid(cached)
    var dc = _ink_centroid(direct)
    assert_true(
        abs(cc.x - dc.x) < 0.1 and abs(cc.y - dc.y) < 0.1,
        "same centroid: " + String(cc.x) + " vs " + String(dc.x),
    )


def test_supersampling_places_text_where_scale_one_does() raises:
    # Rendering at a factor s and shrinking with `downsample` averages,
    # into output pixel p, the device block whose center is user
    # p + (s - 1) / (2 s), so a drawing scaled by s alone shows up that
    # much *early* after the shrink -- 3/8 px at s = 4, for every
    # primitive, not only text. The recipe `downsample` documents,
    # translate by (s - 1) / 2 before the scale, cancels it; this pins
    # both halves.
    var cache = FontCache()
    var plain = Canvas(W, H, BG)
    draw_text(plain, 10.3, 25.6, "Abc", INK, 12.0, cache=cache)
    var a = _ink_centroid(plain)
    assert_true(a.x >= 0.0, "drew ink")

    var offset = Canvas(4 * W, 4 * H, BG)
    offset.translate(1.5, 1.5)
    offset.scale(4.0, 4.0)
    draw_text(offset, 10.3, 25.6, "Abc", INK, 12.0, cache=cache)
    var b = _ink_centroid(downsample(offset, 4))
    assert_true(
        abs(a.x - b.x) < 0.05 and abs(a.y - b.y) < 0.05,
        "with the offset: " + String(b.x - a.x) + ", " + String(b.y - a.y),
    )

    var bare = Canvas(4 * W, 4 * H, BG)
    bare.scale(4.0, 4.0)
    draw_text(bare, 10.3, 25.6, "Abc", INK, 12.0, cache=cache)
    var c = _ink_centroid(downsample(bare, 4))
    assert_true(
        abs((a.x - c.x) - 0.375) < 0.03 and abs((a.y - c.y) - 0.375) < 0.03,
        "without it, 3/8 px early: "
        + String(c.x - a.x)
        + ", "
        + String(c.y - a.y),
    )


def test_scaled_and_rotated_text_hit_the_glyph_mask_cache() raises:
    var cache = FontCache()
    var c = Canvas(W, H, BG)
    c.scale(3.0, 3.0)
    draw_text(c, 3, 20, "Abc", INK, 12.0, cache=cache)
    var after_first = cache.glyph_mask_count()
    assert_true(after_first >= 3, "one mask per glyph at least")
    draw_text(c, 3, 20, "Abc", INK, 12.0, cache=cache)
    assert_equal(
        cache.glyph_mask_count(), after_first, "the second draw is all hits"
    )
    c.reset_transform()
    c.scale(2.0, 2.0)
    draw_text(c, 3, 20, "Abc", INK, 12.0, cache=cache)
    assert_true(
        cache.glyph_mask_count() > after_first, "a new scale is a new key"
    )
    var before_rotated = cache.glyph_mask_count()
    var r = Canvas(W, H, BG)
    draw_text(r, 40, 60, "Abc", INK, 12.0, rotation=0.5, cache=cache)
    assert_true(
        cache.glyph_mask_count() > before_rotated, "rotated glyphs are cached"
    )
    var after_rotated = cache.glyph_mask_count()
    draw_text(r, 40, 60, "Abc", INK, 12.0, rotation=0.5, cache=cache)
    assert_equal(cache.glyph_mask_count(), after_rotated, "and hit again")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
