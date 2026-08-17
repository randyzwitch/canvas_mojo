"""Tests for canvas_mojo/text/glyph_outline.mojo.

Needs a "Sans"-resolvable system font (fontconfig's generic sans-serif
alias) to run -- same real-machine dependency tests/
test_text.mojo and test_font_discovery.mojo already document.

Locked-in values below are all re-measured against this machine's real
DejaVu Sans through the native `ttf.mojo` path specifically, not
carried over from the earlier FreeType-backed version of this module:
`num_glyphs`/`units_per_EM`/`ascender`/`descender` match this exact
font's well-known real metrics (the same values `ttf.mojo`'s own
from-scratch Python-oracle cross-check already confirmed). Glyph
metrics ("I"'s width/height/advance at size 60) do *not* match the old
FreeType-hinted values exactly anymore -- a real, understood,
expected difference documented at each assertion below, not a
regression: FreeType's default hinting rounds thin stems (like "I"'s
own single vertical stroke) to whole pixels for on-screen crispness;
this module's native path never hints, by design (see `ttf.mojo`'s
own module docstring for why). Every "I"-at-size-60 value here is
exact -- `raw_units * 60 / 2048` for `units_per_EM=2048` and any
integer `raw_units` is exactly representable in `Float64` (2048 is a
power of two), so these are provable exact arithmetic, not values
needing a tolerance.
"""

from std.testing import assert_equal, assert_true, TestSuite

from canvas_mojo.buffer import Canvas
from canvas_mojo.color import Color
from canvas_mojo.text.font_discovery import resolve_font_file
from canvas_mojo.text.glyph_outline import face_line_metrics, glyph_metrics, glyph_path, has_glyph
from canvas_mojo.text.ttf import TTFFace
from canvas_mojo.path import fill_path_aa

comptime BG = Color(255, 255, 255)
comptime FG = Color(0, 0, 0)


def _sans_face(pixel_size: Int) raises -> TTFFace:
    var path = resolve_font_file("Sans")
    var face = TTFFace(path)
    face.set_pixel_size(pixel_size)
    return face^


def test_line_metrics_match_known_font_metrics() raises:
    # DejaVu Sans's real metrics: units_per_EM=2048, ascender=1901,
    # descender=-483 (font design units) -- confirmed via ttf.mojo's
    # own from-scratch Python-oracle cross-check. At 60px: exactly
    # 1901*60/2048 = 55.693359375 and -483*60/2048 = -14.150390625 --
    # exact arithmetic (2048 is a power of two), not an approximation,
    # so this is a real equality check, not a tolerance-based one.
    var face = _sans_face(60)
    var lm = face_line_metrics(face)
    assert_equal(lm.ascender, 55.693359375)
    assert_equal(lm.descender, -14.150390625)
    assert_true(lm.line_height > lm.ascender - lm.descender - 2.0)


def test_line_metrics_without_a_size_raises() raises:
    # Confirmed via probe, not assumed: without set_pixel_size, this
    # doesn't crash -- it raises explicitly (see ttf.mojo's own
    # TTFFace.scale docstring), the same "don't silently trust an
    # unset size" stance the FreeType-backed version of this module
    # already took.
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
    # "I" at size 60 in Sans -- re-measured against the native,
    # unhinted path specifically (see this file's own module
    # docstring for why these differ from the old FreeType-hinted
    # values, and why they're nonetheless exact rather than
    # tolerance-based): width=5.91796875 (raw 202 units -- DejaVu
    # Sans's own "I" stem, unrounded), height=43.740234375 (raw 1492
    # units), advance=17.6953125 (raw 604 units, matching ttf.mojo's
    # own test_ttf.mojo... this is the same font/glyph, cross-checked
    # independently there too).
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
    # Confirmed via probe: exactly 1 contour, 4 points, all on-curve
    # (no curves in a capital I) -- decomposes to move_to + 3x line_to
    # + a closing line_to back to the start + close(), 6 commands
    # total. Locked in here as a structural regression check -- the
    # exact same fact ttf.mojo's own test_ttf.mojo independently
    # confirms at the raw-outline level (this test confirms it survives
    # the full path-decomposition step too).
    var face = _sans_face(60)
    var p = glyph_path(face, 73, 0.0, 0.0)  # 'I'
    assert_equal(len(p.commands), 6)


def test_o_glyph_renders_a_round_shape_with_a_hole() raises:
    # The real end-to-end check: decompose a genuinely curved,
    # multi-contour glyph ('O' has an outer and inner contour) and
    # rasterize it through this package's own fill_path_aa -- no
    # FreeType, no Cairo, no linked font-rendering library anywhere in
    # this call chain. A correct render has ink (the ring itself), a
    # real hole at the visual center (the inner contour correctly
    # punched via fill_path_aa's default EVEN_ODD rule), and covers a
    # plausible fraction of its own bounding box (a ring covers
    # meaningfully less than a solid disc would, but nowhere near
    # zero) -- confirmed by direct pixel inspection, the same rigor
    # tests/test_text.mojo's own ink-bbox checks use.
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
    assert_true(center_pixel.r == BG.r and center_pixel.g == BG.g and center_pixel.b == BG.b)

    # A ring's own ink is a real fraction of its bounding box, but
    # nowhere near all of it (that would mean the hole didn't get
    # punched) or almost none of it (that would mean barely anything
    # rendered at all).
    var bbox_area = Int(gm.width + 2.0) * Int(gm.height + 2.0)
    assert_true(ink_pixels > bbox_area // 10)
    assert_true(ink_pixels < bbox_area * 8 // 10)


def test_has_glyph_true_for_a_real_character() raises:
    var face = _sans_face(24)
    assert_true(has_glyph(face, 0x41))  # 'A'


def test_has_glyph_false_for_a_codepoint_this_font_lacks() raises:
    # Confirmed via probe: DejaVu Sans has no CJK coverage -- cmap
    # lookup returns glyph index 0 (.notdef) for it, not a real glyph.
    # If this ever starts failing because DejaVu Sans gained CJK
    # glyphs, that's a real environment change, not a sign has_glyph
    # itself is wrong.
    var face = _sans_face(24)
    assert_true(not has_glyph(face, 0x4E2D))  # 中


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
