"""Tests for canvas_mojo/text/bidi.mojo.

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

from canvas_mojo.text.bidi import detect_base_level, visual_order


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
        0x05E9, 0x05DC, 0x05D5, 0x05DD,
        0x0020,
        0x0031, 0x0032, 0x0033,
        0x0020,
        0x05E2, 0x05D5, 0x05DC, 0x05DD,
    ]
    var base = detect_base_level(cps)
    assert_equal(base, 1)
    var out = visual_order(cps, base)
    var expected: List[Int] = [
        0x05DD, 0x05DC, 0x05D5, 0x05E2,
        0x0020,
        0x0031, 0x0032, 0x0033,
        0x0020,
        0x05DD, 0x05D5, 0x05DC, 0x05E9,
    ]
    assert_equal(len(out), len(expected))
    for i in range(len(expected)):
        assert_equal(out[i], expected[i])


def test_embedded_rtl_word_keeps_surrounding_spaces_in_place() raises:
    # Regression test for a real bug caught by probe: "Hello שלום
    # World" (base LTR, one Hebrew word embedded) originally pulled
    # the space *after* the Hebrew word into its own reversal,
    # corrupting the spacing (a doubled gap after "Hello", none before
    # "World") -- see bidi.mojo's own _resolve_levels docstring for
    # the two-sided neutral-resolution fix. Checked here structurally
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
