"""Tests for canvas/text/font_discovery.mojo.

Needs a "Sans"-resolvable system font (the generic sans-serif alias),
the same real-machine dependency tests/test_text.mojo documents.

What's tested is the whole of font matching: resolving a
family/slant/weight request to some real, existing font file, expanding
the generic and metric aliases, matching family names case- and
blank-insensitively, and constraining a match to a font that actually
has a given codepoint. Assertions are about which properties the answer
has, not about a specific font being the right aesthetic answer on an
arbitrary machine, except where a machine-specific fact is called out
below.

Three machine-specific facts hold these up. DejaVu Sans ships separate
Regular/Bold files, which is what makes BOLD differ from NORMAL. DejaVu
Sans Mono ships a separate Oblique file, which is what makes an oblique
monospace request observable. And the "Ubuntu" font lacks a snowman
glyph (U+2603) that "DejaVu Sans" has; if a future image's Ubuntu font
gains it, the fallback assertion needs a different missing character.

Which *style* files a family ships beyond those is not assumed:
fonts-dejavu-core includes DejaVuSans-Oblique.ttf on a GitHub runner and
not on every desktop install, so a slant request for DejaVu Sans lands
on a different file depending on the image. Tests that would otherwise
encode that read the matched face's family back out of the FontDatabase
(`_matched_face_answers_to`) instead.

Each test builds at most one `FontDatabase` and asks it several
questions, rather than calling the free `resolve_font_file` once per
assertion: every one of those calls scans the machine's font
directories from scratch, which was most of this file's runtime.
`test_a_reused_database_answers_exactly_as_the_free_functions_do` is
what lets the rest do that -- it pins `FontDatabase.resolve` and the
free functions to the same answers, so testing through the cheaper one
tests both.

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


def test_generic_aliases_resolve_and_stay_distinct() raises:
    # One scan, several properties of generic-family expansion. Each
    # resolution goes through `database.resolve`, which is the same
    # matching the free functions run -- see
    # test_a_reused_database_answers_exactly_as_the_free_functions_do,
    # which pins the two paths together so the rest of this file can
    # use the cheaper one.
    var database = FontDatabase()

    var sans = database.resolve("Sans")
    assert_true(sans.byte_length() > 0, "Sans resolves to something")
    assert_true(_looks_like_a_font_file(sans), "and it is an sfnt file")
    # A real, readable file on disk, not just a plausible-looking
    # string the scan reported.
    assert_true(_is_readable_file(sans), "and it opens")

    var mono = database.resolve("Monospace")
    assert_true(_looks_like_a_font_file(mono), "Monospace resolves too")

    # The point of expanding "sans-serif"/"serif"/"monospace" into
    # separate preference lists: collapsing them onto one file would
    # still pass every "resolves to a font" assertion above.
    var serif = database.resolve("serif")
    assert_true(not (sans == serif), "sans and serif differ")
    assert_true(not (sans == mono), "sans and monospace differ")
    assert_true(not (serif == mono), "serif and monospace differ")

    # "Sans" is render.mojo's own default family and "sans-serif" is
    # what svg.mojo writes, so the two spellings must not resolve
    # differently.
    assert_equal(sans, database.resolve("sans-serif"), "Sans == sans-serif")
    assert_equal(mono, database.resolve("monospace"), "Monospace == monospace")


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


def test_family_matching_normalizes_ranks_and_falls_back() raises:
    # One scan, the four properties of family matching that need one.
    var database = FontDatabase()

    # fontconfig's FcStrCmpIgnoreBlanksAndCase, which _normalize_family
    # reimplements: a caller writing "dejavusans" means "DejaVu Sans".
    var canonical = database.resolve("DejaVu Sans")
    assert_equal(database.resolve("dejavu sans"), canonical, "lower case")
    assert_equal(database.resolve("DEJAVUSANS"), canonical, "no blanks")
    assert_equal(
        database.resolve("  DejaVu   Sans  "), canonical, "extra blanks"
    )

    # Every request has the default sans list appended to it, so an
    # exact family match has to outrank it -- otherwise "DejaVu Sans
    # Mono" would silently resolve to the same file "Sans" does.
    var sans = database.resolve("Sans")
    var mono = database.resolve("DejaVu Sans Mono")
    assert_true(not (mono == sans), "an exact family beats the default list")
    assert_true(mono.lower().endswith("mono.ttf"), "and lands on the mono file")

    # Matching scores rather than filters, and the default sans list is
    # appended to every request, so an unknown family name doesn't
    # raise on a system with any fonts installed -- it falls back the
    # way a browser does with an unknown CSS font-family.
    var unknown = database.resolve("ThisFontDoesNotExistAnywhereReally12345")
    assert_true(_looks_like_a_font_file(unknown), "an unknown family resolves")
    assert_equal(unknown, sans, "through the default sans list")

    # "Helvetica" is not installed on a Linux image, and the
    # metric-alias table is what makes it resolve to a real
    # metric-compatible sans (URW's Nimbus Sans from fonts-urw-base35,
    # or Liberation Sans/Arimo where those are installed) rather than
    # falling through to the default sans list. On macOS, where
    # Helvetica itself ships with the OS, the requested name is ahead
    # of its own substitutes and wins -- which is the same rule, not an
    # exception to it.
    var substitute = database.resolve("Helvetica").lower()
    assert_true(_looks_like_a_font_file(substitute), "Helvetica resolves")
    assert_true(
        "helvetica" in substitute
        or "nimbussans" in substitute
        or "liberationsans" in substitute
        or "arimo" in substitute,
        "to itself or a metric-compatible substitute",
    )


def test_weight_and_slant_pick_faces_within_the_family() raises:
    # One scan for every style-term property.
    var database = FontDatabase()

    # See this file's docstring for why the bold/normal split holds on
    # this machine.
    var normal_path = database.resolve("Sans", weight=FontWeight.NORMAL)
    var bold_path = database.resolve("Sans", weight=FontWeight.BOLD)
    assert_true(not (normal_path == bold_path), "bold is a different file")
    assert_true(
        bold_path.lower().endswith("bold.ttf"), "and it is the bold one"
    )

    # DejaVu Sans Mono ships Book/Bold/Oblique/BoldOblique as separate
    # files everywhere this runs, which is what makes the slant term
    # observable as a different *file* rather than only a different
    # face.
    var upright = database.resolve("Monospace", slant=FontSlant.NORMAL)
    var oblique = database.resolve("Monospace", slant=FontSlant.OBLIQUE)
    assert_true(not (upright == oblique), "oblique is a different file")
    assert_true(
        oblique.lower().endswith("oblique.ttf"), "and it is the oblique one"
    )

    # Omitting a term must mean exactly what asking for its normal
    # value means, since every call site relies on the defaults.
    var plain = database.resolve("Sans")
    assert_equal(plain, normal_path, "default weight is NORMAL")
    assert_equal(
        plain,
        database.resolve("Sans", slant=FontSlant.NORMAL),
        "default slant is NORMAL",
    )

    # Slant is scored below family, so asking for an italic must stay
    # in the requested family rather than promoting some other family
    # that happens to ship one. Whether it lands on that family's
    # oblique face (italic and oblique are near-substitutes, penalty 1)
    # or falls back to its upright one (penalty 3) depends on what the
    # image installed, which is exactly why this asserts on the family
    # and not on the file.
    for slant in [FontSlant.NORMAL, FontSlant.ITALIC, FontSlant.OBLIQUE]:
        var path = database.resolve("DejaVu Sans", slant=slant)
        assert_true(
            _matched_face_answers_to(database, path, "dejavusans"),
            "a slant request stays inside DejaVu Sans",
        )


def test_font_slant_equality() raises:
    assert_true(FontSlant.NORMAL == FontSlant.NORMAL)
    assert_true(not (FontSlant.ITALIC == FontSlant.OBLIQUE))


def test_font_weight_equality() raises:
    assert_true(FontWeight.NORMAL == FontWeight.NORMAL)
    assert_true(not (FontWeight.NORMAL == FontWeight.BOLD))


def test_char_constrained_resolution() raises:
    # One scan for all three charset-constraint properties.
    var database = FontDatabase()

    # Contrasting fallback on this machine (see this file's docstring):
    # "Ubuntu" the font has no snowman glyph (U+2603) and "DejaVu Sans"
    # does, so requesting Ubuntu constrained to that character must
    # fall back rather than return Ubuntu's file regardless.
    var plain_ubuntu = database.resolve("Ubuntu")
    var snowman = database.resolve(
        "Ubuntu", FontSlant.NORMAL, FontWeight.NORMAL, 0x2603
    )
    assert_true(not (snowman == plain_ubuntu), "U+2603 falls back off Ubuntu")
    assert_true(_looks_like_a_font_file(snowman), "onto a real font file")

    # 'A' -- the Ubuntu font has it, so the charset constraint changes
    # nothing.
    var letter_a = database.resolve(
        "Ubuntu", FontSlant.NORMAL, FontWeight.NORMAL, 0x41
    )
    assert_equal(letter_a, plain_ubuntu, "a covered character is a no-op")

    # With no CJK font installed, no candidate covers the codepoint, so
    # the unconstrained best match is returned. This must not raise
    # just because nothing installed has the character.
    var cjk = database.resolve(
        "Sans", FontSlant.NORMAL, FontWeight.NORMAL, 0x4E2D
    )
    assert_true(
        _looks_like_a_font_file(cjk),
        "an uncovered character degrades to a match",
    )


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
