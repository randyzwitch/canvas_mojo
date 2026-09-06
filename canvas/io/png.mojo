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
It compresses the scanlines twice, unfiltered and Sub-filtered (spec
section 9), and keeps the smaller stream.
`read_png` accepts color types 0/2/4/6 at 8-bit depth and indexed
color (type 3, `PLTE` with an optional `tRNS`) at 1/2/4/8 bits,
non-interlaced; other bit depths and Adam7 interlacing
raise rather than misreading pixels. Alpha is preserved in both
directions, so a file round-trips through `read_png` -> `write_png`
unchanged.
"""

from canvas.buffer import Canvas, BYTES_PER_PIXEL
from canvas.color import Color
from canvas.io.deflate import deflate, inflate


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


def _adler32(data: List[UInt8]) -> UInt32:
    """RFC 1950's checksum for the zlib stream trailer: a running sum,
    not a table-driven algorithm.

    The modulo is deferred rather than taken per byte. `% BASE` is a
    ring homomorphism for addition, so reducing once at the end of a
    block gives the same value as reducing every step, provided the
    accumulators cannot overflow in between. NMAX is the standard bound
    for that in 32 bits: the largest n with
    255*n*(n+1)/2 + (n+1)*(BASE-1) < 2^32, so a block of that length
    cannot carry s2 past the end of the type.
    """
    comptime BASE = UInt32(65521)
    comptime NMAX = 5552
    var s1 = UInt32(1)
    var s2 = UInt32(0)
    var n = len(data)
    var p = data.unsafe_ptr()
    var i = 0
    while i < n:
        var block = NMAX
        if n - i < block:
            block = n - i
        for j in range(i, i + block):
            s1 += UInt32(p[unsafe_offset=j])
            s2 += s1
        s1 %= BASE
        s2 %= BASE
        i += block
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


def write_png(canvas: Canvas, path: String) raises:
    """Write `canvas` to `path` as an 8-bit, non-interlaced PNG --
    color type 6 (truecolor + alpha) if any pixel is not fully opaque,
    color type 2 (truecolor) otherwise.

    Args:
        canvas: Canvas to write.
        path: File path to write to.

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
    var raw = List[UInt8](capacity=h * (1 + w * channels))
    for y in range(h):
        raw.append(0)
        var row_start = y * w * BYTES_PER_PIXEL
        if has_alpha:
            raw.extend(
                canvas.pixels[row_start : row_start + w * BYTES_PER_PIXEL]
            )
        else:
            for x in range(w):
                var i = row_start + x * BYTES_PER_PIXEL
                raw.append(px[unsafe_offset=i])
                raw.append(px[unsafe_offset=i + 1])
                raw.append(px[unsafe_offset=i + 2])

    # Two candidate encodings, both compressed, the smaller kept. The
    # unfiltered rows win wherever deflate's LZ77 finds flat color
    # and repeated rows, which is most of a chart; the Sub-filtered
    # rows win on a gradient, whose steady ramps become runs of one
    # small delta. Measured over this package's own examples: Sub
    # takes 30% off the gradient and loses on everything else, so the
    # choice has to be per image (#167, which has the table). Up,
    # Average, Paeth and a per-row adaptive pick were measured too and
    # won nothing Sub did not, so they are not candidates.
    var compressed = deflate(raw)
    var sub = _sub_filtered(raw, h, w * channels, channels)
    var compressed_sub = deflate(sub)
    var filtered = len(compressed_sub) < len(compressed)
    if filtered:
        compressed = compressed_sub^

    var zlib_stream = List[UInt8]()
    # zlib header (RFC 1950 2.2): CMF=0x78 (deflate, 32K window),
    # FLG=0x01 (FLEVEL=0/"fastest", matching deflate()'s single-block,
    # bounded-search scope). (0x78*256 + 0x01) % 31 == 0, the header's
    # required self-check.
    zlib_stream.append(0x78)
    zlib_stream.append(0x01)
    zlib_stream.extend(compressed^)
    _append_u32_be(zlib_stream, _adler32(sub) if filtered else _adler32(raw))

    _write_chunk(file_buf, crc_table, "IDAT", zlib_stream)
    _write_chunk(file_buf, crc_table, "IEND", List[UInt8]())

    var f = open(path, "w")
    f.write_bytes(Span(file_buf))
    f.close()


def _read_u32_be(data: List[UInt8], pos: Int) raises -> Int:
    if pos + 4 > len(data):
        raise Error("png: truncated file (expected a 4-byte big-endian value)")
    return (
        (Int(data[pos]) << 24)
        | (Int(data[pos + 1]) << 16)
        | (Int(data[pos + 2]) << 8)
        | Int(data[pos + 3])
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
    var out = List[UInt8](length=len(raw), fill=0)
    var rp = raw.unsafe_ptr()
    var op = out.unsafe_ptr()
    var stride = 1 + row_bytes
    for y in range(height):
        var base = y * stride
        op[unsafe_offset=base] = 1
        for i in range(row_bytes):
            var cur = Int(rp[unsafe_offset=base + 1 + i])
            var left = 0
            if i >= bpp:
                left = Int(rp[unsafe_offset=base + 1 + i - bpp])
            op[unsafe_offset=base + 1 + i] = UInt8((cur - left) & 0xFF)
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


def _unfilter_scanlines(
    raw: List[UInt8], width: Int, height: Int, bpp: Int
) raises -> List[UInt8]:
    """`_unfilter_rows` for rows of `width` whole-byte pixels."""
    return _unfilter_rows(raw, width * bpp, height, bpp)


def _unfilter_rows(
    raw: List[UInt8], row_bytes: Int, height: Int, bpp: Int
) raises -> List[UInt8]:
    """Reverses PNG's per-scanline filtering (spec section 9). `raw` is
    `inflate`'s output: a filter-type byte plus `width * bpp` filtered
    bytes, repeated `height` times. Each row reconstructs from the
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
    var pos = 0
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
            for x in range(row_bytes):
                cp[unsafe_offset=x] = fp[unsafe_offset=x]
        elif filter_type == 1:
            for x in range(bpp):
                cp[unsafe_offset=x] = fp[unsafe_offset=x]
            for x in range(bpp, row_bytes):
                cp[unsafe_offset=x] = (
                    fp[unsafe_offset=x] + cp[unsafe_offset=x - bpp]
                )
        elif filter_type == 2:
            for x in range(row_bytes):
                cp[unsafe_offset=x] = fp[unsafe_offset=x] + pp[unsafe_offset=x]
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
        for i in range(n * BYTES_PER_PIXEL):
            dp[unsafe_offset=i] = sp[unsafe_offset=i]
    elif color_type == 2:
        for i in range(n):
            var px = i * 3
            var d = i * BYTES_PER_PIXEL
            dp[unsafe_offset=d] = sp[unsafe_offset=px]
            dp[unsafe_offset=d + 1] = sp[unsafe_offset=px + 1]
            dp[unsafe_offset=d + 2] = sp[unsafe_offset=px + 2]
            dp[unsafe_offset=d + 3] = 255
    elif color_type == 0:
        for i in range(n):
            var gray = sp[unsafe_offset=i]
            var d = i * BYTES_PER_PIXEL
            dp[unsafe_offset=d] = gray
            dp[unsafe_offset=d + 1] = gray
            dp[unsafe_offset=d + 2] = gray
            dp[unsafe_offset=d + 3] = 255
    else:  # 4 -- _bytes_per_pixel already rejected anything else
        for i in range(n):
            var gray = sp[unsafe_offset=i * 2]
            var d = i * BYTES_PER_PIXEL
            dp[unsafe_offset=d] = gray
            dp[unsafe_offset=d + 1] = gray
            dp[unsafe_offset=d + 2] = gray
            dp[unsafe_offset=d + 3] = sp[unsafe_offset=i * 2 + 1]
    return Canvas(width, height, pixels^)


def read_png(path: String) raises -> Canvas:
    """Read a PNG file into a Canvas. Handles 8-bit depth, color types
    0/2/4/6, non-interlaced; anything else raises (see this module's
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
            if interlace_method != 0:
                raise Error("png: Adam7 interlacing is not supported")
            var packed_ok = color_type == 3 and (
                bit_depth == 1 or bit_depth == 2 or bit_depth == 4
            )
            if bit_depth != 8 and not packed_ok:
                raise Error(
                    String(
                        "png: unsupported bit depth ",
                        bit_depth,
                        " (8-bit, or 1/2/4-bit indexed color)",
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

    var bpp = _bytes_per_pixel(color_type)
    if color_type == 3:
        if len(palette) < 3:
            raise Error("png: indexed color without a PLTE chunk")
        var row_bytes = (width * bit_depth + 7) // 8
        var unfiltered = _unfilter_rows(raw, row_bytes, height, 1)
        return _canvas_from_indexed(
            unfiltered, row_bytes, width, height, bit_depth, palette, trns
        )
    var unfiltered = _unfilter_scanlines(raw, width, height, bpp)
    return _canvas_from_scanlines(unfiltered, width, height, color_type)


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
