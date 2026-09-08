"""Tests for canvas/text/render.mojo.

These can't assert exact pixel sets the way canvas.shapes' tests
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

`test_measure_text_matches_known_glyph_extents` and the kerning and
ligature tests are the ones asserting exact values, which depend on `ttf.mojo`'s
unhinted metrics: a hinting rasterizer rounds thin stems like "I"'s
single stroke to whole pixels, and `ttf.mojo` never hints.

Needs a "Sans"-resolvable system font (the generic sans-serif
alias), true of most Linux/macOS systems but not guaranteed the way a
checked-in fixture would be. The font-fallback tests need a second
machine-specific fact -- the "Ubuntu" font lacking a snowman glyph
"DejaVu Sans" has -- see test_font_discovery.mojo.
"""

from std.math import pi
from std.testing import assert_equal, assert_true, TestSuite

from canvas.color import Color
from canvas.buffer import Canvas
from canvas.path import Path
from canvas.text.font_cache import _GLYPH_MASK_BUDGET, FontCache
from canvas.text.font_discovery import FontSlant, FontWeight
from canvas.text.render import (
    draw_layout,
    draw_text,
    measure_layout,
    measure_text,
    measure_text_block,
    prepare_text,
    stroke_text,
    TextAlign,
    _apply_run_kerning,
    _shape_line,
    _ShapedGlyph,
)
from canvas.text.ttf import TTFFace
from std.memory import ArcPointer

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

    def __init__(
        out self,
        min_x: Int,
        max_x: Int,
        min_y: Int,
        max_y: Int,
        found_any: Bool,
    ):
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


def _is_bg(c: Canvas, x: Int, y: Int) -> Bool:
    var p = c.get_pixel(x, y)
    return p.r == BG.r and p.g == BG.g and p.b == BG.b


def _within(a: Int, b: Int, slack: Int) -> Bool:
    return a - b <= slack and b - a <= slack


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

    assert_true(
        pred_min_x > Float64(actual.min_x) - 2.0
        and pred_min_x < Float64(actual.min_x) + 2.0
    )
    assert_true(
        pred_max_x > Float64(actual.max_x) - 2.0
        and pred_max_x < Float64(actual.max_x) + 2.0
    )
    assert_true(
        pred_min_y > Float64(actual.min_y) - 2.0
        and pred_min_y < Float64(actual.min_y) + 2.0
    )
    assert_true(
        pred_max_y > Float64(actual.max_y) - 2.0
        and pred_max_y < Float64(actual.max_y) + 2.0
    )


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

    assert_true(
        pred_min_x > Float64(actual.min_x) - 2.0
        and pred_min_x < Float64(actual.min_x) + 2.0
    )
    assert_true(
        pred_max_x > Float64(actual.max_x) - 2.0
        and pred_max_x < Float64(actual.max_x) + 2.0
    )
    assert_true(
        pred_min_y > Float64(actual.min_y) - 2.0
        and pred_min_y < Float64(actual.min_y) + 2.0
    )
    assert_true(
        pred_max_y > Float64(actual.max_y) - 2.0
        and pred_max_y < Float64(actual.max_y) + 2.0
    )

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
    assert_true(
        pred_max_x > Float64(actual.max_x) - 2.0
        and pred_max_x < Float64(actual.max_x) + 2.0
    )


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
    # _shape_line, so this catches the reordering being applied on one
    # side only.
    var c = Canvas(150, 60, BG)
    draw_text(c, 20, 40, "שלום", FG, 30.0)
    var actual = _ink_bbox(c, BG)
    assert_true(actual.found_any)

    var m = measure_text("שלום", 30.0)
    assert_true(m.width > 0.0)
    var actual_width = Float64(actual.max_x - actual.min_x)
    assert_true(actual_width > m.width - 3.0 and actual_width < m.width + 3.0)


def test_measure_and_draw_agree_on_bidi_reordering() raises:
    # _shape_line is the one integration point both _measure_line and
    # draw_text's render pass go through. Calling it directly (Mojo
    # doesn't enforce leading-underscore privacy, as test_dash.mojo
    # already relies on) checks the wiring, which is what drifts if a
    # change touches one call site and not the other. test_bidi.mojo
    # covers the reordering algorithm itself.
    var cache = FontCache()
    var face = cache.resolve_face(
        "Sans", FontSlant.NORMAL, FontWeight.NORMAL, 30.0
    )
    var out = _shape_line(face[], "שלום 12", True, True)
    # Digits stay in reading order; test_bidi.mojo checks the same
    # against bidi.visual_order directly. Neither digit is substituted,
    # so each shaped glyph still carries its own codepoint.
    var one_idx = -1
    var two_idx = -1
    for i in range(len(out)):
        if out[i].codepoint == 0x31:
            one_idx = i
        if out[i].codepoint == 0x32:
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


def _assert_same_pixels(a: Canvas, b: Canvas, label: String) raises:
    assert_equal(a.width, b.width, label)
    assert_equal(a.height, b.height, label)
    for y in range(a.height):
        for x in range(a.width):
            var p = a.get_pixel(x, y)
            var q = b.get_pixel(x, y)
            if p.r != q.r or p.g != q.g or p.b != q.b or p.a != q.a:
                var at = label + " at " + String(x) + "," + String(y)
                assert_equal(p.r, q.r, at)
                assert_equal(p.g, q.g, at)
                assert_equal(p.b, q.b, at)
                assert_equal(p.a, q.a, at)


def test_glyph_cache_hit_matches_miss_at_whole_pixels() raises:
    # The first draw rasterizes every glyph into the cache; the second
    # composites the cached masks. A translucent color makes the alpha
    # arithmetic part of what has to agree.
    var cache = FontCache()
    var ink = Color(30, 90, 200, 140)
    var first = Canvas(160, 40, BG)
    draw_text(first, 8, 28, "Cached 42", ink, 16.0, cache=cache)
    var masks = cache.glyph_mask_count()
    assert_true(masks >= 8, "one mask per distinct glyph")

    var second = Canvas(160, 40, BG)
    draw_text(second, 8, 28, "Cached 42", ink, 16.0, cache=cache)
    assert_equal(cache.glyph_mask_count(), masks, "the second draw hit")
    _assert_same_pixels(first, second, "hit vs miss")

    # And at a different whole-pixel position the same masks apply.
    var moved = Canvas(160, 40, BG)
    draw_text(moved, 31, 22, "Cached 42", ink, 16.0, cache=cache)
    assert_equal(cache.glyph_mask_count(), masks, "same sub-pixel offset")
    var fresh = FontCache()
    var reference = Canvas(160, 40, BG)
    draw_text(reference, 31, 22, "Cached 42", ink, 16.0, cache=fresh)
    _assert_same_pixels(reference, moved, "moved hit vs fresh miss")


def test_glyph_cache_hit_matches_miss_at_sub_pixel_anchors() raises:
    # The key carries the origin's exact fractional part, so a label at
    # x = 10.3 and one at x = 42.3 share masks, and a label at 10.7 gets
    # its own. Every hit must match a fresh rasterization at the same
    # place.
    var cache = FontCache()
    var warm = Canvas(200, 40, BG)
    draw_text(warm, 10.3, 27.6, "tick 1.5", FG, 13.0, cache=cache)
    var masks = cache.glyph_mask_count()

    var hit = Canvas(200, 40, BG)
    draw_text(hit, 42.3, 27.6, "tick 1.5", FG, 13.0, cache=cache)
    assert_equal(cache.glyph_mask_count(), masks, "same fraction, no miss")
    var fresh = FontCache()
    var miss = Canvas(200, 40, BG)
    draw_text(miss, 42.3, 27.6, "tick 1.5", FG, 13.0, cache=fresh)
    _assert_same_pixels(miss, hit, "sub-pixel hit vs miss")

    var other = Canvas(200, 40, BG)
    draw_text(other, 10.7, 27.6, "tick 1.5", FG, 13.0, cache=cache)
    assert_true(
        cache.glyph_mask_count() > masks, "a new fraction is a new mask"
    )


def test_glyph_cache_composites_under_clips() raises:
    # Cached masks meet the rectangle clip per row and the clip path
    # per pixel, the same way a direct fill does.
    var cache = FontCache()
    var warm = Canvas(160, 60, BG)
    draw_text(warm, 6, 40, "Clipped", FG, 20.0, cache=cache)

    var clipped = Canvas(160, 60, BG)
    clipped.push_clip(20, 10, 60, 25)
    draw_text(clipped, 6, 40, "Clipped", FG, 20.0, cache=cache)
    clipped.pop_clip()
    var fresh = FontCache()
    var reference = Canvas(160, 60, BG)
    reference.push_clip(20, 10, 60, 25)
    draw_text(reference, 6, 40, "Clipped", FG, 20.0, cache=fresh)
    reference.pop_clip()
    _assert_same_pixels(reference, clipped, "under a clip rect")
    for x in range(160):
        var p = clipped.get_pixel(x, 45)
        assert_equal(p.r, BG.r, "row 45 is outside the clip")

    var circle = Path()
    circle.ellipse(60.0, 32.0, 35.0, 22.0)
    var masked = Canvas(160, 60, BG)
    masked.push_clip_path(circle)
    draw_text(masked, 6, 40, "Clipped", FG, 20.0, cache=cache)
    masked.pop_clip()
    var fresh2 = FontCache()
    var reference2 = Canvas(160, 60, BG)
    reference2.push_clip_path(circle)
    draw_text(reference2, 6, 40, "Clipped", FG, 20.0, cache=fresh2)
    reference2.pop_clip()
    _assert_same_pixels(reference2, masked, "under a clip path")


def test_rotated_text_is_cached_at_its_orientation() raises:
    var cache = FontCache()
    var c = Canvas(120, 120, BG)
    draw_text(c, 20, 100, "Up", FG, 16.0, rotation=-pi / 2.0, cache=cache)
    var first = cache.glyph_mask_count()
    assert_true(first >= 2, "one mask per rotated glyph")
    var bbox = _ink_bbox(c, BG)
    assert_true(bbox.found_any, "and it renders")
    draw_text(c, 20, 100, "Up", FG, 16.0, rotation=-pi / 2.0, cache=cache)
    assert_equal(cache.glyph_mask_count(), first, "drawn again from the cache")
    # A different orientation is a different mask.
    draw_text(c, 20, 100, "Up", FG, 16.0, rotation=0.3, cache=cache)
    assert_true(cache.glyph_mask_count() > first, "keyed by orientation")


# Kerning. Every expected value below is DejaVu Sans at 64 px: it has
# 2048 units per em, so a design unit is 64/2048 = 1/32 px and every
# quantity here is an exact binary fraction, the reasoning
# test_measure_text_matches_known_glyph_extents gives for its numbers.
# The design-unit counts are the font's own, cross-checked by the
# Python oracle test_ttf.mojo's kerning tests use:
#
#     hmtx advance   A 1401   V 1401   T 1251   R 1423
#     GPOS pairs     AV -131  VA -131  AT -159  TA -159  AR 0


def test_kerning_pulls_a_kerned_pair_together() raises:
    # A 1401 + V 1401 = 2802 units = 87.5625 px of plain advance, and
    # the AV pair adjusts by -131 units = -4.09375 px, leaving
    # 83.46875. measure_text kerns by default.
    assert_equal(measure_text("A", 64.0).advance, 43.78125)
    assert_equal(measure_text("V", 64.0).advance, 43.78125)
    assert_equal(measure_text("AV", 64.0, kerning=False).advance, 87.5625)
    assert_equal(measure_text("AV", 64.0).advance, 83.46875)

    # The issue's own statement of the property: a kerned pair measures
    # narrower than its two characters measured apart.
    var apart = (
        measure_text("A", 64.0).advance + measure_text("V", 64.0).advance
    )
    assert_true(measure_text("AV", 64.0).advance < apart)


def test_kerning_off_restores_the_sum_of_advances() raises:
    # "AVATAR" kerns at four of its five pairs (-131, -131, -159, -159,
    # 0 = -580 units = -18.125 px), so the two settings are far apart;
    # with kerning off the total is exactly the per-character advances
    # added up, each measured on its own where no pair exists.
    var cache = FontCache()
    var text = String("AVATAR")
    var summed = 0.0
    for cp in text.codepoints():
        summed += measure_text(String(cp), 64.0, cache=cache).advance
    assert_equal(summed, 258.6875)
    assert_equal(
        measure_text(text, 64.0, kerning=False, cache=cache).advance, 258.6875
    )
    assert_equal(measure_text(text, 64.0, cache=cache).advance, 240.5625)
    assert_equal(258.6875 - 240.5625, 18.125)


def test_measure_and_draw_agree_on_a_kerned_string() raises:
    # The property the whole change turns on: one advance accumulation,
    # so a measured width and a rendered one cannot drift. Rendered
    # against measure_text_block's prediction, kerned and unkerned,
    # within the pixel or two of floor-rounding and AA fringe that
    # test_measure_text_block_matches_rendered_ink_unrotated allows.
    var cache = FontCache()
    var text = String("AVATAR")
    var anchor_x = 20

    var kerned = Canvas(400, 120, BG)
    draw_text(kerned, anchor_x, 90, text, FG, 64.0, cache=cache)
    var kerned_ink = _ink_bbox(kerned, BG)
    assert_true(kerned_ink.found_any)
    var kerned_box = measure_text_block(text, 64.0, cache=cache)
    var kerned_right = Float64(anchor_x) + kerned_box.x + kerned_box.width
    assert_true(
        kerned_right > Float64(kerned_ink.max_x) - 2.0
        and kerned_right < Float64(kerned_ink.max_x) + 2.0
    )

    var plain = Canvas(400, 120, BG)
    draw_text(plain, anchor_x, 90, text, FG, 64.0, kerning=False, cache=cache)
    var plain_ink = _ink_bbox(plain, BG)
    assert_true(plain_ink.found_any)
    var plain_box = measure_text_block(text, 64.0, kerning=False, cache=cache)
    var plain_right = Float64(anchor_x) + plain_box.x + plain_box.width
    assert_true(
        plain_right > Float64(plain_ink.max_x) - 2.0
        and plain_right < Float64(plain_ink.max_x) + 2.0
    )

    # Both renders start at the same place and the kerned one ends
    # earlier: the string tightens rather than shifting.
    assert_equal(kerned_ink.min_x, plain_ink.min_x)
    assert_true(kerned_ink.max_x < plain_ink.max_x)


def test_kerning_leaves_the_glyph_mask_cache_alone() raises:
    # Kerning moves the pen, not the glyph, so the mask cache is keyed
    # and filled as before: drawing the same kerned string twice adds
    # no entries the second time. The kerned and unkerned counts are
    # not compared, since a kerned pen lands on different sub-pixel
    # offsets and those are part of the key by design.
    var cache = FontCache()
    var text = String("AVATAR")

    var first = Canvas(400, 120, BG)
    draw_text(first, 20, 90, text, FG, 64.0, cache=cache)
    var after_first = cache.glyph_mask_count()
    assert_true(after_first > 0)

    var second = Canvas(400, 120, BG)
    draw_text(second, 20, 90, text, FG, 64.0, cache=cache)
    assert_equal(cache.glyph_mask_count(), after_first)
    _assert_same_pixels(first, second, "kerned redraw through a warm cache")


def _face_at(size: Float64, mut cache: FontCache) raises -> ArcPointer[TTFFace]:
    return cache.resolve_face("Sans", FontSlant.NORMAL, FontWeight.NORMAL, size)


def test_kerning_is_looked_up_between_logical_neighbours() raises:
    # A `GPOS` pair adjustment is stated for the pair as *written*, so
    # it has to be looked up as (logical i, logical i + 1) whichever way
    # the run draws. Where it lands then differs, and _apply_run_kerning
    # is the whole of that decision.
    #
    # "Ay" is the pair that makes a reversed lookup visible: DejaVu Sans
    # states -139 units for (A, y) and nothing at all for (y, A), so a
    # run that reversed its glyphs before looking the pair up would drop
    # the adjustment rather than merely move it. ("AV" would not show
    # it -- this font's class matrix answers -131 both ways round.)
    #
    # -139 units at 64 px is -139/32 = -4.34375 px exactly, since 2048
    # units per em puts a design unit at 1/32 px.
    var cache = FontCache()
    var face = _face_at(64.0, cache)
    var a = face[].glyph_index_for_codepoint(0x41)
    var y = face[].glyph_index_for_codepoint(0x79)
    assert_equal(face[].kern_adjustment(a, y), -139)
    assert_equal(face[].kern_adjustment(y, a), 0)

    # Left to right, logical order is drawing order: the adjustment
    # sits on the second of the two, the glyph a pass reaches second.
    var ltr: List[_ShapedGlyph] = [
        _ShapedGlyph(a, 0x41),
        _ShapedGlyph(y, 0x79),
    ]
    _apply_run_kerning(face[], ltr, False)
    assert_equal(ltr[0].kern_before, 0.0)
    assert_equal(ltr[1].kern_before, -4.34375)

    # Right to left, the same logical pair: reversing the run puts
    # logical 0 to the right of logical 1, so logical 0 is now the one a
    # pass reaches second and carries the adjustment. Same lookup, same
    # value, other glyph.
    var rtl: List[_ShapedGlyph] = [
        _ShapedGlyph(a, 0x41),
        _ShapedGlyph(y, 0x79),
    ]
    _apply_run_kerning(face[], rtl, True)
    assert_equal(rtl[0].kern_before, -4.34375)
    assert_equal(rtl[1].kern_before, 0.0)

    # Either way the run takes the same width, since the adjustment
    # moves the pen between the same two glyphs.
    assert_equal(
        ltr[0].kern_before + ltr[1].kern_before,
        rtl[0].kern_before + rtl[1].kern_before,
    )


def test_a_right_to_left_run_carries_its_kerning_reversed() raises:
    # The same rule through _shape_line, on a run that really is
    # right-to-left. DejaVu Sans states no pair adjustment between any
    # two of the 568 glyphs its Hebrew and Arabic blocks reach, so this
    # pins the wiring rather than a number: the glyphs come back
    # reversed, none of them invents an adjustment, and the advance is
    # the plain sum.
    var cache = FontCache()
    var face = _face_at(64.0, cache)
    var shaped = _shape_line(face[], "שלום", True, True)
    assert_equal(len(shaped), 4)

    # Reversed: the last character typed is drawn first.
    assert_equal(shaped[0].codepoint, 0x05DD)
    assert_equal(shaped[3].codepoint, 0x05E9)

    var total = 0.0
    for glyph in shaped:
        assert_equal(glyph.kern_before, 0.0)
        assert_equal(face[].kern_adjustment(glyph.glyph, shaped[0].glyph), 0)
        total += Float64(face[].advance_width(glyph.glyph)) / 32.0
    assert_equal(measure_text("שלום", 64.0, cache=cache).advance, total)


def test_kerning_off_leaves_every_glyph_unkerned() raises:
    # The `kerning` switch reaches the shaping step now, so it has to
    # zero `kern_before` rather than be re-read by each pass.
    var cache = FontCache()
    var face = _face_at(64.0, cache)
    var on = _shape_line(face[], "AVATAR", True, True)
    var off = _shape_line(face[], "AVATAR", True, False)
    assert_equal(len(on), len(off))
    var kerned_any = False
    for i in range(len(on)):
        assert_equal(on[i].glyph, off[i].glyph)
        assert_equal(off[i].kern_before, 0.0)
        if on[i].kern_before != 0.0:
            kerned_any = True
    assert_true(kerned_any)


def test_kerning_does_not_cross_a_bidi_run_boundary() raises:
    # A pair adjustment between two scripts' glyphs is not something a
    # font states, and the runs are shaped separately, so the first
    # glyph of each run starts unkerned. "AV שלום" is a Latin run then
    # a Hebrew one; the Latin part keeps its own kerning.
    var cache = FontCache()
    var face = _face_at(64.0, cache)
    var mixed = _shape_line(face[], "AV שלום", True, True)
    var latin = _shape_line(face[], "AV ", True, True)
    assert_equal(len(mixed), 7)
    for i in range(3):
        assert_equal(mixed[i].glyph, latin[i].glyph)
        assert_equal(mixed[i].kern_before, latin[i].kern_before)
    # A 0, V -131 units = -4.09375 px, space 0, then the Hebrew run.
    assert_equal(mixed[0].kern_before, 0.0)
    assert_equal(mixed[1].kern_before, -4.09375)
    assert_equal(mixed[2].kern_before, 0.0)
    assert_equal(mixed[3].kern_before, 0.0)


# Ligatures. Same font and size as the kerning tests above -- DejaVu
# Sans at 64 px, one design unit to 1/32 px -- so every value below is
# an exact binary fraction. The font's own numbers, read by the Python
# oracle test_ttf.mojo's tests use:
#
#     hmtx advance   f 721   i 569   l 569   A 1401   V 1401
#     liga glyphs    ff 1411   fi 1290   fl 1290   ffi 1980
#     GPOS pairs     Af -73   AV -131   ff 0   fi 0   Vf 0
#
# "ff" and "ffi" are the ligatures that narrow a string: each is 31
# units short of its components' advances added up. "fi" and "fl" are
# drawn as one glyph too, but their advance is exactly the sum, so
# they are the case where substitution shows in the pixels and not in
# the measurement.


def test_ligature_narrows_a_measured_string() raises:
    # f 721 + f 721 = 1442 units = 45.0625 px of plain advance against
    # the "ff" glyph's 1411 units = 44.09375, and f + f + i = 2011 =
    # 62.84375 against "ffi"'s 1980 = 61.875. measure_text substitutes
    # by default.
    assert_equal(measure_text("f", 64.0).advance, 22.53125)
    assert_equal(measure_text("i", 64.0).advance, 17.78125)
    assert_equal(measure_text("ff", 64.0, ligatures=False).advance, 45.0625)
    assert_equal(measure_text("ff", 64.0).advance, 44.09375)
    assert_equal(measure_text("ffi", 64.0, ligatures=False).advance, 62.84375)
    assert_equal(measure_text("ffi", 64.0).advance, 61.875)

    # The property the step turns on: a ligated string measures
    # narrower than its characters measured apart.
    var apart = (
        measure_text("f", 64.0).advance * 2.0 + measure_text("i", 64.0).advance
    )
    assert_equal(apart, 62.84375)
    assert_true(measure_text("ffi", 64.0).advance < apart)

    # "fi" ligates -- test_ttf.mojo pins the substitution itself -- and
    # measures the same either way, since this font gives the ligature
    # exactly its components' advance.
    assert_equal(measure_text("fi", 64.0).advance, 40.3125)
    assert_equal(measure_text("fi", 64.0, ligatures=False).advance, 40.3125)


def test_kerning_applies_between_the_substituted_glyphs() raises:
    # Substitution runs first, so a pair adjustment is looked up
    # between the glyphs that end up on the line. "Aff" unligated kerns
    # A against f by -73 units: 1401 + 721 + 721 - 73 = 2770 =
    # 86.5625 px. Ligated, A's right-hand neighbor is the "ff" glyph,
    # which this font kerns against nothing, so the -73 does not apply
    # and the string measures 1401 + 1411 = 2812 = 87.875 -- wider,
    # not narrower.
    var cache = FontCache()
    assert_equal(
        measure_text("Aff", 64.0, ligatures=False, cache=cache).advance,
        86.5625,
    )
    assert_equal(measure_text("Aff", 64.0, cache=cache).advance, 87.875)

    # A pair away from the ligature still kerns: "AVff" is A + V + the
    # "ff" glyph, 1401 + 1401 + 1411 = 4213 = 131.65625 unkerned, and
    # the AV pair's -131 leaves 4082 = 127.5625.
    assert_equal(
        measure_text("AVff", 64.0, kerning=False, cache=cache).advance,
        131.65625,
    )
    assert_equal(measure_text("AVff", 64.0, cache=cache).advance, 127.5625)

    # Neither switch on: the plain sum of four advances, 4244 units.
    assert_equal(
        measure_text(
            "AVff", 64.0, kerning=False, ligatures=False, cache=cache
        ).advance,
        132.625,
    )


def test_measure_and_draw_agree_on_a_ligated_string() raises:
    # One shaping step feeds both passes, so a measured width and a
    # rendered one cannot drift. Rendered against measure_text_block's
    # prediction, ligated and not, within the pixel or two of
    # floor-rounding and AA fringe that
    # test_measure_text_block_matches_rendered_ink_unrotated allows.
    var cache = FontCache()
    var text = String("ffi")
    var anchor_x = 20

    var ligated = Canvas(300, 120, BG)
    draw_text(ligated, anchor_x, 90, text, FG, 64.0, cache=cache)
    var ligated_ink = _ink_bbox(ligated, BG)
    assert_true(ligated_ink.found_any)
    var ligated_box = measure_text_block(text, 64.0, cache=cache)
    var ligated_right = Float64(anchor_x) + ligated_box.x + ligated_box.width
    assert_true(
        ligated_right > Float64(ligated_ink.max_x) - 2.0
        and ligated_right < Float64(ligated_ink.max_x) + 2.0
    )

    var plain = Canvas(300, 120, BG)
    draw_text(plain, anchor_x, 90, text, FG, 64.0, ligatures=False, cache=cache)
    var plain_ink = _ink_bbox(plain, BG)
    assert_true(plain_ink.found_any)
    var plain_box = measure_text_block(text, 64.0, ligatures=False, cache=cache)
    var plain_right = Float64(anchor_x) + plain_box.x + plain_box.width
    assert_true(
        plain_right > Float64(plain_ink.max_x) - 2.0
        and plain_right < Float64(plain_ink.max_x) + 2.0
    )

    # Both renders start at the same place and the ligated one ends
    # earlier: the string tightens rather than shifting.
    assert_equal(ligated_ink.min_x, plain_ink.min_x)
    assert_true(ligated_ink.max_x < plain_ink.max_x)


def test_a_ligature_gets_its_own_glyph_mask() raises:
    # The mask cache keys a substituted glyph by its glyph index and
    # everything else by codepoint, so "ffi" drawn as one glyph caches
    # one mask where the same string drawn as three characters caches
    # three -- the two "f"s land on different sub-pixel offsets, which
    # are part of the key by design, so neither shares with the other.
    var ligated_cache = FontCache()
    var ligated = Canvas(300, 120, BG)
    draw_text(ligated, 20, 90, "ffi", FG, 64.0, cache=ligated_cache)
    assert_equal(ligated_cache.glyph_mask_count(), 1)

    var plain_cache = FontCache()
    var plain = Canvas(300, 120, BG)
    draw_text(
        plain, 20, 90, "ffi", FG, 64.0, ligatures=False, cache=plain_cache
    )
    assert_equal(plain_cache.glyph_mask_count(), 3)

    # And the ligature's key is stable: the same string drawn again
    # through a warm cache adds nothing and paints the same pixels.
    var again = Canvas(300, 120, BG)
    draw_text(again, 20, 90, "ffi", FG, 64.0, cache=ligated_cache)
    assert_equal(ligated_cache.glyph_mask_count(), 1)
    _assert_same_pixels(ligated, again, "ligated redraw through a warm cache")


# Stroked text. `stroke_text` reuses draw_text's whole layout and
# swaps fill_path_aa for stroke_path_aa, so what is worth asserting is
# the difference between a filled glyph and its outline: an outline is
# ink at the glyph's edges and background in the middle of the wall
# between them, where the fill is solid.


def test_stroke_text_empty_string_is_noop() raises:
    var c = Canvas(40, 40, BG)
    stroke_text(c, 5.0, 20.0, "", FG, 24.0, width=2.0)
    _assert_canvas_untouched(c, BG, "empty string stroked something")


def test_stroke_text_outlines_the_glyph_rather_than_filling_it() raises:
    # "O" at 120 px: a wide counter and a wall thick enough that a
    # 2 px stroke centered on each contour leaves clear background
    # between the two.
    var cache = FontCache()
    var filled = Canvas(220, 200, BG)
    draw_text(filled, 20.0, 150.0, "O", FG, 120.0, cache=cache)
    var box = _ink_bbox(filled, BG)
    assert_true(box.found_any, "the filled reference drew something")

    # On the row through the middle of the glyph, walk the left wall:
    # the first inked pixel is the outer contour, the last of that run
    # is the inner one, and the middle of the run is solid fill.
    var row = (box.min_y + box.max_y) // 2
    var left_edge = box.min_x
    while left_edge <= box.max_x and _is_bg(filled, left_edge, row):
        left_edge += 1
    var wall_end = left_edge
    while wall_end <= box.max_x and not _is_bg(filled, wall_end, row):
        wall_end += 1
    wall_end -= 1
    assert_true(
        wall_end - left_edge >= 5,
        "the wall is thick enough for the assertion below to mean something",
    )
    var wall_mid = (left_edge + wall_end) // 2

    var stroked = Canvas(220, 200, BG)
    stroke_text(stroked, 20.0, 150.0, "O", FG, 120.0, width=2.0, cache=cache)

    # Ink on the contour the fill's left edge sits on -- within a
    # pixel either way, a 2 px stroke being centered on it.
    assert_true(
        not _is_bg(stroked, left_edge - 1, row)
        or not _is_bg(stroked, left_edge, row)
        or not _is_bg(stroked, left_edge + 1, row),
        "the stroke covers the glyph's outer contour",
    )
    # And nothing in the middle of the wall, which the fill covers
    # solidly.
    assert_true(not _is_bg(filled, wall_mid, row), "the fill covers the wall")
    assert_true(
        _is_bg(stroked, wall_mid, row),
        "the stroke leaves the middle of the wall empty",
    )
    # The counter -- the hole in the "O" -- is empty either way.
    var centre_x = (box.min_x + box.max_x) // 2
    assert_true(_is_bg(filled, centre_x, row), "the counter is a hole")
    assert_true(_is_bg(stroked, centre_x, row), "and stays one when stroked")


def test_stroke_text_matches_the_filled_bounding_box() raises:
    # The same layout drawn two ways, so the two boxes differ only by
    # the half stroke width the outline adds on each side plus its
    # anti-aliased fringe -- inside one stroke width on every edge.
    var cache = FontCache()
    var text = String("Handgloves")
    var filled = Canvas(400, 120, BG)
    draw_text(filled, 20.0, 90.0, text, FG, 48.0, cache=cache)
    var stroked = Canvas(400, 120, BG)
    stroke_text(stroked, 20.0, 90.0, text, FG, 48.0, width=2.0, cache=cache)

    var f = _ink_bbox(filled, BG)
    var s = _ink_bbox(stroked, BG)
    assert_true(f.found_any and s.found_any, "both drew something")
    assert_true(_within(s.min_x, f.min_x, 2), "left edges agree")
    assert_true(_within(s.max_x, f.max_x, 2), "right edges agree")
    assert_true(_within(s.min_y, f.min_y, 2), "top edges agree")
    assert_true(_within(s.max_y, f.max_y, 2), "bottom edges agree")


def test_stroke_text_rotated_90_swaps_ink_bbox_dimensions() raises:
    # Rotation is draw_text's, applied to the same placed outline
    # before it is stroked rather than filled.
    var cache = FontCache()
    var flat = Canvas(200, 200, BG)
    stroke_text(flat, 30.0, 120.0, "Axis", FG, 32.0, width=2.0, cache=cache)
    var turned = Canvas(200, 200, BG)
    stroke_text(
        turned,
        120.0,
        170.0,
        "Axis",
        FG,
        32.0,
        width=2.0,
        rotation=-pi / 2.0,
        cache=cache,
    )
    var f = _ink_bbox(flat, BG)
    var t = _ink_bbox(turned, BG)
    assert_true(f.found_any and t.found_any, "both drew something")
    assert_true(f.max_x - f.min_x > f.max_y - f.min_y, "the flat label is wide")
    assert_true(t.max_y - t.min_y > t.max_x - t.min_x, "the turned one is tall")


def test_stroke_text_leaves_the_glyph_mask_cache_alone() raises:
    # The mask cache holds a glyph's fill coverage; the outline around
    # that shape is a different figure, so stroking stores nothing and
    # reads nothing.
    var cache = FontCache()
    var c = Canvas(300, 120, BG)
    stroke_text(c, 20.0, 90.0, "Outline", FG, 48.0, width=2.0, cache=cache)
    assert_equal(cache.glyph_mask_count(), 0, "stroking caches no masks")
    assert_true(_ink_bbox(c, BG).found_any, "and still renders")


def _churn_glyphs(mut cache: FontCache, rounds: Int, size: Float64) raises:
    """Draw a word at `rounds` distinct sub-pixel anchors, which makes
    a new mask per call and is what drives the store past its bounds.
    """
    var canvas = Canvas(400, 200, BG)
    for i in range(rounds):
        var fx = 20.0 + Float64(i % 64) / 64.0
        var fy = 120.0 + Float64((i // 64) % 64) / 64.0
        draw_text(
            canvas, fx, fy, "Heading", Color(20, 30, 40), size, cache=cache
        )


def test_glyph_masks_turn_over_within_their_bounds() raises:
    # The store is bounded twice: by bytes, because a 200-pixel mask is
    # forty times a 12-pixel one and a count cannot tell them apart,
    # and by entries, because a dictionary of tens of thousands costs
    # more to probe than the hits it holds are worth.
    #
    # A label drawn throughout keeps its masks. Turning over releases
    # the older of two generations and a lookup moves an entry back to
    # the younger one, where clearing the whole store would have thrown
    # the label away and re-rasterized it on the next draw.
    var cache = FontCache()
    var canvas = Canvas(400, 120, BG)
    var ink = Color(20, 30, 40)
    draw_text(canvas, 10.0, 60.0, "Q3 revenue", ink, 13.0, cache=cache)
    var hot = cache.glyph_mask_count()
    assert_true(hot >= 8, "the hot label cached its glyphs")

    _churn_glyphs(cache, 300, 12.0)
    draw_text(canvas, 10.0, 60.0, "Q3 revenue", ink, 13.0, cache=cache)

    assert_true(
        cache.glyph_mask_turnovers() > 0,
        "the churn was large enough to force a turnover",
    )
    assert_true(
        cache.glyph_mask_bytes() <= _GLYPH_MASK_BUDGET,
        String(
            "glyph masks hold ",
            cache.glyph_mask_bytes(),
            " bytes, over the ",
            _GLYPH_MASK_BUDGET,
            " budget",
        ),
    )
    # Two generations of 2,048, so the store never holds more than
    # 4,096 however long the churn runs.
    assert_true(
        cache.glyph_mask_count() <= 4096,
        String("glyph masks grew to ", cache.glyph_mask_count()),
    )

    var before = cache.glyph_mask_count()
    draw_text(canvas, 10.0, 60.0, "Q3 revenue", ink, 13.0, cache=cache)
    assert_equal(
        cache.glyph_mask_count(),
        before,
        "a label drawn through the churn is still cached",
    )


def test_clear_glyph_masks_releases_them_and_keeps_faces() raises:
    var cache = FontCache()
    var canvas = Canvas(400, 120, BG)
    draw_text(
        canvas, 10.0, 60.0, "Release", Color(20, 30, 40), 16.0, cache=cache
    )
    assert_true(cache.glyph_mask_count() > 0, "masks were cached")
    var scanned = cache.has_scanned()
    cache.clear_glyph_masks()
    assert_equal(cache.glyph_mask_count(), 0, "masks released")
    assert_equal(cache.glyph_mask_bytes(), 0, "bytes released with them")
    assert_equal(cache.has_scanned(), scanned, "the font scan is kept")
    # And drawing again still works, from a cold mask store.
    var again = Canvas(400, 120, BG)
    draw_text(
        again, 10.0, 60.0, "Release", Color(20, 30, 40), 16.0, cache=cache
    )
    assert_true(cache.glyph_mask_count() > 0, "re-rasterized after the clear")


# --- prepared layouts (#294) ---------------------------------------
# A prepared layout has to be indistinguishable from laying the text
# out inside the call. Every test below renders or measures the same
# thing both ways and asserts they agree exactly -- there is no
# tolerance here, because the two paths share `_layout_block` and any
# difference would be a placement bug rather than a rounding one.


def _same_pixels(a: Canvas, b: Canvas, label: String) raises:
    assert_equal(a.width, b.width, label + " width")
    assert_equal(a.height, b.height, label + " height")
    var differing = 0
    for y in range(a.height):
        for x in range(a.width):
            var p = a.get_pixel(x, y)
            var q = b.get_pixel(x, y)
            if p.r != q.r or p.g != q.g or p.b != q.b or p.a != q.a:
                differing += 1
    assert_equal(differing, 0, label + ": differing pixels")


def _inked(c: Canvas) -> Int:
    var n = 0
    for y in range(c.height):
        for x in range(c.width):
            var p = c.get_pixel(x, y)
            if p.r != 255 or p.g != 255 or p.b != 255:
                n += 1
    return n


def test_measure_layout_matches_measure_text_block() raises:
    var cache = FontCache()
    var texts: List[String] = [
        "Revenue by region",
        "Revenue by region\nQ3 2026\nsource: internal",
        "",
        "   ",
    ]
    var aligns: List[TextAlign] = [
        TextAlign.LEFT,
        TextAlign.CENTER,
        TextAlign.RIGHT,
    ]
    for ti in range(len(texts)):
        for ai in range(len(aligns)):
            for ri in range(2):
                var rot = 0.0 if ri == 0 else 0.4
                ref t = texts[ti]
                var want = measure_text_block(
                    t, 14.0, rotation=rot, align=aligns[ai], cache=cache
                )
                var layout = prepare_text(
                    t, 14.0, rotation=rot, align=aligns[ai], cache=cache
                )
                var got = measure_layout(layout)
                var at = String("text ", ti, " align ", ai, " rot ", ri)
                assert_equal(got.x, want.x, at + " x")
                assert_equal(got.y, want.y, at + " y")
                assert_equal(got.width, want.width, at + " width")
                assert_equal(got.height, want.height, at + " height")


def test_draw_layout_matches_draw_text() raises:
    var cache = FontCache()
    var ink = Color(20, 30, 40)
    var text = String("Revenue by region\nQ3 2026 preliminary")
    var aligns: List[TextAlign] = [
        TextAlign.LEFT,
        TextAlign.CENTER,
        TextAlign.RIGHT,
    ]
    for ai in range(len(aligns)):
        for ri in range(2):
            var rot = 0.0 if ri == 0 else 0.35
            var direct = Canvas(320, 180, Color(255, 255, 255))
            draw_text(
                direct,
                60.0,
                80.0,
                text,
                ink,
                15.0,
                rotation=rot,
                align=aligns[ai],
                cache=cache,
            )
            var prepared = Canvas(320, 180, Color(255, 255, 255))
            var layout = prepare_text(
                text, 15.0, rotation=rot, align=aligns[ai], cache=cache
            )
            draw_layout(prepared, 60.0, 80.0, layout, ink, cache=cache)
            _same_pixels(prepared, direct, String("align ", ai, " rot ", ri))
            assert_true(_inked(direct) > 40, "the scene must draw ink")


def test_one_layout_draws_at_several_anchors() raises:
    """The layout is anchor-relative, which is the property that makes
    it worth keeping while a label's position is still being decided.
    """
    var cache = FontCache()
    var ink = Color(10, 10, 10)
    var text = String("Northwest 1,284")
    var xs: List[Float64] = [20.0, 90.5, 160.25]
    var ys: List[Float64] = [40.0, 90.0, 140.75]
    var direct = Canvas(320, 180, Color(255, 255, 255))
    for i in range(3):
        draw_text(direct, xs[i], ys[i], text, ink, 13.0, cache=cache)
    var prepared = Canvas(320, 180, Color(255, 255, 255))
    var layout = prepare_text(text, 13.0, cache=cache)
    for i in range(3):
        draw_layout(prepared, xs[i], ys[i], layout, ink, cache=cache)
    _same_pixels(prepared, direct, "three anchors")
    assert_true(_inked(direct) > 100, "three labels must draw ink")


def test_draw_layout_under_a_translated_canvas() raises:
    """A pure translation moves the anchor and keeps the layout, so
    the transform has to come off before the glyphs are written or it
    lands twice.
    """
    var cache = FontCache()
    var ink = Color(0, 0, 0)
    var text = String("Baseline")
    var direct = Canvas(320, 180, Color(255, 255, 255))
    direct.save()
    direct.translate(37.0, 21.0)
    draw_text(direct, 40.0, 60.0, text, ink, 14.0, cache=cache)
    direct.restore()
    var prepared = Canvas(320, 180, Color(255, 255, 255))
    prepared.save()
    prepared.translate(37.0, 21.0)
    var layout = prepare_text(text, 14.0, cache=cache)
    draw_layout(prepared, 40.0, 60.0, layout, ink, cache=cache)
    prepared.restore()
    _same_pixels(prepared, direct, "translated")
    assert_true(_inked(direct) > 20, "the label must draw ink")


def test_draw_layout_falls_back_under_a_rotated_canvas() raises:
    """A transform beyond a translation places glyphs through the
    matrix, so the prepared placement no longer applies and the call
    lays out again. The output still has to match exactly.
    """
    var cache = FontCache()
    var ink = Color(0, 0, 0)
    var text = String("Rotated")
    var direct = Canvas(320, 180, Color(255, 255, 255))
    direct.save()
    direct.rotate(0.25)
    direct.translate(30.0, 20.0)
    draw_text(direct, 40.0, 60.0, text, ink, 14.0, cache=cache)
    direct.restore()
    var prepared = Canvas(320, 180, Color(255, 255, 255))
    prepared.save()
    prepared.rotate(0.25)
    prepared.translate(30.0, 20.0)
    var layout = prepare_text(text, 14.0, cache=cache)
    draw_layout(prepared, 40.0, 60.0, layout, ink, cache=cache)
    prepared.restore()
    _same_pixels(prepared, direct, "rotated canvas")
    assert_true(_inked(direct) > 20, "the label must draw ink")


def test_empty_and_whitespace_layouts_draw_nothing() raises:
    var cache = FontCache()
    var blanks: List[String] = ["", "   ", "\n\n"]
    for i in range(len(blanks)):
        var layout = prepare_text(blanks[i], 14.0, cache=cache)
        assert_true(not layout.has_ink(), String("blank ", i, " has_ink"))
        var c = Canvas(80, 40, Color(255, 255, 255))
        draw_layout(c, 10.0, 20.0, layout, Color(0, 0, 0), cache=cache)
        assert_equal(_inked(c), 0, String("blank ", i, " drew ink"))
        var m = measure_layout(layout)
        assert_equal(m.width, 0.0, String("blank ", i, " width"))
        assert_equal(m.height, 0.0, String("blank ", i, " height"))


def test_layout_pins_the_inputs_that_shaped_it() raises:
    """The pinned fields are what a caller checks a cached layout
    against before reusing it, so they have to read back."""
    var cache = FontCache()
    var layout = prepare_text(
        "Sales",
        17.0,
        family="Sans",
        weight=FontWeight.BOLD,
        rotation=0.5,
        align=TextAlign.CENTER,
        kerning=False,
        ligatures=False,
        cache=cache,
    )
    assert_equal(layout.text, "Sales")
    assert_equal(layout.size, 17.0)
    assert_equal(layout.family, "Sans")
    assert_true(layout.weight == FontWeight.BOLD, "weight")
    assert_equal(layout.rotation, 0.5)
    assert_true(layout.align == TextAlign.CENTER, "align")
    assert_true(not layout.kerning, "kerning")
    assert_true(not layout.ligatures, "ligatures")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
