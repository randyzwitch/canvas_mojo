"""Read and write PNG files, stdlib-only, with no zlib/libpng
dependency -- this package's approach to every binary format it handles
(BMP here, TrueType/sfnt in `canvas/text/ttf.mojo`).

PNG's image data is wrapped in a zlib stream (RFC 1950) around a
DEFLATE stream (RFC 1951). Both directions go through
`canvas/io/deflate.mojo`: `write_png` compresses through its LZ77
+ fixed-Huffman `deflate()`, `read_png` decompresses through
`inflate()`, which has to handle whatever a real encoder produced.

Two checksums, hand-rolled from their public specs (PNG spec Appendix D
for CRC-32, RFC 1950 section 9 for Adler-32) and verified against
zlib's `crc32`/`adler32` on the same byte sequences. `read_png` checks
both against every file it reads -- chunk CRC-32s, and the decompressed
data's Adler-32 against the zlib trailer -- rather than trusting that
decoding produced *some* output.

Two byte orders are in play, which is a classic place to go wrong:
PNG's chunk framing (length, CRC-32) and the zlib Adler-32 trailer are
big-endian, but DEFLATE's stored-block LEN/NLEN fields are
little-endian.

`write_png` emits color type 6 (truecolor + alpha) when the canvas
contains a pixel that is not fully opaque, and color type 2 (truecolor,
no alpha) when it does not, so a render that never used transparency
carries no alpha channel in the file.

`read_png` accepts color types 0/2/4/6 (grayscale, truecolor,
grayscale+alpha, truecolor+alpha) at 8-bit depth, non-interlaced.
Indexed/palette color (type 3), other bit depths, and Adam7 interlacing
raise a clear error rather than misreading pixels.

A PNG's alpha channel is kept: `Canvas` stores per-pixel alpha (see
buffer.mojo), so `read_png` writes each pixel's alpha straight through
instead of compositing it away onto white, and a file round-trips
through `read_png` -> `write_png` unchanged.
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


def _crc32(data: List[UInt8], table: List[UInt32]) -> UInt32:
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

    Bytes are read through `unsafe_ptr` because the loop bound is
    `len(data)` itself, so the index cannot leave the buffer, and a
    checked read costs several times what the arithmetic does at this
    size -- this runs over every raw byte of the image.
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

    var crc = _crc32(type_and_data, table)
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

    # One pass to decide the colour type. `has_alpha` is false for the
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

    # Raw scanlines: a filter-type byte, then that row's pixel bytes.
    # Filter type 0 (None, no per-pixel prediction) because deflate()'s
    # LZ77 already finds the horizontal-run redundancy a predictor
    # targets, and these images are dominated by flat-color regions.
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

    var zlib_stream = List[UInt8]()
    # zlib header (RFC 1950 2.2): CMF=0x78 (deflate, 32K window),
    # FLG=0x01 (FLEVEL=0/"fastest", matching deflate()'s single-block,
    # bounded-search scope). (0x78*256 + 0x01) % 31 == 0, the header's
    # required self-check.
    zlib_stream.append(0x78)
    zlib_stream.append(0x01)
    var compressed = deflate(raw)
    zlib_stream.extend(compressed^)
    _append_u32_be(zlib_stream, _adler32(raw))

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
    """Byte width per pixel at 8-bit depth, by color type. `read_png`
    accepts 0/2/4/6; type 3 (indexed/palette) is out of scope.
    """
    if color_type == 0:
        return 1  # grayscale
    if color_type == 2:
        return 3  # truecolor (RGB)
    if color_type == 4:
        return 2  # grayscale + alpha
    if color_type == 6:
        return 4  # truecolor + alpha (RGBA)
    raise Error(
        String(
            "png: unsupported color type ",
            color_type,
            " (only 0/2/4/6 at 8-bit depth are supported)",
        )
    )


def _unfilter_scanlines(
    raw: List[UInt8], width: Int, height: Int, bpp: Int
) raises -> List[UInt8]:
    """Reverses PNG's per-scanline filtering (spec section 9). `raw` is
    `inflate`'s output: a filter-type byte plus `width * bpp` filtered
    bytes, repeated `height` times. Each row reconstructs from the
    already-reconstructed row above it and its own already-
    reconstructed bytes to the left, the dependency order the spec's
    formulas assume. Bytes left of the first pixel, and the row above
    the first scanline, are zero per the spec -- no special case
    needed, since `a`/`c` default to 0 when `x < bpp` and `prev_row`
    starts zeroed.
    """
    var row_bytes = width * bpp
    var out = List[UInt8](capacity=height * row_bytes)
    # Both row buffers are sized up front and written by index, never
    # appended to. That matters because the unfilter loop below holds
    # raw pointers into them: appending can reallocate, which would
    # move the buffer and leave those pointers dangling. Sizing them
    # here makes that impossible rather than merely unlikely, and
    # reuses them across scanlines instead of allocating per row.
    var prev_row = List[UInt8](capacity=row_bytes)
    var cur_row = List[UInt8](capacity=row_bytes)
    for _ in range(row_bytes):
        prev_row.append(0)
        cur_row.append(0)

    var pos = 0
    for _ in range(height):
        if pos >= len(raw):
            raise Error(
                "png: truncated scanline data (fewer rows than IHDR's own"
                " height)"
            )
        var filter_type = Int(raw[pos])
        pos += 1
        if pos + row_bytes > len(raw):
            raise Error("png: truncated scanline data (row cut short)")

        # Four reads per byte of the image, all at indices the loop
        # bounds already constrain: `pos + x` stays inside `raw`
        # because the row was length-checked just above, and the
        # `x >= bpp` guards keep the back-references inside the two row
        # buffers, which are `row_bytes` long by construction.
        var rp = raw.unsafe_ptr()
        var cp = cur_row.unsafe_ptr()
        var pp = prev_row.unsafe_ptr()
        for x in range(row_bytes):
            var filt_x = Int(rp[unsafe_offset=pos + x])
            var a = Int(cp[unsafe_offset=x - bpp]) if x >= bpp else 0
            var b = Int(pp[unsafe_offset=x])
            var c = Int(pp[unsafe_offset=x - bpp]) if x >= bpp else 0

            var recon: Int
            if filter_type == 0:
                recon = filt_x
            elif filter_type == 1:
                recon = filt_x + a
            elif filter_type == 2:
                recon = filt_x + b
            elif filter_type == 3:
                recon = filt_x + (a + b) // 2
            elif filter_type == 4:
                recon = filt_x + _paeth_predictor(a, b, c)
            else:
                raise Error(String("png: invalid filter type ", filter_type))
            cp[unsafe_offset=x] = UInt8(recon & 0xFF)

        pos += row_bytes
        # A copy, not a move: cur_row becomes prev_row just below, so
        # `out` needs its own bytes. One bulk .copy(), not a per-byte
        # append loop.
        out.extend(cur_row.copy())
        # Swap roles rather than move: both buffers must stay alive and
        # allocated for the next row, since the pointers above are
        # taken fresh each iteration but the storage is reused.
        var spare = prev_row^
        prev_row = cur_row^
        cur_row = spare^

    return out^


def _canvas_from_scanlines(
    unfiltered: List[UInt8], width: Int, height: Int, color_type: Int
) raises -> Canvas:
    """Converts already-unfiltered scanline bytes into a Canvas.

    Builds the RGBA buffer directly and hands it to the
    `(width, height, pixels)` constructor rather than writing pixels into
    a blank canvas one at a time: a `write_pixel` walk would *composite*
    each pixel onto the canvas's initial background, losing alpha.
    Decoding a file is a replace, not a draw.
    """
    var bpp = _bytes_per_pixel(color_type)
    var row_bytes = width * bpp
    var pixels = List[UInt8](capacity=width * height * BYTES_PER_PIXEL)
    for y in range(height):
        var row_start = y * row_bytes
        for x in range(width):
            var px = row_start + x * bpp
            if color_type == 0:
                var gray = unfiltered[px]
                pixels.append(gray)
                pixels.append(gray)
                pixels.append(gray)
                pixels.append(255)
            elif color_type == 2:
                pixels.append(unfiltered[px])
                pixels.append(unfiltered[px + 1])
                pixels.append(unfiltered[px + 2])
                pixels.append(255)
            elif color_type == 4:
                var gray = unfiltered[px]
                pixels.append(gray)
                pixels.append(gray)
                pixels.append(gray)
                pixels.append(unfiltered[px + 1])
            else:  # 6 -- _bytes_per_pixel already rejected anything else
                pixels.append(unfiltered[px])
                pixels.append(unfiltered[px + 1])
                pixels.append(unfiltered[px + 2])
                pixels.append(unfiltered[px + 3])
    return Canvas(width, height, pixels^)


def read_png(path: String) raises -> Canvas:
    """Read a PNG file into a Canvas. Handles 8-bit depth, color types
    0/2/4/6, non-interlaced; anything else raises (see this module's
    docstring).

    Every chunk's CRC-32 is checked against its trailing 4 bytes, and
    the decompressed data's Adler-32 against the zlib stream's, so a
    corrupted or truncated file is rejected rather than misdecoded into
    a plausible-looking wrong image.

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
    var have_ihdr = False
    var idat = List[UInt8]()
    var seen_iend = False

    var pos = 8
    while not seen_iend:
        var length = _read_u32_be(data, pos)
        pos += 4
        if pos + 4 > len(data):
            raise Error("png: truncated chunk header")
        var type_bytes = List[UInt8](capacity=4)
        for i in range(4):
            type_bytes.append(data[pos + i])
        var chunk_type = String()
        for b in type_bytes:
            chunk_type += chr(Int(b))
        pos += 4

        if pos + length + 4 > len(data):
            raise Error(String("png: truncated '", chunk_type, "' chunk data"))

        var type_and_data = List[UInt8](capacity=4 + length)
        for b in type_bytes:
            type_and_data.append(b)
        for i in range(length):
            type_and_data.append(data[pos + i])

        var expected_crc = _read_u32_be(data, pos + length)
        var actual_crc = Int(_crc32(type_and_data, crc_table))
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
            var bit_depth = Int(data[pos + 8])
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
            if bit_depth != 8:
                raise Error(
                    String(
                        "png: unsupported bit depth ",
                        bit_depth,
                        " (only 8-bit depth is supported)",
                    )
                )
            if width <= 0 or height <= 0:
                raise Error("png: invalid image dimensions")
            have_ihdr = True
        elif chunk_type == "IDAT":
            if not have_ihdr:
                raise Error("png: IDAT chunk before IHDR")
            for i in range(length):
                idat.append(data[pos + i])
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
    for i in range(2, len(idat) - 4):
        deflate_data.append(idat[i])
    var expected_adler = _read_u32_be(idat, len(idat) - 4)

    var raw = inflate(deflate_data^)

    var actual_adler = Int(_adler32(raw))
    if actual_adler != expected_adler:
        raise Error(
            "png: Adler-32 mismatch after decompression -- corrupted file"
        )

    var bpp = _bytes_per_pixel(color_type)
    var unfiltered = _unfilter_scanlines(raw, width, height, bpp)
    return _canvas_from_scanlines(unfiltered, width, height, color_type)
