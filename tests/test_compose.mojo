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
neighbors.
"""

from std.math import floor, pi
from std.testing import assert_equal, assert_raises, assert_true, TestSuite

from canvas.blend import BlendMode
from canvas.buffer import Canvas
from canvas.color import Color
from canvas.color import _div255
from canvas.compose import Filter, draw_canvas, draw_image
from canvas.geometry import Matrix2D
from canvas.mask import Mask
from canvas.path import Path
from canvas.resize import downsample
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
    # produce drawing that color directly, which is the point -- a
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
    """A source with a different color in every pixel, so a blit and a
    mapped draw are compared on real data rather than one flat color.
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


def _expected_over_opaque(
    src: Color, dst: Color, coverage: Int, opacity: Int
) -> Color:
    """Source-over onto an opaque destination, written out from the
    specification rather than from the code under test.

    The alpha is scaled by coverage and then by opacity, each through
    the same `_div255`, in that order -- the vector path folds both
    into one multiply-add and must land on the same bytes.
    """
    var a = _div255(Int(src.a) * coverage)
    a = _div255(a * opacity)
    var inv = 255 - a
    return Color(
        UInt8(_div255(Int(src.r) * a + Int(dst.r) * inv)),
        UInt8(_div255(Int(src.g) * a + Int(dst.g) * inv)),
        UInt8(_div255(Int(src.b) * a + Int(dst.b) * inv)),
        255,
    )


def test_masked_and_scaled_compositing_matches_the_specification() raises:
    """The vector path folds coverage and opacity into the alpha before
    blending. Checked against the arithmetic spelled out above, over a
    width that is not a multiple of the eight-pixel group so the tail
    is covered too.
    """
    comptime W = 61
    comptime H = 9
    var opacities: List[Int] = [0, 1, 128, 254, 255]
    for oi in range(len(opacities)):
        var op = opacities[oi]
        var src = _varied_source(W, H, 137)
        var mask = Mask(W, H)
        var mp = mask.coverage.unsafe_ptr()
        for i in range(W * H):
            mp[unsafe_offset=i] = UInt8((i * 37) & 0xFF)

        # Mask and opacity together.
        var got = Canvas(W, H, WHITE)
        draw_canvas(got, src, 0, 0, mask)
        for y in range(H):
            for x in range(W):
                var want = _expected_over_opaque(
                    src.get_pixel(x, y),
                    WHITE,
                    Int(mask.coverage[y * W + x]),
                    255,
                )
                var p = got.get_pixel(x, y)
                var at = String("mask at (", x, ", ", y, ")")
                assert_equal(p.r, want.r, at + " r")
                assert_equal(p.g, want.g, at + " g")
                assert_equal(p.b, want.b, at + " b")
                assert_equal(p.a, want.a, at + " a")

        # Opacity on its own.
        var go = Canvas(W, H, WHITE)
        draw_canvas(go, src, 0, 0, UInt8(op))
        for y in range(H):
            for x in range(W):
                var want = _expected_over_opaque(
                    src.get_pixel(x, y), WHITE, 255, op
                )
                var p = go.get_pixel(x, y)
                var at = String("opacity ", op, " at (", x, ", ", y, ")")
                assert_equal(p.r, want.r, at + " r")
                assert_equal(p.g, want.g, at + " g")
                assert_equal(p.b, want.b, at + " b")


def test_a_group_over_mixed_destination_alpha_falls_back() raises:
    """The vector kernel only runs where all eight destination pixels
    are opaque. A row that turns translucent partway must still come
    out identical to the same draw done one pixel at a time -- which
    here is the same draw onto a destination made opaque a pixel at a
    time, compared against a canvas built with a translucent hole.
    """
    comptime W = 24
    comptime H = 4
    var src = _varied_source(W, H, 200)

    var mixed = Canvas(W, H, WHITE)
    # A translucent pixel inside the second group of eight.
    mixed.set_pixel(9, 1, Color(60, 70, 80, 100))
    var before = mixed.get_pixel(9, 1)

    var drawn = Canvas(W, H, WHITE)
    drawn.set_pixel(9, 1, before)
    draw_canvas(drawn, src, 0, 0, 200)

    # Every pixel whose destination was opaque must match the
    # specification; the one that was not is left to the exact path
    # and only has to stay put as a valid blend, not equal it.
    for y in range(H):
        for x in range(W):
            if x == 9 and y == 1:
                continue
            var want = _expected_over_opaque(
                src.get_pixel(x, y), WHITE, 255, 200
            )
            var p = drawn.get_pixel(x, y)
            var at = String("mixed dst at (", x, ", ", y, ")")
            assert_equal(p.r, want.r, at + " r")
            assert_equal(p.g, want.g, at + " g")
            assert_equal(p.b, want.b, at + " b")
    assert_true(
        drawn.get_pixel(9, 1).a >= before.a,
        "compositing over a translucent pixel raises its alpha",
    )


def test_opacity_and_mask_agree_with_a_pre_scaled_mask() raises:
    """Opacity 128 with full coverage, and coverage 128 with full
    opacity, scale the same alpha by the same factor in the same
    order, so they must produce the same bytes.
    """
    comptime W = 33
    comptime H = 5
    var src = _varied_source(W, H, 255)

    var by_opacity = Canvas(W, H, WHITE)
    draw_canvas(by_opacity, src, 0, 0, 128)

    var flat = Mask(W, H)
    var fp = flat.coverage.unsafe_ptr()
    for i in range(W * H):
        fp[unsafe_offset=i] = 128
    var by_mask = Canvas(W, H, WHITE)
    draw_canvas(by_mask, src, 0, 0, flat)

    _assert_same_bytes(by_opacity, by_mask, "opacity 128 vs coverage 128")


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
    # A quarter turn about the center of a 4x4 source, which is the
    # texel-space point (2, 2). Positive angles turn +x toward +y,
    # clockwise on a y-down canvas, so the top-right pixel ends up
    # bottom-right and the bottom-left pixel ends up top-left.
    #
    # Pixel (3, 0) has its center at (3.5, 0.5); relative to the center
    # that is (1.5, -1.5), which the quarter turn takes to (1.5, 1.5),
    # so it lands on (3.5, 3.5) -- destination pixel (3, 3). Pixel
    # (0, 3), center (0.5, 3.5), goes from (-1.5, 1.5) to (-1.5, -1.5)
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
    # its center at px + 0.5 and samples u = px, whose two horizontal
    # neighbors are the pixels centered at px - 0.5 and px + 0.5 --
    # source columns px - 1 and px, each weighted 0.5. Vertically the
    # sample lands exactly on a pixel center, so the row is untouched.
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
    # pixel's center: the missing neighbor is column 0 itself, so the
    # edge column comes through undiluted.
    assert_equal(dst.get_pixel(0, 1).r, 0, "the edge pixel is clamped")
    # u = 4 is the source's right edge, which is outside it.
    _assert_rgb(dst, 4, 1, WHITE, "past the source's right edge")


def test_bilinear_does_not_bleed_a_transparent_neighbour() raises:
    # Opaque red beside fully transparent green, sampled halfway
    # between them. Weighting premultiplied gives alpha
    # 0.5 * 255 + 0.5 * 0 = 127.5, rounding to 128, and color
    # (0.5 * 255 * 255) / 127.5 = 255 red with no green at all.
    # Averaging straight color instead would put 128 green in it.
    var src = Canvas(2, 1, CLEAR)
    src.set_pixel(0, 0, Color(255, 0, 0, 255))
    src.set_pixel(1, 0, Color(0, 255, 0, 0))

    var dst = Canvas(4, 2, CLEAR)
    draw_canvas(dst, src, Matrix2D.translation(0.5, 0.0))

    var p = dst.get_pixel(1, 0)
    assert_equal(p.a, 128, "alpha is the interpolated alpha")
    assert_equal(p.r, 255, "the opaque neighbor's red survives whole")
    assert_equal(p.g, 0, "the transparent neighbor contributes no color")


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
    # round(255 * 0.5) = 128, and keeps its color.
    var src = Canvas(2, 2, RED)
    var dst = Canvas(8, 8, CLEAR)
    draw_canvas(
        dst, src, Matrix2D.scaling(2.0, 2.0), 0.5, filter=Filter.NEAREST
    )
    var p = dst.get_pixel(1, 1)
    assert_equal(p.a, 128, "opacity scales the source's alpha")
    assert_equal(p.r, 255, "over a transparent destination the color stands")


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


def _reference_blit(
    dst_w: Int, dst_h: Int, bg: Color, src: Canvas, ox: Int, oy: Int
) raises -> Canvas:
    """`draw_canvas` computed the slow way, one `set_pixel` per source
    pixel, for the wide classification path to be checked against.
    """
    var out = Canvas(dst_w, dst_h, bg)
    for sy in range(src.height):
        for sx in range(src.width):
            out.set_pixel(ox + sx, oy + sy, src.get_pixel(sx, sy))
    return out^


def _assert_same(a: Canvas, b: Canvas, what: String) raises:
    for i in range(len(a.pixels)):
        if a.pixels[i] != b.pixels[i]:
            raise Error(
                what
                + ": byte "
                + String(i)
                + " (pixel "
                + String(i // 4)
                + ", channel "
                + String(i % 4)
                + "): got "
                + String(a.pixels[i])
                + ", want "
                + String(b.pixels[i])
            )


def test_one_translucent_pixel_anywhere_in_a_wide_block() raises:
    # The compositor classifies 32 pixels with a single reduction and
    # copies all of them when every alpha is 255. A single pixel that is
    # not opaque has to break that, wherever it sits, so this walks one
    # such pixel across every column of a row wider than the block and
    # compares every byte against a per-pixel reference.
    var widths: List[Int] = [31, 32, 33, 64, 65, 97]
    var alphas: List[UInt8] = [0, 1, 127, 254]
    for wi in range(len(widths)):
        var w = widths[wi]
        for ai in range(len(alphas)):
            var a = alphas[ai]
            for bad in range(w):
                var src = Canvas(w, 3, Color(200, 100, 50, 255))
                src.set_pixel(bad, 1, Color(10, 220, 90, a))
                var dst = Canvas(w + 8, 5, Color(30, 60, 90))
                draw_canvas(dst, src, 4, 1)
                var want = _reference_blit(
                    w + 8, 5, Color(30, 60, 90), src, 4, 1
                )
                _assert_same(
                    dst,
                    want,
                    "w="
                    + String(w)
                    + " alpha="
                    + String(a)
                    + " at col "
                    + String(bad),
                )


def _pattern(kind: Int, w: Int, h: Int) raises -> Canvas:
    """One of the alpha layouts #351 asks to be compared: 0 fully
    opaque, 1 alternating, 2 sparse, 3 transparent border, 4 fully
    transparent.
    """
    if kind == 4:
        return Canvas(w, h, Color(200, 100, 50, 0))
    var c = Canvas(w, h, Color(200, 100, 50, 255))
    if kind == 1:
        for y in range(h):
            for x in range(0, w, 2):
                c.set_pixel(x, y, Color(10, 220, 90, 128))
    elif kind == 2:
        for y in range(h):
            c.set_pixel((y * 37) % w, y, Color(10, 220, 90, 7))
    elif kind == 3:
        for x in range(w):
            c.set_pixel(x, 0, Color(0, 0, 0, 0))
            c.set_pixel(x, h - 1, Color(0, 0, 0, 0))
        for y in range(h):
            c.set_pixel(0, y, Color(0, 0, 0, 0))
            c.set_pixel(w - 1, y, Color(0, 0, 0, 0))
    return c^


def test_alpha_patterns_across_the_wide_block() raises:
    # The four patterns #351 asks for, plus fully transparent. Each has
    # to reproduce the per-pixel reference byte for byte, at offsets
    # that put the wide block in and out of phase with the source.
    var w = 100
    var h = 6
    var names: List[String] = [
        "opaque",
        "alternating",
        "sparse",
        "border",
        "transparent",
    ]
    for kind in range(5):
        for oi in range(3):
            var ox = -3 + oi * 4
            var src = _pattern(kind, w, h)
            var dst = Canvas(w + 10, h + 4, Color(30, 60, 90))
            draw_canvas(dst, src, ox, 2)
            var want = _reference_blit(
                w + 10, h + 4, Color(30, 60, 90), src, ox, 2
            )
            _assert_same(dst, want, names[kind] + " at offset " + String(ox))


def test_wide_block_under_a_clip_rect() raises:
    # A clip narrows the run the compositor walks, so the wide block can
    # start mid-source and end mid-block.
    var src = Canvas(97, 5, Color(200, 100, 50, 255))
    src.set_pixel(40, 2, Color(10, 220, 90, 100))
    for ci in range(4):
        var cx = 3 + ci * 7
        var dst = Canvas(110, 9, Color(30, 60, 90))
        dst.push_clip(cx, 1, 61, 6)
        draw_canvas(dst, src, 5, 2)
        dst.pop_clip()

        var want = Canvas(110, 9, Color(30, 60, 90))
        want.push_clip(cx, 1, 61, 6)
        for sy in range(src.height):
            for sx in range(src.width):
                want.set_pixel(5 + sx, 2 + sy, src.get_pixel(sx, sy))
        want.pop_clip()
        _assert_same(dst, want, "clip at x=" + String(cx))


def test_draw_image_at_its_pixel_size_is_the_blit() raises:
    # Geometric (3.5, 4.5) is the top-left corner of pixel (4, 5),
    # where fill_rect(3.5, 4.5, ...) starts as well; the image's own
    # size, given or defaulted, puts one cell on each pixel.
    for alpha in [UInt8(255), UInt8(96)]:
        var src = _varied_source(6, 5, alpha)
        var placed = Canvas(12, 10, WHITE)
        placed.draw_image(src, 3.5, 4.5)
        var sized = Canvas(12, 10, WHITE)
        draw_image(sized, src, 3.5, 4.5, 6.0, 5.0)
        var blit = Canvas(12, 10, WHITE)
        draw_canvas(blit, src, 4, 5)
        _assert_same_bytes(blit, placed, "the image's own size")
        _assert_same_bytes(blit, sized, "the same size given explicitly")


def _fill_rect_per_cell(
    mut dst: Canvas,
    src: Canvas,
    x: Float64,
    y: Float64,
    w: Float64,
    h: Float64,
) raises:
    """The block as a chart draws it without an image primitive: one
    fill_rect per cell at the cell's geometric box.
    """
    var n = src.width
    var m = src.height
    for j in range(m):
        for i in range(n):
            var x0 = x + w * Float64(i) / Float64(n)
            var x1 = x + w * Float64(i + 1) / Float64(n)
            var y0 = y + h * Float64(j) / Float64(m)
            var y1 = y + h * Float64(j + 1) / Float64(m)
            fill_rect(dst, x0, y0, x1 - x0, y1 - y0, src.get_pixel(i, j))


def _frame(mut c: Canvas, variant: Int):
    """Four axis-aligned frames a block can be drawn under: none, a
    scale that runs the block off the canvas, a mirrored scale, and a
    scale inside a clip rectangle.
    """
    if variant == 1:
        c.translate(1.2, -0.4)
        c.scale(2.5, 1.7)
    elif variant == 2:
        c.translate(58.0, 0.0)
        c.scale(-1.3, 1.9)
    elif variant == 3:
        c.push_clip(15, 10, 20, 12)
        c.scale(1.4, 1.2)


def test_draw_image_covers_the_pixels_a_fill_rect_per_cell_would() raises:
    for variant in range(4):
        for alpha in [UInt8(255), UInt8(160)]:
            var src = _varied_source(7, 5, alpha)
            var by_image = Canvas(60, 40, WHITE)
            var by_rects = Canvas(60, 40, WHITE)
            _frame(by_image, variant)
            _frame(by_rects, variant)
            by_image.draw_image(src, 10.3, 7.7, 33.0, 19.5)
            _fill_rect_per_cell(by_rects, src, 10.3, 7.7, 33.0, 19.5)
            _assert_same_bytes(
                by_rects,
                by_image,
                "frame " + String(variant) + " alpha " + String(alpha),
            )


def test_draw_image_under_supersampling_matches_the_fill_rect_recipe() raises:
    # The recipe on `downsample`: draw at f times the size, shifted by
    # (f - 1) / 2, then downsample. Every cell edge of a block at
    # integer coordinates then lands on a pixel center, the tie both
    # snaps must break the same way.
    var src = Canvas(2, 2, RED)
    src.set_pixel(1, 0, BLUE)
    src.set_pixel(0, 1, Color(0, 200, 0, 128))
    for f in [1, 3]:
        var by_image = Canvas(40 * f, 30 * f, WHITE)
        var by_rects = Canvas(40 * f, 30 * f, WHITE)
        var shift = Float64(f - 1) / 2.0
        by_image.translate(shift, shift)
        by_image.scale(Float64(f), Float64(f))
        by_rects.translate(shift, shift)
        by_rects.scale(Float64(f), Float64(f))
        by_image.draw_image(src, 4.0, 5.0, 20.0, 10.0)
        _fill_rect_per_cell(by_rects, src, 4.0, 5.0, 20.0, 10.0)
        _assert_same_bytes(
            downsample(by_rects, f),
            downsample(by_image, f),
            "supersample factor " + String(f),
        )


def test_draw_image_under_a_rotation_takes_the_cell_under_each_center() raises:
    # Off the axis-aligned path the block goes through the sampler,
    # which reads pixel corners; the half-pixel shift in draw_image is
    # what puts it back on the shapes' convention. The oracle maps each
    # pixel's center (px, py) back into user space and picks the cell.
    var src = _varied_source(3, 2, 255)
    var dst = Canvas(50, 40, WHITE)
    dst.translate(30.2, 10.6)
    dst.rotate(pi / 2.0)
    dst.draw_image(src, 2.3, 1.1, 9.0, 6.0)
    var inv = dst.current_transform().inverse()
    var covered = 0
    for py in range(40):
        for px in range(50):
            var u = inv.apply(Float64(px), Float64(py))
            var expected = WHITE
            if u.x >= 2.3 and u.x < 11.3 and u.y >= 1.1 and u.y < 7.1:
                var i = Int(floor((u.x - 2.3) / 3.0))
                var j = Int(floor((u.y - 1.1) / 3.0))
                expected = src.get_pixel(i, j)
                covered += 1
            _assert_rgb(
                dst,
                px,
                py,
                expected,
                "pixel (" + String(px) + ", " + String(py) + ")",
            )
    assert_true(covered == 54, "a 9 x 6 block rotated covers 54 pixels")


def test_draw_image_draws_a_pending_batch_first() raises:
    var dst = Canvas(20, 20, WHITE)
    dst.begin_batch()
    dst.fill_circle_aa(10, 10, 8, RED)
    var block = Canvas(4, 4, BLUE)
    dst.draw_image(block, 7.5, 7.5)
    dst.end_batch()
    _assert_rgb(dst, 9, 9, BLUE, "the image lands over the disk recorded first")
    _assert_rgb(dst, 4, 10, RED, "the disk is still drawn")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
