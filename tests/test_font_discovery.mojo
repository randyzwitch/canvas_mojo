"""Tests for canvas/text/font_discovery.mojo.

Needs a "Sans"-resolvable system font (the generic sans-serif alias),
the same real-machine dependency tests/test_text.mojo documents.

What's tested is what this module is responsible for, which is the
whole of font matching: resolving a family/slant/weight request to some
real, existing font file, expanding the generic and metric aliases,
matching family names case- and blank-insensitively, and constraining a
match to a font that actually has a given codepoint.
The one thing still out of scope is a *specific* font being the right
aesthetic answer on an arbitrary machine; assertions are about which
properties the answer has, except where a machine-specific fact is
called out below.

Three machine-specific facts hold these up. DejaVu Sans ships separate
Regular/Bold files, which is what makes BOLD differ from NORMAL -- a
failure on a different CI image is an environment difference to look
at, not a test to loosen. DejaVu Sans Mono ships a separate Oblique
file, which is what makes an oblique monospace request observable. And
the "Ubuntu" font lacks a snowman glyph (U+2603) that "DejaVu Sans"
has; if a future image's Ubuntu font gains it, the fallback assertion
needs a different missing character rather than the mechanism being
broken.

What is deliberately *not* assumed is which *style* files a family
ships beyond those: fonts-dejavu-core includes DejaVuSans-Oblique.ttf
on a GitHub runner and not on every desktop install, so a slant request
for DejaVu Sans lands on a different file depending on the image. Tests
that would otherwise encode that read the matched face's family back
out of the FontDatabase (`_matched_face_answers_to`) instead.

That third fact needs the "Ubuntu" font family actually installed.
Without it, "Ubuntu" resolves through the default sans list like any
other unknown family, collapsing the "falls back to a different font"
assertion for reasons unrelated to the code under test -- see
.github/workflows/ci.yml's `fonts-ubuntu` install step.
"""

from std.testing import assert_equal, assert_true, TestSuite

from canvas.text.font_discovery import (
    FontDatabase,
    FontSlant,
    FontWeight,
    _normalize_family,
    resolve_font_file,
    resolve_font_file_for_char,
)


def _looks_like_a_font_file(path: String) -> Bool:
    # The four sfnt container extensions the scan collects; anything
    # else coming back would mean the walk picked up a file it can't
    # have read an identity out of.
    var lowered = path.lower()
    return (
        lowered.endswith(".ttf")
        or lowered.endswith(".ttc")
        or lowered.endswith(".otf")
        or lowered.endswith(".otc")
    )


def _is_readable_file(path: String) raises -> Bool:
    with open(path, "r") as f:
        return f.read(4).byte_length() > 0


def _matched_face_answers_to(
    database: FontDatabase, path: String, family_key: String
) -> Bool:
    """Whether the face `database` resolved to lists `family_key` among
    the normalized names it answers to.

    An assertion about *which family* matched, rather than about a
    filename: which file within a family a style request lands on is an
    image difference (fonts-dejavu-core ships DejaVuSans-Oblique.ttf on
    a GitHub runner and not on every desktop install), while which
    family it lands on is the thing under test. Any face sharing the
    path counts, since a .ttc holds several.
    """
    for face in database.faces:
        if face.path == path and family_key in face.names:
            return True
    return False


def test_resolves_sans_to_an_existing_font_file() raises:
    var path = resolve_font_file("Sans")
    assert_true(path.byte_length() > 0)
    assert_true(_looks_like_a_font_file(path))
    # A real, readable file on disk, not just a plausible-looking
    # string the scan reported.
    assert_true(_is_readable_file(path))


def test_resolves_monospace_alias() raises:
    var path = resolve_font_file("Monospace")
    assert_true(_looks_like_a_font_file(path))


def test_the_three_generic_aliases_resolve_to_three_different_files() raises:
    # The point of expanding "sans-serif"/"serif"/"monospace" into
    # separate preference lists: collapsing them onto one file would
    # still pass every "resolves to a font" assertion above.
    var sans = resolve_font_file("sans-serif")
    var serif = resolve_font_file("serif")
    var mono = resolve_font_file("monospace")
    assert_true(not (sans == serif))
    assert_true(not (sans == mono))
    assert_true(not (serif == mono))


def test_generic_alias_spellings_agree() raises:
    # "Sans" is render.mojo's own default family and "sans-serif" is
    # what svg.mojo writes, so the two spellings must not resolve
    # differently.
    assert_equal(resolve_font_file("Sans"), resolve_font_file("sans-serif"))
    assert_equal(resolve_font_file("Monospace"), resolve_font_file("monospace"))


def test_family_matching_ignores_case_and_blanks() raises:
    # fontconfig's FcStrCmpIgnoreBlanksAndCase, which _normalize_family
    # reimplements: a caller writing "dejavusans" means "DejaVu Sans".
    var canonical = resolve_font_file("DejaVu Sans")
    assert_equal(resolve_font_file("dejavu sans"), canonical)
    assert_equal(resolve_font_file("DEJAVUSANS"), canonical)
    assert_equal(resolve_font_file("  DejaVu   Sans  "), canonical)


def test_normalizing_a_family_name_drops_case_and_blanks() raises:
    # The normal form itself, rather than a resolution through it:
    # fontconfig's FcStrCmpIgnoreBlanksAndCase, as a key both a request
    # and an installed face get reduced to.
    assert_equal(_normalize_family("DejaVu Sans"), "dejavusans")
    assert_equal(_normalize_family("  DEJAVU   SANS "), "dejavusans")
    assert_equal(_normalize_family("DejaVu Sans Mono"), "dejavusansmono")
    # Distinct families must not collide once the blanks are gone.
    assert_true(
        not (
            _normalize_family("DejaVu Sans")
            == _normalize_family("DejaVu Serif")
        )
    )


def test_normalizing_a_non_ascii_family_name_keeps_it_readable() raises:
    # Walking bytes instead of codepoints would still *match* correctly
    # -- both sides go through this same function -- but would turn
    # every non-ASCII name into mojibake on the way. Asserting the text
    # rather than only the round-trip is what catches that.
    assert_equal(_normalize_family("Grøtesk Ærial"), "grøteskærial")
    assert_equal(_normalize_family("源ノ角ゴシック"), "源ノ角ゴシック")
    # Still case- and blank-insensitive with non-ASCII in the name.
    assert_equal(
        _normalize_family("Grøtesk Ærial"), _normalize_family("grøteskærial")
    )


def test_a_family_request_beats_the_default_sans_list() raises:
    # Every request has the default sans list appended to it, so an
    # exact family match has to outrank it -- otherwise "DejaVu Sans
    # Mono" would silently resolve to the same file "Sans" does.
    var mono = resolve_font_file("DejaVu Sans Mono")
    assert_true(not (mono == resolve_font_file("Sans")))
    assert_true(mono.lower().endswith("mono.ttf"))


def test_bold_weight_resolves_to_a_different_file_than_normal() raises:
    # See this file's docstring for why this holds on this machine.
    var normal_path = resolve_font_file("Sans", weight=FontWeight.NORMAL)
    var bold_path = resolve_font_file("Sans", weight=FontWeight.BOLD)
    assert_true(not (normal_path == bold_path))
    assert_true(bold_path.lower().endswith("bold.ttf"))


def test_oblique_slant_resolves_to_the_oblique_face() raises:
    # DejaVu Sans Mono ships Book/Bold/Oblique/BoldOblique as separate
    # files everywhere this runs, which is what makes the slant term
    # observable as a different *file* rather than only a different
    # face.
    var upright = resolve_font_file("Monospace", slant=FontSlant.NORMAL)
    var oblique = resolve_font_file("Monospace", slant=FontSlant.OBLIQUE)
    assert_true(not (upright == oblique))
    assert_true(oblique.lower().endswith("oblique.ttf"))


def test_a_slant_request_stays_inside_the_requested_family() raises:
    # Slant is scored below family, so asking for an italic must stay
    # in the requested family rather than promoting some other family
    # that happens to ship one. Whether it lands on that family's
    # oblique face (italic and oblique are near-substitutes, penalty 1)
    # or falls back to its upright one (penalty 3) depends on what the
    # image installed, which is exactly why this asserts on the family
    # and not on the file.
    var database = FontDatabase()
    for slant in [FontSlant.NORMAL, FontSlant.ITALIC, FontSlant.OBLIQUE]:
        var path = database.resolve("DejaVu Sans", slant=slant)
        assert_true(_matched_face_answers_to(database, path, "dejavusans"))


def test_default_weight_matches_explicit_normal() raises:
    var default_path = resolve_font_file("Sans")
    var explicit_path = resolve_font_file("Sans", weight=FontWeight.NORMAL)
    assert_equal(default_path, explicit_path)


def test_default_slant_matches_explicit_normal() raises:
    var default_path = resolve_font_file("Sans")
    var explicit_path = resolve_font_file("Sans", slant=FontSlant.NORMAL)
    assert_equal(default_path, explicit_path)


def test_an_unrecognized_family_still_resolves_through_the_default_list() raises:
    # Matching scores rather than filters, and the default sans list is
    # appended to every request, so an unknown family name doesn't
    # raise on a system with any fonts installed -- it falls back the
    # way a browser does with an unknown CSS font-family.
    var path = resolve_font_file("ThisFontDoesNotExistAnywhereReally12345")
    assert_true(_looks_like_a_font_file(path))
    assert_equal(path, resolve_font_file("Sans"))


def test_a_metric_alias_resolves_to_its_substitute_family() raises:
    # "Helvetica" is not installed on a Linux image, and the
    # metric-alias table is what makes it resolve to a real
    # metric-compatible sans (URW's Nimbus Sans from fonts-urw-base35,
    # or Liberation Sans/Arimo where those are installed) rather than
    # falling through to the default sans list. On macOS, where
    # Helvetica itself ships with the OS, the requested name is ahead
    # of its own substitutes and wins -- which is the same rule, not an
    # exception to it.
    var name = resolve_font_file("Helvetica").lower()
    assert_true(_looks_like_a_font_file(name))
    assert_true(
        "helvetica" in name
        or "nimbussans" in name
        or "liberationsans" in name
        or "arimo" in name
    )


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
    var fallback_path = resolve_font_file_for_char(
        "Ubuntu", FontSlant.NORMAL, FontWeight.NORMAL, 0x2603
    )
    var plain_ubuntu_path = resolve_font_file("Ubuntu")
    assert_true(not (fallback_path == plain_ubuntu_path))
    assert_true(_looks_like_a_font_file(fallback_path))


def test_char_constrained_resolution_is_a_noop_when_the_family_already_has_it() raises:
    # 'A' -- the Ubuntu font has it, so the charset constraint changes
    # nothing.
    var constrained_path = resolve_font_file_for_char(
        "Ubuntu", FontSlant.NORMAL, FontWeight.NORMAL, 0x41
    )
    var plain_path = resolve_font_file("Ubuntu")
    assert_equal(constrained_path, plain_path)


def test_char_constrained_resolution_degrades_gracefully_with_no_real_match() raises:
    # With no CJK font installed, no candidate covers the codepoint, so
    # the unconstrained best match is returned. This must not raise
    # just because nothing installed has the character.
    var path = resolve_font_file_for_char(
        "Sans", FontSlant.NORMAL, FontWeight.NORMAL, 0x4E2D
    )
    assert_true(_looks_like_a_font_file(path))


def test_scanned_database_holds_real_readable_font_files() raises:
    # The scan itself, rather than one resolution through it: every
    # face it reports must be a file that exists, opens, and carries an
    # sfnt extension. Skipping unreadable files is deliberate (see
    # _parse_font_file); reporting one that can't be opened would not
    # be.
    var database = FontDatabase()
    assert_true(len(database.faces) > 0)
    for face in database.faces:
        assert_true(_looks_like_a_font_file(face.path))
        assert_true(len(face.names) > 0)
        assert_true(face.weight >= 1 and face.weight <= 1000)
        assert_true(_is_readable_file(face.path))


def test_a_reused_database_answers_exactly_as_the_free_functions_do() raises:
    # FontCache holds a FontDatabase and every cache-less entry point
    # builds a throwaway one, so the two paths agreeing is what keeps
    # `cache=` from changing what gets drawn.
    var database = FontDatabase()
    assert_equal(database.resolve("Sans"), resolve_font_file("Sans"))
    assert_equal(
        database.resolve("Sans", FontSlant.NORMAL, FontWeight.BOLD),
        resolve_font_file("Sans", weight=FontWeight.BOLD),
    )
    assert_equal(
        database.resolve("Ubuntu", FontSlant.NORMAL, FontWeight.NORMAL, 0x2603),
        resolve_font_file_for_char(
            "Ubuntu", FontSlant.NORMAL, FontWeight.NORMAL, 0x2603
        ),
    )


def test_repeated_scans_agree_with_each_other() raises:
    # Directory order is filesystem order, which is why the walk sorts.
    # Without that, two equally-scored faces would tie-break differently
    # between runs and a chart's fonts would change under it.
    var first = FontDatabase()
    var second = FontDatabase()
    assert_equal(len(first.faces), len(second.faces))
    for i in range(len(first.faces)):
        assert_equal(first.faces[i].path, second.faces[i].path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
