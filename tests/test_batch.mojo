"""`Canvas.begin_batch` / `end_batch`: everything drawn inside a batch
comes out byte for byte as drawing it at once would, at any worker
count, and everything a batch cannot record lands in order.

The scenes below mix every recorded primitive, translucent colors that
overlap (so order shows), the sampled sweep (a self-overlapping
even-odd path), a clip rectangle, a clip path, a transform and a
blend mode; each is drawn twice, immediately and batched, and the two
buffers are compared whole.
"""

from std.math import cos, pi, sin
from std.testing import assert_equal, assert_true, TestSuite

from canvas.buffer import Canvas
from canvas.color import Color
from canvas.blend import BlendMode
from canvas.fill_rule import FillRule
from canvas.geometry import FPoint, Point
from canvas.path import Path, fill_path_aa, stroke_path_aa
from canvas.shapes.arcs import fill_arc_aa, fill_ring_sector_aa, draw_arc_aa
from canvas.shapes.circles import (
    draw_circle_aa,
    fill_circle,
    fill_circle_aa,
    fill_circles_aa,
)
from canvas.shapes.ellipses import fill_ellipse_aa
from canvas.shapes.lines import (
    draw_line,
    draw_line_aa,
    draw_polygon_aa,
    draw_polyline_aa,
)
from canvas.shapes.polygon_fill import fill_polygon_aa
from canvas.shapes.rects import fill_rect, fill_rect_gradient
from canvas.gradient import LinearGradient
from canvas.vector.draw_target import DrawTarget
from canvas.vector.svg import SvgCanvas

comptime BG = Color(255, 255, 255, 255)
comptime W = 400
comptime H = 300


def _assert_same(a: Canvas, b: Canvas, what: String) raises:
    assert_equal(len(a.pixels), len(b.pixels), what + ": sizes")
    var ap = a.pixels.unsafe_ptr()
    var bp = b.pixels.unsafe_ptr()
    for i in range(len(a.pixels)):  # i < len
        if ap[unsafe_offset=i] != bp[unsafe_offset=i]:
            var px = (i // 4) % a.width
            var py = (i // 4) // a.width
            assert_true(
                False,
                what
                + ": pixel ("
                + String(px)
                + ", "
                + String(py)
                + ") channel "
                + String(i % 4)
                + " differs: "
                + String(ap[unsafe_offset=i])
                + " vs "
                + String(bp[unsafe_offset=i]),
            )


def _ink_count(c: Canvas) -> Int:
    var n = 0
    for y in range(c.height):
        for x in range(c.width):
            if c.get_pixel(x, y).r != BG.r:
                n += 1
    return n


def _wiggle() raises -> Path:
    """A closed path of cubics that overlaps itself, so even-odd and
    nonzero disagree and the even-odd fill takes the sampled sweep."""
    var p = Path()
    p.move_to(30.0, 150.0)
    for i in range(10):
        var a = Float64(i) * 0.9
        p.cubic_curve_to(
            40.0 + 30.0 * Float64(i),
            150.0 + 110.0 * sin(a),
            55.0 + 30.0 * Float64(i),
            150.0 - 110.0 * cos(a * 1.3),
            70.0 + 28.0 * Float64(i),
            150.0 + 70.0 * sin(a * 1.9),
        )
    p.close()
    return p^


def _scene(mut c: Canvas) raises:
    """Every recorded primitive, overlapping, opaque and translucent."""
    var ink = Color(20, 40, 120, 255)
    var tint = Color(220, 60, 40, 120)
    var wash = Color(40, 180, 90, 90)
    # Solid rects first, some translucent, overlapping.
    for i in range(12):
        fill_rect(c, 10 + i * 30, 20, 40, 220, tint if i % 2 == 0 else wash)
    # Small closed-form disks, a scatter with overlaps.
    for i in range(300):
        var fx = 8.0 + Float64((i * 37) % 3800) * 0.1
        var fy = 8.0 + Float64((i * 53) % 2800) * 0.1
        fill_circle_aa(
            c, fx, fy, 1.5 + Float64(i % 5), tint if i % 3 == 0 else ink
        )
    # Larger disks, past the closed form, through the area path.
    for i in range(30):
        var fx = 20.0 + Float64((i * 131) % 360)
        var fy = 20.0 + Float64((i * 71) % 260)
        fill_circle_aa(c, fx, fy, 8.5 + Float64(i % 7), wash)
    # Ellipses, both routes.
    for i in range(40):
        var fx = 15.0 + Float64((i * 97) % 370)
        var fy = 15.0 + Float64((i * 59) % 270)
        fill_ellipse_aa(
            c, fx, fy, 2.0 + Float64(i % 4), 5.0 + Float64(i % 6), tint
        )
    fill_ellipse_aa(c, 200.0, 150.0, 60.0, 25.0, wash)
    # Paths: nonzero, and even-odd on a self-overlapping outline.
    var wig = _wiggle()
    fill_path_aa(c, wig, wash, FillRule.NONZERO)
    fill_path_aa(c, wig, tint, FillRule.EVEN_ODD)
    stroke_path_aa(c, wig, ink, width=2.5)
    # Strokes: a noisy polyline, dashed, a polygon outline, lines.
    var series = List[FPoint]()
    for i in range(400):
        series.append(
            FPoint(
                10.0 + Float64(i) * 0.95, 150.0 + 100.0 * sin(Float64(i) * 0.31)
            )
        )
    draw_polyline_aa(c, series, ink, width=1.5)
    var dashes: List[Float64] = [5.0, 3.0]
    draw_polyline_aa(c, series, tint, width=3.0, dashes=dashes)
    var tri: List[FPoint] = [
        FPoint(50.0, 50.0),
        FPoint(350.0, 80.0),
        FPoint(200.0, 260.0),
    ]
    draw_polygon_aa(c, tri, wash, width=4.0)
    fill_polygon_aa(c, tri, tint, FillRule.NONZERO)
    for i in range(20):
        draw_line_aa(
            c,
            0.0,
            Float64(i) * 15.0,
            400.0,
            Float64(i) * 15.0 + 7.0,
            wash,
            width=1.0,
        )
    # Arcs, ring sectors, stroked circles and ellipses.
    fill_arc_aa(c, 300.0, 200.0, 50.0, -1.2, 1.4, tint)
    fill_ring_sector_aa(c, 100.0, 200.0, 20.0, 45.0, 0.3, 2.9, ink)
    draw_circle_aa(c, 320.0, 80.0, 40.0, ink, width=3.0)
    draw_arc_aa(c, 80.0, 80.0, 35.0, 0.5, 2.5, tint, width=5.0)


def _draw_both(scene_id: Int, workers: Int) raises -> Tuple[Canvas, Canvas]:
    var direct = Canvas(W, H, BG)
    var batched = Canvas(W, H, BG)
    direct.set_max_workers(workers)
    batched.set_max_workers(workers)
    _apply_scene(direct, scene_id, False)
    _apply_scene(batched, scene_id, True)
    return (direct^, batched^)


def _apply_scene(mut c: Canvas, scene_id: Int, batch: Bool) raises:
    if scene_id == 1:
        c.push_clip(40, 30, 300, 220)
    elif scene_id == 2:
        var clip = Path()
        clip.ellipse(200.0, 150.0, 170.0, 120.0)
        c.push_clip_path(clip)
    elif scene_id == 3:
        c.translate(200.0, 150.0)
        c.rotate(0.35)
        c.scale(0.8, 0.8)
        c.translate(-200.0, -150.0)
    elif scene_id == 4:
        c.set_blend_mode(BlendMode.MULTIPLY)
    if batch:
        c.begin_batch()
    _scene(c)
    if batch:
        c.end_batch()


def test_batch_draws_the_same_pixels_as_drawing_at_once() raises:
    var both = _draw_both(0, 0)
    assert_true(_ink_count(both[0]) > 10000, "the scene drew")
    _assert_same(both[0], both[1], "plain scene")


def test_batch_under_a_clip_rect() raises:
    var both = _draw_both(1, 0)
    _assert_same(both[0], both[1], "clip rect")


def test_batch_under_a_clip_path() raises:
    var both = _draw_both(2, 0)
    _assert_same(both[0], both[1], "clip path")


def test_batch_under_a_transform() raises:
    var both = _draw_both(3, 0)
    _assert_same(both[0], both[1], "transform")


def test_batch_under_a_blend_mode() raises:
    var both = _draw_both(4, 0)
    _assert_same(both[0], both[1], "multiply")


def test_batch_is_the_same_at_every_worker_count() raises:
    var one = _draw_both(0, 1)
    var many = _draw_both(0, 0)
    var few = _draw_both(0, 3)
    _assert_same(one[1], many[1], "1 vs all workers")
    _assert_same(few[1], many[1], "3 vs all workers")


def test_immediate_primitives_inside_a_batch_stay_in_order() raises:
    # A gradient rect, a hard-edged disk, a Bresenham line and a
    # whole-canvas fill are not recorded; each draws what is pending
    # first, so the result is the same as with no batch at all.
    var direct = Canvas(W, H, BG)
    var batched = Canvas(W, H, BG)
    for pass_id in range(2):
        var tint = Color(220, 60, 40, 120)
        if pass_id == 1:
            batched.begin_batch()
        for i in range(60):
            var fx = 10.0 + Float64((i * 37) % 380)
            var fy = 10.0 + Float64((i * 53) % 280)
            if pass_id == 0:
                fill_circle_aa(direct, fx, fy, 6.0, tint)
            else:
                fill_circle_aa(batched, fx, fy, 6.0, tint)
        var g = LinearGradient(0.0, 0.0, 400.0, 0.0)
        g.add_stop(0.0, Color(0, 0, 0, 200))
        g.add_stop(1.0, Color(0, 120, 255, 60))
        if pass_id == 0:
            fill_rect_gradient(direct, 50, 100, 300, 60, g)
            fill_circle(direct, 200, 150, 40, Color(0, 0, 0, 255))
            draw_line(direct, 0, 0, 399, 299, Color(255, 0, 0, 255))
            direct.fill(Color(0, 255, 0, 60))
            fill_circle_aa(direct, 200.0, 150.0, 30.0, tint)
        else:
            fill_rect_gradient(batched, 50, 100, 300, 60, g)
            fill_circle(batched, 200, 150, 40, Color(0, 0, 0, 255))
            draw_line(batched, 0, 0, 399, 299, Color(255, 0, 0, 255))
            batched.fill(Color(0, 255, 0, 60))
            fill_circle_aa(batched, 200.0, 150.0, 30.0, tint)
            batched.end_batch()
    _assert_same(direct, batched, "immediates inside a batch")


def test_a_state_change_inside_a_batch_draws_what_is_pending_first() raises:
    var direct = Canvas(W, H, BG)
    var batched = Canvas(W, H, BG)
    var tint = Color(220, 60, 40, 120)
    for pass_id in range(2):
        if pass_id == 1:
            batched.begin_batch()
        for i in range(50):
            var fx = 10.0 + Float64((i * 37) % 380)
            var fy = 10.0 + Float64((i * 53) % 280)
            if pass_id == 0:
                fill_circle_aa(direct, fx, fy, 5.0, tint)
            else:
                fill_circle_aa(batched, fx, fy, 5.0, tint)
        if pass_id == 0:
            direct.push_clip(100, 80, 200, 140)
            direct.set_blend_mode(BlendMode.MULTIPLY)
        else:
            batched.push_clip(100, 80, 200, 140)
            batched.set_blend_mode(BlendMode.MULTIPLY)
        for i in range(50):
            var fx = 10.0 + Float64((i * 41) % 380)
            var fy = 10.0 + Float64((i * 43) % 280)
            if pass_id == 0:
                fill_circle_aa(direct, fx, fy, 5.0, tint)
            else:
                fill_circle_aa(batched, fx, fy, 5.0, tint)
        if pass_id == 0:
            direct.pop_clip()
            direct.set_blend_mode(BlendMode.SOURCE_OVER)
            fill_rect(direct, 0, 0, 400, 40, tint)
        else:
            batched.pop_clip()
            batched.set_blend_mode(BlendMode.SOURCE_OVER)
            fill_rect(batched, 0, 0, 400, 40, tint)
            batched.end_batch()
    _assert_same(direct, batched, "state change inside a batch")


def test_only_the_outermost_end_batch_draws() raises:
    var c = Canvas(120, 90, BG)
    c.begin_batch()
    c.begin_batch()
    fill_circle_aa(c, 60.0, 45.0, 20.0, Color(0, 0, 0, 255))
    c.end_batch()
    assert_equal(_ink_count(c), 0, "the inner end_batch drew nothing")
    c.end_batch()
    assert_true(_ink_count(c) > 1000, "the outer end_batch drew the disk")
    c.end_batch()  # unbalanced: a no-op
    var direct = Canvas(120, 90, BG)
    fill_circle_aa(direct, 60.0, 45.0, 20.0, Color(0, 0, 0, 255))
    _assert_same(direct, c, "nested batch")


def test_batch_of_disks_matches_the_batched_marker_entry_point() raises:
    # `fill_circles_aa` is what the batch generalizes: a batch of
    # single `fill_circle_aa` calls draws its pixels.
    var centers = List[FPoint]()
    for i in range(500):
        centers.append(
            FPoint(
                8.0 + Float64((i * 37) % 3800) * 0.1,
                8.0 + Float64((i * 53) % 2800) * 0.1,
            )
        )
    var tint = Color(220, 60, 40, 120)
    for radius in [3.5, 10.5]:
        var by_entry = Canvas(W, H, BG)
        fill_circles_aa(by_entry, centers, radius, tint)
        var by_batch = Canvas(W, H, BG)
        by_batch.begin_batch()
        for i in range(len(centers)):
            fill_circle_aa(by_batch, centers[i].x, centers[i].y, radius, tint)
        by_batch.end_batch()
        _assert_same(by_entry, by_batch, "markers r=" + String(radius))


def _generic_scene[T: DrawTarget](mut target: T) raises:
    target.begin_batch()
    target.fill_circle_aa(30, 30, 10, Color(0, 0, 0, 255))
    target.fill_rect(5, 5, 20, 20, Color(200, 0, 0, 255))
    target.end_batch()


def test_batching_through_the_trait() raises:
    var svg_batched = SvgCanvas(100, 100)
    _generic_scene(svg_batched)
    var svg_plain = SvgCanvas(100, 100)
    svg_plain.fill_circle_aa(30, 30, 10, Color(0, 0, 0, 255))
    svg_plain.fill_rect(5, 5, 20, 20, Color(200, 0, 0, 255))
    assert_equal(
        svg_batched.to_string(), svg_plain.to_string(), "svg ignores batches"
    )
    var raster = Canvas(100, 100, BG)
    _generic_scene(raster)
    var direct = Canvas(100, 100, BG)
    direct.fill_circle_aa(30, 30, 10, Color(0, 0, 0, 255))
    direct.fill_rect(5, 5, 20, 20, Color(200, 0, 0, 255))
    _assert_same(direct, raster, "raster through the trait")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
