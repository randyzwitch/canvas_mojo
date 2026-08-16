"""DEFLATE decompression (RFC 1951) -- a direct translation of zlib's
own `puff.c` reference decoder (Mark Adler, zlib-licensed; "a simple
inflate written to be an unambiguous way to specify the deflate
format"), not independently re-derived from the RFC alone. Same
reasoning `canvas_mojo/glyph_outline.mojo`'s own docstring gives for
translating FreeType's `FT_Outline_Decompose` faithfully rather than
re-deriving TrueType outline decoding from memory: DEFLATE is a
closed, formally specified, decades-stable algorithm (unlike font
discovery/shaping, which `font_discovery.mojo`'s own docstring
explains are open-ended, system-dependent subsystems better left to a
linked library) -- exactly the kind of thing this package already
builds from spec elsewhere (Bresenham lines, midpoint circles, glyph
outlines), so writing it natively here rather than linking zlib is
consistent with that, not a special case.

Deliberately the "SLOW" (readable, bit-at-a-time) `decode()` variant
`puff.c` itself offers as an alternative to its faster table-driven
one -- correctness and clarity over speed, matching this whole
package's stance elsewhere (chart-sized images, not a video codec).

Verified against real zlib output, not just "translated carefully and
hoped": every stage was checked by round-tripping actual
`zlib.compress()` output (stored, fixed-Huffman, and dynamic-Huffman
blocks all separately exercised) back to the exact original bytes --
see canvas_mojo/tests/test_deflate.mojo.
"""

comptime _MAX_BITS = 15
comptime _MAX_L_CODES = 286
comptime _MAX_D_CODES = 30
comptime _MAX_CODES = _MAX_L_CODES + _MAX_D_CODES
comptime _FIX_L_CODES = 288


struct _BitReader(Movable):
    """Reads DEFLATE's own bit-packed stream: bits are packed into
    bytes LSB-first (RFC 1951 section 3.1.1), so a byte is consumed by
    shifting it into a buffer at the *top* (past whatever bits are
    already pending) and bits are read back out from the *bottom* --
    directly mirroring puff.c's own `bits()` function, including its
    "always leaves fewer than eight bits buffered" invariant.
    """

    var data: List[UInt8]
    var pos: Int
    var bitbuf: Int
    var bitcnt: Int

    def __init__(out self, var data: List[UInt8]):
        self.data = data^
        self.pos = 0
        self.bitbuf = 0
        self.bitcnt = 0

    def read_bits(mut self, need: Int) raises -> Int:
        var val = self.bitbuf
        while self.bitcnt < need:
            if self.pos >= len(self.data):
                raise Error("deflate: out of input")
            val |= Int(self.data[self.pos]) << self.bitcnt
            self.pos += 1
            self.bitcnt += 8
        self.bitbuf = val >> need
        self.bitcnt -= need
        return val & ((1 << need) - 1)

    def align_to_byte(mut self):
        """Discard any partial byte left in the bit buffer -- stored
        blocks (RFC 1951 3.2.4) always start byte-aligned.
        """
        self.bitbuf = 0
        self.bitcnt = 0

    def read_byte(mut self) raises -> UInt8:
        if self.pos >= len(self.data):
            raise Error("deflate: out of input")
        var b = self.data[self.pos]
        self.pos += 1
        return b


struct _Huffman(Movable):
    """Canonical Huffman decode tables -- `counts[length]` is the
    number of symbols of that length, `symbols` holds the symbol
    values sorted by (length, then original symbol order), matching
    puff.c's own `struct huffman` exactly. See `_decode`'s own
    docstring for how these two arrays alone are enough to decode.
    """

    var counts: List[Int]
    var symbols: List[Int]

    def __init__(out self, var counts: List[Int], var symbols: List[Int]):
        self.counts = counts^
        self.symbols = symbols^


def _construct(lengths: List[Int], n: Int, mut left_out: Int) raises -> _Huffman:
    """Direct translation of puff.c's `construct()`: given a length
    (0..MAX_BITS) per symbol for `n` symbols, builds the tables
    `_decode` needs. Raises for an over-subscribed code (more codes of
    some length than bits allow -- always invalid, regardless of
    context). An *incomplete* code is not raised here -- both a fixed
    block's own distance code and a dynamic block's single-symbol code
    are legitimately incomplete (RFC 1951 3.2.7's own "one distance
    code of one bit" case); only the caller knows whether
    incompleteness is acceptable for the code it just built, reported
    back via `left_out` (0 for a complete code, >0 for an incomplete
    one -- puff.c's own `construct()` return value). An out-parameter
    rather than a two-field return struct: extracting one field out of
    a local multi-field struct value hits a real Mojo ownership
    limitation ("field ... destroyed out of the middle of a value"),
    the same one `draw_target.mojo`'s own history documents for a
    move-in/move-out wrapper struct -- confirmed here directly (this
    function originally returned `_ConstructResult(table, left)`,
    and every call site's `result.table^` failed to compile with
    exactly that error) before switching to this shape instead.
    """
    var counts = List[Int](capacity=_MAX_BITS + 1)
    for _ in range(_MAX_BITS + 1):
        counts.append(0)
    for symbol in range(n):
        counts[lengths[symbol]] += 1

    if counts[0] == n:
        # No codes at all -- a valid, if useless, table (any decode()
        # call against it will fail), matching puff.c's own "complete,
        # but decode() will fail" comment.
        var empty_symbols = List[Int](capacity=n)
        for _ in range(n):
            empty_symbols.append(0)
        left_out = 0
        return _Huffman(counts^, empty_symbols^)

    var left = 1
    for length in range(1, _MAX_BITS + 1):
        left <<= 1
        left -= counts[length]
        if left < 0:
            raise Error("deflate: over-subscribed Huffman code")

    var offsets = List[Int](capacity=_MAX_BITS + 1)
    for _ in range(_MAX_BITS + 1):
        offsets.append(0)
    for length in range(1, _MAX_BITS):
        offsets[length + 1] = offsets[length] + counts[length]

    var symbols = List[Int](capacity=n)
    for _ in range(n):
        symbols.append(0)
    for symbol in range(n):
        if lengths[symbol] != 0:
            symbols[offsets[lengths[symbol]]] = symbol
            offsets[lengths[symbol]] += 1

    left_out = left
    return _Huffman(counts^, symbols^)


def _decode(mut reader: _BitReader, table: _Huffman) raises -> Int:
    """Direct translation of puff.c's own (readable, `#ifdef SLOW`)
    `decode()`: reads one bit at a time, building up a code value
    exactly as the canonical-Huffman construction algorithm (RFC 1951
    3.2.2) assigns them, and returns as soon as the accumulated
    (code, length) falls within the range assigned to that length --
    `_construct`'s own `counts`/`symbols` arrays are exactly what this
    range check needs, no full decode tree required.
    """
    var code = 0
    var first = 0
    var index = 0
    for length in range(1, _MAX_BITS + 1):
        code |= reader.read_bits(1)
        var count = table.counts[length]
        if code - count < first:
            return table.symbols[index + (code - first)]
        index += count
        first += count
        first <<= 1
        code <<= 1
    raise Error("deflate: invalid Huffman code (ran out of bits)")


def _codes(mut reader: _BitReader, mut out: List[UInt8], lencode: _Huffman, distcode: _Huffman) raises:
    """Direct translation of puff.c's `codes()`: decode literal/length
    and distance symbols until the end-of-block symbol (256). The
    length/distance base+extra-bits tables are RFC 1951 3.2.5's own,
    transcribed directly from the spec text, cross-checked against
    puff.c's identical tables. `List[Int]` literals are built fresh
    per call rather than as module-level `comptime` constants --
    `comptime List[Int]` doesn't materialize to a usable runtime value
    in this Mojo version (confirmed directly, the same issue
    bidi.mojo's own mirroring table hit and worked around); the
    negligible cost of rebuilding four small lists per block is a
    fine trade for not fighting that again here.
    """
    var lens: List[Int] = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
        35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
    ]
    var lext: List[Int] = [
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
        3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
    ]
    var dists: List[Int] = [
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
        257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
        8193, 12289, 16385, 24577,
    ]
    var dext: List[Int] = [
        0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
        7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
    ]

    while True:
        var symbol = _decode(reader, lencode)
        if symbol < 256:
            out.append(UInt8(symbol))
        elif symbol == 256:
            break
        else:
            symbol -= 257
            if symbol >= 29:
                raise Error("deflate: invalid length code")
            var length = lens[symbol] + reader.read_bits(lext[symbol])

            var dsymbol = _decode(reader, distcode)
            if dsymbol >= 30:
                raise Error("deflate: invalid distance code")
            var dist = dists[dsymbol] + reader.read_bits(dext[dsymbol])
            if dist > len(out):
                raise Error("deflate: distance too far back")

            # Forward, one byte at a time -- not a bulk copy. Overlapping
            # copies (length > distance) are legal and common (e.g. dist=1
            # repeats the last byte `length` times); each iteration reads
            # from the *already-growing* `out`, exactly reproducing that
            # overlap the way puff.c's own byte-at-a-time loop does (its
            # own comment explicitly warns memcpy/memmove are wrong here).
            var start = len(out) - dist
            for i in range(length):
                out.append(out[start + i])


def _stored_block(mut reader: _BitReader, mut out: List[UInt8]) raises:
    """RFC 1951 3.2.4 -- a raw, uncompressed block: byte-align, read
    LEN/NLEN (little-endian, NLEN is LEN's one's complement, checked
    the same way `canvas_mojo/io/png.mojo`'s own writer produces it),
    then copy LEN bytes straight through.
    """
    reader.align_to_byte()
    var len_lo = Int(reader.read_byte())
    var len_hi = Int(reader.read_byte())
    var length = len_lo | (len_hi << 8)
    var nlen_lo = Int(reader.read_byte())
    var nlen_hi = Int(reader.read_byte())
    var nlen = nlen_lo | (nlen_hi << 8)
    if nlen != (0xFFFF ^ length):
        raise Error("deflate: stored block LEN/NLEN mismatch")
    for _ in range(length):
        out.append(reader.read_byte())


struct _CodeTables(Movable):
    var lencode: _Huffman
    var distcode: _Huffman

    def __init__(out self, var lencode: _Huffman, var distcode: _Huffman):
        self.lencode = lencode^
        self.distcode = distcode^


def _fixed_tables() raises -> _CodeTables:
    """RFC 1951 3.2.6 -- the literal/length and distance Huffman codes
    for BTYPE=01 are fixed by the spec itself (not transmitted); the
    exact bit-length breakpoints below (0-143 -> 8 bits, 144-255 -> 9,
    256-279 -> 7, 280-287 -> 8; all 30 distance codes -> 5 bits) are
    the spec's own table, matching puff.c's `fixed()` construction.
    """
    var lengths = List[Int](capacity=_FIX_L_CODES)
    for _ in range(144):
        lengths.append(8)
    for _ in range(144, 256):
        lengths.append(9)
    for _ in range(256, 280):
        lengths.append(7)
    for _ in range(280, _FIX_L_CODES):
        lengths.append(8)
    var lit_left = 0
    var lit_table = _construct(lengths, _FIX_L_CODES, lit_left)

    var dlengths = List[Int](capacity=_MAX_D_CODES)
    for _ in range(_MAX_D_CODES):
        dlengths.append(5)
    var dist_left = 0
    var dist_table = _construct(dlengths, _MAX_D_CODES, dist_left)

    return _CodeTables(lit_table^, dist_table^)


def _dynamic_tables(mut reader: _BitReader) raises -> _CodeTables:
    """RFC 1951 3.2.7 -- a dynamic block transmits its own literal/
    length and distance code lengths, themselves Huffman-coded via a
    third, small "code length" alphabet (0-15 literal lengths, 16/17/18
    run-length instructions), whose own lengths arrive as 19 plain
    3-bit values in the permuted `order` below (the spec's own
    ordering, chosen so a short code-length-code list -- the common
    case -- stays short). Direct translation of puff.c's `dynamic()`.
    """
    var order: List[Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    var nlen = reader.read_bits(5) + 257
    var ndist = reader.read_bits(5) + 1
    var ncode = reader.read_bits(4) + 4
    if nlen > _MAX_L_CODES or ndist > _MAX_D_CODES:
        raise Error("deflate: too many length/distance codes")

    var lengths = List[Int](capacity=_MAX_CODES)
    for _ in range(_MAX_CODES):
        lengths.append(0)
    for index in range(ncode):
        lengths[order[index]] = reader.read_bits(3)
    for index in range(ncode, 19):
        lengths[order[index]] = 0

    var cl_lengths = List[Int](capacity=19)
    for i in range(19):
        cl_lengths.append(lengths[i])
    var cl_left = 0
    var cl_code = _construct(cl_lengths, 19, cl_left)
    if cl_left != 0:
        raise Error("deflate: incomplete code-length code")

    var index = 0
    while index < nlen + ndist:
        var symbol = _decode(reader, cl_code)
        if symbol < 16:
            lengths[index] = symbol
            index += 1
        else:
            var repeat_value = 0
            var repeat_count: Int
            if symbol == 16:
                if index == 0:
                    raise Error("deflate: repeat code with no previous length")
                repeat_value = lengths[index - 1]
                repeat_count = 3 + reader.read_bits(2)
            elif symbol == 17:
                repeat_count = 3 + reader.read_bits(3)
            else:
                repeat_count = 11 + reader.read_bits(7)
            if index + repeat_count > nlen + ndist:
                raise Error("deflate: repeat count exceeds code length list")
            for _ in range(repeat_count):
                lengths[index] = repeat_value
                index += 1

    if lengths[256] == 0:
        raise Error("deflate: dynamic block missing end-of-block code")

    var lit_lengths = List[Int](capacity=nlen)
    for i in range(nlen):
        lit_lengths.append(lengths[i])
    var lit_left = 0
    var lit_table = _construct(lit_lengths, nlen, lit_left)
    if lit_left != 0 and nlen != lit_table.counts[0] + lit_table.counts[1]:
        raise Error("deflate: invalid literal/length code lengths")

    var dist_lengths = List[Int](capacity=ndist)
    for i in range(ndist):
        dist_lengths.append(lengths[nlen + i])
    var dist_left = 0
    var dist_table = _construct(dist_lengths, ndist, dist_left)
    if dist_left != 0 and ndist != dist_table.counts[0] + dist_table.counts[1]:
        raise Error("deflate: invalid distance code lengths")

    return _CodeTables(lit_table^, dist_table^)


def inflate(var compressed: List[UInt8]) raises -> List[UInt8]:
    """Decompress a raw DEFLATE stream (RFC 1951) -- not a zlib stream
    (RFC 1950); callers with a zlib-wrapped stream (PNG's own IDAT
    data, for one) strip the 2-byte header and 4-byte Adler-32 trailer
    first (see canvas_mojo/io/png.mojo). Direct translation of puff.c's
    own top-level `puff()` driver loop. Takes ownership of `compressed`
    (moved into the internal bit reader) rather than copying it --
    `List[UInt8]` isn't cheaply copyable, and no caller needs its own
    buffer back afterward.
    """
    var reader = _BitReader(compressed^)
    var out = List[UInt8]()
    while True:
        var last = reader.read_bits(1)
        var block_type = reader.read_bits(2)
        if block_type == 0:
            _stored_block(reader, out)
        elif block_type == 1:
            var tables = _fixed_tables()
            _codes(reader, out, tables.lencode, tables.distcode)
        elif block_type == 2:
            var tables = _dynamic_tables(reader)
            _codes(reader, out, tables.lencode, tables.distcode)
        else:
            raise Error("deflate: invalid block type (3, reserved)")
        if last == 1:
            break
    return out^
