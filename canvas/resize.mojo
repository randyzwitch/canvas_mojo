"""Box-filter downsampling: shrink a Canvas by an integer factor, each
output pixel the average of the corresponding factor x factor block of
input pixels.

This is the mechanism behind supersampled anti-aliasing -- render
`factor` times larger than the final size, then `downsample()` back --
so every output pixel averages `factor * factor` real source samples.
"""

from std.runtime.asyncrt import TaskGroup, parallelism_level

from canvas.buffer import Canvas, BYTES_PER_PIXEL

# Below this many *source* pixels read, the resize runs inline rather
# than dispatching tasks. Matches the fill sweep's threshold in
# canvas.aa_crossing; set by benchmark (#96).
comptime _MIN_PARALLEL_PIXELS = 40000


def downsample(source: Canvas, factor: Int) raises -> Canvas:
    """Shrink `source` by `factor`, which must evenly divide both
    `source.width` and `source.height` -- raises rather than truncating
    a partial edge block away. `factor=1` is a valid no-op copy, so a
    caller sweeping `factor` across several values needn't branch
    around 1.

    Each output pixel is the *rounded* mean (see the `+ n // 2` below)
    of its `factor x factor` source block, per channel. Alpha is
    averaged alongside r/g/b -- see the comment on `pixels` below for
    what that does and does not hold for.

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
    #
    # Sized up front and written by index rather than appended, because
    # appending is inherently sequential -- it is the order of the
    # calls that decides where a pixel lands. Indexing lets output rows
    # be computed independently, which is what the banding below needs.
    var pixels = List[UInt8](
        length=out_width * out_height * BYTES_PER_PIXEL, fill=0
    )

    # Output rows are the most independent loop in this package: each
    # reads a disjoint block of the source and writes its own slots,
    # with no shared scratch at all. So a large resize is split into
    # bands, one task per band.
    #
    # Only a large one -- see _MIN_PARALLEL_PIXELS. The threshold is on
    # *source* pixels read rather than output pixels written, since
    # that is what the work actually scales with: a factor-8
    # downsample writes very little but reads 64 pixels for each of
    # them.
    var bands = 1
    if out_width * out_height * n >= _MIN_PARALLEL_PIXELS:
        bands = parallelism_level()
        if bands > out_height:
            bands = out_height
        if bands < 1:
            bands = 1

    if bands == 1:
        _downsample_band(source, pixels, 0, out_height, out_width, factor, n)
        return Canvas(out_width, out_height, pixels^)

    var per_band = (out_height + bands - 1) // bands
    var tg = TaskGroup()
    for b in range(bands):
        var band_start = b * per_band
        var band_end = band_start + per_band
        if band_end > out_height:
            band_end = out_height
        if band_start >= band_end:
            continue
        tg.create_task(
            _downsample_band_async(
                source, pixels, band_start, band_end, out_width, factor, n
            )
        )
    tg.wait()
    return Canvas(out_width, out_height, pixels^)


async def _downsample_band_async(
    source: Canvas,
    mut pixels: List[UInt8],
    first_row: Int,
    last_row: Int,
    out_width: Int,
    factor: Int,
    n: Int,
):
    """`_downsample_band` as a task, so the single-band path stays an
    ordinary call with no coroutine machinery around it.
    """
    _downsample_band(source, pixels, first_row, last_row, out_width, factor, n)


def _downsample_band(
    source: Canvas,
    mut pixels: List[UInt8],
    first_row: Int,
    last_row: Int,
    out_width: Int,
    factor: Int,
    n: Int,
):
    """Average source blocks into output rows [first_row, last_row).

    Bands write disjoint output rows and only read the source, so no
    two ever touch the same byte -- which is the basis on which
    `pixels` is shared mutably between them.
    """
    for oy in range(first_row, last_row):
        var out_idx = oy * out_width * BYTES_PER_PIXEL
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
            pixels[out_idx] = UInt8((r_sum + n // 2) // n)
            pixels[out_idx + 1] = UInt8((g_sum + n // 2) // n)
            pixels[out_idx + 2] = UInt8((b_sum + n // 2) // n)
            pixels[out_idx + 3] = UInt8((a_sum + n // 2) // n)
            out_idx += BYTES_PER_PIXEL
