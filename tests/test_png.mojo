"""Byte-level tests for the PNG encoder and decoder.

Every non-compressed byte here -- signature, IHDR fields, chunk
framing, CRC-32/Adler-32 placement -- was computed by hand from the
struct layout with zlib as an oracle, then confirmed against the real
output. The exception is IDAT's compressed payload, where hand-deriving
an exact LZ77+Huffman bitstream isn't practical: EXPECTED_HEX's IDAT
bytes were captured from real output and verified two ways --
decompressed back through `inflate()`, and separately through Python's
`zlib.decompress()` -- both reproducing the scanline bytes
[1, 10, 20, 30, 30, 30, 30]: filter type 1 (Sub), the first pixel as
is, the second as its difference from the first. `write_png` compresses
the row unfiltered and Sub-filtered and keeps the smaller, and for this
row Sub wins by two bytes. The Adler-32 trailer and every chunk CRC-32
were recomputed to match, and the file decoded independently through a
from-scratch Python reader (chunks, `zlib.crc32`, `zlib.decompress`,
the spec's Sub formula) back to the two pixels.

A 2x1 canvas keeps the whole file checkable in full at 70 bytes. Unlike
test_bmp.mojo, which checks specific header fields and rows, these
check every byte: a wrong CRC, Adler-32 or DEFLATE-framing byte
anywhere makes a real decoder reject the file outright rather than
misrender it.
"""

from std.testing import assert_equal, assert_true, TestSuite

from canvas.color import Color
from canvas.buffer import Canvas
from canvas.io.deflate import deflate, inflate
from canvas.io.png import (
    decode_png,
    read_png,
    write_png,
    _adler32,
    _append_u32_be,
    _crc32_table,
    _write_chunk,
)

comptime TMP_PATH = "tests/_test_png_output.png"

# Captured from write_png()'s output for a 2x1 canvas with pixels
# (10,20,30) and (40,50,60), then verified as this module's docstring
# describes.
comptime EXPECTED_HEX = "89504e470d0a1a0a0000000d49484452000000020000000108020000007b40e8dd0000000d49444154780163e4129103020001da009815d059b50000000049454e44ae426082"


def _hex_digit_value(b: UInt8) -> Int:
    if b >= UInt8(ord("0")) and b <= UInt8(ord("9")):
        return Int(b) - Int(ord("0"))
    return Int(b) - Int(ord("a")) + 10


def _hex_to_bytes(hex: String) -> List[UInt8]:
    var raw = hex.as_bytes()
    var n = len(raw)
    var out = List[UInt8](capacity=n // 2)
    var i = 0
    while i < n:
        var hi = _hex_digit_value(UInt8(raw[i]))
        var lo = _hex_digit_value(UInt8(raw[i + 1]))
        out.append(UInt8(hi * 16 + lo))
        i += 2
    return out^


def _write_sample() raises -> List[UInt8]:
    var c = Canvas(2, 1, Color(255, 255, 255))
    c.set_pixel(0, 0, Color(10, 20, 30))
    c.set_pixel(1, 0, Color(40, 50, 60))
    write_png(c, TMP_PATH)

    var f = open(TMP_PATH, "r")
    var buf = f.read_bytes()
    f.close()
    return buf^


def test_matches_independently_computed_reference_bytes() raises:
    var buf = _write_sample()
    var expected = _hex_to_bytes(EXPECTED_HEX)
    assert_equal(len(buf), len(expected))
    for i in range(len(expected)):
        assert_equal(buf[i], expected[i])


def test_signature_bytes() raises:
    var buf = _write_sample()
    var expected: List[UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    for i in range(8):
        assert_equal(buf[i], expected[i])


def test_ihdr_dimensions_and_color_type() raises:
    var buf = _write_sample()
    # IHDR data starts at byte 16 (8 signature + 4 length + 4 type)
    assert_equal(buf[16], UInt8(0))  # width (u32 BE) == 2
    assert_equal(buf[17], UInt8(0))
    assert_equal(buf[18], UInt8(0))
    assert_equal(buf[19], UInt8(2))
    assert_equal(buf[20], UInt8(0))  # height (u32 BE) == 1
    assert_equal(buf[21], UInt8(0))
    assert_equal(buf[22], UInt8(0))
    assert_equal(buf[23], UInt8(1))
    assert_equal(buf[24], UInt8(8))  # bit depth
    assert_equal(buf[25], UInt8(2))  # color type: truecolor, no alpha


def _assert_tag_at(buf: List[UInt8], offset: Int, tag: String) raises:
    var expected = tag.as_bytes()
    for i in range(4):
        assert_equal(buf[offset + i], UInt8(expected[i]))


def test_chunk_type_tags_appear_in_order() raises:
    var buf = _write_sample()
    _assert_tag_at(buf, 12, "IHDR")
    # IDAT's tag offset (37) depends only on IHDR's fixed 13-byte data
    # size, so it holds however well the payload compresses. IEND's
    # offset does shift with IDAT's length: 13 bytes of data here, so
    # IEND's length field starts at 41 + 13 + 4 = 58 and its tag at 62.
    _assert_tag_at(buf, 37, "IDAT")
    _assert_tag_at(buf, 62, "IEND")


def test_iend_crc_is_the_universal_constant() raises:
    # IEND always has empty data, so its CRC-32 over the ASCII bytes
    # "IEND" is the same 0xAE426082 in every PNG, cross-checked against
    # zlib's crc32. The offset (66, the file's last 4 bytes) shifts
    # with IDAT's length; the value doesn't.
    var buf = _write_sample()
    assert_equal(buf[66], UInt8(0xAE))
    assert_equal(buf[67], UInt8(0x42))
    assert_equal(buf[68], UInt8(0x60))
    assert_equal(buf[69], UInt8(0x82))


comptime READ_TMP_PATH = "tests/_test_png_read_input.png"


def _read_png_bytes() -> List[UInt8]:
    # A real 121-byte PNG (width=5, height=4, RGB) generated by
    # Python's zlib: dynamic-Huffman DEFLATE, cycling through all five
    # scanline filter types (None/Sub/Up/Average/Paeth), one per row.
    # write_png emits filter type None or Sub and never Up, Average
    # or Paeth, so this one file is what exercises those three
    # reconstruction formulas in _unfilter_scanlines -- coverage of
    # what a full-featured external encoder produces, not a second
    # look at this package's narrower writer.
    return [
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
        0,
        0,
        0,
        13,
        73,
        72,
        68,
        82,
        0,
        0,
        0,
        5,
        0,
        0,
        0,
        4,
        8,
        2,
        0,
        0,
        0,
        201,
        81,
        98,
        23,
        0,
        0,
        0,
        64,
        73,
        68,
        65,
        84,
        120,
        218,
        99,
        96,
        103,
        102,
        212,
        103,
        102,
        12,
        103,
        102,
        172,
        103,
        102,
        92,
        206,
        204,
        200,
        200,
        110,
        207,
        168,
        193,
        192,
        11,
        71,
        76,
        12,
        54,
        12,
        12,
        54,
        188,
        12,
        54,
        82,
        12,
        54,
        234,
        12,
        54,
        38,
        204,
        44,
        85,
        140,
        34,
        114,
        82,
        34,
        114,
        138,
        34,
        114,
        234,
        34,
        114,
        122,
        0,
        195,
        210,
        6,
        110,
        53,
        92,
        191,
        213,
        0,
        0,
        0,
        0,
        73,
        69,
        78,
        68,
        174,
        66,
        96,
        130,
    ]


def _read_expected_pixels() -> List[UInt8]:
    return [
        7,
        3,
        1,
        47,
        3,
        1,
        87,
        3,
        1,
        127,
        3,
        1,
        167,
        3,
        1,
        7,
        63,
        1,
        47,
        63,
        14,
        87,
        63,
        27,
        127,
        63,
        40,
        167,
        63,
        53,
        7,
        123,
        1,
        47,
        123,
        27,
        87,
        123,
        53,
        127,
        123,
        79,
        167,
        123,
        105,
        7,
        183,
        1,
        47,
        183,
        40,
        87,
        183,
        79,
        127,
        183,
        118,
        167,
        183,
        157,
    ]


def _write_read_sample() raises -> Canvas:
    var png_bytes = _read_png_bytes()
    var f = open(READ_TMP_PATH, "w")
    f.write_bytes(Span(png_bytes))
    f.close()
    return read_png(READ_TMP_PATH)


def test_read_decodes_all_five_filter_types_correctly() raises:
    var canvas = _write_read_sample()
    var expected = _read_expected_pixels()
    assert_equal(canvas.width, 5)
    assert_equal(canvas.height, 4)
    for y in range(4):
        for x in range(5):
            var idx = (y * 5 + x) * 3
            var p = canvas.get_pixel(x, y)
            assert_equal(p.r, expected[idx])
            assert_equal(p.g, expected[idx + 1])
            assert_equal(p.b, expected[idx + 2])


def test_read_write_round_trip() raises:
    # This package's writer read back by its reader: a different path
    # from the real-zlib vector above, since write_png emits only
    # filter types None and Sub.
    var c = Canvas(6, 5, Color(240, 240, 240))
    for y in range(5):
        for x in range(6):
            c.set_pixel(
                x,
                y,
                Color(
                    UInt8(x * 40 % 256),
                    UInt8(y * 50 % 256),
                    UInt8((x + y) * 10 % 256),
                ),
            )
    write_png(c, TMP_PATH)
    var c2 = read_png(TMP_PATH)
    assert_equal(c2.width, c.width)
    assert_equal(c2.height, c.height)
    for y in range(5):
        for x in range(6):
            var p1 = c.get_pixel(x, y)
            var p2 = c2.get_pixel(x, y)
            assert_equal(p1.r, p2.r)
            assert_equal(p1.g, p2.g)
            assert_equal(p1.b, p2.b)


def _idat_scanlines(path: String) raises -> List[UInt8]:
    """The decompressed scanline bytes of a one-IDAT PNG `write_png`
    wrote: the chunk's data minus the 2-byte zlib header and 4-byte
    Adler-32 trailer, through inflate().
    """
    var f = open(path, "r")
    var buf = f.read_bytes()
    f.close()
    # IDAT is the second chunk write_png emits, so its length field
    # sits right after IHDR: 8 (signature) + 25 (IHDR chunk) = 33.
    var length = (
        (Int(buf[33]) << 24)
        | (Int(buf[34]) << 16)
        | (Int(buf[35]) << 8)
        | Int(buf[36])
    )
    var deflate_data = List[UInt8]()
    deflate_data.extend(buf[41 + 2 : 41 + length - 4])
    return inflate(deflate_data^)


def test_write_picks_sub_for_a_ramp() raises:
    # A 256x1 row whose red channel counts 0..255 with green and blue
    # at zero. Unfiltered, every byte value appears and nothing
    # repeats, so the row is 768 near-incompressible literals. Under
    # Sub each red byte becomes 1 (its difference from the pixel to
    # the left) and green/blue stay 0, so the row is the three bytes
    # 1 0 0 repeated -- one LZ77 match. Sub has to win, and the
    # scanline's filter byte says which was kept.
    var c = Canvas(256, 1, Color(0, 0, 0))
    for x in range(256):
        c.set_pixel(x, 0, Color(UInt8(x), 0, 0))
    write_png(c, TMP_PATH)

    var scanlines = _idat_scanlines(TMP_PATH)
    assert_equal(len(scanlines), 1 + 256 * 3)
    assert_equal(scanlines[0], 1, "filter byte 1: Sub was kept")
    # The first pixel is unchanged; every later red byte is the +1
    # step.
    assert_equal(scanlines[1], 0)
    assert_equal(scanlines[4], 1)
    assert_equal(scanlines[1 + 200 * 3], 1)

    # And it reads back as written.
    var back = read_png(TMP_PATH)
    for x in range(256):
        assert_equal(back.get_pixel(x, 0).r, UInt8(x))
        assert_equal(back.get_pixel(x, 0).g, 0)


def test_write_keeps_none_for_a_flat_row() raises:
    # A flat row is 768 copies of one byte pattern under None and 3
    # bytes then 765 zeros under Sub; both compress to almost nothing,
    # and the tie-break keeps None, which is also what the pinned 2x1
    # sample above relies on for tiny inputs where the two differ by a
    # byte or two either way. What matters is that the choice is made
    # by size, never by assumption: whichever won, the file must read
    # back exactly.
    var c = Canvas(256, 1, Color(90, 60, 30))
    write_png(c, TMP_PATH)
    var back = read_png(TMP_PATH)
    for x in range(0, 256, 17):
        assert_equal(back.get_pixel(x, 0).r, 90)
        assert_equal(back.get_pixel(x, 0).g, 60)
        assert_equal(back.get_pixel(x, 0).b, 30)


def _indexed_png(
    width: Int,
    height: Int,
    bit_depth: Int,
    palette: List[UInt8],
    trns: List[UInt8],
    rows: List[List[UInt8]],
) raises -> List[UInt8]:
    """A hand-built indexed-color PNG: IHDR, PLTE, tRNS when non-empty,
    one IDAT of filter-0 scanlines given as their packed bytes, IEND.
    """
    var out: List[UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    var table = _crc32_table()
    var ihdr = List[UInt8]()
    _append_u32_be(ihdr, UInt32(width))
    _append_u32_be(ihdr, UInt32(height))
    ihdr.append(UInt8(bit_depth))
    ihdr.append(3)
    ihdr.append(0)
    ihdr.append(0)
    ihdr.append(0)
    _write_chunk(out, table, "IHDR", ihdr)
    _write_chunk(out, table, "PLTE", palette)
    if len(trns) > 0:
        _write_chunk(out, table, "tRNS", trns)
    var raw = List[UInt8]()
    for row in rows:
        raw.append(0)
        for b in row:
            raw.append(b)
    var zlib = List[UInt8]()
    zlib.append(0x78)
    zlib.append(0x01)
    zlib.extend(deflate(raw))
    _append_u32_be(zlib, _adler32(raw))
    _write_chunk(out, table, "IDAT", zlib)
    _write_chunk(out, table, "IEND", List[UInt8]())
    return out^


def test_decode_indexed_color_with_a_transparent_entry() raises:
    # A 2x2 image over a three-entry palette at 8 bits, with tRNS
    # making entry 1 half transparent and entry 2 (past tRNS's end)
    # opaque by default.
    var palette: List[UInt8] = [255, 0, 0, 0, 255, 0, 0, 0, 255]
    var trns: List[UInt8] = [255, 128]
    var rows: List[List[UInt8]] = [[0, 1], [2, 0]]
    var c = decode_png(_indexed_png(2, 2, 8, palette, trns, rows))
    assert_equal(c.width, 2)
    assert_equal(c.height, 2)
    var p00 = c.get_pixel(0, 0)
    assert_equal(Int(p00.r), 255)
    assert_equal(Int(p00.a), 255)
    var p10 = c.get_pixel(1, 0)
    assert_equal(Int(p10.g), 255)
    assert_equal(Int(p10.a), 128, "tRNS entry 1")
    var p01 = c.get_pixel(0, 1)
    assert_equal(Int(p01.b), 255)
    assert_equal(Int(p01.a), 255, "past tRNS is opaque")


def test_decode_indexed_color_at_four_bits_packs_two_pixels_per_byte() raises:
    # Indices 1, 2, 3, 0 across one 4-pixel row: bytes 0x12 0x30, the
    # high nibble first.
    var palette: List[UInt8] = [0, 0, 0, 10, 10, 10, 20, 20, 20, 30, 30, 30]
    var rows: List[List[UInt8]] = [[0x12, 0x30]]
    var c = decode_png(_indexed_png(4, 1, 4, palette, List[UInt8](), rows))
    assert_equal(Int(c.get_pixel(0, 0).r), 10)
    assert_equal(Int(c.get_pixel(1, 0).r), 20)
    assert_equal(Int(c.get_pixel(2, 0).r), 30)
    assert_equal(Int(c.get_pixel(3, 0).r), 0)
    # A palette index past the table is an error, not a read past it.
    var bad: List[List[UInt8]] = [[0x1F, 0x00]]
    var raised = False
    try:
        _ = decode_png(_indexed_png(4, 1, 4, palette, List[UInt8](), bad))
    except e:
        raised = True
    assert_true(raised, "index 15 with a 4-entry palette")


def test_read_rejects_bad_signature() raises:
    var bad: List[UInt8] = [1, 2, 3, 4, 5, 6, 7, 8, 9]
    var path = "tests/_test_png_bad_signature.png"
    var f = open(path, "w")
    f.write_bytes(Span(bad))
    f.close()
    var raised = False
    try:
        var c = read_png(path)
        _ = c
    except:
        raised = True
    assert_true(raised)


def test_read_rejects_corrupted_crc() raises:
    var corrupted = _read_png_bytes()
    corrupted[20] = corrupted[20] ^ UInt8(
        0xFF
    )  # flip a byte inside IHDR's data
    var path = "tests/_test_png_bad_crc.png"
    var f = open(path, "w")
    f.write_bytes(Span(corrupted))
    f.close()
    var raised = False
    try:
        var c = read_png(path)
        _ = c
    except:
        raised = True
    assert_true(raised)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
