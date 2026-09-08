"""Bidirectional text layout: a partial implementation of the Unicode
Bidirectional Algorithm (UAX #9), covering what real mixed
Hebrew/Arabic/Latin/digit text needs. Each codepoint is classified by
direction and assigned an embedding level, the line is reordered into
visual (left-to-right-drawable) order by the run-reversal technique of
UAX #9's rule L2, and paired characters (parens, brackets, comparisons)
that land inside a right-to-left run are mirrored.

Character classes follow Unicode 15.0.

The explicit controls are implemented, not merely recognized: X1-X8's
directional status stack gives every character its embedding level and
override, so LRE/RLE raise the level of what they enclose, LRO/RLO
force its direction, PDF pops, and an LRI/RLI/FSI isolate gives its
contents a level of their own while itself belonging to the text
outside. FSI reads its direction from its first strong content (P2/P3
over the isolate). Overflow past BD2's depth limit of 125, and a PDF
with nothing to pop or one trapped inside an isolate, are counted
rather than applied, so a malformed run of controls cannot corrupt the
levels of the text after it. The controls are then dropped before
rendering rather than shaped into `.notdef` boxes.

Combining marks are recognized (rule W1: a mark takes the direction of
the character it attaches to) and reordering is done by cluster, so a
base and its marks stay together. The invisible strong marks
LRM/RLM/ALM set direction as they should.

A line with no explicit control in it skips X1-X8 entirely -- with
none, the algorithm can only return the paragraph level -- so an
ordinary label pays one comparison per codepoint and nothing else.

Not implemented here:

- UAX #9's full weak/neutral-type resolution (W1-W7, N0-N2), which
  collapses into two rules here: a mark takes its base's level (W1),
  and a neutral/weak run takes the level of the strong text next to
  it, or the level it is embedded in. Correct for digits, punctuation
  and spaces between words, not for every adjacency UAX #9 enumerates.
  The isolating run sequences of BD13 are not built either; neutral
  resolution runs over the line rather than per sequence.
- The full `Mn`/`Me` set: `_is_combining_mark` covers the scripts this
  package shapes (Latin, Hebrew, Arabic, Syriac, Thaana, NKo,
  Samaritan, Mandaic, and the general combining blocks), not the
  several hundred ranges UnicodeData.txt lists.
- Arabic contextual letter-shaping: this module reorders and mirrors
  existing codepoints only. `joining.mojo` picks each Arabic letter's
  contextual form, and `render.mojo` shapes each run `visual_runs`
  reports before reordering it, since joining is defined between
  logical neighbors.

Hebrew has no contextual shaping, so Hebrew text laid out through this
module renders fully.
"""


comptime _STRONG_L = 0
comptime _STRONG_R = 1
comptime _WEAK_NEUTRAL = 2
comptime _WEAK_NUMBER = 3
# An explicit directional formatting character: invisible, and not
# text. It takes the level of what surrounds it and is dropped before
# rendering.
comptime _EXPLICIT = 4
# A non-spacing combining mark (UAX #9's NSM). It takes the direction
# of the character it attaches to, and must never be separated from it.
comptime _MARK = 5

# The explicit formatting characters (UAX #9 table 2). LRE/RLE/LRO/RLO
# and PDF are the deprecated embedding controls; LRI/RLI/FSI and PDI
# are the isolates that replaced them.
comptime _LRE = 0x202A
comptime _RLE = 0x202B
comptime _PDF = 0x202C
comptime _LRO = 0x202D
comptime _RLO = 0x202E
comptime _LRI = 0x2066
comptime _RLI = 0x2067
comptime _FSI = 0x2068
comptime _PDI = 0x2069
# The invisible *strong* marks, which are text-like rather than
# structural: they carry a direction and nothing else.
comptime _LRM = 0x200E
comptime _RLM = 0x200F
comptime _ALM = 0x061C


def _is_isolate_initiator(cp: Int) -> Bool:
    return cp == _LRI or cp == _RLI or cp == _FSI


def _is_explicit_control(cp: Int) -> Bool:
    """The structural formatting characters, which have no glyph.
    LRM/RLM/ALM are deliberately not here: they are strong characters
    that happen to be invisible, and dropping them would lose the
    direction they exist to supply.
    """
    if cp >= _LRE and cp <= _RLO:
        return True
    return cp >= _LRI and cp <= _PDI


def _is_combining_mark(cp: Int) -> Bool:
    """Non-spacing marks, over the scripts this package shapes:
    Latin diacritics, Hebrew niqqud and cantillation, Arabic harakat
    and Quranic annotation, Syriac, Thaana, Samaritan, plus the
    general combining blocks. Unicode 15.1 ranges.

    Not the full `Mn`/`Me` set from UnicodeData.txt -- an exhaustive
    table would be several hundred ranges, and the scripts outside
    this list are ones nothing here shapes yet. A mark outside it is
    treated as an ordinary character, which is what happened to every
    mark before this function existed.
    """
    if cp < 0x0300:
        return False
    if cp <= 0x036F:  # Combining Diacritical Marks
        return True
    if cp >= 0x0483 and cp <= 0x0489:  # Cyrillic
        return True
    if cp >= 0x0591 and cp <= 0x05BD:  # Hebrew cantillation, niqqud
        return True
    if cp == 0x05BF or cp == 0x05C7:
        return True
    if cp >= 0x05C1 and cp <= 0x05C2:
        return True
    if cp >= 0x05C4 and cp <= 0x05C5:
        return True
    if cp >= 0x0610 and cp <= 0x061A:  # Arabic
        return True
    if cp >= 0x064B and cp <= 0x065F:
        return True
    if cp == 0x0670:
        return True
    if cp >= 0x06D6 and cp <= 0x06DC:
        return True
    if cp >= 0x06DF and cp <= 0x06E4:
        return True
    if cp >= 0x06E7 and cp <= 0x06E8:
        return True
    if cp >= 0x06EA and cp <= 0x06ED:
        return True
    if cp == 0x0711:  # Syriac
        return True
    if cp >= 0x0730 and cp <= 0x074A:
        return True
    if cp >= 0x07A6 and cp <= 0x07B0:  # Thaana
        return True
    if cp >= 0x07EB and cp <= 0x07F3:  # NKo
        return True
    if cp >= 0x0816 and cp <= 0x082D:  # Samaritan
        return True
    if cp >= 0x0859 and cp <= 0x085B:  # Mandaic
        return True
    if cp >= 0x08D3 and cp <= 0x08FF:  # Arabic Extended-A marks
        return True
    if cp >= 0x1AB0 and cp <= 0x1AFF:  # Combining Diacriticals Extended
        return True
    if cp >= 0x1DC0 and cp <= 0x1DFF:  # Combining Diacriticals Supplement
        return True
    if cp >= 0x20D0 and cp <= 0x20F0:  # Combining Diacriticals for Symbols
        return True
    if cp >= 0xFE20 and cp <= 0xFE2F:  # Combining Half Marks
        return True
    return False


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
    # Before the script ranges below: ALM sits inside the Arabic block
    # and the marks sit inside Hebrew and Arabic, so testing the
    # blocks first would swallow them.
    if cp == _LRM:
        return _STRONG_L
    if cp == _RLM or cp == _ALM:
        return _STRONG_R
    if _is_explicit_control(cp):
        return _EXPLICIT
    if _is_combining_mark(cp):
        return _MARK
    if (cp >= 0x21 and cp <= 0x2F) or (cp >= 0x3A and cp <= 0x40):
        return _WEAK_NEUTRAL
    # Latin and the blocks beside it are most of most text, and none
    # of what follows can match below U+0300: the combining marks
    # start there, Hebrew at U+0590, Arabic at U+0600, and every
    # formatting character including ALM is higher still. Answering
    # here saves that whole chain of range tests per codepoint on the
    # common line.
    if cp >= 0x41 and cp < 0x0300:
        return _STRONG_L

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


# UAX #9's cap on explicit depth (BD2). Past it the controls are
# overflow and take no effect, which is what the two overflow counters
# below track.
comptime _MAX_DEPTH = 125

# Directional override status carried on the explicit stack (X1).
comptime _OVERRIDE_NEUTRAL = 0
comptime _OVERRIDE_L = 1
comptime _OVERRIDE_R = 2


def _matching_pdi(codepoints: List[Int], start: Int) -> Int:
    """BD9: the PDI that matches the isolate initiator at `start`, or
    `len(codepoints)` if the initiator is unmatched.

    Scans forward counting nested initiators, so an inner isolate's
    PDI does not close the outer one.
    """
    var depth = 1
    for i in range(start + 1, len(codepoints)):
        var cp = codepoints[i]
        if _is_isolate_initiator(cp):
            depth += 1
        elif cp == _PDI:
            depth -= 1
            if depth == 0:
                return i
    return len(codepoints)


def _first_strong_level(codepoints: List[Int], start: Int, end: Int) -> Int:
    """P2/P3 over `[start, end)`: 1 if the first strong character is
    right-to-left, 0 otherwise, skipping anything inside a nested
    isolate. What FSI uses to decide which of LRI/RLI it stands for.
    """
    var i = start
    while i < end:
        var cp = codepoints[i]
        if _is_isolate_initiator(cp):
            i = _matching_pdi(codepoints, i)
            if i < end:
                i += 1
            continue
        var cls = _codepoint_class(cp)
        if cls == _STRONG_R:
            return 1
        if cls == _STRONG_L:
            return 0
        i += 1
    return 0


def _explicit_levels(
    codepoints: List[Int],
    base_level: Int,
    mut levels: List[Int],
    mut overrides: List[Int],
):
    """UAX #9 X1-X8: the embedding level and directional override each
    character sits at, once the explicit controls have been applied.

    A directional status stack holds (level, override, is_isolate).
    An embedding or override control pushes the next level of its
    direction; PDF pops one; an isolate initiator pushes and is itself
    left at the *outer* level, since it belongs to the text around it
    rather than the text it encloses; PDI pops back to that initiator's
    level and takes it too. Overflow past `_MAX_DEPTH`, or a PDF with
    nothing to pop, is counted rather than applied, so a malformed run
    of controls cannot corrupt the levels of the text after it.

    An override makes every character inside it strong in that
    direction regardless of its own class, which is the difference
    between LRE/RLE and LRO/RLO.
    """
    var n = len(codepoints)
    var stack_level = List[Int]()
    var stack_override = List[Int]()
    var stack_isolate = List[Bool]()
    stack_level.append(base_level)
    stack_override.append(_OVERRIDE_NEUTRAL)
    stack_isolate.append(False)
    var overflow_isolate = 0
    var overflow_embedding = 0
    var valid_isolate = 0

    for i in range(n):
        var cp = codepoints[i]
        var top = len(stack_level) - 1
        var cur = stack_level[top]

        if cp == _RLE or cp == _LRE or cp == _RLO or cp == _LRO:
            # X2-X5. The control itself sits at the level outside it.
            levels[i] = cur
            overrides[i] = stack_override[top]
            var rtl = cp == _RLE or cp == _RLO
            var next = (cur + 1) | 1 if rtl else (cur + 2) & ~1
            if (
                next <= _MAX_DEPTH
                and overflow_isolate == 0
                and overflow_embedding == 0
            ):
                stack_level.append(next)
                if cp == _RLO:
                    stack_override.append(_OVERRIDE_R)
                elif cp == _LRO:
                    stack_override.append(_OVERRIDE_L)
                else:
                    stack_override.append(_OVERRIDE_NEUTRAL)
                stack_isolate.append(False)
            elif overflow_isolate == 0:
                overflow_embedding += 1
            continue

        if _is_isolate_initiator(cp):
            # X5a-X5c. The initiator belongs to the text around it.
            levels[i] = cur
            overrides[i] = stack_override[top]
            var rtl = cp == _RLI
            if cp == _FSI:
                var close = _matching_pdi(codepoints, i)
                rtl = _first_strong_level(codepoints, i + 1, close) == 1
            var next = (cur + 1) | 1 if rtl else (cur + 2) & ~1
            if (
                next <= _MAX_DEPTH
                and overflow_isolate == 0
                and overflow_embedding == 0
            ):
                valid_isolate += 1
                stack_level.append(next)
                stack_override.append(_OVERRIDE_NEUTRAL)
                stack_isolate.append(True)
            else:
                overflow_isolate += 1
            continue

        if cp == _PDI:
            # X6a. Unwind to the matching initiator, then take its
            # level -- the PDI closes the isolate from outside it.
            if overflow_isolate > 0:
                overflow_isolate -= 1
            elif valid_isolate > 0:
                overflow_embedding = 0
                while not stack_isolate[len(stack_isolate) - 1]:
                    _ = stack_level.pop()
                    _ = stack_override.pop()
                    _ = stack_isolate.pop()
                _ = stack_level.pop()
                _ = stack_override.pop()
                _ = stack_isolate.pop()
                valid_isolate -= 1
            var t2 = len(stack_level) - 1
            levels[i] = stack_level[t2]
            overrides[i] = stack_override[t2]
            continue

        if cp == _PDF:
            # X7. A PDF inside an isolate, or with nothing to pop, is
            # ignored rather than escaping its isolate.
            levels[i] = cur
            overrides[i] = stack_override[top]
            if overflow_isolate > 0:
                pass
            elif overflow_embedding > 0:
                overflow_embedding -= 1
            elif (
                not stack_isolate[len(stack_isolate) - 1]
                and len(stack_level) >= 2
            ):
                _ = stack_level.pop()
                _ = stack_override.pop()
                _ = stack_isolate.pop()
                var t3 = len(stack_level) - 1
                levels[i] = stack_level[t3]
                overrides[i] = stack_override[t3]
            continue

        # X6: everything else takes the current level and override.
        levels[i] = cur
        overrides[i] = stack_override[top]


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
    # P2 skips everything between an isolate initiator and its
    # matching PDI: an isolate is opaque to the paragraph's direction,
    # which is the whole reason it is called one.
    var depth = 0
    for cp in codepoints:
        if _is_isolate_initiator(cp):
            depth += 1
            continue
        if cp == _PDI:
            if depth > 0:
                depth -= 1
            continue
        if depth > 0:
            continue
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

    # X1-X8 give every character its embedding level and override,
    # and the passes below then resolve *within* those rather than
    # against the paragraph level.
    #
    # A line with no explicit control cannot come out of X1-X8 as
    # anything but the paragraph level, so it skips the whole thing --
    # no stacks, no per-character arrays, and no reads of them below.
    # That is every ordinary label, and the check costs one comparison
    # per codepoint.
    var has_control = False
    for i in range(n):
        var cp = codepoints[i]
        if cp >= _LRE and cp <= _PDI and _is_explicit_control(cp):
            has_control = True
            break
    var explicit = List[Int]()
    var overrides = List[Int]()
    if has_control:
        explicit = List[Int](length=n, fill=base_level)
        overrides = List[Int](length=n, fill=_OVERRIDE_NEUTRAL)
        _explicit_levels(codepoints, base_level, explicit, overrides)

    # Two loops rather than one with a test in it: the no-control
    # case is every ordinary label, and it should not pay a branch per
    # character for a feature it is not using.
    if not has_control:
        var even = base_level % 2 == 0
        var l_level = base_level if even else base_level + 1
        var r_level = base_level + 1 if even else base_level
        for i in range(n):
            var cls = _codepoint_class(codepoints[i])
            if cls == _STRONG_L:
                levels[i] = l_level
            elif cls == _STRONG_R:
                levels[i] = r_level
    else:
        for i in range(n):
            var cls = _codepoint_class(codepoints[i])
            if overrides[i] == _OVERRIDE_L:
                cls = _STRONG_L
            elif overrides[i] == _OVERRIDE_R:
                cls = _STRONG_R
            var e = explicit[i]
            if cls == _STRONG_L:
                levels[i] = e if e % 2 == 0 else e + 1
            elif cls == _STRONG_R:
                levels[i] = e if e % 2 == 1 else e + 1
            elif _is_explicit_control(codepoints[i]):
                # Removed before rendering, but it must not split a
                # run: give it the level of the text it sits in.
                levels[i] = e

    var last_level = base_level
    for i in range(n):
        if levels[i] != -1:
            last_level = levels[i]
        elif _codepoint_class(codepoints[i]) == _WEAK_NUMBER:
            var level = last_level if last_level % 2 == 0 else last_level + 1
            levels[i] = level
            last_level = level

    # UAX #9 rule W1: a combining mark takes the direction of what it
    # attaches to. Run after the number pass so a mark on a digit
    # follows the digit. A mark whose predecessor is still unresolved
    # is left unresolved too, joining the neutral run around it, which
    # is what W1 gives once that run resolves.
    for i in range(n):
        if levels[i] == -1 and _codepoint_class(codepoints[i]) == _MARK:
            if i > 0 and levels[i - 1] != -1:
                levels[i] = levels[i - 1]

    var i = 0
    while i < n:
        if levels[i] == -1:
            var j = i
            while j < n and levels[j] == -1:
                j += 1
            var before = levels[i - 1] if i > 0 else -1
            var after = levels[j] if j < n else -1
            # A neutral run with no strong neighbour agreeing on a
            # side falls back to the level it is *embedded* in, not
            # the paragraph's -- inside an isolate those differ, and
            # using the paragraph level would pull the run out of the
            # isolate it belongs to.
            var own = explicit[i] if has_control else base_level
            var resolved: Int
            if before == -1 and after == -1:
                resolved = own
            elif before == -1:
                resolved = after
            elif after == -1:
                resolved = before
            elif before == after:
                resolved = before
            else:
                resolved = own
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


struct BidiRun(ImplicitlyCopyable, Movable):
    """One maximal span of a line at a single embedding level.
    `codepoints[start]` through `codepoints[start + length - 1]` are the
    run's characters *in logical order*; an odd `level` means the run
    draws right to left, so its glyphs reverse after they are shaped.
    """

    var start: Int
    var length: Int
    var level: Int

    def __init__(out self, start: Int, length: Int, level: Int):
        self.start = start
        self.length = length
        self.level = level

    def is_rtl(self) -> Bool:
        """Whether this run draws right to left.

        Returns:
            True for an odd embedding level.
        """
        return self.level % 2 == 1


def visual_runs(codepoints: List[Int], base_level: Int) -> List[BidiRun]:
    """The line's level runs, left to right, each still holding its
    characters in logical order.

    This is rule L2 applied at run granularity rather than to single
    positions, which is the same reordering: a maximal span of positions
    at or above some level is always a whole number of level runs, so
    reversing the runs and then reversing inside each odd-level run
    reproduces `visual_order`'s sequence exactly. Splitting it that way
    is what lets a caller shape each run against its *logical*
    neighbors -- Arabic joining and ligature formation are defined
    there, not against the reversed sequence -- and reorder afterwards.

    Args:
        codepoints: A line's Unicode codepoints, in logical order.
        base_level: The paragraph's base embedding level -- 0 for LTR,
            1 for RTL, typically from detect_base_level.

    Returns:
        The runs in visual order. A pure left-to-right line is one run.
    """
    var levels = _resolve_levels(codepoints, base_level)
    var n = len(levels)
    var starts = List[Int]()
    var lengths = List[Int]()
    var run_levels = List[Int]()
    var i = 0
    while i < n:
        var j = i + 1
        while j < n and levels[j] == levels[i]:
            j += 1
        starts.append(i)
        lengths.append(j - i)
        run_levels.append(levels[i])
        i = j

    var order = _reorder_indices(run_levels)
    var out = List[BidiRun](capacity=len(order))
    for idx in order:
        out.append(BidiRun(starts[idx], lengths[idx], run_levels[idx]))
    return out^


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

    Explicit formatting characters (LRE/RLE/LRO/RLO/PDF and the
    isolates) are dropped: they are structure, not text, and have no
    glyph. LRM/RLM/ALM are dropped for the same reason by the caller
    that renders, but are kept here because they are strong characters
    whose direction has already been used.

    Returns:
        The codepoints in visual order, mirrored where an RTL level
        requires it, with the explicit formatting characters removed.
    """
    var result = List[Int](capacity=len(codepoints))
    for run in visual_runs(codepoints, base_level):
        if run.is_rtl():
            # Reversed by cluster, not by codepoint. A combining mark
            # follows its base in logical order and has to keep
            # following it after the reversal, or the mark lands on
            # the previous letter -- a Hebrew word with niqqud comes
            # out with every point one letter to the right.
            var i = run.start + run.length - 1
            while i >= run.start:
                var base = i
                while base > run.start and _is_combining_mark(codepoints[base]):
                    base -= 1
                for k in range(base, i + 1):
                    if _codepoint_class(codepoints[k]) != _EXPLICIT:
                        result.append(_mirror_codepoint(codepoints[k]))
                i = base - 1
        else:
            for i in range(run.start, run.start + run.length):
                if _codepoint_class(codepoints[i]) != _EXPLICIT:
                    result.append(codepoints[i])
    return result^
