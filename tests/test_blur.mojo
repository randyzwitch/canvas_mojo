"""Tests for blur.mojo: blur()'s three-box Gaussian approximation and
draw_shadowed(), the drop-shadow/glow composite built on it.

Most cases below check a structural property (symmetry, conservation,
flatness away from an edge, exact colour with no bleed) rather than a
hand-traced pixel value, since deriving a box-blurred pixel by hand
across three passes is impractical -- see the file docstring's own
reasoning for why `test_golden.mojo` is the one place a per-pixel trace
isn't the standard. Where an exact value *is* tractable (radius 0, the
edge clamp on a tiny array, an opaque flat interior, a lone opaque
pixel with nothing else to blend against, a blend-mode composite over
an opaque background) the test asserts it exactly.
"""

from std.testing import assert_equal, assert_true, TestSuite

from canvas.blend import BlendMode
from canvas.blur import blur, draw_shadowed, _box_blur_line, _clamp_index
from canvas.buffer import Canvas
from canvas.color import Color
from canvas.shapes.rects import fill_rect

comptime WHITE = Color(255, 255, 255)
comptime BLUE = Color(0, 0, 255)
comptime BLACK_OPAQUE = Color(0, 0, 0, 255)


def test_radius_zero_is_a_noop() raises:
    # A few different colours and alphas, so a stray write anywhere
    # would show up.
    var c = Canvas(6, 6, Color(0, 0, 0, 0))
    c.set_pixel(1, 1, Color(255, 0, 0, 255))
    c.set_pixel(2, 3, Color(0, 200, 30, 128))
    c.set_pixel(4, 4, Color(10, 20, 30, 40))
    fill_rect(c, 0, 0, 6, 2, WHITE)

    var before = List[Color]()
    for y in range(6):
        for x in range(6):
            before.append(c.get_pixel(x, y))

    blur(c, 0.0)
    blur(c, -5.0)

    var i = 0
    for y in range(6):
        for x in range(6):
            var p = c.get_pixel(x, y)
            assert_equal(p.r, before[i].r, "radius<=0 must not touch r")
            assert_equal(p.g, before[i].g, "radius<=0 must not touch g")
            assert_equal(p.b, before[i].b, "radius<=0 must not touch b")
            assert_equal(p.a, before[i].a, "radius<=0 must not touch a")
            i += 1


def test_single_pixel_spreads_symmetrically_and_conserves_alpha() raises:
    # A single opaque pixel, alone on a 41x41 transparent canvas, blurred
    # with radius=8 (so the three approximating box radii sum to well
    # under 20 -- see blur.mojo's _box_radii for the derivation; a
    # margin of 20 on every side is generous enough that the edge clamp
    # never engages and the two properties below hold in the ideal,
    # unclamped case:
    #
    # - Separability: each of the three passes applies the *same* box
    #   radius horizontally and vertically, so the combined 2D kernel
    #   is a product of two identical 1-D kernels, and is therefore
    #   symmetric under negating dx, negating dy, or swapping the two.
    # - Conservation: a normalized box average, applied where the
    #   window never needs clamping, redistributes mass without
    #   creating or destroying it -- the sum over the whole canvas
    #   should still be 255 once the three passes are done, save for
    #   whatever the final float-to-byte rounding perturbs it by.
    var w = 41
    var cx = 20
    var cy = 20
    var c = Canvas(w, w, Color(0, 0, 0, 0))
    c.set_pixel(cx, cy, Color(255, 255, 255, 255))

    blur(c, 8.0)

    for d in [1, 3, 5, 8, 10]:
        var right = Int(c.get_pixel(cx + d, cy).a)
        var left = Int(c.get_pixel(cx - d, cy).a)
        var down = Int(c.get_pixel(cx, cy + d).a)
        var up = Int(c.get_pixel(cx, cy - d).a)
        assert_equal(right, left, "horizontal profile must be symmetric")
        assert_equal(down, up, "vertical profile must be symmetric")
        assert_equal(right, down, "x and y profiles must match")

    var total = 0
    for y in range(w):
        for x in range(w):
            total += Int(c.get_pixel(x, y).a)
    # Independent per-pixel rounding over the blurred footprint (on the
    # order of (2*10+1)^2 pixels) can drift the integer total from the
    # ideal 255 by a small amount without any bug being involved; 24 is
    # a generous bound; a real defect (e.g. energy leaking off one
    # side) misses by far more than that.
    assert_true(
        abs(total - 255) <= 24,
        "total alpha must be conserved within rounding, got " + String(total),
    )


def test_opaque_flat_region_stays_flat_away_from_its_edges() raises:
    # A 21x21 opaque block on an opaque white background, blurred with
    # a small radius (box radii summing to 3 -- see blur.mojo). Ten
    # pixels of margin from the block's own boundary is well clear of
    # that reach, so the block's centre must come out exactly the
    # colour it was: an opaque flat neighbourhood premultiplies,
    # box-averages, and unpremultiplies back to itself exactly, with no
    # floating-point rounding involved (every value along the way is an
    # integer representable exactly in Float64).
    var c = Canvas(41, 41, WHITE)
    var block = Color(30, 60, 90)
    fill_rect(c, 10, 10, 21, 21, block)

    blur(c, 3.0)

    var p = c.get_pixel(20, 20)
    assert_equal(p.r, block.r, "flat interior red")
    assert_equal(p.g, block.g, "flat interior green")
    assert_equal(p.b, block.b, "flat interior blue")
    assert_equal(p.a, 255, "flat interior stays opaque")


def test_transparent_neighbor_does_not_tint_the_blurred_color() raises:
    # The background is transparent *white* -- (255, 255, 255, 0) --
    # specifically so a blur that averaged straight (non-premultiplied)
    # colour would pull every touched pixel toward pink. A single
    # opaque red pixel's premultiplied colour is (255, 0, 0), which is
    # numerically identical to its own alpha (255) in the red channel
    # and zero in the others; the transparent background premultiplies
    # to (0, 0, 0) everywhere regardless of its stored white. Blurring
    # a plane that is already identical to the alpha plane produces an
    # identical result (the same sliding-window arithmetic run on the
    # same numbers), so the unpremultiplied red channel divides out to
    # exactly 255, and green/blue -- blurred from all zeros -- stay
    # exactly 0, at every pixel the blur reaches.
    var w = 21
    var cx = 10
    var cy = 10
    var c = Canvas(w, w, Color(255, 255, 255, 0))
    c.set_pixel(cx, cy, Color(255, 0, 0, 255))

    blur(c, 6.0)

    var touched = 0
    for y in range(w):
        for x in range(w):
            var p = c.get_pixel(x, y)
            if p.a > 0:
                touched += 1
                assert_equal(p.r, 255, "red channel must stay saturated")
                assert_equal(p.g, 0, "green must not pick up the bleed")
                assert_equal(p.b, 0, "blue must not pick up the bleed")
    assert_true(touched > 1, "the blur must have spread past the one pixel")


def test_box_blur_line_clamps_at_the_edge() raises:
    # _box_blur_line directly, on a 5-sample line with all the mass at
    # index 0 and a window radius of 2 (width 5). Edge clamp means an
    # out-of-range index repeats the nearest in-range one, so the
    # window for output x is the five (possibly repeated) samples
    # nearest x, clamped into [0, 4]:
    #   x=0: window indices -2,-1,0,1,2 -> clamped 0,0,0,1,2
    #        -> values 10,10,10,0,0 -> sum 30 -> 30/5 = 6.0
    #   x=1: window -1..3 -> clamped 0,0,1,2,3 -> 10,10,0,0,0 -> 20/5 = 4.0
    #   x=2: window 0..4 -> 0,1,2,3,4 (no clamping needed) -> 10,0,0,0,0
    #        -> 10/5 = 2.0
    #   x=3: window 1..5 -> clamped 1,2,3,4,4 -> 0,0,0,0,0 -> 0.0
    #   x=4: window 2..6 -> clamped 2,3,4,4,4 -> 0,0,0,0,0 -> 0.0
    var src: List[Float64] = [10.0, 0.0, 0.0, 0.0, 0.0]
    var dst: List[Float64] = [0.0, 0.0, 0.0, 0.0, 0.0]
    _box_blur_line(src, dst, 0, 1, 5, 2)

    assert_equal(
        dst[0], 6.0, "x=0 clamps three copies of index 0 into its window"
    )
    assert_equal(dst[1], 4.0, "x=1 clamps two copies of index 0")
    assert_equal(dst[2], 2.0, "x=2 needs no clamping")
    assert_equal(dst[3], 0.0, "x=3's window no longer reaches the source")
    assert_equal(dst[4], 0.0, "x=4's window clamps the far (empty) edge")


def test_clamp_index_helper() raises:
    assert_equal(_clamp_index(-3, 5), 0, "negative index clamps to 0")
    assert_equal(_clamp_index(0, 5), 0, "in range at the low edge")
    assert_equal(_clamp_index(2, 5), 2, "in range stays put")
    assert_equal(_clamp_index(4, 5), 4, "in range at the high edge")
    assert_equal(_clamp_index(7, 5), 4, "past the end clamps to count - 1")


def test_draw_shadowed_places_a_softened_offset_copy_under_the_shape() raises:
    # A 10x10 opaque blue block in a 20x20 transparent layer, placed at
    # (15, 15) on a 50x50 white canvas -- so the shape occupies
    # dst [20, 30) x [20, 30). An opaque black shadow, blur radius 3.0
    # (box radii summing to 3 -- see blur.mojo), offset by (6, 6) puts
    # the shadow's own *unblurred* footprint at [26, 36) x [26, 36).
    #
    # (31, 31) sits inside that footprint, at least 5 pixels from every
    # one of its edges -- clear of the blur's reach (3) -- and outside
    # the shape's footprint, so it is shadow only: by the same
    # flat-interior reasoning as the block test above, it must come out
    # exactly opaque black.
    #
    # (25, 25) is deep inside the shape's own footprint, so the opaque
    # shape drawn on top must leave it exactly blue, whatever the
    # shadow underneath drew there.
    #
    # (36, 31) sits exactly on the shadow's original, unblurred right
    # edge -- outside the shape -- so the blur must have softened it to
    # something between white and black rather than a hard cut.
    var layer = Canvas(20, 20, Color(0, 0, 0, 0))
    fill_rect(layer, 5, 5, 10, 10, BLUE)

    var dst = Canvas(50, 50, WHITE)
    draw_shadowed(dst, layer, 15, 15, BLACK_OPAQUE, 3.0, 6, 6)

    var shadow_only = dst.get_pixel(31, 31)
    assert_equal(shadow_only.r, 0, "deep shadow interior is opaque black (r)")
    assert_equal(shadow_only.g, 0, "deep shadow interior is opaque black (g)")
    assert_equal(shadow_only.b, 0, "deep shadow interior is opaque black (b)")
    assert_equal(shadow_only.a, 255, "deep shadow interior is opaque")

    var shape_pixel = dst.get_pixel(25, 25)
    assert_equal(shape_pixel.r, BLUE.r, "the shape itself is unchanged (r)")
    assert_equal(shape_pixel.g, BLUE.g, "the shape itself is unchanged (g)")
    assert_equal(shape_pixel.b, BLUE.b, "the shape itself is unchanged (b)")

    var soft_edge = dst.get_pixel(36, 31)
    assert_true(
        soft_edge.r > 20 and soft_edge.r < 235,
        "the shadow's edge must be softened, not a hard cut: got "
        + String(soft_edge.r),
    )

    var untouched = dst.get_pixel(2, 2)
    assert_equal(untouched.r, 255, "background well away from the scene")


def test_draw_shadowed_respects_the_active_clip() raises:
    var layer = Canvas(20, 20, Color(0, 0, 0, 0))
    fill_rect(layer, 5, 5, 10, 10, BLUE)

    var dst = Canvas(50, 50, WHITE)
    # A clip that excludes the whole scene (shape and shadow alike):
    # nothing draw_shadowed does should escape it.
    dst.push_clip(0, 0, 10, 10)
    draw_shadowed(dst, layer, 15, 15, BLACK_OPAQUE, 3.0, 6, 6)
    dst.pop_clip()

    var shadow_only = dst.get_pixel(31, 31)
    assert_equal(shadow_only.r, 255, "shadow outside the clip must not draw")
    var shape_pixel = dst.get_pixel(25, 25)
    assert_equal(shape_pixel.r, 255, "shape outside the clip must not draw")


def test_draw_shadowed_applies_the_blend_mode() raises:
    # Same geometry as the basic draw_shadowed test, over an opaque
    # (200, 100, 50) background instead of white, with the shadow
    # colour an opaque mid grey (128, 128, 128) and MULTIPLY active.
    #
    # For an opaque source over an opaque background, MULTIPLY reduces
    # to _div255(bg_channel * src_channel) exactly (see blend.mojo's
    # _blend_pixel: an opaque source makes the backdrop's own weight
    # zero regardless of the mode, so the general formula collapses to
    # the plain per-channel product). At (31, 31), the deep shadow
    # interior is exactly opaque (128, 128, 128) before compositing (by
    # the same flat-interior reasoning used elsewhere in this file), so
    # the composited channel is:
    #   r: _div255(200 * 128) = _div255(25600) = 100
    #   g: _div255(100 * 128) = _div255(12800) = 50
    #   b: _div255(50  * 128) = _div255(6400)  = 25
    var layer = Canvas(20, 20, Color(0, 0, 0, 0))
    fill_rect(layer, 5, 5, 10, 10, BLUE)

    var bg = Color(200, 100, 50)
    var dst = Canvas(50, 50, bg)
    dst.set_blend_mode(BlendMode.MULTIPLY)
    draw_shadowed(dst, layer, 15, 15, Color(128, 128, 128, 255), 3.0, 6, 6)
    dst.set_blend_mode(BlendMode.SOURCE_OVER)

    var p = dst.get_pixel(31, 31)
    assert_equal(p.r, 100, "multiplied red")
    assert_equal(p.g, 50, "multiplied green")
    assert_equal(p.b, 25, "multiplied blue")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
