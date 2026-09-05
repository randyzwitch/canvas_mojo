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


def test_exclusion_at_full_and_partial_alpha() raises:
    # B = Cb + Cs - 2*(Cb*Cs // 255).
    #   r: 200 + 128 - 2*100 = 128
    #   g: 100 + 255 - 2*100 = 155
    #   b: 50  + 0   - 0     = 50
    _assert_rgba(
        _drawn(BlendMode.EXCLUSION, SRC, BG), 128, 155, 50, 255, "exclusion"
    )
    #   r: (128*128 + 127*200) // 255 = (16384 + 25400) // 255 = 163
    #   g: (128*155 + 127*100) // 255 = (19840 + 12700) // 255 = 127
    #   b: (128*50  + 127*50)  // 255 = (6400 + 6350) // 255 = 50
    _assert_rgba(
        _drawn(BlendMode.EXCLUSION, SRC.with_alpha(128), BG),
        163,
        127,
        50,
        255,
        "exclusion at half alpha",
    )


def test_color_dodge_brightens_and_saturates_at_one() raises:
    # B = min(1, Cb / (1 - Cs)), with Cs = 1 pinned to 1 and Cb = 0 to 0.
    #   r: Cs = 128: min(255, 200*255 // 127) = min(255, 401) = 255
    #   g: Cs = 255: 255 outright
    #   b: Cs = 0:   50*255 // 255 = 50, the backdrop unchanged
    _assert_rgba(
        _drawn(BlendMode.COLOR_DODGE, SRC, BG), 255, 255, 50, 255, "dodge"
    )
    #   r: (128*255 + 127*200) // 255 = (32640 + 25400) // 255 = 227
    #   g: (128*255 + 127*100) // 255 = (32640 + 12700) // 255 = 177
    #   b: (128*50  + 127*50)  // 255 = 50
    _assert_rgba(
        _drawn(BlendMode.COLOR_DODGE, SRC.with_alpha(128), BG),
        227,
        177,
        50,
        255,
        "dodge at half alpha",
    )
    # A black backdrop channel stays black whatever the source does.
    _assert_rgba(
        _drawn(BlendMode.COLOR_DODGE, Color(255, 128, 0), Color(0, 0, 0)),
        0,
        0,
        0,
        255,
        "dodge over black",
    )


def test_color_burn_darkens_and_saturates_at_zero() raises:
    # B = 1 - min(1, (1 - Cb) / Cs), with Cs = 0 pinned to 0 and
    # Cb = 1 to 1.
    #   r: Cs = 128: 255 - min(255, 55*255 // 128) = 255 - 109 = 146
    #   g: Cs = 255: 255 - min(255, 155*255 // 255) = 255 - 155 = 100
    #   b: Cs = 0:   0 outright
    _assert_rgba(
        _drawn(BlendMode.COLOR_BURN, SRC, BG), 146, 100, 0, 255, "burn"
    )
    #   r: (128*146 + 127*200) // 255 = (18688 + 25400) // 255 = 172
    #   g: (128*100 + 127*100) // 255 = 100
    #   b: (128*0   + 127*50)  // 255 = 6350 // 255 = 24
    _assert_rgba(
        _drawn(BlendMode.COLOR_BURN, SRC.with_alpha(128), BG),
        172,
        100,
        24,
        255,
        "burn at half alpha",
    )
    # A white backdrop channel stays white whatever the source does.
    _assert_rgba(
        _drawn(BlendMode.COLOR_BURN, Color(0, 128, 255), Color(255, 255, 255)),
        255,
        255,
        255,
        255,
        "burn over white",
    )


def test_hard_light_takes_each_channel_to_the_side_its_source_is_on() raises:
    # Overlay with the operands swapped: the source channel picks the
    # half.
    #   r: 2*128 = 256 > 255, so screen(Cb, 2*Cs - 255) with t = 1:
    #      200 + 1 - (200*1 // 255) = 201
    #   g: 2*255 = 510, t = 255: 100 + 255 - (100*255 // 255) = 255
    #   b: 2*0 = 0 <= 255, so multiply(Cb, 0) = 0
    _assert_rgba(
        _drawn(BlendMode.HARD_LIGHT, SRC, BG), 201, 255, 0, 255, "hard light"
    )
    #   r: (128*201 + 127*200) // 255 = (25728 + 25400) // 255 = 200
    #   g: (128*255 + 127*100) // 255 = (32640 + 12700) // 255 = 177
    #   b: (128*0   + 127*50)  // 255 = 24
    _assert_rgba(
        _drawn(BlendMode.HARD_LIGHT, SRC.with_alpha(128), BG),
        200,
        177,
        24,
        255,
        "hard light at half alpha",
    )
    # And the swap is exact: hard-light(Cb, Cs) == overlay(Cs, Cb).
    var hl = _blend_pixel(BlendMode.HARD_LIGHT, SRC, BG)
    var ov = _blend_pixel(BlendMode.OVERLAY, BG, SRC)
    _assert_rgba(
        hl,
        Int(ov.r),
        Int(ov.g),
        Int(ov.b),
        255,
        "hard-light is overlay swapped",
    )


def test_soft_light_in_floating_point() raises:
    # Computed in 0-1 floats and rounded to the nearest channel.
    #   r: Cb = 0.7843, Cs = 0.5020 > 0.5, so D = sqrt(Cb) = 0.8856 and
    #      B = Cb + (2*Cs - 1)*(D - Cb) = 0.7843 + 0.0039*0.1013 = 0.7847
    #      -> 200.1 -> 200
    #   g: Cb = 0.3922, Cs = 1: B = D = sqrt(0.3922) = 0.6262
    #      -> 159.7 -> 160
    #   b: Cb = 0.1961, Cs = 0 <= 0.5: B = Cb - Cb*(1 - Cb)
    #      = 0.1961 - 0.1576 = 0.0384 -> 9.8 -> 10
    _assert_rgba(
        _drawn(BlendMode.SOFT_LIGHT, SRC, BG), 200, 160, 10, 255, "soft light"
    )
    #   r: (128*200 + 127*200) // 255 = 51000 // 255 = 200
    #   g: (128*160 + 127*100) // 255 = (20480 + 12700) // 255 = 130
    #   b: (128*10  + 127*50)  // 255 = (1280 + 6350) // 255 = 29
    _assert_rgba(
        _drawn(BlendMode.SOFT_LIGHT, SRC.with_alpha(128), BG),
        200,
        130,
        29,
        255,
        "soft light at half alpha",
    )
    # The cubic branch: Cb <= 0.25 with a source past 0.5.
    #   Cb = 0.2, D = ((16*0.2 - 12)*0.2 + 4)*0.2 = (-1.76 + 4)*0.2 = 0.448
    #   Cs = 1: B = 0.2 + 1*(0.448 - 0.2) = 0.448 -> 114.2 -> 114
    _assert_rgba(
        _drawn(BlendMode.SOFT_LIGHT, Color(255, 255, 255), Color(51, 51, 51)),
        114,
        114,
        114,
        255,
        "soft light on the cubic branch",
    )


def test_hue_takes_the_source_hue_at_the_backdrop_lum_and_sat() raises:
    # In 0-1 floats: Cb = (0.7843, 0.3922, 0.1961), Lum(Cb) = 0.4882,
    # Sat(Cb) = 0.5882. Cs = (0.5020, 1, 0), Sat(Cs) = 1.
    # SetSat(Cs, 0.5882): max g -> 0.5882, min b -> 0, mid
    #   r -> 0.5020*0.5882 = 0.2953. Lum of that is 0.4356.
    # SetLum(.., 0.4882) adds 0.0526 to each channel, nothing to clip:
    #   (0.3479, 0.6408, 0.0526) -> (89, 163, 13)
    _assert_rgba(_drawn(BlendMode.HUE, SRC, BG), 89, 163, 13, 255, "hue")
    #   r: (128*89  + 127*200) // 255 = (11392 + 25400) // 255 = 144
    #   g: (128*163 + 127*100) // 255 = (20864 + 12700) // 255 = 131
    #   b: (128*13  + 127*50)  // 255 = (1664 + 6350) // 255 = 31
    _assert_rgba(
        _drawn(BlendMode.HUE, SRC.with_alpha(128), BG),
        144,
        131,
        31,
        255,
        "hue at half alpha",
    )


def test_saturation_takes_the_source_sat_and_clips_below_zero() raises:
    # SetSat(Cb, Sat(Cs) = 1): max r -> 1, min b -> 0, mid
    #   g -> (0.3922 - 0.1961) / 0.5882 = 0.3333. Lum of that is 0.4967.
    # SetLum(.., 0.4882) subtracts 0.0085: (0.9915, 0.3248, -0.0085),
    # and the negative blue is what ClipColor pulls back, scaling the
    # distance from grey 0.4882 by 0.4882 / 0.4967 = 0.9829:
    #   (0.9830, 0.3277, 0) -> (251, 84, 0)
    _assert_rgba(
        _drawn(BlendMode.SATURATION, SRC, BG), 251, 84, 0, 255, "saturation"
    )
    #   r: (128*251 + 127*200) // 255 = (32128 + 25400) // 255 = 225
    #   g: (128*84  + 127*100) // 255 = (10752 + 12700) // 255 = 91
    #   b: (128*0   + 127*50)  // 255 = 24
    _assert_rgba(
        _drawn(BlendMode.SATURATION, SRC.with_alpha(128), BG),
        225,
        91,
        24,
        255,
        "saturation at half alpha",
    )


def test_color_keeps_the_backdrop_lum_under_the_source_colour() raises:
    # SetLum(Cs, Lum(Cb)): Lum(Cs) = 0.7406, so subtract 0.2524 from Cs:
    # (0.2496, 0.7476, -0.2524). ClipColor scales by
    # 0.4882 / (0.4882 + 0.2524) = 0.6592 about grey 0.4882:
    #   (0.3309, 0.6592, 0) -> (84, 168, 0)
    _assert_rgba(_drawn(BlendMode.COLOR, SRC, BG), 84, 168, 0, 255, "color")
    #   r: (128*84  + 127*200) // 255 = (10752 + 25400) // 255 = 141
    #   g: (128*168 + 127*100) // 255 = (21504 + 12700) // 255 = 134
    #   b: (128*0   + 127*50)  // 255 = 24
    _assert_rgba(
        _drawn(BlendMode.COLOR, SRC.with_alpha(128), BG),
        141,
        134,
        24,
        255,
        "color at half alpha",
    )


def test_luminosity_keeps_the_backdrop_colour_and_clips_above_one() raises:
    # SetLum(Cb, Lum(Cs)): add 0.2524 to Cb: (1.0367, 0.6446, 0.4485).
    # Red is past 1, so ClipColor scales by
    # (1 - 0.7406) / (1.0367 - 0.7406) = 0.8760 about grey 0.7406:
    #   (1.0, 0.6565, 0.4847) -> (255, 167, 124)
    _assert_rgba(
        _drawn(BlendMode.LUMINOSITY, SRC, BG), 255, 167, 124, 255, "luminosity"
    )
    #   r: (128*255 + 127*200) // 255 = (32640 + 25400) // 255 = 227
    #   g: (128*167 + 127*100) // 255 = (21376 + 12700) // 255 = 133
    #   b: (128*124 + 127*50)  // 255 = (15872 + 6350) // 255 = 87
    _assert_rgba(
        _drawn(BlendMode.LUMINOSITY, SRC.with_alpha(128), BG),
        227,
        133,
        87,
        255,
        "luminosity at half alpha",
    )


def test_a_non_separable_mode_over_a_transparent_pixel_is_the_source() raises:
    # ab = 0 leaves Cs' = Cs, so the triple blend has no effect until
    # something is underneath, like the separable modes.
    _assert_rgba(
        _drawn(BlendMode.HUE, SRC, Color(0, 0, 0, 0)),
        128,
        255,
        0,
        255,
        "hue over nothing draws the source",
    )


def test_clear_and_destination_are_the_two_ends() raises:
    # CLEAR: Fa = Fb = 0, nothing survives.
    _assert_rgba(
        _drawn(BlendMode.CLEAR, SRC.with_alpha(128), BG.with_alpha(200)),
        0,
        0,
        0,
        0,
        "clear",
    )
    # DESTINATION: Fa = 0, Fb = 1, the backdrop is untouched.
    _assert_rgba(
        _drawn(BlendMode.DESTINATION, SRC.with_alpha(128), BG.with_alpha(200)),
        200,
        100,
        50,
        200,
        "destination",
    )


def test_destination_over_paints_the_source_behind() raises:
    # Fa = 1 - ab = 55, Fb = 1.
    #   wa = (128*55) // 255 = 7040 // 255 = 27, wb = 200, ao = 227.
    #   r: (27*128 + 200*200) // 227 = (3456 + 40000) // 227 = 191
    #   g: (27*255 + 200*100) // 227 = (6885 + 20000) // 227 = 118
    #   b: (27*0   + 200*50)  // 227 = 10000 // 227 = 44
    _assert_rgba(
        _drawn(
            BlendMode.DESTINATION_OVER, SRC.with_alpha(128), BG.with_alpha(200)
        ),
        191,
        118,
        44,
        227,
        "destination-over",
    )
    # Over an opaque backdrop the source is entirely hidden.
    _assert_rgba(
        _drawn(BlendMode.DESTINATION_OVER, SRC, BG),
        200,
        100,
        50,
        255,
        "destination-over under an opaque pixel",
    )


def test_source_in_and_out_keep_the_source_colour() raises:
    # Both have Fb = 0, so Co = (wa*Cs) // wa = Cs; only the alpha
    # moves. source-in: Fa = ab, so ao = (128 * 200) // 255 = 100.
    _assert_rgba(
        _drawn(BlendMode.SOURCE_IN, SRC.with_alpha(128), BG.with_alpha(200)),
        128,
        255,
        0,
        100,
        "source-in scales the source alpha by the backdrop's",
    )
    # source-out: Fa = 1 - ab, so ao = (128 * 55) // 255 = 27.
    _assert_rgba(
        _drawn(BlendMode.SOURCE_OUT, SRC.with_alpha(128), BG.with_alpha(200)),
        128,
        255,
        0,
        27,
        "source-out keeps the source where the backdrop is not",
    )
    # source-in over a transparent pixel draws nothing at all.
    _assert_rgba(
        _drawn(BlendMode.SOURCE_IN, SRC, Color(0, 0, 0, 0)),
        0,
        0,
        0,
        0,
        "source-in over nothing",
    )


def test_atop_composites_inside_the_other_side() raises:
    # source-atop: Fa = ab = 200, Fb = 1 - as = 127.
    #   wa = (128*200) // 255 = 100, wb = (200*127) // 255 = 99, ao = 199.
    #   r: (100*128 + 99*200) // 199 = (12800 + 19800) // 199 = 163
    #   g: (100*255 + 99*100) // 199 = (25500 + 9900) // 199 = 177
    #   b: (100*0   + 99*50)  // 199 = 4950 // 199 = 24
    _assert_rgba(
        _drawn(BlendMode.SOURCE_ATOP, SRC.with_alpha(128), BG.with_alpha(200)),
        163,
        177,
        24,
        199,
        "source-atop",
    )
    # The alpha is the backdrop's own: the source never adds coverage.
    _assert_rgba(
        _drawn(BlendMode.SOURCE_ATOP, SRC, Color(0, 0, 0, 0)),
        0,
        0,
        0,
        0,
        "source-atop over nothing draws nothing",
    )
    # destination-atop: Fa = 1 - ab = 55, Fb = as = 128.
    #   wa = 27, wb = (200*128) // 255 = 100, ao = 127.
    #   r: (27*128 + 100*200) // 127 = (3456 + 20000) // 127 = 184
    #   g: (27*255 + 100*100) // 127 = (6885 + 10000) // 127 = 132
    #   b: (27*0   + 100*50)  // 127 = 5000 // 127 = 39
    _assert_rgba(
        _drawn(
            BlendMode.DESTINATION_ATOP, SRC.with_alpha(128), BG.with_alpha(200)
        ),
        184,
        132,
        39,
        127,
        "destination-atop",
    )


def test_add_sums_and_clamps() raises:
    # Fa = Fb = 1: wa = 128, wb = 200, ao = min(255, 328) = 255.
    #   r: (128*128 + 200*200) // 255 = (16384 + 40000) // 255 = 221
    #   g: (128*255 + 200*100) // 255 = (32640 + 20000) // 255 = 206
    #   b: (128*0   + 200*50)  // 255 = 10000 // 255 = 39
    _assert_rgba(
        _drawn(BlendMode.ADD, SRC.with_alpha(128), BG.with_alpha(200)),
        221,
        206,
        39,
        255,
        "add of two translucent pixels",
    )
    # Two opaque pixels: each channel is the plain sum, clamped.
    #   r: 128 + 200 = 328 -> 255, g: 255 + 100 -> 255, b: 0 + 50 = 50
    _assert_rgba(
        _drawn(BlendMode.ADD, SRC, BG), 255, 255, 50, 255, "add clamps"
    )
    # Over nothing, add is the source.
    _assert_rgba(
        _drawn(BlendMode.ADD, SRC.with_alpha(128), Color(0, 0, 0, 0)),
        128,
        255,
        0,
        128,
        "add over nothing",
    )


def test_span_fast_paths_match_the_pixel_blend() raises:
    # A filled region blends whole rows at a time, with fast paths for
    # separable modes over opaque pixels: a scalar one for all eleven,
    # and a four-pixel vector one for the six whose B is plain integer
    # arithmetic. A row with an opaque stretch, a translucent hole and
    # a ragged end runs every branch in one span; each pixel must be
    # what _blend_pixel gives.
    var modes: List[BlendMode] = [
        BlendMode.MULTIPLY,
        BlendMode.SCREEN,
        BlendMode.OVERLAY,
        BlendMode.DARKEN,
        BlendMode.LIGHTEN,
        BlendMode.DIFFERENCE,
        BlendMode.EXCLUSION,
        BlendMode.COLOR_DODGE,
        BlendMode.COLOR_BURN,
        BlendMode.HARD_LIGHT,
        BlendMode.SOFT_LIGHT,
        BlendMode.HUE,
        BlendMode.SOURCE_ATOP,
    ]
    var sources: List[Color] = [SRC, SRC.with_alpha(128), SRC.with_alpha(3)]
    for m in modes:
        for src in sources:
            var c = Canvas(23, 2, BG)
            # Pixels 5..7 translucent, pixel 12 transparent: the vector
            # path has to skip the groups holding them.
            for x in range(5, 8):
                c.set_pixel(x, 0, Color(0, 0, 0, 0))
                c.set_pixel(x, 0, Color(90, 140, 210, 100))
            c.set_pixel(12, 0, Color(0, 0, 0, 0))
            var before = List[Color]()
            for x in range(23):
                before.append(c.get_pixel(x, 0))
            c.set_blend_mode(m)
            fill_rect(c, 0, 0, 23, 1, src)
            for x in range(23):
                var want = _blend_pixel(m, src, before[x])
                var got = c.get_pixel(x, 0)
                var at = String(m) + " a=" + String(src.a) + " x=" + String(x)
                assert_equal(Int(got.r), Int(want.r), at + " r")
                assert_equal(Int(got.g), Int(want.g), at + " g")
                assert_equal(Int(got.b), Int(want.b), at + " b")
                assert_equal(Int(got.a), Int(want.a), at + " a")
            # The row below was never touched.
            _assert_rgba(c.get_pixel(3, 1), 200, 100, 50, 255, "untouched row")


def test_every_mode_is_classified_once() raises:
    # The three families partition the table, and the classification
    # is what routes a pixel through _blend_pixel.
    var porter_duff: List[BlendMode] = [
        BlendMode.SOURCE_OVER,
        BlendMode.SOURCE,
        BlendMode.DESTINATION_IN,
        BlendMode.DESTINATION_OUT,
        BlendMode.XOR,
        BlendMode.CLEAR,
        BlendMode.DESTINATION,
        BlendMode.DESTINATION_OVER,
        BlendMode.SOURCE_IN,
        BlendMode.SOURCE_OUT,
        BlendMode.SOURCE_ATOP,
        BlendMode.DESTINATION_ATOP,
        BlendMode.ADD,
    ]
    for m in porter_duff:
        assert_false(m.is_separable())
        assert_false(m.is_non_separable())
    var separable: List[BlendMode] = [
        BlendMode.MULTIPLY,
        BlendMode.SCREEN,
        BlendMode.OVERLAY,
        BlendMode.DARKEN,
        BlendMode.LIGHTEN,
        BlendMode.DIFFERENCE,
        BlendMode.EXCLUSION,
        BlendMode.COLOR_DODGE,
        BlendMode.COLOR_BURN,
        BlendMode.HARD_LIGHT,
        BlendMode.SOFT_LIGHT,
    ]
    for m in separable:
        assert_true(m.is_separable())
        assert_false(m.is_non_separable())
    var non_separable: List[BlendMode] = [
        BlendMode.HUE,
        BlendMode.SATURATION,
        BlendMode.COLOR,
        BlendMode.LUMINOSITY,
    ]
    for m in non_separable:
        assert_false(m.is_separable())
        assert_true(m.is_non_separable())


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
    assert_equal(c.blend_mode(), BlendMode.MULTIPLY)
    # Nested, to pin that each restore pops one level rather than
    # resetting to the default.
    c.save()
    c.set_blend_mode(BlendMode.XOR)
    assert_equal(c.blend_mode(), BlendMode.XOR)
    c.restore()
    assert_equal(c.blend_mode(), BlendMode.MULTIPLY, "inner restore")
    c.restore()
    assert_equal(c.blend_mode(), BlendMode.SOURCE_OVER, "outer restore")

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
    each.set_blend_mode(BlendMode.EXCLUSION)
    each.fill_circle_aa(60, 10, 5, Color(0, 0, 0))
    each.set_blend_mode(BlendMode.COLOR_DODGE)
    each.fill_circle_aa(70, 10, 5, Color(0, 0, 0))
    each.set_blend_mode(BlendMode.COLOR_BURN)
    each.fill_circle_aa(80, 10, 5, Color(0, 0, 0))
    each.set_blend_mode(BlendMode.HARD_LIGHT)
    each.fill_circle_aa(90, 10, 5, Color(0, 0, 0))
    each.set_blend_mode(BlendMode.SOFT_LIGHT)
    each.fill_circle_aa(10, 20, 5, Color(0, 0, 0))
    each.set_blend_mode(BlendMode.HUE)
    each.fill_circle_aa(20, 20, 5, Color(0, 0, 0))
    each.set_blend_mode(BlendMode.SATURATION)
    each.fill_circle_aa(30, 20, 5, Color(0, 0, 0))
    each.set_blend_mode(BlendMode.COLOR)
    each.fill_circle_aa(40, 20, 5, Color(0, 0, 0))
    each.set_blend_mode(BlendMode.LUMINOSITY)
    each.fill_circle_aa(50, 20, 5, Color(0, 0, 0))
    var out = each.to_string()
    assert_true('style="mix-blend-mode:screen"' in out)
    assert_true('style="mix-blend-mode:overlay"' in out)
    assert_true('style="mix-blend-mode:darken"' in out)
    assert_true('style="mix-blend-mode:lighten"' in out)
    assert_true('style="mix-blend-mode:difference"' in out)
    assert_true('style="mix-blend-mode:exclusion"' in out)
    assert_true('style="mix-blend-mode:color-dodge"' in out)
    assert_true('style="mix-blend-mode:color-burn"' in out)
    assert_true('style="mix-blend-mode:hard-light"' in out)
    assert_true('style="mix-blend-mode:soft-light"' in out)
    assert_true('style="mix-blend-mode:hue"' in out)
    assert_true('style="mix-blend-mode:saturation"' in out)
    assert_true('style="mix-blend-mode:color"' in out)
    assert_true('style="mix-blend-mode:luminosity"' in out)


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
    svg.set_blend_mode(BlendMode.CLEAR)
    svg.fill_rect(50, 0, 10, 10, Color(0, 0, 0))
    svg.set_blend_mode(BlendMode.SOURCE_ATOP)
    svg.fill_rect(60, 0, 10, 10, Color(0, 0, 0))
    svg.set_blend_mode(BlendMode.ADD)
    svg.fill_rect(70, 0, 10, 10, Color(0, 0, 0))
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
