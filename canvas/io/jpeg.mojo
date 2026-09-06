"""Read baseline JPEG files (ITU T.81), stdlib-only, with no libjpeg
dependency.

A JPEG file is a sequence of marker segments -- quantization tables
(DQT), Huffman tables (DHT), the frame header (SOF), an optional
restart interval (DRI), and the scan (SOS) whose entropy-coded data
runs to the next marker -- followed by EOI. `decode_jpeg` walks the
segments, and for the scan decodes each minimum coded unit (MCU) in
order: per component, `v x h` blocks of 64 quantized DCT
coefficients, each a Huffman-coded DC difference and run-length
coded AC terms in zigzag order, dequantized and put through the
inverse DCT into the component's sample plane. The planes are then
resampled to the image grid and converted from YCbCr to RGB (JFIF's
equations) into an opaque `Canvas`. A chroma plane subsampled 2:1
horizontally, vertically or both is upsampled with the triangle
filter libjpeg calls "fancy" (`_upsample`): each output sample is
three parts the nearest input sample to one part the next nearest,
with libjpeg's rounding, so a file decodes to the same pixels here
as through libjpeg to within the inverse DCT's rounding. Other
ratios take the nearest sample.

Scope: baseline and extended sequential Huffman processes (SOF0 and
SOF1) at 8-bit precision, 1 or 3 components, any sampling factors,
with or without restart intervals. Progressive (SOF2), lossless,
hierarchical, arithmetic-coded and 12-bit files raise with the
reason, as does a four-component (CMYK) file. An Adobe APP14 segment
declaring the three components as RGB rather than YCbCr is honored;
EXIF orientation is not applied.

The Huffman decode is T.81 Annex F.2.2.3, with a nine-bit lookup
ahead of it for the codes short enough to fit, the same shape as
`canvas.io.deflate`'s. The bit reader unstuffs `FF 00` and stops at a
marker, so a truncated scan pads with zero bits rather than reading
past its data.
"""

from std.math import cos, pi, sqrt

from canvas.buffer import Canvas, BYTES_PER_PIXEL

# Bits of lookahead the fast Huffman lookup table covers.
comptime _LOOKUP_BITS = 9


def _zigzag() -> List[Int]:
    """Zigzag index k -> natural (row-major) index of that coefficient
    in the 8x8 block (T.81 Figure A.6)."""
    return [
        0,
        1,
        8,
        16,
        9,
        2,
        3,
        10,
        17,
        24,
        32,
        25,
        18,
        11,
        4,
        5,
        12,
        19,
        26,
        33,
        40,
        48,
        41,
        34,
        27,
        20,
        13,
        6,
        7,
        14,
        21,
        28,
        35,
        42,
        49,
        56,
        57,
        50,
        43,
        36,
        29,
        22,
        15,
        23,
        30,
        37,
        44,
        51,
        58,
        59,
        52,
        45,
        38,
        31,
        39,
        46,
        53,
        60,
        61,
        54,
        47,
        55,
        62,
        63,
    ]


struct _HuffTable(Movable):
    """One DC or AC Huffman table: the canonical code ranges per length
    (`mincode`/`maxcode`/`valptr` into `symbols`, T.81 Annex C) and a
    `_LOOKUP_BITS`-wide table of `(symbol << 8) | length` for the
    codes that short, -1 elsewhere.
    """

    var present: Bool
    var mincode: List[Int]
    var maxcode: List[Int]
    var valptr: List[Int]
    var symbols: List[Int]
    var lookup: List[Int]

    def __init__(out self):
        self.present = False
        self.mincode = List[Int](length=17, fill=0)
        self.maxcode = List[Int](length=17, fill=-1)
        self.valptr = List[Int](length=17, fill=0)
        self.symbols = List[Int]()
        self.lookup = List[Int]()

    def __init__(out self, counts: List[Int], var symbols: List[Int]):
        """From a DHT segment's sixteen code counts (index 1..16) and
        the symbols in order of increasing code length."""
        self.present = True
        self.mincode = List[Int](length=17, fill=0)
        self.maxcode = List[Int](length=17, fill=-1)
        self.valptr = List[Int](length=17, fill=0)
        self.lookup = List[Int](length=1 << _LOOKUP_BITS, fill=-1)
        self.symbols = symbols^
        var code = 0
        var k = 0
        for length in range(1, 17):
            var n = counts[length]
            if n > 0:
                self.valptr[length] = k
                self.mincode[length] = code
                for _ in range(n):
                    if length <= _LOOKUP_BITS:
                        var entry = (self.symbols[k] << 8) | length
                        var lo = code << (_LOOKUP_BITS - length)
                        var hi = (code + 1) << (_LOOKUP_BITS - length)
                        for i in range(lo, hi):
                            self.lookup[i] = entry
                    code += 1
                    k += 1
                self.maxcode[length] = code - 1
            code <<= 1


struct _BitReader(Movable):
    """The scan's entropy-coded bits, most significant first (T.81
    F.2.2.5), with `FF 00` unstuffed to `FF` and a stop at any other
    marker: past it, or past the end of the data, the reader yields
    zero bits, and `marker_pos` says where the marker begins.
    """

    var data: List[UInt8]
    var pos: Int
    var buf: Int
    var cnt: Int
    var marker_pos: Int

    def __init__(out self, var data: List[UInt8], pos: Int):
        self.data = data^
        self.pos = pos
        self.buf = 0
        self.cnt = 0
        self.marker_pos = -1

    def _fill(mut self, want: Int):
        var p = self.data.unsafe_ptr()
        var n = len(self.data)
        # Refill to well past `want`, so a symbol and the bits after it
        # come out of one refill rather than two.
        while self.cnt < 32:
            var b = 0
            if self.marker_pos < 0 and self.pos < n:
                b = Int(p[unsafe_offset=self.pos])
                if b == 0xFF:
                    var nxt = 0
                    if self.pos + 1 < n:
                        nxt = Int(p[unsafe_offset=self.pos + 1])
                    if nxt == 0:
                        self.pos += 2
                    elif nxt == 0xFF:
                        # Fill byte ahead of a marker: skip it.
                        self.pos += 1
                        continue
                    else:
                        self.marker_pos = self.pos
                        b = 0
                else:
                    self.pos += 1
            self.buf = (self.buf << 8) | b
            self.cnt += 8

    @always_inline
    def peek(mut self, n: Int) -> Int:
        if self.cnt < n:
            self._fill(n)
        return (self.buf >> (self.cnt - n)) & ((1 << n) - 1)

    @always_inline
    def drop(mut self, n: Int):
        self.cnt -= n
        self.buf &= (1 << self.cnt) - 1

    def bits(mut self, n: Int) -> Int:
        if n == 0:
            return 0
        var v = self.peek(n)
        self.drop(n)
        return v

    def restart(mut self) raises:
        """At a restart interval boundary: discard the partial byte,
        consume the RSTn marker, and resume after it."""
        self.buf = 0
        self.cnt = 0
        var p = self.marker_pos if self.marker_pos >= 0 else self.pos
        while (
            p + 1 < len(self.data)
            and self.data[p] == 0xFF
            and self.data[p + 1] == 0xFF
        ):
            p += 1
        if p + 1 >= len(self.data) or self.data[p] != 0xFF:
            raise Error("jpeg: expected a restart marker")
        var m = Int(self.data[p + 1])
        if m < 0xD0 or m > 0xD7:
            raise Error("jpeg: expected a restart marker")
        self.pos = p + 2
        self.marker_pos = -1

    def end(self) -> Int:
        """Where the scan's data ends: the marker that stopped the
        reader, or the current position."""
        return self.marker_pos if self.marker_pos >= 0 else self.pos


def _decode_symbol(mut bits: _BitReader, table: _HuffTable) raises -> Int:
    var entry = table.lookup.unsafe_ptr()[unsafe_offset=bits.peek(_LOOKUP_BITS)]
    if entry >= 0:
        bits.drop(entry & 0xFF)
        return entry >> 8
    var code = bits.bits(1)
    var length = 1
    while code > table.maxcode[length]:
        code = (code << 1) | bits.bits(1)
        length += 1
        if length > 16:
            raise Error("jpeg: invalid Huffman code in scan data")
    return table.symbols[table.valptr[length] + code - table.mincode[length]]


@always_inline
def _extend(v: Int, s: Int) -> Int:
    """T.81 F.2.2.1 EXTEND: `s` received bits to a signed value."""
    if s == 0:
        return 0
    if v < (1 << (s - 1)):
        return v - (1 << s) + 1
    return v


struct _Component(Movable):
    """One image component: its sampling factors, quantization table
    index, Huffman table indices from the scan header, DC predictor,
    and sample plane (`pw x ph`, a whole number of MCUs)."""

    var id: Int
    var h: Int
    var v: Int
    var tq: Int
    var td: Int
    var ta: Int
    var dc_pred: Int
    var pw: Int
    var ph: Int
    var plane: List[UInt8]

    def __init__(out self, id: Int, h: Int, v: Int, tq: Int):
        self.id = id
        self.h = h
        self.v = v
        self.tq = tq
        self.td = 0
        self.ta = 0
        self.dc_pred = 0
        self.pw = 0
        self.ph = 0
        self.plane = List[UInt8]()


def _idct_table() -> List[Float32]:
    """`c[u * 8 + x] = C(u) / 2 * cos((2x + 1) u pi / 16)`, the 1-D
    inverse DCT basis (T.81 A.3.3), laid out so the eight outputs of
    one input frequency are one contiguous vector."""
    var t = List[Float32](length=64, fill=0.0)
    for x in range(8):
        for u in range(8):
            var cu = 1.0 / sqrt(2.0) if u == 0 else 1.0
            t[u * 8 + x] = Float32(
                cu / 2.0 * cos(Float64(2 * x + 1) * Float64(u) * pi / 16.0)
            )
    return t^


def _idct_block(
    coef: List[Int],
    basis: List[Float32],
    mut plane: List[UInt8],
    plane_w: Int,
    bx: Int,
    by: Int,
):
    """Inverse DCT of the 64 dequantized coefficients in `coef`
    (natural order), level-shifted by 128, clamped, into the 8x8 block
    of `plane` whose top-left sample is (bx, by). Separable, each pass
    an eight-lane vector: a row's eight outputs are the sum over its
    frequencies of the coefficient times that frequency's basis
    vector, and a zero coefficient -- most of them, after
    quantization -- is skipped."""
    comptime V = SIMD[DType.float32, 8]
    var cp = coef.unsafe_ptr()
    var bp = basis.unsafe_ptr()
    var rows = InlineArray[V, 8](fill=V(0.0))
    for v in range(8):
        var acc = V(0.0)
        for u in range(8):
            var c = cp[unsafe_offset=v * 8 + u]
            if c != 0:
                acc += (
                    V(Float32(c))
                    * bp.unsafe_offset(u * 8).unsafe_load[width=8]()
                )
        rows[v] = acc
    # Columns: output row y is the sum over v of rows[v] (the eight x
    # values at frequency v) times basis[v][y].
    var pp = plane.unsafe_ptr()
    for y in range(8):
        var acc = V(128.5)
        for v in range(8):
            acc += rows[v] * V(bp[unsafe_offset=v * 8 + y])
        var clamped = acc.clamp(0.0, 255.0).cast[DType.uint8]()
        pp.unsafe_offset((by + y) * plane_w + bx).unsafe_store(clamped)


def _flat_block(
    dc: Int, mut plane: List[UInt8], plane_w: Int, bx: Int, by: Int
):
    """The inverse DCT of a block whose only term is DC: every sample
    is `dc / 8` plus the level shift."""
    var s = Int(Float32(dc) / 8.0 + 128.5) if dc >= 0 else Int(
        Float32(dc) / 8.0 + 128.5
    )
    if s < 0:
        s = 0
    if s > 255:
        s = 255
    var v = UInt8(s)
    var pp = plane.unsafe_ptr()
    for y in range(8):
        var row = (by + y) * plane_w + bx
        for x in range(8):
            pp[unsafe_offset=row + x] = v


def _u16(data: List[UInt8], pos: Int) raises -> Int:
    if pos + 2 > len(data):
        raise Error("jpeg: truncated segment")
    return (Int(data[pos]) << 8) | Int(data[pos + 1])


def read_jpeg(path: String) raises -> Canvas:
    """Read a baseline JPEG file into an opaque Canvas. See the module
    docstring for what is and is not supported.

    Args:
        path: File path to read.

    Returns:
        The decoded image as a Canvas, every pixel opaque.

    Raises:
        Error: `path` can't be read, isn't a JPEG, uses an unsupported
            process (progressive, lossless, arithmetic, 12-bit, CMYK),
            or is malformed.
    """
    var f = open(path, "r")
    var data = f.read_bytes()
    f.close()
    return decode_jpeg(data^)


def decode_jpeg(var data: List[UInt8]) raises -> Canvas:
    """Decode a baseline JPEG held in memory into a Canvas: `read_jpeg`
    after the file is read. Same scope and errors.

    Args:
        data: The complete JPEG file contents.

    Returns:
        The decoded image as an opaque RGBA canvas.

    Raises:
        Error: Not a JPEG, an unsupported process, or malformed data.
    """
    if len(data) < 4 or data[0] != 0xFF or data[1] != 0xD8:
        raise Error("jpeg: missing SOI marker -- not a JPEG file")

    var qt = List[List[Int]]()
    for _ in range(4):
        qt.append(List[Int](length=64, fill=0))
    var qt_present = List[Bool](length=4, fill=False)
    var dc_tables = List[_HuffTable]()
    var ac_tables = List[_HuffTable]()
    for _ in range(4):
        dc_tables.append(_HuffTable())
        ac_tables.append(_HuffTable())
    var zz = _zigzag()

    var width = 0
    var height = 0
    var comps = List[_Component]()
    var hmax = 1
    var vmax = 1
    var restart_interval = 0
    var adobe_transform = -1
    var have_frame = False
    var have_scan = False

    var pos = 2
    while pos < len(data):
        # Find the next marker, skipping fill bytes.
        if data[pos] != 0xFF:
            raise Error("jpeg: expected a marker")
        while pos < len(data) and data[pos] == 0xFF:
            pos += 1
        if pos >= len(data):
            break
        var marker = Int(data[pos])
        pos += 1
        if (
            marker == 0xD8
            or (marker >= 0xD0 and marker <= 0xD7)
            or marker == 0x01
        ):
            continue
        if marker == 0xD9:
            break
        var length = _u16(data, pos)
        var seg = pos + 2
        var seg_end = pos + length
        if seg_end > len(data):
            raise Error("jpeg: truncated segment")
        pos = seg_end

        if marker == 0xDB:
            # DQT: one or more tables, 8- or 16-bit, in zigzag order.
            var p = seg
            while p < seg_end:
                var pq = Int(data[p]) >> 4
                var tq = Int(data[p]) & 15
                if tq > 3:
                    raise Error("jpeg: quantization table index out of range")
                p += 1
                for k in range(64):
                    if pq == 0:
                        qt[tq][k] = Int(data[p])
                        p += 1
                    else:
                        qt[tq][k] = _u16(data, p)
                        p += 2
                qt_present[tq] = True
        elif marker == 0xC4:
            # DHT: one or more tables.
            var p = seg
            while p < seg_end:
                var tc = Int(data[p]) >> 4
                var th = Int(data[p]) & 15
                if th > 3 or tc > 1:
                    raise Error("jpeg: Huffman table index out of range")
                p += 1
                var counts = List[Int](length=17, fill=0)
                var total = 0
                for i in range(1, 17):
                    counts[i] = Int(data[p])
                    total += counts[i]
                    p += 1
                if p + total > seg_end:
                    raise Error("jpeg: truncated Huffman table")
                var symbols = List[Int](capacity=total)
                for i in range(total):
                    symbols.append(Int(data[p + i]))
                p += total
                if tc == 0:
                    dc_tables[th] = _HuffTable(counts, symbols^)
                else:
                    ac_tables[th] = _HuffTable(counts, symbols^)
        elif marker == 0xC0 or marker == 0xC1:
            if have_frame:
                raise Error("jpeg: more than one frame header")
            var precision = Int(data[seg])
            if precision != 8:
                raise Error(
                    String(
                        "jpeg: unsupported sample precision ",
                        precision,
                        " (only 8-bit)",
                    )
                )
            height = _u16(data, seg + 1)
            width = _u16(data, seg + 3)
            var n = Int(data[seg + 5])
            if height == 0 or width == 0:
                raise Error("jpeg: invalid image dimensions")
            if n != 1 and n != 3:
                raise Error(
                    String(
                        "jpeg: unsupported component count ",
                        n,
                        " (only 1 or 3)",
                    )
                )
            for i in range(n):
                var b = seg + 6 + i * 3
                var hv = Int(data[b + 1])
                var h = hv >> 4
                var v = hv & 15
                if h < 1 or h > 4 or v < 1 or v > 4:
                    raise Error("jpeg: invalid sampling factors")
                comps.append(
                    _Component(Int(data[b]), h, v, Int(data[b + 2]) & 3)
                )
                if h > hmax:
                    hmax = h
                if v > vmax:
                    vmax = v
            have_frame = True
        elif marker == 0xC2:
            raise Error(
                "jpeg: progressive JPEG is not supported (baseline only)"
            )
        elif (
            marker == 0xC3
            or (marker >= 0xC5 and marker <= 0xC7)
            or (marker >= 0xC9 and marker <= 0xCB)
            or (marker >= 0xCD and marker <= 0xCF)
        ):
            raise Error(
                "jpeg: unsupported process (lossless, hierarchical or"
                " arithmetic-coded)"
            )
        elif marker == 0xDD:
            restart_interval = _u16(data, seg)
        elif marker == 0xEE:
            # Adobe APP14: byte 11 of the segment is the color transform
            # flag -- 0 for RGB, 1 for YCbCr.
            if (
                length >= 14
                and data[seg] == 0x41
                and data[seg + 1] == 0x64
                and data[seg + 2] == 0x6F
                and data[seg + 3] == 0x62
                and data[seg + 4] == 0x65
            ):
                adobe_transform = Int(data[seg + 11])
        elif marker == 0xDA:
            if not have_frame:
                raise Error("jpeg: scan before frame header")
            if have_scan:
                raise Error("jpeg: more than one scan (baseline only)")
            var ns = Int(data[seg])
            if ns != len(comps):
                raise Error(
                    "jpeg: a scan covering fewer components than the frame"
                    " is not supported"
                )
            for i in range(ns):
                var cid = Int(data[seg + 1 + i * 2])
                var t = Int(data[seg + 2 + i * 2])
                var found = False
                for c in range(len(comps)):
                    if comps[c].id == cid:
                        comps[c].td = t >> 4
                        comps[c].ta = t & 15
                        found = True
                if not found:
                    raise Error("jpeg: scan names a component the frame lacks")
            have_scan = True
            pos = _decode_scan(
                data,
                seg_end,
                comps,
                hmax,
                vmax,
                width,
                height,
                qt,
                qt_present,
                dc_tables,
                ac_tables,
                zz,
                restart_interval,
            )
        # Every other segment (APPn, COM, DNL, ...) is skipped.

    if not have_scan:
        raise Error("jpeg: no scan data")
    return _to_canvas(comps, hmax, vmax, width, height, adobe_transform)


def _decode_scan(
    data: List[UInt8],
    start: Int,
    mut comps: List[_Component],
    hmax: Int,
    vmax: Int,
    width: Int,
    height: Int,
    qt: List[List[Int]],
    qt_present: List[Bool],
    dc_tables: List[_HuffTable],
    ac_tables: List[_HuffTable],
    zz: List[Int],
    restart_interval: Int,
) raises -> Int:
    """Decode the entropy-coded data from `start` into every
    component's plane, MCU by MCU. Returns where the data ended."""
    var mcu_w = 8 * hmax
    var mcu_h = 8 * vmax
    var mcus_x = (width + mcu_w - 1) // mcu_w
    var mcus_y = (height + mcu_h - 1) // mcu_h
    for c in range(len(comps)):
        comps[c].pw = mcus_x * comps[c].h * 8
        comps[c].ph = mcus_y * comps[c].v * 8
        comps[c].plane = List[UInt8](length=comps[c].pw * comps[c].ph, fill=0)
        comps[c].dc_pred = 0
        if not qt_present[comps[c].tq]:
            raise Error(
                "jpeg: scan uses a quantization table that was not defined"
            )
        if (
            not dc_tables[comps[c].td].present
            or not ac_tables[comps[c].ta].present
        ):
            raise Error("jpeg: scan uses a Huffman table that was not defined")

    var basis = _idct_table()
    var coef = List[Int](length=64, fill=0)
    var bits = _BitReader(data.copy(), start)
    var mcu_count = 0
    for my in range(mcus_y):
        for mx in range(mcus_x):
            if (
                restart_interval > 0
                and mcu_count > 0
                and mcu_count % restart_interval == 0
            ):
                bits.restart()
                for c in range(len(comps)):
                    comps[c].dc_pred = 0
            for c in range(len(comps)):
                var h = comps[c].h
                var v = comps[c].v
                for by in range(v):
                    for bx in range(h):
                        var any_ac = _decode_block(
                            bits,
                            dc_tables[comps[c].td],
                            ac_tables[comps[c].ta],
                            qt[comps[c].tq],
                            zz,
                            comps[c],
                            coef,
                        )
                        if any_ac:
                            _idct_block(
                                coef,
                                basis,
                                comps[c].plane,
                                comps[c].pw,
                                (mx * h + bx) * 8,
                                (my * v + by) * 8,
                            )
                        else:
                            _flat_block(
                                coef[0],
                                comps[c].plane,
                                comps[c].pw,
                                (mx * h + bx) * 8,
                                (my * v + by) * 8,
                            )
            mcu_count += 1
    return bits.end()


def _decode_block(
    mut bits: _BitReader,
    dc: _HuffTable,
    ac: _HuffTable,
    q: List[Int],
    zz: List[Int],
    mut comp: _Component,
    mut coef: List[Int],
) raises -> Bool:
    """One block's DC difference and AC run/size pairs (T.81 F.2.2),
    dequantized into `coef` in natural order. Returns whether any AC
    term was non-zero; a block that is DC alone is flat, and the
    inverse DCT of it is a broadcast."""
    # `coef`, `zz` and `q` are 64 long and `k` stays within 0..63, so
    # the accesses below go through pointers.
    var cp = coef.unsafe_ptr()
    var zp = zz.unsafe_ptr()
    var qp = q.unsafe_ptr()
    for i in range(64):
        cp[unsafe_offset=i] = 0
    var t = _decode_symbol(bits, dc)
    if t > 11:
        raise Error("jpeg: invalid DC category")
    comp.dc_pred += _extend(bits.bits(t), t)
    cp[unsafe_offset=0] = comp.dc_pred * qp[unsafe_offset=0]
    var any_ac = False
    var k = 1
    while k < 64:
        var rs = _decode_symbol(bits, ac)
        var r = rs >> 4
        var s = rs & 15
        if s == 0:
            if r == 15:
                k += 16
                continue
            break
        k += r
        if k > 63:
            raise Error("jpeg: AC coefficient run past the block")
        cp[unsafe_offset=zp[unsafe_offset=k]] = (
            _extend(bits.bits(s), s) * qp[unsafe_offset=k]
        )
        any_ac = True
        k += 1
    return any_ac


@always_inline
def _clamp_byte(v: Float32) -> UInt8:
    var i = Int(v + 0.5)
    if i < 0:
        return 0
    if i > 255:
        return 255
    return UInt8(i)


def _upsample(
    comp: _Component, hmax: Int, vmax: Int, width: Int, height: Int
) -> List[UInt8]:
    """`comp`'s plane resampled to `width x height`. A 2:1 ratio in
    either direction takes libjpeg's fancy (triangle) upsampling with
    its rounding, edges replicated; anything else the nearest sample.
    """
    var cw = (width * comp.h + hmax - 1) // hmax
    var ch = (height * comp.v + vmax - 1) // vmax
    var pw = comp.pw
    var sp = comp.plane.unsafe_ptr()
    var out = List[UInt8](unsafe_uninit_length=width * height)
    var op = out.unsafe_ptr()
    var rx = hmax // comp.h
    var ry = vmax // comp.v
    var fancy_x = rx == 2 and hmax % comp.h == 0
    var fancy_y = ry == 2 and vmax % comp.v == 0
    var plain_x = rx == 1 and hmax % comp.h == 0
    var plain_y = ry == 1 and vmax % comp.v == 0
    if (fancy_x or plain_x) and (fancy_y or plain_y) and cw >= 1 and ch >= 1:
        # Column sums first (the vertical pass), then the horizontal
        # pass over them -- jdsample.c's h2v2, h2v1 and h1v2 kernels,
        # unified: a direction not upsampled has weight 4 on its own
        # row/column (the sum of 3 and 1), which keeps one rounding
        # rule for every case.
        var colsum = List[Int](length=cw, fill=0)
        var cp = colsum.unsafe_ptr()
        var out_h = ch * ry
        for oy in range(min(out_h, height)):
            var iy = oy // ry
            var row0 = sp.unsafe_offset(iy * pw)
            if fancy_y:
                var near = iy - 1 if oy % 2 == 0 else iy + 1
                if near < 0:
                    near = 0
                if near > ch - 1:
                    near = ch - 1
                var row1 = sp.unsafe_offset(near * pw)
                for x in range(cw):
                    cp[unsafe_offset=x] = Int(row0[unsafe_offset=x]) * 3 + Int(
                        row1[unsafe_offset=x]
                    )
            else:
                for x in range(cw):
                    cp[unsafe_offset=x] = Int(row0[unsafe_offset=x]) * 4
            var dst = op.unsafe_offset(oy * width)
            if fancy_x:
                for x in range(cw):
                    var this = cp[unsafe_offset=x]
                    var last = cp[unsafe_offset=x - 1] if x > 0 else this
                    var nxt = cp[unsafe_offset=x + 1] if x < cw - 1 else this
                    var ox = 2 * x
                    if ox < width:
                        dst[unsafe_offset=ox] = UInt8(
                            (this * 3 + last + 8) >> 4
                        )
                    if ox + 1 < width:
                        dst[unsafe_offset=ox + 1] = UInt8(
                            (this * 3 + nxt + 7) >> 4
                        )
            else:
                for x in range(min(cw, width)):
                    dst[unsafe_offset=x] = UInt8((cp[unsafe_offset=x] + 2) >> 2)
        # Rows past the plane's own (a height not a multiple of the
        # ratio) repeat the last one.
        for oy in range(min(out_h, height), height):
            for x in range(width):
                op[unsafe_offset=oy * width + x] = op[
                    unsafe_offset=(out_h - 1) * width + x
                ]
        return out^
    for y in range(height):
        var iy = y * comp.v // vmax
        for x in range(width):
            op[unsafe_offset=y * width + x] = sp[
                unsafe_offset=iy * pw + x * comp.h // hmax
            ]
    return out^


def _to_canvas(
    comps: List[_Component],
    hmax: Int,
    vmax: Int,
    width: Int,
    height: Int,
    adobe_transform: Int,
) raises -> Canvas:
    """The component planes resampled to the image grid and converted
    to RGB. Three components are YCbCr (JFIF) unless an Adobe segment
    said RGB; one is grayscale."""
    var pixels = List[UInt8](
        unsafe_uninit_length=width * height * BYTES_PER_PIXEL
    )
    var dp = pixels.unsafe_ptr()
    var n = width * height
    if len(comps) == 1:
        var g = _upsample(comps[0], hmax, vmax, width, height)
        var gp = g.unsafe_ptr()
        for i in range(n):
            var v = gp[unsafe_offset=i]
            var d = i * BYTES_PER_PIXEL
            dp[unsafe_offset=d] = v
            dp[unsafe_offset=d + 1] = v
            dp[unsafe_offset=d + 2] = v
            dp[unsafe_offset=d + 3] = 255
        return Canvas(width, height, pixels^)

    var y_plane = _upsample(comps[0], hmax, vmax, width, height)
    var cb_plane = _upsample(comps[1], hmax, vmax, width, height)
    var cr_plane = _upsample(comps[2], hmax, vmax, width, height)
    var yp = y_plane.unsafe_ptr()
    var bp = cb_plane.unsafe_ptr()
    var rp = cr_plane.unsafe_ptr()
    var rgb = adobe_transform == 0
    for i in range(n):
        var a = Float32(yp[unsafe_offset=i])
        var b = Float32(bp[unsafe_offset=i])
        var c = Float32(rp[unsafe_offset=i])
        var d = i * BYTES_PER_PIXEL
        if rgb:
            dp[unsafe_offset=d] = yp[unsafe_offset=i]
            dp[unsafe_offset=d + 1] = bp[unsafe_offset=i]
            dp[unsafe_offset=d + 2] = rp[unsafe_offset=i]
        else:
            var cb = b - 128.0
            var cr = c - 128.0
            dp[unsafe_offset=d] = _clamp_byte(a + 1.402 * cr)
            dp[unsafe_offset=d + 1] = _clamp_byte(
                a - 0.344136 * cb - 0.714136 * cr
            )
            dp[unsafe_offset=d + 2] = _clamp_byte(a + 1.772 * cb)
        dp[unsafe_offset=d + 3] = 255
    return Canvas(width, height, pixels^)
