"""Tests for canvas_mojo/text/render.mojo.

These can't assert exact pixel sets the way canvas_mojo.shapes' tests
do: real system-font rasterization (hinting, AA, glyph shapes) isn't
something this repo re-derives by hand the way Bresenham or
midpoint-circle output is. What's tested instead are the properties
this module is responsible for:

  - the early-exit edge cases (empty string, whitespace-only text,
    fully transparent color) are true no-ops
  - the glyph-outline-to-Path-to-fill_path_aa pipeline places ink where
    requested, in the requested color, for at least one pixel a solid
    glyph interior guarantees full coverage on
  - anti-aliasing happens: mixed-coverage edge pixels exist, not just
    pure background and pure foreground
  - every touched pixel obeys the src-over blend invariant, staying a
    convex combination of background and foreground per channel
  - two identical calls produce identical output, so no state leaks
    between them

Only `test_measure_text_matches_known_glyph_extents` asserts exact
values, which depend on `ttf.mojo`'s unhinted metrics: a hinting
rasterizer rounds thin stems like "I"'s single stroke to whole pixels,
and `ttf.mojo` never hints.

Needs a "Sans"-resolvable system font (fontconfig's generic sans-serif
alias), true of most Linux/macOS systems but not guaranteed the way a
checked-in fixture would be. The font-fallback tests need a second
machine-specific fact -- the "Ubuntu" font lacking a snowman glyph
"DejaVu Sans" has -- see test_font_discovery.mojo.
"""

from std.math import pi
from std.testing import assert_equal, assert_true, TestSuite

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas
from canvas_mojo.text.render import draw_text, measure_text, measure_text_block, TextAlign, _visual_codepoints

comptime BG = Color(255, 255, 255)
comptime FG = Color(200, 20, 20, 255)


def _assert_canvas_untouched(c: Canvas, bg: Color, label: String) raises:
    for y in range(c.height):
        for x in range(c.width):
            var p = c.get_pixel(x, y)
            assert_equal(p.r, bg.r, label)
            assert_equal(p.g, bg.g, label)
            assert_equal(p.b, bg.b, label)


struct _InkBBox(ImplicitlyCopyable, Movable):
    """Bounding box of every non-background pixel; a struct rather than
    a 4-tuple so the fields have names at call sites.
    """

    var min_x: Int
    var max_x: Int
    var min_y: Int
    var max_y: Int
    var found_any: Bool

    def __init__(out self, min_x: Int, max_x: Int, min_y: Int, max_y: Int, found_any: Bool):
        self.min_x = min_x
        self.max_x = max_x
        self.min_y = min_y
        self.max_y = max_y
        self.found_any = found_any


def _ink_bbox(c: Canvas, bg: Color) -> _InkBBox:
    var min_x = c.width
    var max_x = -1
    var min_y = c.height
    var max_y = -1
    var found_any = False
    for y in range(c.height):
        for x in range(c.width):
            var p = c.get_pixel(x, y)
            if p.r != bg.r or p.g != bg.g or p.b != bg.b:
                found_any = True
                if x < min_x:
                    min_x = x
                if x > max_x:
                    max_x = x
                if y < min_y:
                    min_y = y
                if y > max_y:
                    max_y = y
    return _InkBBox(min_x, max_x, min_y, max_y, found_any)


def test_empty_string_is_noop() raises:
    var c = Canvas(40, 40, BG)
    draw_text(c, 5, 20, "", FG, 24.0)
    _assert_canvas_untouched(c, BG, "empty string drew something")


def test_whitespace_only_is_noop() raises:
    # Measuring " " reports width=0, height=0 -- an advance with no
    # ink -- so this takes the same early return as the empty string,
    # not a 1-pixel-wide sliver.
    var c = Canvas(40, 40, BG)
    draw_text(c, 5, 20, "   ", FG, 24.0)
    _assert_canvas_untouched(c, BG, "whitespace-only drew something")


def test_alpha_zero_is_noop() raises:
    var c = Canvas(60, 60, BG)
    draw_text(c, 5, 40, "I", Color(200, 20, 20, 0), 40.0)
    _assert_canvas_untouched(c, BG, "fully transparent color drew something")


def test_opaque_glyph_has_an_exact_full_coverage_pixel() raises:
    # A large solid vertical stroke has interior pixels far enough from
    # any edge for full coverage (alpha == 255), which set_pixel writes
    # unblended -- so at least one pixel must equal FG exactly, not
    # merely come close.
    var c = Canvas(120, 120, BG)
    draw_text(c, 10, 90, "I", FG, 60.0)

    var exact_matches = 0
    for y in range(c.height):
        for x in range(c.width):
            var p = c.get_pixel(x, y)
            if p.r == FG.r and p.g == FG.g and p.b == FG.b:
                exact_matches += 1
    assert_true(exact_matches > 0)


def test_opaque_glyph_has_antialiased_edge_pixels() raises:
    # Same render as above: some pixels are neither pure background nor
    # pure foreground, so the fill isn't hard-edged.
    var c = Canvas(120, 120, BG)
    draw_text(c, 10, 90, "I", FG, 60.0)

    var partial = 0
    for y in range(c.height):
        for x in range(c.width):
            var p = c.get_pixel(x, y)
            var is_bg = p.r == BG.r and p.g == BG.g and p.b == BG.b
            var is_fg = p.r == FG.r and p.g == FG.g and p.b == FG.b
            if not is_bg and not is_fg:
                partial += 1
    assert_true(partial > 0)


def test_translucent_text_stays_within_blend_bounds() raises:
    # Under src-over, every touched channel must stay within
    # [min(bg, fg), max(bg, fg)] -- but within 1 unit, not exactly:
    # the pipeline floors twice (unpremultiply's integer divide, then
    # blend_over) for a translucent unpremultiplied color, so a result
    # sitting on the boundary can land 1 past it. Measured max
    # deviation across every touched pixel is exactly 1. A wider one
    # would mean something beyond rounding -- unpremultiplying by the
    # wrong alpha, say -- which this still catches.
    var bg = Color(30, 200, 60)
    var fg = Color(200, 20, 20, 130)
    var c = Canvas(120, 120, bg)
    draw_text(c, 10, 90, "I", fg, 60.0)

    # Int, not UInt8: a UInt8 lower bound of 0 minus a tolerance of 1
    # wraps to 255 rather than going negative.
    comptime TOLERANCE = 1
    var lo_r = Int(min(bg.r, fg.r)) - TOLERANCE
    var hi_r = Int(max(bg.r, fg.r)) + TOLERANCE
    var lo_g = Int(min(bg.g, fg.g)) - TOLERANCE
    var hi_g = Int(max(bg.g, fg.g)) + TOLERANCE
    var lo_b = Int(min(bg.b, fg.b)) - TOLERANCE
    var hi_b = Int(max(bg.b, fg.b)) + TOLERANCE

    for y in range(c.height):
        for x in range(c.width):
            var p = c.get_pixel(x, y)
            assert_true(Int(p.r) >= lo_r and Int(p.r) <= hi_r)
            assert_true(Int(p.g) >= lo_g and Int(p.g) <= hi_g)
            assert_true(Int(p.b) >= lo_b and Int(p.b) <= hi_b)


def test_draw_text_is_deterministic() raises:
    var c1 = Canvas(120, 120, BG)
    var c2 = Canvas(120, 120, BG)
    draw_text(c1, 10, 90, "Ag", FG, 40.0)
    draw_text(c2, 10, 90, "Ag", FG, 40.0)

    for y in range(c1.height):
        for x in range(c1.width):
            var p1 = c1.get_pixel(x, y)
            var p2 = c2.get_pixel(x, y)
            assert_equal(p1.r, p2.r)
            assert_equal(p1.g, p2.g)
            assert_equal(p1.b, p2.b)


def test_measure_text_matches_known_glyph_extents() raises:
    # "I" in Sans at size 24: ink width=2.3671875, height=17.49609375,
    # advance=7.078125, measured against the unhinted ttf.mojo path.
    # Exact rather than tolerance-based -- font-design-unit counts
    # times a power-of-two-denominator fraction, the same reasoning
    # test_glyph_outline.mojo gives for this glyph at another size.
    var m = measure_text("I", 24.0)
    assert_equal(m.width, 2.3671875)
    assert_equal(m.height, 17.49609375)
    assert_equal(m.advance, 7.078125)


def test_measure_text_long_string_is_not_empty() raises:
    # A long runtime-constructed String, built by concatenation rather
    # than typed as one literal, must measure nonzero. The two aren't
    # interchangeable at the String-marshaling level, so a literal here
    # would exercise less than it appears to.
    var built = String("jumps over") + String(" the lazy dog")
    var m = measure_text(built, 22.0)
    assert_true(m.width > 0.0)
    assert_true(m.height > 0.0)
    assert_true(m.advance > 0.0)


def test_draw_text_long_single_line_renders_ink() raises:
    # The same long-runtime-String property, for the draw_text path:
    # its internal sizing pass runs this length of string through the
    # "any_ink" check, so a failure silently no-ops the whole call
    # rather than just mismeasuring.
    var c = Canvas(320, 60, BG)
    draw_text(c, 10, 40, "jumps over the lazy dog", FG, 22.0)
    var bbox = _ink_bbox(c, BG)
    assert_true(bbox.found_any)


def test_measure_text_empty_string_is_all_zero() raises:
    var m = measure_text("", 24.0)
    assert_equal(m.width, 0.0)
    assert_equal(m.height, 0.0)
    assert_equal(m.advance, 0.0)


def test_rotation_zero_matches_omitting_the_argument() raises:
    # One code path for rotated and unrotated: passing rotation=0.0
    # explicitly must produce byte-identical output to omitting it.
    var c1 = Canvas(120, 120, BG)
    var c2 = Canvas(120, 120, BG)
    draw_text(c1, 10, 90, "Ag", FG, 40.0)
    draw_text(c2, 10, 90, "Ag", FG, 40.0, rotation=0.0)

    for y in range(c1.height):
        for x in range(c1.width):
            var p1 = c1.get_pixel(x, y)
            var p2 = c2.get_pixel(x, y)
            assert_equal(p1.r, p2.r)
            assert_equal(p1.g, p2.g)
            assert_equal(p1.b, p2.b)


def test_rotation_90_degrees_swaps_ink_bbox_dimensions() raises:
    # "I" unrotated is a tall narrow stroke, its ink bbox much taller
    # than wide. Rotated 90 degrees it lies on its side: wider than
    # tall, dimensions roughly swapped. Roughly, since AA fringe and
    # integer rounding shift them -- but the tall/narrow vs. wide/short
    # relationship must flip, not merely move.
    var c1 = Canvas(150, 150, BG)
    draw_text(c1, 60, 100, "I", FG, 60.0)
    var unrotated = _ink_bbox(c1, BG)
    assert_true(unrotated.found_any)
    var unrotated_width = unrotated.max_x - unrotated.min_x
    var unrotated_height = unrotated.max_y - unrotated.min_y
    assert_true(unrotated_height > unrotated_width)  # tall and narrow

    var c2 = Canvas(150, 150, BG)
    draw_text(c2, 60, 100, "I", FG, 60.0, rotation=pi / 2.0)
    var rotated = _ink_bbox(c2, BG)
    assert_true(rotated.found_any)
    var rotated_width = rotated.max_x - rotated.min_x
    var rotated_height = rotated.max_y - rotated.min_y
    assert_true(rotated_width > rotated_height)  # now wide and short


def test_multiline_produces_ink_in_separate_vertical_bands() raises:
    var c = Canvas(120, 150, BG)
    draw_text(c, 10, 40, "A\nB", FG, 30.0)
    var bbox = _ink_bbox(c, BG)
    assert_true(bbox.found_any)

    # A background row must exist strictly between the two baselines:
    # collapsed or overlapping lines would leave no such gap.
    var found_gap_row = False
    for y in range(bbox.min_y + 1, bbox.max_y):
        var row_all_bg = True
        for x in range(bbox.min_x, bbox.max_x + 1):
            var p = c.get_pixel(x, y)
            if p.r != BG.r or p.g != BG.g or p.b != BG.b:
                row_all_bg = False
                break
        if row_all_bg:
            found_gap_row = True
            break
    assert_true(found_gap_row)


def test_multiline_blank_line_takes_space_but_draws_nothing() raises:
    # "A\n\nB": three line slots, the middle empty. The gap between A's
    # ink and B's spans roughly two line heights, not one, so the blank
    # line counted for spacing despite contributing no ink.
    var c_two_lines = Canvas(120, 200, BG)
    draw_text(c_two_lines, 10, 40, "A\nB", FG, 30.0)
    var two_line_bbox = _ink_bbox(c_two_lines, BG)

    var c_three_lines = Canvas(120, 200, BG)
    draw_text(c_three_lines, 10, 40, "A\n\nB", FG, 30.0)
    var three_line_bbox = _ink_bbox(c_three_lines, BG)

    assert_true(two_line_bbox.found_any)
    assert_true(three_line_bbox.found_any)
    # same top (line 0 unaffected), but B lands further down when a
    # blank line precedes it
    assert_true(three_line_bbox.max_y > two_line_bbox.max_y)


def test_align_left_ink_starts_near_the_anchor() raises:
    var c = Canvas(150, 60, BG)
    var anchor_x = 40
    draw_text(c, anchor_x, 40, "Hi", FG, 30.0, align=TextAlign.LEFT)
    var bbox = _ink_bbox(c, BG)
    assert_true(bbox.found_any)
    # x_bearing is typically small and non-negative for Latin glyphs,
    # so the ink's left edge should be within a few pixels of anchor_x
    assert_true(bbox.min_x >= anchor_x - 2 and bbox.min_x <= anchor_x + 5)


def test_align_right_ink_ends_near_the_anchor() raises:
    var c = Canvas(150, 60, BG)
    var anchor_x = 100
    draw_text(c, anchor_x, 40, "Hi", FG, 30.0, align=TextAlign.RIGHT)
    var bbox = _ink_bbox(c, BG)
    assert_true(bbox.found_any)
    assert_true(bbox.max_x <= anchor_x + 2 and bbox.max_x >= anchor_x - 5)


def test_align_center_ink_straddles_the_anchor() raises:
    var c = Canvas(150, 60, BG)
    var anchor_x = 75
    draw_text(c, anchor_x, 40, "Hi", FG, 30.0, align=TextAlign.CENTER)
    var bbox = _ink_bbox(c, BG)
    assert_true(bbox.found_any)
    # centered ink brackets the anchor on both sides, unlike left
    # (anchor at or before all ink) or right (anchor at or after)
    assert_true(bbox.min_x < anchor_x)
    assert_true(bbox.max_x > anchor_x)


def test_measure_text_block_matches_rendered_ink_unrotated() raises:
    # Cross-checked against draw_text's rendered ink bbox (_ink_bbox)
    # rather than a hand-derived number: what matters to a layout
    # caller is whether the prediction agrees with what lands on the
    # canvas, not whether the math is internally consistent. A 60pt "I"
    # at anchor (60, 100) renders ink at x=[65,72], y=[55,99], and
    # measure_text_block predicts the same position within a pixel or
    # two of floor-rounding and AA fringe.
    var anchor_x = 60
    var anchor_y = 100
    var c = Canvas(150, 150, BG)
    draw_text(c, anchor_x, anchor_y, "I", FG, 60.0)
    var actual = _ink_bbox(c, BG)
    assert_true(actual.found_any)

    var predicted = measure_text_block("I", 60.0)
    var pred_min_x = Float64(anchor_x) + predicted.x
    var pred_max_x = Float64(anchor_x) + predicted.x + predicted.width
    var pred_min_y = Float64(anchor_y) + predicted.y
    var pred_max_y = Float64(anchor_y) + predicted.y + predicted.height

    assert_true(pred_min_x > Float64(actual.min_x) - 2.0 and pred_min_x < Float64(actual.min_x) + 2.0)
    assert_true(pred_max_x > Float64(actual.max_x) - 2.0 and pred_max_x < Float64(actual.max_x) + 2.0)
    assert_true(pred_min_y > Float64(actual.min_y) - 2.0 and pred_min_y < Float64(actual.min_y) + 2.0)
    assert_true(pred_max_y > Float64(actual.max_y) - 2.0 and pred_max_y < Float64(actual.max_y) + 2.0)


def test_measure_text_block_matches_rendered_ink_rotated() raises:
    # Same cross-check rotated -- the case _layout_block exists for,
    # since an unrotated box is easy to get right by accident. Same
    # "I", same anchor, rotation=pi/2.
    var anchor_x = 60
    var anchor_y = 100
    var c = Canvas(150, 150, BG)
    draw_text(c, anchor_x, anchor_y, "I", FG, 60.0, rotation=pi / 2.0)
    var actual = _ink_bbox(c, BG)
    assert_true(actual.found_any)

    var predicted = measure_text_block("I", 60.0, rotation=pi / 2.0)
    var pred_min_x = Float64(anchor_x) + predicted.x
    var pred_max_x = Float64(anchor_x) + predicted.x + predicted.width
    var pred_min_y = Float64(anchor_y) + predicted.y
    var pred_max_y = Float64(anchor_y) + predicted.y + predicted.height

    assert_true(pred_min_x > Float64(actual.min_x) - 2.0 and pred_min_x < Float64(actual.min_x) + 2.0)
    assert_true(pred_max_x > Float64(actual.max_x) - 2.0 and pred_max_x < Float64(actual.max_x) + 2.0)
    assert_true(pred_min_y > Float64(actual.min_y) - 2.0 and pred_min_y < Float64(actual.min_y) + 2.0)
    assert_true(pred_max_y > Float64(actual.max_y) - 2.0 and pred_max_y < Float64(actual.max_y) + 2.0)

    # The tall/narrow-vs-wide/short flip
    # test_rotation_90_degrees_swaps_ink_bbox_dimensions confirms on
    # pixels must hold for the *predicted* box too: right shape, not
    # just right position.
    assert_true(predicted.width > predicted.height)


def test_measure_text_block_right_align_matches_rendered_ink() raises:
    var anchor_x = 100
    var c = Canvas(150, 60, BG)
    draw_text(c, anchor_x, 40, "Hi", FG, 30.0, align=TextAlign.RIGHT)
    var actual = _ink_bbox(c, BG)
    assert_true(actual.found_any)

    var predicted = measure_text_block("Hi", 30.0, align=TextAlign.RIGHT)
    var pred_max_x = Float64(anchor_x) + predicted.x + predicted.width
    assert_true(pred_max_x > Float64(actual.max_x) - 2.0 and pred_max_x < Float64(actual.max_x) + 2.0)


def test_measure_text_block_empty_string_is_a_zero_box() raises:
    var b = measure_text_block("", 24.0)
    assert_equal(b.x, 0.0)
    assert_equal(b.y, 0.0)
    assert_equal(b.width, 0.0)
    assert_equal(b.height, 0.0)


def test_measure_text_block_whitespace_only_is_a_zero_box() raises:
    # Matches draw_text's whitespace-only no-op: no ink means no box,
    # not a box sized by whitespace's nonzero advance.
    var b = measure_text_block("   ", 24.0)
    assert_equal(b.x, 0.0)
    assert_equal(b.y, 0.0)
    assert_equal(b.width, 0.0)
    assert_equal(b.height, 0.0)


def test_measure_text_block_rotation_zero_matches_omitting_the_argument() raises:
    var explicit = measure_text_block("Hi", 24.0, rotation=0.0)
    var omitted = measure_text_block("Hi", 24.0)
    assert_equal(explicit.x, omitted.x)
    assert_equal(explicit.y, omitted.y)
    assert_equal(explicit.width, omitted.width)
    assert_equal(explicit.height, omitted.height)


def test_hebrew_word_renders_ink() raises:
    # "שלום" -- DejaVu Sans has real Hebrew glyphs, so this isn't
    # measuring a fallback-to-.notdef box.
    var c = Canvas(150, 60, BG)
    draw_text(c, 20, 40, "שלום", FG, 30.0)
    var bbox = _ink_bbox(c, BG)
    assert_true(bbox.found_any)


def test_hebrew_measure_matches_rendered_ink() raises:
    # The unrotated cross-check applied to a right-to-left script.
    # draw_text's render pass and measure_text both go through
    # bidi.visual_order via _visual_codepoints, so this catches the
    # reordering being applied on one side only.
    var c = Canvas(150, 60, BG)
    draw_text(c, 20, 40, "שלום", FG, 30.0)
    var actual = _ink_bbox(c, BG)
    assert_true(actual.found_any)

    var m = measure_text("שלום", 30.0)
    assert_true(m.width > 0.0)
    var actual_width = Float64(actual.max_x - actual.min_x)
    assert_true(actual_width > m.width - 3.0 and actual_width < m.width + 3.0)


def test_measure_and_draw_agree_on_bidi_reordering() raises:
    # _visual_codepoints is the one integration point both
    # _measure_line and draw_text's render pass go through. Calling it
    # directly (Mojo doesn't enforce leading-underscore privacy, as
    # test_dash.mojo already relies on) checks the wiring, which is
    # what drifts if a change touches one call site and not the other.
    # test_bidi.mojo covers the reordering algorithm itself.
    var out = _visual_codepoints("שלום 12")
    # Digits stay in reading order; test_bidi.mojo checks the same
    # against bidi.visual_order directly.
    var one_idx = -1
    var two_idx = -1
    for i in range(len(out)):
        if out[i] == 0x31:
            one_idx = i
        if out[i] == 0x32:
            two_idx = i
    assert_true(one_idx >= 0 and two_idx >= 0)
    assert_true(one_idx < two_idx)


def test_draw_text_falls_back_to_a_font_with_the_glyph() raises:
    # End-to-end proof that draw_text's fallback wiring
    # (_resolve_glyph) reaches rendering, not just
    # resolve_font_file_for_char in isolation, which
    # test_font_discovery.mojo covers. The "Ubuntu" font has no snowman
    # glyph (U+2603), so with fallback working, drawing it produces
    # real ink; without, it would render as an empty zero-size
    # .notdef.
    var c = Canvas(60, 60, BG)
    draw_text(c, 10, 45, "☃", FG, 32.0, family="Ubuntu")
    var bbox = _ink_bbox(c, BG)
    assert_true(bbox.found_any)


def test_measure_text_falls_back_to_a_font_with_the_glyph() raises:
    # The same property for measure_text: a font that has the glyph
    # reports non-zero ink dimensions. No specific .notdef size is
    # asserted -- what matters is that measurement and rendering agree
    # fallback happened, not a second copy of glyph_outline.mojo's
    # locked-in metrics.
    var m = measure_text("☃", 32.0, family="Ubuntu")
    assert_true(m.width > 0.0)
    assert_true(m.height > 0.0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
