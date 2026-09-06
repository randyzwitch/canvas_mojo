"""Tests for io/jpeg.mojo: baseline JPEG decoding against files
written by Pillow (libjpeg) under tests/jpeg/, each beside a PNG of
what libjpeg itself decodes it to.

The comparison is a tolerance, not equality: the inverse DCT here is
floating point where libjpeg's default is integer, so a sample can
land one level off, and the YCbCr conversion rounds once more. The
fixtures cover 4:4:4, 4:2:0 and 4:2:2 chroma subsampling, an odd
image size (partial MCUs on both edges), grayscale, and restart
intervals. A progressive file must raise rather than misdecode.

To regenerate the fixtures: the `scene` in this file's docstring is a
horizontal red ramp against a vertical green ramp, a red ellipse and
a green rectangle, saved by Pillow at the subsampling and quality
named in each fixture, with `restart_marker_blocks=2` for the restart
one; the expected PNG is Pillow's own decode of the saved file.
"""

from std.testing import assert_equal, assert_true, TestSuite

from canvas.io.jpeg import decode_jpeg, read_jpeg
from canvas.io.png import read_png

comptime _DIR = "tests/jpeg/"


def _max_and_mean_diff(name: String) raises -> Tuple[Int, Float64]:
    var got = read_jpeg(_DIR + name + ".jpg")
    var want = read_png(_DIR + name + "_expected.png")
    assert_equal(got.width, want.width, "decoded width")
    assert_equal(got.height, want.height, "decoded height")
    var maxd = 0
    var total = 0
    for y in range(want.height):
        for x in range(want.width):
            var g = got.get_pixel(x, y)
            var w = want.get_pixel(x, y)
            assert_equal(g.a, 255, "a JPEG decodes opaque")
            var ds: List[Int] = [
                abs(Int(g.r) - Int(w.r)),
                abs(Int(g.g) - Int(w.g)),
                abs(Int(g.b) - Int(w.b)),
            ]
            for d in ds:
                if d > maxd:
                    maxd = d
                total += d
    return (maxd, Float64(total) / Float64(want.width * want.height * 3))


def _assert_close(name: String, max_allowed: Int, mean_allowed: Float64) raises:
    var r = _max_and_mean_diff(name)
    assert_true(
        r[0] <= max_allowed,
        String(name, ": max channel difference ", r[0], " > ", max_allowed),
    )
    assert_true(
        r[1] <= mean_allowed,
        String(name, ": mean channel difference ", r[1], " > ", mean_allowed),
    )


def test_444_matches_libjpeg() raises:
    _assert_close("color_444", 3, 0.2)


def test_420_fancy_upsampling_matches_libjpeg() raises:
    _assert_close("color_420", 4, 0.2)


def test_422_odd_size_matches_libjpeg() raises:
    _assert_close("odd_size_422", 4, 0.8)


def test_grayscale_matches_libjpeg() raises:
    _assert_close("gray", 2, 0.2)


def test_restart_intervals_match_libjpeg() raises:
    _assert_close("restart", 4, 0.2)


def test_progressive_raises() raises:
    var raised = False
    try:
        _ = read_jpeg(_DIR + "progressive.jpg")
    except e:
        raised = True
        assert_true(
            "progressive" in String(e),
            "the error names the unsupported process",
        )
    assert_true(raised, "a progressive file must raise")


def test_not_a_jpeg_raises() raises:
    var raised = False
    try:
        _ = read_png(_DIR + "gray.jpg")
    except:
        raised = True
    assert_true(raised, "read_png rejects a JPEG")
    raised = False
    try:
        _ = decode_jpeg([0, 1, 2, 3])
    except e:
        raised = True
        assert_true("SOI" in String(e), "the error names the missing marker")
    assert_true(raised, "decode_jpeg rejects non-JPEG bytes")


def test_truncated_file_raises() raises:
    var f = open(_DIR + "color_420.jpg", "r")
    var data = f.read_bytes()
    f.close()
    var half = List[UInt8]()
    for i in range(len(data) // 2):
        half.append(data[i])
    var raised = False
    try:
        _ = decode_jpeg(half^)
    except:
        raised = True
    assert_true(raised, "a file cut in half must raise")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
