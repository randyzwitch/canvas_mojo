"""Decoder tests for Adam7 interlacing and 16-bit samples, against
fixtures under `tests/png/`.

The fixtures were written by a from-scratch Python encoder using only
`zlib` and `struct` -- no Pillow, and nothing from this package -- so
agreement is evidence rather than a tautology. Each row is filtered
with a different one of the five filter types, cycling, and each
Adam7 pass starts the cycle at its own index, so between them the
files exercise every reconstruction formula on both interlaced and
plain rows. Pillow then read every fixture back as an independent
check: it decodes each `_adam7` file to exactly the pixels of its
`_plain` twin, and honours both transparency keys.

To regenerate: write the IHDR/PLTE/tRNS/IDAT/IEND chunks by hand with
`zlib.crc32` and `zlib.compress`; for an interlaced file, emit the
seven Adam7 passes (origins (0,0) (4,0) (0,4) (2,0) (0,2) (1,0) (0,1)
with strides (8,8) (8,8) (4,8) (4,4) (2,4) (2,2) (1,2)) one after
another into a single stream, skipping any pass whose width or height
rounds to zero.

The `_plain`/`_adam7` pairs hold identical pixel data, which is the
property the interlacing test rests on: de-interlacing is correct
exactly when the two decode the same. The 16-bit values were picked so
that rounding and truncation disagree -- 65280 reduces to 254 rounded
and 255 truncated, 129 to 1 and 0 -- and the 16-bit key sits one level
from a neighbour that reduces to the same 8-bit color, so a decoder
comparing after reduction would clear an opaque pixel too.
"""

from std.testing import assert_equal, assert_true, TestSuite

from canvas.buffer import Canvas
from canvas.io.png import read_png

comptime _DIR = "tests/png/"


def _assert_same(got: Canvas, want: Canvas, label: String) raises:
    assert_equal(got.width, want.width, label + " width")
    assert_equal(got.height, want.height, label + " height")
    for y in range(want.height):
        for x in range(want.width):
            var g = got.get_pixel(x, y)
            var w = want.get_pixel(x, y)
            var at = String(label, " at (", x, ", ", y, ")")
            assert_equal(g.r, w.r, at + " r")
            assert_equal(g.g, w.g, at + " g")
            assert_equal(g.b, w.b, at + " b")
            assert_equal(g.a, w.a, at + " a")


def _assert_rgba(
    canvas: Canvas, x: Int, y: Int, r: Int, g: Int, b: Int, a: Int
) raises:
    var px = canvas.get_pixel(x, y)
    var at = String("(", x, ", ", y, ")")
    assert_equal(Int(px.r), r, at + " r")
    assert_equal(Int(px.g), g, at + " g")
    assert_equal(Int(px.b), b, at + " b")
    assert_equal(Int(px.a), a, at + " a")


def _raises(path: String) raises -> Bool:
    try:
        var c = read_png(path)
        _ = c
        return False
    except:
        return True


def test_adam7_decodes_to_its_non_interlaced_twin() raises:
    """The six pairs hold the same pixels in the two layouts, so any
    de-interlacing error shows up as a mismatch. Between them they
    cover truecolor, grayscale, RGBA, 16-bit and 4-bit indexed, and
    sizes that leave later passes empty.
    """
    var names: List[String] = [
        "i13x9_rgba8",
        "i1x1_rgb8",
        "i5x3_rgb8",
        "i9x9_gray8",
        "i7x6_rgb16",
        "i11x5_idx4",
    ]
    for i in range(len(names)):
        ref name = names[i]
        var plain = read_png(_DIR + name + "_plain.png")
        var adam7 = read_png(_DIR + name + "_adam7.png")
        _assert_same(adam7, plain, name)


def test_adam7_one_pixel_image_uses_only_the_first_pass() raises:
    """A 1x1 image puts its single pixel in pass 1; the other six are
    empty and contribute no filter byte at all. Reading one would
    desynchronize the stream, so this is the case that catches it.
    """
    var c = read_png(_DIR + "i1x1_rgb8_adam7.png")
    assert_equal(c.width, 1)
    assert_equal(c.height, 1)
    _assert_rgba(c, 0, 0, 200, 100, 50, 255)


def test_adam7_five_by_three_leaves_later_passes_empty() raises:
    """5x3: pass 2 has one column, pass 3 no rows (its y origin is 4),
    pass 7 three columns. Spot-checked against the plain twin's own
    pixel values, which the generator computed as
    ((x * 50) % 256, (y * 80) % 256, (x + y) * 20).
    """
    var c = read_png(_DIR + "i5x3_rgb8_adam7.png")
    assert_equal(c.width, 5)
    assert_equal(c.height, 3)
    _assert_rgba(c, 0, 0, 0, 0, 0, 255)
    _assert_rgba(c, 4, 0, 200, 0, 80, 255)
    _assert_rgba(c, 2, 2, 100, 160, 80, 255)
    _assert_rgba(c, 4, 2, 200, 160, 120, 255)


def test_sixteen_bit_gray_rounds_rather_than_truncating() raises:
    """`round(v * 255 / 65535)`, not the high byte. 65280 is the case
    that separates them: 65280 * 255 / 65535 is 254.004, so it rounds
    to 254, while its high byte is 255. 129 is the other: 0.502 rounds
    to 1 where the high byte is 0.
    """
    var c = read_png(_DIR + "gray16.png")
    assert_equal(c.width, 4)
    assert_equal(c.height, 3)
    _assert_rgba(c, 0, 0, 0, 0, 0, 255)  # 0
    _assert_rgba(c, 1, 0, 255, 255, 255, 255)  # 65535
    _assert_rgba(c, 2, 0, 254, 254, 254, 255)  # 65280, not 255
    _assert_rgba(c, 3, 0, 128, 128, 128, 255)  # 32768
    _assert_rgba(c, 0, 1, 1, 1, 1, 255)  # 257 = 1 * 257 exactly
    _assert_rgba(c, 1, 1, 0, 0, 0, 255)  # 128 -> 0.498
    _assert_rgba(c, 2, 1, 1, 1, 1, 255)  # 129 -> 0.502, not 0
    _assert_rgba(c, 1, 2, 255, 255, 255, 255)  # 65534


def test_sixteen_bit_rgb_reduces_each_channel() raises:
    var c = read_png(_DIR + "rgb16.png")
    _assert_rgba(c, 0, 0, 0, 255, 128, 255)
    _assert_rgba(c, 1, 0, 1, 2, 3, 255)
    _assert_rgba(c, 2, 0, 254, 0, 1, 255)
    _assert_rgba(c, 2, 1, 0, 0, 0, 255)


def test_sixteen_bit_gray_alpha_reduces_both() raises:
    var c = read_png(_DIR + "graya16.png")
    _assert_rgba(c, 0, 0, 0, 0, 0, 255)
    _assert_rgba(c, 1, 0, 255, 255, 255, 0)
    _assert_rgba(c, 2, 0, 128, 128, 128, 128)
    _assert_rgba(c, 0, 1, 1, 1, 1, 2)
    _assert_rgba(c, 2, 1, 254, 254, 254, 1)


def test_sixteen_bit_rgba_reduces_every_channel() raises:
    var c = read_png(_DIR + "rgba16.png")
    _assert_rgba(c, 0, 0, 0, 255, 128, 255)
    _assert_rgba(c, 1, 0, 1, 2, 3, 0)
    _assert_rgba(c, 2, 0, 254, 0, 1, 128)
    _assert_rgba(c, 0, 1, 0, 0, 0, 1)
    _assert_rgba(c, 1, 1, 255, 0, 0, 255)
    _assert_rgba(c, 2, 1, 0, 0, 255, 0)


def test_sixteen_bit_key_is_compared_before_reduction() raises:
    """The key is (1000, 2000, 3000) and pixel (1, 0) is
    (1001, 2000, 3000) -- one level away. Both reduce to (4, 8, 12),
    so a decoder that compared the 8-bit result would clear the alpha
    of a pixel the file means to be opaque. Only (0, 0) is keyed.
    """
    var c = read_png(_DIR + "rgb16_key.png")
    _assert_rgba(c, 0, 0, 4, 8, 12, 0)
    _assert_rgba(c, 1, 0, 4, 8, 12, 255)
    _assert_rgba(c, 0, 1, 0, 0, 0, 255)
    _assert_rgba(c, 1, 1, 0, 0, 0, 255)


def test_eight_bit_truecolor_key_clears_matching_pixels() raises:
    var c = read_png(_DIR + "rgb8_key.png")
    _assert_rgba(c, 0, 0, 10, 20, 30, 0)
    _assert_rgba(c, 1, 0, 40, 50, 60, 255)
    _assert_rgba(c, 0, 1, 10, 20, 30, 0)
    _assert_rgba(c, 1, 1, 0, 0, 0, 255)


def test_eight_bit_grayscale_key_clears_matching_pixels() raises:
    var c = read_png(_DIR + "gray8_key.png")
    _assert_rgba(c, 0, 0, 0, 0, 0, 255)
    _assert_rgba(c, 1, 0, 128, 128, 128, 0)
    _assert_rgba(c, 0, 1, 255, 255, 255, 255)
    _assert_rgba(c, 1, 1, 128, 128, 128, 0)


def test_truncated_adam7_stream_raises() raises:
    """Forty bytes short of the compressed stream. The failure has to
    come out as an error, not as a short read that leaves later passes
    scattering garbage into the image.
    """
    assert_true(_raises(_DIR + "adam7_truncated.png"))


def test_unknown_interlace_method_raises() raises:
    """The spec defines methods 0 and 1 only. Pillow reads this file
    as if it were not interlaced; here it raises, since guessing would
    return an image whose pixels are in the wrong places.
    """
    assert_true(_raises(_DIR + "bad_interlace.png"))


def test_sixteen_bit_indexed_raises() raises:
    """Palette indices have no 16-bit form. The header declares one,
    and the decoder rejects it before reading a pixel.
    """
    assert_true(_raises(_DIR + "idx16.png"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
