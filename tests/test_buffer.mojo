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


def test_annotated_group_methods_are_no_ops_on_a_canvas() raises:
    # DrawTarget declares these so a caller can name what it draws
    # without knowing which backend it holds. A raster canvas has
    # nowhere to put the name, so both are no-ops -- what matters is
    # that generic code bracketing its drawing with them still draws,
    # and that an unbalanced call cannot break anything.
    var c = Canvas(6, 6, Color(0, 0, 0))
    c.begin_annotated_group("a series")
    c.fill_rect(1, 1, 2, 2, Color(255, 255, 255))
    c.end_annotated_group()
    c.end_annotated_group()  # unbalanced, still nothing

    _assert_pixel_eq(c, 1, 1, 255)
    _assert_pixel_eq(c, 5, 5, 0)


def _assert_pixel_eq(c: Canvas, x: Int, y: Int, expected_r: UInt8) raises:
    var p = c.get_pixel(x, y)
    assert_equal(p.r, expected_r)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
