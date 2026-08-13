"""Write a Canvas out as a PNG file -- stdlib-only, no zlib/libpng
dependency, matching this whole workspace's approach to binary
formats elsewhere (BMP here, TrueType/sfnt in the deleted `fonts/`
package's history).

PNG's image data is always wrapped in a zlib stream (RFC 1950), which
in turn wraps a DEFLATE stream (RFC 1951) -- normally LZ77 + Huffman
coding, real compression. This writer sidesteps implementing DEFLATE's
compression at all: RFC 1951 section 3.2.4 defines a "stored" block
type (BTYPE=00) that copies bytes through uncompressed, a fully valid
DEFLATE encoding any conforming decoder must accept, just a larger one
than a compressed stream would be. That's an acceptable trade here --
BMP already made the same call (uncompressed) for the same reason:
"viewable, lossless, trivial to verify byte-by-byte" doesn't need
small files, and this workspace has no compression library to lean on
anyway. PNG earns its place alongside BMP despite that for one reason:
unlike BMP, decent viewers actually preview it well, and it's the
format someone downstream would expect to receive.

Two checksum algorithms, hand-rolled per their public specs
(PNG spec Appendix D for CRC-32; RFC 1950 section 9 for Adler-32),
each independently verified against zlib's own `crc32`/`adler32` on
the same byte sequences before being trusted. Every byte of a written
file was also round-tripped through a from-scratch PNG chunk parser
(signature, IHDR, IDAT-as-zlib-stream, IEND -- not relying on any
existing PNG/imaging library, matching how the CRC/Adler code was
verified against the spec itself, not against a library that might
hide the same bug this code could have), confirming the pixels decode
back out exactly.

Two byte orders in play, worth being explicit about since getting
this wrong is a classic mistake: PNG's own chunk framing (length,
CRC-32) and the zlib wrapper's Adler-32 trailer are big-endian: but
DEFLATE's stored-block LEN/NLEN fields are little-endian -- a real
RFC 1951 detail, not a typo, confirmed against zlib's own output.

Color type 2 (truecolor, no alpha), 8-bit depth: matches Canvas's own
storage (RGB, no per-pixel alpha -- see buffer.mojo's docstring).
"""

from canvas_mojo.buffer import Canvas


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


def _deflate_stored(data: List[UInt8]) -> List[UInt8]:
    """Wrap `data` in DEFLATE stored (uncompressed) blocks -- RFC 1951
    section 3.2.4. Each block: a 3-bit header (BFINAL + BTYPE=00)
    padded out to a byte boundary (valid here because a stored block
    always starts and ends byte-aligned, so the padding is simply the
    rest of that first byte, all zero bits), then LEN/NLEN (16-bit
    little-endian; NLEN is LEN's one's complement, a self-check real
    decoders verify) and the raw bytes themselves. Max 65535 bytes per
    block, so anything larger splits across multiple blocks -- BFINAL
    set only on the last one.
    """
    var out = List[UInt8]()
    comptime MAX_BLOCK = 65535
    var pos = 0
    var total = len(data)

    while True:
        var remaining = total - pos
        var block_len = remaining if remaining < MAX_BLOCK else MAX_BLOCK
        var is_final = pos + block_len >= total

        # BFINAL in bit 0, BTYPE (00 = stored) in bits 1-2, remaining
        # 5 bits of this byte are padding up to the next byte
        # boundary -- all zero, so the header byte is just BFINAL itself.
        out.append(UInt8(1) if is_final else UInt8(0))
        _append_u16_le(out, UInt16(block_len))
        _append_u16_le(out, UInt16(UInt32(0xFFFF) ^ UInt32(block_len)))
        for i in range(block_len):
            out.append(data[pos + i])

        pos += block_len
        if is_final:
            break

    return out^


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
    # prediction, matching "no real compression" throughout this
    # writer) followed by that row's RGB bytes, one row after another.
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
    # window), FLG=0x01 (fastest/no compression, matching what this
    # actually is) -- and (0x78*256 + 0x01) % 31 == 0, the header's
    # required self-check, confirmed not just assumed.
    zlib_stream.append(0x78)
    zlib_stream.append(0x01)
    var compressed = _deflate_stored(raw)
    for b in compressed:
        zlib_stream.append(b)
    _append_u32_be(zlib_stream, _adler32(raw))

    _write_chunk(file_buf, crc_table, "IDAT", zlib_stream)
    _write_chunk(file_buf, crc_table, "IEND", List[UInt8]())

    var f = open(path, "w")
    f.write_bytes(Span(file_buf))
    f.close()
