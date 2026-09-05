"""Tests for pattern.mojo: PatternSource.color_at under each Extend
mode, the offset it samples through, hatch_tile's five kinds, and the
path/rect fills in canvas.path/canvas.shapes.rects that take a pattern
as their fill source. Every expected wrap/reflect/clamp index is
hand-computed from the same floor-based modulo arithmetic the
docstring describes, not read back out of the implementation.
"""

from std.testing import assert_equal, assert_true, TestSuite

from canvas.buffer import Canvas
from canvas.color import Color
from canvas.fill_rule import FillRule
from canvas.pattern import Extend, Hatch, PatternSource, hatch_tile
from canvas.path import (
    Path,
    fill_path_pattern,
    fill_path_pattern_aa,
)
from canvas.shapes.lines import LineCap, draw_line_aa
from canvas.shapes.rects import fill_rect_pattern


def _indexed_tile() raises -> Canvas:
    """A 4x4 tile where every pixel's red channel is a unique index
    16*y + x (0..15, distinct and never repeating), so sampling the
    wrong pixel under wraparound reads back a different, checkable
    value rather than coincidentally matching.
    """
    var tile = Canvas(4, 4, Color(0, 0, 0))
    for y in range(4):
        for x in range(4):
            tile.set_pixel(x, y, Color(UInt8(16 * y + x), 0, 0, 255))
    return tile^


def test_extend_repeat_wraps_forward_and_backward() raises:
    var tile = _indexed_tile()
    var pattern = PatternSource(tile, Extend.REPEAT)

    # x=5: 5 % 4 = 1 (Mojo's truncating "%" already gives the right
    # answer for a positive value) -> tile column 1.
    assert_equal(pattern.color_at(5.0, 0.0).r, tile.get_pixel(1, 0).r)

    # x=-1: -1 % 4 = -1 truncated toward zero, not the floor-based -3;
    # +4 corrects it to 3 -> tile column 3, the wraparound neighbor of
    # column 0, not column 1 a truncating implementation would give.
    assert_equal(pattern.color_at(-1.0, 0.0).r, tile.get_pixel(3, 0).r)

    # y=-5: -5 % 4 = -1 (truncated), +4 = 3 -> tile row 3.
    assert_equal(pattern.color_at(0.0, -5.0).r, tile.get_pixel(0, 3).r)


def test_extend_reflect_mirrors_including_negative_coordinates() raises:
    var tile = _indexed_tile()
    var pattern = PatternSource(tile, Extend.REFLECT)

    # x=4: period = 2*4 = 8, m = 4 % 8 = 4; 4 >= 4 so the mapped index
    # is period-1-m = 8-1-4 = 3 -- the tile's own last column, mirrored
    # back rather than wrapped to column 0.
    assert_equal(pattern.color_at(4.0, 0.0).r, tile.get_pixel(3, 0).r)

    # x=-1: m = -1 % 8 = -1 truncated, +8 = 7; 7 >= 4 so mapped =
    # 8-1-7 = 0 -- column 0 mirrored across the left edge onto itself.
    assert_equal(pattern.color_at(-1.0, 0.0).r, tile.get_pixel(0, 0).r)

    # x=-4: m = -4 % 8 = -4 truncated, +8 = 4; 4 >= 4 so mapped =
    # 8-1-4 = 3 -- one full period back, still column 3.
    assert_equal(pattern.color_at(-4.0, 0.0).r, tile.get_pixel(3, 0).r)


def test_extend_pad_clamps_to_the_tile_edge() raises:
    var tile = _indexed_tile()
    var pattern = PatternSource(tile, Extend.PAD)

    assert_equal(pattern.color_at(100.0, 0.0).r, tile.get_pixel(3, 0).r)
    assert_equal(pattern.color_at(-100.0, 0.0).r, tile.get_pixel(0, 0).r)
    assert_equal(pattern.color_at(0.0, 100.0).r, tile.get_pixel(0, 3).r)


def test_extend_none_is_transparent_outside_the_tile() raises:
    var tile = _indexed_tile()
    var pattern = PatternSource(tile, Extend.NONE)

    var outside = pattern.color_at(-1.0, 0.0)
    assert_equal(outside.a, 0)

    var inside = pattern.color_at(2.0, 1.0)
    assert_equal(inside.r, tile.get_pixel(2, 1).r)
    assert_equal(inside.a, 255)


def test_offset_shifts_the_sampled_tile_origin() raises:
    var tile = _indexed_tile()
    var pattern = PatternSource(tile, Extend.REPEAT, ox=10.0, oy=5.0)

    # The tile's own (0, 0) now sits at device point (10, 5).
    assert_equal(pattern.color_at(10.0, 5.0).r, tile.get_pixel(0, 0).r)
    assert_equal(pattern.color_at(11.0, 5.0).r, tile.get_pixel(1, 0).r)
    # One step short of the offset wraps backward, same arithmetic as
    # the un-offset REPEAT case shifted by (10, 5).
    assert_equal(pattern.color_at(9.0, 5.0).r, tile.get_pixel(3, 0).r)


def _rect_path(x: Float64, y: Float64, w: Float64, h: Float64) raises -> Path:
    var p = Path()
    p.move_to(x, y)
    p.line_to(x + w, y)
    p.line_to(x + w, y + h)
    p.line_to(x, y + h)
    p.close()
    return p^


def test_fill_path_pattern_interior_matches_the_source() raises:
    var tile = _indexed_tile()
    var pattern = PatternSource(tile, Extend.REPEAT)
    var canvas = Canvas(16, 16, Color(255, 255, 255))
    var path = _rect_path(0.0, 0.0, 16.0, 16.0)
    fill_path_pattern(canvas, path, pattern)

    # Well inside the fill, spanning two full tile periods -- coverage
    # is complete everywhere, so the pixel is exactly what the source
    # reports at that point, no blending with the white background.
    for y in range(16):
        for x in range(16):
            var expected = pattern.color_at(Float64(x), Float64(y))
            var got = canvas.get_pixel(x, y)
            assert_equal(got.r, expected.r)


def test_fill_path_pattern_aa_interior_matches_the_source() raises:
    var tile = _indexed_tile()
    var pattern = PatternSource(tile, Extend.REPEAT)
    var canvas = Canvas(16, 16, Color(255, 255, 255))
    # The path's own edge sits a couple of pixels outside the canvas on
    # every side, so every sampled pixel below is a full-coverage
    # interior point of the AA fill rather than a boundary pixel at
    # ~50% coverage -- a gradient's coverage-at-the-edge is covered by
    # the gradient tests, and isn't the thing under test here.
    var path = _rect_path(-2.0, -2.0, 20.0, 20.0)
    fill_path_pattern_aa(canvas, path, pattern)

    for y in range(16):
        for x in range(16):
            var expected = pattern.color_at(Float64(x), Float64(y))
            var got = canvas.get_pixel(x, y)
            assert_equal(got.r, expected.r)


def test_fill_rect_pattern_matches_the_source() raises:
    var tile = _indexed_tile()
    var pattern = PatternSource(tile, Extend.REPEAT)
    var canvas = Canvas(12, 12, Color(255, 255, 255))
    fill_rect_pattern(canvas, 0, 0, 12, 12, pattern)

    for y in range(12):
        for x in range(12):
            var expected = pattern.color_at(Float64(x), Float64(y))
            var got = canvas.get_pixel(x, y)
            assert_equal(got.r, expected.r)


def test_hatch_diagonal_ink_and_background() raises:
    var spacing = 20
    var ink = Color(0, 0, 0)
    var bg = Color(255, 255, 255)
    var tile = hatch_tile(spacing, 3.0, ink, bg, Hatch.DIAGONAL)

    # (10, 10) sits exactly on the main diagonal's centerline -- fully
    # inside the 3px-wide line, far from either end.
    assert_equal(tile.get_pixel(10, 10).r, 0)

    # (2, 17): distance to the line y=x is |2-17|/sqrt(2) ~= 10.6,
    # far outside a 1.5px half-width -- background.
    assert_equal(tile.get_pixel(2, 17).r, 255)


def test_hatch_cross_ink_on_both_diagonals() raises:
    var spacing = 20
    var ink = Color(0, 0, 0)
    var bg = Color(255, 255, 255)
    var tile = hatch_tile(spacing, 3.0, ink, bg, Hatch.CROSS)

    # (10, 10): on the main diagonal y=x.
    assert_equal(tile.get_pixel(10, 10).r, 0)
    # (10, 9): on the anti-diagonal x+y=19 (the line from (0,19) to
    # (19,0)), since 10+9=19.
    assert_equal(tile.get_pixel(10, 9).r, 0)
    # (2, 10): distance to y=x is |2-10|/sqrt(2) ~= 5.7; distance to
    # x+y=19 is |12-19|/sqrt(2) ~= 4.9 -- both well past a 1.5px
    # half-width, background.
    assert_equal(tile.get_pixel(2, 10).r, 255)


def test_hatch_horizontal_ink_and_background() raises:
    var spacing = 20
    var ink = Color(0, 0, 0)
    var bg = Color(255, 255, 255)
    var tile = hatch_tile(spacing, 4.0, ink, bg, Hatch.HORIZONTAL)

    # Center row = (20-1)/2 = 9.5; a 4px line spans y in [7.5, 11.5],
    # so row 9 (well inside) is ink, row 0 (far above) is background.
    assert_equal(tile.get_pixel(10, 9).r, 0)
    assert_equal(tile.get_pixel(10, 0).r, 255)


def test_hatch_vertical_ink_and_background() raises:
    var spacing = 20
    var ink = Color(0, 0, 0)
    var bg = Color(255, 255, 255)
    var tile = hatch_tile(spacing, 4.0, ink, bg, Hatch.VERTICAL)

    assert_equal(tile.get_pixel(9, 10).r, 0)
    assert_equal(tile.get_pixel(0, 10).r, 255)


def test_hatch_dots_ink_at_center_background_at_corner() raises:
    var spacing = 20
    var ink = Color(0, 0, 0)
    var bg = Color(255, 255, 255)
    var tile = hatch_tile(spacing, 6.0, ink, bg, Hatch.DOTS)

    # Center at ((20-1)/2, (20-1)/2) = (9.5, 9.5), radius 3 -- (10, 10)
    # is distance sqrt(0.5) ~= 0.7 from center, well inside the dot.
    assert_equal(tile.get_pixel(10, 10).r, 0)
    assert_equal(tile.get_pixel(0, 0).r, 255)


def _reference_hatch(
    spacing: Int, width: Float64, cross: Bool
) raises -> Canvas:
    """The repeated pattern drawn directly onto a 3x3-tile canvas: the
    family of parallel stripes one tile apart, every one a single
    continuous line with its ends far outside the canvas. Its centre
    tile is what a seamless hatch tile has to equal.
    """
    var s = Float64(spacing)
    var ink = Color(0, 0, 0)
    var reference = Canvas(spacing * 3, spacing * 3, Color(255, 255, 255))
    for k in range(-4, 5):
        var off = Float64(k) * s
        draw_line_aa(
            reference,
            -s + off,
            -s,
            4.0 * s + off,
            4.0 * s,
            ink,
            width=width,
            cap=LineCap.BUTT,
        )
        if cross:
            # The tile's anti-diagonal runs through (0, s - 1) and
            # (s - 1, 0), so its family has intercept s - 1 + k * s in
            # tile space, 3s - 1 + k * s here.
            draw_line_aa(
                reference,
                -s + off,
                4.0 * s - 1.0,
                4.0 * s + off,
                -s - 1.0,
                ink,
                width=width,
                cap=LineCap.BUTT,
            )
    return reference^


def test_diagonal_hatch_tiles_without_a_seam() raises:
    # Repeated, a diagonal hatch is the family of parallel stripes one
    # tile apart, and the tile's pixels near its off-diagonal corners
    # are covered by the neighbouring stripes, not its own: at spacing
    # 8 and width 3, the corner pixel (7, 0) is 0.7 px from the next
    # stripe's centre. A tile that only draws its own stripe leaves
    # those corners background and shows a notch at every tile
    # boundary. The tile must equal the centre tile of the pattern
    # drawn directly, pixel for pixel, for DIAGONAL and CROSS.
    var spacing = 8
    var width = 3.0
    var ink = Color(0, 0, 0)
    var bg = Color(255, 255, 255)
    var tile = hatch_tile(spacing, width, ink, bg, Hatch.DIAGONAL)
    assert_true(
        tile.get_pixel(spacing - 1, 0).r < 255,
        "the corner under the neighbouring stripe carries ink",
    )
    assert_true(tile.get_pixel(0, spacing - 1).r < 255, "and the other")

    var reference = _reference_hatch(spacing, width, False)
    for y in range(spacing):
        for x in range(spacing):
            assert_equal(
                tile.get_pixel(x, y).r,
                reference.get_pixel(spacing + x, spacing + y).r,
                "diagonal tile pixel (" + String(x) + ", " + String(y) + ")",
            )
    var cross = hatch_tile(spacing, width, ink, bg, Hatch.CROSS)
    var cross_ref = _reference_hatch(spacing, width, True)
    for y in range(spacing):
        for x in range(spacing):
            assert_equal(
                cross.get_pixel(x, y).r,
                cross_ref.get_pixel(spacing + x, spacing + y).r,
                "cross tile pixel (" + String(x) + ", " + String(y) + ")",
            )

    # And tiled through PatternSource, the stripe runs across the seam
    # where four copies meet: the tile's bottom-right corner and the
    # next tile's top-left are both solid ink.
    var pattern = PatternSource(tile, Extend.REPEAT)
    var big = Canvas(spacing * 2, spacing * 2, bg)
    fill_rect_pattern(big, 0, 0, spacing * 2, spacing * 2, pattern)
    assert_equal(big.get_pixel(spacing - 1, spacing - 1).r, 0)
    assert_equal(big.get_pixel(spacing, spacing).r, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
