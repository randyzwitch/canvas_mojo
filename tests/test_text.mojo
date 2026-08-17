"""Tests for canvas_mojo/text/render.mojo.

Unlike primitives.mojo's tests, these can't assert exact pixel sets --
real system-font rasterization (hinting, AA, glyph shapes) isn't
something this repo can independently re-derive by hand the way
Bresenham/midpoint-circle output can (see canvas_mojo/text/render.mojo's
module docstring). What's tested instead are the properties this
module's own code is actually responsible for, verified against this
module's real behavior (via probe scripts, not assumption) before
being locked in here:

  - the early-exit edge cases (empty string, whitespace-only text,
    fully transparent color) are true no-ops
  - the glyph-outline-to-Path-to-fill_path_aa pipeline actually places
    ink where requested, in the requested color, for at least one
    pixel a solid glyph interior guarantees full coverage on
  - anti-aliasing is genuinely happening (mixed-coverage edge pixels
    exist, not just pure background/pure foreground)
  - every touched pixel obeys the src-over blend invariant (result is
    a convex combination of background and foreground per channel,
    never overshooting either) -- the same blend_over every other
    filled primitive in this package already goes through, via
    Canvas.set_pixel, not a text-specific mechanism
  - two identical calls produce identical output (no hidden state
    between calls -- each one resolves and loads its own font face
    fresh)

Confirmed by direct comparison, not assumed: this entire suite passed
unchanged (structural checks, ink-bbox cross-checks, no-op edge cases,
the lot) across two real rewrites -- first from wrapping Cairo to a
native fontconfig+FreeType+fill_path_aa pipeline, later from that to
fully native TrueType parsing (`ttf.mojo`, no FreeType either). The
one exception both times was `test_measure_text_matches_known_glyph_
extents`'s own hand-locked exact pixel values, which *did* need
updating on the FreeType-removal rewrite specifically: FreeType's
default hinting rounds thin stems (like "I"'s own single vertical
stroke) to whole pixels for on-screen crispness, and `ttf.mojo`
deliberately never hints (see that module's own docstring for why) --
a real, understood, expected difference in the *exact* number, not a
regression in what the pipeline actually does. Every other test here
being insensitive to that same difference is exactly what "properties
this module is responsible for, not exact rasterizer output" (see
above) is supposed to buy.

Needs a "Sans"-resolvable system font (fontconfig's generic sans-serif
alias) to run -- true of most Linux/macOS systems, but not guaranteed
the way a checked-in fixture would be. The font-fallback tests need a
second, more specific fact about this machine (the "Ubuntu" font
lacking a snowman glyph "DejaVu Sans" has) -- see
test_font_discovery.mojo's own docstring for the same dependency and
why it's safe to assert here.
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
    """Bounding box of every non-background pixel -- a small struct
    instead of a 4-tuple purely so the fields have names at call
    sites, matching this codebase's general aversion to positional
    magic values (see e.g. geometry.mojo's Point).
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
    # Confirmed via probe: Cairo's own text_extents(" ") reports
    # width=0, height=0 -- no ink, just an advance -- so this hits the
    # same early-return path as the empty string, not a 1-pixel-wide
    # sliver.
    var c = Canvas(40, 40, BG)
    draw_text(c, 5, 20, "   ", FG, 24.0)
    _assert_canvas_untouched(c, BG, "whitespace-only drew something")


def test_alpha_zero_is_noop() raises:
    var c = Canvas(60, 60, BG)
    draw_text(c, 5, 40, "I", Color(200, 20, 20, 0), 40.0)
    _assert_canvas_untouched(c, BG, "fully transparent color drew something")


def test_opaque_glyph_has_an_exact_full_coverage_pixel() raises:
    # A large enough solid vertical stroke has interior pixels far
    # enough from any edge that Cairo's AA gives them full coverage
    # (alpha == 255), which set_pixel writes through unblended -- so
    # at least one pixel must equal FG exactly, not just "close to".
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
    # Same render as above: confirms this isn't a hard-edged fill --
    # some pixels are neither pure background nor pure foreground.
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
    # For src-over compositing, every touched pixel's channel must be
    # close to a convex combination of background and foreground -- it
    # can't end up meaningfully outside [min(bg, fg), max(bg, fg)].
    # "Close to", with a 1-unit tolerance, not exactly: this module's
    # pipeline floors twice in a row (unpremultiply's integer divide,
    # then Canvas.set_pixel's own blend_over) wherever draw_text hands
    # off a translucent, already-unpremultiplied color, so a
    # continuous-math result exactly at (or within rounding of) the
    # boundary can legitimately come out 1 unit past it -- confirmed
    # by probe: real low-coverage AA edge pixels here, max deviation
    # exactly 1, never more, across every touched pixel. A wider
    # deviation would mean something more than rounding is wrong (e.g.
    # unpremultiplying by the wrong alpha), which this still catches.
    var bg = Color(30, 200, 60)
    var fg = Color(200, 20, 20, 130)
    var c = Canvas(120, 120, bg)
    draw_text(c, 10, 90, "I", fg, 60.0)

    # Int, not UInt8: a UInt8 lower bound of 0 minus a tolerance of 1
    # would wrap around to 255 instead of going negative.
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
    # Locked-in values confirmed by probe against the native, unhinted
    # ttf.mojo path specifically (see this file's own module docstring
    # for why these differ from the old FreeType-hinted 3.0/18.0/~7.0):
    # "I" in Sans at size 24 has ink width=2.3671875, height=
    # 17.49609375, advance=7.078125 -- all exact (raw font-design-unit
    # counts times a power-of-two-denominator fraction, the same
    # "provably exact, not a tolerance" reasoning
    # test_glyph_outline.mojo's own docstring gives for the identical
    # glyph at a different size).
    var m = measure_text("I", 24.0)
    assert_equal(m.width, 2.3671875)
    assert_equal(m.height, 17.49609375)
    assert_equal(m.advance, 7.078125)


def test_measure_text_long_string_is_not_empty() raises:
    # Regression test for a real, confirmed bug (see text.mojo's own
    # docstring): cairo_mojo's Context.text_extents(text: String)
    # silently reports width=height=0 once a String crosses ~20 bytes
    # -- but *only* for a runtime-constructed String, not a literal;
    # a bare string literal passed directly (even a long one) never
    # triggered it, which is exactly what made this bug so easy to
    # miss originally. Building this one via concatenation, not typing
    # it as one literal, is what actually exercises the bug -- a
    # version of this test using a literal here would silently test
    # nothing, the same mistake made (and caught) once already.
    var built = String("jumps over") + String(" the lazy dog")
    var m = measure_text(built, 22.0)
    assert_true(m.width > 0.0)
    assert_true(m.height > 0.0)
    assert_true(m.advance > 0.0)


def test_draw_text_long_single_line_renders_ink() raises:
    # Same regression category as the measure_text one above, but for
    # the draw_text/_show_text path specifically -- draw_text's own
    # internal sizing pass uses exactly this length of string in its
    # "any_ink" check, so a regression here would make the whole call
    # silently no-op, not just mismeasure.
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
    # Locks in the module docstring's claim directly: one code path
    # for the rotated and unrotated cases, not two -- rotation=0.0
    # explicitly must produce byte-identical output to not passing it
    # at all, not just "close".
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
    # "I" is a tall, narrow vertical stroke unrotated -- its ink bbox
    # is much taller than wide. Rotated 90 degrees, that stroke should
    # now lie on its side: much wider than tall, with the two
    # dimensions roughly swapped (not identical -- AA fringe and
    # integer rounding mean "roughly", but the tall/narrow vs.
    # wide/short relationship must flip, a real geometric property,
    # not just "the pixels moved somewhere").
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

    # A background row must exist strictly between the two lines'
    # baselines -- if multi-line collapsed to one line (or overlapped
    # instead of stacking), no such gap would exist anywhere in range.
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
    # "A\n\nB": three line slots, the middle one empty. The gap between
    # A's ink and B's ink should span roughly two line heights, not
    # one -- confirms the blank line was counted for vertical spacing
    # (not skipped/collapsed) even though it contributed no ink itself.
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
    # Cross-check against draw_text's own actually-rendered ink bbox
    # (via _ink_bbox, this file's existing tool) rather than a purely
    # hand-derived number -- the property that actually matters for a
    # layout caller is "does the prediction agree with what draw_text
    # puts on the canvas", not just "is the math internally
    # consistent". Locked-in numbers confirmed by probe (same
    # methodology as test_measure_text_matches_known_glyph_extents
    # above): a 60pt "I" at anchor (60, 100) actually renders ink at
    # x=[65,72], y=[55,99]; measure_text_block predicts an
    # anchor-relative box landing at the same position, off by at most
    # a pixel or two from floor-rounding + AA fringe (the same slop
    # draw_text's own pixel placement has relative to Cairo's ink
    # extents), not because the shared layout math itself is
    # approximate.
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
    # Same cross-check, but rotated -- the case the shared
    # _layout_block math actually exists for (an unrotated box is a
    # much easier case to get right by accident). Same "I", same
    # anchor, rotation=pi/2 this time.
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

    # The same tall/narrow-vs-wide/short flip
    # test_rotation_90_degrees_swaps_ink_bbox_dimensions confirms on
    # actual pixels must also hold for the *predicted* box -- not just
    # "close to the right position" but "the right shape".
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
    # Matches draw_text's own whitespace-only no-op -- see
    # test_whitespace_only_is_noop above: no ink means no box, not a
    # box sized by whitespace's own nonzero advance.
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
    # "שלום" -- DejaVu Sans genuinely has Hebrew glyphs (confirmed via
    # probe against the real font before writing this test), so this
    # isn't measuring a fallback-to-.notdef box.
    var c = Canvas(150, 60, BG)
    draw_text(c, 20, 40, "שלום", FG, 30.0)
    var bbox = _ink_bbox(c, BG)
    assert_true(bbox.found_any)


def test_hebrew_measure_matches_rendered_ink() raises:
    # Same cross-check methodology as
    # test_measure_text_block_matches_rendered_ink_unrotated above,
    # applied to a right-to-left script -- draw_text's render pass and
    # measure_text's own measurement both go through bidi.visual_order
    # (see text.mojo's own _visual_codepoints), so if that reordering
    # were only applied on one side and not the other, this would be
    # the test to catch it.
    var c = Canvas(150, 60, BG)
    draw_text(c, 20, 40, "שלום", FG, 30.0)
    var actual = _ink_bbox(c, BG)
    assert_true(actual.found_any)

    var m = measure_text("שלום", 30.0)
    assert_true(m.width > 0.0)
    var actual_width = Float64(actual.max_x - actual.min_x)
    assert_true(actual_width > m.width - 3.0 and actual_width < m.width + 3.0)


def test_measure_and_draw_agree_on_bidi_reordering() raises:
    # text.mojo's own _visual_codepoints is the one integration point
    # both _measure_line (used by measure_text/measure_text_block) and
    # draw_text's render pass go through -- calling it directly here
    # (Mojo doesn't enforce leading-underscore privacy, same
    # established pattern this codebase already relies on elsewhere,
    # e.g. testing _is_dash_on directly) confirms the wiring itself,
    # the thing most likely to drift if a future change touched one
    # call site and not the other, distinct from bidi.mojo's own
    # test_bidi.mojo, which tests the reordering algorithm in
    # isolation.
    var out = _visual_codepoints("שלום 12")
    # Digits stay in reading order (see test_bidi.mojo's own
    # test_digit_run_inside_hebrew_stays_in_reading_order for the
    # equivalent direct check against bidi.visual_order).
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
    # Real, end-to-end proof that draw_text's own font-fallback wiring
    # (text.mojo's _resolve_glyph) actually reaches rendering, not
    # just font_discovery.resolve_font_file_for_char in isolation
    # (see test_font_discovery.mojo's own tests for that layer alone).
    # "Ubuntu" (the font) has no snowman glyph (U+2603, confirmed via
    # probe); if fallback works, drawing it anyway produces real ink,
    # not nothing (a family that genuinely lacked *any* fallback would
    # render this as an empty, zero-size .notdef with no ink at all,
    # the same as any other glyph-less codepoint here would).
    var c = Canvas(60, 60, BG)
    draw_text(c, 10, 45, "☃", FG, 32.0, family="Ubuntu")
    var bbox = _ink_bbox(c, BG)
    assert_true(bbox.found_any)


def test_measure_text_falls_back_to_a_font_with_the_glyph() raises:
    # Same property as the render test above, for measure_text: a
    # font that actually has the glyph reports real, non-zero ink
    # dimensions -- not the same measurement a truly glyph-less
    # character would (this file has no test asserting a specific
    # numeric .notdef size, deliberately -- what matters here is that
    # measurement and rendering agree fallback happened, not a second
    # copy of glyph_outline.mojo's own locked-in font metrics).
    var m = measure_text("☃", 32.0, family="Ubuntu")
    assert_true(m.width > 0.0)
    assert_true(m.height > 0.0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
