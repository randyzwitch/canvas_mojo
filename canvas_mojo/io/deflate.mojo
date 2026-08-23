"""DEFLATE (RFC 1951): decompression, a direct translation of zlib's
own `puff.c` reference decoder (Mark Adler, zlib-licensed; "a simple
inflate written to be an unambiguous way to specify the deflate
format"), not independently re-derived from the RFC alone; and
compression, a from-scratch LZ77 + fixed-Huffman encoder (`deflate()`,
below `inflate()` in this file) built directly against the RFC's own
text once `inflate()` already existed to round-trip-verify it against
(see that function's own docstring for how). Translating a reference
implementation faithfully is the same discipline
`canvas_mojo/text/ttf.mojo` applies to the OpenType spec: DEFLATE is a
closed, formally specified, decades-stable algorithm (unlike font
discovery/shaping, which `canvas_mojo/text/font_discovery.mojo`'s own
docstring explains are open-ended, system-dependent subsystems better
left to a linked library) -- exactly the kind of thing this package
builds from spec elsewhere (Bresenham lines, midpoint circles, glyph
outlines), so writing it natively here rather than linking zlib (or
any other compression tool) is consistent with that, not a special
case.

`inflate()` is deliberately the "SLOW" (readable, bit-at-a-time)
`decode()` variant `puff.c` itself offers as an alternative to its
faster table-driven one -- correctness and clarity over speed,
matching this whole package's stance elsewhere (chart-sized images,
not a video codec). `deflate()` makes the identical trade on the
encode side: a single fixed-Huffman block (RFC 1951 3.2.6, BTYPE=01 --
no dynamic Huffman tree to build/transmit) over a straightforward
hash-chain LZ77 match finder (bounded search depth, see `_MAX_CHAIN`)
-- real compression, not maximal compression; canvas_mojo.io.png's own
`write_png` is this package's own first real caller, see that module's
own docstring for what "real enough" means for images this size.

Verified against real zlib output, not just "translated carefully and
hoped": `inflate()`'s every stage was checked by round-tripping actual
`zlib.compress()` output (stored, fixed-Huffman, and dynamic-Huffman
blocks all separately exercised) back to the exact original bytes.
`deflate()` is checked the same way in reverse -- its own output fed
back through `inflate()` (round-trip identity, the strongest check
available once a verified decoder already exists) AND independently
through Python's `zlib.decompress()` (a completely separate
implementation, catching a bug the two if they happened to share one)
-- see tests/test_deflate.mojo.
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


struct _BitWriter(Movable):
    """Writes DEFLATE's own bit-packed stream -- the exact inverse of
    _BitReader (see that struct's own docstring for the LSB-first
    packing convention both share): each write_bits() call shifts the
    new bits in above whatever's already pending in `bitbuf`'s low
    bits, flushing a full byte out to `data` every time 8 or more bits
    accumulate.
    """

    var data: List[UInt8]
    var bitbuf: Int
    var bitcnt: Int

    def __init__(out self):
        self.data = List[UInt8]()
        self.bitbuf = 0
        self.bitcnt = 0

    def write_bits(mut self, value: Int, nbits: Int):
        self.bitbuf |= (value & ((1 << nbits) - 1)) << self.bitcnt
        self.bitcnt += nbits
        while self.bitcnt >= 8:
            self.data.append(UInt8(self.bitbuf & 0xFF))
            self.bitbuf >>= 8
            self.bitcnt -= 8

    def write_code(mut self, code: Int, nbits: Int):
        """Huffman codes are packed *most*-significant-bit first (RFC
        1951 3.2.2) -- the one field in the whole format that isn't
        packed LSB-first the way write_bits (and every other DEFLATE
        field: BFINAL, BTYPE, length/distance extra bits) is. Writes
        one bit at a time, `code`'s own top bit first, each individual
        bit pushed through the ordinary LSB-oriented write_bits (no
        ordering ambiguity for a single bit) -- confirmed against
        _decode's own read order, not just asserted: _decode builds its
        `code` by treating the *first* bit it reads as that value's
        *most*-significant bit (`code |= read_bits(1)` before each
        `code <<= 1`), so writing top-bit-first here is what makes an
        encoded symbol actually round-trip back through the existing,
        already-verified decoder.
        """
        for i in range(nbits - 1, -1, -1):
            self.write_bits((code >> i) & 1, 1)

    def finish(mut self) raises -> List[UInt8]:
        """Flush any partial final byte -- DEFLATE's last byte is
        zero-padded in its unused high bits, exactly what's already
        sitting in `bitbuf` above `bitcnt`'s own valid bits. Returns a
        copy of `self.data` rather than moving it out -- `mut self` is
        a borrow, not ownership, so `self` has to stay in a valid
        state after this returns; `List[UInt8]` isn't *implicitly*
        copyable (the same reason inflate()'s own docstring gives for
        taking its input by ownership instead), but it does offer an
        explicit `.copy()` -- one bulk copy rather than an
        element-by-element loop, which matters here since `self.data`
        is the *entire* DEFLATE-compressed output, easily tens to
        hundreds of KB for a real image.
        """
        if self.bitcnt > 0:
            self.data.append(UInt8(self.bitbuf & 0xFF))
            self.bitbuf = 0
            self.bitcnt = 0
        return self.data.copy()


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
    limitation ("field ... destroyed out of the middle of a value") --
    confirmed here directly: returning a `_ConstructResult(table,
    left)` struct instead makes every call site's `result.table^` fail
    to compile with exactly that error.
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


comptime _MIN_MATCH = 3
comptime _MAX_MATCH = 258
comptime _WINDOW = 32768
# How many candidate prior positions a match search checks (and how
# many a hash bucket keeps on hand at all) -- a speed/ratio knob, not
# a correctness one: fewer candidates just means settling for a
# shorter or more distant match than an exhaustive search might find,
# never an invalid one. 32 is a conservative, "good enough" choice
# (real encoders often go much higher at their own top compression
# levels) -- see this file's own module docstring for why "real
# compression, not maximal" is the deliberate bar here.
comptime _MAX_CHAIN = 32


def _fixed_lit_lengths() -> List[Int]:
    """The same per-symbol code lengths _fixed_tables() builds for
    decoding (RFC 1951 3.2.6's own fixed assignment), rebuilt here in
    the shape the *encoder* needs: a plain length-per-symbol list
    (_build_codes' own input), not _construct's decode-oriented
    counts/symbols table.
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
    return lengths^


def _fixed_dist_lengths() -> List[Int]:
    var lengths = List[Int](capacity=_MAX_D_CODES)
    for _ in range(_MAX_D_CODES):
        lengths.append(5)
    return lengths^


def _build_codes(lengths: List[Int]) -> List[Int]:
    """RFC 1951 3.2.2's own canonical-Huffman code-generation
    algorithm, transcribed directly from the spec's own pseudocode:
    given a per-symbol length (0 = symbol unused), returns the actual
    numeric code value assigned to each symbol, indexed by symbol (not
    _construct's own sorted-by-length decode layout -- a different,
    encode-oriented representation of the identical canonical
    assignment, which is exactly why round-tripping through the
    existing, independently-built decoder is a real correctness check
    and not a circular one: the two are separate implementations of
    the same spec, not two views of shared state).
    """
    var max_len = 0
    for l in lengths:
        if l > max_len:
            max_len = l

    var bl_count = List[Int](capacity=max_len + 1)
    for _ in range(max_len + 1):
        bl_count.append(0)
    for l in lengths:
        if l > 0:
            bl_count[l] += 1

    var code = 0
    var next_code = List[Int](capacity=max_len + 1)
    for _ in range(max_len + 1):
        next_code.append(0)
    for bits in range(1, max_len + 1):
        code = (code + bl_count[bits - 1]) << 1
        next_code[bits] = code

    var codes = List[Int](capacity=len(lengths))
    for _ in range(len(lengths)):
        codes.append(0)
    for n in range(len(lengths)):
        var l = lengths[n]
        if l != 0:
            codes[n] = next_code[l]
            next_code[l] += 1
    return codes^


def _length_symbol(length: Int, lens: List[Int]) -> Int:
    """Which of the 29 length codes (RFC 1951 3.2.5, `lens`'s own
    ascending base-length table -- the identical one `_codes` uses to
    decode) covers a raw LZ77 match `length` -- the largest index whose
    own base is <= `length`; every base above it, if any, covers a
    strictly longer minimum. Linear scan over 29 entries, not a binary
    search -- see this module's own docstring for why clarity beats
    speed here throughout.
    """
    var idx = len(lens) - 1
    while lens[idx] > length:
        idx -= 1
    return idx


def _distance_symbol(distance: Int, dists: List[Int]) -> Int:
    """The distance-code analog of _length_symbol, over `dists`'s own
    30-entry base-distance table.
    """
    var idx = len(dists) - 1
    while dists[idx] > distance:
        idx -= 1
    return idx


def _hash3(data: List[UInt8], pos: Int) -> Int:
    """The 3 raw bytes at `pos`, packed into one 24-bit integer -- used
    directly as a Dict key, not hashed down into a smaller bucket
    count with the collisions that would introduce: every entry a
    lookup finds is *guaranteed* to already share the same 3-byte
    prefix as the position being matched (no separate re-check needed
    before extending a candidate further), the identical minimum LZ77
    match length (_MIN_MATCH) DEFLATE itself requires anyway.
    """
    return (Int(data[pos]) << 16) | (Int(data[pos + 1]) << 8) | Int(data[pos + 2])


def _insert_hash(mut chains: Dict[Int, List[Int]], data: List[UInt8], pos: Int) raises:
    """Records `pos` as a candidate match source for its own 3-byte
    prefix, capped at _MAX_CHAIN entries per key (oldest dropped first)
    -- bounds memory for a prefix that recurs constantly (a large flat-
    color region's own background color, say, could otherwise recur
    literally millions of times in one image) without changing which
    candidates a search actually considers: _find_match already only
    checks the _MAX_CHAIN *most recent* entries, the same ones kept.
    """
    var key = _hash3(data, pos)
    if key in chains:
        chains[key].append(pos)
        if len(chains[key]) > _MAX_CHAIN:
            _ = chains[key].pop(0)
    else:
        var bucket = List[Int]()
        bucket.append(pos)
        chains[key] = bucket^


struct _Match(ImplicitlyCopyable, Movable):
    var length: Int
    var distance: Int

    def __init__(out self, length: Int, distance: Int):
        self.length = length
        self.distance = distance


def _find_match(chains: Dict[Int, List[Int]], data: List[UInt8], pos: Int) raises -> _Match:
    """The best (longest, and among equal lengths, nearest -- searched
    most-recent-first) LZ77 match for the bytes starting at `pos`,
    among whatever candidates `chains` already has on hand for that
    same 3-byte prefix (see _insert_hash) -- a length of 0 means no
    match at least _MIN_MATCH long was found, the caller's own signal
    to emit a literal byte instead.

    Match length is found by direct byte-by-byte comparison against
    the *original* input array, not a partially-built output buffer --
    safe (and correct, not just convenient) even when candidate and
    current position overlap (distance < length, e.g. a solid-color
    run's own distance=1 case): every byte compared already exists in
    `data`, whether or not its own position is behind or past `pos`
    itself, which is exactly the "legal and common" overlapping-copy
    case inflate()'s own _codes docstring describes on the decode side.
    """
    var n = len(data)
    if pos + _MIN_MATCH > n:
        return _Match(0, 0)

    var key = _hash3(data, pos)
    if key not in chains:
        return _Match(0, 0)

    var best_length = 0
    var best_distance = 0
    var max_possible = min(_MAX_MATCH, n - pos)
    ref chain = chains[key]
    var j = len(chain) - 1
    while j >= 0:
        var candidate = chain[j]
        var distance = pos - candidate
        if distance > _WINDOW:
            break  # older entries (smaller j) are only further still
        var length = 0
        while length < max_possible and data[candidate + length] == data[pos + length]:
            length += 1
        if length > best_length:
            best_length = length
            best_distance = distance
        j -= 1

    if best_length < _MIN_MATCH:
        return _Match(0, 0)
    return _Match(best_length, best_distance)


def deflate(data: List[UInt8]) raises -> List[UInt8]:
    """Compress `data` into a raw DEFLATE stream (RFC 1951) -- real
    LZ77 + fixed-Huffman compression, this package's own from-scratch
    encoder (see this module's own docstring for the deliberate "real,
    not maximal" scope: one fixed-Huffman block, hash-chain match
    search capped at _MAX_CHAIN candidates). Not a zlib stream (RFC
    1950) -- callers that need one (canvas_mojo/io/png.mojo's own
    write_png, for one) wrap this output in the 2-byte header/4-byte
    Adler-32 trailer themselves, the exact inverse of what inflate()'s
    own docstring says its callers strip first.

    Always emits exactly one block (BFINAL=1 from the start) -- fine
    for the chart-sized images this package renders (RFC 1951 puts no
    upper bound on a single block's own length the way stored blocks'
    own 65535-byte-per-block limit does, RFC 1951 3.2.4), not a scale
    this ever needs to split across multiple blocks for.
    """
    var writer = _BitWriter()
    writer.write_bits(1, 1)  # BFINAL = 1 -- the only block
    writer.write_bits(1, 2)  # BTYPE = 01 (fixed Huffman)

    var lit_lengths = _fixed_lit_lengths()
    var lit_codes = _build_codes(lit_lengths)
    var dist_lengths = _fixed_dist_lengths()
    var dist_codes = _build_codes(dist_lengths)

    # Same base-length/base-distance tables _codes() decodes against
    # (RFC 1951 3.2.5) -- see that function's own docstring for why
    # these are rebuilt per call rather than shared module-level
    # constants (a real Mojo `comptime List[Int]` limitation, not a
    # style choice).
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

    var chains = Dict[Int, List[Int]]()
    var n = len(data)
    var i = 0
    while i < n:
        var m = _find_match(chains, data, i)
        if m.length >= _MIN_MATCH:
            var lsym = _length_symbol(m.length, lens)
            writer.write_code(lit_codes[257 + lsym], lit_lengths[257 + lsym])
            writer.write_bits(m.length - lens[lsym], lext[lsym])

            var dsym = _distance_symbol(m.distance, dists)
            writer.write_code(dist_codes[dsym], dist_lengths[dsym])
            writer.write_bits(m.distance - dists[dsym], dext[dsym])

            # Only the match's own starting position is indexed for
            # future searches, not every position it spans -- a real,
            # deliberate compression-ratio trade (a match starting
            # partway through this one won't be found), not a
            # correctness gap: see this module's own docstring on
            # "real compression, not maximal".
            if i + _MIN_MATCH <= n:
                _insert_hash(chains, data, i)
            i += m.length
        else:
            var byte = Int(data[i])
            writer.write_code(lit_codes[byte], lit_lengths[byte])
            if i + _MIN_MATCH <= n:
                _insert_hash(chains, data, i)
            i += 1

    writer.write_code(lit_codes[256], lit_lengths[256])  # end-of-block
    return writer.finish()
