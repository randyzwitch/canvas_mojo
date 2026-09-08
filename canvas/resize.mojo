"""Box-filter downsampling: shrink a Canvas by an integer factor, each
output pixel the average of the corresponding factor x factor block of
input pixels.

This is the mechanism behind supersampled anti-aliasing -- render
`factor` times larger than the final size, then `downsample()` back --
so every output pixel averages `factor * factor` real source samples.
"""

from std.math import floor
from std.runtime.asyncrt import TaskGroup

from canvas.buffer import Canvas, BYTES_PER_PIXEL
from canvas.workers import _bands_for

# Below this many source pixels, resize runs inline.
comptime _MIN_PARALLEL_PIXELS = 40000


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


# --- arbitrary-size resize ------------------------------------------


struct _AxisWeights(Movable):
    """Per-output-position resampling weights along one axis, flat.

    `weights[offsets[i] : offsets[i] + counts[i]]` are the weights for
    output position `i`, applying to source positions
    `starts[i] ..< starts[i] + counts[i]`. Flattened rather than a list
    of lists because the inner loop reads them once per pixel of the
    other axis, and a `List[List[...]]` costs an indirection per
    output position on every one of those.
    """

    var starts: List[Int]
    var counts: List[Int]
    var offsets: List[Int]
    var weights: List[Float64]
    var sums: List[Float64]

    def __init__(
        out self,
        var starts: List[Int],
        var counts: List[Int],
        var offsets: List[Int],
        var weights: List[Float64],
        var sums: List[Float64],
    ):
        self.starts = starts^
        self.counts = counts^
        self.offsets = offsets^
        self.weights = weights^
        self.sums = sums^


def _axis_weights(src_len: Int, out_len: Int) -> _AxisWeights:
    """Weights taking `src_len` samples to `out_len` along one axis.

    Two regimes, which is what makes one function serve both
    directions of resize:

    Shrinking (`out_len < src_len`) uses the exact **area** each
    output pixel covers: output pixel `i` spans source
    `[i * s, (i + 1) * s)` for `s = src_len / out_len`, and each
    source pixel's weight is the length of its overlap with that
    span. At an integer ratio every weight is exactly 1 and the count
    is exactly the ratio, which is what makes this agree with
    `downsample` to the byte.

    Growing (`out_len >= src_len`) uses a **triangle** of radius 1
    around the mapped center, which is linear interpolation. An area
    filter would degenerate to nearest-neighbor here, since the span
    lands inside a single source pixel.

    Coordinates are pixel-center based throughout: source pixel `j`
    covers `[j, j + 1)` in the continuous axis, matching this
    package's convention that pixel (x, y) is the square
    [x - 0.5, x + 0.5] shifted by the half-pixel the two spaces differ
    by.
    """
    var starts = List[Int](capacity=out_len)
    var counts = List[Int](capacity=out_len)
    var offsets = List[Int](capacity=out_len)
    var weights = List[Float64]()
    var sums = List[Float64](capacity=out_len)
    var scale = Float64(src_len) / Float64(out_len)

    if out_len < src_len:
        for i in range(out_len):
            var lo = Float64(i) * scale
            var hi = Float64(i + 1) * scale
            var j0 = Int(lo)
            var j1 = Int(hi)
            if Float64(j1) < hi:
                j1 += 1
            if j1 > src_len:
                j1 = src_len
            if j0 >= j1:
                j0 = min(j0, src_len - 1)
                j1 = j0 + 1
            starts.append(j0)
            counts.append(j1 - j0)
            offsets.append(len(weights))
            var total = 0.0
            for j in range(j0, j1):
                var a = max(lo, Float64(j))
                var b = min(hi, Float64(j + 1))
                var w = max(0.0, b - a)
                total += w
                weights.append(w)
            sums.append(total if total > 0.0 else 1.0)
    else:
        for i in range(out_len):
            # Center of output pixel i in source coordinates.
            var center = (Float64(i) + 0.5) * scale - 0.5
            var j0 = Int(floor(center))
            var j1 = j0 + 2
            if j0 < 0:
                j0 = 0
            if j1 > src_len:
                j1 = src_len
            if j0 >= j1:
                j0 = src_len - 1
                j1 = src_len
            starts.append(j0)
            counts.append(j1 - j0)
            offsets.append(len(weights))
            var total = 0.0
            for j in range(j0, j1):
                var t = abs(center - Float64(j))
                var w = max(0.0, 1.0 - t)
                total += w
                weights.append(w)
            sums.append(total if total > 0.0 else 1.0)
    return _AxisWeights(starts^, counts^, offsets^, weights^, sums^)


# Total horizontally-filtered scratch live across all bands. The
# full-height intermediate this replaces is
# `out_width * source.height * 4` doubles -- 28.5 MB for the
# 741-column case -- written to memory and read straight back. Each
# band gets an equal share, small enough to stay in cache, and the
# only cost is re-filtering the few source rows two consecutive chunks
# share.
#
# Budgeted in total rather than per band because the bands are
# concurrent: a per-band figure that looks modest is multiplied by the
# worker count, and at 64 bands a 1 MB strip is 56 MB live -- worse
# than the buffer it replaces, and measurably slower than this.
comptime _SCRATCH_BYTES = 6 << 20

# A band never gets less than this, however many bands there are.
comptime _MIN_STRIP_BYTES = 96 << 10


def _resize_h_rows(
    source: Canvas,
    mut strip: List[Float64],
    strip_off: Int,
    strip_first: Int,
    out_width: Int,
    wx: _AxisWeights,
    first_row: Int,
    last_row: Int,
):
    """Source rows [first_row, last_row) resampled horizontally into a
    strip that starts at source row `strip_first`, as
    alpha-premultiplied `(r*a, g*a, b*a, a)` in Float64.

    Premultiplied because that is what makes the color average
    alpha-weighted, the same rule `downsample` follows: a transparent
    source pixel contributes no color rather than contributing black.
    Float64 rather than Float32 because the sums reach a few times
    255 * 255 * (source span), past the 2^24 where Float32 stops
    representing integers exactly.
    """
    var sp = source.pixels.unsafe_ptr()
    var op = strip.unsafe_ptr()
    var src_stride = source.width * BYTES_PER_PIXEL
    var wp = wx.weights.unsafe_ptr()
    for y in range(first_row, last_row):
        var row = y * src_stride
        var orow = strip_off + (y - strip_first) * out_width * 4
        for i in range(out_width):
            var j0 = wx.starts[i]
            var n = wx.counts[i]
            var wo = wx.offsets[i]
            var r = 0.0
            var g = 0.0
            var b = 0.0
            var a = 0.0
            for k in range(n):
                var w = wp[unsafe_offset=wo + k]
                var s = row + (j0 + k) * BYTES_PER_PIXEL
                var sa = Float64(Int(sp[unsafe_offset=s + 3]))
                r += w * Float64(Int(sp[unsafe_offset=s])) * sa
                g += w * Float64(Int(sp[unsafe_offset=s + 1])) * sa
                b += w * Float64(Int(sp[unsafe_offset=s + 2])) * sa
                a += w * sa
            var o = orow + i * 4
            op[unsafe_offset=o] = r
            op[unsafe_offset=o + 1] = g
            op[unsafe_offset=o + 2] = b
            op[unsafe_offset=o + 3] = a


def _strip_rows_for(wy: _AxisWeights, first_out: Int, last_out: Int) -> Int:
    """Source rows output rows [first_out, last_out) read between
    them. `wy.starts` is non-decreasing, so the window is the first
    row's start through the last row's end."""
    var s0 = wy.starts[first_out]
    var last = last_out - 1
    return wy.starts[last] + wy.counts[last] - s0


def _chunk_rows(
    wy: _AxisWeights, out_height: Int, out_width: Int, bands: Int
) -> Int:
    """Output rows per chunk: as many as keep one band's strip inside
    its share of `_SCRATCH_BYTES`, and never fewer than one."""
    var per_band = _SCRATCH_BYTES // max(bands, 1)
    if per_band < _MIN_STRIP_BYTES:
        per_band = _MIN_STRIP_BYTES
    var budget = per_band // (out_width * 4 * 8)
    if budget < 1:
        budget = 1
    var c = out_height
    while c > 1:
        # A whole-height chunk is the worst case; halve until the
        # window it needs fits the budget.
        if _strip_rows_for(wy, 0, c) <= budget:
            break
        c = c // 2
    if c < 1:
        c = 1
    return c


def _resize_fused_band(
    source: Canvas,
    out_width: Int,
    wx: _AxisWeights,
    wy: _AxisWeights,
    mut pixels: List[UInt8],
    mut scratch: List[Float64],
    scratch_off: Int,
    first_out: Int,
    last_out: Int,
    chunk: Int,
):
    """Output rows [first_out, last_out), filtered both ways through a
    strip of horizontally-filtered rows rather than a full-height
    intermediate.

    The strip is a slice of one `scratch` buffer the caller allocates
    for every band at once, at `scratch_off`; allocating per band
    instead cost 64 allocations and their first-touch faults on every
    call. Bands write disjoint rows of `pixels` and disjoint slices of
    `scratch`, which is the whole safety argument.
    """
    var oy = first_out
    while oy < last_out:
        var end = min(oy + chunk, last_out)
        var s0 = wy.starts[oy]
        var s1 = wy.starts[end - 1] + wy.counts[end - 1]
        _resize_h_rows(source, scratch, scratch_off, s0, out_width, wx, s0, s1)
        _resize_v_rows(
            scratch, scratch_off, s0, out_width, wx, wy, pixels, oy, end
        )
        oy = end


async def _resize_fused_band_async(
    source: Canvas,
    out_width: Int,
    wx: _AxisWeights,
    wy: _AxisWeights,
    mut pixels: List[UInt8],
    mut scratch: List[Float64],
    scratch_off: Int,
    first_out: Int,
    last_out: Int,
    chunk: Int,
):
    """`_resize_fused_band` as a task. Every aggregate is borrowed,
    never owned: canvas_mojo#97."""
    _resize_fused_band(
        source,
        out_width,
        wx,
        wy,
        pixels,
        scratch,
        scratch_off,
        first_out,
        last_out,
        chunk,
    )


def _resize_streamed(
    source: Canvas,
    out_width: Int,
    out_height: Int,
    wx: _AxisWeights,
    wy: _AxisWeights,
    mut pixels: List[UInt8],
    max_workers: Int,
):
    """Both passes, banded over output rows, with the intermediate cut
    to a strip per band."""
    var bands = _bands_for(out_width * out_height, out_height, max_workers)
    var chunk = _chunk_rows(wy, out_height, out_width, bands)
    var per_band = (out_height + bands - 1) // bands

    # Widest window any chunk can need, so every band's slice is the
    # same size and one allocation covers them all.
    var widest = 0
    var probe = 0
    while probe < out_height:
        var end = min(probe + chunk, out_height)
        var rows = _strip_rows_for(wy, probe, end)
        if rows > widest:
            widest = rows
        probe = end
    var strip_len = widest * out_width * 4

    if bands <= 1:
        var scratch = List[Float64](unsafe_uninit_length=strip_len)
        _resize_fused_band(
            source, out_width, wx, wy, pixels, scratch, 0, 0, out_height, chunk
        )
        return

    var scratch = List[Float64](unsafe_uninit_length=strip_len * bands)
    var tg = TaskGroup()
    for b in range(bands):
        var lo = b * per_band
        var hi = min(lo + per_band, out_height)
        if lo >= hi:
            continue
        tg.create_task(
            _resize_fused_band_async(
                source,
                out_width,
                wx,
                wy,
                pixels,
                scratch,
                b * strip_len,
                lo,
                hi,
                chunk,
            )
        )
    tg.wait()
    _ = len(scratch)
    # Named past the tasks, or they are freed while bands read them.
    _ = len(wx.weights)
    _ = len(wy.weights)
    _ = len(wx.sums)
    _ = source.width


def _resize_v_rows(
    strip: List[Float64],
    strip_off: Int,
    strip_first: Int,
    out_width: Int,
    wx: _AxisWeights,
    wy: _AxisWeights,
    mut pixels: List[UInt8],
    first_row: Int,
    last_row: Int,
):
    """The vertical pass, reading a strip that starts at source row
    `strip_first` and unpremultiplying into 8-bit RGBA.

    Same weights, same accumulation order and the same single division
    by the product of the two axes' sums whatever the strip's height,
    so the bytes written do not depend on how the horizontally
    filtered rows were chunked.

    Alpha is the plain weighted mean of the source alphas; color is
    the sum of `color * alpha` over the sum of `alpha`, so a nearly
    transparent source pixel barely moves the color. An output pixel
    whose alpha rounds to zero becomes transparent black, since no
    color it could carry would ever be visible and leaving one there
    only invites it to leak through a later operation. Both rules are
    `downsample`'s, and this agrees with it byte for byte at an
    integer ratio.
    """
    var mp = strip.unsafe_ptr()
    var op = pixels.unsafe_ptr()
    var wp = wy.weights.unsafe_ptr()
    for oy in range(first_row, last_row):
        var j0 = wy.starts[oy]
        var n = wy.counts[oy]
        var wo = wy.offsets[oy]
        var out_row = oy * out_width * BYTES_PER_PIXEL
        for x in range(out_width):
            var r = 0.0
            var g = 0.0
            var b = 0.0
            var a = 0.0
            for k in range(n):
                var w = wp[unsafe_offset=wo + k]
                var m = strip_off + ((j0 + k - strip_first) * out_width + x) * 4
                r += w * mp[unsafe_offset=m]
                g += w * mp[unsafe_offset=m + 1]
                b += w * mp[unsafe_offset=m + 2]
                a += w * mp[unsafe_offset=m + 3]
            var o = out_row + x * BYTES_PER_PIXEL
            # The weights are left unnormalized and divided out once,
            # here, by the exact product of the two axes' sums. At an
            # integer ratio that product is the block size and every
            # accumulated value is an exact integer in Float64, which
            # is what makes this agree with `downsample` to the byte;
            # normalizing the weights first would divide by an inexact
            # 1/3 or 1/5 and flip the occasional round-half case.
            var scale = wx.sums[x] * wy.sums[oy]
            var alpha = Int(a / scale + 0.5)
            if alpha < 0:
                alpha = 0
            if alpha > 255:
                alpha = 255
            if alpha == 0 or a <= 0.0:
                op[unsafe_offset=o] = 0
                op[unsafe_offset=o + 1] = 0
                op[unsafe_offset=o + 2] = 0
                op[unsafe_offset=o + 3] = 0
                continue
            # Color needs no scale: it is a sum of `color * alpha`
            # over a sum of `alpha`, and the weight factors cancel.
            var cr = Int(r / a + 0.5)
            var cg = Int(g / a + 0.5)
            var cb = Int(b / a + 0.5)
            op[unsafe_offset=o] = UInt8(max(0, min(255, cr)))
            op[unsafe_offset=o + 1] = UInt8(max(0, min(255, cg)))
            op[unsafe_offset=o + 2] = UInt8(max(0, min(255, cb)))
            op[unsafe_offset=o + 3] = UInt8(alpha)


def resize(source: Canvas, width: Int, height: Int) raises -> Canvas:
    """Resample `source` to exactly `width` x `height`, with alpha-
    correct filtering and no constraint on the ratio.

    `downsample` shrinks by an integer factor that has to divide both
    dimensions; this takes any target size, including fractional and
    anisotropic ratios, and one axis growing while the other shrinks.

    The filter is chosen per axis by what that axis is doing. An axis
    being **reduced** takes the exact area each output pixel covers,
    which is the right answer for minification and is what suppresses
    aliasing on a checkerboard or a fine grid. An axis being
    **enlarged** takes a triangle of radius one, which is linear
    interpolation; an area filter there would collapse to
    nearest-neighbor, since the covered span falls inside a single
    source pixel.

    Color is filtered alpha-weighted and returned as straight RGBA,
    so transparent source pixels neither darken an edge nor
    contribute hidden color, and an output pixel whose alpha rounds
    to zero is transparent black. These are `downsample`'s rules, and
    at an integer ratio dividing both dimensions this *is*
    `downsample` -- the same bytes, through the same fixed-factor
    kernels, at the same cost.

    Extra memory is one intermediate of `width * source.height * 4`
    doubles, from resampling horizontally before vertically. The
    integer-ratio path above allocates none of it.

    Args:
        source: Canvas to resample.
        width: Target width in pixels, at least 1.
        height: Target height in pixels, at least 1.

    Returns:
        A new `width` x `height` Canvas.

    Raises:
        Error: If `width` or `height` is below 1.
    """
    if width < 1 or height < 1:
        raise Error(
            String(
                "resize: target size must be at least 1x1, got ",
                width,
                "x",
                height,
            )
        )
    if width == source.width and height == source.height:
        # Every byte preserved, including color under zero alpha,
        # which a filtered round trip would flatten.
        return Canvas(width, height, source.pixels.copy())

    # A shrink by one integer factor on both axes is exactly what
    # downsample computes: every weight is 1 and the count is the
    # factor, so the weighted mean reduces to the block mean. Taking
    # its fixed-factor kernels rather than the general path saves a
    # Float64 intermediate of `width * source.height * 4` doubles --
    # 30.7 MB at 1600x1200 -> 2x -- and 3.2x the time, for bytes that
    # were already identical. The equivalence is checked past this
    # dispatch by test_the_general_filter_still_agrees_with_downsample.
    if source.width % width == 0 and source.height % height == 0:
        var factor = source.width // width
        if factor == source.height // height:
            return downsample(source, factor)

    return _resize_general(source, width, height)


def _resize_general(source: Canvas, width: Int, height: Int) raises -> Canvas:
    """`resize`'s two-pass filter, without the fast paths in front of
    it. Separate so a test can still reach it at an integer ratio and
    check it agrees with `downsample` there -- the property the
    dispatch above rests on, which is otherwise unobservable once the
    dispatch takes that case.

    Args:
        source: Canvas to resample.
        width: Target width in pixels, at least 1.
        height: Target height in pixels, at least 1.

    Returns:
        A new `width` x `height` Canvas.
    """
    var wx = _axis_weights(source.width, width)
    var wy = _axis_weights(source.height, height)
    var pixels = List[UInt8](
        unsafe_uninit_length=width * height * BYTES_PER_PIXEL
    )
    _resize_streamed(
        source, width, height, wx, wy, pixels, source.max_workers()
    )
    return Canvas(width, height, pixels^)
