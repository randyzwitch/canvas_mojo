"""DEFLATE (RFC 1951), both directions.

`inflate()` is a translation of zlib's `puff.c` reference decoder (Mark
Adler, zlib-licensed), with a first-level lookup table in front of its
bit-at-a-time `decode()` (`_decode_fast`). `deflate()` is a
from-scratch LZ77 + Huffman encoder built against the RFC: one block,
coded with either the fixed tables (RFC 1951 3.2.6, BTYPE=01) or a
dynamic code fitted to the data (3.2.7, BTYPE=10), whichever spends
fewer bits, over a hash-chain match finder with bounded search depth
(`_MAX_CHAIN`). canvas.io.png's `write_png` is the caller.

tests/test_deflate.mojo round-trips both directions against real
`zlib.compress()`/`zlib.decompress()` output.
"""


comptime _MAX_BITS = 15
comptime _MAX_L_CODES = 286
comptime _MAX_D_CODES = 30
comptime _MAX_CODES = _MAX_L_CODES + _MAX_D_CODES
comptime _FIX_L_CODES = 288


# --- RFC 1951 3.2.5 length/distance tables ----------------------------------
# Built by function rather than held as module-level `comptime` lists:
# `comptime List[Int]` doesn't materialize to a usable runtime value in
# this Mojo version (the same limitation bidi.mojo's mirroring table
# works around). Both the decoder (`_codes`) and the encoder (`deflate`)
# read them, so they are defined once here.


def _code_length_order() -> List[Int]:
    """The order RFC 1951 3.2.7 transmits the code-length alphabet's
    own code lengths in: the run-length symbols first, then the
    literal lengths from the middle outward, so the trailing entries a
    typical block never uses can be left off (`HCLEN`).
    """
    return [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]


def _length_bases() -> List[Int]:
    """Base match length for each of the 29 length codes 257..285."""
    return [
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


def _length_extra_bits() -> List[Int]:
    """Extra bits following each length code."""
    return [
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


def _distance_bases() -> List[Int]:
    """Base distance for each of the 30 distance codes."""
    return [
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


def _distance_extra_bits() -> List[Int]:
    """Extra bits following each distance code."""
    return [
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

    def fill(mut self, want: Int) -> Int:
        """Buffer whole bytes until at least `want` bits are pending,
        or the input runs out; returns how many are pending. Nothing
        is consumed: `_decode`'s table lookup peeks at these and
        `drop_bits` takes only the code's own length.
        """
        while self.bitcnt < want and self.pos < len(self.data):
            self.bitbuf |= Int(self.data[self.pos]) << self.bitcnt
            self.pos += 1
            self.bitcnt += 8
        return self.bitcnt

    @always_inline
    def drop_bits(mut self, n: Int):
        self.bitbuf >>= n
        self.bitcnt -= n

    def align_to_byte(mut self):
        """Discard any partial byte in the bit buffer: stored blocks
        (RFC 1951 3.2.4) always start byte-aligned. Whole bytes `fill`
        buffered ahead go back to the input, since `read_byte` reads
        from there.
        """
        self.pos -= self.bitcnt // 8
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


# Codes up to this long decode by one table lookup on the next bits of
# input (`_Huffman.fast`); longer ones, which are rare, fall through to
# the bit-at-a-time walk. Nine bits covers every fixed-table literal
# and length code (RFC 1951 3.2.6) and, in practice, nearly every
# dynamic one.
comptime _FAST_BITS = 9


struct _Huffman(Movable):
    """Canonical Huffman decode tables, puff.c's `struct huffman`:
    `counts[length]` is how many symbols have that length, `symbols`
    holds symbol values sorted by length then original order. `_decode`
    shows why these two arrays suffice.

    `fast` is the lookup table over the next `_FAST_BITS` bits of
    input, built from the same two arrays: an entry is
    `symbol << 4 | length` for a code that short, and -1 where the code
    is longer. Deflate packs code bits most-significant first into a
    stream read least-significant first, so a code indexes the table
    bit-reversed, and every entry whose low `length` bits are that
    reversed code holds the symbol.
    """

    var counts: List[Int]
    var symbols: List[Int]
    var fast: List[Int]

    def __init__(out self, var counts: List[Int], var symbols: List[Int]):
        self.counts = counts^
        self.symbols = symbols^
        self.fast = List[Int](length=1 << _FAST_BITS, fill=-1)
        var code = 0
        var index = 0
        for length in range(1, _MAX_BITS + 1):
            for _ in range(self.counts[length]):
                if length <= _FAST_BITS:
                    var rev = _reverse_bits(code, length)
                    var entry = (self.symbols[index] << 4) | length
                    var stride = 1 << length
                    for i in range(rev, 1 << _FAST_BITS, stride):
                        self.fast[i] = entry
                code += 1
                index += 1
            code <<= 1


def _construct(
    lengths: List[Int], n: Int, mut left_out: Int
) raises -> _Huffman:
    """Direct translation of puff.c's `construct()`: given a length
    (0..MAX_BITS) per symbol for `n` symbols, builds the tables
    `_decode` needs. Raises on an over-subscribed code (more codes of
    some length than the bits allow), which is invalid in any context.

    An *incomplete* code does not raise: a fixed block's distance code
    and a dynamic block's single-symbol code are both legitimately
    incomplete (RFC 1951 3.2.7). Only the caller knows whether that is
    acceptable, so it comes back through `left_out` -- 0 when complete,
    >0 when not, puff.c's `construct()` return value.

    `left_out` is an out-parameter rather than a returned struct field:
    returning `_ConstructResult(table, left)` makes every call site's
    `result.table^` fail to compile with "field ... destroyed out of the
    middle of a value".
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
    """The next symbol of `table` from `reader`: a lookup in
    `table.fast` on the pending bits when the code is short enough and
    the input holds it whole, otherwise puff.c's readable (`#ifdef
    SLOW`) `decode()` -- a bit at a time, building a code value the way
    canonical-Huffman construction (RFC 1951 3.2.2) assigns them, and
    returning once the accumulated (code, length) falls in that
    length's assigned range. `_construct`'s counts/symbols arrays are
    all the range check needs -- no decode tree.
    """
    var avail = reader.fill(_FAST_BITS)
    var entry = table.fast[reader.bitbuf & ((1 << _FAST_BITS) - 1)]
    if entry >= 0:
        var length = entry & 15
        if length <= avail:
            reader.drop_bits(length)
            return entry >> 4
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

    The tables come from `_length_bases` and friends below.
    """
    var lens = _length_bases()
    var lext = _length_extra_bits()
    var dists = _distance_bases()
    var dext = _distance_extra_bits()

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

            # Overlapping copies (length > distance) are legal and
            # common -- dist=1 repeats the last byte `length` times --
            # so a single bulk copy of the run is wrong, as puff.c
            # warns. But the first `dist` bytes of the run never
            # overlap their source, and once they are written the
            # next `2 * dist` do not either: the run is copied in
            # chunks that double, each from bytes already in place, in
            # sixteen-byte vectors where a chunk is long enough. The
            # output is grown once for the whole run.
            var n0 = len(out)
            var start = n0 - dist
            if n0 + length > out.capacity():
                # Grow geometrically: `resize` alone grows to the exact
                # length, and a run per match would then reallocate
                # the whole output every few hundred bytes.
                out.reserve(max(2 * out.capacity(), n0 + length))
            out.resize(unsafe_uninit_length=n0 + length)
            var op = out.unsafe_ptr()
            var copied = 0
            while copied < length:
                var chunk = min(dist + copied, length - copied)
                var d = n0 + copied
                var k = 0
                while k + 16 <= chunk:
                    op.unsafe_offset(d + k).unsafe_store(
                        op.unsafe_offset(start + k).unsafe_load[width=16]()
                    )
                    k += 16
                while k < chunk:
                    op[unsafe_offset=d + k] = op[unsafe_offset=start + k]
                    k += 1
                copied += chunk


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
    codes are fixed by the spec, not transmitted -- puff.c's `fixed()`,
    over the length lists the encoder also uses.
    """
    var lit_left = 0
    var lit_table = _construct(_fixed_lit_lengths(), _FIX_L_CODES, lit_left)

    var dist_left = 0
    var dist_table = _construct(_fixed_dist_lengths(), _MAX_D_CODES, dist_left)

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
    var order = _code_length_order()

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
    rather than copying.

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

# The longest match `deflate` still looks one byte further for. Above
# it a match is taken as found, without the second search the lazy
# rule needs. Both a ratio and a speed knob, and monotonic in neither:
# set by benchmark (#172, which has the numbers) over the example
# images, where 48, 64 and 96 land within 0.1% of each other, 32 comes
# out 1.9% larger, and 128 and up is both larger and slower to write.
comptime _MAX_LAZY = 64

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
    """RFC 1951 3.2.6's fixed literal/length code lengths, one per
    symbol: 0-143 -> 8 bits, 144-255 -> 9, 256-279 -> 7, 280-287 -> 8.
    `_construct` turns them into decode tables and `_build_codes` into
    the encoder's codes.
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


def _reverse_bits(code: Int, nbits: Int) -> Int:
    """`code`'s low `nbits` bits in the opposite order."""
    var out = 0
    var rest = code
    for _ in range(nbits):
        out = (out << 1) | (rest & 1)
        rest >>= 1
    return out


def _build_codes(lengths: List[Int]) -> List[Int]:
    """RFC 1951 3.2.2's canonical-Huffman code generation, transcribed
    from the spec's pseudocode: given a per-symbol length (0 = unused),
    returns each symbol's code, indexed by symbol.

    Each code comes back *bit-reversed*. Huffman codes pack
    most-significant-bit first (RFC 1951 3.2.2), the one field in the
    format that isn't LSB-first like BFINAL, BTYPE and the extra bits,
    and `_BitWriter.write_bits` packs LSB-first. Reversing once here
    lets the encoder emit a code with one `write_bits` call instead of
    one per bit, and matches `_decode`'s read order, which treats the
    first bit read as the value's most-significant one.
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
            codes[n] = _reverse_bits(next_code[l], l)
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

    The _MAX_CHAIN cap sits on the search rather than the insert, since
    `_find_match` never looks past that many candidates. Walking `prev`
    from `head` yields positions most-recent-first, which is what makes
    `_find_match`'s "nearest among equal lengths" tie-break free.
    """

    # Int32, not Int: these are positions in a buffer DEFLATE already
    # caps at a 32768-byte match distance, so 32 bits is ample, and
    # halving both arrays keeps the pair at 256KB rather than 512KB --
    # small enough not to disturb the allocator on a caller that
    # encodes in a loop.
    var head: List[Int32]
    var prev: List[Int32]
    var mask: Int
    # How far the input has been indexed: every position below this is
    # in `head`/`prev`, and none at or above it is. The encoder walks
    # forward and looks back, so this is what keeps a position from
    # being indexed twice (which would link it to itself and cut the
    # chain) or skipped.
    var indexed: Int

    def __init__(out self, n: Int):
        var size = _MIN_HASH_SIZE
        while size < n and size < _MAX_HASH_SIZE:
            size <<= 1
        self.head = List[Int32](length=size, fill=-1)
        # _WINDOW entries, not one per input byte. A match may never
        # reach further back than _WINDOW, so a link out of that range
        # could never be used, and sizing this to the input instead
        # measured slower (#104).
        self.prev = List[Int32](length=_WINDOW, fill=-1)
        self.mask = size - 1
        self.indexed = 0

    def index_upto(mut self, data: List[UInt8], limit: Int):
        """Record every position below `limit` not already recorded as
        a candidate match source for the 3 bytes at it. Positions with
        fewer than _MIN_MATCH bytes after them are never recorded,
        since nothing can match against them. Unbounded in what it
        stores; the search is what caps how far back it looks.

        A range at a time rather than a position at a time: the encoder
        indexes every position of every token, so this loop runs once
        per input byte. The pointers and the 3-byte key are carried
        across iterations, leaving two stores and a shift per position.

        Args:
            data: The bytes being compressed.
            limit: One past the last position to record.
        """
        var start = self.indexed
        var stop = min(limit, len(data) - _MIN_MATCH + 1)
        if start >= stop:
            return
        self.indexed = stop
        var d = data.unsafe_ptr()
        var hp = self.head.unsafe_ptr()
        var pp = self.prev.unsafe_ptr()
        var v = (
            (Int(d[unsafe_offset=start]) << 16)
            | (Int(d[unsafe_offset=start + 1]) << 8)
            | Int(d[unsafe_offset=start + 2])
        )
        for pos in range(start, stop):
            var h = ((v * _HASH_MUL) >> 16) & self.mask
            pp[unsafe_offset=pos & _WINDOW_MASK] = hp[unsafe_offset=h]
            hp[unsafe_offset=h] = Int32(pos)
            if pos + 1 < stop:
                # The next position's key is this one shifted up a
                # byte, so only one byte is read per position. In range
                # because `stop` leaves _MIN_MATCH bytes after the last
                # position: pos + 3 is at most stop + 1 <= len(data) - 1.
                v = ((v << 8) | Int(d[unsafe_offset=pos + 3])) & 0xFFFFFF


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
    (see _hash3), so the comparison below establishes a real match; a
    collision costs a rejected candidate, never a wrong match.

    Length is measured against the *original* input array, not a
    partially-built output buffer, which stays correct when candidate and
    current position overlap (distance < length, as in a solid-color run
    at distance=1): every byte compared already exists in `data`.
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


struct _Token(ImplicitlyCopyable, Movable):
    """One LZ77 output symbol: a literal byte (`distance` 0, `value`
    the byte) or a match (`distance` 1 or more, `value` its length).
    `deflate` buffers the whole token stream so it can count symbol
    frequencies before choosing a code, then emits from the buffer.
    """

    var value: Int
    var distance: Int

    def __init__(out self, value: Int, distance: Int):
        self.value = value
        self.distance = distance


def _tree_depths(weights: List[Int]) -> List[Int]:
    """Leaf depths of the Huffman tree over `weights`, of which there
    are at least two: repeatedly merges the two lightest parentless
    nodes, lowest index first on a tie, which makes the result
    deterministic. Quadratic in the leaf count, which is at most 288.
    """
    var m = len(weights)
    var weight = List[Int](capacity=2 * m - 1)
    var parent = List[Int](capacity=2 * m - 1)
    for w in weights:
        weight.append(w)
        parent.append(-1)

    var remaining = m
    while remaining > 1:
        var a = -1
        var b = -1
        for i in range(len(weight)):
            if parent[i] != -1:
                continue
            if a == -1 or weight[i] < weight[a]:
                b = a
                a = i
            elif b == -1 or weight[i] < weight[b]:
                b = i
        var node = len(weight)
        weight.append(weight[a] + weight[b])
        parent.append(-1)
        parent[a] = node
        parent[b] = node
        remaining -= 1

    var depths = List[Int](capacity=m)
    for k in range(m):
        var depth = 0
        var i = k
        while parent[i] != -1:
            i = parent[i]
            depth += 1
        depths.append(depth)
    return depths^


def _huffman_lengths(freqs: List[Int], limit: Int) -> List[Int]:
    """Code length per symbol for a canonical Huffman code over
    `freqs` -- zero for a symbol never used -- with none longer than
    `limit`: 15 for the literal/length and distance alphabets, 7 for
    the code-length alphabet (RFC 1951 3.2.7).

    A plain Huffman tree over the counts gives the shortest code. When
    its deepest leaf exceeds `limit`, every count is halved (rounding
    up, so a used symbol stays used) and the tree rebuilt: flattening
    the counts flattens the tree, and equal counts give a balanced one
    no deeper than ceil(log2(symbols)) -- 9 for 286 symbols, 5 for 19
    -- so this always finishes inside the limit. The price is a code a
    little longer than optimal in the rare case it triggers, never an
    invalid one.

    A single used symbol gets length 1 rather than the tree's 0.
    DEFLATE has no zero-length code, and the decoder accepts the
    one-code incomplete tree that results (RFC 1951 3.2.7 says so of
    a lone distance code).
    """
    var n = len(freqs)
    var lengths = List[Int](length=n, fill=0)
    var used = List[Int]()
    for symbol in range(n):
        if freqs[symbol] > 0:
            used.append(symbol)
    if len(used) == 0:
        return lengths^
    if len(used) == 1:
        lengths[used[0]] = 1
        return lengths^

    var weights = List[Int](capacity=len(used))
    for symbol in used:
        weights.append(freqs[symbol])
    while True:
        var depths = _tree_depths(weights)
        var deepest = 0
        for depth in depths:
            if depth > deepest:
                deepest = depth
        if deepest <= limit:
            for k in range(len(used)):
                lengths[used[k]] = depths[k]
            return lengths^
        for k in range(len(weights)):
            weights[k] = (weights[k] + 1) // 2


struct _LengthCode(ImplicitlyCopyable, Movable):
    """One symbol of the code-length alphabet as `_run_length_code`
    emits it: the symbol (0-18), and the extra bits 16/17/18 carry.
    """

    var symbol: Int
    var extra: Int
    var extra_bits: Int

    def __init__(out self, symbol: Int, extra: Int, extra_bits: Int):
        self.symbol = symbol
        self.extra = extra
        self.extra_bits = extra_bits


def _run_length_code(lengths: List[Int]) -> List[_LengthCode]:
    """RFC 1951 3.2.7's run-length coding of a code-length sequence:
    0-15 stand for themselves, 16 repeats the previous length 3-6 times
    (2 extra bits), 17 is a run of 3-10 zeros (3 extra bits) and 18 a
    run of 11-138 zeros (7 extra bits). Greedy, longest run first, the
    same choices zlib's `send_tree` makes. A run too short for its
    repeat symbol is written out literally.
    """
    var out = List[_LengthCode]()
    var n = len(lengths)
    var i = 0
    while i < n:
        var value = lengths[i]
        var run = 1
        while i + run < n and lengths[i + run] == value:
            run += 1
        i += run

        if value == 0:
            while run >= 11:
                var take = min(run, 138)
                out.append(_LengthCode(18, take - 11, 7))
                run -= take
            if run >= 3:
                out.append(_LengthCode(17, run - 3, 3))
                run = 0
            while run > 0:
                out.append(_LengthCode(0, 0, 0))
                run -= 1
        else:
            # The first occurrence is literal; 16 repeats what came
            # before it.
            out.append(_LengthCode(value, 0, 0))
            run -= 1
            while run >= 3:
                var take = min(run, 6)
                out.append(_LengthCode(16, take - 3, 2))
                run -= take
            while run > 0:
                out.append(_LengthCode(value, 0, 0))
                run -= 1
    return out^


def deflate(data: List[UInt8]) raises -> List[UInt8]:
    """Compress `data` into a raw DEFLATE stream (RFC 1951): LZ77 over
    a head/prev hash-chain match search (see _HashChains) capped at
    _MAX_CHAIN candidates, then one Huffman-coded block. Not a zlib
    stream (RFC 1950) -- a caller needing one, such as write_png, adds
    the 2-byte header and 4-byte Adler-32 trailer itself.

    Every position of every token is indexed, so a match can start
    partway into an earlier one and a run is coded at distance 1. A
    match shorter than _MAX_LAZY is not taken until the position one
    byte on has been searched too: if that one is longer, the byte here
    is emitted as a literal and the longer match follows it.

    The block is coded with whichever of the two Huffman options costs
    fewer bits, worked out from the token stream's symbol frequencies
    before anything is written: the fixed tables (3.2.6), which carry
    no header, or a dynamic code fitted to those frequencies (3.2.7),
    which pays for its header with shorter codes. A handful of bytes
    stays fixed; anything image-sized goes dynamic. The extra bits a
    match's length and distance carry are the same under both, so
    they drop out of the comparison.

    Always one block (BFINAL=1 from the start): RFC 1951 caps a stored
    block at 65535 bytes but puts no upper bound on a compressed one.

    Args:
        data: Bytes to compress.

    Returns:
        The compressed bytes, no zlib wrapper.
    """
    # The same base-length/base-distance tables _codes() decodes
    # against.
    var lens = _length_bases()
    var lext = _length_extra_bits()
    var dists = _distance_bases()
    var dext = _distance_extra_bits()

    # Pass one: LZ77 into a token buffer, counting symbols as it goes.
    var n = len(data)
    var chains = _HashChains(n)
    var tokens = List[_Token]()
    var lit_freq = List[Int](length=_MAX_L_CODES, fill=0)
    var dist_freq = List[Int](length=_MAX_D_CODES, fill=0)
    var i = 0
    # The match the previous position's look-ahead found and left for
    # this one, so a deferred match is searched for once rather than
    # twice.
    var deferred = _Match(0, 0)
    var have_deferred = False
    while i < n:
        var m: _Match
        if have_deferred:
            m = deferred
            have_deferred = False
        else:
            m = _find_match(chains, data, i)
        if m.length >= _MIN_MATCH:
            # Lazy matching: a match starting one byte later may be
            # longer than this one, and a literal plus the longer match
            # then covers the same bytes in fewer bits than this match
            # plus whatever follows it. Skipped when this match already
            # runs as far as one starting a byte later could reach,
            # where no improvement is possible.
            if m.length < min(_MAX_LAZY, n - i):
                chains.index_upto(data, i + 1)
                var later = _find_match(chains, data, i + 1)
                if later.length > m.length:
                    var byte = Int(data[i])
                    tokens.append(_Token(byte, 0))
                    lit_freq[byte] += 1
                    deferred = later
                    have_deferred = True
                    i += 1
                    continue
            tokens.append(_Token(m.length, m.distance))
            lit_freq[257 + _length_symbol(m.length, lens)] += 1
            dist_freq[_distance_symbol(m.distance, dists)] += 1
            # Every position the match covers is indexed, not only the
            # position the search ran from. Inside a run, that puts the
            # immediately preceding position in the bucket, so the next
            # search finds it at distance 1 -- which costs no extra
            # bits -- rather than reaching back to the run's start.
            chains.index_upto(data, i + m.length)
            i += m.length
        else:
            var byte = Int(data[i])
            tokens.append(_Token(byte, 0))
            lit_freq[byte] += 1
            chains.index_upto(data, i + 1)
            i += 1
    lit_freq[256] = 1  # end-of-block, sent exactly once

    # A dynamic code for these frequencies, and what it would cost.
    var dyn_lit = _huffman_lengths(lit_freq, _MAX_BITS)
    var dyn_dist = _huffman_lengths(dist_freq, _MAX_BITS)
    # HLIT/HDIST: trailing unused symbols are not transmitted. 257
    # literal/length codes and 1 distance code are the minimums the
    # header can express.
    var nlit = _MAX_L_CODES
    while nlit > 257 and dyn_lit[nlit - 1] == 0:
        nlit -= 1
    var ndist = _MAX_D_CODES
    while ndist > 1 and dyn_dist[ndist - 1] == 0:
        ndist -= 1
    var combined = List[Int](capacity=nlit + ndist)
    combined.extend(dyn_lit[0:nlit])
    combined.extend(dyn_dist[0:ndist])
    var rle = _run_length_code(combined)
    var cl_freq = List[Int](length=19, fill=0)
    for code in rle:
        cl_freq[code.symbol] += 1
    var cl_lengths = _huffman_lengths(cl_freq, 7)
    var order = _code_length_order()
    var ncl = 19
    while ncl > 4 and cl_lengths[order[ncl - 1]] == 0:
        ncl -= 1

    var dynamic_bits = 5 + 5 + 4 + 3 * ncl
    for code in rle:
        dynamic_bits += cl_lengths[code.symbol] + code.extra_bits
    for symbol in range(_MAX_L_CODES):
        dynamic_bits += lit_freq[symbol] * dyn_lit[symbol]
    for symbol in range(_MAX_D_CODES):
        dynamic_bits += dist_freq[symbol] * dyn_dist[symbol]

    var fixed_lit = _fixed_lit_lengths()
    var fixed_bits = 0
    for symbol in range(_MAX_L_CODES):
        fixed_bits += lit_freq[symbol] * fixed_lit[symbol]
    for symbol in range(_MAX_D_CODES):
        fixed_bits += dist_freq[symbol] * 5

    # Pass two: the header, then the tokens through the chosen code.
    var writer = _BitWriter()
    writer.write_bits(1, 1)  # BFINAL = 1 -- the only block
    var lit_lengths: List[Int]
    var dist_lengths: List[Int]
    if dynamic_bits < fixed_bits:
        writer.write_bits(2, 2)  # BTYPE = 10 (dynamic Huffman)
        writer.write_bits(nlit - 257, 5)
        writer.write_bits(ndist - 1, 5)
        writer.write_bits(ncl - 4, 4)
        for k in range(ncl):
            writer.write_bits(cl_lengths[order[k]], 3)
        var cl_codes = _build_codes(cl_lengths)
        for code in rle:
            writer.write_bits(cl_codes[code.symbol], cl_lengths[code.symbol])
            if code.extra_bits > 0:
                writer.write_bits(code.extra, code.extra_bits)
        lit_lengths = dyn_lit^
        dist_lengths = dyn_dist^
    else:
        writer.write_bits(1, 2)  # BTYPE = 01 (fixed Huffman)
        lit_lengths = fixed_lit^
        dist_lengths = _fixed_dist_lengths()
    var lit_codes = _build_codes(lit_lengths)
    var dist_codes = _build_codes(dist_lengths)

    for token in tokens:
        if token.distance == 0:
            writer.write_bits(lit_codes[token.value], lit_lengths[token.value])
            continue
        var lsym = _length_symbol(token.value, lens)
        writer.write_bits(lit_codes[257 + lsym], lit_lengths[257 + lsym])
        writer.write_bits(token.value - lens[lsym], lext[lsym])
        var dsym = _distance_symbol(token.distance, dists)
        writer.write_bits(dist_codes[dsym], dist_lengths[dsym])
        writer.write_bits(token.distance - dists[dsym], dext[dsym])

    writer.write_bits(lit_codes[256], lit_lengths[256])  # end-of-block
    return writer.finish()
