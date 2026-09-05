"""Tests for mask.mojo: building a Mask from a path, an alpha channel
or a luminance, and painting, clipping and compositing through one.

The anchor property is that a mask built from a path and painted
through with `fill_mask` is pixel for pixel what `push_clip_path` plus
a fill produces: the same coverage, reached two ways. Everything else
checks a hand-derived value -- a uniform coverage scales alpha by
`(a * c) // 255`, nested masks multiply -- or a structural one, like
a blurred disk's mask giving a soft edge.
"""

from std.testing import assert_equal, assert_raises, assert_true, TestSuite

from canvas.blend import BlendMode
from canvas.blur import blur
from canvas.buffer import Canvas
from canvas.color import Color
from canvas.compose import draw_canvas
from canvas.fill_rule import FillRule
from canvas.gradient import LinearGradient
from canvas.mask import (
    Mask,
    apply_mask,
    fill_mask,
    fill_mask_source,
    push_clip_mask,
)
from canvas.path import Path
from canvas.shapes.circles import fill_circle_aa
from canvas.shapes.rects import fill_rect

comptime CLEAR = Color(0, 0, 0, 0)
comptime WHITE = Color(255, 255, 255)
comptime RED = Color(255, 0, 0)
comptime BLUE = Color(0, 0, 255)


def _assert_rgba(
    got: Color, r: Int, g: Int, b: Int, a: Int, msg: String
) raises:
    assert_equal(Int(got.r), r, msg + " (red)")
    assert_equal(Int(got.g), g, msg + " (green)")
    assert_equal(Int(got.b), b, msg + " (blue)")
    assert_equal(Int(got.a), a, msg + " (alpha)")


def _ellipse_path() raises -> Path:
    var p = Path()
    p.ellipse(20.0, 20.0, 12.0, 8.0)
    return p^


def test_mask_from_path_paints_what_the_clip_path_lets_through() raises:
    # The same coverage reached two ways: a mask painted through, and
    # a clip path drawn under. Every pixel, every channel, including
    # the anti-aliased edge.
    var path = _ellipse_path()
    var mask = Mask.from_path(path, 40, 40)

    var painted = Canvas(40, 40, CLEAR)
    fill_mask(painted, mask, BLUE)

    var clipped = Canvas(40, 40, CLEAR)
    clipped.push_clip_path(path)
    fill_rect(clipped, 0, 0, 40, 40, BLUE)

    for y in range(40):
        for x in range(40):
            var a = painted.get_pixel(x, y)
            var b = clipped.get_pixel(x, y)
            var at = " at " + String(x) + "," + String(y)
            assert_equal(a.r, b.r, "r" + at)
            assert_equal(a.g, b.g, "g" + at)
            assert_equal(a.b, b.b, "b" + at)
            assert_equal(a.a, b.a, "a" + at)
    # And the mask is a real stencil: the center is fully covered, a
    # corner not at all, and the boundary is in between.
    assert_equal(mask.coverage_at(20, 20), 255)
    assert_equal(mask.coverage_at(0, 0), 0)
    var edge = Int(mask.coverage_at(32, 20))
    assert_true(edge > 0 and edge < 255, "soft edge: " + String(edge))


def test_mask_from_path_honours_the_fill_rule() raises:
    # Two same-direction squares overlapping: the overlap is a hole
    # under even-odd and solid under nonzero.
    var p = Path()
    p.rect(0.0, 0.0, 20.0, 20.0)
    p.rect(10.0, 10.0, 20.0, 20.0)
    var even_odd = Mask.from_path(p, 30, 30, FillRule.EVEN_ODD)
    var nonzero = Mask.from_path(p, 30, 30, FillRule.NONZERO)
    assert_equal(even_odd.coverage_at(15, 15), 0, "even-odd hole")
    assert_equal(nonzero.coverage_at(15, 15), 255, "nonzero solid")
    assert_equal(even_odd.coverage_at(5, 5), 255)
    assert_equal(nonzero.coverage_at(25, 25), 255)


def test_fill_mask_scales_the_alpha_by_the_coverage() raises:
    # Coverage 128 on an opaque color: alpha (255 * 128) // 255 = 128.
    var c = Canvas(4, 4, CLEAR)
    fill_mask(c, Mask(4, 4, 128), RED)
    _assert_rgba(c.get_pixel(1, 1), 255, 0, 0, 128, "half coverage")
    # It compounds with the color's own alpha: (128 * 128) // 255 = 64.
    var d = Canvas(4, 4, CLEAR)
    fill_mask(d, Mask(4, 4, 128), RED.with_alpha(128))
    _assert_rgba(d.get_pixel(1, 1), 255, 0, 0, 64, "half of half")
    # Zero coverage leaves the pixel alone; full coverage is the plain
    # color.
    var e = Canvas(4, 4, WHITE)
    fill_mask(e, Mask(4, 4, 0), RED)
    _assert_rgba(e.get_pixel(1, 1), 255, 255, 255, 255, "untouched")
    fill_mask(e, Mask(4, 4, 255), RED)
    _assert_rgba(e.get_pixel(1, 1), 255, 0, 0, 255, "opaque through")


def test_fill_mask_at_an_offset_and_off_the_canvas() raises:
    var c = Canvas(20, 20, CLEAR)
    fill_mask(c, Mask(4, 4, 255), RED, 10, 10)
    assert_equal(c.get_pixel(10, 10).a, 255, "top-left of the mask")
    assert_equal(c.get_pixel(13, 13).a, 255, "bottom-right of the mask")
    assert_equal(c.get_pixel(9, 9).a, 0, "just outside")
    assert_equal(c.get_pixel(14, 14).a, 0, "just outside")
    assert_equal(c.get_pixel(10, 14).a, 0, "one row below")
    # Hanging off the top-left edge: the visible part draws, the rest
    # is skipped rather than wrapping or raising.
    fill_mask(c, Mask(4, 4, 255), BLUE, -2, -2)
    assert_equal(c.get_pixel(0, 0).b, 255)
    assert_equal(c.get_pixel(1, 1).b, 255)
    assert_equal(c.get_pixel(2, 2).b, 0)
    assert_equal(c.get_pixel(19, 0).a, 0)
    # And off the bottom-right edge.
    fill_mask(c, Mask(4, 4, 255), BLUE, 18, 18)
    assert_equal(c.get_pixel(19, 19).b, 255)
    assert_equal(c.get_pixel(17, 17).b, 0)


def test_fill_mask_source_takes_the_colour_from_the_source() raises:
    # A black-to-white gradient across x 0..9, queried per pixel; the
    # mask only gates alpha.
    var g = LinearGradient(0.0, 0.0, 9.0, 0.0)
    g.add_stop(0.0, Color(0, 0, 0))
    g.add_stop(1.0, Color(255, 255, 255))
    var c = Canvas(10, 1, CLEAR)
    fill_mask_source(c, Mask(10, 1, 255), g)
    for x in range(10):
        var want = g.color_at(Float64(x), 0.0)
        var got = c.get_pixel(x, 0)
        assert_equal(got.r, want.r, "column " + String(x))
        assert_equal(got.a, 255)
    var half = Canvas(10, 1, CLEAR)
    fill_mask_source(half, Mask(10, 1, 128), g)
    assert_equal(half.get_pixel(9, 0).r, 255, "color kept")
    assert_equal(half.get_pixel(9, 0).a, 128, "alpha halved")


def test_fill_mask_respects_the_clip_and_the_blend_mode() raises:
    var c = Canvas(10, 10, WHITE)
    c.push_clip(0, 0, 5, 5)
    fill_mask(c, Mask(10, 10, 255), RED)
    c.pop_clip()
    _assert_rgba(c.get_pixel(2, 2), 255, 0, 0, 255, "inside the clip")
    _assert_rgba(c.get_pixel(7, 7), 255, 255, 255, 255, "outside it")
    # MULTIPLY over white is the source color itself, since B(1, Cs)
    # = Cs; over red the green and blue channels go to zero.
    c.set_blend_mode(BlendMode.MULTIPLY)
    fill_mask(c, Mask(10, 10, 255), Color(128, 255, 0))
    _assert_rgba(c.get_pixel(7, 7), 128, 255, 0, 255, "multiply over white")
    _assert_rgba(c.get_pixel(2, 2), 128, 0, 0, 255, "multiply over red")


def test_mask_from_alpha_and_from_luminance() raises:
    var c = Canvas(3, 2, CLEAR)
    c.set_pixel(0, 0, Color(255, 255, 255, 255))  # opaque white
    c.set_pixel(1, 0, Color(0, 0, 0, 255))  # opaque black
    c.set_pixel(2, 0, Color(255, 255, 255, 0))  # transparent white
    c.set_pixel(0, 1, Color(100, 100, 100, 255))  # mid gray
    c.set_pixel(1, 1, Color(255, 0, 0, 255))  # pure red
    # A half-transparent white: set_pixel blends it over the
    # transparent backdrop, which keeps the color and the alpha.
    c.set_pixel(2, 1, Color(255, 255, 255, 128))

    var alpha = Mask.from_alpha(c)
    assert_equal(alpha.coverage_at(0, 0), 255)
    assert_equal(alpha.coverage_at(1, 0), 255)
    assert_equal(alpha.coverage_at(2, 0), 0)
    assert_equal(alpha.coverage_at(2, 1), 128)

    # Luminance is (30 R + 59 G + 11 B) // 100, scaled by alpha.
    var luma = Mask.from_luminance(c)
    assert_equal(luma.coverage_at(0, 0), 255, "white")
    assert_equal(luma.coverage_at(1, 0), 0, "black")
    assert_equal(luma.coverage_at(2, 0), 0, "transparent white")
    assert_equal(luma.coverage_at(0, 1), 100, "gray 100")
    # 30 * 255 // 100 = 76.
    assert_equal(luma.coverage_at(1, 1), 76, "red")
    # (255 * 128) // 255 = 128.
    assert_equal(luma.coverage_at(2, 1), 128, "half-alpha white")
    # Outside the mask is 0.
    assert_equal(luma.coverage_at(-1, 0), 0)
    assert_equal(luma.coverage_at(3, 0), 0)


def test_a_blurred_disk_mask_gives_a_soft_edged_fill() raises:
    # A disk of radius 10 on a transparent canvas, blurred, becomes a
    # stencil whose interior is solid, whose far field is empty and
    # whose edge ramps.
    var stencil = Canvas(40, 40, CLEAR)
    fill_circle_aa(stencil, 20.0, 20.0, 10.0, Color(0, 0, 0))
    blur(stencil, 3.0)
    var mask = Mask.from_alpha(stencil)

    var c = Canvas(40, 40, CLEAR)
    fill_mask(c, mask, BLUE)
    assert_equal(c.get_pixel(20, 20).a, 255, "solid interior")
    assert_equal(c.get_pixel(20, 20).b, 255)
    assert_equal(c.get_pixel(1, 1).a, 0, "empty corner")
    var edge = Int(c.get_pixel(30, 20).a)
    assert_true(edge > 0 and edge < 255, "ramped edge: " + String(edge))
    var further = Int(c.get_pixel(33, 20).a)
    assert_true(further < edge, "and falling off outward")


def test_push_clip_mask_multiplies_into_the_parent() raises:
    # Two half masks nested: (128 * 128) // 255 = 64 of an opaque fill
    # gets through. Popping the inner one restores 128.
    var c = Canvas(4, 4, CLEAR)
    push_clip_mask(c, Mask(4, 4, 128))
    push_clip_mask(c, Mask(4, 4, 128))
    fill_rect(c, 0, 0, 4, 4, RED)
    _assert_rgba(c.get_pixel(1, 1), 255, 0, 0, 64, "two half masks")
    c.pop_clip_path()
    var d = Canvas(4, 4, CLEAR)
    push_clip_mask(d, Mask(4, 4, 128))
    fill_rect(d, 0, 0, 4, 4, RED)
    _assert_rgba(d.get_pixel(1, 1), 255, 0, 0, 128, "one half mask")
    # A rectangle clip on top still applies independently.
    var e = Canvas(4, 4, CLEAR)
    push_clip_mask(e, Mask(4, 4, 128))
    e.push_clip(0, 0, 2, 2)
    fill_rect(e, 0, 0, 4, 4, BLUE)
    _assert_rgba(e.get_pixel(1, 1), 0, 0, 255, 128, "inside the rect")
    _assert_rgba(e.get_pixel(3, 3), 0, 0, 0, 0, "outside it, untouched")


def test_push_clip_mask_from_a_path_is_the_clip_path() raises:
    var path = _ellipse_path()
    var via_mask = Canvas(40, 40, CLEAR)
    push_clip_mask(via_mask, Mask.from_path(path, 40, 40))
    var via_path = Canvas(40, 40, CLEAR)
    via_path.push_clip_path(path)
    for y in range(40):
        for x in range(40):
            assert_equal(
                via_mask.clip_coverage(x, y),
                via_path.clip_coverage(x, y),
                "coverage at " + String(x) + "," + String(y),
            )


def test_push_clip_mask_at_an_offset_clips_everything_else() raises:
    var c = Canvas(6, 6, CLEAR)
    push_clip_mask(c, Mask(2, 2, 255), 1, 1)
    assert_equal(c.clip_coverage(1, 1), 255)
    assert_equal(c.clip_coverage(2, 2), 255)
    assert_equal(c.clip_coverage(0, 0), 0, "before the mask")
    assert_equal(c.clip_coverage(3, 3), 0, "past the mask")
    fill_rect(c, 0, 0, 6, 6, RED)
    assert_equal(c.get_pixel(1, 1).a, 255)
    assert_equal(c.get_pixel(5, 5).a, 0)


def test_inverted_is_the_complement() raises:
    var m = Mask(2, 1, 200)
    var inv = m.inverted()
    assert_equal(inv.coverage_at(0, 0), 55)
    assert_equal(inv.coverage_at(1, 0), 55)
    assert_equal(m.coverage_at(0, 0), 200, "the original is unchanged")
    assert_equal(Mask(1, 1, 0).inverted().coverage_at(0, 0), 255)


def test_apply_mask_scales_alpha_and_draw_canvas_composites_through_it() raises:
    var src = Canvas(4, 4, RED)
    var half = apply_mask(src, Mask(4, 4, 128))
    _assert_rgba(half.get_pixel(1, 1), 255, 0, 0, 128, "alpha halved")
    _assert_rgba(src.get_pixel(1, 1), 255, 0, 0, 255, "source unchanged")
    # A mask smaller than the source: pixels it does not reach go
    # transparent.
    var corner = apply_mask(src, Mask(2, 2, 255))
    assert_equal(corner.get_pixel(1, 1).a, 255)
    assert_equal(corner.get_pixel(3, 3).a, 0)

    var dst = Canvas(8, 8, CLEAR)
    draw_canvas(dst, src, 2, 2, Mask(2, 2, 128))
    _assert_rgba(dst.get_pixel(2, 2), 255, 0, 0, 128, "through the mask")
    _assert_rgba(dst.get_pixel(5, 5), 0, 0, 0, 0, "beyond it, nothing")


def test_mask_over_the_wrong_number_of_bytes_raises() raises:
    with assert_raises(contains="expected 6"):
        _ = Mask(3, 2, List[UInt8](length=5, fill=0))
    var ok = Mask(3, 2, List[UInt8](length=6, fill=9))
    assert_equal(ok.coverage_at(2, 1), 9)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
