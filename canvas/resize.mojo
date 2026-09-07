"""Box-filter downsampling: shrink a Canvas by an integer factor, each
output pixel the average of the corresponding factor x factor block of
input pixels.

This is the mechanism behind supersampled anti-aliasing -- render
`factor` times larger than the final size, then `downsample()` back --
so every output pixel averages `factor * factor` real source samples.
"""

from std.runtime.asyncrt import TaskGroup

from canvas.buffer import Canvas, BYTES_PER_PIXEL
from canvas.workers import _bands_for

# Below this many *source* pixels read, the resize runs inline rather
# than dispatching tasks. Matches the fill sweep's threshold in
# canvas.aa_crossing; set by benchmark (#96).
comptime _MIN_PARALLEL_PIXELS = 40000


# Source samples read worth one downsampling task -- samples, not
# output pixels, since a factor-8 pass writes little and reads 64
# pixels for each of them. A 1600x1200 factor-2 pass improves through
# 32 bands (7527 us at one worker, 769 at thirty-two, 813 at
# sixty-four). See `canvas.workers`.
comptime _RESIZE_SAMPLES_PER_BAND = 60000


def downsample(source: Canvas, factor: Int) raises -> Canvas:
    """Shrink `source` by `factor`, which must evenly divide both
    `source.width` and `source.height` -- raises rather than truncating
    a partial edge block away. `factor=1` is a valid no-op copy, so a
    caller sweeping `factor` across several values needn't branch
    around 1.

    Alpha is the rounded mean of the source block. Color is averaged
    with alpha weights and returned as straight RGBA, so transparent
    samples do not darken a shape's edge or contribute hidden color.
    A block whose alpha rounds to zero becomes transparent black.
    Factor 1 copies every byte, including color under zero alpha.

    Supersampling with it: pixel (px, py) is centered at (px, py), and
    output pixel p averages source pixels `factor * p` through
    `factor * p + factor - 1`, whose center is `factor * p +
    (factor - 1) / 2`. A drawing scaled by `factor` alone therefore
    shows up `(factor - 1) / (2 * factor)` px early after the shrink --
    3/8 px at 4 -- for every primitive. Translate by `(factor - 1) / 2`
    before the scale and it lands where a scale-1 drawing does:

        big.translate((f - 1) / 2, (f - 1) / 2)
        big.scale(f, f)
        ... draw ...
        var out = downsample(big, f)

    The recipe places every primitive, `Int` rects included, where a
    factor-1 drawing places it (within about 0.01 px for circles,
    ellipses, lines, paths, and text). Output is not byte-identical
    across factors: antialiased edges legitimately differ between a
    supersampled render and a plain one.

    The recipe moves geometry, not snapping. `fill_rect` snaps its
    edges in *device* space after the transform, so a fractional
    logical edge that resolves to one gray column at factor 1 resolves
    to `factor` finer steps instead, and that edge stops matching the
    factor-1 output. A caller who wants hard edges under supersampling
    snaps each edge to the nearest half-integer in logical space before
    drawing, and derives the size from the two snapped edges rather
    than snapping a position and a size separately, which lets two
    rounding errors accumulate in the width. Every factor then
    produces the same crisp edge in the same place. Lines, paths, and
    text are never snapped and need nothing.

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

    if factor == 1:
        return Canvas(source.width, source.height, source.pixels.copy())

    var out_width = source.width // factor
    var out_height = source.height // factor
    var n = factor * factor

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
    var bands = _bands_for(
        out_width * out_height * n,
        out_height,
        _RESIZE_SAMPLES_PER_BAND,
        source.max_workers(),
    )

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

    Factors 2 and 4 take kernels with the block size known at compile
    time, which is what lets the sample loops unroll and the divisor
    become a shift. Every other factor takes the general path below,
    and factor 1 is an exact copy either way.
    """
    if factor == 2:
        _downsample_band_fixed[2](
            source, pixels, first_row, last_row, out_width
        )
        return
    if factor == 4:
        _downsample_band_fixed[4](
            source, pixels, first_row, last_row, out_width
        )
        return
    _downsample_band_general(
        source, pixels, first_row, last_row, out_width, factor, n
    )


# Eight pixels' worth of alpha lanes: OR this in and an all-255 vector
# means every one of the eight alphas was 255.
# ...and the complement, for the opposite question: AND this in and a
# zero vector means every one of the eight alphas was zero.
comptime _ALPHA_ONLY32 = SIMD[DType.uint8, 32](
    0,
    0,
    0,
    255,
    0,
    0,
    0,
    255,
    0,
    0,
    0,
    255,
    0,
    0,
    0,
    255,
    0,
    0,
    0,
    255,
    0,
    0,
    0,
    255,
    0,
    0,
    0,
    255,
    0,
    0,
    0,
    255,
)
comptime _NOT_ALPHA32 = SIMD[DType.uint8, 32](
    255,
    255,
    255,
    0,
    255,
    255,
    255,
    0,
    255,
    255,
    255,
    0,
    255,
    255,
    255,
    0,
    255,
    255,
    255,
    0,
    255,
    255,
    255,
    0,
    255,
    255,
    255,
    0,
    255,
    255,
    255,
    0,
)


def _downsample_band_fixed[
    factor: Int
](
    source: Canvas,
    mut pixels: List[UInt8],
    first_row: Int,
    last_row: Int,
    out_width: Int,
):
    """`_downsample_band` for a block size known at compile time.

    A block whose samples are all opaque -- which is most of an opaque
    image, and all of one with no alpha at all -- needs no alpha
    weighting: with every alpha at 255 the weighted mean reduces to
    the plain one, because `(255*S + 255*n/2) / (255*n)` is
    `(S + n/2) / n` exactly, numerator and denominator sharing the
    factor of 255. And `n` here is 4 or 16, so that division is a
    shift. The three divisions by a varying alpha sum are a third of
    what a factor-2 pass spends, and this takes them off every block
    that does not straddle a shape's edge.

    At factor 2 such a run also goes four output pixels at a time.
    Mixed-alpha blocks fall back to the weighted form, which is the
    arithmetic the general path does, so an edge pixel is unchanged.
    """
    comptime N = factor * factor
    comptime HALF = N // 2
    comptime SHIFT = 2 if factor == 2 else 4
    var sp = source.pixels.unsafe_ptr()
    var op = pixels.unsafe_ptr()
    var src_stride = source.width * BYTES_PER_PIXEL
    var block_bytes = factor * BYTES_PER_PIXEL
    for oy in range(first_row, last_row):
        var out_idx = oy * out_width * BYTES_PER_PIXEL
        var row_base = oy * factor * src_stride
        var ox = 0
        while ox < out_width:
            var take = 1

            comptime if factor == 2:
                # Four output pixels at a time: eight source pixels
                # from each of two rows, thirty-two bytes each. Where
                # all sixteen samples are opaque the group is a widen,
                # a row add, a pairwise fold and a shift, and the
                # sixteen result bytes go out in one store.
                if ox + 4 <= out_width:
                    var top = sp.unsafe_offset(
                        row_base + ox * block_bytes
                    ).unsafe_load[width=32]()
                    var bot = sp.unsafe_offset(
                        row_base + src_stride + ox * block_bytes
                    ).unsafe_load[width=32]()
                    if (top | _NOT_ALPHA32).reduce_min() == 255 and (
                        bot | _NOT_ALPHA32
                    ).reduce_min() == 255:
                        var rows = (
                            top.cast[DType.uint16]() + bot.cast[DType.uint16]()
                        )
                        var left = rows.shuffle[
                            0,
                            1,
                            2,
                            3,
                            8,
                            9,
                            10,
                            11,
                            16,
                            17,
                            18,
                            19,
                            24,
                            25,
                            26,
                            27,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                        ]().slice[16, offset=0]()
                        var right = rows.shuffle[
                            4,
                            5,
                            6,
                            7,
                            12,
                            13,
                            14,
                            15,
                            20,
                            21,
                            22,
                            23,
                            28,
                            29,
                            30,
                            31,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                        ]().slice[16, offset=0]()
                        var mean = (
                            (left + right + SIMD[DType.uint16, 16](HALF))
                            >> UInt16(SHIFT)
                        ).cast[DType.uint8]()
                        op.unsafe_offset(out_idx).unsafe_store(mean)
                        ox += 4
                        out_idx += 4 * BYTES_PER_PIXEL
                        continue
                    if (top & _ALPHA_ONLY32).reduce_or() == 0 and (
                        bot & _ALPHA_ONLY32
                    ).reduce_or() == 0:
                        # Nothing to average. Every sample is
                        # transparent, so the output alpha rounds to
                        # zero and the four pixels are canonical
                        # transparent black -- which a layer drawn on a
                        # transparent ground is mostly made of.
                        op.unsafe_offset(out_idx).unsafe_store(
                            SIMD[DType.uint8, 16](0)
                        )
                        ox += 4
                        out_idx += 4 * BYTES_PER_PIXEL
                        continue
                    # A group that is neither takes the pixel path
                    # below, all four of it, rather than being tested
                    # again once per pixel.
                    take = 4

            for _ in range(take):
                var block = row_base + ox * block_bytes
                var r_sum = 0
                var g_sum = 0
                var b_sum = 0
                var a_sum = 0
                var opaque = True
                for dy in range(factor):
                    var i = block + dy * src_stride
                    for _ in range(factor):
                        var a = Int(sp[unsafe_offset=i + 3])
                        r_sum += Int(sp[unsafe_offset=i])
                        g_sum += Int(sp[unsafe_offset=i + 1])
                        b_sum += Int(sp[unsafe_offset=i + 2])
                        a_sum += a
                        if a != 255:
                            opaque = False
                        i += BYTES_PER_PIXEL
                if opaque:
                    op[unsafe_offset=out_idx] = UInt8((r_sum + HALF) >> SHIFT)
                    op[unsafe_offset=out_idx + 1] = UInt8(
                        (g_sum + HALF) >> SHIFT
                    )
                    op[unsafe_offset=out_idx + 2] = UInt8(
                        (b_sum + HALF) >> SHIFT
                    )
                    op[unsafe_offset=out_idx + 3] = 255
                else:
                    var alpha = (a_sum + HALF) >> SHIFT
                    # A block faint enough that the output alpha rounds
                    # to zero is canonical transparent black, so
                    # nothing divides by an alpha sum that rounded away.
                    if alpha == 0:
                        op[unsafe_offset=out_idx] = 0
                        op[unsafe_offset=out_idx + 1] = 0
                        op[unsafe_offset=out_idx + 2] = 0
                    else:
                        # Weighted again, by each sample's own alpha.
                        var wr = 0
                        var wg = 0
                        var wb = 0
                        for dy in range(factor):
                            var i = block + dy * src_stride
                            for _ in range(factor):
                                var a = Int(sp[unsafe_offset=i + 3])
                                wr += Int(sp[unsafe_offset=i]) * a
                                wg += Int(sp[unsafe_offset=i + 1]) * a
                                wb += Int(sp[unsafe_offset=i + 2]) * a
                                i += BYTES_PER_PIXEL
                        var half_a = a_sum // 2
                        op[unsafe_offset=out_idx] = UInt8(
                            (wr + half_a) // a_sum
                        )
                        op[unsafe_offset=out_idx + 1] = UInt8(
                            (wg + half_a) // a_sum
                        )
                        op[unsafe_offset=out_idx + 2] = UInt8(
                            (wb + half_a) // a_sum
                        )
                    op[unsafe_offset=out_idx + 3] = UInt8(alpha)
                ox += 1
                out_idx += BYTES_PER_PIXEL


def _downsample_band_general(
    source: Canvas,
    mut pixels: List[UInt8],
    first_row: Int,
    last_row: Int,
    out_width: Int,
    factor: Int,
    n: Int,
):
    """`_downsample_band` for any factor, with the block size known
    only at run time.
    """
    # The sample count is fixed for the band. Power-of-two factors
    # allow alpha averaging by a shift; color uses the unrounded alpha
    # sum so rounding output alpha never changes the color weights.
    var half = n // 2
    var shift = 0
    var probe = n
    while probe > 1 and probe & 1 == 0:
        probe >>= 1
        shift += 1
    var pow2 = probe == 1
    var sp = source.pixels.unsafe_ptr()
    var op = pixels.unsafe_ptr()
    var src_stride = source.width * BYTES_PER_PIXEL
    var block_bytes = factor * BYTES_PER_PIXEL
    for oy in range(first_row, last_row):
        var out_idx = oy * out_width * BYTES_PER_PIXEL
        var row_base = oy * factor * src_stride
        for ox in range(out_width):
            var r_sum = 0
            var g_sum = 0
            var b_sum = 0
            var a_sum = 0
            var block = row_base + ox * block_bytes
            for dy in range(factor):
                var i = block + dy * src_stride
                for _ in range(factor):
                    var a = Int(sp[unsafe_offset=i + 3])
                    r_sum += Int(sp[unsafe_offset=i]) * a
                    g_sum += Int(sp[unsafe_offset=i + 1]) * a
                    b_sum += Int(sp[unsafe_offset=i + 2]) * a
                    a_sum += a
                    i += BYTES_PER_PIXEL
            var alpha = (a_sum + half) >> shift if pow2 else (a_sum + half) // n
            if alpha == 0:
                op[unsafe_offset=out_idx] = 0
                op[unsafe_offset=out_idx + 1] = 0
                op[unsafe_offset=out_idx + 2] = 0
            else:
                var half_a = a_sum // 2
                op[unsafe_offset=out_idx] = UInt8((r_sum + half_a) // a_sum)
                op[unsafe_offset=out_idx + 1] = UInt8((g_sum + half_a) // a_sum)
                op[unsafe_offset=out_idx + 2] = UInt8((b_sum + half_a) // a_sum)
            op[unsafe_offset=out_idx + 3] = UInt8(alpha)
            out_idx += BYTES_PER_PIXEL
