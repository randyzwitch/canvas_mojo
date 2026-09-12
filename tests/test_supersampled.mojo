"""Tests for Canvas.begin_supersampled / end_supersampled: a region
drawn at a multiple of the canvas's resolution without the enlarged
buffer ever existing whole.

The contract is byte-identity with the two-step recipe -- draw into a
`factor` times larger canvas under the shift and scale `downsample`
documents, then downsample -- so every test here renders both and
compares every channel of every pixel. A region that merely looked
right would be useless: a consumer adopting it re-records nothing.
"""

from std.testing import assert_equal, assert_raises, assert_true, TestSuite

from canvas.buffer import Canvas
from canvas.color import Color
from canvas.resize import downsample
from canvas.geometry import FPoint
from canvas.gradient import LinearGradient
from canvas.blur import blur
from canvas.shapes.circles import fill_circles_aa
from canvas.text.font_cache import FontCache
from canvas.text.render import draw_text

comptime BG = Color(255, 255, 255)
comptime INK = Color(30, 60, 120, 200)


def _scene(mut c: Canvas) raises:
    """Shapes at fractional positions, crossing band boundaries, in
    every kind the batch records: closed-form disks, a stroke through
    the area rasterizer, and a snapped rectangle."""
    for i in range(40):
        c.fill_circle_aa(
            7.3 + Float64(i) * 4.7, 5.9 + Float64((i * 13) % 47) * 2.3, 3.4, INK
        )
    for i in range(12):
        var y = 3.5 + Float64(i) * 9.1
        c.draw_line_aa(2.0, y, 118.0, y + 3.0, Color(200, 40, 40, 160), 1.7)
    c.fill_rect(11.25, 21.75, 30.5, 14.25, Color(0, 160, 90, 120))


def _recipe(width: Int, height: Int, factor: Int) raises -> Canvas:
    """The two-step: draw enlarged under the half-pixel shift, then
    downsample. What the region has to reproduce exactly."""
    var scratch = Canvas(width * factor, height * factor, BG)
    var shift = Float64(factor - 1) / 2.0
    scratch.translate(shift, shift)
    scratch.scale(Float64(factor), Float64(factor))
    _scene(scratch)
    return downsample(scratch, factor)


def _assert_same(a: Canvas, b: Canvas, label: String) raises:
    assert_equal(a.width, b.width, label + " (width)")
    assert_equal(a.height, b.height, label + " (height)")
    for y in range(a.height):
        for x in range(b.width):
            var p = a.get_pixel(x, y)
            var q = b.get_pixel(x, y)
            var at = label + " at (" + String(x) + ", " + String(y) + ")"
            assert_equal(p.r, q.r, at + " (r)")
            assert_equal(p.g, q.g, at + " (g)")
            assert_equal(p.b, q.b, at + " (b)")
            assert_equal(p.a, q.a, at + " (a)")


def test_matches_the_recipe_at_every_factor() raises:
    # 90 rows against a 20-row band is five bands, so shapes cross
    # boundaries in every direction.
    for factor in [2, 3, 4]:
        var want = _recipe(120, 90, factor)
        var got = Canvas(120, 90, BG)
        got.begin_supersampled(factor, BG)
        _scene(got)
        got.end_supersampled()
        _assert_same(want, got, "factor " + String(factor))


def test_matches_the_recipe_within_a_single_band() raises:
    # Fewer rows than one band, so the replay takes its inline path
    # rather than a task group.
    var want = _recipe(120, 12, 3)
    var got = Canvas(120, 12, BG)
    got.begin_supersampled(3, BG)
    _scene(got)
    got.end_supersampled()
    _assert_same(want, got, "one band")


def test_a_factor_of_one_or_less_draws_directly() raises:
    var plain = Canvas(60, 40, BG)
    _scene(plain)
    for factor in [1, 0, -2]:
        var got = Canvas(60, 40, BG)
        got.begin_supersampled(factor, BG)
        _scene(got)
        got.end_supersampled()
        _assert_same(plain, got, "factor " + String(factor))


def test_an_empty_region_leaves_the_canvas_alone() raises:
    var got = Canvas(40, 30, Color(10, 20, 30))
    got.begin_supersampled(3, BG)
    got.end_supersampled()
    for y in range(30):
        for x in range(40):
            assert_equal(got.get_pixel(x, y).r, 10, "untouched")


def test_a_second_region_raises() raises:
    var c = Canvas(40, 30, BG)
    c.begin_supersampled(2, BG)
    with assert_raises():
        c.begin_supersampled(2, BG)
    c.end_supersampled()


def test_end_without_begin_is_a_no_op() raises:
    var c = Canvas(20, 15, BG)
    c.end_supersampled()
    assert_equal(c.get_pixel(3, 3).r, 255, "nothing drawn")


def test_the_transform_is_restored_after_the_region() raises:
    var c = Canvas(40, 30, BG)
    c.translate(3.0, 4.0)
    var before = c.current_transform()
    c.begin_supersampled(3, BG)
    _scene(c)
    c.end_supersampled()
    var after = c.current_transform()
    assert_equal(after.a, before.a, "scale x restored")
    assert_equal(after.d, before.d, "scale y restored")
    assert_equal(after.e, before.e, "translation x restored")
    assert_equal(after.f, before.f, "translation y restored")


def test_text_in_a_region_matches_the_recipe() raises:
    """Text is what made this API worth having to a chart consumer:
    labels are drawn into the enlarged space and shrunk with
    everything else, so a region that could not hold them would be a
    no-op for charts. A glyph's cached coverage mask is recorded and
    composited per band, which is why this is exact rather than close:
    routing text through the outline instead differed by one level on
    227 pixels, because the mask cache quantizes sub-pixel placement.

    No golden: the glyphs come from whatever fonts this machine has,
    which is why both sides are rendered here and compared to each
    other.
    """
    var cache = FontCache()
    var factor = 3
    var scratch = Canvas(160 * factor, 90 * factor, BG)
    var shift = Float64(factor - 1) / 2.0
    scratch.translate(shift, shift)
    scratch.scale(Float64(factor), Float64(factor))
    _text_scene(scratch, cache)
    var want = downsample(scratch, factor)

    var got = Canvas(160, 90, BG)
    got.begin_supersampled(factor, BG)
    _text_scene(got, cache)
    got.end_supersampled()
    _assert_same(want, got, "text in a region")


def _text_scene(mut c: Canvas, mut cache: FontCache) raises:
    for i in range(6):
        c.fill_circle_aa(
            12.0 + Float64(i) * 18.0, 20.0, 5.5, Color(200, 60, 60, 180)
        )
    draw_text(c, 6.0, 40.0, "Axis label 123", INK, 11.0, cache=cache)
    draw_text(c, 6.0, 58.0, "Another line gjpq", INK, 9.0, cache=cache)
    draw_text(c, 6.0, 76.0, "Tick 0.75", Color(90, 90, 90), 8.0, cache=cache)


def _draw_case(mut c: Canvas, which: Int) raises:
    """The scenes below, by number, so both renders draw the same one
    without a function parameter."""
    if which == 0:
        # `fill_circles_aa` draws rather than records, so a region
        # containing it gives up its banded replay (#409). It is on
        # `DrawTarget`, so a generic caller reaches it.
        var centres: List[FPoint] = [
            FPoint(50.0, 40.0),
            FPoint(100.0, 60.0),
            FPoint(150.0, 80.0),
        ]
        fill_circles_aa(c, centres, 6.0, INK)
    elif which == 1:
        # A clip is a state change, which also draws what is pending
        # first; before #409 a region containing one came out blank.
        c.push_clip(20, 20, 160, 80)
        c.fill_circle_aa(100.0, 60.0, 20.0, INK)
        c.pop_clip()
    elif which == 2:
        var ramp = LinearGradient(10.0, 10.0, 110.0, 60.0)
        ramp.add_stop(0.0, Color(200, 30, 30))
        ramp.add_stop(1.0, Color(30, 30, 200))
        c.fill_rect_gradient(10, 10, 100, 50, ramp)
    elif which == 4:
        # A colour per marker, which travels in its own side list.
        var centres = List[FPoint]()
        var colours = List[Color]()
        for i in range(24):
            centres.append(
                FPoint(
                    20.0 + Float64((i * 31) % 160),
                    15.0 + Float64((i * 17) % 90),
                )
            )
            colours.append(
                Color(UInt8(20 + i * 9), UInt8(200 - i * 7), 120, 190)
            )
        fill_circles_aa(c, centres, 5.5, colours)
    elif which == 5:
        var centres: List[FPoint] = [
            FPoint(60.0, 50.0),
            FPoint(140.0, 80.0),
        ]
        fill_circles_aa(c, centres, 18.0, INK)
    elif which == 6 or which == 7:
        var pts = List[FPoint]()
        for i in range(120):
            pts.append(
                FPoint(
                    25.0 + Float64((i * 29) % 150),
                    20.0 + Float64((i * 41) % 100),
                )
            )
        var halo = Color(90, 140, 220, 90)
        var dot = Color(20, 50, 120, 230)
        c.push_clip(20, 15, 160, 110)
        if which == 6:
            fill_circles_aa(c, pts, 9.0, halo)
            fill_circles_aa(c, pts, 3.5, dot)
        else:
            for i in range(len(pts)):
                ref p = pts[i]
                c.fill_circle_aa(p.x, p.y, 9.0, halo)
            for i in range(len(pts)):
                ref p = pts[i]
                c.fill_circle_aa(p.x, p.y, 3.5, dot)
        c.pop_clip()
    else:
        # Recordable and unrecordable work interleaved, so the order
        # the region gives up in is what decides the pixels.
        c.fill_circle_aa(40.0, 30.0, 9.0, INK)
        var pair: List[FPoint] = [FPoint(90.0, 40.0), FPoint(130.0, 70.0)]
        fill_circles_aa(c, pair, 7.0, Color(200, 60, 60, 180))
        c.fill_circle_aa(60.0, 80.0, 11.0, Color(0, 140, 90, 150))
        c.push_clip(30, 30, 120, 60)
        c.fill_circle_aa(100.0, 60.0, 22.0, Color(90, 40, 160, 170))
        c.pop_clip()


def _assert_case_matches(which: Int, label: String) raises:
    comptime W = 200
    comptime H = 120
    var factor = 3
    var scratch = Canvas(W * factor, H * factor, BG)
    var shift = Float64(factor - 1) / 2.0
    scratch.translate(shift, shift)
    scratch.scale(Float64(factor), Float64(factor))
    _draw_case(scratch, which)
    var want = downsample(scratch, factor)
    var got = Canvas(W, H, BG)
    got.begin_supersampled(factor, BG)
    _draw_case(got, which)
    got.end_supersampled()
    _assert_same(want, got, label)


def test_a_bulk_marker_call_in_a_region_matches() raises:
    _assert_case_matches(0, "fill_circles_aa")


def test_a_bulk_marker_call_with_a_colour_each_matches() raises:
    _assert_case_matches(4, "fill_circles_aa with colours")


def test_bulk_markers_past_the_closed_form_radius_match() raises:
    # Above the closed-form limit the band body takes the polygon
    # route, which the recorded op has to reach as well.
    _assert_case_matches(5, "fill_circles_aa large radius")


def test_a_clip_in_a_region_matches() raises:
    _assert_case_matches(1, "push_clip")


def test_a_gradient_in_a_region_matches() raises:
    _assert_case_matches(2, "fill_rect_gradient")


def test_two_bulk_marker_calls_layer_in_order() raises:
    """An effect scatter: a translucent halo under every point, which
    a chart draws as two bulk calls over the same centres.

    Two recorded marker ops covering the same pixels is what pins the
    order, since the halo's alpha makes the result depend on which was
    drawn first. Nothing that paints disjoint areas would catch a
    replay that reordered them, and the rest of this file paints
    mostly disjoint marks.

    It is also the shape a consumer's effect scatter has, and that
    mark never took the bulk path's fallback -- it was already
    recording before #414 -- so it exercises the half of the change
    that is meant to be invisible.
    """
    _assert_case_matches(6, "halo and point, two bulk calls")


def test_a_layered_mark_matches_however_it_is_expressed() raises:
    # The same picture drawn a marker at a time rather than in bulk.
    # Both reach the region, by different routes, and must agree with
    # the recipe and so with each other.
    _assert_case_matches(7, "halo and point, per marker")


def test_recordable_and_unrecordable_work_interleaved() raises:
    _assert_case_matches(3, "mixed")


def test_repeated_renders_of_a_mixed_region() raises:
    """A region drawn over and over, with recordable and unrecordable
    work in it, which is what a program rendering many charts does.

    This is #412: a clip records as an op, and when something else in
    the region forces it to materialize, those ops replay onto one
    canvas shared by every band. Applying them from parallel tasks
    raced on its clip stack and crashed the runtime rather than
    drawing wrongly, so a batch holding clip ops now renders on one
    band. It took both a clip and a bulk marker call to show: either
    alone is fine, and a single render always was.
    """
    var cache = FontCache()
    for k in range(12):
        var out = Canvas(200, 150, BG)
        out.begin_supersampled(3, BG)
        out.begin_batch()
        for i in range(20):
            var x = 20.0 + Float64(i) * 8.0
            out.draw_line_aa(x, 10.0, x, 140.0, Color(225, 225, 225), 1.0)
        out.end_batch()
        out.push_clip(20, 10, 160, 130)
        for i in range(60):
            out.fill_circle_aa(
                20.0 + Float64((i * 37) % 160),
                10.0 + Float64((i * 53) % 130),
                4.0,
                INK,
            )
        out.pop_clip()
        var pts: List[FPoint] = [FPoint(60.0, 40.0), FPoint(120.0, 90.0)]
        fill_circles_aa(out, pts, 5.0, Color(200, 60, 60, 180))
        draw_text(
            out, 10.0, 145.0, "label", Color(40, 40, 40), 8.0, cache=cache
        )
        out.end_supersampled()
        assert_true(out.width == 200, "render " + String(k) + " completed")


def test_a_recordable_scene_keeps_its_banded_replay() raises:
    """The docstring on `begin_supersampled` promises the enlarged
    buffer is not held for a scene it can record. Byte-identity cannot
    check that: the pixels are the same whether the region replayed
    band by band or gave up and materialized. So read the flag, which
    is the only place the difference shows before `end_supersampled`
    clears it."""
    var out = Canvas(200, 150, BG)
    out.begin_supersampled(3, BG)
    _scene(out)
    var pts: List[FPoint] = [FPoint(60.0, 40.0), FPoint(120.0, 90.0)]
    fill_circles_aa(out, pts, 5.0, Color(200, 60, 60, 180))
    out.push_clip(20, 10, 160, 130)
    out.fill_circle_aa(70.0, 50.0, 6.0, INK)
    out.pop_clip()
    assert_equal(
        out._region_materialized,
        False,
        "a recordable scene must not materialize the enlarged buffer",
    )
    out.end_supersampled()


def test_bulk_markers_keep_the_banded_replay() raises:
    """The whole point of #415, stated as a resource claim rather than
    a timing one. A bulk marker call used to force materialization,
    which is what a consumer's gate was written to avoid."""
    var out = Canvas(200, 150, BG)
    out.begin_supersampled(3, BG)
    var pts = List[FPoint]()
    for i in range(200):
        pts.append(
            FPoint(
                10.0 + Float64((i * 37) % 180), 8.0 + Float64((i * 53) % 134)
            )
        )
    fill_circles_aa(out, pts, 2.5, INK)
    assert_equal(
        out._region_materialized,
        False,
        "a bulk marker call must not materialize the enlarged buffer",
    )
    out.end_supersampled()


def test_an_unrecordable_primitive_materializes() raises:
    """The other half of the same claim, so the test above cannot pass
    by the flag simply never being set. A blur has no recorded form,
    so it gives up the banded replay where it appears -- and the
    result is still correct, which is exactly why the fallback needs a
    test rather than an eye."""
    var out = Canvas(200, 150, BG)
    out.begin_supersampled(3, BG)
    _scene(out)
    assert_equal(
        out._region_materialized,
        False,
        "still recording before the blur",
    )
    blur(out, 2.0)
    assert_equal(
        out._region_materialized,
        True,
        "a blur has no recorded form, so the region must materialize",
    )
    out.end_supersampled()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
