"""Tests for Canvas: pixel storage, bounds checks, and blending as it
actually happens through set_pixel (not just Color.blend_over in
isolation -- this exercises the buffer indexing math too).
"""

from std.testing import assert_equal, assert_true, assert_false, TestSuite

from canvas.color import Color
from canvas.buffer import (
    Canvas,
    _clear_bands,
    _pack_rgba,
    _MIN_PARALLEL_CLEAR,
    BYTES_PER_PIXEL,
)


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


def test_clear_bands_stays_serial_inside_one_l3_slice() raises:
    # The threshold is the point of the whole rule: below it a band
    # moves lines to another CCX's slice and costs more than it saves.
    var under = (_MIN_PARALLEL_CLEAR // BYTES_PER_PIXEL) - 1
    assert_equal(_clear_bands(under, 0), 1)
    assert_equal(_clear_bands(1, 0), 1)
    assert_equal(_clear_bands(0, 0), 1)


def test_clear_bands_splits_past_the_slice_and_honors_the_cap() raises:
    var over = _MIN_PARALLEL_CLEAR // BYTES_PER_PIXEL
    assert_true(_clear_bands(over, 0) >= 2)
    # A worker cap below the band count wins, but never drops the fill
    # to a band count of zero.
    assert_equal(_clear_bands(over, 1), 1)
    assert_true(_clear_bands(over, 2) <= 2)


def _first_differing_pixel(c: Canvas, packed: UInt32) -> Int:
    """The first pixel of `c` that is not `packed`, or -1. Sixteen
    pixels per comparison: these canvases are past the parallel-clear
    threshold, so a scalar sweep of one would dominate the file.
    """
    comptime LANES = 16
    var n = c.width * c.height
    var p32 = c.pixels.unsafe_ptr().unsafe_bitcast[UInt32]()
    var want = SIMD[DType.uint32, LANES](packed)
    var i = 0
    while i + LANES <= n:
        var v = p32.unsafe_offset(i).unsafe_load[width=LANES]()
        if (v ^ want).reduce_max() != 0:
            for k in range(i, i + LANES):
                if p32[unsafe_offset=k] != packed:
                    return k
        i += LANES
    while i < n:
        if p32[unsafe_offset=i] != packed:
            return i
        i += 1
    return -1


def _assert_uniform(c: Canvas, r: UInt8, g: UInt8, b: UInt8) raises:
    # Every pixel, not a sample: a banded fill's failure mode is a whole
    # band left unwritten, and only a full sweep sees that.
    var packed = _pack_rgba(Color(r, g, b))
    var bad = _first_differing_pixel(c, packed)
    if bad >= 0:
        raise Error(
            "pixel "
            + String(bad)
            + " of "
            + String(c.width * c.height)
            + " was not the fill color"
        )


def test_constructor_fills_every_pixel_of_a_banded_canvas() raises:
    # Wide enough to cross _MIN_PARALLEL_CLEAR, and with a pixel count
    # that is neither a multiple of the band count nor of the eight-lane
    # store, so both the band tail and the scalar tail run.
    var px = _MIN_PARALLEL_CLEAR // BYTES_PER_PIXEL + 3
    var c = Canvas(px, 1, Color(11, 22, 33))
    assert_true(_clear_bands(px, 0) >= 2)
    _assert_uniform(c, 11, 22, 33)


def test_fill_covers_every_pixel_of_a_banded_canvas() raises:
    var px = _MIN_PARALLEL_CLEAR // BYTES_PER_PIXEL + 3
    var c = Canvas(px, 1, Color(0, 0, 0))
    c.fill(Color(44, 55, 66))
    _assert_uniform(c, 44, 55, 66)


def test_banded_fill_matches_a_serial_one_byte_for_byte() raises:
    # Same fill, once on a canvas past the threshold and once on one
    # capped to a single worker. The bytes must not depend on how the
    # work was divided.
    var px = _MIN_PARALLEL_CLEAR // BYTES_PER_PIXEL + 7
    var banded = Canvas(px, 1, Color(0, 0, 0))
    banded.fill(Color(77, 88, 99))

    var serial = Canvas(px, 1, Color(0, 0, 0))
    serial.set_max_workers(1)
    serial.fill(Color(77, 88, 99))

    assert_equal(len(banded.pixels), len(serial.pixels))
    var packed = _pack_rgba(Color(77, 88, 99))
    assert_equal(_first_differing_pixel(banded, packed), -1)
    assert_equal(_first_differing_pixel(serial, packed), -1)


def test_fill_under_a_clip_does_not_take_the_whole_buffer_path() raises:
    # The fast path is only correct for the whole buffer; a clip must
    # still cut the fill down even on a canvas past the threshold.
    var c = Canvas(8, 6, Color(0, 0, 0))
    c.push_clip(2, 2, 3, 2)
    c.fill(Color(255, 255, 255))
    c.pop_clip()
    for y in range(6):
        for x in range(8):
            var inside = x >= 2 and x < 5 and y >= 2 and y < 4
            _assert_pixel_eq(c, x, y, UInt8(255) if inside else UInt8(0))


def test_translucent_fill_still_blends() raises:
    var c = Canvas(4, 3, Color(0, 0, 0))
    c.fill(Color(255, 255, 255, 128))
    var p = c.get_pixel(2, 1)
    assert_true(p.r > 0 and p.r < 255)
    assert_equal(p.a, 255)


def _assert_pixel_eq(c: Canvas, x: Int, y: Int, expected_r: UInt8) raises:
    var p = c.get_pixel(x, y)
    assert_equal(p.r, expected_r)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
