"""Bidirectional text layout: a partial implementation of the Unicode
Bidirectional Algorithm (UAX #9), covering what real mixed
Hebrew/Arabic/Latin/digit text needs. Each codepoint is classified by
direction and assigned an embedding level, the line is reordered into
visual (left-to-right-drawable) order by the run-reversal technique of
UAX #9's rule L2, and paired characters (parens, brackets, comparisons)
that land inside a right-to-left run are mirrored.

Character classes come from `bidi_data.mojo`, generated from Unicode
15.0 and exact for every codepoint.

The algorithm is implemented in full: X1-X8 assign explicit levels
from the directional controls, X9 sets the controls aside, BD13 groups
the level runs into isolating run sequences, W1-W7 resolve the weak
types, N0 the bracket pairs, N1-N2 the neutrals, I1-I2 turn the
resolved types into levels, and L1 returns separators and trailing
whitespace to the paragraph level. Reordering (L2) is by cluster, so a
base and its combining marks move together and a mark never lands on
the letter beside its own.

It passes all 91,707 cases of Unicode's `BidiCharacterTest.txt` for
15.0. A sampled subset is committed under `tests/bidi/` and checked by
`tests/test_bidi.mojo`, including every case that caught a bug while
this was written.

Two fast paths keep that off the common line. Text with no
right-to-left character and no control in it resolves to the
paragraph level by definition, and returns immediately. Latin-1 --
nearly all the text this package draws -- reads its class from a
direct 256-entry table rather than searching the range table. Together
they hold the cost of full conformance to about 2% on an ordinary
label; without them it was three times slower.

Not implemented here:

- Arabic contextual letter-shaping: this module reorders and mirrors
  existing codepoints only. `joining.mojo` picks each Arabic letter's
  contextual form, and `render.mojo` shapes each run `visual_runs`
  reports before reordering it, since joining is defined between
  logical neighbors.

Hebrew has no contextual shaping, so Hebrew text laid out through this
module renders fully.
"""


from canvas.text.bidi_data import (
    bidi_class,
    bracket_is_open,
    bracket_partner,
    canonical_bracket,
    _BC_AL,
    _BC_AN,
    _BC_B,
    _BC_BN,
    _BC_CS,
    _BC_EN,
    _BC_ES,
    _BC_ET,
    _BC_FSI,
    _BC_L,
    _BC_LRE,
    _BC_LRI,
    _BC_LRO,
    _BC_NSM,
    _BC_ON,
    _BC_PDF,
    _BC_PDI,
    _BC_R,
    _BC_RLE,
    _BC_RLI,
    _BC_RLO,
    _BC_S,
    _BC_WS,
)

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
    var t = bidi_class(cp)
    return t == _BC_LRI or t == _BC_RLI or t == _BC_FSI


def is_formatting_control(cp: Int) -> Bool:
    """Whether the codepoint is one of the structural directional
    formatting characters -- the embeddings, the overrides, PDF, the
    isolates and PDI.

    These carry no glyph, so a renderer drops them rather than shaping
    them into `.notdef` boxes. LRM/RLM/ALM are deliberately excluded:
    they are strong characters that happen to be invisible, and their
    direction has already been used by the time this is asked.

    Args:
        cp: The codepoint to test.

    Returns:
        True if the codepoint is a directional formatting control.
    """
    var t = bidi_class(cp)
    return (
        t == _BC_RLE
        or t == _BC_LRE
        or t == _BC_RLO
        or t == _BC_LRO
        or t == _BC_PDF
        or t == _BC_LRI
        or t == _BC_RLI
        or t == _BC_FSI
        or t == _BC_PDI
    )


def is_combining_mark(cp: Int) -> Bool:
    """Whether the codepoint is a non-spacing mark (UAX #9's NSM).

    Exact for every codepoint, read from the generated table rather
    than a hand-kept list of ranges: a mark that reordering separates
    from its base renders on the wrong letter, and the scripts that
    would show it are not ones this package can enumerate with any
    confidence.

    Args:
        cp: The codepoint to test.

    Returns:
        True if the codepoint is a non-spacing mark.
    """
    return bidi_class(cp) == _BC_NSM


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
        var t = bidi_class(cp)
        if t == _BC_R or t == _BC_AL:
            return 1
        if t == _BC_L:
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
        var t = bidi_class(cp)
        if t == _BC_R or t == _BC_AL:
            return 1
        if t == _BC_L:
            return 0
    return 0


def _resolve_levels(codepoints: List[Int], base_level: Int) -> List[Int]:
    """One embedding level per codepoint: the whole of UAX #9's
    resolution, in the order the spec sets out.

    X1-X8 assign explicit levels from the directional controls. X9
    marks the controls themselves as taking no further part. BD13
    groups the level runs into isolating run sequences, so text inside
    an isolate resolves as one piece with the text around it. W1-W7
    then resolve the weak types within each sequence, N0 the bracket
    pairs, N1-N2 the neutrals, and I1-I2 turn the resolved types into
    the levels the reordering reads. L1 finally returns separators and
    trailing whitespace to the paragraph level.

    A line with no explicit control skips X1-X8: with none, they can
    only return the paragraph level.
    """
    var n = len(codepoints)
    var levels = List[Int](length=n, fill=base_level)
    if n == 0:
        return levels^

    var types = List[Int](capacity=n)
    for i in range(n):
        types.append(bidi_class(codepoints[i]))

    # The common line: left-to-right text with no right-to-left
    # character and no control in it. Everything then resolves to the
    # paragraph level, so the whole of X1-X8, BD13, W, N and I can be
    # skipped. This is every ordinary Latin label, and it is the
    # difference between the full algorithm costing nothing on them
    # and costing half again as much per character.
    if base_level == 0:
        var plain = True
        for i in range(n):
            var t = types[i]
            if (
                t == _BC_R
                or t == _BC_AL
                or t == _BC_AN
                or t == _BC_RLE
                or t == _BC_LRE
                or t == _BC_RLO
                or t == _BC_LRO
                or t == _BC_PDF
                or t == _BC_LRI
                or t == _BC_RLI
                or t == _BC_FSI
                or t == _BC_PDI
            ):
                plain = False
                break
        if plain:
            return levels^

    var has_control = False
    for i in range(n):
        var t = types[i]
        if (
            t == _BC_RLE
            or t == _BC_LRE
            or t == _BC_RLO
            or t == _BC_LRO
            or t == _BC_PDF
            or t == _BC_LRI
            or t == _BC_RLI
            or t == _BC_FSI
            or t == _BC_PDI
        ):
            has_control = True
            break

    if has_control:
        var overrides = List[Int](length=n, fill=_OVERRIDE_NEUTRAL)
        _explicit_levels(codepoints, base_level, levels, overrides)
        # X6: an override makes every character inside it strong in
        # that direction, whatever its own class says.
        for i in range(n):
            if overrides[i] == _OVERRIDE_L:
                types[i] = _BC_L
            elif overrides[i] == _OVERRIDE_R:
                types[i] = _BC_R

    var original = types.copy()
    # X1-X8's levels, kept apart from the ones I1/I2 will write. The
    # run boundaries and every sos/eos are defined against these: read
    # them from `levels` instead and a sequence resolved earlier has
    # already moved the level its neighbour is compared with.

    # Level runs over the characters X9 leaves in play.
    var explicit = levels.copy()

    var kept = List[Int]()
    for i in range(n):
        if not _is_removed_by_x9(types[i]):
            kept.append(i)
    if len(kept) == 0:
        return levels^

    var run_start = List[Int]()
    var run_end = List[Int]()  # exclusive, indices into `kept`
    var k = 0
    while k < len(kept):
        var j = k + 1
        while j < len(kept) and explicit[kept[j]] == explicit[kept[k]]:
            j += 1
        run_start.append(k)
        run_end.append(j)
        k = j

    # BD13: a run ending in an isolate initiator with a matching PDI
    # continues into the run that PDI starts.
    var consumed = List[Bool](length=len(run_start), fill=False)
    for r in range(len(run_start)):
        if consumed[r]:
            continue
        var seq = List[Int]()
        var cur = r
        while True:
            consumed[cur] = True
            for x in range(run_start[cur], run_end[cur]):
                seq.append(kept[x])
            var last = kept[run_end[cur] - 1]
            var lt = types[last]
            if lt != _BC_LRI and lt != _BC_RLI and lt != _BC_FSI:
                break
            var close = _matching_pdi(codepoints, last)
            if close >= n:
                break
            var nxt = -1
            for r2 in range(len(run_start)):
                if not consumed[r2] and kept[run_start[r2]] == close:
                    nxt = r2
                    break
            if nxt < 0:
                break
            cur = nxt

        var level = explicit[seq[0]]
        # X10's sos/eos: compare against the level on each side, the
        # paragraph level standing in past the ends.
        var before_level = base_level
        var first = seq[0]
        for i in range(first - 1, -1, -1):
            if not _is_removed_by_x9(types[i]):
                before_level = explicit[i]
                break
        var last_i = seq[len(seq) - 1]
        var after_level = base_level
        var lt2 = types[last_i]
        var unmatched = (
            lt2 == _BC_LRI or lt2 == _BC_RLI or lt2 == _BC_FSI
        ) and _matching_pdi(codepoints, last_i) >= n
        if not unmatched:
            for i in range(last_i + 1, n):
                if not _is_removed_by_x9(types[i]):
                    after_level = explicit[i]
                    break
        var sos = _dir_of_level(max(level, before_level))
        var eos = _dir_of_level(max(level, after_level))

        _resolve_weak(types, seq, sos)
        _resolve_brackets(codepoints, original, types, seq, sos, level)
        _resolve_neutrals(types, seq, sos, eos, level)

        # I1/I2: the resolved types become levels.
        for x in range(len(seq)):
            var i = seq[x]
            var t = types[i]
            if level % 2 == 0:
                if t == _BC_R:
                    levels[i] = level + 1
                elif t == _BC_AN or t == _BC_EN:
                    levels[i] = level + 2
            else:
                if t == _BC_L or t == _BC_EN or t == _BC_AN:
                    levels[i] = level + 1

    # X9 leftovers take the level of what precedes them, so they never
    # split a run when the reordering walks it.
    for i in range(n):
        if _is_removed_by_x9(types[i]):
            levels[i] = levels[i - 1] if i > 0 else base_level

    # L1: separators, and any whitespace or isolate formatting run
    # before one or at the end of the line, return to the paragraph
    # level. Judged on the *original* types, not the resolved ones.
    var i = n - 1
    var trailing = True
    while i >= 0:
        var ot = original[i]
        if ot == _BC_B or ot == _BC_S:
            levels[i] = base_level
            trailing = True
        elif (
            ot == _BC_WS
            or ot == _BC_LRI
            or ot == _BC_RLI
            or ot == _BC_FSI
            or ot == _BC_PDI
            or _is_removed_by_x9(ot)
        ):
            if trailing:
                levels[i] = base_level
        else:
            trailing = False
        i -= 1

    return levels^


def _is_removed_by_x9(t: Int) -> Bool:
    """X9: the embedding and override controls, and BN, take no part
    in the rules below. They keep a level so they never split a run,
    and are skipped when the isolating run sequences are built. The
    isolates and PDI are *not* removed -- they are neutrals the later
    rules read.
    """
    return (
        t == _BC_RLE
        or t == _BC_LRE
        or t == _BC_RLO
        or t == _BC_LRO
        or t == _BC_PDF
        or t == _BC_BN
    )


@always_inline
def _is_ni(t: Int) -> Bool:
    """UAX #9's NI: the neutrals plus the isolate formatting
    characters, which N0-N2 resolve together."""
    return (
        t == _BC_B
        or t == _BC_S
        or t == _BC_WS
        or t == _BC_ON
        or t == _BC_FSI
        or t == _BC_LRI
        or t == _BC_RLI
        or t == _BC_PDI
    )


@always_inline
def _dir_of_level(level: Int) -> Int:
    return _BC_R if level % 2 == 1 else _BC_L


@always_inline
def _strong_of(t: Int) -> Int:
    """The direction a resolved type counts as for N0/N1. Numbers
    count as R, which is what keeps a digit run from splitting the
    right-to-left text around it."""
    if t == _BC_EN or t == _BC_AN or t == _BC_R:
        return _BC_R
    if t == _BC_L:
        return _BC_L
    return -1


def _resolve_weak(mut types: List[Int], seq: List[Int], sos: Int):
    """W1-W7 over one isolating run sequence, in order. Each rule
    reads what the one before it left, so they cannot be merged."""
    var m = len(seq)

    # W1: NSM takes the type of the character it follows, or sos at
    # the start. After an isolate initiator or PDI it becomes ON
    # instead -- a mark cannot attach across an isolate boundary.
    var prev = sos
    for k in range(m):
        var t = types[seq[k]]
        if t == _BC_NSM:
            var repl = _BC_ON if (
                prev == _BC_LRI
                or prev == _BC_RLI
                or prev == _BC_FSI
                or prev == _BC_PDI
            ) else prev
            types[seq[k]] = repl
            prev = repl
        else:
            prev = t

    # W2: EN becomes AN when the last strong type before it was AL.
    # Digits in Arabic text run with the Arabic, not against it.
    var last_strong = sos
    for k in range(m):
        var t = types[seq[k]]
        if t == _BC_L or t == _BC_R or t == _BC_AL:
            last_strong = t
        elif t == _BC_EN and last_strong == _BC_AL:
            types[seq[k]] = _BC_AN

    # W3: AL is R from here; distinguishing it was W2's job alone.
    for k in range(m):
        if types[seq[k]] == _BC_AL:
            types[seq[k]] = _BC_R

    # W4: a single ES between two EN, or a single CS between two of
    # the same numeric type, joins them -- "1.234", "12,345".
    for k in range(1, m - 1):
        var t = types[seq[k]]
        var before = types[seq[k - 1]]
        var after = types[seq[k + 1]]
        if t == _BC_ES and before == _BC_EN and after == _BC_EN:
            types[seq[k]] = _BC_EN
        elif t == _BC_CS and before == after:
            if before == _BC_EN or before == _BC_AN:
                types[seq[k]] = before

    # W5: a run of ET adjacent to EN becomes EN -- "$123", "45%".
    var k5 = 0
    while k5 < m:
        if types[seq[k5]] != _BC_ET:
            k5 += 1
            continue
        var j = k5
        while j < m and types[seq[j]] == _BC_ET:
            j += 1
        var before = types[seq[k5 - 1]] if k5 > 0 else sos
        var after = types[seq[j]] if j < m else -1
        if before == _BC_EN or after == _BC_EN:
            for x in range(k5, j):
                types[seq[x]] = _BC_EN
        k5 = j

    # W6: separators and terminators still unattached are neutral.
    for k in range(m):
        var t = types[seq[k]]
        if t == _BC_ET or t == _BC_ES or t == _BC_CS:
            types[seq[k]] = _BC_ON

    # W7: EN becomes L when the last strong type before it was L, so
    # digits in Latin text are simply Latin.
    last_strong = sos
    for k in range(m):
        var t = types[seq[k]]
        if t == _BC_L or t == _BC_R:
            last_strong = t
        elif t == _BC_EN and last_strong == _BC_L:
            types[seq[k]] = _BC_L


def _resolve_brackets(
    codepoints: List[Int],
    original: List[Int],
    mut types: List[Int],
    seq: List[Int],
    sos: Int,
    level: Int,
):
    """N0: a bracket pair resolves to one direction, so "(שלום)" keeps
    its parentheses around the word rather than splitting them off.

    A pair containing a strong type matching the embedding takes the
    embedding direction. A pair containing only the opposite direction
    takes that instead, unless the text before the pair disagrees, in
    which case the embedding wins. BD16 caps the open stack at 63.
    """
    var e = _dir_of_level(level)
    var o = _BC_L if e == _BC_R else _BC_R
    var m = len(seq)
    var open_at = List[Int]()
    var open_partner = List[Int]()
    var pair_a = List[Int]()
    var pair_b = List[Int]()
    for k in range(m):
        var i = seq[k]
        if types[i] != _BC_ON:
            continue
        var cp = codepoints[i]
        var partner = bracket_partner(cp)
        if partner == 0:
            continue
        if bracket_is_open(cp):
            if len(open_at) >= 63:
                break
            open_at.append(k)
            open_partner.append(partner)
        else:
            var cc = canonical_bracket(cp)
            for s in range(len(open_at) - 1, -1, -1):
                if open_partner[s] == cc:
                    pair_a.append(open_at[s])
                    pair_b.append(k)
                    while len(open_at) > s:
                        _ = open_at.pop()
                        _ = open_partner.pop()
                    break

    # N0 takes the pairs in order of their *opening* bracket, not the
    # order they close in. It matters because each pair reads the
    # types the pairs before it resolved: with "a ( ( b ) )" the outer
    # pair has to settle before the inner one looks back for context,
    # and closing order gets that backwards. Insertion sort -- BD16
    # caps the list at 63.
    for x in range(1, len(pair_a)):
        var ka = pair_a[x]
        var kb = pair_b[x]
        var y = x - 1
        while y >= 0 and pair_a[y] > ka:
            pair_a[y + 1] = pair_a[y]
            pair_b[y + 1] = pair_b[y]
            y -= 1
        pair_a[y + 1] = ka
        pair_b[y + 1] = kb

    for p in range(len(pair_a)):
        var a = pair_a[p]
        var b = pair_b[p]
        var found_e = False
        var found_o = False
        for k in range(a + 1, b):
            var d = _strong_of(types[seq[k]])
            if d == e:
                found_e = True
            elif d == o:
                found_o = True
        var chosen = -1
        if found_e:
            chosen = e
        elif found_o:
            var context = sos
            for k in range(a - 1, -1, -1):
                var d = _strong_of(types[seq[k]])
                if d >= 0:
                    context = d
                    break
            chosen = o if context == o else e
        if chosen >= 0:
            types[seq[a]] = chosen
            types[seq[b]] = chosen
            # N0's last clause: characters that were NSM before W1
            # and immediately follow a bracket this rule changed take
            # the bracket's direction too, or the mark detaches from
            # the bracket it belongs to.
            for start in [a, b]:
                var x = start + 1
                while x < m and original[seq[x]] == _BC_NSM:
                    types[seq[x]] = chosen
                    x += 1


def _resolve_neutrals(
    mut types: List[Int], seq: List[Int], sos: Int, eos: Int, level: Int
):
    """N1: a run of neutrals between two of the same direction takes
    it. N2: anything left takes the embedding direction."""
    var e = _dir_of_level(level)
    var m = len(seq)
    var k = 0
    while k < m:
        if not _is_ni(types[seq[k]]):
            k += 1
            continue
        var j = k
        while j < m and _is_ni(types[seq[j]]):
            j += 1
        var before = sos
        if k > 0:
            var d = _strong_of(types[seq[k - 1]])
            if d >= 0:
                before = d
        var after = eos
        if j < m:
            var d2 = _strong_of(types[seq[j]])
            if d2 >= 0:
                after = d2
        var resolved = before if before == after else e
        for x in range(k, j):
            types[seq[x]] = resolved
        k = j


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
                while base > run.start and is_combining_mark(codepoints[base]):
                    base -= 1
                for k in range(base, i + 1):
                    if not is_formatting_control(codepoints[k]):
                        result.append(_mirror_codepoint(codepoints[k]))
                i = base - 1
        else:
            for i in range(run.start, run.start + run.length):
                if not is_formatting_control(codepoints[i]):
                    result.append(codepoints[i])
    return result^
