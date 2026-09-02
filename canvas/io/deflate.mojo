"""DEFLATE (RFC 1951), both directions.

`inflate()` is a direct translation of zlib's `puff.c` reference
decoder (Mark Adler, zlib-licensed; "a simple inflate written to be an
unambiguous way to specify the deflate format") rather than a
re-derivation from the RFC alone. `deflate()` is a from-scratch LZ77 +
fixed-Huffman encoder built against the RFC's text, with `inflate()`
already in place to round-trip against. DEFLATE is a closed, formally
specified, decades-stable algorithm, so it belongs in this package the
way Bresenham lines and glyph outlines do -- unlike font
discovery/shaping, which font_discovery.mojo explains is an
open-ended, system-dependent subsystem better left to a linked
library.

`inflate()` is puff.c's "SLOW" (readable, bit-at-a-time) `decode()`
variant rather than its faster table-driven one: chart-sized images,
not a video codec. `deflate()` makes the same trade -- a single
fixed-Huffman block (RFC 1951 3.2.6, BTYPE=01, no dynamic tree to
build or transmit) over a hash-chain LZ77 match finder with bounded
search depth (`_MAX_CHAIN`). Real compression, not maximal.
canvas.io.png's `write_png` is the caller.

Verified against real zlib output: every `inflate()` stage
round-trips actual `zlib.compress()` output (stored, fixed-Huffman and
dynamic-Huffman blocks each separately) back to the original bytes,
and `deflate()`'s output goes back through both `inflate()` and
Python's `zlib.decompress()` -- a separate implementation, so a shared
bug can't hide. See tests/test_deflate.mojo.
"""

comptime _MAX_BITS = 15
comptime _MAX_L_CODES = 286
comptime _MAX_D_CODES = 30
comptime _MAX_CODES = _MAX_L_CODES + _MAX_D_CODES
comptime _FIX_L_CODES = 288


struct _BitReader(Movable):
    """Reads DEFLATE's bit-packed stream. Bits pack into bytes
    LSB-first (RFC 1951 3.1.1), so a byte is shifted into the buffer at
    the *top*, past whatever is pending, and read back from the
    *bottom* -- puff.c's `bits()`, including its "always leaves fewer
    than eight bits buffered" invariant.
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
        """Discard any partial byte in the bit buffer: stored blocks
        (RFC 1951 3.2.4) always start byte-aligned.
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
    """Writes DEFLATE's bit-packed stream, the inverse of _BitReader
    (same LSB-first convention): each write_bits() shifts new bits in
    above what's pending in `bitbuf`'s low bits, flushing a byte to
    `data` whenever 8 or more accumulate.
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
        """Huffman codes pack *most*-significant-bit first (RFC 1951
        3.2.2) -- the one field in the format that isn't LSB-first like
        BFINAL, BTYPE and the length/distance extra bits. Writes one
        bit at a time, top bit first, each through the ordinary
        write_bits (a single bit has no ordering ambiguity). This
        matches _decode's read order, which treats the first bit read
        as the value's most-significant one.
        """
        for i in range(nbits - 1, -1, -1):
            self.write_bits((code >> i) & 1, 1)

    def finish(mut self) raises -> List[UInt8]:
        """Flush any partial final byte. DEFLATE zero-pads the last
        byte's unused high bits, which is what already sits in `bitbuf`
        above `bitcnt`. Returns a `.copy()` of `self.data` rather than
        moving it out, since `mut self` is a borrow and `self` must
        stay valid -- one bulk copy, not an element-by-element loop,
        over what may be hundreds of KB.
        """
        if self.bitcnt > 0:
            self.data.append(UInt8(self.bitbuf & 0xFF))
            self.bitbuf = 0
            self.bitcnt = 0
        return self.data.copy()


struct _Huffman(Movable):
    """Canonical Huffman decode tables, puff.c's `struct huffman`:
    `counts[length]` is how many symbols have that length, `symbols`
    holds symbol values sorted by length then original order. `_decode`
    shows why these two arrays suffice.
    """

    var counts: List[Int]
    var symbols: List[Int]

    def __init__(out self, var counts: List[Int], var symbols: List[Int]):
        self.counts = counts^
        self.symbols = symbols^


def _construct(
    lengths: List[Int], n: Int, mut left_out: Int
) raises -> _Huffman:
    """Direct translation of puff.c's `construct()`: given a length
    (0..MAX_BITS) per symbol for `n` symbols, builds the tables
    `_decode` needs. Raises on an over-subscribed code (more codes of
    some length than the bits allow), which is invalid in any context.

    An *incomplete* code does not raise: a fixed block's distance code
    and a dynamic block's single-symbol code are both legitimately
    incomplete (RFC 1951 3.2.7's "one distance code of one bit"). Only
    the caller knows whether that's acceptable, so it comes back
    through `left_out` -- 0 when complete, >0 when not, puff.c's
    `construct()` return value.

    `left_out` is an out-parameter rather than a returned struct field
    because extracting a field from a local multi-field value hits a
    Mojo ownership limitation: returning `_ConstructResult(table,
    left)` makes every call site's `result.table^` fail to compile with
    "field ... destroyed out of the middle of a value".
    """
    var counts = List[Int](capacity=_MAX_BITS + 1)
    for _ in range(_MAX_BITS + 1):
        counts.append(0)
    for symbol in range(n):
        counts[lengths[symbol]] += 1

    if counts[0] == n:
        # No codes at all: a valid but useless table -- any decode()
        # against it fails. puff.c calls this "complete, but decode()
        # will fail".
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
    """Direct translation of puff.c's readable (`#ifdef SLOW`)
    `decode()`: reads a bit at a time, building a code value the way
    canonical-Huffman construction (RFC 1951 3.2.2) assigns them, and
    returns once the accumulated (code, length) falls in that length's
    assigned range. `_construct`'s counts/symbols arrays are all the
    range check needs -- no decode tree.
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


def _codes(
    mut reader: _BitReader,
    mut out: List[UInt8],
    lencode: _Huffman,
    distcode: _Huffman,
) raises:
    """Direct translation of puff.c's `codes()`: decode literal/length
    and distance symbols until the end-of-block symbol (256). The
    length/distance base+extra-bits tables are RFC 1951 3.2.5's,
    transcribed from the spec and cross-checked against puff.c's.

    The `List[Int]` literals are rebuilt per call rather than held as
    module-level `comptime` constants: `comptime List[Int]` doesn't
    materialize to a usable runtime value in this Mojo version (the
    same limitation bidi.mojo's mirroring table works around). Four
    small lists per block is a cheap way to avoid it.
    """
    var lens: List[Int] = [
        3,
        4,
        5,
        6,
        7,
        8,
        9,
        10,
        11,
        13,
        15,
        17,
        19,
        23,
        27,
        31,
        35,
        43,
        51,
        59,
        67,
        83,
        99,
        115,
        131,
        163,
        195,
        227,
        258,
    ]
    var lext: List[Int] = [
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        1,
        1,
        1,
        1,
        2,
        2,
        2,
        2,
        3,
        3,
        3,
        3,
        4,
        4,
        4,
        4,
        5,
        5,
        5,
        5,
        0,
    ]
    var dists: List[Int] = [
        1,
        2,
        3,
        4,
        5,
        7,
        9,
        13,
        17,
        25,
        33,
        49,
        65,
        97,
        129,
        193,
        257,
        385,
        513,
        769,
        1025,
        1537,
        2049,
        3073,
        4097,
        6145,
        8193,
        12289,
        16385,
        24577,
    ]
    var dext: List[Int] = [
        0,
        0,
        0,
        0,
        1,
        1,
        2,
        2,
        3,
        3,
        4,
        4,
        5,
        5,
        6,
        6,
        7,
        7,
        8,
        8,
        9,
        9,
        10,
        10,
        11,
        11,
        12,
        12,
        13,
        13,
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

            # Forward, one byte at a time, not a bulk copy: overlapping
            # copies (length > distance) are legal and common -- dist=1
            # repeats the last byte `length` times -- so each iteration
            # has to read from the already-growing `out`. puff.c warns
            # explicitly that memcpy/memmove are wrong here.
            var start = len(out) - dist
            for i in range(length):
                out.append(out[start + i])


def _stored_block(mut reader: _BitReader, mut out: List[UInt8]) raises:
    """RFC 1951 3.2.4, a raw uncompressed block: byte-align, read
    LEN/NLEN (little-endian; NLEN is LEN's one's complement, checked),
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
    """RFC 1951 3.2.6: BTYPE=01's literal/length and distance Huffman
    codes are fixed by the spec, not transmitted. The bit-length
    breakpoints below (0-143 -> 8 bits, 144-255 -> 9, 256-279 -> 7,
    280-287 -> 8; all 30 distance codes -> 5) are the spec's table, as
    in puff.c's `fixed()`.
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
    """RFC 1951 3.2.7: a dynamic block transmits its literal/length and
    distance code lengths, themselves Huffman-coded via a third small
    "code length" alphabet (0-15 literal lengths, 16/17/18 run-length
    instructions). That alphabet's lengths arrive as 19 plain 3-bit
    values in the permuted `order` below, the spec's ordering, which
    keeps the common short list short. Direct translation of puff.c's
    `dynamic()`.
    """
    var order: List[Int] = [
        16,
        17,
        18,
        0,
        8,
        7,
        9,
        6,
        10,
        5,
        11,
        4,
        12,
        3,
        13,
        2,
        14,
        1,
        15,
    ]

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
    """Decompress a raw DEFLATE stream (RFC 1951), not a zlib stream
    (RFC 1950): a caller holding a zlib-wrapped stream, such as PNG's
    IDAT data, strips the 2-byte header and 4-byte Adler-32 trailer
    first. Direct translation of puff.c's top-level `puff()` loop.

    Takes ownership of `compressed`, moving it into the bit reader
    rather than copying: `List[UInt8]` isn't cheaply copyable and no
    caller needs the buffer back.

    Args:
        compressed: Raw DEFLATE bytes, no zlib wrapper.

    Returns:
        The decompressed bytes.

    Raises:
        Error: `compressed` is truncated or malformed.
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
# How many candidate prior positions a match search checks, and how
# many a hash bucket keeps at all. A speed/ratio knob, not a
# correctness one: fewer candidates means a shorter or more distant
# match than an exhaustive search would find, never an invalid one.
# Real encoders go much higher at their top compression levels.
comptime _MAX_CHAIN = 32

# Hash table sizing for the match search below. The table is indexed by
# a hash of the 3 bytes at a position, and holds the most recent
# position with that hash; `_HashChains.prev` links each position to
# the previous one sharing it. Both are plain integer arrays, so an
# insert is two stores and never allocates.
#
# Sized to the input rather than fixed: a 2x1 PNG's 7-byte scanline
# does not need (and should not zero) a 64K-entry table, while an
# 800x600 RGBA image's ~1.9MB does. Rounded up to a power of two so the
# index is a mask rather than a modulo.
comptime _MIN_HASH_SIZE = 256
comptime _MAX_HASH_SIZE = 1 << 15
# _WINDOW is a power of two, so a position maps into `prev` with a mask.
comptime _WINDOW_MASK = _WINDOW - 1

# Knuth's multiplicative constant, 2^32 / phi. The 3-byte prefix is
# spread across the table's width by multiplying and taking the high
# bits, so inputs differing only in their low byte -- consecutive
# pixels of a gradient, say -- land in different buckets instead of
# adjacent ones.
comptime _HASH_MUL = 2654435761


def _fixed_lit_lengths() -> List[Int]:
    """RFC 1951 3.2.6's fixed code lengths in the shape the *encoder*
    needs: a plain length-per-symbol list for _build_codes, rather than
    _construct's decode-oriented counts/symbols table.
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
    """RFC 1951 3.2.2's canonical-Huffman code generation, transcribed
    from the spec's pseudocode: given a per-symbol length (0 = unused),
    returns each symbol's numeric code, indexed by symbol.

    This is a separate encode-oriented representation of the same
    canonical assignment `_construct` builds sorted by length for
    decoding -- two implementations of one spec, not two views of
    shared state, which is what makes round-tripping through the
    decoder a real check rather than a circular one.
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
    """Which of the 29 length codes (RFC 1951 3.2.5's ascending
    base-length table, the one `_codes` decodes against) covers an LZ77
    match `length`: the largest index whose base is <= `length`. Linear
    scan over 29 entries, not a binary search.
    """
    var idx = len(lens) - 1
    while lens[idx] > length:
        idx -= 1
    return idx


def _distance_symbol(distance: Int, dists: List[Int]) -> Int:
    """The distance-code analog of _length_symbol, over the 30-entry
    base-distance table.
    """
    var idx = len(dists) - 1
    while dists[idx] > distance:
        idx -= 1
    return idx


def _hash3(data: List[UInt8], pos: Int, mask: Int) -> Int:
    """A table index for the 3 bytes at `pos`. 3 bytes because that is
    DEFLATE's minimum match length (_MIN_MATCH).

    Unlike an exact 24-bit key, this can collide: two different
    3-byte prefixes may share a bucket. That costs a little of the
    search budget but cannot produce a wrong match, because
    `_find_match` compares candidates against the input byte by byte
    rather than trusting the bucket.
    """
    var v = (
        (Int(data[pos]) << 16) | (Int(data[pos + 1]) << 8) | Int(data[pos + 2])
    )
    return ((v * _HASH_MUL) >> 16) & mask


struct _HashChains(Movable):
    """Most-recent-position-per-hash (`head`) plus a per-position link
    to the next-most-recent sharing that hash (`prev`) -- the standard
    LZ77 chain structure, and the reason a match search does not need a
    dictionary.

    This replaced a `Dict[Int, List[Int]]` whose per-position insert
    hashed a key, risked an allocation, and called `pop(0)` on the
    bucket -- an O(bucket) memmove -- once per byte of every image
    written. Here an insert is two array stores, and the _MAX_CHAIN cap
    moves from the insert (bounding what is stored) to the search
    (bounding what is walked), which is where it was always doing the
    real work: `_find_match` never looked past that many candidates
    anyway.

    Walking `prev` from `head` yields positions in most-recent-first
    order, which is what makes `_find_match`'s "nearest among equal
    lengths" tie-break fall out for free.
    """

    # Int32, not Int: these are positions in a buffer DEFLATE already
    # caps at a 32768-byte match distance, so 32 bits is ample, and
    # halving both arrays keeps the pair at 256KB rather than 512KB --
    # small enough not to disturb the allocator on a caller that
    # encodes in a loop.
    var head: List[Int32]
    var prev: List[Int32]
    var mask: Int

    def __init__(out self, n: Int):
        var size = _MIN_HASH_SIZE
        while size < n and size < _MAX_HASH_SIZE:
            size <<= 1
        self.head = List[Int32](length=size, fill=-1)
        # _WINDOW entries, not one per input byte. A match may never
        # reach further back than _WINDOW, so a link out of that range
        # could never be used -- making this array proportional to the
        # input instead would allocate and zero ~8 bytes per byte
        # compressed (15MB for an 800x600 RGBA image), which measured
        # slower than the dictionary this replaced.
        self.prev = List[Int32](length=_WINDOW, fill=-1)
        self.mask = size - 1

    def insert(mut self, data: List[UInt8], pos: Int):
        """Record `pos` as a candidate match source for its 3-byte
        prefix. Unbounded in what it stores; the search is what caps
        how far back it looks.
        """
        var h = _hash3(data, pos, self.mask)
        var hp = self.head.unsafe_ptr()
        self.prev.unsafe_ptr()[unsafe_offset=pos & _WINDOW_MASK] = hp[
            unsafe_offset=h
        ]
        hp[unsafe_offset=h] = Int32(pos)


struct _Match(ImplicitlyCopyable, Movable):
    var length: Int
    var distance: Int

    def __init__(out self, length: Int, distance: Int):
        self.length = length
        self.distance = distance


def _find_match(chains: _HashChains, data: List[UInt8], pos: Int) -> _Match:
    """The best LZ77 match for the bytes at `pos` -- longest, and
    nearest among equal lengths, since the chain is walked
    most-recent-first -- among the _MAX_CHAIN most recent positions
    sharing this position's hash bucket. Length 0 means nothing at
    least _MIN_MATCH long was found, and the caller emits a literal
    byte.

    A bucket may hold positions whose 3 bytes merely *hash* the same
    (see _hash3), so a candidate is not assumed to match; the
    comparison below establishes it. A collision therefore costs a
    rejected candidate, never a wrong match.

    Length is measured by byte-by-byte comparison against the
    *original* input array, not a partially-built output buffer, which
    stays correct when candidate and current position overlap
    (distance < length, e.g. a solid-color run at distance=1): every
    byte compared already exists in `data`. That's the overlapping-copy
    case _codes handles on the decode side.
    """
    var n = len(data)
    if pos + _MIN_MATCH > n:
        return _Match(0, 0)

    var best_length = 0
    var best_distance = 0
    var max_possible = min(_MAX_MATCH, n - pos)
    # The comparison loop below is where this function spends its time
    # -- deflate's cost scales with _MAX_CHAIN precisely because each
    # candidate is compared byte by byte -- and a checked List read
    # costs several times the compare it guards. Both indices stay
    # inside `data`: `pos + length` is bounded by `max_possible`, which
    # is at most `n - pos`, and `candidate + length` is smaller still
    # since `candidate < pos`.
    var d = data.unsafe_ptr()
    var pp = chains.prev.unsafe_ptr()
    var candidate = Int(
        chains.head.unsafe_ptr()[unsafe_offset=_hash3(data, pos, chains.mask)]
    )
    var walked = 0
    while candidate >= 0 and walked < _MAX_CHAIN:
        walked += 1
        var distance = pos - candidate
        if distance > _WINDOW:
            break  # earlier links are only further still
        var length = 0
        while (
            length < max_possible
            and d[unsafe_offset=candidate + length]
            == d[unsafe_offset=pos + length]
        ):
            length += 1
        if length > best_length:
            best_length = length
            best_distance = distance
            if best_length >= max_possible:
                # Nothing later in the chain can beat a match already
                # at the cap, so stop rather than compare the rest.
                # This is the difference between O(_MAX_CHAIN *
                # _MAX_MATCH) and O(_MAX_MATCH) per position on flat
                # input, where every candidate matches to the full
                # length and none can improve on the first: a large
                # flat-color region is exactly that, and it is what
                # this package's own images are mostly made of.
                # Searching most-recent-first means the first candidate
                # to reach the cap is also the nearest one, so the
                # "nearest among equal lengths" tie-break is unchanged
                # and so is the emitted stream, byte for byte.
                break
        # `prev` wraps every _WINDOW positions, so an untouched slot
        # can still hold a position from a previous lap. A chain is
        # strictly decreasing by construction, so anything that is not
        # is such a leftover and ends the walk.
        var next_candidate = Int(pp[unsafe_offset=candidate & _WINDOW_MASK])
        if next_candidate >= candidate:
            break
        candidate = next_candidate

    if best_length < _MIN_MATCH:
        return _Match(0, 0)
    return _Match(best_length, best_distance)


def deflate(data: List[UInt8]) raises -> List[UInt8]:
    """Compress `data` into a raw DEFLATE stream (RFC 1951): LZ77 +
    fixed-Huffman, one block, head/prev hash-chain match search
    (see _HashChains) capped at _MAX_CHAIN candidates. Not a zlib stream (RFC 1950) -- a caller
    needing one, such as write_png, adds the 2-byte header and 4-byte
    Adler-32 trailer itself.

    Always one block (BFINAL=1 from the start). RFC 1951 caps a stored
    block at 65535 bytes but puts no upper bound on a compressed one,
    so chart-sized images never need splitting.

    Args:
        data: Bytes to compress.

    Returns:
        The compressed bytes, no zlib wrapper.
    """
    var writer = _BitWriter()
    writer.write_bits(1, 1)  # BFINAL = 1 -- the only block
    writer.write_bits(1, 2)  # BTYPE = 01 (fixed Huffman)

    var lit_lengths = _fixed_lit_lengths()
    var lit_codes = _build_codes(lit_lengths)
    var dist_lengths = _fixed_dist_lengths()
    var dist_codes = _build_codes(dist_lengths)

    # Same base-length/base-distance tables _codes() decodes against
    # (RFC 1951 3.2.5), rebuilt per call for the `comptime List[Int]`
    # reason _codes documents.
    var lens: List[Int] = [
        3,
        4,
        5,
        6,
        7,
        8,
        9,
        10,
        11,
        13,
        15,
        17,
        19,
        23,
        27,
        31,
        35,
        43,
        51,
        59,
        67,
        83,
        99,
        115,
        131,
        163,
        195,
        227,
        258,
    ]
    var lext: List[Int] = [
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        1,
        1,
        1,
        1,
        2,
        2,
        2,
        2,
        3,
        3,
        3,
        3,
        4,
        4,
        4,
        4,
        5,
        5,
        5,
        5,
        0,
    ]
    var dists: List[Int] = [
        1,
        2,
        3,
        4,
        5,
        7,
        9,
        13,
        17,
        25,
        33,
        49,
        65,
        97,
        129,
        193,
        257,
        385,
        513,
        769,
        1025,
        1537,
        2049,
        3073,
        4097,
        6145,
        8193,
        12289,
        16385,
        24577,
    ]
    var dext: List[Int] = [
        0,
        0,
        0,
        0,
        1,
        1,
        2,
        2,
        3,
        3,
        4,
        4,
        5,
        5,
        6,
        6,
        7,
        7,
        8,
        8,
        9,
        9,
        10,
        10,
        11,
        11,
        12,
        12,
        13,
        13,
    ]

    var n = len(data)
    var chains = _HashChains(n)
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

            # Only the match's starting position is indexed, not every
            # position it spans: a compression-ratio trade (a match
            # starting partway through this one won't be found), not a
            # correctness gap.
            if i + _MIN_MATCH <= n:
                chains.insert(data, i)
            i += m.length
        else:
            var byte = Int(data[i])
            writer.write_code(lit_codes[byte], lit_lengths[byte])
            if i + _MIN_MATCH <= n:
                chains.insert(data, i)
            i += 1

    writer.write_code(lit_codes[256], lit_lengths[256])  # end-of-block
    return writer.finish()
