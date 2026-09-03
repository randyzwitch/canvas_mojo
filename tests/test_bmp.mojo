"""Byte-level tests for the BMP encoder.

Unlike test_color/test_buffer (which assert on in-memory Color/Canvas
values -- the right level for testing raster *logic*), these tests go
through the actual file bytes, because the thing being verified *is*
the byte layout: header fields, little-endian packing, the BGR
channel swap, bottom-up row order, and per-row padding to a 4-byte
boundary.

The canvas is 3 pixels wide (9 bytes/row) so the padding path is
exercised: a width whose row bytes already land on a 4-byte boundary
(64*3=192, say) never reaches that code.
"""

from std.testing import assert_raises, assert_equal, TestSuite

from canvas.color import Color
from canvas.buffer import Canvas
from canvas.io.bmp import write_bmp, read_bmp

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
        255,
        255,
        255,
        255,
        255,
        255,
        60,
        50,
        40,
        0,
        0,
        0,
    ]
    for i in range(12):
        assert_equal(buf[54 + i], expected[i])


def test_row1_is_top_canvas_row_bgr_with_padding() raises:
    # Row 1 of the file is canvas row y=0: (10,20,30) as BGR, white,
    # white, then 3 padding bytes.
    var buf = _write_sample()
    var expected: List[UInt8] = [
        30,
        20,
        10,
        255,
        255,
        255,
        255,
        255,
        255,
        0,
        0,
        0,
    ]
    for i in range(12):
        assert_equal(buf[66 + i], expected[i])


def test_read_bmp_round_trips_write_bmp() raises:
    # The property that matters: whatever write_bmp emits, read_bmp
    # returns unchanged. Includes odd widths, which exercise BMP's
    # 4-byte row padding -- a width of 5 pixels is 15 bytes of BGR
    # padded to 16, so a reader that ignores padding drifts by one byte
    # per row and shears the image.
    for w in [1, 2, 3, 4, 5, 7]:
        var src = Canvas(w, 5, Color(0, 0, 0))
        for y in range(5):
            for x in range(w):
                src.set_pixel(
                    x, y, Color(UInt8(x * 20 + 5), UInt8(y * 40 + 3), 200)
                )
        write_bmp(src, TMP_PATH)
        var back = read_bmp(TMP_PATH)
        assert_equal(back.width, w, "width survives")
        assert_equal(back.height, 5, "height survives")
        for y in range(5):
            for x in range(w):
                var a = src.get_pixel(x, y)
                var b = back.get_pixel(x, y)
                assert_equal(b.r, a.r, "red survives the round trip")
                assert_equal(b.g, a.g, "green survives the round trip")
                assert_equal(b.b, a.b, "blue survives the round trip")
                assert_equal(b.a, 255, "decoded pixels are opaque")


def test_read_bmp_orientation_is_not_flipped() raises:
    # BMP stores rows bottom-up. A reader that forgets returns a
    # vertically mirrored image, which a symmetric test image would
    # never catch -- so this one is deliberately asymmetric.
    var src = Canvas(2, 2, Color(0, 0, 0))
    src.set_pixel(0, 0, Color(255, 0, 0))
    src.set_pixel(1, 0, Color(0, 255, 0))
    src.set_pixel(0, 1, Color(0, 0, 255))
    src.set_pixel(1, 1, Color(255, 255, 0))
    write_bmp(src, TMP_PATH)

    var back = read_bmp(TMP_PATH)
    assert_equal(back.get_pixel(0, 0).r, 255, "top-left stays top-left")
    assert_equal(back.get_pixel(0, 0).g, 0)
    assert_equal(back.get_pixel(1, 0).g, 255, "top-right stays top-right")
    assert_equal(back.get_pixel(0, 1).b, 255, "bottom-left stays put")
    assert_equal(back.get_pixel(1, 1).r, 255, "bottom-right stays put")
    assert_equal(back.get_pixel(1, 1).g, 255)


def test_read_bmp_handles_top_down_row_order() raises:
    # A negative height field means rows are stored top-down instead of
    # BMP's usual bottom-up. write_bmp never emits that, so the only
    # way to cover the branch is to build one: take a normal file,
    # negate the height, and reverse the stored rows. A reader that
    # ignored the sign would return this vertically mirrored.
    var src = Canvas(2, 2, Color(0, 0, 0))
    src.set_pixel(0, 0, Color(255, 0, 0))
    src.set_pixel(1, 0, Color(0, 255, 0))
    src.set_pixel(0, 1, Color(0, 0, 255))
    src.set_pixel(1, 1, Color(255, 255, 0))
    write_bmp(src, TMP_PATH)

    var f = open(TMP_PATH, "r")
    var data = f.read_bytes()
    f.close()

    # Height field at offset 22, little-endian i32: 2 becomes -2.
    data[22] = 0xFE
    data[23] = 0xFF
    data[24] = 0xFF
    data[25] = 0xFF

    # ...and the two stored rows swap, so the image itself is unchanged
    # and only its declared order differs.
    var row_size = ((2 * 3 + 3) // 4) * 4
    var flipped = List[UInt8]()
    for i in range(54):
        flipped.append(data[i])
    for i in range(row_size):
        flipped.append(data[54 + row_size + i])
    for i in range(row_size):
        flipped.append(data[54 + i])

    var out = open(TMP_PATH, "w")
    out.write_bytes(Span(flipped))
    out.close()

    var back = read_bmp(TMP_PATH)
    assert_equal(back.get_pixel(0, 0).r, 255, "top-left is still red")
    assert_equal(back.get_pixel(1, 0).g, 255, "top-right is still green")
    assert_equal(back.get_pixel(0, 1).b, 255, "bottom-left is still blue")
    assert_equal(back.get_pixel(1, 1).r, 255, "bottom-right is still yellow")
    assert_equal(back.get_pixel(1, 1).g, 255)


def test_read_bmp_rejects_a_non_bmp() raises:
    var f = open(TMP_PATH, "w")
    var junk: List[UInt8] = [
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
    ]
    for _ in range(60):
        junk.append(0)
    f.write_bytes(Span(junk))
    f.close()
    with assert_raises(contains="BM"):
        _ = read_bmp(TMP_PATH)


def test_read_bmp_rejects_a_truncated_file() raises:
    var src = Canvas(4, 4, Color(10, 20, 30))
    write_bmp(src, TMP_PATH)
    var f = open(TMP_PATH, "r")
    var full = f.read_bytes()
    f.close()

    var cut = List[UInt8]()
    for i in range(60):  # header plus a few pixel bytes, then nothing
        cut.append(full[i])
    var out = open(TMP_PATH, "w")
    out.write_bytes(Span(cut))
    out.close()

    with assert_raises(contains="truncated"):
        _ = read_bmp(TMP_PATH)


def test_read_bmp_rejects_an_unsupported_bit_depth() raises:
    var src = Canvas(4, 4, Color(10, 20, 30))
    write_bmp(src, TMP_PATH)
    var f = open(TMP_PATH, "r")
    var data = f.read_bytes()
    f.close()
    data[28] = 8  # bits-per-pixel field: claim a palettized 8-bit file
    data[29] = 0
    var out = open(TMP_PATH, "w")
    out.write_bytes(Span(data))
    out.close()

    with assert_raises(contains="bit depth"):
        _ = read_bmp(TMP_PATH)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
