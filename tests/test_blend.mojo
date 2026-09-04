"""Tests for blend and composite modes: `BlendMode`, the canvas state
that carries one, the arithmetic each mode applies, and the
`mix-blend-mode` attribute the SVG backend emits.

Every expected pixel below is derived from the formulas in
canvas/blend.mojo and written out with the arithmetic, not read back
from a run. The integer steps are the ones the code takes -- `_div255`
truncates, and so does the final divide by the output alpha -- so the
assertions are exact equalities.

Three properties beyond the per-mode arithmetic matter as much:
SOURCE_OVER has to produce the bytes it always did, the packed
whole-word store has to still be what an opaque source-over fill takes,
and `save`/`restore` has to carry the mode along with the transform.
"""

from std.testing import assert_equal, assert_false, assert_true, TestSuite

from canvas.blend import BlendMode, _blend_pixel
from canvas.buffer import Canvas
from canvas.color import Color
from canvas.path import Path
from canvas.shapes.circles import fill_circle_aa
from canvas.shapes.rects import fill_rect
from canvas.vector.svg import SvgCanvas

# The backdrop every raster test draws onto, opaque unless a test says
# otherwise, and the source it draws with. Chosen so no channel pair is
# symmetric: 200 > 128 puts OVERLAY on its screen half in red and on
# its multiply half in green and blue, and DARKEN/LIGHTEN pick
# different sides per channel.
comptime BG = Color(200, 100, 50)
comptime SRC = Color(128, 255, 0)


def _drawn(mode: BlendMode, src: Color, bg: Color) raises -> Color:
    """`src` filled over a canvas of `bg` under `mode`, read back at an
    interior pixel. A 4x4 fill covering the whole canvas, so the pixel
    read is interior to the rectangle and no anti-aliased edge is
    involved.
    """
    var c = Canvas(4, 4, bg)
    c.set_blend_mode(mode)
    fill_rect(c, 0, 0, 4, 4, src)
    return c.get_pixel(1, 1)


def _assert_rgba(
    got: Color, r: Int, g: Int, b: Int, a: Int, msg: String
) raises:
    assert_equal(Int(got.r), r, msg + " (red)")
    assert_equal(Int(got.g), g, msg + " (green)")
    assert_equal(Int(got.b), b, msg + " (blue)")
    assert_equal(Int(got.a), a, msg + " (alpha)")


def test_default_mode_is_source_over() raises:
    var c = Canvas(4, 4, BG)
    assert_true(
        c.blend_mode() == BlendMode.SOURCE_OVER,
        "a fresh canvas composites source-over",
    )
    assert_true(BlendMode.SOURCE_OVER.is_source_over())
    assert_false(BlendMode.MULTIPLY.is_source_over())
    assert_false(BlendMode.SOURCE_OVER.is_separable())
    assert_false(BlendMode.XOR.is_separable())
    assert_true(BlendMode.MULTIPLY.is_separable())
    assert_true(BlendMode.DIFFERENCE.is_separable())


def test_source_over_is_unchanged_by_the_mode_machinery() raises:
    # The pre-existing arithmetic, asserted independently: a source at
    # alpha 128 over an opaque backdrop is
    # (128*Cs + 127*Cb) // 255 per channel, alpha 255.
    #   r: (128*128 + 127*200) // 255 = (16384 + 25400) // 255 = 163
    #   g: (128*255 + 127*100) // 255 = (32640 + 12700) // 255 = 177
    #   b: (128*0   + 127*50)  // 255 = 6350 // 255 = 24
    var got = _drawn(BlendMode.SOURCE_OVER, SRC.with_alpha(128), BG)
    _assert_rgba(got, 163, 177, 24, 255, "src-over at half alpha")

    # And the general blend agrees with Color.blend_over exactly, which
    # is what makes SOURCE_OVER the identity case of both halves of the
    # formula rather than a separate path with its own rounding.
    var general = _blend_pixel(
        BlendMode.SOURCE_OVER, SRC.with_alpha(128), Color(BG.r, BG.g, BG.b, 200)
    )
    var direct = SRC.with_alpha(128).blend_over(Color(BG.r, BG.g, BG.b, 200))
    _assert_rgba(
        general,
        Int(direct.r),
        Int(direct.g),
        Int(direct.b),
        Int(direct.a),
        "_blend_pixel(SOURCE_OVER) == Color.blend_over",
    )


def test_multiply_at_full_and_partial_alpha() raises:
    # Opaque backdrop, so Cs' is B outright: B = Cb*Cs // 255.
    #   r: 200*128 // 255 = 25600 // 255 = 100
    #   g: 100*255 // 255 = 100
    #   b: 50*0    // 255 = 0
    # Fa = 1, Fb = 1 - as = 0, so the result is Cs' at alpha 255.
    _assert_rgba(
        _drawn(BlendMode.MULTIPLY, SRC, BG), 100, 100, 0, 255, "multiply opaque"
    )

    # At as = 128 the same B composites source-over onto the backdrop:
    # (128*B + 127*Cb) // 255.
    #   r: (128*100 + 127*200) // 255 = (12800 + 25400) // 255 = 149
    #   g: (128*100 + 127*100) // 255 = (12800 + 12700) // 255 = 100
    #   b: (128*0   + 127*50)  // 255 = 6350 // 255 = 24
    _assert_rgba(
        _drawn(BlendMode.MULTIPLY, SRC.with_alpha(128), BG),
        149,
        100,
        24,
        255,
        "multiply at half alpha",
    )


def test_screen_at_full_and_partial_alpha() raises:
    # B = Cb + Cs - Cb*Cs // 255.
    #   r: 200 + 128 - 100 = 228
    #   g: 100 + 255 - 100 = 255
    #   b: 50  + 0   - 0   = 50
    _assert_rgba(
        _drawn(BlendMode.SCREEN, SRC, BG), 228, 255, 50, 255, "screen opaque"
    )

    #   r: (128*228 + 127*200) // 255 = (29184 + 25400) // 255 = 214
    #   g: (128*255 + 127*100) // 255 = (32640 + 12700) // 255 = 177
    #   b: (128*50  + 127*50)  // 255 = (6400 + 6350) // 255 = 50
    _assert_rgba(
        _drawn(BlendMode.SCREEN, SRC.with_alpha(128), BG),
        214,
        177,
        50,
        255,
        "screen at half alpha",
    )


def test_overlay_takes_each_channel_to_the_side_its_backdrop_is_on() raises:
    # Overlay is hard-light with the operands swapped, so the backdrop
    # channel picks the half:
    #   r: 2*200 = 400 > 255, so screen(Cs, 2*Cb - 255) with t = 145:
    #      128 + 145 - (128*145 // 255) = 273 - 72 = 201
    #   g: 2*100 = 200 <= 255, so multiply(Cs, 2*Cb):
    #      255*200 // 255 = 200
    #   b: 2*50 = 100 <= 255: 0*100 // 255 = 0
    _assert_rgba(
        _drawn(BlendMode.OVERLAY, SRC, BG), 201, 200, 0, 255, "overlay opaque"
    )

    #   r: (128*201 + 127*200) // 255 = (25728 + 25400) // 255 = 200
    #   g: (128*200 + 127*100) // 255 = (25600 + 12700) // 255 = 150
    #   b: (128*0   + 127*50)  // 255 = 6350 // 255 = 24
    _assert_rgba(
        _drawn(BlendMode.OVERLAY, SRC.with_alpha(128), BG),
        200,
        150,
        24,
        255,
        "overlay at half alpha",
    )


def test_darken_and_lighten_pick_per_channel() raises:
    # min(Cb, Cs) per channel: min(200,128)=128, min(100,255)=100,
    # min(50,0)=0.
    _assert_rgba(
        _drawn(BlendMode.DARKEN, SRC, BG), 128, 100, 0, 255, "darken opaque"
    )
    # max: 200, 255, 50.
    _assert_rgba(
        _drawn(BlendMode.LIGHTEN, SRC, BG), 200, 255, 50, 255, "lighten opaque"
    )

    # darken at as = 128: (128*B + 127*Cb) // 255.
    #   r: (128*128 + 127*200) // 255 = (16384 + 25400) // 255 = 163
    #   g: (128*100 + 127*100) // 255 = 25500 // 255 = 100
    #   b: (128*0   + 127*50)  // 255 = 6350 // 255 = 24
    _assert_rgba(
        _drawn(BlendMode.DARKEN, SRC.with_alpha(128), BG),
        163,
        100,
        24,
        255,
        "darken at half alpha",
    )


def test_difference_at_full_and_partial_alpha() raises:
    # |Cb - Cs|: |200-128| = 72, |100-255| = 155, |50-0| = 50.
    _assert_rgba(
        _drawn(BlendMode.DIFFERENCE, SRC, BG),
        72,
        155,
        50,
        255,
        "difference opaque",
    )

    #   r: (128*72  + 127*200) // 255 = (9216 + 25400) // 255 = 135
    #   g: (128*155 + 127*100) // 255 = (19840 + 12700) // 255 = 127
    #   b: (128*50  + 127*50)  // 255 = 12750 // 255 = 50
    _assert_rgba(
        _drawn(BlendMode.DIFFERENCE, SRC.with_alpha(128), BG),
        135,
        127,
        50,
        255,
        "difference at half alpha",
    )


def test_a_blend_mode_over_a_translucent_backdrop() raises:
    # With ab = 128 the backdrop only partly participates in B:
    # Cs' = ((255 - 128)*Cs + 128*B) // 255, then source-over.
    # An opaque source: Fa = 1, Fb = 0, so the result is Cs' at 255.
    #   B  = (100, 100, 0) as above.
    #   r: (127*128 + 128*100) // 255 = (16256 + 12800) // 255 = 113
    #   g: (127*255 + 128*100) // 255 = (32385 + 12800) // 255 = 177
    #   b: (127*0   + 128*0)   // 255 = 0
    _assert_rgba(
        _drawn(BlendMode.MULTIPLY, SRC, BG.with_alpha(128)),
        113,
        177,
        0,
        255,
        "multiply over a half-transparent backdrop",
    )


def test_source_overwrites_the_pixel_outright() raises:
    # Fa = 1, Fb = 0: ao = as, and Co = (as*Cs) // as = Cs. A
    # translucent source therefore replaces a more opaque backdrop
    # rather than compositing onto it.
    _assert_rgba(
        _drawn(BlendMode.SOURCE, Color(10, 20, 30, 64), BG.with_alpha(200)),
        10,
        20,
        30,
        64,
        "source replaces colour and alpha",
    )
    # An opaque source under SOURCE is the same pixel source-over would
    # write, which is what makes the mode safe to leave set.
    _assert_rgba(
        _drawn(BlendMode.SOURCE, SRC, BG), 128, 255, 0, 255, "opaque source"
    )


def test_destination_in_and_out_keep_the_backdrop_colour() raises:
    # Both have Fa = 0, so no source colour reaches the pixel and
    # Co = (wb*Cb) // wb = Cb; only the alpha moves.
    # destination-in: Fb = as, so ao = (200 * 128) // 255 = 100.
    _assert_rgba(
        _drawn(
            BlendMode.DESTINATION_IN, Color(10, 20, 30, 128), BG.with_alpha(200)
        ),
        200,
        100,
        50,
        100,
        "destination-in scales the backdrop alpha by the source's",
    )
    # destination-out: Fb = 1 - as, so ao = (200 * 127) // 255 = 99.
    _assert_rgba(
        _drawn(
            BlendMode.DESTINATION_OUT,
            Color(10, 20, 30, 128),
            BG.with_alpha(200),
        ),
        200,
        100,
        50,
        99,
        "destination-out cuts the backdrop alpha by the source's",
    )
    # An opaque source under destination-out erases the pixel outright:
    # Fb = 0, so ao = 0 and no colour is defined.
    _assert_rgba(
        _drawn(BlendMode.DESTINATION_OUT, SRC, BG),
        0,
        0,
        0,
        0,
        "an opaque cut-out clears the pixel",
    )


def test_xor_keeps_what_each_side_does_not_cover() raises:
    # Fa = 1 - ab, Fb = 1 - as, both 127 here.
    #   wa = wb = (128 * 127) // 255 = 16256 // 255 = 63, ao = 126.
    #   r: (63*10 + 63*200) // 126 = 13230 // 126 = 105
    #   g: (63*20 + 63*100) // 126 = 7560 // 126 = 60
    #   b: (63*30 + 63*50)  // 126 = 5040 // 126 = 40
    _assert_rgba(
        _drawn(BlendMode.XOR, Color(10, 20, 30, 128), Color(200, 100, 50, 128)),
        105,
        60,
        40,
        126,
        "xor of two half-transparent pixels",
    )
    # Two opaque pixels cancel completely: Fa = Fb = 0.
    _assert_rgba(
        _drawn(BlendMode.XOR, SRC, BG), 0, 0, 0, 0, "xor of two opaque pixels"
    )


def test_a_blend_mode_over_a_transparent_pixel_is_the_source() raises:
    # ab = 0 leaves Cs' = Cs and Fb = 0 leaves nothing of the backdrop,
    # so a blend mode is invisible until something is underneath.
    _assert_rgba(
        _drawn(BlendMode.MULTIPLY, SRC, Color(0, 0, 0, 0)),
        128,
        255,
        0,
        255,
        "multiply over nothing draws the source",
    )


def test_coverage_scales_the_source_alpha_along_an_edge() raises:
    # An anti-aliased edge reaches the blend as a partly transparent
    # source, so a mode is applied in proportion to coverage. Asserted
    # as a relation rather than a hand-traced coverage value: under
    # DARKEN the interior is min(Cb, Cs) and the edge sits between that
    # and the untouched backdrop.
    var c = Canvas(40, 40, Color(200, 200, 200))
    c.set_blend_mode(BlendMode.DARKEN)
    fill_circle_aa(c, 20.0, 20.0, 12.0, Color(60, 60, 60))
    assert_equal(Int(c.get_pixel(20, 20).r), 60, "interior is the darker side")
    assert_equal(Int(c.get_pixel(2, 2).r), 200, "outside is untouched")
    var edge = Int(c.get_pixel(20, 8).r)
    assert_true(
        edge > 60 and edge < 200,
        "the anti-aliased edge lands between the two: " + String(edge),
    )


def test_save_and_restore_carry_the_blend_mode() raises:
    var c = Canvas(4, 4, BG)
    c.save()
    c.set_blend_mode(BlendMode.MULTIPLY)
    assert_true(c.blend_mode() == BlendMode.MULTIPLY)
    # Nested, to pin that each restore pops one level rather than
    # resetting to the default.
    c.save()
    c.set_blend_mode(BlendMode.XOR)
    assert_true(c.blend_mode() == BlendMode.XOR)
    c.restore()
    assert_true(c.blend_mode() == BlendMode.MULTIPLY, "inner restore")
    c.restore()
    assert_true(c.blend_mode() == BlendMode.SOURCE_OVER, "outer restore")

    # And the mode a restore puts back is the one later fills use.
    fill_rect(c, 0, 0, 4, 4, SRC)
    _assert_rgba(
        c.get_pixel(1, 1), 128, 255, 0, 255, "source-over after restore"
    )


def test_restore_with_nothing_saved_leaves_the_mode_alone() raises:
    var c = Canvas(4, 4, BG)
    c.set_blend_mode(BlendMode.SCREEN)
    c.restore()
    assert_true(
        c.blend_mode() == BlendMode.SCREEN,
        "an unmatched restore is a no-op, as it is for the transform",
    )


def test_an_opaque_source_over_fill_is_byte_identical_before_and_after() raises:
    # The packed whole-word store is only correct for source-over with
    # an opaque colour. Setting a mode and setting it back has to leave
    # that path exactly as it was, byte for byte across the buffer --
    # this is the assertion standing between a blend mode and every
    # golden image.
    var before = Canvas(32, 24, BG)
    fill_rect(before, 4, 4, 20, 14, SRC)

    var after = Canvas(32, 24, BG)
    after.set_blend_mode(BlendMode.MULTIPLY)
    after.set_blend_mode(BlendMode.SOURCE_OVER)
    fill_rect(after, 4, 4, 20, 14, SRC)

    assert_equal(len(before.pixels), len(after.pixels))
    for i in range(len(before.pixels)):
        assert_equal(
            Int(before.pixels[i]),
            Int(after.pixels[i]),
            "byte " + String(i) + " of an opaque source-over fill",
        )

    # The same through save/restore, which is how a caller actually
    # scopes a mode.
    var scoped = Canvas(32, 24, BG)
    scoped.save()
    scoped.set_blend_mode(BlendMode.DIFFERENCE)
    scoped.restore()
    fill_rect(scoped, 4, 4, 20, 14, SRC)
    for i in range(len(before.pixels)):
        assert_equal(
            Int(before.pixels[i]),
            Int(scoped.pixels[i]),
            "byte " + String(i) + " after a scoped mode",
        )


def test_a_translucent_source_over_fill_is_unchanged_too() raises:
    # _fill_region's hoisted translucent path is the other one a mode
    # must not disturb.
    var before = Canvas(32, 24, BG)
    fill_rect(before, 4, 4, 20, 14, SRC.with_alpha(128))

    var after = Canvas(32, 24, BG)
    after.set_blend_mode(BlendMode.SOURCE)
    after.set_blend_mode(BlendMode.SOURCE_OVER)
    fill_rect(after, 4, 4, 20, 14, SRC.with_alpha(128))

    for i in range(len(before.pixels)):
        assert_equal(
            Int(before.pixels[i]),
            Int(after.pixels[i]),
            "byte " + String(i) + " of a translucent source-over fill",
        )


def test_a_mode_applies_only_where_a_shape_draws() raises:
    # The documented limit: Cairo and the HTML5 canvas apply an
    # operator across the whole clip region, so destination-in there
    # clears everything the source misses. Here an untouched pixel is
    # untouched.
    var c = Canvas(16, 16, BG)
    c.set_blend_mode(BlendMode.DESTINATION_IN)
    fill_rect(c, 0, 0, 8, 8, Color(0, 0, 0, 128))
    assert_equal(Int(c.get_pixel(2, 2).a), 128, "covered: 255*128 // 255")
    assert_equal(Int(c.get_pixel(12, 12).a), 255, "uncovered: left alone")


def test_a_mode_reaches_a_fill_under_a_rectangle_clip() raises:
    # push_clip narrows _fill_region's rectangle rather than going per
    # pixel, so the mode has to survive that path as well.
    var c = Canvas(16, 16, BG)
    c.push_clip(0, 0, 8, 16)
    c.set_blend_mode(BlendMode.MULTIPLY)
    fill_rect(c, 0, 0, 16, 16, SRC)
    c.pop_clip()
    _assert_rgba(c.get_pixel(2, 2), 100, 100, 0, 255, "inside the clip")
    _assert_rgba(c.get_pixel(12, 2), 200, 100, 50, 255, "outside the clip")


def test_a_mode_reaches_a_fill_under_a_clip_path() raises:
    # A clip path sends every pixel through set_pixel's masked branch,
    # which scales the source alpha by coverage and then blends. Fully
    # inside the mask the coverage is 255, so the pixel is the mode's
    # own answer.
    var c = Canvas(24, 24, BG)
    c.push_clip_path(_clip_square())
    c.set_blend_mode(BlendMode.MULTIPLY)
    fill_rect(c, 0, 0, 24, 24, SRC)
    c.pop_clip_path()
    _assert_rgba(c.get_pixel(10, 10), 100, 100, 0, 255, "inside the clip path")
    _assert_rgba(
        c.get_pixel(22, 22), 200, 100, 50, 255, "outside the clip path"
    )


def _clip_square() raises -> Path:
    var p = Path()
    p.rect(2.0, 2.0, 16.0, 16.0)
    return p^


def test_svg_emits_mix_blend_mode_for_the_separable_modes() raises:
    var svg = SvgCanvas(100, 80)
    svg.set_blend_mode(BlendMode.MULTIPLY)
    svg.fill_rect(10, 20, 30, 40, Color(18, 52, 86))
    assert_true(
        '<rect x="10" y="20" width="30" height="40" fill="#123456"'
        ' style="mix-blend-mode:multiply"/>'
        in svg.to_string(),
        "the whole element, exact attributes",
    )

    var each = SvgCanvas(100, 80)
    each.set_blend_mode(BlendMode.SCREEN)
    each.fill_circle_aa(10, 10, 5, Color(0, 0, 0))
    each.set_blend_mode(BlendMode.OVERLAY)
    each.fill_circle_aa(20, 10, 5, Color(0, 0, 0))
    each.set_blend_mode(BlendMode.DARKEN)
    each.fill_circle_aa(30, 10, 5, Color(0, 0, 0))
    each.set_blend_mode(BlendMode.LIGHTEN)
    each.fill_circle_aa(40, 10, 5, Color(0, 0, 0))
    each.set_blend_mode(BlendMode.DIFFERENCE)
    each.fill_circle_aa(50, 10, 5, Color(0, 0, 0))
    var out = each.to_string()
    assert_true('style="mix-blend-mode:screen"' in out)
    assert_true('style="mix-blend-mode:overlay"' in out)
    assert_true('style="mix-blend-mode:darken"' in out)
    assert_true('style="mix-blend-mode:lighten"' in out)
    assert_true('style="mix-blend-mode:difference"' in out)


def test_svg_emits_nothing_for_source_over_or_a_porter_duff_mode() raises:
    var svg = SvgCanvas(100, 80)
    svg.fill_rect(0, 0, 10, 10, Color(0, 0, 0))
    svg.set_blend_mode(BlendMode.SOURCE_OVER)
    svg.fill_rect(10, 0, 10, 10, Color(0, 0, 0))
    svg.set_blend_mode(BlendMode.XOR)
    svg.fill_rect(20, 0, 10, 10, Color(0, 0, 0))
    svg.set_blend_mode(BlendMode.DESTINATION_OUT)
    svg.fill_rect(30, 0, 10, 10, Color(0, 0, 0))
    svg.set_blend_mode(BlendMode.SOURCE)
    svg.fill_rect(40, 0, 10, 10, Color(0, 0, 0))
    assert_true(
        "mix-blend-mode" not in svg.to_string(),
        "CSS has no keyword for the Porter-Duff operators",
    )


def test_svg_save_and_restore_carry_the_blend_mode() raises:
    var svg = SvgCanvas(100, 80)
    svg.save()
    svg.set_blend_mode(BlendMode.SCREEN)
    svg.translate(5.0, 0.0)
    svg.fill_rect(0, 0, 10, 10, Color(0, 0, 0))
    svg.restore()
    svg.fill_rect(0, 0, 10, 10, Color(0, 0, 0))
    var out = svg.to_string()
    assert_true(
        'style="mix-blend-mode:screen"' in out, "the element inside the scope"
    )
    assert_equal(
        out.count('style="mix-blend-mode:screen"'),
        1,
        "restore puts the transform and the mode back together",
    )
    assert_true(
        svg.blend_mode() == BlendMode.SOURCE_OVER, "and the state reads back"
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
