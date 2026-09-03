"""Bidirectional text layout: a partial implementation of the Unicode
Bidirectional Algorithm (UAX #9), covering what real mixed
Hebrew/Arabic/Latin/digit text needs. Each codepoint is classified by
direction and assigned an embedding level, the line is reordered into
visual (left-to-right-drawable) order by the run-reversal technique of
UAX #9's rule L2, and paired characters (parens, brackets, comparisons)
that land inside a right-to-left run are mirrored.

Not implemented here:

- UAX #9's full weak/neutral-type resolution (rules W1-W7, N0-N2), which
  collapses into one rule: a neutral/weak run takes the level of the
  strong text next to it, or the paragraph's base level. That is correct
  for digits, punctuation and spaces between words, not for every
  adjacency UAX #9 enumerates.
- Explicit directional formatting characters
  (LRE/RLE/PDF/LRI/RLI/FSI/PDI/LRM/RLM), which are not recognized at
  all.
- Keeping combining marks attached to their base character during
  reordering. A base+diacritic pair in an RTL script (Hebrew niqqud,
  Arabic tashkeel) has its mark repositioned by the same per-codepoint
  reversal every other character gets.
- Arabic contextual letter-shaping: selecting a letter's
  isolated/initial/medial/final glyph form and connecting it to its
  neighbors. This module reorders and mirrors existing codepoints only.

Hebrew has no contextual shaping -- each codepoint always maps to the
same glyph -- so Hebrew text laid out through this module renders fully.
Arabic gets the correct right-to-left order and correctly mirrored
punctuation, with each letter in its isolated form.
"""


comptime _STRONG_L = 0
comptime _STRONG_R = 1
comptime _WEAK_NEUTRAL = 2
comptime _WEAK_NUMBER = 3


def _codepoint_class(cp: Int) -> Int:
    """Simplified strong-L / strong-R / weak classification.
    Whitespace and common punctuation are WEAK_NEUTRAL, resolving to
    the surrounding strong run's level. Digits are WEAK_NUMBER, UAX
    #9's "European Number" category, which needs separate treatment: a
    digit run inside RTL text still displays left-to-right ("123" reads
    one-two-three even in a Hebrew sentence), so _resolve_levels gives
    it an even (LTR) level rather than an inherited odd one.

    Hebrew/Arabic and their presentation-form blocks are STRONG_R;
    everything else defaults to STRONG_L, since most scripts (Latin,
    Cyrillic, Greek, CJK, ...) are left-to-right and enumerating them
    isn't the point.
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

    Args:
        codepoints: A line's Unicode codepoints, in logical order.

    Returns:
        0 for LTR, 1 for RTL.
    """
    for cp in codepoints:
        var cls = _codepoint_class(cp)
        if cls == _STRONG_R:
            return 1
        if cls == _STRONG_L:
            return 0
    return 0


def _resolve_levels(codepoints: List[Int], base_level: Int) -> List[Int]:
    """One level per codepoint, in three passes -- the simplification
    of UAX #9's W1-W7/N0-N2 this module's docstring describes.

    Pass 1: strong characters get their natural level (base_level if
    they match the paragraph direction, base_level+1 if they oppose
    it); everything else is left unresolved (-1).

    Pass 2: WEAK_NUMBER (digits) resolve against the nearest preceding
    resolved level, bumped to the next even level if that one is odd
    (RTL), since a digit run displays left-to-right even inside RTL
    text. Without the bump, "123" in Hebrew text comes out "321".

    Pass 3: remaining WEAK_NEUTRAL runs (whitespace/punctuation)
    resolve against *both* neighbors: matching levels win, differing
    levels (a real direction boundary) fall back to base_level, and at
    either end of the line whichever neighbor exists wins. The
    two-sided rule matters -- inheriting only from the preceding level
    pulls the space between an RTL word and a following LTR word into
    the RTL run's reversal, so "Hello שלום World" renders with a
    doubled gap after "Hello" and none before "World".
    """
    var n = len(codepoints)
    var levels = List[Int](capacity=n)
    for _ in range(n):
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
    codepoints themselves, so a caller can reorder per-codepoint data
    it tracks alongside: from the highest level present down to the
    lowest *odd* level, reverse every maximal run of positions at or
    above the level being processed. The standard nested-run reversal,
    correct for arbitrarily nested RTL-in-LTR-in-RTL text even though
    _resolve_levels assigns levels more simply.
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
    angle brackets, guillemets, <=/>=) swaps for its mirror image
    inside a right-to-left run -- "(" in RTL text opens to the *left*,
    which means drawing ")"'s glyph rather than flipping pixels.
    Covers the common set, not BidiMirroring.txt's full ~500 entries.
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
    reorder into visual (left-to-right-drawable) order, and mirror any
    paired character left at an odd (RTL) level. The result is a
    sequence a caller walks strictly left to right, accumulating glyph
    advances rightward, exactly as it walks a plain LTR line.

    Args:
        codepoints: A line's Unicode codepoints, in logical order.
        base_level: The paragraph's base embedding level -- 0 for LTR,
            1 for RTL, typically from detect_base_level.

    Returns:
        The codepoints in visual order, mirrored where an RTL level
        requires it.
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
