"""Compositing one canvas onto another: everything else in this package
draws *shapes* into a buffer, and this draws a buffer into a buffer.

Three things use it: layers, where each part of a figure is drawn onto
its own transparent canvas and composed in order; marker caching, where
one rasterized marker is stamped per point instead of re-filled; and
supersampling a region, where an area is rendered large, `downsample`d
and placed.

`draw_canvas` composites through the same straight-alpha src-over every
primitive uses (`Color.blend_over`), so a translucent source blends as a
translucent shape would and a transparent source pixel leaves the
destination untouched.
"""

from std.memory import unsafe_memcpy

from canvas.buffer import Canvas, BYTES_PER_PIXEL
from canvas.color import Color, _div255


def draw_canvas(mut dst: Canvas, src: Canvas, x: Int, y: Int):
    """Composite `src` onto `dst` with its top-left corner at (x, y).

    Clipped to `dst`'s bounds and to its active clip region -- both a
    rectangle clip and a clip path -- so a source hanging off an edge
    draws its visible part rather than raising or wrapping. Fully
    transparent source pixels leave the destination untouched.

    Args:
        dst: Canvas composited onto.
        src: Canvas to draw. Unchanged.
        x: Destination column for `src`'s left edge.
        y: Destination row for `src`'s top edge.
    """
    draw_canvas(dst, src, x, y, 255)


def draw_canvas(mut dst: Canvas, src: Canvas, x: Int, y: Int, opacity: UInt8):
    """`draw_canvas` with the whole source scaled to `opacity` first --
    the usual way a layer is faded, without having to have rendered it
    translucent in the first place.

    `opacity` multiplies each source pixel's own alpha, so a pixel
    already half-transparent in a layer drawn at half opacity ends up
    at a quarter. 255 leaves the source's alpha untouched and is what
    the three-argument overload passes.

    Args:
        dst: Canvas composited onto.
        src: Canvas to draw. Unchanged.
        x: Destination column for `src`'s left edge.
        y: Destination row for `src`'s top edge.
        opacity: Scales every source pixel's alpha, 255 for unchanged.
    """
    if opacity == 0:
        return

    # The overlapping rectangle in destination coordinates, already cut
    # to the canvas and the active clip -- the same intersection
    # set_pixel would apply one pixel at a time.
    var region = dst.effective_fill_rect(x, y, src.width, src.height)
    var rx = region[0]
    var ry = region[1]
    var rw = region[2]
    var rh = region[3]
    if rw <= 0 or rh <= 0:
        return

    var sp = src.pixels.unsafe_ptr()
    var src_stride = src.width * BYTES_PER_PIXEL
    var full = opacity == 255

    # A clip path modulates each pixel individually, which the direct
    # pointer writes below cannot express: `effective_fill_rect` folds
    # in the rectangle clip, since that is a range, but a path clip is a
    # per-pixel coverage value. Route through `set_pixel` while one is
    # pushed, the same fallback `Canvas._fill_region` and the gradient
    # rect fills in canvas.shapes.rects make -- see `Canvas.write_pixel`
    # for the contract. Nothing pays for this until a clip path exists.
    if dst.has_clip_mask():
        for row in range(rh):
            var s_idx = (ry + row - y) * src_stride + (rx - x) * BYTES_PER_PIXEL
            for col in range(rw):
                var sa = sp[unsafe_offset=s_idx + 3]
                var effective_a = sa
                if not full:
                    effective_a = UInt8(_div255(Int(sa) * Int(opacity)))
                if effective_a != 0:
                    dst.set_pixel(
                        rx + col,
                        ry + row,
                        Color(
                            sp[unsafe_offset=s_idx],
                            sp[unsafe_offset=s_idx + 1],
                            sp[unsafe_offset=s_idx + 2],
                            effective_a,
                        ),
                    )
                s_idx += BYTES_PER_PIXEL
        return

    var dp = dst.pixels.unsafe_ptr()
    var dst_stride = dst.width * BYTES_PER_PIXEL

    for row in range(rh):
        var s_idx = (ry + row - y) * src_stride + (rx - x) * BYTES_PER_PIXEL
        var d_idx = (ry + row) * dst_stride + rx * BYTES_PER_PIXEL
        for _ in range(rw):
            var sa = sp[unsafe_offset=s_idx + 3]
            if full and sa == 255:
                # Opaque source pixel at full opacity: the destination
                # is replaced outright, whatever its own alpha was.
                dp[unsafe_offset=d_idx] = sp[unsafe_offset=s_idx]
                dp[unsafe_offset=d_idx + 1] = sp[unsafe_offset=s_idx + 1]
                dp[unsafe_offset=d_idx + 2] = sp[unsafe_offset=s_idx + 2]
                dp[unsafe_offset=d_idx + 3] = 255
            elif sa != 0 or not full:
                var effective_a = sa
                if not full:
                    # Scaling by opacity/255 through the same exact
                    # division the blend itself uses, rather than a
                    # second approximation of it.
                    effective_a = UInt8(_div255(Int(sa) * Int(opacity)))
                if effective_a != 0:
                    var source = Color(
                        sp[unsafe_offset=s_idx],
                        sp[unsafe_offset=s_idx + 1],
                        sp[unsafe_offset=s_idx + 2],
                        effective_a,
                    )
                    var blended = source.blend_over(
                        Color(
                            dp[unsafe_offset=d_idx],
                            dp[unsafe_offset=d_idx + 1],
                            dp[unsafe_offset=d_idx + 2],
                            dp[unsafe_offset=d_idx + 3],
                        )
                    )
                    dp[unsafe_offset=d_idx] = blended.r
                    dp[unsafe_offset=d_idx + 1] = blended.g
                    dp[unsafe_offset=d_idx + 2] = blended.b
                    dp[unsafe_offset=d_idx + 3] = blended.a
            # sa == 0 at full opacity: fully transparent source, the
            # destination keeps whatever it had.
            s_idx += BYTES_PER_PIXEL
            d_idx += BYTES_PER_PIXEL
