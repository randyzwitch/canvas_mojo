"""Read and write PNG files -- stdlib-only, no zlib/libpng dependency,
matching this whole workspace's approach to binary formats elsewhere
(BMP here, TrueType/sfnt in the deleted `fonts/` package's history).

PNG's image data is always wrapped in a zlib stream (RFC 1950), which
in turn wraps a DEFLATE stream (RFC 1951) -- LZ77 + Huffman coding,
real compression. `write_png` used to sidestep implementing DEFLATE's
compression side at all, via RFC 1951 3.2.4's "stored" block type
(BTYPE=00, a fully valid but uncompressed DEFLATE encoding) -- the
same trade BMP still makes ("viewable, lossless, trivial to verify
byte-by-byte" over small files). `write_png` no longer needs to make
that trade: `canvas_mojo/io/deflate.mojo` now has a real LZ77 + fixed-
Huffman `deflate()` alongside its own decoder (`inflate`, which
`read_png` already depended on, since a *reader* has to handle
whatever real-world encoder actually produced the file, stored blocks
or genuine compression alike) -- see that module's own docstring for
how each side is built and verified. PNG earns its place alongside BMP
for the same reason it always did (decent viewers preview it well,
it's the format someone downstream would expect to receive or hand
you), now with the small-file half of that bargain actually delivered
too, natively -- no external compression tool, matching the "own the
whole pipeline in Mojo" stance behind every other binary format this
package reads or writes.

Two checksum algorithms, hand-rolled per their public specs
(PNG spec Appendix D for CRC-32; RFC 1950 section 9 for Adler-32),
each independently verified against zlib's own `crc32`/`adler32` on
the same byte sequences before being trusted. `read_png` verifies both
checksums against every real file it reads too (chunk CRC-32s, and the
decompressed data's own Adler-32 against the zlib trailer) -- not just
trusting that decoding "worked" because it produced *some* output.

Two byte orders in play, worth being explicit about since getting
this wrong is a classic mistake: PNG's own chunk framing (length,
CRC-32) and the zlib wrapper's Adler-32 trailer are big-endian: but
DEFLATE's stored-block LEN/NLEN fields are little-endian -- a real
RFC 1951 detail, not a typo, confirmed against zlib's own output.

`write_png` only ever emits color type 2 (truecolor, no alpha), 8-bit
depth: matches Canvas's own storage (RGB, no per-pixel alpha -- see
buffer.mojo's docstring). `read_png` accepts more of what real
encoders actually produce -- color types 0/2/4/6 (grayscale,
truecolor, grayscale+alpha, truecolor+alpha) at 8-bit depth, non-
interlaced -- but not all of PNG's own full breadth: indexed/palette
color (type 3), bit depths other than 8, and Adam7 interlacing all
raise a clear, specific error rather than silently misreading pixels.
That's a deliberate v1 scope, not an oversight: 8-bit RGB/RGBA/
grayscale (with or without alpha), non-interlaced, is what the
overwhelming majority of real-world PNGs (including every one this
package's own `write_png` produces) actually are; the rest is real,
addressable scope if a concrete file needs it, not attempted
speculatively ahead of one. A PNG with an alpha channel loses that
alpha on read -- `read_png` composites each pixel through `Canvas.
set_pixel`'s own existing blend_over, same as every other draw
operation, flattening onto the fresh canvas's own white background,
because `Canvas` itself has no per-pixel alpha channel to preserve it
in (see buffer.mojo's own docstring) -- this is that same, already-
documented architectural fact showing up here, not a new limitation
`read_png` introduces.
"""

from canvas_mojo.buffer import Canvas
from canvas_mojo.color import Color
from canvas_mojo.io.deflate import deflate, inflate


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
    """Standard CRC-32 (IEEE 802.3 / zlib / PNG) table, built from the
    polynomial 0xEDB88320 -- the reversed-bit-order form of the
    canonical 0x04C11DB7 polynomial, used because both PNG and zlib
    process bits/bytes least-significant-first. Straight from the PNG
    spec's own sample code (Appendix D), independently re-typed and
    verified against zlib's own crc32 rather than trusted on sight.
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
    """RFC 1950's checksum for the zlib stream trailer -- a simpler
    running sum than CRC-32, not a table-driven algorithm. `% BASE`
    every byte rather than the batched-mod-every-N-bytes trick real
    zlib implementations use for speed: correct either way, and this
    is the version that reads as an unmodified transcription of the
    spec's own definition.
    """
    comptime BASE = UInt32(65521)
    var s1 = UInt32(1)
    var s2 = UInt32(0)
    for byte in data:
        s1 = (s1 + UInt32(byte)) % BASE
        s2 = (s2 + s1) % BASE
    return (s2 << 16) | s1


def _write_chunk(mut buf: List[UInt8], table: List[UInt32], chunk_type: String, data: List[UInt8]):
    """Append one PNG chunk: length(4, data only) + type(4 ASCII) +
    data + CRC-32(4, over type+data, NOT length) -- all big-endian.
    """
    _append_u32_be(buf, UInt32(len(data)))

    var type_and_data = List[UInt8](capacity=4 + len(data))
    var type_bytes = chunk_type.as_bytes()
    for i in range(len(type_bytes)):
        type_and_data.append(UInt8(type_bytes[i]))
    for b in data:
        type_and_data.append(b)

    for b in type_and_data:
        buf.append(b)
    _append_u32_be(buf, _crc32(type_and_data, table))


def write_png(canvas: Canvas, path: String) raises:
    var w = canvas.width
    var h = canvas.height
    var crc_table = _crc32_table()

    var file_buf = List[UInt8]()
    var signature: List[UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    for b in signature:
        file_buf.append(b)

    var ihdr = List[UInt8]()
    _append_u32_be(ihdr, UInt32(w))
    _append_u32_be(ihdr, UInt32(h))
    ihdr.append(8)  # bit depth
    ihdr.append(2)  # color type: truecolor, no alpha
    ihdr.append(0)  # compression method (always 0 -- deflate)
    ihdr.append(0)  # filter method (always 0)
    ihdr.append(0)  # interlace method: none
    _write_chunk(file_buf, crc_table, "IHDR", ihdr)

    # Raw scanlines: a filter-type byte (0 = None -- no per-pixel
    # prediction; deflate()'s own LZ77 already finds the same
    # horizontal-run redundancy a predictor filter targets, and this
    # package's own images are dominated by large flat-color regions
    # where that already compresses extremely well, see deflate.mojo's
    # own module docstring) followed by that row's RGB bytes, one row
    # after another.
    var raw = List[UInt8](capacity=h * (1 + w * 3))
    for y in range(h):
        raw.append(0)
        for x in range(w):
            var c = canvas.get_pixel(x, y)
            raw.append(c.r)
            raw.append(c.g)
            raw.append(c.b)

    var zlib_stream = List[UInt8]()
    # zlib header (RFC 1950 section 2.2): CMF=0x78 (deflate, 32K
    # window), FLG=0x01 (FLEVEL=0/"fastest", matching deflate()'s own
    # single-fixed-Huffman-block, bounded-search-depth scope -- real
    # compression, not the maximal effort a slower encoder could reach
    # for the same bytes, see deflate.mojo's own module docstring) --
    # and (0x78*256 + 0x01) % 31 == 0, the header's required self-
    # check, confirmed not just assumed.
    zlib_stream.append(0x78)
    zlib_stream.append(0x01)
    var compressed = deflate(raw)
    for b in compressed:
        zlib_stream.append(b)
    _append_u32_be(zlib_stream, _adler32(raw))

    _write_chunk(file_buf, crc_table, "IDAT", zlib_stream)
    _write_chunk(file_buf, crc_table, "IEND", List[UInt8]())

    var f = open(path, "w")
    f.write_bytes(Span(file_buf))
    f.close()


def _read_u32_be(data: List[UInt8], pos: Int) raises -> Int:
    if pos + 4 > len(data):
        raise Error("png: truncated file (expected a 4-byte big-endian value)")
    return (Int(data[pos]) << 24) | (Int(data[pos + 1]) << 16) | (Int(data[pos + 2]) << 8) | Int(data[pos + 3])


def _paeth_predictor(a: Int, b: Int, c: Int) -> Int:
    """PNG spec section 9.4 -- picks whichever of the left (a), above
    (b), or upper-left (c) neighbor is closest to `a + b - c`, in that
    exact tie-breaking order (the spec is explicit that the comparison
    order is load-bearing, not arbitrary).
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
    """8-bit-depth-only byte width per pixel, by color type -- see
    this file's own module docstring for which color types `read_png`
    actually accepts (0/2/4/6) and why (3, indexed/palette, is a real,
    deliberately out-of-scope gap, not covered here).
    """
    if color_type == 0:
        return 1  # grayscale
    if color_type == 2:
        return 3  # truecolor (RGB)
    if color_type == 4:
        return 2  # grayscale + alpha
    if color_type == 6:
        return 4  # truecolor + alpha (RGBA)
    raise Error(String("png: unsupported color type ", color_type, " (only 0/2/4/6 at 8-bit depth are supported)"))


def _unfilter_scanlines(raw: List[UInt8], width: Int, height: Int, bpp: Int) raises -> List[UInt8]:
    """Reverses PNG's own per-scanline filtering (spec section 9) --
    `raw` is `inflate`'s own output: one filter-type byte followed by
    `width * bpp` filtered bytes, repeated `height` times. Reconstructs
    each row using the row directly above it (already reconstructed,
    never the still-filtered version) and the current row's own
    already-reconstructed bytes to the left -- exactly the dependency
    order the spec's own reconstruction formulas assume. Bytes "to the
    left of" the first pixel, and the entire row above the first
    scanline, are treated as zero (the spec's own stated convention),
    not a special case this code has to detect separately -- `a`/`c`
    default to 0 when `x < bpp`, and `prev_row` starts zeroed.
    """
    var row_bytes = width * bpp
    var out = List[UInt8](capacity=height * row_bytes)
    var prev_row = List[UInt8](capacity=row_bytes)
    for _ in range(row_bytes):
        prev_row.append(0)

    var pos = 0
    for _ in range(height):
        if pos >= len(raw):
            raise Error("png: truncated scanline data (fewer rows than IHDR's own height)")
        var filter_type = Int(raw[pos])
        pos += 1
        if pos + row_bytes > len(raw):
            raise Error("png: truncated scanline data (row cut short)")

        var cur_row = List[UInt8](capacity=row_bytes)
        for x in range(row_bytes):
            var filt_x = Int(raw[pos + x])
            var a = Int(cur_row[x - bpp]) if x >= bpp else 0
            var b = Int(prev_row[x])
            var c = Int(prev_row[x - bpp]) if x >= bpp else 0

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
            cur_row.append(UInt8(recon & 0xFF))

        pos += row_bytes
        for b in cur_row:
            out.append(b)
        prev_row = cur_row^

    return out^


def _canvas_from_scanlines(unfiltered: List[UInt8], width: Int, height: Int, color_type: Int) raises -> Canvas:
    """Converts already-unfiltered scanline bytes into a Canvas,
    compositing every pixel through `set_pixel`'s own existing
    blend_over -- see this file's own module docstring for why a PNG
    with an alpha channel loses it here (Canvas has no per-pixel alpha
    of its own to preserve it in), not a gap specific to this function.
    """
    var canvas = Canvas(width, height)
    var bpp = _bytes_per_pixel(color_type)
    var row_bytes = width * bpp
    for y in range(height):
        var row_start = y * row_bytes
        for x in range(width):
            var px = row_start + x * bpp
            var color: Color
            if color_type == 0:
                var gray = unfiltered[px]
                color = Color(gray, gray, gray)
            elif color_type == 2:
                color = Color(unfiltered[px], unfiltered[px + 1], unfiltered[px + 2])
            elif color_type == 4:
                var gray = unfiltered[px]
                color = Color(gray, gray, gray, unfiltered[px + 1])
            else:  # 6 -- _bytes_per_pixel already rejected anything else
                color = Color(unfiltered[px], unfiltered[px + 1], unfiltered[px + 2], unfiltered[px + 3])
            canvas.set_pixel(x, y, color)
    return canvas^


def read_png(path: String) raises -> Canvas:
    """Read a PNG file into a Canvas -- see this file's own module
    docstring for exactly which PNGs this handles (8-bit depth,
    color types 0/2/4/6, non-interlaced) and what it deliberately
    doesn't (indexed color, other bit depths, Adam7 interlacing --
    all raise a clear, specific error rather than misreading pixels).

    Every chunk's CRC-32 is checked against the file's own trailing
    4 bytes, and the fully-decompressed image data's Adler-32 is
    checked against the zlib stream's own trailing 4 bytes -- a
    corrupted or truncated file is rejected explicitly, not silently
    misdecoded into a plausible-looking wrong image.
    """
    var f = open(path, "r")
    var content = f.read_bytes()
    f.close()
    var data = List[UInt8](capacity=len(content))
    for b in content:
        data.append(b)

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
            raise Error(String("png: CRC-32 mismatch in '", chunk_type, "' chunk -- corrupted file"))

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
                raise Error("png: unsupported compression method (only method 0/deflate is supported)")
            if filter_method != 0:
                raise Error("png: unsupported filter method (only method 0 is supported)")
            if interlace_method != 0:
                raise Error("png: Adam7 interlacing is not supported")
            if bit_depth != 8:
                raise Error(String("png: unsupported bit depth ", bit_depth, " (only 8-bit depth is supported)"))
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
        # Any other chunk type (PLTE, ancillary chunks like tEXt/pHYs/
        # gAMA/...) is safely skipped -- read_png doesn't need them for
        # any color type it supports (see this file's own module
        # docstring: palette/indexed color is explicitly out of scope,
        # so PLTE is never actually required here).

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
        raise Error("png: Adler-32 mismatch after decompression -- corrupted file")

    var bpp = _bytes_per_pixel(color_type)
    var unfiltered = _unfilter_scanlines(raw, width, height, bpp)
    return _canvas_from_scanlines(unfiltered, width, height, color_type)
