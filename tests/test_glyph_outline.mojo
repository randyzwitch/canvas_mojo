"""Tests for canvas/text/glyph_outline.mojo.

Needs a "Sans"-resolvable system font (the generic sans-serif
alias), the same real-machine dependency test_text.mojo and
test_font_discovery.mojo document.

Locked-in values are measured against this machine's DejaVu Sans
through the native `ttf.mojo` path:
`num_glyphs`/`units_per_EM`/`ascender`/`descender` match the font's
well-known metrics, which `ttf.mojo`'s Python oracle confirms. Glyph
metrics ("I"'s width/height/advance at size 60) are unhinted and so
differ slightly from a hinting rasterizer's, which rounds thin stems
like "I"'s single stroke to whole pixels.

Every "I"-at-size-60 value is exact rather than tolerance-based:
`raw_units * 60 / 2048` is exactly representable in `Float64` for any
integer `raw_units`, since 2048 is a power of two.
"""

from std.testing import assert_equal, assert_true, TestSuite

from canvas.buffer import Canvas
from canvas.color import Color
from canvas.text.font_discovery import resolve_font_file
from canvas.text.glyph_outline import (
    face_line_metrics,
    glyph_metrics,
    glyph_path,
    has_glyph,
)
from canvas.text.ttf import TTFFace
from canvas.path import fill_path_aa

comptime BG = Color(255, 255, 255)
comptime FG = Color(0, 0, 0)


def _sans_face(pixel_size: Int) raises -> TTFFace:
    var path = resolve_font_file("Sans")
    var face = TTFFace(path)
    face.set_pixel_size(pixel_size)
    return face^


def test_line_metrics_match_known_font_metrics() raises:
    # DejaVu Sans's metrics in font design units: units_per_EM=2048,
    # ascender=1901, descender=-483, per ttf.mojo's Python oracle. At
    # 60px that's exactly 1901*60/2048 = 55.693359375 and
    # -483*60/2048 = -14.150390625 -- exact, since 2048 is a power of
    # two, so equality rather than tolerance.
    var face = _sans_face(60)
    var lm = face_line_metrics(face)
    assert_equal(lm.ascender, 55.693359375)
    assert_equal(lm.descender, -14.150390625)
    assert_true(lm.line_height > lm.ascender - lm.descender - 2.0)


def test_line_metrics_without_a_size_raises() raises:
    # Without set_pixel_size this raises explicitly (see
    # TTFFace.scale) rather than measuring at some defaulted size.
    var path = resolve_font_file("Sans")
    var face = TTFFace(path)
    var raised = False
    try:
        var lm = face_line_metrics(face)
        _ = lm
    except:
        raised = True
    assert_true(raised)


def test_glyph_metrics_i_at_size_60() raises:
    # "I" at size 60 in Sans, unhinted: width=5.91796875 (raw 202
    # units, DejaVu Sans's unrounded "I" stem), height=43.740234375
    # (raw 1492), advance=17.6953125 (raw 604, which test_ttf.mojo
    # cross-checks against the same font).
    var face = _sans_face(60)
    var gm = glyph_metrics(face, 73)  # 'I'
    assert_equal(gm.width, 5.91796875)
    assert_equal(gm.height, 43.740234375)
    assert_equal(gm.advance, 17.6953125)


def test_glyph_metrics_without_a_size_raises() raises:
    var path = resolve_font_file("Sans")
    var face = TTFFace(path)
    var raised = False
    try:
        var gm = glyph_metrics(face, 73)
        _ = gm
    except:
        raised = True
    assert_true(raised)


def test_i_glyph_outline_is_a_simple_rectangle() raises:
    # Exactly 1 contour, 4 points, all on-curve (a capital I has no
    # curves), decomposing to move_to + 3x line_to + a closing line_to
    # + close(): 6 commands. test_ttf.mojo confirms the same at the
    # raw-outline level; this checks it survives decomposition.
    var face = _sans_face(60)
    var p = glyph_path(face, 73, 0.0, 0.0)  # 'I'
    assert_equal(len(p.commands), 6)


def test_o_glyph_renders_a_round_shape_with_a_hole() raises:
    # The end-to-end check: decompose a curved multi-contour glyph
    # ('O' has an outer and an inner contour) and rasterize it through
    # fill_path_aa, with no linked font library in the call chain. A
    # correct render has ink in the ring, a hole at the visual center
    # from the inner contour under the default EVEN_ODD rule, and
    # covers a plausible fraction of its bounding box -- less than a
    # solid disc, nowhere near zero.
    var face = _sans_face(40)
    var gm = glyph_metrics(face, 79)  # 'O'
    var c = Canvas(60, 60, BG)
    var path = glyph_path(face, 79, 5.0, 45.0)
    fill_path_aa(c, path, FG)

    var ink_pixels = 0
    for y in range(c.height):
        for x in range(c.width):
            var pix = c.get_pixel(x, y)
            if not (pix.r == BG.r and pix.g == BG.g and pix.b == BG.b):
                ink_pixels += 1
    assert_true(ink_pixels > 0)

    # The hole: 'O's visual center, well inside the outer ring and
    # well outside the inner one for any reasonably-proportioned O.
    var center_x = 5 + Int(gm.width / 2.0)
    var center_y = 45 - Int(gm.height / 2.0)
    var center_pixel = c.get_pixel(center_x, center_y)
    assert_true(
        center_pixel.r == BG.r
        and center_pixel.g == BG.g
        and center_pixel.b == BG.b
    )

    # A ring's ink is a real fraction of its bounding box: all of it
    # would mean the hole wasn't punched, almost none that barely
    # anything rendered.
    var bbox_area = Int(gm.width + 2.0) * Int(gm.height + 2.0)
    assert_true(ink_pixels > bbox_area // 10)
    assert_true(ink_pixels < bbox_area * 8 // 10)


def test_has_glyph_true_for_a_real_character() raises:
    var face = _sans_face(24)
    assert_true(has_glyph(face, 0x41))  # 'A'


def test_has_glyph_false_for_a_codepoint_this_font_lacks() raises:
    # DejaVu Sans has no CJK coverage, so cmap lookup returns glyph
    # index 0 (.notdef). A failure here means the installed font gained
    # CJK glyphs, not that has_glyph is wrong.
    var face = _sans_face(24)
    assert_true(not has_glyph(face, 0x4E2D))  # 中


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
