"""Bidirectional text layout -- a practical, deliberately partial
implementation of the Unicode Bidirectional Algorithm (UAX #9), just
enough to lay out real mixed Hebrew/Arabic/Latin/digit text correctly:
classify each codepoint's direction, assign it an embedding level,
reorder the line into visual (left-to-right-drawable) order via the
same run-reversal technique UAX #9's own rule L2 uses, and mirror
paired characters (parens/brackets/comparisons) that end up inside a
right-to-left run.

What this deliberately does NOT implement, and why that's a reasonable
line to draw rather than an oversight: UAX #9's full weak/neutral-type
resolution (rules W1-W7, N0-N2) has many rules for corner cases this
collapses into one simplified rule (a neutral/weak run takes the
level of the strong text immediately before it, or the paragraph's
own base level if there is none -- correct for the overwhelmingly
common case of digits/punctuation/spaces sitting between words, not
exhaustively correct for every adjacency UAX #9 itself enumerates).
Explicit directional formatting characters (LRE/RLE/PDF/LRI/RLI/FSI/
PDI/LRM/RLM) aren't recognized at all -- a real, separable feature for
callers that need explicit direction overrides, not a silent gap in
the common case this targets. Combining marks aren't specially kept
attached to their base character during reordering -- a base+diacritic
pair used with an RTL script here (Hebrew niqqud, Arabic tashkeel)
would have its mark's relative position affected by the same per-
codepoint reversal every other character gets, which is a real,
visible limitation for vocalized/diacritic-heavy text specifically,
not for plain consonantal text.

Font/glyph-shaping note: this module only reorders and mirrors
*existing* codepoints -- it does not perform Arabic's own contextual
letter-shaping (selecting a letter's isolated/initial/medial/final
glyph form and connecting it to its neighbors). Hebrew has no
contextual shaping at all (each codepoint always maps to the same
glyph), so Hebrew text laid out through this module renders fully
correctly. Arabic text laid out through this module gets the correct
right-to-left *order* and correctly-mirrored punctuation, but each
letter renders in its isolated form, disconnected from its neighbors
-- directionally correct, not visually shaped. Real Arabic shaping
(a per-letter joining-type table, contextual glyph selection, and
mapping to the font's own Arabic Presentation Forms glyphs) is a
separate, larger feature, not attempted here.
"""


comptime _STRONG_L = 0
comptime _STRONG_R = 1
comptime _WEAK_NEUTRAL = 2
comptime _WEAK_NUMBER = 3


def _codepoint_class(cp: Int) -> Int:
    """Simplified strong-L / strong-R / weak classification -- see
    this module's own docstring for what "simplified" means here.
    Whitespace and common punctuation are WEAK_NEUTRAL (resolved to
    match the surrounding strong run's level exactly, staying part of
    its flow); digits are their own WEAK_NUMBER class -- UAX #9's own
    "European Number" category, which needs different treatment: a
    run of digits inside right-to-left text must still display left-
    to-right internally ("123" reads as one-two-three, not reversed,
    even embedded in a Hebrew sentence), which _resolve_levels handles
    by giving WEAK_NUMBER its own even (LTR) level rather than
    inheriting an odd (RTL) one. Hebrew/Arabic (and their
    presentation-form blocks) are STRONG_R; everything else defaults
    to STRONG_L, matching the practical reality that most scripts
    (Latin, Cyrillic, Greek, CJK, ...) are left-to-right and this
    isn't trying to enumerate them all.
    """
    if cp >= 0x30 and cp <= 0x39:
        return _WEAK_NUMBER
    if cp == 0x20 or cp == 0x09 or cp == 0x0A or cp == 0x0D:
        return _WEAK_NEUTRAL
    if (cp >= 0x21 and cp <= 0x2F) or (cp >= 0x3A and cp <= 0x40):
        return _WEAK_NEUTRAL

    # Hebrew, Hebrew presentation forms.
    if cp >= 0x0590 and cp <= 0x05FF:
        return _STRONG_R
    if cp >= 0xFB1D and cp <= 0xFB4F:
        return _STRONG_R

    # Arabic, Arabic Supplement, Arabic Extended-A, Syriac, Thaana,
    # NKo, and the Arabic presentation-form compatibility blocks.
    if cp >= 0x0600 and cp <= 0x08FF:
        return _STRONG_R
    if cp >= 0xFB50 and cp <= 0xFDFF:
        return _STRONG_R
    if cp >= 0xFE70 and cp <= 0xFEFF:
        return _STRONG_R

    return _STRONG_L


def detect_base_level(codepoints: List[Int]) -> Int:
    """UAX #9 rules P2/P3, simplified to their common-case outcome:
    the paragraph's base embedding level is RTL (1) if the first
    strongly-directional codepoint is STRONG_R, LTR (0) otherwise
    (including the case where every codepoint is weak -- an all-digit
    or all-punctuation line has no basis to be anything but LTR).
    """
    for cp in codepoints:
        var cls = _codepoint_class(cp)
        if cls == _STRONG_R:
            return 1
        if cls == _STRONG_L:
            return 0
    return 0


def _resolve_levels(codepoints: List[Int], base_level: Int) -> List[Int]:
    """One level per codepoint, in three passes -- see this module's
    own docstring for why this whole function is a deliberate
    simplification of UAX #9's own weak-type resolution rules (W1-W7,
    N0-N2), not an attempt to reproduce them exactly.

    Pass 1: strong characters get their natural level (base_level if
    they match the paragraph direction, base_level+1 if they oppose
    it); everything else is left unresolved (-1).

    Pass 2: WEAK_NUMBER (digits) resolve against the nearest preceding
    resolved level, bumped to the next even level if that's odd (RTL)
    -- a digit run must display left-to-right internally even
    embedded in RTL text ("123" reads as one-two-three, never
    reversed). Confirmed necessary by probe: without this bump, "123"
    inside Hebrew text came out reordered to "321".

    Pass 3: remaining WEAK_NEUTRAL runs (whitespace/punctuation)
    resolve against *both* neighbors, not just the preceding one --
    the same level on both sides uses that level; different levels (a
    genuine direction boundary) fall back to the paragraph's own
    base_level; at either end of the line, whichever neighbor exists
    wins. This two-sided rule matters concretely, not just in theory:
    a one-sided "inherit the preceding level" rule (tried first, then
    replaced) pulled the space between an RTL word and a following
    LTR word into the RTL run's own reversal, corrupting the spacing
    around it -- confirmed via probe ("Hello שלום World" rendered
    with a doubled gap after "Hello" and no gap before "World") before
    switching to this two-sided version, which resolves that boundary
    space to the paragraph's base level instead, leaving it exactly
    where it logically belongs.
    """
    var n = len(codepoints)
    var levels = List[Int](capacity=n)
    for i in range(n):
        levels.append(-1)

    for i in range(n):
        var cls = _codepoint_class(codepoints[i])
        if cls == _STRONG_L:
            levels[i] = base_level if base_level % 2 == 0 else base_level + 1
        elif cls == _STRONG_R:
            levels[i] = base_level if base_level % 2 == 1 else base_level + 1

    var last_level = base_level
    for i in range(n):
        if levels[i] != -1:
            last_level = levels[i]
        elif _codepoint_class(codepoints[i]) == _WEAK_NUMBER:
            var level = last_level if last_level % 2 == 0 else last_level + 1
            levels[i] = level
            last_level = level

    var i = 0
    while i < n:
        if levels[i] == -1:
            var j = i
            while j < n and levels[j] == -1:
                j += 1
            var before = levels[i - 1] if i > 0 else -1
            var after = levels[j] if j < n else -1
            var resolved: Int
            if before == -1 and after == -1:
                resolved = base_level
            elif before == -1:
                resolved = after
            elif after == -1:
                resolved = before
            elif before == after:
                resolved = before
            else:
                resolved = base_level
            for k in range(i, j):
                levels[k] = resolved
            i = j
        else:
            i += 1

    return levels^


def _reorder_indices(levels: List[Int]) -> List[Int]:
    """UAX #9 rule L2, applied to an index array rather than the
    codepoints directly (so a caller can reorder any per-codepoint
    data it's tracking alongside, not just the codepoint values
    themselves): from the highest level present down to the lowest
    *odd* level, reverse every maximal run of consecutive positions
    whose level is at or above the level being processed. This is the
    standard, general nested-run-reversal technique -- correct for
    arbitrarily nested RTL-in-LTR-in-RTL text, not just one level of
    embedding, despite _resolve_levels' own simplified level
    assignment above.
    """
    var n = len(levels)
    var indices = List[Int](capacity=n)
    for i in range(n):
        indices.append(i)
    if n == 0:
        return indices^

    var max_level = 0
    var min_odd_level = -1
    for level in levels:
        if level > max_level:
            max_level = level
        if level % 2 == 1:
            if min_odd_level == -1 or level < min_odd_level:
                min_odd_level = level

    if min_odd_level == -1:
        # Every character is at an even (LTR) level -- nothing to
        # reverse, matching a plain left-to-right line exactly.
        return indices^

    var level = max_level
    while level >= min_odd_level:
        var i = 0
        while i < n:
            if levels[indices[i]] >= level:
                var j = i
                while j < n and levels[indices[j]] >= level:
                    j += 1
                # Reverse indices[i:j] in place.
                var lo = i
                var hi = j - 1
                while lo < hi:
                    var tmp = indices[lo]
                    indices[lo] = indices[hi]
                    indices[hi] = tmp
                    lo += 1
                    hi -= 1
                i = j
            else:
                i += 1
        level -= 1

    return indices^


def _mirror_codepoint(cp: Int) -> Int:
    """UAX #9 rule L4: a paired character (parens, brackets, braces,
    angle brackets/comparisons, guillemets, <=/>=) swaps for its
    mirror image when it ends up inside a right-to-left run -- "(" in
    RTL text must visually open to the *left*, which means drawing it
    as ")"'s glyph, not literally flipping the glyph's own pixels.
    Covers the common practical set, not the full ~500-entry Unicode
    BidiMirroring.txt (see this module's own docstring on scope).
    """
    if cp == 0x28:
        return 0x29
    if cp == 0x29:
        return 0x28
    if cp == 0x5B:
        return 0x5D
    if cp == 0x5D:
        return 0x5B
    if cp == 0x7B:
        return 0x7D
    if cp == 0x7D:
        return 0x7B
    if cp == 0x3C:
        return 0x3E
    if cp == 0x3E:
        return 0x3C
    if cp == 0xAB:
        return 0xBB
    if cp == 0xBB:
        return 0xAB
    if cp == 0x2039:
        return 0x203A
    if cp == 0x203A:
        return 0x2039
    if cp == 0x2264:
        return 0x2265
    if cp == 0x2265:
        return 0x2264
    return cp


def visual_order(codepoints: List[Int], base_level: Int) -> List[Int]:
    """The full pipeline: resolve each codepoint's embedding level,
    reorder into visual (left-to-right-drawable) order, and mirror
    any paired character that ends up at an odd (RTL) level after
    reordering -- the sequence a caller can now walk strictly left to
    right (accumulating glyph advances rightward) and get correct
    on-screen output for mixed-direction text, no different from how
    it already walked a plain LTR line.
    """
    var levels = _resolve_levels(codepoints, base_level)
    var order = _reorder_indices(levels)
    var result = List[Int](capacity=len(codepoints))
    for idx in order:
        var cp = codepoints[idx]
        if levels[idx] % 2 == 1:
            cp = _mirror_codepoint(cp)
        result.append(cp)
    return result^
