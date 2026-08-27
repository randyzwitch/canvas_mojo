"""Write a Canvas out as an uncompressed 24-bit BMP file.

BMP is natively previewable by most editors (including VS Code's
built-in image preview) and OS file browsers, while still being
trivial to encode with nothing but stdlib byte I/O and no
compression.
"""

from canvas_mojo.buffer import Canvas


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
        var row_start = y * w * 3
        var dst_row = 54 + (h - 1 - y) * row_size
        for x in range(w):
            var si = row_start + x * 3
            var di = dst_row + x * 3
            out[unsafe_offset=di] = src[unsafe_offset=si + 2]  # B
            out[unsafe_offset=di + 1] = src[unsafe_offset=si + 1]  # G
            out[unsafe_offset=di + 2] = src[unsafe_offset=si]  # R
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
