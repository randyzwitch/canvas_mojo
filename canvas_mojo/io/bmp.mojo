"""Write a Canvas out as an uncompressed 24-bit BMP file.

BMP is natively previewable by most editors (including VS Code's
built-in image preview) and OS file browsers, while still being
trivial to encode with nothing but stdlib byte I/O and no
compression.
"""

from canvas_mojo.buffer import Canvas


def _append_u16_le(mut buf: List[UInt8], value: UInt16):
    buf.append(UInt8(value & 0xFF))
    buf.append(UInt8((value >> 8) & 0xFF))


def _append_u32_le(mut buf: List[UInt8], value: UInt32):
    buf.append(UInt8(value & 0xFF))
    buf.append(UInt8((value >> 8) & 0xFF))
    buf.append(UInt8((value >> 16) & 0xFF))
    buf.append(UInt8((value >> 24) & 0xFF))


def write_bmp(canvas: Canvas, path: String) raises:
    var w = canvas.width
    var h = canvas.height
    var row_size = ((w * 3 + 3) // 4) * 4  # rows padded to 4-byte multiples
    var pixel_data_size = row_size * h
    var file_size = 54 + pixel_data_size

    var buf = List[UInt8](capacity=file_size)

    # BITMAPFILEHEADER (14 bytes)
    buf.append(UInt8(ord("B")))
    buf.append(UInt8(ord("M")))
    _append_u32_le(buf, UInt32(file_size))
    _append_u32_le(buf, 0)  # reserved
    _append_u32_le(buf, 54)  # pixel data offset

    # BITMAPINFOHEADER (40 bytes)
    _append_u32_le(buf, 40)
    _append_u32_le(buf, UInt32(w))
    _append_u32_le(buf, UInt32(h))
    _append_u16_le(buf, 1)  # color planes
    _append_u16_le(buf, 24)  # bits per pixel
    _append_u32_le(buf, 0)  # compression: BI_RGB (none)
    _append_u32_le(buf, UInt32(pixel_data_size))
    _append_u32_le(buf, 2835)  # ~72 DPI, horizontal
    _append_u32_le(buf, 2835)  # ~72 DPI, vertical
    _append_u32_le(buf, 0)  # colors in palette (n/a)
    _append_u32_le(buf, 0)  # important colors (n/a)

    # Pixel data: stored bottom-up, channel order BGR, rows padded to
    # a 4-byte boundary. Reads straight from canvas.pixels by index
    # rather than through canvas.get_pixel -- every (x, y) here is
    # already known in-bounds (the loop ranges come straight from
    # canvas.width/height), so get_pixel's own in_bounds check and the
    # Color it constructs just to immediately destructure back into
    # three bytes are both pure overhead a whole-image write pays once
    # per pixel for nothing. Can't bulk-copy a whole row the way
    # png.mojo's own write_png does (RGB source, BGR destination --
    # every pixel's own byte order has to actually flip), but this
    # still drops the per-pixel bounds check and struct-construction.
    var pad = row_size - w * 3
    for y in range(h - 1, -1, -1):
        var row_start = y * w * 3
        for x in range(w):
            var idx = row_start + x * 3
            buf.append(canvas.pixels[idx + 2])  # B
            buf.append(canvas.pixels[idx + 1])  # G
            buf.append(canvas.pixels[idx])  # R
        for _ in range(pad):
            buf.append(0)

    var f = open(path, "w")
    f.write_bytes(Span(buf))
    f.close()
