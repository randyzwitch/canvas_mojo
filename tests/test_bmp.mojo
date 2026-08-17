"""Byte-level tests for the BMP encoder.

Unlike test_color/test_buffer (which assert on in-memory Color/Canvas
values -- the right level for testing raster *logic*), these tests go
through the actual file bytes, because the thing being verified *is*
the byte layout: header fields, little-endian packing, the BGR
channel swap, bottom-up row order, and per-row padding to a 4-byte
boundary.

The canvas is deliberately 3 pixels wide (9 bytes/row) so padding is
actually exercised -- the earlier 64px-wide demo never hit that path,
since 64*3=192 is already a multiple of 4.
"""

from std.testing import assert_equal, TestSuite

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas
from canvas_mojo.io.bmp import write_bmp

comptime TMP_PATH = "tests/_test_bmp_output.bmp"


def _write_sample() raises -> List[UInt8]:
    var c = Canvas(3, 2, Color(255, 255, 255))
    c.set_pixel(0, 0, Color(10, 20, 30))  # top row
    c.set_pixel(2, 1, Color(40, 50, 60))  # bottom row, last column
    write_bmp(c, TMP_PATH)

    var f = open(TMP_PATH, "r")
    var buf = f.read_bytes()
    f.close()
    return buf^


def test_file_size_matches_header_plus_padded_rows() raises:
    var buf = _write_sample()
    # 54-byte header + 2 rows * 12 bytes/row (9 pixel bytes + 3 pad).
    assert_equal(len(buf), 78)


def test_bm_magic_bytes() raises:
    var buf = _write_sample()
    assert_equal(buf[0], UInt8(ord("B")))
    assert_equal(buf[1], UInt8(ord("M")))


def test_header_fields() raises:
    var buf = _write_sample()
    # file size (u32 LE) == 78
    assert_equal(buf[2], UInt8(78))
    assert_equal(buf[3], UInt8(0))
    assert_equal(buf[4], UInt8(0))
    assert_equal(buf[5], UInt8(0))
    # pixel data offset (u32 LE) == 54
    assert_equal(buf[10], UInt8(54))
    assert_equal(buf[11], UInt8(0))
    assert_equal(buf[12], UInt8(0))
    assert_equal(buf[13], UInt8(0))
    # width (u32 LE) == 3
    assert_equal(buf[18], UInt8(3))
    assert_equal(buf[19], UInt8(0))
    assert_equal(buf[20], UInt8(0))
    assert_equal(buf[21], UInt8(0))
    # height (u32 LE) == 2
    assert_equal(buf[22], UInt8(2))
    assert_equal(buf[23], UInt8(0))
    assert_equal(buf[24], UInt8(0))
    assert_equal(buf[25], UInt8(0))
    # bits per pixel (u16 LE) == 24
    assert_equal(buf[28], UInt8(24))
    assert_equal(buf[29], UInt8(0))


def test_row0_is_bottom_canvas_row_bgr_with_padding() raises:
    # Row 0 of the file is canvas row y=1 (bottom-up storage):
    # white, white, (40,50,60) as BGR, then 3 padding bytes.
    var buf = _write_sample()
    var expected: List[UInt8] = [
        255, 255, 255, 255, 255, 255, 60, 50, 40, 0, 0, 0
    ]
    for i in range(12):
        assert_equal(buf[54 + i], expected[i])


def test_row1_is_top_canvas_row_bgr_with_padding() raises:
    # Row 1 of the file is canvas row y=0: (10,20,30) as BGR, white,
    # white, then 3 padding bytes.
    var buf = _write_sample()
    var expected: List[UInt8] = [
        30, 20, 10, 255, 255, 255, 255, 255, 255, 0, 0, 0
    ]
    for i in range(12):
        assert_equal(buf[66 + i], expected[i])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
