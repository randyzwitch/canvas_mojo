"""Box-filter downsampling -- shrink a Canvas by an integer factor,
each output pixel the average of the corresponding factor x factor
block of input pixels. This is the actual mechanism behind
supersampled anti-aliasing: render `factor` times larger than the
intended final size, then `downsample()` back to it, and every output
pixel averages `factor * factor` real source samples instead of one.
The result has the same pixel dimensions as an unsupersampled render,
with finer edges baked into the file rather than left to whatever
displays it.
"""

from canvas.buffer import Canvas, BYTES_PER_PIXEL


def downsample(source: Canvas, factor: Int) raises -> Canvas:
    """Shrink `source` by `factor`, which must evenly divide both
    `source.width` and `source.height` -- raises rather than truncating
    a partial edge block away. `factor=1` is a valid no-op copy, so a
    caller sweeping `factor` across several values needn't branch
    around 1.

    Each output pixel is the *rounded* mean (see the `+ n // 2` below)
    of its `factor x factor` source block, per r/g/b channel. Alpha
    isn't involved: Canvas stores none per pixel.

    Args:
        source: Canvas to shrink.
        factor: Integer shrink factor; must evenly divide both
            `source.width` and `source.height`.

    Returns:
        A new canvas, `source.width // factor` by
        `source.height // factor`.

    Raises:
        Error: `factor` isn't positive, or doesn't evenly divide
            `source`'s dimensions.
    """
    if factor <= 0:
        raise Error(
            "downsample(): factor must be positive (got " + String(factor) + ")"
        )
    if source.width % factor != 0 or source.height % factor != 0:
        raise Error(
            "downsample(): factor ("
            + String(factor)
            + ") must evenly divide both width ("
            + String(source.width)
            + ") and height ("
            + String(source.height)
            + ")"
        )

    var out_width = source.width // factor
    var out_height = source.height // factor
    var n = factor * factor

    # Built via append in the row-major (y outer, x inner, R-G-B) order
    # Canvas's pixels buffer uses. Every output pixel is computed here
    # and written once, so set_pixel's in_bounds/in_clip checks -- both
    # always true on a fresh clip-free canvas -- would add nothing, and
    # the (width, height, pixels) constructor skips the solid fill a
    # plain Canvas() would immediately overwrite.
    var pixels = List[UInt8](capacity=out_width * out_height * BYTES_PER_PIXEL)
    # Every coordinate below comes from out_width/out_height times
    # `factor`, which is how the output dimensions were derived, so
    # each read is on-canvas by construction -- see Canvas.read_pixel.
    #
    # Alpha is averaged alongside the colour channels. That is the
    # right answer for the case this exists for -- supersample at 2x,
    # downsample to 1x -- where a block straddling a shape's edge on a
    # transparent background should come out partly transparent, in
    # exactly the proportion of the block the shape covered.
    #
    # It is *not* correct in general: averaging straight (rather than
    # premultiplied) colour lets a fully transparent pixel's colour
    # bleed into the result. For a downsample of a rendered image that
    # is harmless, since a transparent pixel here carries the
    # background colour it was initialised with rather than arbitrary
    # data. Worth knowing before reusing this on an arbitrary RGBA
    # image.
    for oy in range(out_height):
        for ox in range(out_width):
            var r_sum = 0
            var g_sum = 0
            var b_sum = 0
            var a_sum = 0
            for dy in range(factor):
                for dx in range(factor):
                    var p = source.read_pixel(
                        ox * factor + dx, oy * factor + dy
                    )
                    r_sum += Int(p.r)
                    g_sum += Int(p.g)
                    b_sum += Int(p.b)
                    a_sum += Int(p.a)
            pixels.append(UInt8((r_sum + n // 2) // n))
            pixels.append(UInt8((g_sum + n // 2) // n))
            pixels.append(UInt8((b_sum + n // 2) // n))
            pixels.append(UInt8((a_sum + n // 2) // n))
    return Canvas(out_width, out_height, pixels^)
