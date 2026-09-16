"""Tests for canvas/bounds.mojo: `BoundsTarget`, the `DrawTarget` that
measures instead of drawing. The check that matters most is the last
group: every primitive drawn into a `Canvas` and into a `BoundsTarget`
through one generic function, the canvas scanned for ink, and the two
boxes compared. That is the only test that the answer is the ink and
not the geometry someone assumed the ink would be.
"""

from std.math import pi
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from canvas.blend import BlendMode
from canvas.bounds import BoundsTarget
from canvas.buffer import Canvas
from canvas.color import Color, ColorSpace
from canvas.geometry import FPoint, Matrix2D
from canvas.path import Path
from canvas.shapes.lines import LineCap, LineJoin
from canvas.text.font_cache import FontCache
from canvas.text.render import text_run_anchors
from canvas.text.text_align import TextAlign
from canvas.text.text_run import TextRun
from canvas.vector.draw_target import DrawTarget

comptime BG = Color(255, 255, 255)
comptime INK = Color(20, 40, 200)


def _scan(c: Canvas) -> Tuple[Bool, Int, Int, Int, Int]:
    """The whole-pixel box around every pixel that is not `BG`, as
    (found, x, y, width, height)."""
    var found = False
    var min_x = 0
    var min_y = 0
    var max_x = 0
    var max_y = 0
    for y in range(c.height):
        for x in range(c.width):
            var p = c.get_pixel(x, y)
            if p.r == BG.r and p.g == BG.g and p.b == BG.b:
                continue
            if not found:
                min_x = x
                max_x = x
                min_y = y
                max_y = y
                found = True
                continue
            min_x = min(min_x, x)
            max_x = max(max_x, x)
            min_y = min(min_y, y)
            max_y = max(max_y, y)
    if not found:
        return (False, 0, 0, 0, 0)
    return (True, min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)


def _assert_box(
    got: Tuple[Int, Int, Int, Int],
    x: Int,
    y: Int,
    w: Int,
    h: Int,
    label: String,
) raises:
    assert_equal(got[0], x, label + " (x)")
    assert_equal(got[1], y, label + " (y)")
    assert_equal(got[2], w, label + " (width)")
    assert_equal(got[3], h, label + " (height)")


# --- The union on its own -------------------------------------------------


def test_nothing_drawn_has_no_ink() raises:
    var b = BoundsTarget(100, 80)
    assert_false(b.has_ink())
    _assert_box(b.ink_pixels(), 0, 0, 0, 0, "empty")
    var g = b.ink_bounds()
    assert_equal(g[0], 0.0)
    assert_equal(g[2], 0.0)


def test_pixel_rect_is_exact() raises:
    var b = BoundsTarget(100, 80)
    b.fill_rect(10, 20, 30, 15, INK)
    assert_true(b.has_ink())
    _assert_box(b.ink_pixels(), 10, 20, 30, 15, "pixel rect")
    var g = b.ink_bounds()
    assert_equal(g[0], 9.5)
    assert_equal(g[1], 19.5)
    assert_equal(g[2], 39.5)
    assert_equal(g[3], 34.5)


def test_geometric_rect_snaps_like_fill_rect() raises:
    # Edges at 19.5 and 59.5 are pixel boundaries: pixels 20..59.
    var b = BoundsTarget(100, 80)
    b.fill_rect(19.5, 4.5, 40.0, 30.0, INK)
    _assert_box(b.ink_pixels(), 20, 5, 40, 30, "boundary edges")
    # An edge at 20.4 snaps to 20.5, so pixel 20 is out.
    var c = BoundsTarget(100, 80)
    c.fill_rect(20.4, 4.5, 39.1, 30.0, INK)
    _assert_box(c.ink_pixels(), 21, 5, 39, 30, "snapped edges")


def test_zero_size_shapes_add_nothing() raises:
    var b = BoundsTarget(100, 80)
    b.fill_rect(10, 10, 0, 5, INK)
    b.fill_rect(10.0, 10.0, 0.2, 5.0, INK)
    b.fill_circle_aa(50.0, 40.0, 0.0, INK)
    b.fill_circles_aa(List[FPoint](), 3.0, INK)
    b.fill_path_aa(Path(), INK)
    assert_false(b.has_ink())


def test_union_grows_across_calls() raises:
    var b = BoundsTarget(200, 200)
    b.fill_rect(10, 10, 5, 5, INK)
    b.fill_rect(100, 150, 5, 5, INK)
    _assert_box(b.ink_pixels(), 10, 10, 95, 145, "two rects")


def test_stroke_box_is_wider_than_its_fill() raises:
    var p = Path()
    p.move_to(20.0, 20.0)
    p.line_to(80.0, 20.0)
    p.line_to(80.0, 60.0)
    p.close()
    var fill = BoundsTarget(200, 200)
    fill.fill_path_aa(p, INK)
    var stroke = BoundsTarget(200, 200)
    stroke.stroke_path_aa(p, INK, width=6.0, join=LineJoin.MITER)
    var f = fill.ink_bounds()
    var s = stroke.ink_bounds()
    assert_true(s[0] < f[0], "stroke starts left of fill")
    assert_true(s[1] < f[1], "stroke starts above fill")
    assert_true(s[2] > f[2], "stroke ends right of fill")
    assert_true(s[3] > f[3], "stroke ends below fill")
    # The corner at (20, 20) is acute (about 34 degrees), so its MITER
    # tip reaches about 10 px past the vertex, well beyond the half
    # width a cap or a BEVEL would add; the right angle at (80, 20)
    # reaches exactly half the width and would not tell the two apart.
    assert_true(s[0] < 20.0 - 3.0 - 1.0, "miter spike counts")


def test_circle_box_is_center_plus_radius() raises:
    var b = BoundsTarget(200, 200)
    b.fill_circle_aa(50, 60, 10, INK)
    var g = b.ink_bounds()
    assert_true(abs(g[0] - 40.0) < 0.01, "left")
    assert_true(abs(g[1] - 50.0) < 0.01, "top")
    assert_true(abs(g[2] - 60.0) < 0.01, "right")
    assert_true(abs(g[3] - 70.0) < 0.01, "bottom")
    _assert_box(b.ink_pixels(), 40, 50, 21, 21, "disk pixels")


def test_ring_outline_reaches_outer_edge() raises:
    var b = BoundsTarget(200, 200)
    b.draw_circle_aa(50.0, 50.0, 10.0, INK, width=4.0)
    var g = b.ink_bounds()
    assert_true(abs(g[0] - 38.0) < 0.01, "outer edge is radius + width/2")


def test_image_contributes_its_own_size() raises:
    var img = Canvas(16, 8, INK)
    var b = BoundsTarget(200, 200)
    b.draw_image(img, 10.5, 20.5)
    _assert_box(b.ink_pixels(), 11, 21, 16, 8, "image at own size")
    var s = BoundsTarget(200, 200)
    s.draw_image(img, 10.5, 20.5, 32.0, 4.0)
    _assert_box(s.ink_pixels(), 11, 21, 32, 4, "image scaled")


def test_mesh_counts_only_referenced_vertices() raises:
    var pts: List[FPoint] = [
        FPoint(10.0, 10.0),
        FPoint(30.0, 10.0),
        FPoint(10.0, 30.0),
        FPoint(150.0, 150.0),
    ]
    var faces: List[Int] = [0, 1, 2]
    var colors: List[Color] = [INK]
    var b = BoundsTarget(200, 200)
    b.fill_mesh(pts, faces, colors)
    var g = b.ink_bounds()
    assert_equal(g[2], 30.0, "unused vertex does not count")


def test_text_contributes_its_block() raises:
    var cache = FontCache()
    var b = BoundsTarget(300, 100)
    b.draw_text(20.0, 50.0, "Tight", INK, 16.0, cache=cache)
    assert_true(b.has_ink())
    var g = b.ink_bounds()
    assert_true(g[0] >= 19.0 and g[0] < 25.0, "starts near the anchor")
    assert_true(g[3] > g[1] + 8.0, "has a line's height")
    var e = BoundsTarget(300, 100)
    e.draw_text(20.0, 50.0, "", INK, 16.0, cache=cache)
    assert_false(e.has_ink(), "empty text is no ink")


def test_text_runs_bound_the_union_of_their_runs() raises:
    var cache = FontCache()
    var runs: List[TextRun] = [TextRun("x", 24.0), TextRun("2", 16.0, dy=-9.0)]
    var b = BoundsTarget(300, 100)
    b.draw_text_runs(20.0, 50.0, runs, INK, cache=cache)
    var d = BoundsTarget(300, 100)
    var anchors = text_run_anchors(20.0, 50.0, runs, cache=cache)
    for i in range(len(runs)):
        d.draw_text(
            anchors[i].x,
            anchors[i].y,
            runs[i].text,
            INK,
            runs[i].size,
            cache=cache,
        )
    var got = b.ink_bounds()
    var want = d.ink_bounds()
    assert_equal(got[0], want[0], "the runs' box is draw_text's per run")
    assert_equal(got[1], want[1], "the runs' box is draw_text's per run")
    assert_equal(got[2], want[2], "the runs' box is draw_text's per run")
    assert_equal(got[3], want[3], "the runs' box is draw_text's per run")
    var base = BoundsTarget(300, 100)
    base.draw_text(20.0, 50.0, "x", INK, 24.0, cache=cache)
    assert_true(got[1] < base.ink_bounds()[1], "the superscript reaches above")
    var empty: List[TextRun] = [TextRun("", 24.0)]
    var e = BoundsTarget(300, 100)
    e.draw_text_runs(20.0, 50.0, empty, INK, cache=cache)
    assert_false(e.has_ink(), "an empty run is no ink")


# --- Clips, page, state ---------------------------------------------------


def test_clip_confines_and_excludes() raises:
    var b = BoundsTarget(200, 200)
    b.push_clip(50, 50, 20, 20)
    b.fill_rect(0, 0, 10, 10, INK)
    assert_false(b.has_ink(), "wholly outside the clip")
    b.fill_rect(40, 40, 100, 100, INK)
    _assert_box(b.ink_pixels(), 50, 50, 20, 20, "confined to the clip")
    b.pop_clip()
    b.fill_rect(0, 0, 10, 10, INK)
    _assert_box(b.ink_pixels(), 0, 0, 70, 70, "after pop")


def test_nested_clips_intersect() raises:
    var b = BoundsTarget(200, 200)
    b.push_clip(0, 0, 100, 100)
    b.push_clip(50, 50, 100, 100)
    b.fill_rect(0, 0, 200, 200, INK)
    _assert_box(b.ink_pixels(), 50, 50, 50, 50, "intersection")


def test_page_clips_ink() raises:
    var b = BoundsTarget(100, 100)
    b.fill_rect(-20, -20, 40, 40, INK)
    _assert_box(b.ink_pixels(), 0, 0, 20, 20, "partly off page")
    var off = BoundsTarget(100, 100)
    off.fill_circle_aa(150.0, 150.0, 10.0, INK)
    assert_false(off.has_ink(), "wholly off page")


def test_translate_moves_the_box() raises:
    var b = BoundsTarget(200, 200)
    b.translate(30.0, 40.0)
    b.fill_rect(10, 10, 5, 5, INK)
    _assert_box(b.ink_pixels(), 40, 50, 5, 5, "translated")


def test_scale_grows_the_box() raises:
    var b = BoundsTarget(200, 200)
    b.scale(2.0, 3.0)
    # Edges land on pixel boundaries after the scale (20.5, 31.5), so
    # no snapping tie is involved: pixels 21..30 by 32..46.
    b.fill_rect(10.25, 10.5, 5.0, 5.0, INK)
    _assert_box(b.ink_pixels(), 21, 32, 10, 15, "scaled")


def test_rotation_maps_geometry() raises:
    # A quarter turn about the origin, then translated back on page:
    # the rect (10..20, 0..5) lands at x in -5..0, y in 10..20 before
    # the translation, so at x 95..100, y 10..20 after.
    var b = BoundsTarget(200, 200)
    b.translate(100.0, 0.0)
    b.rotate(pi / 2.0)
    b.fill_rect(10.0, 0.0, 10.0, 5.0, INK)
    var g = b.ink_bounds()
    assert_true(abs(g[0] - 95.0) < 0.01, "left")
    assert_true(abs(g[1] - 10.0) < 0.01, "top")
    assert_true(abs(g[2] - 100.0) < 0.01, "right")
    assert_true(abs(g[3] - 20.0) < 0.01, "bottom")


def test_save_restore_puts_back_state_and_clips() raises:
    var b = BoundsTarget(200, 200)
    b.save()
    b.translate(50.0, 50.0)
    b.push_clip(0, 0, 10, 10)
    b.set_blend_mode(BlendMode.MULTIPLY)
    b.set_color_space(ColorSpace.LINEAR)
    b.restore()
    assert_false(b.has_transform())
    assert_true(b.blend_mode() == BlendMode.SOURCE_OVER)
    assert_true(b.color_space() == ColorSpace.SRGB)
    b.fill_rect(100, 100, 5, 5, INK)
    _assert_box(b.ink_pixels(), 100, 100, 5, 5, "clip popped by restore")
    b.restore()  # nothing saved: a no-op
    b.pop_clip()  # nothing pushed: a no-op


def test_reset_forgets_everything() raises:
    var b = BoundsTarget(200, 200)
    b.translate(10.0, 10.0)
    b.push_clip(0, 0, 50, 50)
    b.fill_rect(0, 0, 5, 5, INK)
    b.reset()
    assert_false(b.has_ink())
    assert_false(b.has_transform())
    b.fill_rect(100, 100, 5, 5, INK)
    _assert_box(b.ink_pixels(), 100, 100, 5, 5, "clip gone")


def test_groups_and_batches_are_no_ops() raises:
    var b = BoundsTarget(200, 200)
    b.begin_annotated_group("series")
    b.begin_batch()
    b.fill_rect(10, 10, 5, 5, INK)
    b.end_batch()
    b.end_annotated_group()
    _assert_box(b.ink_pixels(), 10, 10, 5, 5, "inside group and batch")


def test_repeated_measurement_is_stable() raises:
    var b = BoundsTarget(200, 200)
    for _ in range(12):
        b.fill_circle_aa(50.0, 50.0, 10.0, INK)
        _assert_box(b.ink_pixels(), 40, 40, 21, 21, "same box each time")


# --- Against the ink ------------------------------------------------------
#
# One primitive at a time, drawn into a `Canvas` and a `BoundsTarget`
# through the same generic function, and the canvas scanned. The rule:
# every inked pixel is inside the box, and the box is at most one pixel
# wider on any side. That one pixel is a geometric extent whose
# coverage rounds to zero, which the box counts and the scan cannot.

comptime _KINDS = 14


def _one[T: DrawTarget](mut t: T, kind: Int, mut cache: FontCache) raises:
    var pts: List[FPoint] = [
        FPoint(30.3, 40.6),
        FPoint(70.1, 45.2),
        FPoint(50.8, 80.9),
    ]
    if kind == 0:
        t.fill_rect(20, 30, 40, 25, INK)
    elif kind == 1:
        t.fill_rect(20.3, 30.7, 40.2, 25.9, INK)
    elif kind == 2:
        t.fill_circle_aa(60.4, 50.6, 17.3, INK)
    elif kind == 3:
        t.fill_ellipse_aa(60.4, 50.6, 27.3, 11.1, INK)
    elif kind == 4:
        t.draw_line_aa(
            20.5, 30.5, 90.2, 70.8, INK, width=5.0, cap=LineCap.SQUARE
        )
    elif kind == 5:
        var p = Path()
        p.move_to(20.0, 70.0)
        p.line_to(60.0, 20.0)
        p.line_to(70.0, 75.0)
        t.stroke_path_aa(p, INK, width=6.0, join=LineJoin.MITER)
    elif kind == 6:
        var p = Path()
        p.move_to(20.0, 70.0)
        p.line_to(90.0, 70.0)
        var dashes: List[Float64] = [10.0, 40.0]
        t.stroke_path_aa(p, INK, width=3.0, dashes=dashes, cap=LineCap.BUTT)
    elif kind == 7:
        t.fill_ellipses_aa(pts, 6.3, 4.1, INK)
    elif kind == 8:
        t.fill_arc_aa(60.0, 55.0, 25.0, 0.3, 2.4, INK)
    elif kind == 9:
        t.fill_ring_sector_aa(60.0, 55.0, 12.0, 25.0, 3.5, 5.9, INK)
    elif kind == 10:
        var faces: List[Int] = [0, 1, 2]
        var colors: List[Color] = [INK]
        t.fill_mesh(pts, faces, colors)
    elif kind == 11:
        var img = Canvas(12, 9, INK)
        t.draw_image(img, 30.4, 40.2)
    elif kind == 12:
        t.draw_text(30.0, 60.0, "Ink box", INK, 18.0, cache=cache)
    elif kind == 13:
        t.draw_circle_aa(60.4, 50.6, 17.3, INK, width=3.0)


def _scene[T: DrawTarget](mut t: T, mut cache: FontCache) raises:
    """Everything at once, under a translation and a clip that cuts
    the scene's top-left corner off."""
    t.translate(7.0, 11.0)
    t.push_clip(25, 35, 100, 100)
    for kind in range(_KINDS):
        _one(t, kind, cache)
    t.pop_clip()


def _check_against_scan(c: Canvas, b: BoundsTarget, label: String) raises:
    var s = _scan(c)
    var box = b.ink_pixels()
    assert_equal(s[0], b.has_ink(), label + ": ink present")
    if not s[0]:
        return
    var sx0 = s[1]
    var sy0 = s[2]
    var sx1 = s[1] + s[3] - 1
    var sy1 = s[2] + s[4] - 1
    var bx0 = box[0]
    var by0 = box[1]
    var bx1 = box[0] + box[2] - 1
    var by1 = box[1] + box[3] - 1
    var detail = String(
        ": scan ",
        sx0,
        ",",
        sy0,
        "-",
        sx1,
        ",",
        sy1,
        " box ",
        bx0,
        ",",
        by0,
        "-",
        bx1,
        ",",
        by1,
    )
    assert_true(bx0 <= sx0, label + " box covers scan left" + detail)
    assert_true(by0 <= sy0, label + " box covers scan top" + detail)
    assert_true(bx1 >= sx1, label + " box covers scan right" + detail)
    assert_true(by1 >= sy1, label + " box covers scan bottom" + detail)
    assert_true(sx0 - bx0 <= 1, label + " box tight left" + detail)
    assert_true(sy0 - by0 <= 1, label + " box tight top" + detail)
    assert_true(bx1 - sx1 <= 1, label + " box tight right" + detail)
    assert_true(by1 - sy1 <= 1, label + " box tight bottom" + detail)


def test_each_primitive_matches_a_raster_scan() raises:
    var cache = FontCache()
    for kind in range(_KINDS):
        var c = Canvas(120, 100, BG)
        var b = BoundsTarget(120, 100)
        _one(c, kind, cache)
        _one(b, kind, cache)
        _check_against_scan(c, b, String("kind ", kind))


def test_each_primitive_matches_a_raster_scan_under_a_similarity() raises:
    var cache = FontCache()
    for kind in range(_KINDS):
        var c = Canvas(160, 140, BG)
        var b = BoundsTarget(160, 140)
        c.translate(20.0, 30.0)
        c.scale(1.5, 1.5)
        b.translate(20.0, 30.0)
        b.scale(1.5, 1.5)
        _one(c, kind, cache)
        _one(b, kind, cache)
        _check_against_scan(c, b, String("scaled kind ", kind))


def test_scene_matches_a_raster_scan() raises:
    var cache = FontCache()
    var c = Canvas(140, 120, BG)
    var b = BoundsTarget(140, 120)
    _scene(c, cache)
    _scene(b, cache)
    _check_against_scan(c, b, "scene")


def test_rotated_scene_box_covers_the_ink() raises:
    """Under a canvas rotation text is measured as a mapped box and
    is generous; the rule that survives is that nothing inked falls
    outside the box."""
    var cache = FontCache()
    var c = Canvas(200, 200, BG)
    var b = BoundsTarget(200, 200)
    c.translate(100.0, 20.0)
    c.rotate(0.4)
    b.translate(100.0, 20.0)
    b.rotate(0.4)
    for kind in range(_KINDS):
        _one(c, kind, cache)
        _one(b, kind, cache)
    var s = _scan(c)
    var box = b.ink_pixels()
    assert_true(s[0] and b.has_ink())
    assert_true(box[0] <= s[1], "left")
    assert_true(box[1] <= s[2], "top")
    assert_true(box[0] + box[2] >= s[1] + s[3], "right")
    assert_true(box[1] + box[3] >= s[2] + s[4], "bottom")


def test_crop_recipe_lands_ink_at_the_origin() raises:
    """The use the target exists for: measure, size a canvas to the
    box, draw again translated by minus the box's corner."""
    var cache = FontCache()
    var b = BoundsTarget(300, 300)
    _scene(b, cache)
    var box = b.ink_pixels()
    var crop = Canvas(box[2], box[3], BG)
    crop.translate(-Float64(box[0]), -Float64(box[1]))
    _scene(crop, cache)
    var s = _scan(crop)
    assert_true(s[0], "the crop has ink")
    assert_true(s[1] <= 1 and s[2] <= 1, "ink starts at the crop's corner")
    assert_true(
        s[1] + s[3] >= crop.width - 1 and s[2] + s[4] >= crop.height - 1,
        "ink reaches the crop's far edge",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
