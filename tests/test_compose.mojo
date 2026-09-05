"""Tests for draw_canvas: compositing one canvas onto another, at an
integer offset and through a matrix.

The interesting cases for the integer blit are the ones that only exist
because the canvas carries alpha -- a transparent source leaving the
destination alone, a translucent one blending rather than replacing,
and layer opacity compounding with a source pixel's own alpha.

The matrix overloads are checked against values derived from the
sampling rules rather than read back out: a shift by whole pixels has
to reproduce the blit byte for byte, a 2x scale has to duplicate each
source pixel, a quarter turn has to move a named pixel to a named
place, and a half-pixel shift has to produce the mean of two known
neighbours.
"""

from std.math import pi
from std.testing import assert_equal, assert_raises, assert_true, TestSuite

from canvas.blend import BlendMode
from canvas.buffer import Canvas
from canvas.color import Color
from canvas.compose import Filter, draw_canvas
from canvas.geometry import Matrix2D
from canvas.path import Path
from canvas.shapes.rects import fill_rect

comptime CLEAR = Color(0, 0, 0, 0)
comptime WHITE = Color(255, 255, 255)
comptime RED = Color(255, 0, 0)
comptime BLUE = Color(0, 0, 255)


def _assert_rgb(c: Canvas, x: Int, y: Int, e: Color, label: String) raises:
    var p = c.get_pixel(x, y)
    assert_equal(p.r, e.r, label + " (r)")
    assert_equal(p.g, e.g, label + " (g)")
    assert_equal(p.b, e.b, label + " (b)")


def test_opaque_source_replaces_destination() raises:
    var dst = Canvas(10, 10, WHITE)
    var src = Canvas(4, 4, RED)
    draw_canvas(dst, src, 3, 3)
    _assert_rgb(dst, 4, 4, RED, "inside the pasted region")
    _assert_rgb(dst, 0, 0, WHITE, "outside it")
    _assert_rgb(dst, 7, 7, WHITE, "just past the bottom-right corner")


def test_transparent_source_leaves_destination_untouched() raises:
    var dst = Canvas(8, 8, RED)
    var src = Canvas(8, 8, CLEAR)
    draw_canvas(dst, src, 0, 0)
    for y in range(8):
        for x in range(8):
            _assert_rgb(dst, x, y, RED, "fully transparent source is a no-op")
            assert_equal(dst.get_pixel(x, y).a, 255, "alpha untouched too")


def test_translucent_source_blends() raises:
    # Half-alpha red over opaque white: the same value fill_rect would
    # produce drawing that colour directly, which is the point -- a
    # composited layer must match a directly drawn one.
    var dst = Canvas(4, 4, WHITE)
    var src = Canvas(4, 4, Color(255, 0, 0, 128))
    draw_canvas(dst, src, 0, 0)

    var reference = Canvas(4, 4, WHITE)
    fill_rect(reference, 0, 0, 4, 4, Color(255, 0, 0, 128))

    for y in range(4):
        for x in range(4):
            var a = dst.get_pixel(x, y)
            var b = reference.get_pixel(x, y)
            assert_equal(a.r, b.r, "composite matches a direct draw")
            assert_equal(a.g, b.g)
            assert_equal(a.b, b.b)
            assert_equal(a.a, b.a)


def test_partial_overlap_is_clipped_not_wrapped() raises:
    # A source hanging off the top-left: only its visible part lands,
    # and nothing wraps around to the far edge.
    var dst = Canvas(8, 8, WHITE)
    var src = Canvas(4, 4, RED)
    draw_canvas(dst, src, -2, -2)
    _assert_rgb(dst, 0, 0, RED, "the visible corner is drawn")
    _assert_rgb(dst, 1, 1, RED, "...and the rest of the overlap")
    _assert_rgb(dst, 2, 2, WHITE, "past the source's extent")
    _assert_rgb(dst, 7, 7, WHITE, "nothing wrapped to the far corner")


def test_fully_offscreen_source_is_a_noop() raises:
    var dst = Canvas(8, 8, WHITE)
    var src = Canvas(4, 4, RED)
    draw_canvas(dst, src, 100, 100)
    draw_canvas(dst, src, -50, 0)
    for y in range(8):
        for x in range(8):
            _assert_rgb(dst, x, y, WHITE, "offscreen paste changes nothing")


def test_respects_the_active_clip() raises:
    var dst = Canvas(10, 10, WHITE)
    var src = Canvas(10, 10, RED)
    dst.push_clip(2, 2, 3, 3)
    draw_canvas(dst, src, 0, 0)
    dst.pop_clip()
    _assert_rgb(dst, 3, 3, RED, "inside the clip")
    _assert_rgb(dst, 1, 1, WHITE, "outside the clip is untouched")
    _assert_rgb(dst, 6, 6, WHITE, "past the clip's far edge too")


def test_opacity_scales_the_whole_layer() raises:
    # An opaque red layer at half opacity must equal drawing red at
    # alpha 128 directly.
    var dst = Canvas(4, 4, WHITE)
    var src = Canvas(4, 4, RED)
    draw_canvas(dst, src, 0, 0, 128)

    var reference = Canvas(4, 4, WHITE)
    fill_rect(reference, 0, 0, 4, 4, Color(255, 0, 0, 128))
    _assert_rgb(dst, 2, 2, reference.get_pixel(2, 2), "half-opacity layer")


def test_opacity_compounds_with_source_alpha() raises:
    # A source already at alpha 128, drawn at opacity 128, ends up at
    # floor(128 * 128 / 255) = 64.
    var dst = Canvas(4, 4, CLEAR)
    var src = Canvas(4, 4, Color(10, 20, 30, 128))
    draw_canvas(dst, src, 0, 0, 128)
    assert_equal(dst.get_pixel(2, 2).a, 64, "alphas compound")


def test_zero_opacity_is_a_noop() raises:
    var dst = Canvas(4, 4, WHITE)
    var src = Canvas(4, 4, RED)
    draw_canvas(dst, src, 0, 0, 0)
    _assert_rgb(dst, 2, 2, WHITE, "opacity 0 draws nothing")


def test_layers_compose_in_order() raises:
    # Two transparent layers, each holding one opaque square, composed
    # onto a white sheet: the later layer wins where they overlap. This
    # is the workflow the module exists for.
    var grid = Canvas(12, 12, CLEAR)
    fill_rect(grid, 0, 0, 8, 8, BLUE)
    var series = Canvas(12, 12, CLEAR)
    fill_rect(series, 4, 4, 8, 8, RED)

    var sheet = Canvas(12, 12, WHITE)
    draw_canvas(sheet, grid, 0, 0)
    draw_canvas(sheet, series, 0, 0)

    _assert_rgb(sheet, 1, 1, BLUE, "lower layer only")
    _assert_rgb(sheet, 10, 10, RED, "upper layer only")
    _assert_rgb(sheet, 5, 5, RED, "upper layer wins the overlap")
    _assert_rgb(sheet, 11, 0, WHITE, "neither layer covers this")


def test_draw_canvas_respects_an_active_clip_path() raises:
    # draw_canvas writes straight through the pixel pointer, using
    # effective_fill_rect to pre-clip the region. That folds in a
    # rectangle clip, which is a range, but a clip path is a per-pixel
    # coverage value and cannot be folded into bounds -- so a path clip
    # has to send the composite through set_pixel instead. Without
    # that it draws over the whole overlap and the clip does nothing.
    var clip = Path()
    clip.move_to(0.0, 0.0)
    clip.line_to(5.0, 0.0)
    clip.line_to(5.0, 4.0)
    clip.line_to(0.0, 4.0)
    clip.close()

    var dst = Canvas(10, 4, Color(0, 0, 0))
    var src = Canvas(10, 4, Color(255, 255, 255))
    dst.push_clip_path(clip)
    draw_canvas(dst, src, 0, 0)
    dst.pop_clip_path()

    assert_equal(dst.get_pixel(2, 1).r, 255, "inside the clip path is drawn")
    assert_equal(
        dst.get_pixel(8, 1).r, 0, "outside the clip path is left alone"
    )


def test_draw_canvas_with_opacity_respects_a_clip_path() raises:
    # The opacity overload takes the same path, so it needs the same
    # cover: a faded layer must not escape the clip either.
    var clip = Path()
    clip.move_to(0.0, 0.0)
    clip.line_to(5.0, 0.0)
    clip.line_to(5.0, 4.0)
    clip.line_to(0.0, 4.0)
    clip.close()

    var dst = Canvas(10, 4, Color(0, 0, 0))
    var src = Canvas(10, 4, Color(255, 255, 255))
    dst.push_clip_path(clip)
    draw_canvas(dst, src, 0, 0, 128)
    dst.pop_clip_path()

    # 255 over black at alpha 128 is _div255(255 * 128) = 128.
    assert_equal(dst.get_pixel(2, 1).r, 128, "inside the clip, faded")
    assert_equal(
        dst.get_pixel(8, 1).r, 0, "outside the clip path is left alone"
    )


def test_draw_canvas_clip_path_edge_is_antialiased() raises:
    # A clip path's coverage is 0-255, not in/out, so a composite
    # through a partly covered pixel must come out partial. That only
    # happens by going through set_pixel, which consults the mask --
    # the direct pointer write has no way to.
    #
    # The clip's right edge is x=4.25. A pixel is centered on its
    # coordinate, so pixel 4 spans [3.5, 4.5] and at the default 4x
    # supersample its sub-columns sit at 3.625, 3.875, 4.125 and 4.375.
    # Three of those are inside the edge, so coverage is 3/4 and the
    # composited value is round(0.75 * 255) = 191.
    #
    # The left edge x=0.0 halves pixel 0 the same way: sub-columns at
    # -0.375 and -0.125 fall outside, 0.125 and 0.375 inside, giving
    # 2/4 and round(0.5 * 255) = 128.
    var clip = Path()
    clip.move_to(0.0, 0.0)
    clip.line_to(4.25, 0.0)
    clip.line_to(4.25, 4.0)
    clip.line_to(0.0, 4.0)
    clip.close()

    var dst = Canvas(10, 4, Color(0, 0, 0))
    var src = Canvas(10, 4, Color(255, 255, 255))
    dst.push_clip_path(clip)
    draw_canvas(dst, src, 0, 0)
    dst.pop_clip_path()

    assert_equal(dst.get_pixel(0, 1).r, 128, "half-covered left edge pixel")
    assert_equal(dst.get_pixel(2, 1).r, 255, "fully inside is unattenuated")
    assert_equal(dst.get_pixel(4, 1).r, 191, "three-quarter-covered edge pixel")
    assert_equal(dst.get_pixel(5, 1).r, 0, "fully outside is untouched")


def _varied_source(w: Int, h: Int, alpha: UInt8) raises -> Canvas:
    """A source with a different colour in every pixel, so a blit and a
    mapped draw are compared on real data rather than one flat colour.
    """
    var src = Canvas(w, h, CLEAR)
    for y in range(h):
        for x in range(w):
            src.set_pixel(
                x,
                y,
                Color(
                    UInt8(20 + x * 30),
                    UInt8(10 + y * 25),
                    UInt8(200 - x * 10),
                    alpha,
                ),
            )
    return src^


def _assert_same_bytes(a: Canvas, b: Canvas, label: String) raises:
    """Every channel of every pixel equal -- what "the same bytes"
    means for two canvases of the same size.
    """
    assert_equal(a.width, b.width, label + " (width)")
    assert_equal(a.height, b.height, label + " (height)")
    for y in range(a.height):
        for x in range(a.width):
            var p = a.get_pixel(x, y)
            var q = b.get_pixel(x, y)
            var at = label + " at (" + String(x) + ", " + String(y) + ")"
            assert_equal(p.r, q.r, at + " (r)")
            assert_equal(p.g, q.g, at + " (g)")
            assert_equal(p.b, q.b, at + " (b)")
            assert_equal(p.a, q.a, at + " (a)")


def test_identity_matrix_matches_the_blit() raises:
    var src = _varied_source(6, 5, 255)
    var mapped = Canvas(12, 10, WHITE)
    draw_canvas(mapped, src, Matrix2D.identity())
    var blit = Canvas(12, 10, WHITE)
    draw_canvas(blit, src, 0, 0)
    _assert_same_bytes(blit, mapped, "identity through the matrix overload")


def test_whole_pixel_translation_matches_the_blit() raises:
    # The matrix overload has to reach the same bytes as the integer
    # call for a shift by whole pixels, under either filter: that is
    # the case where a sample point sits in exactly one source pixel,
    # and the case a caller is most likely to compare against.
    for alpha in [UInt8(255), UInt8(96)]:
        var src = _varied_source(6, 5, alpha)
        var blit = Canvas(14, 12, WHITE)
        draw_canvas(blit, src, 5, 3)

        var nearest = Canvas(14, 12, WHITE)
        draw_canvas(
            nearest,
            src,
            Matrix2D.translation(5.0, 3.0),
            filter=Filter.NEAREST,
        )
        _assert_same_bytes(
            blit, nearest, "translated blit, nearest, alpha " + String(alpha)
        )

        var bilinear = Canvas(14, 12, WHITE)
        draw_canvas(bilinear, src, Matrix2D.translation(5.0, 3.0))
        _assert_same_bytes(
            blit, bilinear, "translated blit, bilinear, alpha " + String(alpha)
        )


def test_nearest_at_2x_duplicates_each_pixel() raises:
    # Source pixel i covers [i, i+1) in texel space, so scaling by 2
    # spreads it over destination pixels 2i and 2i+1: destination
    # pixel px samples (px + 0.5) / 2, which is i + 0.25 and i + 0.75
    # for those two. A 3x3 source therefore lands exactly on the 6x6
    # block at the origin, with nothing beyond it.
    var src = _varied_source(3, 3, 255)
    var dst = Canvas(8, 8, WHITE)
    draw_canvas(dst, src, Matrix2D.scaling(2.0, 2.0), filter=Filter.NEAREST)

    for j in range(3):
        for i in range(3):
            var want = src.get_pixel(i, j)
            for dy in range(2):
                for dx in range(2):
                    _assert_rgb(
                        dst,
                        2 * i + dx,
                        2 * j + dy,
                        want,
                        "source ("
                        + String(i)
                        + ", "
                        + String(j)
                        + ") duplicated",
                    )
    _assert_rgb(dst, 6, 0, WHITE, "one column past the scaled source")
    _assert_rgb(dst, 0, 6, WHITE, "one row past it")


def test_nearest_at_3x_across_bands_matches_the_source() raises:
    # A 100x100 source at 3x covers 90,000 destination pixels, above
    # the threshold at which the rows are split into bands drawn
    # concurrently, so this is the parallel path the small sources
    # above never reach. Every destination pixel still reads the source
    # pixel it maps to, band boundaries included.
    var src = _varied_source(100, 100, 255)
    var dst = Canvas(300, 300, WHITE)
    draw_canvas(dst, src, Matrix2D.scaling(3.0, 3.0), filter=Filter.NEAREST)
    var mismatches = 0
    for py in range(300):
        for px in range(300):
            var want = src.get_pixel(px // 3, py // 3)
            var got = dst.get_pixel(px, py)
            if got.r != want.r or got.g != want.g or got.b != want.b:
                mismatches += 1
    assert_equal(mismatches, 0, "pixels that differ from their source pixel")


def test_rotation_about_the_centre_moves_a_known_pixel() raises:
    # A quarter turn about the centre of a 4x4 source, which is the
    # texel-space point (2, 2). Positive angles turn +x toward +y,
    # clockwise on a y-down canvas, so the top-right pixel ends up
    # bottom-right and the bottom-left pixel ends up top-left.
    #
    # Pixel (3, 0) has its centre at (3.5, 0.5); relative to the centre
    # that is (1.5, -1.5), which the quarter turn takes to (1.5, 1.5),
    # so it lands on (3.5, 3.5) -- destination pixel (3, 3). Pixel
    # (0, 3), centre (0.5, 3.5), goes from (-1.5, 1.5) to (-1.5, -1.5)
    # and lands on (0.5, 0.5) -- destination pixel (0, 0).
    var src = _varied_source(4, 4, 255)
    var m = (
        Matrix2D.translation(-2.0, -2.0)
        .then(Matrix2D.rotation(pi / 2.0))
        .then(Matrix2D.translation(2.0, 2.0))
    )

    var dst = Canvas(8, 8, WHITE)
    draw_canvas(dst, src, m, filter=Filter.NEAREST)
    _assert_rgb(dst, 3, 3, src.get_pixel(3, 0), "top-right turns bottom-right")
    _assert_rgb(dst, 0, 0, src.get_pixel(0, 3), "bottom-left turns top-left")
    _assert_rgb(dst, 3, 0, src.get_pixel(0, 0), "top-left turns top-right")
    _assert_rgb(dst, 5, 5, WHITE, "outside the turned square")


def test_bilinear_at_a_half_pixel_offset_averages_two_neighbours() raises:
    # A shift of half a pixel to the right. Destination pixel px has
    # its centre at px + 0.5 and samples u = px, whose two horizontal
    # neighbours are the pixels centred at px - 0.5 and px + 0.5 --
    # source columns px - 1 and px, each weighted 0.5. Vertically the
    # sample lands exactly on a pixel centre, so the row is untouched.
    var src = Canvas(4, 3, CLEAR)
    for y in range(3):
        src.set_pixel(0, y, Color(0, 0, 0))
        src.set_pixel(1, y, Color(90, 90, 90))
        src.set_pixel(2, y, Color(180, 180, 180))
        src.set_pixel(3, y, Color(240, 240, 240))

    var dst = Canvas(6, 3, WHITE)
    draw_canvas(dst, src, Matrix2D.translation(0.5, 0.0))

    # (0 + 90) / 2 and (90 + 180) / 2, both exact.
    assert_equal(dst.get_pixel(1, 1).r, 45, "columns 0 and 1 averaged")
    assert_equal(dst.get_pixel(2, 1).r, 135, "columns 1 and 2 averaged")
    # Destination pixel 0 samples u = 0, half a pixel outside the first
    # pixel's centre: the missing neighbour is column 0 itself, so the
    # edge column comes through undiluted.
    assert_equal(dst.get_pixel(0, 1).r, 0, "the edge pixel is clamped")
    # u = 4 is the source's right edge, which is outside it.
    _assert_rgb(dst, 4, 1, WHITE, "past the source's right edge")


def test_bilinear_does_not_bleed_a_transparent_neighbour() raises:
    # Opaque red beside fully transparent green, sampled halfway
    # between them. Weighting premultiplied gives alpha
    # 0.5 * 255 + 0.5 * 0 = 127.5, rounding to 128, and colour
    # (0.5 * 255 * 255) / 127.5 = 255 red with no green at all.
    # Averaging straight colour instead would put 128 green in it.
    var src = Canvas(2, 1, CLEAR)
    src.set_pixel(0, 0, Color(255, 0, 0, 255))
    src.set_pixel(1, 0, Color(0, 255, 0, 0))

    var dst = Canvas(4, 2, CLEAR)
    draw_canvas(dst, src, Matrix2D.translation(0.5, 0.0))

    var p = dst.get_pixel(1, 0)
    assert_equal(p.a, 128, "alpha is the interpolated alpha")
    assert_equal(p.r, 255, "the opaque neighbour's red survives whole")
    assert_equal(p.g, 0, "the transparent neighbour contributes no colour")


def test_source_rectangle_crops() raises:
    # The 4x4 top-right quadrant of an 8x8 source, drawn at the
    # destination origin: the crop moves which pixels are read, not
    # where they land.
    var src = Canvas(8, 8, CLEAR)
    for y in range(8):
        for x in range(8):
            var c = BLUE if x >= 4 and y < 4 else RED
            src.set_pixel(x, y, c)

    var dst = Canvas(8, 8, WHITE)
    draw_canvas(
        dst, src, 4, 0, 4, 4, Matrix2D.identity(), filter=Filter.NEAREST
    )

    _assert_rgb(dst, 0, 0, BLUE, "the cropped quadrant lands at the origin")
    _assert_rgb(dst, 3, 3, BLUE, "...all of it")
    _assert_rgb(dst, 4, 0, WHITE, "nothing outside the crop is drawn")
    _assert_rgb(dst, 0, 4, WHITE, "below it either")


def test_source_rectangle_reaching_past_an_edge_draws_what_exists() raises:
    # A 4x4 rectangle whose right half is off the source: the two
    # columns that exist are drawn where they map, and the two that do
    # not are left alone.
    var src = Canvas(4, 4, RED)
    var dst = Canvas(8, 8, WHITE)
    draw_canvas(
        dst, src, 2, 0, 4, 4, Matrix2D.identity(), filter=Filter.NEAREST
    )
    _assert_rgb(dst, 0, 0, RED, "source column 2")
    _assert_rgb(dst, 1, 0, RED, "source column 3")
    _assert_rgb(dst, 2, 0, WHITE, "past the source's right edge")


def test_matrix_opacity_scales_alpha() raises:
    # An opaque source at opacity 0.5 lands at alpha
    # round(255 * 0.5) = 128, and keeps its colour.
    var src = Canvas(2, 2, RED)
    var dst = Canvas(8, 8, CLEAR)
    draw_canvas(
        dst, src, Matrix2D.scaling(2.0, 2.0), 0.5, filter=Filter.NEAREST
    )
    var p = dst.get_pixel(1, 1)
    assert_equal(p.a, 128, "opacity scales the source's alpha")
    assert_equal(p.r, 255, "over a transparent destination the colour stands")


def test_matrix_draw_respects_a_clip_rect() raises:
    var src = Canvas(4, 4, RED)
    var dst = Canvas(10, 10, WHITE)
    dst.push_clip(2, 2, 3, 3)
    draw_canvas(dst, src, Matrix2D.scaling(2.0, 2.0), filter=Filter.NEAREST)
    dst.pop_clip()
    _assert_rgb(dst, 3, 3, RED, "inside the clip")
    _assert_rgb(dst, 1, 1, WHITE, "outside the clip is untouched")
    _assert_rgb(dst, 6, 6, WHITE, "past the clip's far edge too")


def test_matrix_draw_respects_a_clip_path() raises:
    # A clip path is a per-pixel coverage mask rather than a range, so
    # the mapped loop has to route its writes through set_pixel, as the
    # blit does.
    var clip = Path()
    clip.move_to(0.0, 0.0)
    clip.line_to(5.0, 0.0)
    clip.line_to(5.0, 6.0)
    clip.line_to(0.0, 6.0)
    clip.close()

    var src = Canvas(4, 4, RED)
    var dst = Canvas(10, 6, WHITE)
    dst.push_clip_path(clip)
    draw_canvas(dst, src, Matrix2D.scaling(2.0, 2.0), filter=Filter.NEAREST)
    dst.pop_clip_path()

    _assert_rgb(dst, 2, 2, RED, "inside the clip path")
    _assert_rgb(dst, 7, 2, WHITE, "outside it is left alone")


def test_matrix_draw_applies_the_blend_mode() raises:
    # The mapped loop writes through write_pixel, so a mode set on the
    # canvas applies to it -- the same result the equivalent rectangle
    # fill produces.
    var src = Canvas(2, 2, Color(128, 128, 128))
    var dst = Canvas(4, 4, Color(200, 200, 200))
    dst.set_blend_mode(BlendMode.MULTIPLY)
    draw_canvas(dst, src, Matrix2D.scaling(2.0, 2.0), filter=Filter.NEAREST)
    dst.set_blend_mode(BlendMode.SOURCE_OVER)

    var reference = Canvas(4, 4, Color(200, 200, 200))
    reference.set_blend_mode(BlendMode.MULTIPLY)
    fill_rect(reference, 0, 0, 4, 4, Color(128, 128, 128))
    reference.set_blend_mode(BlendMode.SOURCE_OVER)

    _assert_same_bytes(reference, dst, "multiplied composite")


def test_matrix_composes_with_the_canvas_transform() raises:
    # The caller's matrix first, the canvas's transform second: a
    # scaled draw under a translated canvas is the scale followed by
    # the translation.
    var src = _varied_source(4, 4, 255)

    var under_state = Canvas(20, 16, WHITE)
    under_state.translate(6.0, 4.0)
    draw_canvas(
        under_state, src, Matrix2D.scaling(2.0, 2.0), filter=Filter.NEAREST
    )
    under_state.reset_transform()

    var composed = Canvas(20, 16, WHITE)
    draw_canvas(
        composed,
        src,
        Matrix2D.scaling(2.0, 2.0).then(Matrix2D.translation(6.0, 4.0)),
        filter=Filter.NEAREST,
    )
    _assert_same_bytes(composed, under_state, "matrix under a canvas frame")


def test_singular_matrix_raises() raises:
    var src = Canvas(4, 4, RED)
    var dst = Canvas(8, 8, WHITE)
    with assert_raises(contains="singular"):
        draw_canvas(dst, src, Matrix2D.scaling(0.0, 1.0))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
