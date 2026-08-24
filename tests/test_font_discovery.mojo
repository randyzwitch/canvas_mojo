"""Tests for canvas_mojo/text/font_discovery.mojo.

Needs a "Sans"-resolvable system font (fontconfig's generic sans-serif
alias), the same real-machine dependency tests/test_text.mojo
documents.

What's tested is what this module is responsible for: resolving a
family/slant/weight request to some real, existing font file, with
slant and weight affecting the result where the installed fonts make
that observable. Not fontconfig's own matching quality or aliasing
rules, which are out of scope here.

Two machine-specific facts hold these up. DejaVu Sans ships separate
Regular/Bold files, which is what makes BOLD differ from NORMAL -- a
failure on a different CI image is an environment difference to look
at, not a test to loosen. And the "Ubuntu" font lacks a snowman glyph
(U+2603) that "DejaVu Sans" has; if a future image's Ubuntu font gains
it, the fallback assertion needs a different missing character rather
than the mechanism being broken.

That second fact needs the "Ubuntu" font family actually installed, not
just fontconfig's runtime library. Without it, "Ubuntu" silently
resolves to whatever fontconfig substitutes, collapsing the "falls back
to a different font" assertion for reasons unrelated to the code under
test -- see .github/workflows/ci.yml's `fonts-ubuntu` install step.
"""

from std.testing import assert_equal, assert_true, TestSuite

from canvas_mojo.text.font_discovery import FontSlant, FontWeight, resolve_font_file, resolve_font_file_for_char


def _looks_like_a_font_file(path: String) -> Bool:
    return (
        path.endswith(".ttf")
        or path.endswith(".ttc")
        or path.endswith(".otf")
        or path.endswith(".pfb")
    )


def test_resolves_sans_to_an_existing_font_file() raises:
    var path = resolve_font_file("Sans")
    assert_true(path.byte_length() > 0)
    assert_true(_looks_like_a_font_file(path))
    with open(path, "r") as f:
        # A real, readable file on disk, not just a plausible-looking
        # string fontconfig reported.
        var first_bytes = f.read(4)
        assert_true(first_bytes.byte_length() > 0)


def test_resolves_monospace_alias() raises:
    var path = resolve_font_file("Monospace")
    assert_true(_looks_like_a_font_file(path))


def test_bold_weight_resolves_to_a_different_file_than_normal() raises:
    # See this file's docstring for why this holds on this machine.
    var normal_path = resolve_font_file("Sans", weight=FontWeight.NORMAL)
    var bold_path = resolve_font_file("Sans", weight=FontWeight.BOLD)
    assert_true(not (normal_path == bold_path))
    assert_true(bold_path.lower().endswith("bold.ttf"))


def test_default_weight_matches_explicit_normal() raises:
    var default_path = resolve_font_file("Sans")
    var explicit_path = resolve_font_file("Sans", weight=FontWeight.NORMAL)
    assert_equal(default_path, explicit_path)


def test_default_slant_matches_explicit_normal() raises:
    var default_path = resolve_font_file("Sans")
    var explicit_path = resolve_font_file("Sans", slant=FontSlant.NORMAL)
    assert_equal(default_path, explicit_path)


def test_an_unrecognized_family_still_resolves_via_fontconfig_fallback() raises:
    # After FcDefaultSubstitute, FcFontMatch essentially always returns
    # some pattern through fontconfig's default-substitution chain, so
    # an unknown family name doesn't raise on a system with any fonts
    # installed -- it silently falls back.
    var path = resolve_font_file("ThisFontDoesNotExistAnywhereReally12345")
    assert_true(_looks_like_a_font_file(path))


def test_font_slant_equality() raises:
    assert_true(FontSlant.NORMAL == FontSlant.NORMAL)
    assert_true(not (FontSlant.ITALIC == FontSlant.OBLIQUE))


def test_font_weight_equality() raises:
    assert_true(FontWeight.NORMAL == FontWeight.NORMAL)
    assert_true(not (FontWeight.NORMAL == FontWeight.BOLD))


def test_char_constrained_resolution_falls_back_to_a_font_that_has_the_glyph() raises:
    # Contrasting fallback on this machine (see this file's docstring):
    # "Ubuntu" the font has no snowman glyph (U+2603) and "DejaVu Sans"
    # does, so requesting Ubuntu constrained to that character must
    # fall back rather than return Ubuntu's file regardless.
    var fallback_path = resolve_font_file_for_char("Ubuntu", FontSlant.NORMAL, FontWeight.NORMAL, 0x2603)
    var plain_ubuntu_path = resolve_font_file("Ubuntu")
    assert_true(not (fallback_path == plain_ubuntu_path))
    assert_true(_looks_like_a_font_file(fallback_path))


def test_char_constrained_resolution_is_a_noop_when_the_family_already_has_it() raises:
    # 'A' -- the Ubuntu font has it, so the charset constraint changes
    # nothing.
    var constrained_path = resolve_font_file_for_char("Ubuntu", FontSlant.NORMAL, FontWeight.NORMAL, 0x41)
    var plain_path = resolve_font_file("Ubuntu")
    assert_equal(constrained_path, plain_path)


def test_char_constrained_resolution_degrades_gracefully_with_no_real_match() raises:
    # With no CJK font installed, fontconfig's default substitution
    # still returns a real font file as its best guess, so this must
    # not raise just because nothing installed has the character.
    var path = resolve_font_file_for_char("Sans", FontSlant.NORMAL, FontWeight.NORMAL, 0x4E2D)
    assert_true(_looks_like_a_font_file(path))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
