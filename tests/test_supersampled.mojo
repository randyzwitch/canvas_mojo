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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
