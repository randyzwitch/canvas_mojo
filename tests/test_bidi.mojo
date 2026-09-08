"""Tests for canvas/text/bidi.mojo.

Locked-in values below are hand-derived and cross-checked, not just
asserted against the code's own output: the Hebrew+digit case was
independently verified against Python's stdlib `unicodedata.
bidirectional()` (confirming the per-character strong/weak
classification this module's own simplified rules are built on)
before being trusted here, and the mirroring/boundary-space cases were
each traced by hand against UAX #9's own stated rules (L2 reordering,
L4 mirroring) before being locked in -- see bidi.mojo's own docstring
for exactly which parts of the real algorithm are simplified.
"""

from std.testing import assert_equal, assert_true, TestSuite

from canvas.text.bidi import (
    detect_base_level,
    visual_order,
    _resolve_levels,
)


def _codepoints_of(s: String) -> List[Int]:
    var out = List[Int]()
    for cp in s.codepoints():
        out.append(Int(cp))
    return out^


def test_pure_ltr_is_unchanged() raises:
    var cps = _codepoints_of("Hello World")
    var base = detect_base_level(cps)
    assert_equal(base, 0)
    var out = visual_order(cps, base)
    assert_equal(len(out), len(cps))
    for i in range(len(cps)):
        assert_equal(out[i], cps[i])


def test_pure_hebrew_word_is_reversed() raises:
    # שלום ("shalom") -- ש ל ו ם reversed is ם ו ל ש.
    var cps: List[Int] = [0x05E9, 0x05DC, 0x05D5, 0x05DD]
    var base = detect_base_level(cps)
    assert_equal(base, 1)
    var out = visual_order(cps, base)
    var expected: List[Int] = [0x05DD, 0x05D5, 0x05DC, 0x05E9]
    for i in range(len(expected)):
        assert_equal(out[i], expected[i])


def test_digit_run_inside_hebrew_stays_in_reading_order() raises:
    # "שלום 123 עולם" -- independently verified against Python's
    # unicodedata.bidirectional() before being locked in here (see
    # this file's own docstring): expected visual order is the two
    # Hebrew words individually reversed and run-order-swapped, with
    # "123" staying "123" (not reversed to "321") in between.
    var cps: List[Int] = [
        0x05E9,
        0x05DC,
        0x05D5,
        0x05DD,
        0x0020,
        0x0031,
        0x0032,
        0x0033,
        0x0020,
        0x05E2,
        0x05D5,
        0x05DC,
        0x05DD,
    ]
    var base = detect_base_level(cps)
    assert_equal(base, 1)
    var out = visual_order(cps, base)
    var expected: List[Int] = [
        0x05DD,
        0x05DC,
        0x05D5,
        0x05E2,
        0x0020,
        0x0031,
        0x0032,
        0x0033,
        0x0020,
        0x05DD,
        0x05D5,
        0x05DC,
        0x05E9,
    ]
    assert_equal(len(out), len(expected))
    for i in range(len(expected)):
        assert_equal(out[i], expected[i])


def test_embedded_rtl_word_keeps_surrounding_spaces_in_place() raises:
    # "Hello שלום World" (base LTR, one Hebrew word embedded): a
    # one-sided neutral resolution pulls the space *after* the Hebrew
    # word into its own reversal, corrupting the spacing (a doubled
    # gap after "Hello", none before "World") -- see bidi.mojo's own
    # _resolve_levels docstring for the two-sided rule that keeps both
    # boundary spaces in place. Checked here structurally
    # (both boundary spaces present and correctly placed, Hebrew
    # letters reversed, "Hello"/"World" themselves untouched) rather
    # than one giant hand-typed expected array, so the property that
    # actually matters (spacing survives) is what's being asserted.
    var cps = _codepoints_of("Hello שלום World")
    var base = detect_base_level(cps)
    assert_equal(base, 0)
    var out = visual_order(cps, base)
    assert_equal(len(out), len(cps))

    # "Hello" unchanged at the start.
    var hello = _codepoints_of("Hello")
    for i in range(len(hello)):
        assert_equal(out[i], hello[i])
    assert_equal(out[5], 0x20)  # boundary space survives

    # The Hebrew word, reversed, follows -- then another boundary
    # space, then "World" unchanged.
    var reversed_shalom: List[Int] = [0x05DD, 0x05D5, 0x05DC, 0x05E9]
    for i in range(len(reversed_shalom)):
        assert_equal(out[6 + i], reversed_shalom[i])
    assert_equal(out[10], 0x20)  # boundary space survives

    var world = _codepoints_of("World")
    for i in range(len(world)):
        assert_equal(out[11 + i], world[i])


def test_parens_mirror_inside_rtl_text() raises:
    # "ש(ע)" -- both parens must swap identity (L4 mirroring) as part
    # of the same reversal that flips the word order -- hand-traced
    # against UAX #9's own L2+L4 rules before being locked in (see
    # this file's own docstring).
    var cps: List[Int] = [0x05E9, 0x0028, 0x05E2, 0x0029]
    var out = visual_order(cps, detect_base_level(cps))
    var expected: List[Int] = [0x0028, 0x05E2, 0x0029, 0x05E9]
    for i in range(len(expected)):
        assert_equal(out[i], expected[i])


def test_empty_string_is_empty() raises:
    var cps = List[Int]()
    assert_equal(detect_base_level(cps), 0)
    var out = visual_order(cps, 0)
    assert_equal(len(out), 0)


def test_all_digits_defaults_to_ltr_base() raises:
    # No strong character anywhere -- nothing to base an RTL judgment
    # on, so this must not spuriously come out RTL.
    var cps = _codepoints_of("12345")
    assert_equal(detect_base_level(cps), 0)


# --- explicit formatting characters and combining marks (#301) ------
# The two gaps bidi.mojo's docstring named: directional controls that
# were "not recognized at all", and combining marks detaching from
# their base under RTL reordering. Values below are hand-derived from
# UAX #9's stated rules (P2 for the isolate skip, W1 for a mark taking
# its base's direction, L2 for the reversal) and cross-checked against
# Python's `unicodedata.bidirectional`, which reports Mn/NSM for the
# marks used and LRE/RLE/LRI/RLI/PDI for the controls.

comptime _LRE = 0x202A
comptime _RLE = 0x202B
comptime _PDF = 0x202C
comptime _LRI = 0x2066
comptime _RLI = 0x2067
comptime _PDI = 0x2069
comptime _LRM = 0x200E
comptime _RLM = 0x200F

comptime _ALEF = 0x05D0
comptime _BET = 0x05D1
comptime _GIMEL = 0x05D2
comptime _QAMATS = 0x05B8  # Hebrew point, a non-spacing mark
comptime _SHEVA = 0x05B0


def _assert_codepoints(got: List[Int], want: List[Int], label: String) raises:
    assert_equal(len(got), len(want), label + " length")
    for i in range(len(want)):
        assert_equal(got[i], want[i], String(label, " at ", i))


def test_a_directional_control_does_not_set_the_base_direction() raises:
    """RLE used to classify as strong L, so it both forced an LTR base
    and rendered as a .notdef box. It is structure, not text."""
    var cps: List[Int] = [_RLE, 0x61, 0x62, _PDF]
    assert_equal(detect_base_level(cps), 0, "an LTR letter decides it")
    var rtl: List[Int] = [_RLE, _ALEF, _BET, _PDF]
    assert_equal(detect_base_level(rtl), 1, "a Hebrew letter decides it")


def test_directional_controls_are_dropped_from_visual_order() raises:
    var cps: List[Int] = [0x61, _LRE, 0x62, _PDF, 0x63]
    var out = visual_order(cps, detect_base_level(cps))
    var want: List[Int] = [0x61, 0x62, 0x63]
    _assert_codepoints(out, want, "controls dropped")


def test_an_isolate_is_skipped_when_finding_the_base_level() raises:
    """UAX #9 P2 skips everything between an isolate initiator and its
    matching PDI. Hebrew inside an isolate must not make the paragraph
    right-to-left -- that is what isolating it means."""
    var isolated: List[Int] = [_LRI, _ALEF, _BET, _PDI, 0x61]
    assert_equal(detect_base_level(isolated), 0, "isolated Hebrew skipped")
    var bare: List[Int] = [_ALEF, _BET, 0x61]
    assert_equal(detect_base_level(bare), 1, "the same Hebrew, not isolated")
    var nested: List[Int] = [_RLI, _LRI, _ALEF, _PDI, _PDI, 0x61]
    assert_equal(detect_base_level(nested), 0, "nested isolates skipped")


def test_an_unmatched_isolate_swallows_the_rest_of_the_line() raises:
    """BD9's matching PDI never arrives, so the scan finds no strong
    character outside the isolate and falls back to LTR. Stated
    because it is a real input, not because it is desirable."""
    var cps: List[Int] = [_LRI, _ALEF, _BET]
    assert_equal(detect_base_level(cps), 0)


def test_the_invisible_strong_marks_set_direction() raises:
    """LRM/RLM carry a direction and nothing else, so unlike the
    structural controls they are exactly what P2 is looking for."""
    var rtl: List[Int] = [_RLM, 0x61, 0x62]
    assert_equal(detect_base_level(rtl), 1, "RLM makes it RTL")
    var ltr: List[Int] = [_LRM, _ALEF, _BET]
    assert_equal(detect_base_level(ltr), 0, "LRM makes it LTR")


def test_a_combining_mark_stays_on_its_base_through_reversal() raises:
    """The bug this fixes. Logical order is alef, qamats, bet: the
    point belongs to the alef. Reversing codepoint by codepoint puts
    the qamats between bet and alef, which renders it on the bet.
    Reversing by cluster keeps it after its own base.
    """
    var cps: List[Int] = [_ALEF, _QAMATS, _BET]
    var base = detect_base_level(cps)
    assert_equal(base, 1)
    var out = visual_order(cps, base)
    var want: List[Int] = [_BET, _ALEF, _QAMATS]
    _assert_codepoints(out, want, "cluster-preserving reversal")


def test_several_marks_on_one_base_keep_their_order() raises:
    """Two points on the same letter stay in logical order relative to
    each other; only the letters reverse."""
    var cps: List[Int] = [_ALEF, _SHEVA, _QAMATS, _BET, _GIMEL]
    var out = visual_order(cps, detect_base_level(cps))
    var want: List[Int] = [_GIMEL, _BET, _ALEF, _SHEVA, _QAMATS]
    _assert_codepoints(out, want, "two marks on one base")


def test_a_mark_takes_the_direction_of_its_base() raises:
    """UAX #9 W1. A mark after a Latin letter belongs to the LTR run
    and must not be dragged into a neighbouring RTL one."""
    var cps: List[Int] = [_ALEF, 0x65, 0x0301, _BET]
    var out = visual_order(cps, detect_base_level(cps))
    # Base is RTL. The Latin "e" plus its acute is one LTR island
    # between two Hebrew letters, so the Hebrew reverses around it
    # while the island keeps its own order.
    var want: List[Int] = [_BET, 0x65, 0x0301, _ALEF]
    _assert_codepoints(out, want, "mark follows its Latin base")


def test_marks_in_pure_ltr_text_are_untouched() raises:
    var cps: List[Int] = [0x65, 0x0301, 0x61]
    var out = visual_order(cps, detect_base_level(cps))
    _assert_codepoints(out, cps, "LTR text is unchanged")


# --- explicit embedding levels (#301) -------------------------------
# UAX #9 X1-X8. Levels are asserted directly rather than through
# visual order, because that is where the rules live: two different
# level assignments can produce the same reordering on one input and
# diverge on the next. Each expected array below was derived by
# walking the directional status stack by hand.
#
# The two level formulas, from X2-X5: the next *odd* level above `n`
# is `(n + 1) | 1`, the next *even* is `(n + 2) & ~1`. So an RLE from
# level 0 goes to 1 and an LRE from 0 goes to 2, not 0.

comptime _LRO = 0x202D
comptime _RLO = 0x202E
comptime _FSI = 0x2068


def _assert_levels(got: List[Int], want: List[Int], label: String) raises:
    assert_equal(len(got), len(want), label + " length")
    for i in range(len(want)):
        assert_equal(got[i], want[i], String(label, " at ", i))


def test_rle_raises_the_level_of_what_it_encloses() raises:
    """ "a RLE b PDF c" at base 0. The RLE itself sits outside at 0 and
    pushes level 1; `b` is strong L, which opposes an odd level, so it
    goes one deeper to 2. The PDF pops and takes the outer level.
    """
    var cps: List[Int] = [0x61, _RLE, 0x62, _PDF, 0x63]
    var want: List[Int] = [0, 0, 2, 0, 0]
    _assert_levels(_resolve_levels(cps, 0), want, "RLE")


def test_rlo_overrides_the_direction_of_what_it_encloses() raises:
    """RLO makes every character inside it strong right-to-left
    whatever its own class, which is the whole difference from RLE:
    the Latin letters here land at level 1 rather than 2.
    """
    var cps: List[Int] = [0x61, _RLO, 0x62, 0x63, _PDF, 0x64]
    var want: List[Int] = [0, 0, 1, 1, 0, 0]
    _assert_levels(_resolve_levels(cps, 0), want, "RLO")
    # And it shows in the output: the overridden pair reverses.
    var out = visual_order(cps, 0)
    var vis: List[Int] = [0x61, 0x63, 0x62, 0x64]
    _assert_codepoints(out, vis, "RLO visual")


def test_lro_holds_latin_order_inside_right_to_left_text() raises:
    """Base RTL, with two Hebrew letters around an LRO'd pair. The
    surrounding Hebrew reverses; the overridden pair does not.
    """
    var cps: List[Int] = [_ALEF, _LRO, _BET, _GIMEL, _PDF, 0x05D3]
    var want: List[Int] = [1, 1, 2, 2, 1, 1]
    _assert_levels(_resolve_levels(cps, 1), want, "LRO")
    var out = visual_order(cps, 1)
    var vis: List[Int] = [0x05D3, _BET, _GIMEL, _ALEF]
    _assert_codepoints(out, vis, "LRO visual")


def test_an_isolate_gives_its_content_its_own_level() raises:
    """ "a RLI b PDI d" at base 0: the initiator and the PDI both sit
    at the outer level, and only what is between them is raised.
    """
    var cps: List[Int] = [0x61, _RLI, _ALEF, _PDI, 0x64]
    var want: List[Int] = [0, 0, 1, 0, 0]
    _assert_levels(_resolve_levels(cps, 0), want, "RLI")


def test_an_lri_inside_rtl_text_goes_two_levels_deeper() raises:
    """Base RTL. LRI from level 1 takes the next *even* level, 2, so
    Hebrew inside it -- opposing that -- lands at 3. Getting the
    formula wrong gives 2 here and the isolate stops isolating.
    """
    var cps: List[Int] = [_ALEF, _LRI, _BET, _PDI, 0x05D3]
    var want: List[Int] = [1, 1, 3, 1, 1]
    _assert_levels(_resolve_levels(cps, 1), want, "LRI in RTL")


def test_fsi_takes_its_direction_from_its_contents() raises:
    """FSI is whichever of LRI/RLI the first strong character inside
    it calls for, so the same control produces different levels for
    Hebrew and Latin content.
    """
    var hebrew: List[Int] = [0x61, _FSI, _ALEF, _PDI, 0x64]
    var want_h: List[Int] = [0, 0, 1, 0, 0]
    _assert_levels(_resolve_levels(hebrew, 0), want_h, "FSI hebrew")
    var latin: List[Int] = [0x61, _FSI, 0x62, _PDI, 0x64]
    var want_l: List[Int] = [0, 0, 2, 0, 0]
    _assert_levels(_resolve_levels(latin, 0), want_l, "FSI latin")


def test_a_pdf_cannot_escape_an_isolate() raises:
    """X7. The PDF inside the isolate has no embedding of its own to
    close, and must not pop the isolate: `c` stays inside.
    """
    var cps: List[Int] = [0x61, _RLI, _ALEF, _PDF, _BET, _PDI, 0x64]
    var want: List[Int] = [0, 0, 1, 1, 1, 0, 0]
    _assert_levels(_resolve_levels(cps, 0), want, "PDF in isolate")


def test_overflowing_the_depth_limit_does_not_corrupt_what_follows() raises:
    """BD2 caps explicit depth at 125. Past it the controls are
    counted as overflow and take no effect, and the text after the
    matching PDFs has to come back to the paragraph level rather than
    being stranded deep.
    """
    var cps = List[Int]()
    for _ in range(130):
        cps.append(_RLE)
    cps.append(0x61)
    for _ in range(130):
        cps.append(_PDF)
    cps.append(0x62)
    var levels = _resolve_levels(cps, 0)
    assert_equal(len(levels), len(cps), "length")
    # The trailing letter is back at the paragraph level.
    assert_equal(levels[len(levels) - 1], 0, "text after the overflow")
    # And nothing anywhere exceeded the cap.
    var deepest = 0
    for i in range(len(levels)):
        if levels[i] > deepest:
            deepest = levels[i]
    assert_true(deepest <= 126, String("deepest level ", deepest))


def test_an_unmatched_pdi_is_ignored() raises:
    var cps: List[Int] = [0x61, _PDI, 0x62]
    var want: List[Int] = [0, 0, 0]
    _assert_levels(_resolve_levels(cps, 0), want, "stray PDI")


def test_nested_embeddings_stack_and_unwind() raises:
    """RLE inside RLE: 0 -> 1 -> 3, and each PDF steps back one."""
    var cps: List[Int] = [
        0x61,
        _RLE,
        _ALEF,
        _RLE,
        _BET,
        _PDF,
        _GIMEL,
        _PDF,
        0x62,
    ]
    var want: List[Int] = [0, 0, 1, 1, 3, 1, 1, 0, 0]
    _assert_levels(_resolve_levels(cps, 0), want, "nested RLE")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
