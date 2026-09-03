"""Tests for Canvas: pixel storage, bounds checks, and blending as it
actually happens through set_pixel (not just Color.blend_over in
isolation -- this exercises the buffer indexing math too).
"""

from std.testing import assert_equal, assert_true, assert_false, TestSuite

from canvas.color import Color
from canvas.buffer import Canvas


def test_constructor_fills_every_pixel() raises:
    var c = Canvas(4, 3, Color(5, 6, 7))
    for y in range(3):
        for x in range(4):
            var p = c.get_pixel(x, y)
            assert_equal(p.r, 5)
            assert_equal(p.g, 6)
            assert_equal(p.b, 7)


def test_opaque_set_pixel_overwrites_exactly() raises:
    var c = Canvas(4, 3, Color(5, 6, 7))
    c.set_pixel(1, 1, Color(9, 9, 9, 255))
    var result = c.get_pixel(1, 1)
    assert_equal(result.r, 9)
    assert_equal(result.g, 9)
    assert_equal(result.b, 9)


def test_set_pixel_blends_through_the_buffer() raises:
    var c = Canvas(4, 3, Color(5, 6, 7))
    c.set_pixel(1, 1, Color(9, 9, 9, 255))
    # sa=128, inv=127; r=g=b = (255*128 + 9*127) // 255 = 132
    c.set_pixel(1, 1, Color(255, 255, 255, 128))
    var result = c.get_pixel(1, 1)
    assert_equal(result.r, 132)
    assert_equal(result.g, 132)
    assert_equal(result.b, 132)


def test_out_of_bounds_set_pixel_is_a_noop() raises:
    var c = Canvas(4, 3, Color(5, 6, 7))
    c.set_pixel(-1, -1, Color(1, 1, 1))
    c.set_pixel(100, 100, Color(1, 1, 1))
    var untouched = c.get_pixel(0, 0)
    assert_equal(untouched.r, 5)
    assert_equal(untouched.g, 6)
    assert_equal(untouched.b, 7)


def test_in_bounds_edges() raises:
    var c = Canvas(4, 3, Color(5, 6, 7))
    assert_true(c.in_bounds(0, 0))
    assert_true(c.in_bounds(3, 2))
    assert_false(c.in_bounds(4, 0))
    assert_false(c.in_bounds(0, 3))
    assert_false(c.in_bounds(-1, 0))


def test_no_active_clip_means_in_clip_is_unconditionally_true() raises:
    # With an empty clip stack, in_clip answers only "is a clip
    # restricting this coordinate", which is no regardless of whether
    # the coordinate is on the canvas at all. Canvas bounds are
    # in_bounds' job, which set_pixel checks separately and first.
    var c = Canvas(4, 3, Color(5, 6, 7))
    assert_true(c.in_clip(0, 0))
    assert_true(c.in_clip(3, 2))
    assert_true(c.in_clip(4, 0))  # off-canvas, but no clip says otherwise
    assert_true(c.in_clip(-100, -100))


def test_push_clip_restricts_set_pixel() raises:
    var c = Canvas(10, 10, Color(0, 0, 0))
    c.push_clip(3, 3, 4, 4)  # x in [3,7), y in [3,7)

    c.set_pixel(5, 5, Color(255, 255, 255))  # inside the clip
    _assert_pixel_eq(c, 5, 5, 255)

    c.set_pixel(1, 1, Color(255, 255, 255))  # outside the clip
    _assert_pixel_eq(c, 1, 1, 0)

    c.set_pixel(7, 5, Color(255, 255, 255))  # x==7 is one past the clip
    _assert_pixel_eq(c, 7, 5, 0)

    c.set_pixel(6, 5, Color(255, 255, 255))  # x==6 is the last included column
    _assert_pixel_eq(c, 6, 5, 255)


def test_pop_clip_restores_full_canvas() raises:
    var c = Canvas(10, 10, Color(0, 0, 0))
    c.push_clip(3, 3, 4, 4)
    c.pop_clip()

    c.set_pixel(1, 1, Color(255, 255, 255))  # outside the popped clip
    _assert_pixel_eq(c, 1, 1, 255)


def test_pop_clip_on_empty_stack_is_a_noop() raises:
    var c = Canvas(10, 10, Color(0, 0, 0))
    c.pop_clip()  # nothing pushed yet -- should not raise or misbehave
    c.set_pixel(1, 1, Color(255, 255, 255))
    _assert_pixel_eq(c, 1, 1, 255)


def test_nested_push_clip_intersects_with_parent() raises:
    # A child clip extending past its parent's is cut to the overlap,
    # which is the point of a stack over a single replaceable rect: a
    # sub-plot can't escape its parent's region by pushing a wider
    # clip.
    var c = Canvas(20, 20, Color(0, 0, 0))
    c.push_clip(2, 2, 10, 10)  # parent: x in [2,12), y in [2,12)
    c.push_clip(5, 5, 20, 20)  # child, deliberately oversized

    c.set_pixel(8, 8, Color(255, 255, 255))  # inside both
    _assert_pixel_eq(c, 8, 8, 255)

    c.set_pixel(15, 8, Color(255, 255, 255))  # inside child, outside parent
    _assert_pixel_eq(c, 15, 8, 0)

    c.set_pixel(3, 3, Color(255, 255, 255))  # inside parent, outside child
    _assert_pixel_eq(c, 3, 3, 0)

    c.pop_clip()  # back to just the parent clip
    c.set_pixel(
        3, 3, Color(255, 255, 255)
    )  # now inside the active (parent) clip
    _assert_pixel_eq(c, 3, 3, 255)


def test_fill_respects_the_active_clip() raises:
    # Canvas.fill() loops over the whole canvas through set_pixel, so
    # clipping composes with Canvas's own methods, not just the free
    # functions in canvas.shapes.
    var c = Canvas(6, 6, Color(0, 0, 0))
    c.push_clip(2, 2, 2, 2)  # x in [2,4), y in [2,4)
    c.fill(Color(255, 255, 255))

    for y in range(6):
        for x in range(6):
            var inside_clip = x >= 2 and x < 4 and y >= 2 and y < 4
            var expected = UInt8(255) if inside_clip else UInt8(0)
            _assert_pixel_eq(c, x, y, expected)


def test_write_pixel_blend_matches_blend_over() raises:
    # test_color.mojo checks blend_over_opaque's arithmetic in
    # isolation; this checks what a caller actually gets after
    # set_pixel has routed through write_pixel and the buffer
    # indexing, across the whole alpha range rather than a sample.
    var bg = Color(17, 200, 90)
    for a in range(256):
        var c = Canvas(1, 1, bg)
        var src = Color(240, 30, 130, UInt8(a))
        c.set_pixel(0, 0, src)
        var expected = src.blend_over(bg)
        var got = c.get_pixel(0, 0)
        assert_equal(got.r, expected.r, "red matches blend_over")
        assert_equal(got.g, expected.g, "green matches blend_over")
        assert_equal(got.b, expected.b, "blue matches blend_over")
        assert_equal(got.a, 255, "an opaque destination stays opaque")


def test_write_pixel_blend_onto_a_translucent_destination() raises:
    # The other branch: a destination carrying its own alpha needs
    # blend_over's per-pixel divide, and an output alpha that actually
    # varies rather than staying pinned at 255.
    var bg = Color(17, 200, 90, 128)
    for a in range(256):
        var c = Canvas(1, 1, bg)
        var src = Color(240, 30, 130, UInt8(a))
        c.set_pixel(0, 0, src)
        var expected = src.blend_over(bg)
        var got = c.get_pixel(0, 0)
        assert_equal(got.r, expected.r, "red matches blend_over")
        assert_equal(got.g, expected.g, "green matches blend_over")
        assert_equal(got.b, expected.b, "blue matches blend_over")
        assert_equal(got.a, expected.a, "output alpha tracks blend_over")


def test_translucent_fill_matches_blend_over_at_every_width() raises:
    # _fill_region blends four pixels per vector pass and leaves the
    # remainder to its scalar loop, so every width mod 4 has to land on
    # the same bytes. 1..17 covers each remainder several times,
    # including the widths below one whole group.
    var bg = Color(17, 200, 90)
    var src = Color(240, 30, 130, 128)
    var expected = src.blend_over(bg)
    for w in range(1, 18):
        var c = Canvas(w, 2, bg)
        c.fill(src)
        for y in range(2):
            for x in range(w):
                var got = c.get_pixel(x, y)
                assert_equal(got.r, expected.r, "red at width " + String(w))
                assert_equal(got.g, expected.g, "green at width " + String(w))
                assert_equal(got.b, expected.b, "blue at width " + String(w))
                assert_equal(got.a, 255, "stays opaque at width " + String(w))


def test_translucent_fill_onto_a_translucent_canvas() raises:
    # A destination carrying its own alpha sends every group to the
    # scalar path, since blend_over's per-pixel divide has no lane-wise
    # form. The result is still blend_over's, output alpha included.
    var bg = Color(17, 200, 90, 128)
    var src = Color(240, 30, 130, 200)
    var expected = src.blend_over(bg)
    var c = Canvas(9, 2, bg)
    c.fill(src)
    for y in range(2):
        for x in range(9):
            var got = c.get_pixel(x, y)
            assert_equal(got.r, expected.r, "red")
            assert_equal(got.g, expected.g, "green")
            assert_equal(got.b, expected.b, "blue")
            assert_equal(got.a, expected.a, "output alpha tracks blend_over")


def test_translucent_fill_over_mixed_destination_alpha() raises:
    # The boundary case between the two: one translucent pixel inside
    # the first group of four makes that group unblendable across
    # lanes, so the row falls to the scalar path partway through.
    # Every pixel must still match blend_over against what it actually
    # held, on both sides of the switch.
    var opaque_bg = Color(17, 200, 90)
    var clear_bg = Color(60, 10, 220, 128)
    var src = Color(240, 30, 130, 128)

    # Built through the pixels constructor: write_pixel would blend the
    # translucent pixel in rather than store it.
    var pixels = List[UInt8]()
    for x in range(10):
        var seed = clear_bg if x == 2 else opaque_bg
        pixels.append(seed.r)
        pixels.append(seed.g)
        pixels.append(seed.b)
        pixels.append(seed.a)
    var c = Canvas(10, 1, pixels^)
    c.fill(src)

    for x in range(10):
        var seed = clear_bg if x == 2 else opaque_bg
        var expected = src.blend_over(seed)
        var got = c.get_pixel(x, 0)
        assert_equal(got.r, expected.r, "red at x=" + String(x))
        assert_equal(got.g, expected.g, "green at x=" + String(x))
        assert_equal(got.b, expected.b, "blue at x=" + String(x))
        assert_equal(got.a, expected.a, "alpha at x=" + String(x))


def _assert_pixel_eq(c: Canvas, x: Int, y: Int, expected_r: UInt8) raises:
    var p = c.get_pixel(x, y)
    assert_equal(p.r, expected_r)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
