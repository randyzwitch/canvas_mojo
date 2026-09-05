"""Arabic joining: which contextual form -- isolated, initial, medial
or final -- each letter of a run takes from the letters beside it. An
Arabic font ships four glyphs for a dual-joining letter and states the
choice between them as `GSUB` `isol`/`init`/`medi`/`fina` features;
this module decides which of the four each character is eligible for,
so `ttf.mojo` can enable that one feature on that one glyph.

The algorithm is the Unicode Standard's (chapter 9, "Arabic Cursive
Joining"), over the `Joining_Type` property `ArabicShaping.txt`
defines:

- **D** dual-joining -- joins on both sides (most letters: beh, seen,
  meem)
- **R** right-joining -- joins only to the preceding letter (alef,
  dal, waw)
- **L** left-joining -- joins only to the following letter; no Arabic
  letter is L, and it is here for completeness
- **C** join-causing -- joins on both sides and takes no form of its
  own (tatweel U+0640, ZWJ U+200D)
- **U** non-joining -- breaks a join (ZWNJ U+200C, digits,
  punctuation, every character outside the covered blocks)
- **T** transparent -- skipped when looking for a neighbor, so a
  vowel mark between two letters does not break their join (the
  harakat, and every other combining mark)

Ranges covered, from `ArabicShaping.txt` plus its stated default (a
character it does not list is T when its General_Category is Mn, Me or
Cf, and U otherwise):

- U+0600..U+06FF Arabic
- U+0750..U+077F Arabic Supplement
- U+0870..U+089F Arabic Extended-B
- U+08A0..U+08FF Arabic Extended-A
- U+200D ZERO WIDTH JOINER (C) and U+FEFF ZERO WIDTH NO-BREAK SPACE
  (T); U+200C ZERO WIDTH NON-JOINER is U, which is the default and
  needs no entry

Everything else is non-joining. That leaves out the other cursive
scripts `ArabicShaping.txt` also covers -- Syriac, N'Ko, Mandaic,
Manichaean, Mongolian, Adlam -- whose letters classify as U here and
so stay in their isolated forms, and the Arabic presentation-form
blocks (U+FB50..U+FDFF, U+FE70..U+FEFF), whose characters *are*
non-joining: they encode a form directly rather than taking one from
context.
"""


# Joining_Type values. U is the default, so the range table below lists
# only the characters that are something else.
comptime _JOIN_NON = 0
comptime _JOIN_DUAL = 1
comptime _JOIN_RIGHT = 2
comptime _JOIN_LEFT = 3
comptime _JOIN_CAUSING = 4
comptime _JOIN_TRANSPARENT = 5

# The form a character is eligible for, one per `GSUB` feature.
# _FORM_NONE covers everything with no contextual form at all: marks,
# tatweel, digits, and every non-Arabic character.
comptime _FORM_NONE = 0
comptime _FORM_ISOLATED = 1
comptime _FORM_INITIAL = 2
comptime _FORM_MEDIAL = 3
comptime _FORM_FINAL = 4


def is_arabic(cp: Int) -> Bool:
    """Whether `cp` belongs to one of the Arabic blocks -- what selects
    the `arab` OpenType script for a run, and so the joining features.
    The presentation-form blocks are included because a font tags their
    `ccmp` and ligature lookups `arab` too, even though the characters
    themselves take no contextual form.

    Args:
        cp: A Unicode codepoint.

    Returns:
        True for Arabic, Arabic Supplement, Arabic Extended-A/B and the
        two Arabic presentation-form blocks.
    """
    if cp >= 0x0600 and cp <= 0x06FF:
        return True
    if cp >= 0x0750 and cp <= 0x077F:
        return True
    if cp >= 0x0870 and cp <= 0x08FF:
        return True
    if cp >= 0xFB50 and cp <= 0xFDFF:
        return True
    if cp >= 0xFE70 and cp <= 0xFEFF:
        return True
    return False


def _joining_type_ranges() -> List[Int]:
    """The Joining_Type table as [first, last, type] triples, ascending
    and disjoint. Only the non-U characters are listed; a codepoint
    that falls in no range is `_JOIN_NON`, which is
    `ArabicShaping.txt`'s own default for everything it does not name.

    Rebuilt per call: a `comptime List[Int]` does not materialize to a
    usable runtime value in the current Mojo version, the same
    limitation `deflate.mojo` and `bidi.mojo` work around.
    `joining_forms` builds it once per run and bisects it per
    character.
    """
    # `# fmt: off` keeps the triples three to a line. The formatter
    # would otherwise put every number on its own, which turns a table
    # a reader can check against `ArabicShaping.txt` into 200 lines
    # they cannot.
    # fmt: off
    return [
        # Arabic U+0600..U+06FF
        0x0610, 0x061A, _JOIN_TRANSPARENT,
        0x061C, 0x061C, _JOIN_TRANSPARENT,
        0x0620, 0x0620, _JOIN_DUAL,
        0x0622, 0x0625, _JOIN_RIGHT,
        0x0626, 0x0626, _JOIN_DUAL,
        0x0627, 0x0627, _JOIN_RIGHT,
        0x0628, 0x0628, _JOIN_DUAL,
        0x0629, 0x0629, _JOIN_RIGHT,
        0x062A, 0x062E, _JOIN_DUAL,
        0x062F, 0x0632, _JOIN_RIGHT,
        0x0633, 0x063F, _JOIN_DUAL,
        0x0640, 0x0640, _JOIN_CAUSING,
        0x0641, 0x0647, _JOIN_DUAL,
        0x0648, 0x0648, _JOIN_RIGHT,
        0x0649, 0x064A, _JOIN_DUAL,
        0x064B, 0x065F, _JOIN_TRANSPARENT,
        0x066E, 0x066F, _JOIN_DUAL,
        0x0670, 0x0670, _JOIN_TRANSPARENT,
        0x0671, 0x0673, _JOIN_RIGHT,
        0x0675, 0x0677, _JOIN_RIGHT,
        0x0678, 0x0687, _JOIN_DUAL,
        0x0688, 0x0699, _JOIN_RIGHT,
        0x069A, 0x06BF, _JOIN_DUAL,
        0x06C0, 0x06C0, _JOIN_RIGHT,
        0x06C1, 0x06C2, _JOIN_DUAL,
        0x06C3, 0x06CB, _JOIN_RIGHT,
        0x06CC, 0x06CC, _JOIN_DUAL,
        0x06CD, 0x06CD, _JOIN_RIGHT,
        0x06CE, 0x06CE, _JOIN_DUAL,
        0x06CF, 0x06CF, _JOIN_RIGHT,
        0x06D0, 0x06D1, _JOIN_DUAL,
        0x06D2, 0x06D3, _JOIN_RIGHT,
        0x06D5, 0x06D5, _JOIN_RIGHT,
        0x06D6, 0x06DC, _JOIN_TRANSPARENT,
        0x06DF, 0x06E4, _JOIN_TRANSPARENT,
        0x06E7, 0x06E8, _JOIN_TRANSPARENT,
        0x06EA, 0x06ED, _JOIN_TRANSPARENT,
        0x06EE, 0x06EF, _JOIN_RIGHT,
        0x06FA, 0x06FC, _JOIN_DUAL,
        0x06FF, 0x06FF, _JOIN_DUAL,
        # Arabic Supplement U+0750..U+077F
        0x0750, 0x0758, _JOIN_DUAL,
        0x0759, 0x075B, _JOIN_RIGHT,
        0x075C, 0x076A, _JOIN_DUAL,
        0x076B, 0x076C, _JOIN_RIGHT,
        0x076D, 0x0770, _JOIN_DUAL,
        0x0771, 0x0771, _JOIN_RIGHT,
        0x0772, 0x0772, _JOIN_DUAL,
        0x0773, 0x0774, _JOIN_RIGHT,
        0x0775, 0x0777, _JOIN_DUAL,
        0x0778, 0x0779, _JOIN_RIGHT,
        0x077A, 0x077F, _JOIN_DUAL,
        # Arabic Extended-B U+0870..U+089F
        0x0870, 0x0882, _JOIN_RIGHT,
        0x0883, 0x0885, _JOIN_CAUSING,
        0x0886, 0x0886, _JOIN_DUAL,
        0x0889, 0x088D, _JOIN_DUAL,
        0x088E, 0x088E, _JOIN_RIGHT,
        0x0898, 0x089F, _JOIN_TRANSPARENT,
        # Arabic Extended-A U+08A0..U+08FF
        0x08A0, 0x08A9, _JOIN_DUAL,
        0x08AA, 0x08AC, _JOIN_RIGHT,
        0x08AE, 0x08AE, _JOIN_RIGHT,
        0x08AF, 0x08B0, _JOIN_DUAL,
        0x08B1, 0x08B2, _JOIN_RIGHT,
        0x08B3, 0x08B8, _JOIN_DUAL,
        0x08B9, 0x08B9, _JOIN_RIGHT,
        0x08BA, 0x08C8, _JOIN_DUAL,
        0x08CA, 0x08E1, _JOIN_TRANSPARENT,
        0x08E3, 0x08FF, _JOIN_TRANSPARENT,
        # ZERO WIDTH JOINER, ZERO WIDTH NO-BREAK SPACE
        0x200D, 0x200D, _JOIN_CAUSING,
        0xFEFF, 0xFEFF, _JOIN_TRANSPARENT,
    ]
    # fmt: on


def _joining_type_in(ranges: List[Int], cp: Int) -> Int:
    """`cp`'s Joining_Type, bisecting the [first, last, type] triples
    `_joining_type_ranges` built.
    """
    var lo = 0
    var hi = len(ranges) // 3 - 1
    while lo <= hi:
        var mid = (lo + hi) // 2
        if cp < ranges[mid * 3]:
            hi = mid - 1
        elif cp > ranges[mid * 3 + 1]:
            lo = mid + 1
        else:
            return ranges[mid * 3 + 2]
    return _JOIN_NON


def joining_type(cp: Int) -> Int:
    """`cp`'s Unicode Joining_Type, over the blocks this module's
    docstring lists. Builds the range table per call, so a caller
    classifying a whole run should use `joining_forms` instead.

    Args:
        cp: A Unicode codepoint.

    Returns:
        One of the module's `_JOIN_*` values.
    """
    return _joining_type_in(_joining_type_ranges(), cp)


def joining_forms(codepoints: List[Int]) -> List[Int]:
    """The contextual form each character of a run is eligible for, one
    per codepoint.

    A character joins to the neighbor on a given side when both are
    willing: the neighbor must be able to join on the side that faces
    it, and the character itself must be able to join on that side. R
    joins only to what precedes it, L only to what follows, D and C to
    both. Transparent characters are skipped when looking for a
    neighbor, so a vowel mark between two letters leaves their join
    intact.

    The forms follow: a D joined on both sides is medial, joined only to
    what precedes it final, only to what follows initial, and otherwise
    isolated. R and L have only two of those available. Everything else
    -- marks, tatweel, digits, non-Arabic text -- gets `_FORM_NONE`.

    Args:
        codepoints: A run's codepoints, in logical order.

    Returns:
        One `_FORM_*` value per codepoint.
    """
    var n = len(codepoints)
    var ranges = _joining_type_ranges()
    var types = List[Int](capacity=n)
    for i in range(n):
        types.append(_joining_type_in(ranges, codepoints[i]))

    var out = List[Int](capacity=n)
    for i in range(n):
        var t = types[i]
        if t != _JOIN_DUAL and t != _JOIN_RIGHT and t != _JOIN_LEFT:
            out.append(_FORM_NONE)
            continue

        var j = i - 1
        while j >= 0 and types[j] == _JOIN_TRANSPARENT:
            j -= 1
        # The preceding character joins forward when it is D, L or C.
        var after_join = j >= 0 and (
            types[j] == _JOIN_DUAL
            or types[j] == _JOIN_LEFT
            or types[j] == _JOIN_CAUSING
        )

        var k = i + 1
        while k < n and types[k] == _JOIN_TRANSPARENT:
            k += 1
        # The following character joins backward when it is D, R or C.
        var before_join = k < n and (
            types[k] == _JOIN_DUAL
            or types[k] == _JOIN_RIGHT
            or types[k] == _JOIN_CAUSING
        )

        if t == _JOIN_RIGHT:
            before_join = False
        elif t == _JOIN_LEFT:
            after_join = False

        if after_join and before_join:
            out.append(_FORM_MEDIAL)
        elif after_join:
            out.append(_FORM_FINAL)
        elif before_join:
            out.append(_FORM_INITIAL)
        else:
            out.append(_FORM_ISOLATED)
    return out^
