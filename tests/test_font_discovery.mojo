"""Tests for canvas_mojo/text/font_discovery.mojo.

Needs a "Sans"-resolvable system font (fontconfig's generic sans-serif
alias) to run -- the same real-machine dependency tests/
test_text.mojo's own docstring documents.

What's tested is what this module is actually responsible for --
resolving a family/slant/weight request to *some* real, existing font
file, with slant/weight genuinely affecting the result where the
system's installed fonts make that observable -- not fontconfig's own
matching quality/aliasing rules, which are out of scope to verify here.
The BOLD-differs-from-NORMAL assertion is a real, probe-confirmed fact
about this machine's fonts (DejaVu Sans ships separate Regular/Bold
files), not a cross-platform guarantee -- if it ever starts failing on
a different CI image, that's a real environment difference to look at,
not a flaky test to loosen. The char-constrained-resolution tests rely
on a second machine-specific fact, also probe-confirmed: the "Ubuntu"
font lacks a snowman glyph (U+2603) that "DejaVu Sans" has -- if a
future CI image's Ubuntu font gains that glyph, the "falls back"
assertion would need a different missing-character example, not a
sign the fallback mechanism itself broke. This needs the "Ubuntu" font
family actually installed (not just fontconfig's own runtime
library) to be meaningful at all -- without it, "Ubuntu" silently
resolves to whatever fontconfig substitutes instead, which can
collapse the "falls back to a different font" assertion for reasons
that have nothing to do with the fallback code under test (a real
failure hit once on CI, see .github/workflows/ci.yml's own
`fonts-ubuntu` install step and its comment for the full story).
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
        # Confirms this is a real, readable file on disk, not just a
        # plausible-looking string fontconfig happened to report.
        var first_bytes = f.read(4)
        assert_true(first_bytes.byte_length() > 0)


def test_resolves_monospace_alias() raises:
    var path = resolve_font_file("Monospace")
    assert_true(_looks_like_a_font_file(path))


def test_bold_weight_resolves_to_a_different_file_than_normal() raises:
    # See this file's own docstring for why this is safe to assert on
    # this machine specifically.
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
    # Confirmed real fontconfig behavior via probe, not assumed: after
    # FcDefaultSubstitute, FcFontMatch essentially always returns
    # *some* pattern (fontconfig's own default-substitution chain), so
    # an unknown family name is not expected to raise on a system with
    # any fonts installed at all -- it silently falls back.
    var path = resolve_font_file("ThisFontDoesNotExistAnywhereReally12345")
    assert_true(_looks_like_a_font_file(path))


def test_font_slant_equality() raises:
    assert_true(FontSlant.NORMAL == FontSlant.NORMAL)
    assert_true(not (FontSlant.ITALIC == FontSlant.OBLIQUE))


def test_font_weight_equality() raises:
    assert_true(FontWeight.NORMAL == FontWeight.NORMAL)
    assert_true(not (FontWeight.NORMAL == FontWeight.BOLD))


def test_char_constrained_resolution_falls_back_to_a_font_that_has_the_glyph() raises:
    # Real, contrasting fallback confirmed via probe on this machine
    # specifically (see this file's own docstring on why that's safe
    # to assert here): "Ubuntu" (the font, not the OS) has no snowman
    # glyph (U+2603), but "DejaVu Sans" does -- requesting the Ubuntu
    # family constrained to that one character must fall back to a
    # font that actually has it, not just return Ubuntu's own file
    # regardless of the constraint.
    var fallback_path = resolve_font_file_for_char("Ubuntu", FontSlant.NORMAL, FontWeight.NORMAL, 0x2603)
    var plain_ubuntu_path = resolve_font_file("Ubuntu")
    assert_true(not (fallback_path == plain_ubuntu_path))
    assert_true(_looks_like_a_font_file(fallback_path))


def test_char_constrained_resolution_is_a_noop_when_the_family_already_has_it() raises:
    # 'A' -- Ubuntu's own font has this already, so the charset
    # constraint shouldn't change anything.
    var constrained_path = resolve_font_file_for_char("Ubuntu", FontSlant.NORMAL, FontWeight.NORMAL, 0x41)
    var plain_path = resolve_font_file("Ubuntu")
    assert_equal(constrained_path, plain_path)


def test_char_constrained_resolution_degrades_gracefully_with_no_real_match() raises:
    # Confirmed via probe: with no CJK font installed anywhere on this
    # machine, fontconfig's own default-substitution still returns a
    # real font file (its best-effort guess), not an error -- this
    # must not raise just because no installed font actually has the
    # requested character.
    var path = resolve_font_file_for_char("Sans", FontSlant.NORMAL, FontWeight.NORMAL, 0x4E2D)
    assert_true(_looks_like_a_font_file(path))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
