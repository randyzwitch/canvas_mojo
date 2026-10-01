"""Retained scenes: output parity, replay isolation and resource lifetime."""

from std.testing import TestSuite, assert_equal, assert_true, assert_false
from canvas import (
    Canvas,
    BoundsTarget,
    Color,
    ColorSpace,
    BlendMode,
    DrawTarget,
    FontCache,
    FontSlant,
    FontWeight,
    TextAlign,
    TextRun,
    Path,
    FillRule,
    Matrix2D,
    LinearGradient,
    LineCap,
    LineJoin,
    SvgCanvas,
    PdfCanvas,
)
from canvas.geometry import FPoint
from canvas.display_list import DisplayList
from canvas.path import PathCommand, PathOp

comptime PAPER = Color(250, 250, 250)
comptime INK = Color(25, 80, 140, 180)


def _scene[
    T: DrawTarget
](
    mut t: T, mut cache: FontCache, baseline: Matrix2D = Matrix2D.identity()
) raises:
    var path = Path()
    path.move_to(8.0, 8.0)
    path.line_to(100.0, 8.0)
    path.quad_curve_to(130.0, 50.0, 100.0, 100.0)
    path.line_to(8.0, 100.0)
    path.close()
    t.save()
    t.translate(5.0, 7.0)
    t.push_clip(0, 0, 125, 110)
    t.push_clip_path(path, FillRule.NONZERO)
    t.begin_annotated_group("retained chart")
    var gradient = LinearGradient(10.0, 10.0, 90.0, 20.0)
    gradient.add_stop(0.0, Color(240, 80, 20))
    gradient.add_stop(1.0, Color(20, 80, 240))
    t.fill_rect_gradient(10, 10, 70, 10, gradient)
    t.fill_rect_gradient(10.25, 22.5, 70.5, 8.0, gradient)
    var pts: List[FPoint] = [
        FPoint(18.0, 40.0),
        FPoint(38.0, 40.0),
        FPoint(28.0, 60.0),
    ]
    var colors: List[Color] = [
        Color(240, 80, 20),
        Color(20, 160, 80),
        Color(20, 80, 240),
    ]
    var faces: List[Int] = [0, 1, 2]
    var face_colors: List[Color] = [INK]
    t.fill_mesh(pts, faces, face_colors)
    t.fill_mesh_shaded(pts, faces, colors)
    t.begin_batch()
    t.begin_batch()
    t.fill_rect(10, 34, 12, 6, INK)
    t.fill_rect(24.25, 34.25, 12.5, 6.5, INK)
    var dashes: List[Float64] = [3.0, 2.0]
    t.draw_line_aa(
        10, 65, 45, 65, INK, 2.0, dashes, 0.5, LineCap.SQUARE, LineJoin.MITER
    )
    t.draw_line_aa(
        10.25,
        70.25,
        45.75,
        70.25,
        INK,
        1.5,
        dashes,
        0.5,
        LineCap.BUTT,
        LineJoin.BEVEL,
    )
    t.fill_circle_aa(55, 40, 4, INK)
    t.fill_circle_aa(65.25, 40.5, 3.5, INK)
    t.draw_circle_aa(75.5, 40.5, 4.5, INK, 1.5)
    t.fill_ellipse_aa(55, 55, 5, 3, INK)
    t.fill_ellipse_aa(70.25, 55.5, 5.5, 2.5, INK)
    t.draw_ellipse_aa(85, 55, 6, 4, INK, 2)
    t.draw_ellipse_aa(100.5, 55.5, 6.5, 4.5, INK, 1.5)
    t.fill_arc_aa(60.0, 75.0, 5.0, 0.0, 2.0, INK)
    t.fill_ring_sector_aa(80.0, 75.0, 3.0, 6.0, 0.0, 2.0, INK)
    var small = Path()
    small.move_to(45.0, 80.0)
    small.line_to(35.0, 95.0)
    small.line_to(55.0, 95.0)
    small.close()
    t.fill_path_aa(small, INK, FillRule.NONZERO)
    t.stroke_path_aa(
        small, INK, 1.5, dashes, 0.5, LineCap.SQUARE, LineJoin.MITER, 2.0
    )
    t.end_batch()
    t.end_batch()
    t.fill_circles_aa(pts, 2.0, INK)
    t.fill_circles_aa(pts, 1.5, colors)
    t.fill_ellipses_aa(pts, 3.0, 1.5, INK)
    t.fill_ellipses_aa(pts, 2.5, 1.0, colors)
    t.fill_arcs_aa(pts, 4.0, 0.5, 1.5, INK)
    t.fill_arcs_aa(pts, 3.5, 0.5, 1.5, colors)
    var image = Canvas(3, 2, Color(160, 20, 80, 128))
    t.draw_image(image, 90.0, 15.0, 12.0, 8.0)
    t.end_annotated_group()
    t.pop_clip_path()
    t.pop_clip()
    t.set_blend_mode(BlendMode.MULTIPLY)
    t.set_color_space(ColorSpace.LINEAR)
    t.fill_rect(20, 20, 5, 5, INK)
    t.set_blend_mode(BlendMode.SOURCE_OVER)
    t.set_color_space(ColorSpace.SRGB)
    t.rotate(0.05)
    t.scale(1.05, 0.95)
    t.transform(Matrix2D.translation(1.0, 2.0))
    t.draw_text(
        15.0,
        118.0,
        "Chart",
        INK,
        12.0,
        "Sans",
        FontSlant.ITALIC,
        FontWeight.BOLD,
        0.03,
        TextAlign.CENTER,
        cache=cache,
    )
    var runs: List[TextRun] = [
        TextRun("x", 12.0, FontSlant.ITALIC),
        TextRun("2", 8.0, dy=-5.0),
    ]
    t.draw_text_runs(
        65.0,
        118.0,
        runs,
        INK,
        "Sans",
        FontWeight.NORMAL,
        -0.03,
        TextAlign.RIGHT,
        cache=cache,
    )
    # The ordinary geometry used for a math fraction/radical rule.
    t.draw_line_aa(60.0, 112.0, 80.0, 112.0, INK, width=1.0)
    t.set_transform(Matrix2D.translation(2.0, 3.0).then(baseline))
    t.fill_rect(120, 15, 3, 3, INK)
    t.set_transform(baseline)
    t.fill_rect(120, 25, 3, 3, INK)
    t.restore()


def test_scene_matches_all_four_direct_targets() raises:
    var cache = FontCache()
    var scene = DisplayList()
    _scene(scene, cache)
    scene.validate()
    var direct = Canvas(150, 150, PAPER)
    var replayed = Canvas(150, 150, PAPER)
    _scene(direct, cache)
    scene.replay(replayed, cache=cache)
    assert_equal(replayed.pixels, direct.pixels, "same full raster buffer")
    var svg_direct = SvgCanvas(150, 150)
    var svg_replay = SvgCanvas(150, 150)
    _scene(svg_direct, cache)
    scene.replay(svg_replay, cache=cache)
    assert_equal(
        svg_replay.to_string(),
        svg_direct.to_string(),
        "native SVG text and image",
    )
    var pdf_direct = PdfCanvas(150, 150)
    var pdf_replay = PdfCanvas(150, 150)
    _scene(pdf_direct, cache)
    scene.replay(pdf_replay, cache=cache)
    assert_equal(
        pdf_replay.to_bytes(compress=False),
        pdf_direct.to_bytes(compress=False),
        "PDF font subsets and resources",
    )
    var bounds_direct = BoundsTarget(150, 150)
    var bounds_replay = BoundsTarget(150, 150)
    _scene(bounds_direct, cache)
    scene.replay(bounds_replay, cache=cache)
    assert_equal(bounds_replay.ink_pixels(), bounds_direct.ink_pixels())


def test_set_and_reset_are_relative_to_each_replay_baseline() raises:
    var cache = FontCache()
    var scene = DisplayList()
    scene.set_transform(Matrix2D.translation(2.0, 3.0))
    scene.fill_rect(0, 0, 1, 1, INK)
    scene.reset_transform()
    scene.fill_rect(0, 0, 1, 1, Color(255, 0, 0))
    var count = scene.command_count()
    var bytes = scene.storage_bytes()
    for x in range(2):
        var target = Canvas(60, 60, PAPER)
        target.translate(10.0 + Float64(x) * 20.0, 10.0)
        target.scale(2.0, 2.0)
        var incoming = target.current_transform()
        target.push_clip(0, 0, 10, 10)
        target.set_blend_mode(BlendMode.MULTIPLY)
        target.set_color_space(ColorSpace.LINEAR)
        scene.replay(target, cache=cache)
        assert_equal(target.current_transform().e, incoming.e)
        assert_equal(target.current_transform().a, incoming.a)
        assert_equal(target.blend_mode(), BlendMode.MULTIPLY)
        assert_equal(target.color_space(), ColorSpace.LINEAR)
        assert_equal(len(target._clip_stack), 1, "incoming clip remains")
        assert_equal(len(target._saved), 0, "replay save removed")
        var x0 = 10 + x * 20
        assert_true(
            target.get_pixel(x0, 10).r > target.get_pixel(x0, 10).g,
            "reset stayed at widget origin",
        )
        assert_equal(
            target.get_pixel(0, 0), PAPER, "reset did not escape baseline"
        )
        assert_true(
            target.get_pixel(x0 + 4, 16) != PAPER,
            "set_transform composed with widget",
        )
    assert_equal(scene.command_count(), count)
    assert_equal(scene.storage_bytes(), bytes)
    assert_true(
        scene.current_transform().is_identity(), "recording was not mutated"
    )


def _owned_scene(mut cache: FontCache) raises -> DisplayList:
    var scene = DisplayList()
    var path = Path()
    path.rect(2.0, 2.0, 10.0, 10.0)
    var pixels = Canvas(2, 2, Color(255, 0, 0))
    var text = String("owned")
    var runs: List[TextRun] = [TextRun("x", 12.0), TextRun("2", 8.0, dy=-4.0)]
    var points: List[FPoint] = [FPoint(30.0, 8.0)]
    scene.fill_path_aa(path, INK)
    scene.draw_image(pixels, 15.0, 3.0)
    scene.draw_text(2.0, 28.0, text, INK, 10.0, cache=cache)
    scene.draw_text_runs(35.0, 28.0, runs, INK, cache=cache)
    scene.fill_circles_aa(points, 3.0, INK)
    path.commands.clear()
    pixels.fill(Color(0, 255, 0))
    text = "changed"
    assert_equal(text, "changed")
    runs[0].text = "changed"
    points[0] = FPoint(100.0, 100.0)
    return scene^


def test_sources_can_mutate_and_die_before_replay() raises:
    var cache = FontCache()
    var first = _owned_scene(cache)
    var scene = first^
    var target = Canvas(80, 40, PAPER)
    scene.replay(target, cache=cache)
    assert_true(target.get_pixel(5, 5) != PAPER, "path owned")
    assert_equal(
        target.get_pixel(16, 4), Color(255, 0, 0), "image snapshot owned"
    )
    assert_true(target.get_pixel(30, 8) != PAPER, "bulk centers owned")
    var svg = SvgCanvas(80, 40)
    scene.replay(svg, cache=cache)
    assert_true("owned" in svg.to_string())
    assert_false("changed" in svg.to_string(), "strings and runs owned")


def test_resources_are_shared_and_commands_are_inline() raises:
    var scene = DisplayList()
    scene.reserve_commands(100)
    var reserved = scene.storage_bytes()
    for i in range(100):
        scene.fill_rect(i, i, 1, 1, INK)
    assert_equal(
        scene.storage_bytes(),
        reserved,
        "no resource or command-buffer growth within reserve",
    )
    assert_equal(
        scene.list_buffer_count(),
        1,
        "all scalar commands share one List buffer",
    )
    assert_equal(
        scene.resource_count(),
        0,
        "scalar-only commands have no heap-owning operands",
    )
    var cache = FontCache()
    var pixels = Canvas(4, 4, INK)
    var runs: List[TextRun] = [TextRun("a shared run", 12.0)]
    scene.draw_image(pixels, 0.0, 0.0)
    scene.draw_text_runs(0.0, 0.0, runs, INK, cache=cache)
    var resources = scene.resource_count()
    for i in range(20):
        scene.draw_image(pixels, Float64(i), 0.0)
        scene.draw_text_runs(Float64(i), 0.0, runs, INK, cache=cache)
    assert_equal(
        scene.resource_count(),
        resources,
        "repeated images and text share snapshots",
    )
    assert_equal(len(scene._images), 1)
    assert_equal(len(scene._runs), 1)
    assert_equal(scene._images[0].pixels, pixels.pixels)


def test_errors_restore_nested_saves_clips_batches_and_groups() raises:
    var scene = DisplayList()
    scene.save()
    scene.translate(4.0, 5.0)
    scene.push_clip(0, 0, 20, 20)
    scene.begin_annotated_group("before error")
    scene.begin_batch()
    scene.fill_rect(2, 2, 2, 2, INK)
    var points: List[FPoint] = [FPoint(0.0, 0.0)]
    var faces: List[Int] = [0]  # not a whole triangle; destination raises
    var colors: List[Color] = [INK]
    scene.fill_mesh(points, faces, colors)
    scene.end_batch()
    scene.end_annotated_group()
    scene.pop_clip()
    scene.restore()
    var cache = FontCache()
    var target = Canvas(50, 50, PAPER)
    target.translate(10.0, 10.0)
    target.set_blend_mode(BlendMode.MULTIPLY)
    target.set_color_space(ColorSpace.LINEAR)
    target.push_clip(0, 0, 30, 30)
    target.begin_batch()
    var failed = False
    try:
        scene.replay(target, cache=cache)
    except:
        failed = True
    assert_true(failed, "mid-replay primitive error")
    assert_equal(target.current_transform().e, 10.0)
    assert_equal(target.current_transform().f, 10.0)
    assert_equal(target.blend_mode(), BlendMode.MULTIPLY)
    assert_equal(target.color_space(), ColorSpace.LINEAR)
    assert_equal(len(target._saved), 0)
    assert_equal(len(target._clip_stack), 1)
    assert_equal(target._batch_depth, 1, "incoming batch preserved")
    target.end_batch()
    assert_true(
        target.get_pixel(16, 17) != PAPER,
        "preceding drawing is not rolled back",
    )
    var svg = SvgCanvas(50, 50)
    failed = False
    try:
        scene.replay(svg, cache=cache)
    except:
        failed = True
    assert_true(failed)
    assert_false(svg._open_group)
    assert_equal(svg._clip_depth, 0)
    assert_equal(len(svg._saved), 0)
    var pdf = PdfCanvas(50, 50)
    pdf.translate(10.0, 10.0)
    failed = False
    try:
        scene.replay(pdf, cache=cache)
    except:
        failed = True
    assert_true(failed)
    assert_false(pdf._open_group)
    assert_equal(pdf._clip_depth, 0)
    assert_equal(len(pdf._saved), 0)
    assert_equal(pdf.current_transform().e, 10.0)
    pdf.fill_rect(0, 0, 2, 2, INK)
    assert_equal(
        pdf.content().count("q "),
        pdf.content().count("Q\n"),
        "PDF graphics scopes closed on error",
    )


def test_invalid_scopes_raise_before_destination_changes() raises:
    var cache = FontCache()
    for variant in range(5):
        var scene = DisplayList()
        scene.fill_rect(1, 1, 2, 2, INK)
        if variant == 0:
            scene.restore()
        elif variant == 1:
            scene.begin_batch()
        elif variant == 2:
            scene.push_clip(0, 0, 10, 10)
            scene.pop_clip_path()
        elif variant == 3:
            scene.push_clip(0, 0, 10, 10)
            scene.save()
            scene.pop_clip()
            scene.restore()
        else:
            scene.begin_annotated_group("unclosed")
        var target = Canvas(20, 20, PAPER)
        var before = target.pixels.copy()
        var failed = False
        try:
            scene.replay(target, cache=cache)
        except:
            failed = True
        assert_true(failed)
        assert_equal(target.pixels, before, "validation precedes first draw")


def test_bounds_include_negative_strokes_and_text_and_unknown_geometry() raises:
    var cache = FontCache()
    var scene = DisplayList()
    scene.draw_line_aa(
        -20.0, -10.0, -5.0, -10.0, INK, width=4.0, cap=LineCap.SQUARE
    )
    var box = scene.bounds(cache=cache)
    assert_true(box.known and box.has_ink)
    assert_true(
        box.min_x <= -22.0 and box.max_x >= -3.0, "square caps included"
    )
    assert_true(
        box.min_y <= -12.0 and box.max_y >= -8.0, "stroke width included"
    )
    scene.draw_text(
        -10.0, 20.0, "italic", INK, 16.0, slant=FontSlant.ITALIC, cache=cache
    )
    var with_text = scene.bounds(cache=cache)
    assert_true(with_text.known and with_text.max_y > box.max_y)
    var empty = DisplayList()
    var empty_box = empty.bounds(cache=cache)
    assert_true(empty_box.known)
    assert_false(empty_box.has_ink)
    var unknown = DisplayList()
    unknown.fill_circle_aa(Float64(1.0) / Float64(0.0), 0.0, 2.0, INK)
    assert_false(unknown.bounds(cache=cache).known)


def test_gradient_and_list_resources_are_deep_snapshots() raises:
    var cache = FontCache()
    var scene = DisplayList()
    var gradient = LinearGradient(0.0, 0.0, 20.0, 0.0)
    gradient.add_stop(0.0, Color(255, 0, 0))
    gradient.add_stop(1.0, Color(0, 0, 255))
    scene.fill_rect_gradient(0, 0, 20, 10, gradient)
    scene.fill_rect_gradient(0, 10, 20, 10, gradient)
    assert_equal(len(scene._gradients), 1, "equal gradient shares a snapshot")
    var expected = Canvas(20, 20, PAPER)
    expected.fill_rect_gradient(0, 0, 20, 20, gradient)
    gradient.add_stop(0.5, Color(0, 255, 0))
    var target = Canvas(20, 20, PAPER)
    scene.replay(target, cache=cache)
    assert_equal(target.pixels, expected.pixels, "gradient stops owned")
    var points: List[FPoint] = [
        FPoint(2.0, 2.0),
        FPoint(8.0, 2.0),
        FPoint(2.0, 8.0),
    ]
    var faces: List[Int] = [0, 1, 2]
    var colors: List[Color] = [INK]
    var mesh = DisplayList()
    mesh.fill_mesh(points, faces, colors)
    faces[0] = 999
    colors[0] = Color(0, 255, 0)
    var mesh_target = Canvas(12, 12, PAPER)
    mesh.replay(mesh_target, cache=cache)
    assert_true(mesh_target.get_pixel(3, 3).b > mesh_target.get_pixel(3, 3).g)


def test_replay_rejects_open_destination_groups_without_closing_them() raises:
    var cache = FontCache()
    var scene = DisplayList()
    scene.fill_rect(0, 0, 2, 2, INK)
    var svg = SvgCanvas(20, 20)
    svg.begin_annotated_group("caller")
    var before = svg.to_string()
    var failed = False
    try:
        scene.replay(svg, cache=cache)
    except:
        failed = True
    assert_true(failed)
    assert_true(svg._open_group)
    assert_equal(svg.to_string(), before)
    var pdf = PdfCanvas(20, 20)
    pdf.begin_annotated_group("caller")
    before = pdf.content()
    failed = False
    try:
        scene.replay(pdf, cache=cache)
    except:
        failed = True
    assert_true(failed)
    assert_true(pdf._open_group)
    assert_equal(pdf.content(), before)


def test_source_image_batch_must_finish_before_capture() raises:
    var source = Canvas(12, 12, PAPER)
    source.begin_batch()
    source.fill_circle_aa(6, 6, 3, INK)
    var scene = DisplayList()
    var failed = False
    try:
        scene.draw_image(source, 0.0, 0.0)
    except:
        failed = True
    assert_true(failed)
    assert_equal(scene.command_count(), 0)
    assert_equal(scene.resource_count(), 0)
    source.end_batch()
    scene.draw_image(source, 0.0, 0.0)
    assert_equal(scene.command_count(), 1)


def test_bounds_stay_conservative_under_rotation_and_clip() raises:
    var cache = FontCache()
    var scene = DisplayList()
    scene.save()
    scene.translate(50.0, 40.0)
    scene.rotate(0.4)
    var clip = Path()
    clip.rect(-30.0, -20.0, 60.0, 40.0)
    scene.push_clip_path(clip)
    var path = Path()
    path.move_to(-20.0, 0.0)
    path.line_to(0.0, -10.0)
    path.line_to(20.0, 0.0)
    var dashes: List[Float64] = [5.0, 2.0]
    scene.stroke_path_aa(
        path, INK, 5.0, dashes, 1.0, LineCap.SQUARE, LineJoin.MITER, 4.0
    )
    scene.draw_text(
        -20.0, 15.0, "ink", INK, 12.0, slant=FontSlant.ITALIC, cache=cache
    )
    scene.pop_clip_path()
    scene.restore()
    var raster = Canvas(100, 80, PAPER)
    scene.replay(raster, cache=cache)
    var box = scene.bounds(cache=cache)
    assert_true(box.known and box.has_ink)
    var inked = 0
    for y in range(raster.height):
        for x in range(raster.width):
            if raster.get_pixel(x, y) != PAPER:
                inked += 1
                assert_true(Float64(x) >= box.min_x and Float64(x) <= box.max_x)
                assert_true(Float64(y) >= box.min_y and Float64(y) <= box.max_y)
    assert_true(inked > 100, "the bounded scene actually painted")


def test_malformed_path_cannot_leave_a_partial_pdf_clip_scope() raises:
    var scene = DisplayList()
    var malformed = Path()
    malformed.commands.append(
        PathCommand(
            PathOp.LINE_TO, FPoint(1.0, 1.0), FPoint(0.0, 0.0), FPoint(0.0, 0.0)
        )
    )
    scene.push_clip_path(malformed)
    scene.pop_clip_path()
    var pdf = PdfCanvas(20, 20)
    pdf.translate(3.0, 4.0)
    var before = pdf.content()
    var cache = FontCache()
    var failed = False
    try:
        scene.replay(pdf, cache=cache)
    except:
        failed = True
    assert_true(failed)
    assert_equal(pdf.content(), before, "validation precedes PDF q")
    assert_equal(len(pdf._saved), 0)
    assert_equal(pdf._clip_depth, 0)
    assert_equal(pdf.current_transform().e, 3.0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
