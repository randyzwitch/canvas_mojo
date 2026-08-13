"""Byte-level tests for the PNG encoder.

Every expected byte value here was independently computed by hand
(struct layout + zlib as an *oracle* to cross-check against), not
derived from this code's own output, then confirmed that the actual
Mojo output matches byte-for-byte before being locked in as an
assertion.

A 2x1 canvas keeps the whole file small enough to hand-verify in full
(75 bytes total) -- unlike test_bmp.mojo's tests, which check specific
header fields and rows, these check every single byte, since a wrong
CRC/Adler-32/DEFLATE-framing byte anywhere would make a real PNG
decoder reject the file outright, not just misrender it.
"""

from std.testing import assert_equal, TestSuite

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas
from canvas_mojo.io.png import write_png

comptime TMP_PATH = "canvas_mojo/tests/_test_png_output.png"

# Independently computed by hand for a 2x1 canvas with pixels
# (10,20,30) and (40,50,60) -- see this file's own docstring.
# zlib.decompress() on the IDAT payload was also confirmed separately
# to round-trip back to the exact raw scanline bytes this encodes.
comptime EXPECTED_HEX = "89504e470d0a1a0a0000000d49484452000000020000000108020000007b40e8dd00000012494441547801010700f8ff000a141e28323c023700d31d22d0ad0000000049454e44ae426082"


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
    _assert_tag_at(buf, 37, "IDAT")
    _assert_tag_at(buf, 67, "IEND")


def test_iend_crc_is_the_universal_constant() raises:
    # IEND always has empty data, so its CRC-32 (over just the ASCII
    # bytes "IEND") is the same fixed value in every PNG ever written
    # -- 0xAE426082, confirmed independently against zlib's own crc32.
    var buf = _write_sample()
    assert_equal(buf[71], UInt8(0xAE))
    assert_equal(buf[72], UInt8(0x42))
    assert_equal(buf[73], UInt8(0x60))
    assert_equal(buf[74], UInt8(0x82))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
