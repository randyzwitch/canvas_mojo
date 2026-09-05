"""Tests for canvas/text/joining.mojo, and for the Arabic shaping
`render.mojo` and `ttf.mojo` build on it.

Two layers, as the kerning and ligature steps before it:

- The joining classifier on hand-built codepoint sequences, where
  every expected form is worked out from the Unicode rule rather than
  read back out of the code. Sequences use real letters so a reader can
  check the joining type against `ArabicShaping.txt`: beh U+0628 and
  seen U+0633 are dual-joining, alef U+0627 and dal U+062F are
  right-joining, fatha U+064E is transparent, tatweel U+0640 is
  join-causing, and ZWJ U+200D / ZWNJ U+200C are join-causing /
  non-joining.
- Real-font shaping, which needs a "Sans"-resolvable system font
  (DejaVu Sans on this machine and in CI). Its `arab` script carries
  `init`/`medi`/`fina` single substitutions and `rlig` ligatures but
  no `isol` feature, so an isolated letter keeps its base glyph.

Every shaped glyph id is checked against an independent route to the
same glyph rather than hard-coded: DejaVu Sans also maps the Arabic
Presentation Forms-B block (U+FE70..U+FEFF) in `cmap`, one codepoint
per form, and `GSUB` substitutes to those same glyphs. So "beh
initial" is asserted as `cmap(U+FE91)`, which no part of the shaping
path produced.
"""

from std.testing import assert_equal, assert_not_equal, assert_true, TestSuite

from canvas.buffer import Canvas
from canvas.color import Color
from canvas.text.font_cache import FontCache
from canvas.text.font_discovery import FontSlant, FontWeight, resolve_font_file
from canvas.text.joining import (
    is_arabic,
    joining_forms,
    joining_type,
    _FORM_FINAL,
    _FORM_INITIAL,
    _FORM_ISOLATED,
    _FORM_MEDIAL,
    _FORM_NONE,
    _JOIN_CAUSING,
    _JOIN_DUAL,
    _JOIN_NON,
    _JOIN_RIGHT,
    _JOIN_TRANSPARENT,
)
from canvas.text.render import draw_text, measure_text, _shape_line
from canvas.text.ttf import TTFFace

comptime BG = Color(255, 255, 255)
comptime FG = Color(0, 0, 0)

# The letters the form tests are built from.
comptime BEH = 0x0628
comptime SEEN = 0x0633
comptime MEEM = 0x0645
comptime HAH = 0x062D
comptime LAM = 0x0644
comptime ALEF = 0x0627
comptime DAL = 0x062F
comptime FATHA = 0x064E
comptime TATWEEL = 0x0640
comptime ZWJ = 0x200D
comptime ZWNJ = 0x200C


def _sans_face() raises -> TTFFace:
    """The "Sans" face at 64 px, the size every measurement below is
    computed at. The size has to be set here rather than per test:
    `_shape_line` kerns as it shapes, and a pair adjustment is scaled
    to pixels through the face's active size.
    """
    var path = resolve_font_file("Sans")
    var face = TTFFace(path)
    face.set_pixel_size(64)
    return face^


struct _Box(ImplicitlyCopyable, Movable):
    """Bounding box of every non-background pixel."""

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


def _ink_bbox(c: Canvas, bg: Color) -> _Box:
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
    return _Box(min_x, max_x, min_y, max_y, found_any)


# --- the joining classifier ----------------------------------------


def test_joining_types_match_the_unicode_property() raises:
    # Spot checks against ArabicShaping.txt, one per class the table
    # encodes.
    assert_equal(joining_type(BEH), _JOIN_DUAL)
    assert_equal(joining_type(SEEN), _JOIN_DUAL)
    assert_equal(joining_type(ALEF), _JOIN_RIGHT)
    assert_equal(joining_type(DAL), _JOIN_RIGHT)
    assert_equal(joining_type(FATHA), _JOIN_TRANSPARENT)
    assert_equal(joining_type(TATWEEL), _JOIN_CAUSING)
    assert_equal(joining_type(ZWJ), _JOIN_CAUSING)
    # ZWNJ is Cf, so the file's default would make it transparent; it
    # is listed explicitly as non-joining, which is the whole point of
    # the character.
    assert_equal(joining_type(ZWNJ), _JOIN_NON)
    # Arabic-Indic digit zero, a space, and a Latin letter: all outside
    # the cursive alphabet.
    assert_equal(joining_type(0x0660), _JOIN_NON)
    assert_equal(joining_type(0x0020), _JOIN_NON)
    assert_equal(joining_type(0x0041), _JOIN_NON)
    # The first and last entries of the Arabic Supplement and Arabic
    # Extended-A ranges, which the table covers past the main block.
    assert_equal(joining_type(0x0750), _JOIN_DUAL)
    assert_equal(joining_type(0x077F), _JOIN_DUAL)
    assert_equal(joining_type(0x08A0), _JOIN_DUAL)
    assert_equal(joining_type(0x08AA), _JOIN_RIGHT)
    # A presentation form encodes its shape rather than taking one.
    assert_equal(joining_type(0xFE91), _JOIN_NON)


def test_is_arabic_selects_the_blocks_the_arab_script_covers() raises:
    assert_true(is_arabic(BEH))
    assert_true(is_arabic(0x0750))
    assert_true(is_arabic(0x08A0))
    assert_true(is_arabic(0xFB50))
    assert_true(is_arabic(0xFE91))
    assert_true(not is_arabic(0x0041))
    # Hebrew is right-to-left but not cursive, and its lookups hang off
    # the `hebr` script.
    assert_true(not is_arabic(0x05D0))


def test_three_dual_joiners_take_init_medi_fina() raises:
    # Each of the three joins on both sides, so the first has only a
    # follower (initial), the middle has both (medial), and the last
    # has only a predecessor (final).
    var forms = joining_forms([BEH, SEEN, MEEM])
    assert_equal(forms[0], _FORM_INITIAL)
    assert_equal(forms[1], _FORM_MEDIAL)
    assert_equal(forms[2], _FORM_FINAL)


def test_a_lone_letter_is_isolated() raises:
    var dual = joining_forms([BEH])
    assert_equal(dual[0], _FORM_ISOLATED)
    var right = joining_forms([ALEF])
    assert_equal(right[0], _FORM_ISOLATED)


def test_a_right_joiner_ends_a_word_and_never_starts_one() raises:
    # D then R: the R joins backwards, so the D has a follower to join
    # (initial) and the R has a predecessor (final).
    var forward = joining_forms([BEH, ALEF])
    assert_equal(forward[0], _FORM_INITIAL)
    assert_equal(forward[1], _FORM_FINAL)

    # R then D: the R cannot join forwards, so neither has a neighbor
    # to join and both stay isolated. This is why "الا" (alef, lam,
    # alef) breaks after the first alef.
    var backward = joining_forms([ALEF, BEH])
    assert_equal(backward[0], _FORM_ISOLATED)
    assert_equal(backward[1], _FORM_ISOLATED)

    # And a right-joiner between two dual-joiners takes the join on its
    # right side only, cutting the word in two: the D before it is
    # medial or initial, the D after it starts a fresh word.
    var middle = joining_forms([BEH, DAL, SEEN])
    assert_equal(middle[0], _FORM_INITIAL)
    assert_equal(middle[1], _FORM_FINAL)
    assert_equal(middle[2], _FORM_ISOLATED)


def test_a_transparent_mark_does_not_break_a_join() raises:
    # A fatha between two letters is skipped when each looks for its
    # neighbor, so the pair joins exactly as if the mark were absent.
    var marked = joining_forms([BEH, FATHA, SEEN])
    assert_equal(marked[0], _FORM_INITIAL)
    assert_equal(marked[1], _FORM_NONE)
    assert_equal(marked[2], _FORM_FINAL)

    var unmarked = joining_forms([BEH, SEEN])
    assert_equal(marked[0], unmarked[0])
    assert_equal(marked[2], unmarked[1])

    # Several marks in a row are skipped the same way, and a mark at
    # either end leaves the letter beside it with no neighbor at all.
    var ends = joining_forms([FATHA, BEH, FATHA, FATHA, SEEN, FATHA])
    assert_equal(ends[0], _FORM_NONE)
    assert_equal(ends[1], _FORM_INITIAL)
    assert_equal(ends[4], _FORM_FINAL)
    assert_equal(ends[5], _FORM_NONE)


def test_zwj_forces_a_join_and_zwnj_breaks_one() raises:
    # ZWJ joins on both sides without drawing anything, so a letter
    # beside it shapes as if a letter were there. This is how an
    # isolated medial form is written down.
    var after = joining_forms([ZWJ, BEH, ZWJ])
    assert_equal(after[1], _FORM_MEDIAL)
    var trailing = joining_forms([BEH, ZWJ])
    assert_equal(trailing[0], _FORM_INITIAL)
    var leading = joining_forms([ZWJ, BEH])
    assert_equal(leading[0], _FORM_NONE)
    assert_equal(leading[1], _FORM_FINAL)

    # ZWNJ is non-joining, so it breaks a join two letters would
    # otherwise make.
    var broken = joining_forms([BEH, ZWNJ, SEEN])
    assert_equal(broken[0], _FORM_ISOLATED)
    assert_equal(broken[1], _FORM_NONE)
    assert_equal(broken[2], _FORM_ISOLATED)


def test_tatweel_joins_on_both_sides_and_takes_no_form() raises:
    # The tatweel is a bare join, drawn as a stretch of baseline. It
    # causes joining like ZWJ but is a visible glyph, and takes no
    # contextual form of its own.
    var forms = joining_forms([BEH, TATWEEL, SEEN])
    assert_equal(forms[0], _FORM_INITIAL)
    assert_equal(forms[1], _FORM_NONE)
    assert_equal(forms[2], _FORM_FINAL)


def test_a_space_breaks_a_word_into_two() raises:
    # Non-joining characters end a word without being part of one.
    var forms = joining_forms([BEH, SEEN, 0x20, MEEM, HAH])
    assert_equal(forms[0], _FORM_INITIAL)
    assert_equal(forms[1], _FORM_FINAL)
    assert_equal(forms[2], _FORM_NONE)
    assert_equal(forms[3], _FORM_INITIAL)
    assert_equal(forms[4], _FORM_FINAL)


def test_empty_and_non_arabic_sequences_have_no_forms() raises:
    var empty = joining_forms(List[Int]())
    assert_equal(len(empty), 0)
    var latin = joining_forms([0x41, 0x42, 0x43])
    assert_equal(len(latin), 3)
    for form in latin:
        assert_equal(form, _FORM_NONE)


# --- shaping through a real font -------------------------------------


def test_bism_shapes_to_the_initial_medial_and_final_forms() raises:
    # "بسم" -- beh, seen, meem, all dual-joining, so init/medi/fina.
    # Each expected glyph comes from the Presentation Forms-B cmap
    # entry for that form, not from the shaper: U+FE91 beh initial,
    # U+FEB4 seen medial, U+FEE2 meem final.
    var face = _sans_face()
    var beh_init = face.glyph_index_for_codepoint(0xFE91)
    var seen_medi = face.glyph_index_for_codepoint(0xFEB4)
    var meem_fina = face.glyph_index_for_codepoint(0xFEE2)
    var beh_isol = face.glyph_index_for_codepoint(BEH)
    var seen_isol = face.glyph_index_for_codepoint(SEEN)
    var meem_isol = face.glyph_index_for_codepoint(MEEM)
    # The two routes have to name different glyphs for the assertion
    # below to say anything.
    assert_true(beh_init != 0 and seen_medi != 0 and meem_fina != 0)
    assert_not_equal(beh_init, beh_isol)
    assert_not_equal(seen_medi, seen_isol)
    assert_not_equal(meem_fina, meem_isol)

    # Arabic draws right to left, so the shaped line comes back with
    # the last letter first.
    var shaped = _shape_line(face, "بسم", True, True)
    assert_equal(len(shaped), 3)
    assert_equal(shaped[0].glyph, meem_fina)
    assert_equal(shaped[1].glyph, seen_medi)
    assert_equal(shaped[2].glyph, beh_init)


def test_muhammad_shapes_to_two_medial_forms() raises:
    # "محمد" -- meem, hah, meem, dal. The dal is right-joining, so it
    # ends the word as a final form and the meem before it is still
    # medial: init, medi, medi, fina.
    var face = _sans_face()
    var meem_init = face.glyph_index_for_codepoint(0xFEE3)
    var hah_medi = face.glyph_index_for_codepoint(0xFEA4)
    var meem_medi = face.glyph_index_for_codepoint(0xFEE4)
    var dal_fina = face.glyph_index_for_codepoint(0xFEAA)
    assert_true(meem_init != 0 and hah_medi != 0)
    assert_true(meem_medi != 0 and dal_fina != 0)
    assert_not_equal(meem_init, meem_medi)

    var shaped = _shape_line(face, "محمد", True, True)
    assert_equal(len(shaped), 4)
    assert_equal(shaped[0].glyph, dal_fina)
    assert_equal(shaped[1].glyph, meem_medi)
    assert_equal(shaped[2].glyph, hah_medi)
    assert_equal(shaped[3].glyph, meem_init)


def test_an_isolated_letter_keeps_its_base_glyph() raises:
    # DejaVu Sans's `arab` script has no `isol` feature -- the base
    # glyph already is the isolated form -- so an unjoined letter comes
    # through unsubstituted, and keeps its codepoint with it.
    var face = _sans_face()
    var shaped = _shape_line(face, "ا", True, True)
    assert_equal(len(shaped), 1)
    assert_equal(shaped[0].glyph, face.glyph_index_for_codepoint(ALEF))
    assert_equal(shaped[0].codepoint, ALEF)


def test_lam_alef_ligates_from_the_forms_not_the_letters() raises:
    # "لا" -- lam then alef, which every Arabic font draws as one
    # glyph. The font keys that ligature on the lam's *initial* form
    # (U+FEDF), so it only matches once the joining features have run:
    # this is the assertion that pins `rlig` after `init`.
    var face = _sans_face()
    var lam_init = face.glyph_index_for_codepoint(0xFEDF)
    var lam_alef = face.glyph_index_for_codepoint(0xFEFB)
    assert_true(lam_init != 0 and lam_alef != 0)

    var shaped = _shape_line(face, "لا", True, True)
    assert_equal(len(shaped), 1)
    assert_equal(shaped[0].glyph, lam_alef)
    # A ligature stands for two characters, so no codepoint names it.
    assert_equal(shaped[0].codepoint, -1)

    # "الا" -- an alef in front cannot join forwards, so the lam still
    # starts a word and the ligature still forms, behind an isolated
    # alef.
    var with_alef = _shape_line(face, "الا", True, True)
    assert_equal(len(with_alef), 2)
    assert_equal(with_alef[0].glyph, lam_alef)
    assert_equal(with_alef[1].glyph, face.glyph_index_for_codepoint(ALEF))


def test_shaping_off_restores_the_isolated_forms() raises:
    # ligatures=False lays out one glyph per character, which for
    # Arabic is the isolated letters, still in right-to-left order.
    var face = _sans_face()
    var shaped = _shape_line(face, "بسم", False, True)
    assert_equal(len(shaped), 3)
    assert_equal(shaped[0].glyph, face.glyph_index_for_codepoint(MEEM))
    assert_equal(shaped[1].glyph, face.glyph_index_for_codepoint(SEEN))
    assert_equal(shaped[2].glyph, face.glyph_index_for_codepoint(BEH))

    # And the lam-alef ligature does not form either.
    var pair = _shape_line(face, "لا", False, True)
    assert_equal(len(pair), 2)
    assert_equal(pair[0].glyph, face.glyph_index_for_codepoint(ALEF))
    assert_equal(pair[1].glyph, face.glyph_index_for_codepoint(LAM))


def test_joined_forms_measure_narrower_than_isolated_ones() raises:
    # Exact, not toleranced: DejaVu Sans is 2048 units per em, so at
    # 64 px a design unit is 64/2048 = 1/32 px and every advance is an
    # exact binary fraction.
    #
    # Joined  "بسم":  beh init 570 + seen medi 1827 + meem fina 1363
    #                 = 3760 units = 117.5 px
    # Isolated       : beh 1928 + seen 2500 + meem 1268
    #                 = 5696 units = 178.0 px
    #
    # DejaVu Sans states no pair kerning for Arabic, so both are the
    # plain sum of `hmtx` advances.
    var joined = measure_text("بسم", 64.0)
    assert_equal(joined.advance, 117.5)
    var isolated = measure_text("بسم", 64.0, ligatures=False)
    assert_equal(isolated.advance, 178.0)

    # And the same for the lam-alef ligature: one 1168-unit glyph
    # against lam 1488 + alef 569 = 2057 units.
    var ligated = measure_text("لا", 64.0)
    assert_equal(ligated.advance, 36.5)
    var unligated = measure_text("لا", 64.0, ligatures=False)
    assert_equal(unligated.advance, 64.28125)


def test_the_advance_is_the_sum_of_the_shaped_glyphs() raises:
    # The same numbers derived a second way: the advance measure_text
    # reports is what the presentation-form glyphs sum to in `hmtx`,
    # with no term the shaping path chose for itself.
    var face = _sans_face()
    var units = (
        face.advance_width(face.glyph_index_for_codepoint(0xFE91))
        + face.advance_width(face.glyph_index_for_codepoint(0xFEB4))
        + face.advance_width(face.glyph_index_for_codepoint(0xFEE2))
    )
    assert_equal(units, 3760)
    assert_equal(measure_text("بسم", 64.0).advance, Float64(units) / 32.0)


def test_measure_and_draw_agree_on_an_arabic_word() raises:
    # measure_text and draw_text walk the same _shape_line output, so
    # this catches shaping being applied on one side only -- which is
    # exactly what a whole-run feature sweep on visual-order glyphs
    # would produce.
    var c = Canvas(260, 120, BG)
    draw_text(c, 30, 80, "بسم", FG, 64.0)
    var ink = _ink_bbox(c, BG)
    assert_true(ink.found_any)

    var m = measure_text("بسم", 64.0)
    var drawn_width = Float64(ink.max_x - ink.min_x)
    assert_true(drawn_width > m.width - 3.0 and drawn_width < m.width + 3.0)

    # The joined word is visibly narrower on the canvas too, not only
    # in the measurement.
    var iso = Canvas(260, 120, BG)
    draw_text(iso, 30, 80, "بسم", FG, 64.0, ligatures=False)
    var iso_ink = _ink_bbox(iso, BG)
    assert_true(iso_ink.found_any)
    assert_true(iso_ink.max_x - iso_ink.min_x > ink.max_x - ink.min_x)


def test_a_mixed_line_leaves_its_latin_run_alone() raises:
    # "AV بسم" starts with a strong L, so the base level is LTR: the
    # Latin run draws first, then the Arabic run right to left. The
    # Latin part has to come out of the mixed line exactly as it comes
    # out on its own -- same glyphs, same kerning -- since selecting
    # `arab` for the Arabic run must not reach the Latin one.
    var face = _sans_face()
    var latin_only = _shape_line(face, "AV ", True, True)
    var mixed = _shape_line(face, "AV بسم", True, True)
    assert_equal(len(latin_only), 3)
    assert_equal(len(mixed), 6)
    for i in range(3):
        assert_equal(mixed[i].glyph, latin_only[i].glyph)
        assert_equal(mixed[i].codepoint, latin_only[i].codepoint)

    # The Arabic run follows, still joined and still reversed.
    assert_equal(mixed[3].glyph, face.glyph_index_for_codepoint(0xFEE2))
    assert_equal(mixed[4].glyph, face.glyph_index_for_codepoint(0xFEB4))
    assert_equal(mixed[5].glyph, face.glyph_index_for_codepoint(0xFE91))

    # And the advances add: "AV " is A 1401 + V 1401 + space 651 with
    # the AV pair kerning -131 = 3322 units = 103.8125 px, and the
    # Arabic word is the 117.5 px above. No pair kerning crosses the
    # boundary -- DejaVu Sans states none for (space, meem final).
    var latin_advance = measure_text("AV ", 64.0).advance
    assert_equal(latin_advance, 103.8125)
    assert_equal(measure_text("AV بسم", 64.0).advance, 103.8125 + 117.5)


def test_a_mixed_line_keeps_its_latin_ligature() raises:
    # The Latin `liga` lookups still run on the Latin run of a line
    # that also selects `arab` for its other run.
    var face = _sans_face()
    var ffi = face.glyph_index_for_codepoint(0xFB03)
    assert_true(ffi != 0)
    var mixed = _shape_line(face, "ffi بسم", True, True)
    # Three characters ligate to one glyph, then the space, then three
    # Arabic letters.
    assert_equal(len(mixed), 5)
    assert_equal(mixed[0].glyph, ffi)
    assert_equal(mixed[2].glyph, face.glyph_index_for_codepoint(0xFEE2))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
