"""Read and write uncompressed BMP files.

BMP is natively previewable by most editors (including VS Code's
built-in image preview) and OS file browsers, while still being
trivial to encode with nothing but stdlib byte I/O and no
compression.

`write_bmp` emits 24-bit BGR, bottom-up, rows padded to a 4-byte
boundary. `read_bmp` accepts 24-bit and 32-bit uncompressed
(BI_RGB) files in either row order, which covers what an editor or a
screenshot tool actually produces. Compressed variants (RLE4/RLE8),
palettized depths (1/4/8-bit) and the BI_BITFIELDS channel-mask forms
raise a clear error rather than misreading pixels -- the same scope
line `read_png` draws, and for the same reason.

BMP has no alpha in its 24-bit form, and its 32-bit form has a fourth
byte that is very often padding rather than a real alpha channel --
files written by tools that leave it zero would decode as fully
transparent if it were trusted. `read_bmp` therefore returns opaque
pixels always; a caller wanting real transparency should be using PNG,
which `canvas.io.png` reads and writes with a genuine alpha channel.
"""

from canvas.buffer import Canvas, BYTES_PER_PIXEL
from canvas.color import Color


def _put_u16(mut buf: List[UInt8], offset: Int, value: UInt16):
    var out = buf.unsafe_ptr()
    out[unsafe_offset=offset] = UInt8(value & 0xFF)
    out[unsafe_offset=offset + 1] = UInt8((value >> 8) & 0xFF)


def _put_u32(mut buf: List[UInt8], offset: Int, value: UInt32):
    var out = buf.unsafe_ptr()
    out[unsafe_offset=offset] = UInt8(value & 0xFF)
    out[unsafe_offset=offset + 1] = UInt8((value >> 8) & 0xFF)
    out[unsafe_offset=offset + 2] = UInt8((value >> 16) & 0xFF)
    out[unsafe_offset=offset + 3] = UInt8((value >> 24) & 0xFF)


def write_bmp(canvas: Canvas, path: String) raises:
    """Write `canvas` to `path` as an uncompressed 24-bit BMP.

    Args:
        canvas: Canvas to write.
        path: File path to write to.

    Raises:
        Error: `path` can't be opened for writing.
    """
    var w = canvas.width
    var h = canvas.height
    var row_size = ((w * 3 + 3) // 4) * 4  # rows padded to 4-byte multiples
    var pixel_data_size = row_size * h
    var file_size = 54 + pixel_data_size

    # Allocated at its final size, uninitialized, and written by index
    # rather than built with `.append()`. Every byte below is written
    # exactly once before `buf` is ever read (the `write_bytes` call at
    # the end), so nothing reads uninitialized memory -- `.append()`'s
    # own length bookkeeping and bounds-checked growth would only be
    # overhead here, since the final size is already known exactly.
    var buf = List[UInt8](unsafe_uninit_length=file_size)

    # BITMAPFILEHEADER (14 bytes)
    buf.unsafe_ptr()[unsafe_offset=0] = UInt8(ord("B"))
    buf.unsafe_ptr()[unsafe_offset=1] = UInt8(ord("M"))
    _put_u32(buf, 2, UInt32(file_size))
    _put_u32(buf, 6, 0)  # reserved
    _put_u32(buf, 10, 54)  # pixel data offset

    # BITMAPINFOHEADER (40 bytes)
    _put_u32(buf, 14, 40)
    _put_u32(buf, 18, UInt32(w))
    _put_u32(buf, 22, UInt32(h))
    _put_u16(buf, 26, 1)  # color planes
    _put_u16(buf, 28, 24)  # bits per pixel
    _put_u32(buf, 30, 0)  # compression: BI_RGB (none)
    _put_u32(buf, 34, UInt32(pixel_data_size))
    _put_u32(buf, 38, 2835)  # ~72 DPI, horizontal
    _put_u32(buf, 42, 2835)  # ~72 DPI, vertical
    _put_u32(buf, 46, 0)  # colors in palette (n/a)
    _put_u32(buf, 50, 0)  # important colors (n/a)

    var out = buf.unsafe_ptr()

    # Pixel data: bottom-up, BGR channel order, rows padded to a
    # 4-byte boundary. Reads `canvas.pixels` through its own pointer
    # rather than `get_pixel` or checked indexing -- the loop ranges
    # come from canvas.width/height, so every index on both sides is
    # already known in-bounds, and this is the single largest loop in
    # the function: get_pixel's in_bounds check, the Color it would
    # build only to destructure again, and a checked read on each side
    # are all pure overhead paid once per output byte.
    var src = canvas.pixels.unsafe_ptr()
    var pad = row_size - w * 3
    for y in range(h - 1, -1, -1):
        var row_start = y * w * BYTES_PER_PIXEL
        var dst_row = 54 + (h - 1 - y) * row_size
        for x in range(w):
            var si = row_start + x * BYTES_PER_PIXEL
            var di = dst_row + x * 3
            var a = src[unsafe_offset=si + 3]
            if a == 255:
                out[unsafe_offset=di] = src[unsafe_offset=si + 2]  # B
                out[unsafe_offset=di + 1] = src[unsafe_offset=si + 1]  # G
                out[unsafe_offset=di + 2] = src[unsafe_offset=si]  # R
            else:
                # 24-bit BMP has nowhere to put alpha, so a translucent
                # pixel is composited onto white before it is written.
                # Writing the stored colour instead would render a
                # transparent region as whatever colour happened to sit
                # underneath the transparency -- black, for a canvas
                # cleared to Color(0, 0, 0, 0) -- which is not what
                # anyone means by a transparent background.
                #
                # White specifically because it is `Canvas`'s own
                # default background, so a translucent render flattened
                # to BMP matches the same render onto an opaque white
                # canvas. `write_png` needs none of this: it emits a
                # real alpha channel.
                var flat = Color(
                    src[unsafe_offset=si],
                    src[unsafe_offset=si + 1],
                    src[unsafe_offset=si + 2],
                    a,
                ).blend_over(Color(255, 255, 255))
                out[unsafe_offset=di] = flat.b
                out[unsafe_offset=di + 1] = flat.g
                out[unsafe_offset=di + 2] = flat.r
        # Padding bytes are never written -- `unsafe_uninit_length`
        # leaves them as whatever memory already held, not zero. BMP's
        # own spec allows any value in row padding (readers must skip
        # it, not interpret it), but this package's own output should
        # not depend on that leniency, so they are zeroed explicitly.
        for p in range(pad):
            out[unsafe_offset=dst_row + w * 3 + p] = 0

    var f = open(path, "w")
    f.write_bytes(Span(buf))
    f.close()


def _read_u16_le(data: List[UInt8], pos: Int) raises -> Int:
    if pos + 2 > len(data):
        raise Error("bmp: truncated file (wanted 2 bytes for a u16)")
    return Int(data[pos]) | (Int(data[pos + 1]) << 8)


def _read_u32_le(data: List[UInt8], pos: Int) raises -> Int:
    if pos + 4 > len(data):
        raise Error("bmp: truncated file (wanted 4 bytes for a u32)")
    return (
        Int(data[pos])
        | (Int(data[pos + 1]) << 8)
        | (Int(data[pos + 2]) << 16)
        | (Int(data[pos + 3]) << 24)
    )


def _read_i32_le(data: List[UInt8], pos: Int) raises -> Int:
    """A signed 32-bit little-endian field. BMP stores image height
    this way, and the sign carries real meaning: negative means the
    rows are stored top-down instead of BMP's usual bottom-up.
    """
    var raw = _read_u32_le(data, pos)
    if raw >= 0x80000000:
        return raw - 0x100000000
    return raw


def read_bmp(path: String) raises -> Canvas:
    """Read an uncompressed 24- or 32-bit BMP into a new Canvas.

    The counterpart to `write_bmp`.

    Handles both row orders. BMP conventionally stores rows
    bottom-up, which is what `write_bmp` emits, but a negative height
    field means top-down and several common tools write that -- reading
    only one order would silently return vertically mirrored images
    from the other.

    Every returned pixel is opaque; see this module's docstring for why
    a 32-bit file's fourth byte is not trusted as alpha.

    Args:
        path: File to read.

    Returns:
        A Canvas holding the decoded image.

    Raises:
        Error: The file is missing, truncated, not a BMP, or uses a
            compression or bit depth outside the supported set.
    """
    var f = open(path, "r")
    var data = f.read_bytes()
    f.close()

    if len(data) < 54:
        raise Error(
            "bmp: file is too short to hold a header (got "
            + String(len(data))
            + " bytes, need at least 54)"
        )
    if data[0] != 0x42 or data[1] != 0x4D:
        raise Error("bmp: missing 'BM' signature -- not a BMP file")

    var pixel_offset = _read_u32_le(data, 10)
    var dib_size = _read_u32_le(data, 14)
    if dib_size < 40:
        raise Error(
            "bmp: unsupported DIB header size "
            + String(dib_size)
            + " (only BITMAPINFOHEADER and later, 40+, are supported)"
        )

    var width = _read_i32_le(data, 18)
    var raw_height = _read_i32_le(data, 22)
    var bpp = _read_u16_le(data, 28)
    var compression = _read_u32_le(data, 30)

    if width <= 0:
        raise Error("bmp: non-positive width " + String(width))
    if raw_height == 0:
        raise Error("bmp: zero height")
    # Negative height is the top-down flag, not an error.
    var top_down = raw_height < 0
    var height = -raw_height if top_down else raw_height

    if compression != 0:
        raise Error(
            "bmp: unsupported compression "
            + String(compression)
            + " (only BI_RGB, uncompressed, is supported)"
        )
    if bpp != 24 and bpp != 32:
        raise Error(
            "bmp: unsupported bit depth "
            + String(bpp)
            + " (only 24- and 32-bit uncompressed BMPs are supported)"
        )

    var channels = bpp // 8
    var row_size = ((width * channels + 3) // 4) * 4
    var needed = pixel_offset + row_size * height
    if len(data) < needed:
        raise Error(
            "bmp: truncated pixel data (need "
            + String(needed)
            + " bytes, file is "
            + String(len(data))
            + ")"
        )

    # Built as a buffer and handed to the (width, height, pixels)
    # constructor rather than written pixel by pixel: decoding is a
    # replace, not a draw, so it must not go through the compositing
    # `write_pixel` -- the same reasoning `read_png` records.
    var pixels = List[UInt8](capacity=width * height * BYTES_PER_PIXEL)
    var src = data.unsafe_ptr()
    for y in range(height):
        # Bottom-up files store the last image row first.
        var src_row = y if top_down else (height - 1 - y)
        var row_start = pixel_offset + src_row * row_size
        for x in range(width):
            var i = row_start + x * channels
            pixels.append(src[unsafe_offset=i + 2])  # R (stored BGR)
            pixels.append(src[unsafe_offset=i + 1])  # G
            pixels.append(src[unsafe_offset=i])  # B
            pixels.append(255)
    return Canvas(width, height, pixels^)
