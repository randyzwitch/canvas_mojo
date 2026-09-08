"""Read and write PNG files, stdlib-only, with no zlib/libpng
dependency.

PNG's image data is a zlib stream (RFC 1950) around a DEFLATE stream
(RFC 1951). Both directions go through `canvas/io/deflate.mojo`.

Two checksums, from the PNG spec Appendix D (CRC-32) and RFC 1950
section 9 (Adler-32). `read_png` checks both on every file it reads --
chunk CRC-32s, and the decompressed data's Adler-32 against the zlib
trailer.

Watch the two byte orders: PNG's chunk framing (length, CRC-32) and the
zlib Adler-32 trailer are big-endian, but DEFLATE's stored-block
LEN/NLEN fields are little-endian.

`write_png` emits color type 6 (truecolor + alpha) when the canvas
contains a pixel that is not fully opaque, and color type 2 otherwise.
Rows go out either unfiltered or Sub-filtered (spec section 9),
whichever compresses smaller, and the choice is made on a sample:
every eighth row is compressed both ways, then the whole image is
compressed once in the encoding that sample picked. `PngLevel` sets
how much of that search happens -- `FAST` skips it outright on an
image flat enough for the answer not to be in doubt, `SMALL`
compresses both encodings in full rather than sampling.
`read_png` accepts color types 0/2/4/6 at 8 or 16 bits and indexed
color (type 3, `PLTE` with an optional `tRNS`) at 1/2/4/8 bits,
Adam7-interlaced or not. A 16-bit sample reduces to 8 by
`round(v * 255 / 65535)`, and a `tRNS` color key is compared against
the sample before that reduction, since two 16-bit values a level
apart can share an 8-bit result. Grayscale below 8 bits is the one
combination the spec allows and this does not; it raises, as an
unknown bit depth, color type or interlace method does, rather than
misreading pixels. Alpha is preserved in both directions, so an 8-bit
file round-trips through `read_png` -> `write_png` unchanged.
"""

from std.math import iota

from canvas.buffer import Canvas, BYTES_PER_PIXEL
from canvas.color import Color
from canvas.io.deflate import (
    _MAX_CHAIN as _DEFLATE_MAX_CHAIN,
    _MAX_LAZY as _DEFLATE_MAX_LAZY,
    deflate,
    inflate,
)


def _append_u16_le(mut buf: List[UInt8], value: UInt16):
    buf.append(UInt8(value & 0xFF))
    buf.append(UInt8((value >> 8) & 0xFF))


def _append_u16_be(mut buf: List[UInt8], value: UInt16):
    buf.append(UInt8((value >> 8) & 0xFF))
    buf.append(UInt8(value & 0xFF))


def _append_u32_be(mut buf: List[UInt8], value: UInt32):
    buf.append(UInt8((value >> 24) & 0xFF))
    buf.append(UInt8((value >> 16) & 0xFF))
    buf.append(UInt8((value >> 8) & 0xFF))
    buf.append(UInt8(value & 0xFF))


def _crc32_table() -> List[UInt32]:
    """Standard CRC-32 (IEEE 802.3 / zlib / PNG) table from the
    polynomial 0xEDB88320, the reversed-bit-order form of the canonical
    0x04C11DB7, since PNG and zlib both process bits
    least-significant-first. From the PNG spec's sample code (Appendix
    D), verified against zlib's crc32.
    """
    var table = List[UInt32](capacity=256)
    for n in range(256):
        var c = UInt32(n)
        for _ in range(8):
            if (c & 1) == 1:
                c = UInt32(0xEDB88320) ^ (c >> 1)
            else:
                c = c >> 1
        table.append(c)
    return table^


def _crc32(data: Span[UInt8, _], table: List[UInt32]) -> UInt32:
    """CRC-32 of `data`. A `Span`, so a caller checking a chunk
    already sitting in a larger buffer passes a view rather than a
    copy.
    """
    var c = UInt32(0xFFFFFFFF)
    for byte in data:
        c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
    return c ^ UInt32(0xFFFFFFFF)


struct PngLevel(Copyable, Equatable, ImplicitlyCopyable, Movable, Writable):
    """How hard `write_png` works to make the file small.

    Every level produces a fully valid PNG that decodes to exactly the
    same pixels; they differ only in how long the encode takes and how
    many bytes come out. Two knobs move together: how far DEFLATE's
    match search walks a hash chain, and how much effort goes into
    choosing between unfiltered and Sub-filtered scanlines.

    FAST settles the filter choice without compressing anything, when
    the image is flat enough for the answer not to be in doubt.
    DEFAULT is what the writer has always done and stays the default.
    SMALL compresses the whole image both ways rather than sampling
    every eighth row, and walks a hash chain four times longer.

    Measured across five images, best of five each:

                          FAST      DEFAULT     SMALL
      chart 800x600     3.3 ms      4.1 ms     7.8 ms
                        9,964 B     9,964 B    9,916 B
      gradient 800x600  3.3 ms      4.3 ms     7.5 ms
                        13,989 B    13,989 B   10,958 B
      grainy 400x300    39.1 ms     39.0 ms    59.0 ms
                        182,136 B   182,136 B  181,793 B
      RGBA 400x300      1.3 ms      1.7 ms     3.7 ms
                        4,658 B     4,658 B    4,631 B

    FAST is about a fifth faster on flat content and identical on
    grainy content, where the probe declines and it falls back. It
    produced the same bytes as DEFAULT on all five, which is what the
    probe is for: it does not guess which filter is better, only
    whether the question is easy.

    Two other ways to make FAST faster were tried and dropped. A short
    chain with the look-ahead off makes a gradient three times larger
    for no time saved, because unfiltered gradient rows are slow to
    deflate. And bounding how much of a match goes into the hash
    chains, the one knob that still moves LZ77 time, does not bind at
    any setting that leaves smooth images intact.
    """

    var _value: Int

    comptime FAST = Self(0)
    comptime DEFAULT = Self(1)
    comptime SMALL = Self(2)

    def __init__(out self, value: Int):
        """Prefer the `FAST`/`DEFAULT`/`SMALL` comptime constants over
        constructing one directly.

        Args:
            value: 0 for FAST, 1 for DEFAULT, 2 for SMALL.
        """
        self._value = value

    def __eq__(self, other: Self) -> Bool:
        return self._value == other._value

    def __ne__(self, other: Self) -> Bool:
        return self._value != other._value

    def write_to[W: Writer](self, mut writer: W):
        if self._value == Self.FAST._value:
            writer.write("FAST")
        elif self._value == Self.SMALL._value:
            writer.write("SMALL")
        else:
            writer.write("DEFAULT")

    def _max_chain(self) -> Int:
        """Hash-chain candidates DEFLATE's match search may walk."""
        if self._value == Self.SMALL._value:
            return 128
        return 32

    def _max_lazy(self) -> Int:
        """Match length below which the search still looks one byte
        ahead for a longer one. Zero turns lazy matching off."""
        if self._value == Self.SMALL._value:
            return 128
        return 64

    def _skips_filter_search(self) -> Bool:
        """Whether this level may decide the filter without
        compressing anything, when the image is flat enough for the
        answer not to be in doubt."""
        return self._value == Self.FAST._value

    def _filter_sample_stride(self) -> Int:
        """Rows between the ones the unfiltered/Sub choice is decided
        on. Zero compares the whole image both ways."""
        if self._value == Self.SMALL._value:
            return 0
        return _FILTER_SAMPLE_STRIDE


def _adler32(data: List[UInt8]) -> UInt32:
    """RFC 1950's checksum for the zlib stream trailer: a running sum,
    not a table-driven algorithm.

    The modulo is deferred rather than taken per byte. `% BASE` is a
    ring homomorphism for addition, so reducing once at the end of a
    block gives the same value as reducing every step, provided the
    accumulators cannot overflow in between.

    Written a byte at a time the recurrence is `s1 += b; s2 += s1`,
    two dependent adds, so it runs at one byte per cycle no matter how
    wide the machine is. Closing the form over a block of `L` bytes
    removes the dependency:

        s1' = s1 + sum(b[i])
        s2' = s2 + L*s1 + sum((L - i) * b[i])

    and both sums come out of two vector accumulators. Stepping
    `vs2 += vs1` before `vs1 += b` leaves `vs1` holding each lane's
    byte total and `vs2` holding it weighted by how many chunks
    followed, which is the position weight up to a per-lane ramp that
    the closing arithmetic subtracts back off.

    Blocks are shorter than the 5552 the byte-at-a-time form allows,
    because these intermediates run larger than the values they add up
    to; 4096 leaves the 32-bit accumulators about half their range
    spare.
    """
    comptime BASE = UInt32(65521)
    comptime W = 32
    comptime BLOCK = 4096
    comptime RAMP = iota[DType.uint32, W]()
    var s1 = UInt32(1)
    var s2 = UInt32(0)
    var n = len(data)
    var p = data.unsafe_ptr()
    var i = 0
    while i < n:
        var block = min(BLOCK, n - i)
        var chunks = block // W
        if chunks > 0:
            var vs1 = SIMD[DType.uint32, W](0)
            var vs2 = SIMD[DType.uint32, W](0)
            for c in range(chunks):
                vs2 += vs1
                vs1 += (
                    p.unsafe_offset(i + c * W)
                    .unsafe_load[width=W]()
                    .cast[DType.uint32]()
                )
            var total = vs1.reduce_add()
            var vec_len = UInt32(chunks * W)
            s2 += vec_len * s1
            s2 += (
                UInt32(W) * (vs2.reduce_add() + total)
                - (vs1 * RAMP).reduce_add()
            )
            s1 += total
            var done = chunks * W
            i += done
            block -= done
        for _ in range(block):
            s1 += UInt32(p[unsafe_offset=i])
            s2 += s1
            i += 1
        s1 %= BASE
        s2 %= BASE
    return (s2 << 16) | s1


def _write_chunk(
    mut buf: List[UInt8],
    table: List[UInt32],
    chunk_type: String,
    data: List[UInt8],
):
    """Append one PNG chunk: length(4, data only) + type(4 ASCII) +
    data + CRC-32(4, over type+data, NOT length) -- all big-endian.

    Builds `type_and_data` once -- needed as its own buffer anyway,
    since _crc32 must see type and data combined -- then *moves* it
    into `buf` rather than copying byte by byte. For IDAT, the whole
    compressed image, that's one copy of the payload instead of two.
    """
    _append_u32_be(buf, UInt32(len(data)))

    var type_and_data = List[UInt8](capacity=4 + len(data))
    var type_bytes = chunk_type.as_bytes()
    for i in range(len(type_bytes)):
        type_and_data.append(UInt8(type_bytes[i]))
    type_and_data.extend(data.copy())

    var crc = _crc32(Span(type_and_data), table)
    buf.extend(type_and_data^)
    _append_u32_be(buf, crc)


def _finish_png(
    var file_buf: List[UInt8],
    crc_table: List[UInt32],
    var compressed: List[UInt8],
    adler: UInt32,
    path: String,
) raises:
    """Wrap the DEFLATE stream in zlib, chunk it as IDAT, close the
    file. Shared by the two routes `write_png` takes through the
    filter choice.
    """
    var zlib_stream = List[UInt8]()
    # zlib header (RFC 1950 2.2): CMF=0x78 (deflate, 32K window),
    # FLG=0x01 (FLEVEL=0/"fastest", matching deflate()'s single-block,
    # bounded-search scope). (0x78*256 + 0x01) % 31 == 0, the header's
    # required self-check.
    zlib_stream.append(0x78)
    zlib_stream.append(0x01)
    zlib_stream.extend(compressed^)
    _append_u32_be(zlib_stream, adler)

    _write_chunk(file_buf, crc_table, "IDAT", zlib_stream)
    _write_chunk(file_buf, crc_table, "IEND", List[UInt8]())

    var f = open(path, "w")
    f.write_bytes(Span(file_buf))
    f.close()


def write_png(
    canvas: Canvas, path: String, level: PngLevel = PngLevel.DEFAULT
) raises:
    """Write `canvas` to `path` as an 8-bit, non-interlaced PNG --
    color type 6 (truecolor + alpha) if any pixel is not fully opaque,
    color type 2 (truecolor) otherwise.

    Args:
        canvas: Canvas to write.
        path: File path to write to.
        level: How hard to work at making the file small. Every level
            decodes to the same pixels; see `PngLevel` for what each
            costs and saves.

    Raises:
        Error: `path` can't be opened for writing.
    """
    var w = canvas.width
    var h = canvas.height
    var crc_table = _crc32_table()

    # One pass to decide the color type. `has_alpha` is false for the
    # overwhelming majority of renders (anything drawn onto an opaque
    # background), and those take the 3-bytes-per-pixel path exactly as
    # before.
    var has_alpha = False
    var px = canvas.pixels.unsafe_ptr()
    for i in range(w * h):
        if px[unsafe_offset=i * BYTES_PER_PIXEL + 3] != 255:
            has_alpha = True
            break
    var channels = 4 if has_alpha else 3

    var file_buf = List[UInt8]()
    var signature: List[UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    for b in signature:
        file_buf.append(b)

    var ihdr = List[UInt8]()
    _append_u32_be(ihdr, UInt32(w))
    _append_u32_be(ihdr, UInt32(h))
    ihdr.append(8)  # bit depth
    # 6 = truecolor + alpha, 2 = truecolor. See this module's docstring
    # on why the narrower type is used when nothing needs the wider.
    ihdr.append(UInt8(6) if has_alpha else UInt8(2))
    ihdr.append(0)  # compression method (always 0 -- deflate)
    ihdr.append(0)  # filter method (always 0)
    ihdr.append(0)  # interlace method: none
    _write_chunk(file_buf, crc_table, "IHDR", ihdr)

    # Raw scanlines: a filter-type byte, then that row's pixel bytes,
    # unfiltered (type 0) first.
    #
    # With alpha, the canvas's own RGBA layout *is* the scanline
    # layout, so each row is one bulk slice copy. Without it the alpha
    # byte has to be dropped per pixel, which is a copy either way --
    # still reading straight from the buffer rather than walking
    # `get_pixel`, which would add w * h bounds checks and Color
    # constructions for no gain.
    var raw = List[UInt8](unsafe_uninit_length=h * (1 + w * channels))
    var rp = raw.unsafe_ptr()
    var o = 0
    for y in range(h):
        rp[unsafe_offset=o] = 0
        o += 1
        var row_start = y * w * BYTES_PER_PIXEL
        if has_alpha:
            var row_len = w * BYTES_PER_PIXEL
            var k = 0
            while k + _UNFILTER_W <= row_len:
                rp.unsafe_offset(o + k).unsafe_store(
                    px.unsafe_offset(row_start + k).unsafe_load[
                        width=_UNFILTER_W
                    ]()
                )
                k += _UNFILTER_W
            while k < row_len:
                rp[unsafe_offset=o + k] = px[unsafe_offset=row_start + k]
                k += 1
            o += row_len
        else:
            # Four bytes read, four written, three kept: the fourth is
            # the alpha, and the next pixel's store lands on it. The
            # last pixel of the row is done by hand, since its fourth
            # byte would be the next row's filter byte -- and on the
            # last row, past the buffer.
            for x in range(w - 1):
                rp.unsafe_offset(o).unsafe_store(
                    px.unsafe_offset(
                        row_start + x * BYTES_PER_PIXEL
                    ).unsafe_load[width=4]()
                )
                o += 3
            var last = row_start + (w - 1) * BYTES_PER_PIXEL
            rp[unsafe_offset=o] = px[unsafe_offset=last]
            rp[unsafe_offset=o + 1] = px[unsafe_offset=last + 1]
            rp[unsafe_offset=o + 2] = px[unsafe_offset=last + 2]
            o += 3

    # Choose unfiltered or Sub-filtered scanlines per image. Flat and
    # repeated rows favor unfiltered data; varying rows favor Sub.
    # Encoding levels may compare samples instead of both full images.
    var row_bytes = w * channels
    var max_chain = level._max_chain()
    var max_lazy = level._max_lazy()
    var stride = level._filter_sample_stride()
    if level._skips_filter_search() and _mostly_repeats_left(
        raw, h, row_bytes, channels
    ):
        # Flat enough that unfiltered rows win without asking, so
        # neither the Sub pass nor the sample compression happens at
        # all. This is where FAST's time goes.
        var only = deflate(raw, max_chain, max_lazy)
        _finish_png(file_buf^, crc_table, only^, _adler32(raw), path)
        return
    var sub = _sub_filtered(raw, h, row_bytes, channels)
    var filtered: Bool
    var compressed: List[UInt8]
    if stride == 0:
        # Both encodings in full rather than a sample, and the smaller
        # one kept.
        var sub_out = deflate(sub, max_chain, max_lazy)
        var raw_out = deflate(raw, max_chain, max_lazy)
        filtered = len(sub_out) < len(raw_out)
        compressed = sub_out^ if filtered else raw_out^
    else:
        # Judge the sample at the default search effort so encoding
        # level does not affect the filter choice.
        filtered = _sub_compresses_smaller(raw, sub, h, row_bytes, stride)
        compressed = deflate(sub, max_chain, max_lazy) if filtered else deflate(
            raw, max_chain, max_lazy
        )

    _finish_png(
        file_buf^,
        crc_table,
        compressed^,
        _adler32(sub) if filtered else _adler32(raw),
        path,
    )


def _read_u32_be(data: List[UInt8], pos: Int) raises -> Int:
    if pos + 4 > len(data):
        raise Error("png: truncated file (expected a 4-byte big-endian value)")
    return (
        (Int(data[pos]) << 24)
        | (Int(data[pos + 1]) << 16)
        | (Int(data[pos + 2]) << 8)
        | Int(data[pos + 3])
    )


# Rows between the ones the filter choice is made on; see `write_png`.
comptime _FILTER_SAMPLE_STRIDE = 8


# Rows sampled by `_mostly_repeats_left`, and the share of their bytes
# that must repeat their left neighbour for the filter choice to be
# settled without compressing anything.
comptime _FLATNESS_ROWS = 16
comptime _FLATNESS_SHARE = 0.5


def _mostly_repeats_left(
    raw: List[UInt8], height: Int, row_bytes: Int, bpp: Int
) -> Bool:
    """Whether enough of the image repeats the pixel to its left that
    unfiltered rows will win.

    Sub subtracts each byte from the one a pixel to its left, so where
    that byte is already identical Sub turns a run of one value into a
    run of zeros -- which deflate compresses about as well either way,
    while unfiltered rows also match the row above. Where the two
    differ, as in a gradient, the answer is genuinely in doubt and the
    caller has to compress a sample both ways to find out.

    So this is not a filter heuristic in the usual sense. It does not
    try to say which filter is better; it says whether the question is
    easy, and only `PngLevel.FAST` acts on it. libpng's byte-residual
    heuristic was tried in this position and answered "Sub" on every
    chart, where Sub loses.
    """
    if row_bytes <= bpp or height <= 0:
        return False
    var stride = 1 + row_bytes
    var step = max(height // _FLATNESS_ROWS, 1)
    var rp = raw.unsafe_ptr()
    var same = 0
    var total = 0
    var y = 0
    var sampled = 0
    while y < height and sampled < _FLATNESS_ROWS:
        var base = y * stride + 1
        for i in range(bpp, row_bytes):
            if rp[unsafe_offset=base + i] == rp[unsafe_offset=base + i - bpp]:
                same += 1
        total += row_bytes - bpp
        sampled += 1
        y += step
    return total > 0 and Float64(same) > Float64(total) * _FLATNESS_SHARE


def _sub_compresses_smaller(
    raw: List[UInt8],
    sub: List[UInt8],
    height: Int,
    row_bytes: Int,
    stride_rows: Int = _FILTER_SAMPLE_STRIDE,
    max_chain: Int = _DEFLATE_MAX_CHAIN,
    max_lazy: Int = _DEFLATE_MAX_LAZY,
) raises -> Bool:
    """Whether the Sub-filtered scanlines compress smaller than the
    unfiltered ones, decided on every `_FILTER_SAMPLE_STRIDE`th row of
    each: the same rows, deflated both ways. Ties keep the unfiltered
    rows, which decode with no reconstruction pass.
    """
    var stride = 1 + row_bytes
    var rows = (height + stride_rows - 1) // stride_rows
    var sample_raw = List[UInt8](unsafe_uninit_length=rows * stride)
    var sample_sub = List[UInt8](unsafe_uninit_length=rows * stride)
    var rp = raw.unsafe_ptr()
    var sp = sub.unsafe_ptr()
    var dr = sample_raw.unsafe_ptr()
    var ds = sample_sub.unsafe_ptr()
    var y = 0
    var o = 0
    while y < height:
        var base = y * stride
        var i = 0
        while i + _UNFILTER_W <= stride:
            dr.unsafe_offset(o + i).unsafe_store(
                rp.unsafe_offset(base + i).unsafe_load[width=_UNFILTER_W]()
            )
            ds.unsafe_offset(o + i).unsafe_store(
                sp.unsafe_offset(base + i).unsafe_load[width=_UNFILTER_W]()
            )
            i += _UNFILTER_W
        while i < stride:
            dr[unsafe_offset=o + i] = rp[unsafe_offset=base + i]
            ds[unsafe_offset=o + i] = sp[unsafe_offset=base + i]
            i += 1
        o += stride
        y += stride_rows
    return len(deflate(sample_sub, max_chain, max_lazy)) < len(
        deflate(sample_raw, max_chain, max_lazy)
    )


def _sub_filtered(
    raw: List[UInt8], height: Int, row_bytes: Int, bpp: Int
) -> List[UInt8]:
    """The scanlines in `raw` (filter byte + `row_bytes` of pixels per
    row, every filter byte 0) re-encoded under filter type 1, Sub: each
    byte replaced by its difference from the byte one pixel to its
    left, the first pixel of a row from zero (spec section 9.2). Same
    layout back, with every filter byte 1.

    Sub needs no row above, which is why it is the one filter worth a
    second pass: it reads `raw` once, sequentially.
    """
    var out = List[UInt8](unsafe_uninit_length=len(raw))
    var rp = raw.unsafe_ptr()
    var op = out.unsafe_ptr()
    var stride = 1 + row_bytes
    for y in range(height):
        var base = y * stride
        op[unsafe_offset=base] = 1
        var src = base + 1
        # The first pixel has nothing to its left, so it goes through
        # unchanged; the rest is a subtraction between two buffers,
        # which vectorizes once the `i >= bpp` test is out of the
        # loop. The wrap at 256 is the encoding the spec asks for.
        for i in range(bpp):
            op[unsafe_offset=src + i] = rp[unsafe_offset=src + i]
        var i = bpp
        while i + _UNFILTER_W <= row_bytes:
            op.unsafe_offset(src + i).unsafe_store(
                rp.unsafe_offset(src + i).unsafe_load[width=_UNFILTER_W]()
                - rp.unsafe_offset(src + i - bpp).unsafe_load[
                    width=_UNFILTER_W
                ]()
            )
            i += _UNFILTER_W
        while i < row_bytes:
            op[unsafe_offset=src + i] = (
                rp[unsafe_offset=src + i] - rp[unsafe_offset=src + i - bpp]
            )
            i += 1
    return out^


def _paeth_predictor(a: Int, b: Int, c: Int) -> Int:
    """PNG spec 9.4: whichever of the left (a), above (b), or
    upper-left (c) neighbor is closest to `a + b - c`, in that
    tie-breaking order, which the spec makes load-bearing.
    """
    var p = a + b - c
    var pa = abs(p - a)
    var pb = abs(p - b)
    var pc = abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    elif pb <= pc:
        return b
    else:
        return c


def _bytes_per_pixel(color_type: Int) raises -> Int:
    """Byte width per pixel at 8-bit depth, by color type. Indexed
    color (type 3) is one byte per pixel at 8 bits and packed below
    that; `decode_png` handles its row width itself.
    """
    if color_type == 0:
        return 1  # grayscale
    if color_type == 2:
        return 3  # truecolor (RGB)
    if color_type == 4:
        return 2  # grayscale + alpha
    if color_type == 6:
        return 4  # truecolor + alpha (RGBA)
    if color_type == 3:
        return 1  # a palette index
    raise Error(
        String(
            "png: unsupported color type ",
            color_type,
            " (only 0/2/3/4/6 are supported)",
        )
    )


def _channels(color_type: Int) raises -> Int:
    """Samples per pixel by color type, whatever the bit depth."""
    if color_type == 0:
        return 1  # grayscale
    if color_type == 2:
        return 3  # truecolor (RGB)
    if color_type == 3:
        return 1  # a palette index
    if color_type == 4:
        return 2  # grayscale + alpha
    if color_type == 6:
        return 4  # truecolor + alpha (RGBA)
    raise Error(
        String(
            "png: unsupported color type ",
            color_type,
            " (only 0/2/3/4/6 are supported)",
        )
    )


def _row_bytes(width: Int, color_type: Int, bit_depth: Int) raises -> Int:
    """Bytes one scanline of `width` pixels occupies, rounded up: a
    row of sub-byte samples is padded to a whole byte, never packed
    across the row boundary (spec section 7.2).
    """
    return (width * _channels(color_type) * bit_depth + 7) // 8


def _filter_bpp(color_type: Int, bit_depth: Int) raises -> Int:
    """The filters' `bpp`: bytes per complete pixel, rounded *down*
    but never below one (spec section 9.2). Sub-byte pixels therefore
    filter against the byte to their left, whole-byte ones against the
    sample of the same channel in the pixel to their left.
    """
    var bits = _channels(color_type) * bit_depth
    if bits < 8:
        return 1
    return bits // 8


# Bytes per step in the two filters that have no left-neighbour
# dependency. Wide enough to fill a vector register on anything
# current; a row shorter than this, or its tail, falls back to bytes.
comptime _UNFILTER_W = 32


def _unfilter_rows(
    raw: List[UInt8], row_bytes: Int, height: Int, bpp: Int, offset: Int = 0
) raises -> List[UInt8]:
    """Reverses PNG's per-scanline filtering (spec section 9). `raw` is
    `inflate`'s output from `offset` on: a filter-type byte plus
    `row_bytes` filtered bytes, repeated `height` times. An interlaced
    image passes the offset of each Adam7 pass, since the passes share
    one stream but filter independently. Each row reconstructs from the
    already-reconstructed row above it and its own already-
    reconstructed bytes to the left, the dependency order the spec's
    formulas assume. Bytes left of the first pixel, and the row above
    the first scanline, are zero per the spec.

    The output is sized up front and written by index: a row's
    "above" is the previous output row, and the first row reads its
    above from a zeroed row. One loop per filter type, since the type
    is fixed for a row and the loop over its bytes is the hot one.
    Every index is bounded by the row length checks and the `x >= bpp`
    guards, so the reads and writes go through pointers.
    """
    var out = List[UInt8](unsafe_uninit_length=height * row_bytes)
    var zero_row = List[UInt8](length=row_bytes, fill=0)
    var rp = raw.unsafe_ptr()
    var op = out.unsafe_ptr()
    var pos = offset
    for y in range(height):
        if pos >= len(raw):
            raise Error(
                "png: truncated scanline data (fewer rows than IHDR's own"
                " height)"
            )
        var filter_type = Int(raw[pos])
        pos += 1
        if pos + row_bytes > len(raw):
            raise Error("png: truncated scanline data (row cut short)")
        var cp = op.unsafe_offset(y * row_bytes)
        var pp = zero_row.unsafe_ptr() if y == 0 else op.unsafe_offset(
            (y - 1) * row_bytes
        )
        var fp = rp.unsafe_offset(pos)
        if filter_type == 0:
            # Nothing to reconstruct: the row is already its own
            # bytes. A byte-at-a-time loop is what the compiler is
            # left with, since it cannot know `raw` and `out` do not
            # overlap; copying a vector at a time says so.
            var x = 0
            while x + _UNFILTER_W <= row_bytes:
                cp.unsafe_offset(x).unsafe_store(
                    fp.unsafe_offset(x).unsafe_load[width=_UNFILTER_W]()
                )
                x += _UNFILTER_W
            while x < row_bytes:
                cp[unsafe_offset=x] = fp[unsafe_offset=x]
                x += 1
        elif filter_type == 1:
            for x in range(bpp):
                cp[unsafe_offset=x] = fp[unsafe_offset=x]
            for x in range(bpp, row_bytes):
                cp[unsafe_offset=x] = (
                    fp[unsafe_offset=x] + cp[unsafe_offset=x - bpp]
                )
        elif filter_type == 2:
            # Up: every byte depends only on the row above, never on
            # its own neighbours, so the whole row goes a vector at a
            # time. The adds wrap at 256, which is the reconstruction
            # the spec asks for.
            var x = 0
            while x + _UNFILTER_W <= row_bytes:
                cp.unsafe_offset(x).unsafe_store(
                    fp.unsafe_offset(x).unsafe_load[width=_UNFILTER_W]()
                    + pp.unsafe_offset(x).unsafe_load[width=_UNFILTER_W]()
                )
                x += _UNFILTER_W
            while x < row_bytes:
                cp[unsafe_offset=x] = fp[unsafe_offset=x] + pp[unsafe_offset=x]
                x += 1
        elif filter_type == 3:
            for x in range(bpp):
                cp[unsafe_offset=x] = UInt8(
                    (Int(fp[unsafe_offset=x]) + Int(pp[unsafe_offset=x]) // 2)
                    & 0xFF
                )
            for x in range(bpp, row_bytes):
                var a = Int(cp[unsafe_offset=x - bpp])
                var b = Int(pp[unsafe_offset=x])
                cp[unsafe_offset=x] = UInt8(
                    (Int(fp[unsafe_offset=x]) + (a + b) // 2) & 0xFF
                )
        elif filter_type == 4:
            for x in range(bpp):
                # Left and upper-left are zero, so the predictor is
                # the byte above.
                cp[unsafe_offset=x] = fp[unsafe_offset=x] + pp[unsafe_offset=x]
            for x in range(bpp, row_bytes):
                var a = Int(cp[unsafe_offset=x - bpp])
                var b = Int(pp[unsafe_offset=x])
                var c = Int(pp[unsafe_offset=x - bpp])
                cp[unsafe_offset=x] = UInt8(
                    (Int(fp[unsafe_offset=x]) + _paeth_predictor(a, b, c))
                    & 0xFF
                )
        else:
            raise Error(String("png: invalid filter type ", filter_type))
        pos += row_bytes
    return out^


def _canvas_from_scanlines(
    unfiltered: List[UInt8], width: Int, height: Int, color_type: Int
) raises -> Canvas:
    """Converts already-unfiltered scanline bytes into a Canvas.

    Builds the RGBA buffer directly and hands it to the
    `(width, height, pixels)` constructor rather than writing pixels into
    a blank canvas one at a time: a `write_pixel` walk would *composite*
    each pixel onto the canvas's initial background, losing alpha.
    Decoding a file is a replace, not a draw. The buffer is sized up
    front and written through pointers: `unfiltered` holds exactly
    `width * height * bpp` bytes, and every read below stays inside a
    pixel of it.
    """
    var bpp = _bytes_per_pixel(color_type)
    var n = width * height
    if len(unfiltered) < n * bpp:
        raise Error("png: scanline data shorter than the image")
    var pixels = List[UInt8](unsafe_uninit_length=n * BYTES_PER_PIXEL)
    var sp = unfiltered.unsafe_ptr()
    var dp = pixels.unsafe_ptr()
    if color_type == 6:
        # Already the canvas's own layout, so this is a copy. Taken a
        # vector at a time: the compiler cannot know the two buffers
        # do not overlap, and a byte loop is what it falls back to.
        var i = 0
        var total = n * BYTES_PER_PIXEL
        while i + _UNFILTER_W <= total:
            dp.unsafe_offset(i).unsafe_store(
                sp.unsafe_offset(i).unsafe_load[width=_UNFILTER_W]()
            )
            i += _UNFILTER_W
        while i < total:
            dp[unsafe_offset=i] = sp[unsafe_offset=i]
            i += 1
    elif color_type == 2:
        # Three source bytes become four. Reading four and overwriting
        # the fourth with the alpha turns a pixel into one load and
        # one store; the last pixel is done by hand, since reading
        # four bytes there would run one past the end.
        for i in range(n - 1):
            var v = sp.unsafe_offset(i * 3).unsafe_load[width=4]()
            v[3] = 255
            dp.unsafe_offset(i * BYTES_PER_PIXEL).unsafe_store(v)
        var last = n - 1
        var lp = last * 3
        var ld = last * BYTES_PER_PIXEL
        dp[unsafe_offset=ld] = sp[unsafe_offset=lp]
        dp[unsafe_offset=ld + 1] = sp[unsafe_offset=lp + 1]
        dp[unsafe_offset=ld + 2] = sp[unsafe_offset=lp + 2]
        dp[unsafe_offset=ld + 3] = 255
    elif color_type == 0:
        for i in range(n):
            var gray = sp[unsafe_offset=i]
            var v = SIMD[DType.uint8, 4](gray, gray, gray, 255)
            dp.unsafe_offset(i * BYTES_PER_PIXEL).unsafe_store(v)
    else:  # 4 -- _bytes_per_pixel already rejected anything else
        for i in range(n):
            var gray = sp[unsafe_offset=i * 2]
            var v = SIMD[DType.uint8, 4](
                gray, gray, gray, sp[unsafe_offset=i * 2 + 1]
            )
            dp.unsafe_offset(i * BYTES_PER_PIXEL).unsafe_store(v)
    return Canvas(width, height, pixels^)


def _canvas_from_scanlines16(
    unfiltered: List[UInt8],
    width: Int,
    height: Int,
    color_type: Int,
    trns: List[UInt8],
) raises -> Canvas:
    """16-bit samples to the Canvas's 8-bit RGBA. Each sample is two
    bytes, big-endian (spec section 7.1).

    The reduction is `round(v * 255 / 65535)`, written
    `(v + 128) // 257` -- exact, because 65535 is 255 * 257, so the
    scale is a division by 257 and adding half the divisor rounds it.
    Keeping the high byte instead is the other common choice and is
    not the same: it maps both 65535 and 65280 to 255 and sits up to
    half a level low across the rest of the range.

    `tRNS` is compared against the samples *before* they are reduced.
    Two 16-bit values one level apart reduce to the same 8-bit value
    and only one of them is the transparent color, so comparing after
    would punch holes in pixels the file meant to be opaque.
    """
    var ch = _channels(color_type)
    var n = width * height
    if len(unfiltered) < n * ch * 2:
        raise Error("png: scanline data shorter than the image")
    var pixels = List[UInt8](unsafe_uninit_length=n * BYTES_PER_PIXEL)
    var sp = unfiltered.unsafe_ptr()
    var dp = pixels.unsafe_ptr()
    var keyed = len(trns) > 0 and (color_type == 0 or color_type == 2)
    var key_r = -1
    var key_g = -1
    var key_b = -1
    if keyed:
        if color_type == 0:
            if len(trns) < 2:
                raise Error("png: tRNS chunk too short for grayscale")
            key_r = (Int(trns[0]) << 8) | Int(trns[1])
            key_g = key_r
            key_b = key_r
        else:
            if len(trns) < 6:
                raise Error("png: tRNS chunk too short for truecolor")
            key_r = (Int(trns[0]) << 8) | Int(trns[1])
            key_g = (Int(trns[2]) << 8) | Int(trns[3])
            key_b = (Int(trns[4]) << 8) | Int(trns[5])
    for i in range(n):
        # Bounded by the length check above: `base` runs to
        # (n - 1) * ch * 2 and each read stays inside that pixel.
        var base = i * ch * 2
        var first = (Int(sp[unsafe_offset=base]) << 8) | Int(
            sp[unsafe_offset=base + 1]
        )
        var r16 = first
        var g16 = first
        var b16 = first
        var a16 = 65535
        if color_type == 2 or color_type == 6:
            g16 = (Int(sp[unsafe_offset=base + 2]) << 8) | Int(
                sp[unsafe_offset=base + 3]
            )
            b16 = (Int(sp[unsafe_offset=base + 4]) << 8) | Int(
                sp[unsafe_offset=base + 5]
            )
            if color_type == 6:
                a16 = (Int(sp[unsafe_offset=base + 6]) << 8) | Int(
                    sp[unsafe_offset=base + 7]
                )
        elif color_type == 4:
            a16 = (Int(sp[unsafe_offset=base + 2]) << 8) | Int(
                sp[unsafe_offset=base + 3]
            )
        if keyed and r16 == key_r and g16 == key_g and b16 == key_b:
            a16 = 0
        var d = i * BYTES_PER_PIXEL
        dp[unsafe_offset=d] = UInt8((r16 + 128) // 257)
        dp[unsafe_offset=d + 1] = UInt8((g16 + 128) // 257)
        dp[unsafe_offset=d + 2] = UInt8((b16 + 128) // 257)
        dp[unsafe_offset=d + 3] = UInt8((a16 + 128) // 257)
    return Canvas(width, height, pixels^)


def _apply_trns8(mut canvas: Canvas, color_type: Int, trns: List[UInt8]) raises:
    """Zero the alpha of every pixel matching `tRNS`'s color key, for
    8-bit grayscale and truecolor.

    Run over the finished RGBA rather than folded into the conversion,
    so the vectorized path above stays as it is. It is exact at this
    depth: the bytes compared are the file's own samples, copied
    through unchanged. The key is stored as 16-bit samples whatever
    the depth (spec section 11.3.2), so only the low byte of each
    carries the 8-bit value.
    """
    var need = 2 if color_type == 0 else 6
    if len(trns) < need:
        raise Error("png: tRNS chunk too short for the color type")
    var key_r = trns[1]
    var key_g = trns[1] if color_type == 0 else trns[3]
    var key_b = trns[1] if color_type == 0 else trns[5]
    var n = canvas.width * canvas.height
    var p = canvas.pixels.unsafe_ptr()
    for i in range(n):
        var d = i * BYTES_PER_PIXEL
        if (
            p[unsafe_offset=d] == key_r
            and p[unsafe_offset=d + 1] == key_g
            and p[unsafe_offset=d + 2] == key_b
        ):
            p[unsafe_offset=d + 3] = 0


def _rows_to_canvas(
    unfiltered: List[UInt8],
    width: Int,
    height: Int,
    color_type: Int,
    bit_depth: Int,
    palette: List[UInt8],
    trns: List[UInt8],
) raises -> Canvas:
    """One rectangle of already-unfiltered rows to a Canvas, by color
    type and depth. The whole image for a non-interlaced file, one
    Adam7 pass for an interlaced one -- the two differ in how the rows
    are found, not in what the samples mean.
    """
    if color_type == 3:
        var row_bytes = _row_bytes(width, color_type, bit_depth)
        return _canvas_from_indexed(
            unfiltered, row_bytes, width, height, bit_depth, palette, trns
        )
    if bit_depth == 16:
        return _canvas_from_scanlines16(
            unfiltered, width, height, color_type, trns
        )
    var canvas = _canvas_from_scanlines(unfiltered, width, height, color_type)
    if len(trns) > 0 and (color_type == 0 or color_type == 2):
        _apply_trns8(canvas, color_type, trns)
    return canvas^


def _deinterlace_adam7(
    raw: List[UInt8],
    width: Int,
    height: Int,
    color_type: Int,
    bit_depth: Int,
    palette: List[UInt8],
    trns: List[UInt8],
) raises -> Canvas:
    """Adam7 (spec section 8.2): seven passes, each a subsampled grid
    with its own origin and stride, concatenated in one stream.

    A pass filters against its *own* neighbours, not the final image's,
    so each is unfiltered separately with the row geometry its own
    width gives it -- which is why `_unfilter_rows` takes an offset
    rather than the stream being split up front. A pass whose width or
    height rounds to zero contributes no bytes at all and is skipped;
    that is the usual case for the later passes of a tiny image, and
    reading a filter byte for one would desynchronize everything after
    it.

    The output starts zeroed so that a pixel no pass reaches stays
    transparent black. Every pixel of the image is covered by exactly
    one pass, so nothing is written twice.
    """
    var xstart: List[Int] = [0, 4, 0, 2, 0, 1, 0]
    var ystart: List[Int] = [0, 0, 4, 0, 2, 0, 1]
    var xstep: List[Int] = [8, 8, 4, 4, 2, 2, 1]
    var ystep: List[Int] = [8, 8, 8, 4, 4, 2, 2]
    var pixels = List[UInt8](length=width * height * BYTES_PER_PIXEL, fill=0)
    var dp = pixels.unsafe_ptr()
    var filter_bpp = _filter_bpp(color_type, bit_depth)
    var pos = 0
    for p in range(7):
        var x0 = xstart[p]
        var y0 = ystart[p]
        var dx = xstep[p]
        var dy = ystep[p]
        var pw = 0
        if width > x0:
            pw = (width - x0 + dx - 1) // dx
        var ph = 0
        if height > y0:
            ph = (height - y0 + dy - 1) // dy
        if pw == 0 or ph == 0:
            continue
        var row_bytes = _row_bytes(pw, color_type, bit_depth)
        var consumed = ph * (row_bytes + 1)
        if pos + consumed > len(raw):
            raise Error(
                String(
                    "png: truncated Adam7 stream -- pass ",
                    p + 1,
                    " of 7 needs ",
                    consumed,
                    " more bytes",
                )
            )
        var unfiltered = _unfilter_rows(raw, row_bytes, ph, filter_bpp, pos)
        pos += consumed
        var sub = _rows_to_canvas(
            unfiltered, pw, ph, color_type, bit_depth, palette, trns
        )
        var subp = sub.pixels.unsafe_ptr()
        for y in range(ph):
            var dest_row = (y0 + y * dy) * width
            var src_row = y * pw
            for x in range(pw):
                var s = (src_row + x) * BYTES_PER_PIXEL
                var d = (dest_row + x0 + x * dx) * BYTES_PER_PIXEL
                dp.unsafe_offset(d).unsafe_store(
                    subp.unsafe_offset(s).unsafe_load[width=BYTES_PER_PIXEL]()
                )
    return Canvas(width, height, pixels^)


def read_png(path: String) raises -> Canvas:
    """Read a PNG file into a Canvas. Handles 8-bit depth, color types
    0/2/4/6 at 8 or 16 bits, interlaced or not; anything else raises
    (see this module's
    docstring).

    Every chunk's CRC-32 is checked against its trailing 4 bytes, and
    the decompressed data's Adler-32 against the zlib stream's, so a
    corrupted or truncated file is rejected rather than misdecoded.

    Args:
        path: File path to read.

    Returns:
        The decoded image as a Canvas, with any alpha channel preserved
        per pixel.

    Raises:
        Error: `path` can't be read, isn't a valid PNG, uses an
            unsupported color type/bit depth/interlacing, or fails a
            checksum.
    """
    var f = open(path, "r")
    var data = f.read_bytes()
    f.close()
    return decode_png(data^)


def decode_png(var data: List[UInt8]) raises -> Canvas:
    """Decode a PNG image held in memory into a Canvas: `read_png`
    after the file is read, for bytes that come from somewhere else,
    such as a font's embedded bitmaps. Same scope and errors.

    Args:
        data: The complete PNG file contents.

    Returns:
        The decoded image as an RGBA canvas.

    Raises:
        Error: Not a PNG, a corrupted chunk, or an unsupported
            feature (see the module docstring).
    """
    var signature: List[UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    if len(data) < 8:
        raise Error("png: file too short to contain a PNG signature")
    for i in range(8):
        if data[i] != signature[i]:
            raise Error("png: missing PNG signature -- not a PNG file")

    var crc_table = _crc32_table()

    var width = 0
    var height = 0
    var color_type = -1
    var bit_depth = 8
    var interlaced = False
    var have_ihdr = False
    var idat = List[UInt8]()
    var palette = List[UInt8]()
    var trns = List[UInt8]()
    var seen_iend = False

    var pos = 8
    while not seen_iend:
        var length = _read_u32_be(data, pos)
        pos += 4
        if pos + 4 > len(data):
            raise Error("png: truncated chunk header")
        var chunk_type = String()
        for i in range(4):
            chunk_type += chr(Int(data[pos + i]))
        var type_start = pos
        pos += 4

        if pos + length + 4 > len(data):
            raise Error(String("png: truncated '", chunk_type, "' chunk data"))

        # The CRC covers type + data, which sit together in the file,
        # so it is checked over a view of `data` rather than a copy.
        var expected_crc = _read_u32_be(data, pos + length)
        var actual_crc = Int(
            _crc32(Span(data)[type_start : pos + length], crc_table)
        )
        if actual_crc != expected_crc:
            raise Error(
                String(
                    "png: CRC-32 mismatch in '",
                    chunk_type,
                    "' chunk -- corrupted file",
                )
            )

        if chunk_type == "IHDR":
            if length != 13:
                raise Error("png: malformed IHDR chunk")
            width = _read_u32_be(data, pos)
            height = _read_u32_be(data, pos + 4)
            bit_depth = Int(data[pos + 8])
            color_type = Int(data[pos + 9])
            var compression_method = Int(data[pos + 10])
            var filter_method = Int(data[pos + 11])
            var interlace_method = Int(data[pos + 12])
            if compression_method != 0:
                raise Error(
                    "png: unsupported compression method (only method 0/deflate"
                    " is supported)"
                )
            if filter_method != 0:
                raise Error(
                    "png: unsupported filter method (only method 0 is"
                    " supported)"
                )
            if interlace_method != 0 and interlace_method != 1:
                raise Error(
                    String(
                        "png: unknown interlace method ",
                        interlace_method,
                        " (the spec defines only 0/none and 1/Adam7)",
                    )
                )
            interlaced = interlace_method == 1
            var packed_ok = color_type == 3 and (
                bit_depth == 1 or bit_depth == 2 or bit_depth == 4
            )
            # 16 bits is defined for every color type but indexed,
            # whose samples are palette indices.
            var deep_ok = bit_depth == 16 and color_type != 3
            if bit_depth != 8 and not packed_ok and not deep_ok:
                raise Error(
                    String(
                        "png: unsupported bit depth ",
                        bit_depth,
                        " for color type ",
                        color_type,
                        " (8-bit for any type, 16-bit for any but indexed,",
                        " 1/2/4-bit for indexed)",
                    )
                )
            if width <= 0 or height <= 0:
                raise Error("png: invalid image dimensions")
            have_ihdr = True
        elif chunk_type == "IDAT":
            if not have_ihdr:
                raise Error("png: IDAT chunk before IHDR")
            idat.extend(data[pos : pos + length])
        elif chunk_type == "PLTE":
            palette.extend(data[pos : pos + length])
        elif chunk_type == "tRNS":
            trns.extend(data[pos : pos + length])
        elif chunk_type == "IEND":
            seen_iend = True
        # Any other chunk type (PLTE, or ancillary ones like
        # tEXt/pHYs/gAMA) is skipped: no supported color type needs
        # them, and palette color is out of scope, so PLTE never
        # matters here.

        pos += length + 4

    if not have_ihdr:
        raise Error("png: missing IHDR chunk")
    if len(idat) == 0:
        raise Error("png: missing IDAT data")

    # Strip the zlib wrapper (RFC 1950): 2-byte header, N bytes of raw
    # DEFLATE data, 4-byte Adler-32 trailer.
    if len(idat) < 6:
        raise Error("png: IDAT data too short to be a valid zlib stream")
    var deflate_data = List[UInt8](capacity=len(idat) - 6)
    deflate_data.extend(idat[2 : len(idat) - 4])
    var expected_adler = _read_u32_be(idat, len(idat) - 4)

    var raw = inflate(deflate_data^)

    var actual_adler = Int(_adler32(raw))
    if actual_adler != expected_adler:
        raise Error(
            "png: Adler-32 mismatch after decompression -- corrupted file"
        )

    if color_type == 3 and len(palette) < 3:
        raise Error("png: indexed color without a PLTE chunk")
    if interlaced:
        return _deinterlace_adam7(
            raw, width, height, color_type, bit_depth, palette, trns
        )
    var row_bytes = _row_bytes(width, color_type, bit_depth)
    var unfiltered = _unfilter_rows(
        raw, row_bytes, height, _filter_bpp(color_type, bit_depth)
    )
    return _rows_to_canvas(
        unfiltered, width, height, color_type, bit_depth, palette, trns
    )


def _canvas_from_indexed(
    unfiltered: List[UInt8],
    row_bytes: Int,
    width: Int,
    height: Int,
    bit_depth: Int,
    palette: List[UInt8],
    trns: List[UInt8],
) raises -> Canvas:
    """Indexed-color rows to RGBA: each pixel's `bit_depth`-bit index
    (packed most-significant first at 1/2/4 bits) selects a `PLTE`
    entry, and its alpha is the matching `tRNS` entry, 255 past the
    end of `tRNS` or without one.
    """
    var entries = len(palette) // 3
    var per_byte = 8 // bit_depth
    var mask = (1 << bit_depth) - 1
    var pixels = List[UInt8](capacity=width * height * BYTES_PER_PIXEL)
    for y in range(height):
        var row = y * row_bytes
        for x in range(width):
            var byte = Int(unfiltered[row + x // per_byte])
            var shift = 8 - bit_depth * (x % per_byte + 1)
            var index = (byte >> shift) & mask
            if index >= entries:
                raise Error("png: palette index past the PLTE table")
            pixels.append(palette[index * 3])
            pixels.append(palette[index * 3 + 1])
            pixels.append(palette[index * 3 + 2])
            pixels.append(trns[index] if index < len(trns) else UInt8(255))
    return Canvas(width, height, pixels^)
