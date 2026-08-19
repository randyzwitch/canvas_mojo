"""Byte-level tests for the PNG encoder and decoder.

Every non-compressed byte here (signature, IHDR fields, chunk framing,
CRC-32/Adler-32 placement) was independently computed by hand (struct
layout + zlib as an *oracle* to cross-check against), not derived from
this code's own output, then confirmed the actual Mojo output matches
byte-for-byte before being locked in as an assertion. The one
exception is IDAT's own compressed payload: canvas_mojo.io.deflate's
own `deflate()` (see that module's own docstring for how it's
verified) makes hand-deriving an exact LZ77+Huffman bitstream
impractical for a human to do reliably -- EXPECTED_HEX's own IDAT
bytes were captured from this package's actual output instead, then
independently verified two ways before being trusted: decompressed
back through canvas_mojo's own `inflate()` (round-trip identity) AND,
separately, through Python's `zlib.decompress()` (a wholly independent
implementation) -- both reproduce the exact same known raw scanline
bytes [0, 10, 20, 30, 40, 50, 60], and the Adler-32 trailer and every
chunk's own CRC-32 were independently recomputed and confirmed to
match too (see tests/test_deflate.mojo for deflate()'s own dedicated
round-trip/cross-verification coverage).

A 2x1 canvas keeps the whole file small enough to check in full (72
bytes total) -- unlike test_bmp.mojo's tests, which check specific
header fields and rows, these check every single byte, since a wrong
CRC/Adler-32/DEFLATE-framing byte anywhere would make a real PNG
decoder reject the file outright, not just misrender it.
"""

from std.testing import assert_equal, assert_true, TestSuite

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas
from canvas_mojo.io.png import read_png, write_png

comptime TMP_PATH = "tests/_test_png_output.png"

# Captured from this package's own write_png() output for a 2x1 canvas
# with pixels (10,20,30) and (40,50,60), then independently verified
# -- see this file's own module docstring for exactly how (this is not
# hand-derived the way the old stored-block-era value was; real
# LZ77+Huffman compression makes that impractical).
comptime EXPECTED_HEX = "89504e470d0a1a0a0000000d49484452000000020000000108020000007b40e8dd0000000f49444154780163e01291d330b20100023700d3096df20d0000000049454e44ae426082"


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
    # IDAT's own tag offset (37) doesn't depend on IDAT's own length --
    # only on IHDR's fixed 13-byte data size, which never changes --
    # so this stays the same regardless of how well IDAT's own payload
    # compresses. IEND's offset does shift with IDAT's own length
    # (real compression makes IDAT shorter than the old stored-block
    # version was, see EXPECTED_HEX's own comment).
    _assert_tag_at(buf, 37, "IDAT")
    _assert_tag_at(buf, 64, "IEND")


def test_iend_crc_is_the_universal_constant() raises:
    # IEND always has empty data, so its CRC-32 (over just the ASCII
    # bytes "IEND") is the same fixed value in every PNG ever written
    # -- 0xAE426082, confirmed independently against zlib's own crc32.
    # Offset (68, the file's own last 4 bytes) shifts with IDAT's own
    # length the same way IEND's own tag offset does above; the value
    # itself doesn't.
    var buf = _write_sample()
    assert_equal(buf[68], UInt8(0xAE))
    assert_equal(buf[69], UInt8(0x42))
    assert_equal(buf[70], UInt8(0x60))
    assert_equal(buf[71], UInt8(0x82))


comptime READ_TMP_PATH = "tests/_test_png_read_input.png"


def _read_png_bytes() -> List[UInt8]:
    # A real PNG file (121 bytes: width=5, height=4, RGB), generated by
    # Python's zlib -- dynamic-Huffman DEFLATE (this package's own
    # write_png only ever emits a single fixed-Huffman block, see
    # canvas_mojo/io/deflate.mojo's own module docstring), cycling
    # through all five PNG scanline filter types (None/Sub/Up/Average/
    # Paeth) one row each (write_png itself only ever emits filter type
    # None), so every reconstruction formula in _unfilter_scanlines and
    # every DEFLATE block type inflate() supports gets exercised by a
    # single file -- real coverage of what a full-featured external
    # encoder produces, not a second look at this package's own
    # narrower writer. Independently verified by probe against the
    # same pixel values before being locked in here.
    return [
        137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0,
        0, 0, 5, 0, 0, 0, 4, 8, 2, 0, 0, 0, 201, 81, 98, 23, 0,
        0, 0, 64, 73, 68, 65, 84, 120, 218, 99, 96, 103, 102, 212, 103, 102, 12,
        103, 102, 172, 103, 102, 92, 206, 204, 200, 200, 110, 207, 168, 193, 192, 11, 71,
        76, 12, 54, 12, 12, 54, 188, 12, 54, 82, 12, 54, 234, 12, 54, 38, 204,
        44, 85, 140, 34, 114, 82, 34, 114, 138, 34, 114, 234, 34, 114, 122, 0, 195,
        210, 6, 110, 53, 92, 191, 213, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66,
        96, 130,
    ]


def _read_expected_pixels() -> List[UInt8]:
    return [
        7, 3, 1, 47, 3, 1, 87, 3, 1, 127, 3, 1, 167, 3, 1, 7, 63,
        1, 47, 63, 14, 87, 63, 27, 127, 63, 40, 167, 63, 53, 7, 123, 1, 47,
        123, 27, 87, 123, 53, 127, 123, 79, 167, 123, 105, 7, 183, 1, 47, 183, 40,
        87, 183, 79, 127, 183, 118, 167, 183, 157,
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
    # This package's own writer, read back by this package's own
    # reader -- a different code path than the hand-crafted real-zlib
    # vector above (write_png only ever emits a single fixed-Huffman
    # block and filter type None -- see _read_png_bytes' own comment),
    # so this is real coverage of that specific path, not a duplicate
    # of the test above.
    var c = Canvas(6, 5, Color(240, 240, 240))
    for y in range(5):
        for x in range(6):
            c.set_pixel(x, y, Color(UInt8(x * 40 % 256), UInt8(y * 50 % 256), UInt8((x + y) * 10 % 256)))
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
    corrupted[20] = corrupted[20] ^ UInt8(0xFF)  # flip a byte inside IHDR's data
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
