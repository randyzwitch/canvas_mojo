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

## Drawing a canvas under a matrix

The overloads taking a `Matrix2D` draw the source scaled, rotated,
skewed or cropped -- what `cairo_set_source_surface` under the CTM and
the HTML5 canvas's `drawImage` do. Each destination pixel in the mapped
source's bounding box is inverse-mapped into the source and sampled
there, `Filter.NEAREST` taking the pixel the point lands in and
`Filter.BILINEAR` mixing the four around it.

These overloads work in *texel* coordinates: source pixel (i, j) covers
the unit square from (i, j) to (i + 1, j + 1), so its center is at
(i + 0.5, j + 0.5) and a `w x h` source occupies [0, w] x [0, h]. That
is the convention Cairo and the HTML5 canvas use for an image, and the
one that makes `Matrix2D.scaling(2.0, 2.0)` land each source pixel on
exactly four destination pixels. It differs from the pixel-center
convention the shape rasterizers use (see CONTRIBUTING.md), and the two
agree wherever it matters here: under a translation by whole pixels
both put source pixel (i, j) at destination pixel (i + tx, j + ty), and
that call takes the blit path above.
"""

from std.math import ceil, floor
from std.memory import unsafe_memcpy
from std.runtime.asyncrt import TaskGroup

from canvas.aa_crossing import _MIN_PARALLEL_PIXELS
from canvas.buffer import Canvas, BYTES_PER_PIXEL
from canvas.color import Color, _DIV255_MUL, _DIV255_SHIFT, _div255
from canvas.geometry import Matrix2D, round_to_int
from canvas.mask import Mask
from canvas.workers import _bands_for


struct Filter(Copyable, Equatable, ImplicitlyCopyable, Movable, Writable):
    """How a transformed `draw_canvas` reads the source between its
    pixels: `NEAREST` takes the one the sample point lands in, giving
    hard pixel edges and no color the source did not already hold, and
    `BILINEAR` mixes the four around it, giving smooth edges and
    intermediate colors.
    """

    var _value: Int

    comptime NEAREST = Self(0)
    comptime BILINEAR = Self(1)

    def __init__(out self, value: Int):
        """Prefer the `NEAREST`/`BILINEAR` comptime constants over
        constructing one directly.

        Args:
            value: 0 for NEAREST, 1 for BILINEAR.
        """
        self._value = value

    def __eq__(self, other: Self) -> Bool:
        return self._value == other._value

    def write_to[W: Writer](self, mut writer: W):
        if self._value == Self.NEAREST._value:
            writer.write("NEAREST")
        elif self._value == Self.BILINEAR._value:
            writer.write("BILINEAR")
        else:
            writer.write("Filter(", self._value, ")")

    def __str__(self) -> String:
        var out = String()
        out.write(self)
        return out


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
    dst._flush_batch()
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

    Under a canvas transform only its translation applies: (x, y) maps
    through the transform and `src` is composited there unscaled and
    unrotated. Pass a `Matrix2D` instead to draw it scaled or rotated.
    """
    dst._flush_batch()
    if dst.has_transform():
        var m = dst.current_transform()
        var p = m.apply(Float64(x), Float64(y))
        _draw_canvas_device(
            dst, src, round_to_int(p.x), round_to_int(p.y), opacity
        )
        return
    _draw_canvas_device(dst, src, x, y, opacity)


def draw_canvas(mut dst: Canvas, src: Canvas, x: Int, y: Int, mask: Mask):
    """`draw_canvas` through a mask: each source pixel's alpha is
    scaled by the mask's coverage at the same position in the source
    before it is composited, so a layer fades where the mask does.
    The mask is aligned with the source's top-left corner, not the
    destination's; source pixels the mask does not reach draw nothing.

    Args:
        dst: Canvas composited onto.
        src: Canvas to draw. Unchanged.
        x: Destination column for `src`'s left edge.
        y: Destination row for `src`'s top edge.
        mask: Coverage over `src`, see `canvas.mask`.
    """
    dst._flush_batch()
    if dst.has_transform():
        var m = dst.current_transform()
        var p = m.apply(Float64(x), Float64(y))
        _draw_canvas_device[True](
            dst, src, round_to_int(p.x), round_to_int(p.y), 255, mask
        )
        return
    _draw_canvas_device[True](dst, src, x, y, 255, mask)


# Groups skipped before testing again for a copyable source run.
comptime _COPY_RETRY = 15

# Groups classified by one horizontal reduction instead of one each.
#
# The reduction is the whole cost of classifying, not the loads and not
# the compare: a copy of an 800x600 canvas is 39.9 us, the same copy
# with a per-group `reduce_min` is 80.6 us, and the same copy with the
# four groups AND-ed together and reduced once is 40.0 us. So the check
# goes from doubling the copy to costing 0.1 us (#351).
#
# AND-ing vectors is vertical work the pipeline absorbs; the horizontal
# reduce is a dependency the branch waits on. Four is enough to hide it
# and keeps the fallback cheap when a block is mixed.
comptime _WIDE = 4
comptime _WIDE_PX = _GROUP * _WIDE
comptime _WIDE_BYTES = _GROUP_BYTES * _WIDE


# Eight pixels' worth of lane masks, used to ask two questions of a
# loaded group at once: OR-ing `_NOT_ALPHA` in leaves an all-255
# vector exactly when every alpha is 255, and AND-ing `_ALPHA_ONLY`
# leaves zero exactly when every alpha is zero.
comptime _GROUP = 8
comptime _GROUP_BYTES = _GROUP * BYTES_PER_PIXEL
comptime _NOT_ALPHA = SIMD[DType.uint8, _GROUP_BYTES](
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
comptime _ALPHA_ONLY = SIMD[DType.uint8, _GROUP_BYTES](
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


@always_inline
def _blend_group_opaque(
    mut dst: Canvas, src: Canvas, d_idx: Int, s_idx: Int
) -> Bool:
    """Composite eight source pixels onto eight destination ones and
    report whether it happened. It happens only where every
    destination pixel is already opaque -- anything drawn on a canvas
    with a background -- because source-over onto an opaque
    destination is `src*a + dst*(255-a)` per channel with the output
    alpha staying 255, and that has no per-pixel division.

    The source alpha is broadcast across each pixel's four lanes; the
    products peak at 130050, which `_div255`'s multiply keeps inside
    32 bits. It is the arithmetic `Color.blend_over_opaque` does,
    including at a = 0 and a = 255, where the formula reproduces that
    function's two early exits exactly rather than approximating them.

    Args:
        dst: Canvas written to. Its eight pixels at `d_idx` must be
            in bounds and inside the active clip.
        src: Canvas read from.
        d_idx: Byte offset of the first destination pixel.
        s_idx: Byte offset of the first source pixel.

    Returns:
        True if the eight pixels were composited, False if the
        destination was not opaque and the caller must fall back.
    """
    comptime W = _GROUP_BYTES
    var v = src.pixels.unsafe_ptr().unsafe_offset(s_idx).unsafe_load[width=W]()
    return _blend_group_with_alpha(dst, v, _broadcast_alpha(v), d_idx)


def _broadcast_alpha(
    v: SIMD[DType.uint8, _GROUP_BYTES]
) -> SIMD[DType.uint32, _GROUP_BYTES]:
    """Each pixel's alpha lane copied across its four lanes, so a
    per-pixel alpha can multiply a per-channel vector."""
    return v.shuffle[
        3,
        3,
        3,
        3,
        7,
        7,
        7,
        7,
        11,
        11,
        11,
        11,
        15,
        15,
        15,
        15,
        19,
        19,
        19,
        19,
        23,
        23,
        23,
        23,
        27,
        27,
        27,
        27,
        31,
        31,
        31,
        31,
    ]().cast[DType.uint32]()


def _blend_group_with_alpha(
    mut dst: Canvas,
    v: SIMD[DType.uint8, _GROUP_BYTES],
    a32: SIMD[DType.uint32, _GROUP_BYTES],
    d_idx: Int,
) -> Bool:
    """Composite eight source pixels `v` onto `dst` at `d_idx` with
    per-lane alpha `a32`, and report whether it happened.

    The blend `_blend_group_opaque` documents, with the alpha handed
    in rather than read from the source, so a mask's coverage and a
    global opacity can be folded into it before it runs.

    Returns:
        True if the eight pixels were composited, False if the
        destination was not opaque and the caller must fall back.
    """
    comptime W = _GROUP_BYTES
    var dp = dst.pixels.unsafe_ptr()
    var dv = dp.unsafe_offset(d_idx).unsafe_load[width=W]()
    if (dv | _NOT_ALPHA).reduce_min() != 255:
        return False
    var num = v.cast[DType.uint32]() * a32 + dv.cast[DType.uint32]() * (
        SIMD[DType.uint32, W](255) - a32
    )
    var outv = ((num * UInt32(_DIV255_MUL)) >> UInt32(_DIV255_SHIFT)).cast[
        DType.uint8
    ]()
    dp.unsafe_offset(d_idx).unsafe_store(outv | _ALPHA_ONLY)
    return True


def _div255_simd(
    v: SIMD[DType.uint32, _GROUP_BYTES]
) -> SIMD[DType.uint32, _GROUP_BYTES]:
    """`_div255` per lane, the same multiply and shift."""
    return (v * UInt32(_DIV255_MUL)) >> UInt32(_DIV255_SHIFT)


def _blend_group_scaled[
    with_mask: Bool
](
    mut dst: Canvas,
    src: Canvas,
    d_idx: Int,
    s_idx: Int,
    mask: Mask,
    m_idx: Int,
    opacity: UInt8,
) -> Bool:
    """`_blend_group_opaque` for eight pixels whose alpha is scaled
    by a mask's coverage, a global opacity, or both.

    The effective alpha is `div255(div255(sa * coverage) * opacity)`,
    each step the same multiply-and-shift the per-pixel path uses and
    in the same order, so the two agree byte for byte. The per-pixel
    path skips a multiplication when coverage or opacity is 255;
    `div255(a * 255) == a` exactly, so doing it anyway changes
    nothing and keeps the vector straight-line.

    Coverage is eight contiguous bytes, one per pixel, widened to the
    four lanes of each pixel by interleaving it with itself twice.

    Returns:
        True if the eight pixels were composited, False if the
        destination was not opaque and the caller must fall back.
    """
    comptime W = _GROUP_BYTES
    var v = src.pixels.unsafe_ptr().unsafe_offset(s_idx).unsafe_load[width=W]()
    var a32 = _broadcast_alpha(v)

    comptime if with_mask:
        var c8 = (
            mask.coverage.unsafe_ptr()
            .unsafe_offset(m_idx)
            .unsafe_load[width=_GROUP]()
        )
        var c32 = (
            c8.interleave(c8).interleave(c8.interleave(c8)).cast[DType.uint32]()
        )
        a32 = _div255_simd(a32 * c32)
    if opacity != 255:
        a32 = _div255_simd(a32 * UInt32(opacity))
    return _blend_group_with_alpha(dst, v, a32, d_idx)


def _draw_canvas_device[
    with_mask: Bool = False
](
    mut dst: Canvas,
    src: Canvas,
    x: Int,
    y: Int,
    opacity: UInt8,
    mask: Mask = Mask(0, 0),
):
    """`draw_canvas` for device-space arguments: the body every
    call lands in. It has no transform check of its own, so its
    loops compile with nothing ahead of them and it never calls
    back into the public function.

    `with_mask` says whether `mask` scales each source pixel's alpha.

    The mask is aligned with the source's top-left corner, not the
    destination's, and a source pixel it does not reach draws nothing
    -- so the region below is cut to the mask as well, and every
    lookup inside the loops is then in range.
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

    comptime if with_mask:
        # The mask covers source pixels (0, 0) to (width, height),
        # which in destination coordinates is the rectangle at (x, y).
        # Outside it coverage is zero and nothing is drawn, so cutting
        # the region to it now keeps every later lookup in range.
        var mx0 = max(rx, x)
        var my0 = max(ry, y)
        var mx1 = min(rx + rw, x + mask.width)
        var my1 = min(ry + rh, y + mask.height)
        rx = mx0
        ry = my0
        rw = mx1 - mx0
        rh = my1 - my0
    if rw <= 0 or rh <= 0:
        return

    var sp = src.pixels.unsafe_ptr()
    var src_stride = src.width * BYTES_PER_PIXEL
    var full = opacity == 255
    var mcov = mask.coverage.unsafe_ptr()
    var mask_w = mask.width

    # A clip path modulates each pixel individually, which the direct
    # pointer writes below cannot express: `effective_fill_rect` folds
    # in the rectangle clip, since that is a range, but a path clip is a
    # per-pixel coverage value. Route through `set_pixel` while one is
    # pushed, the same fallback `Canvas._fill_region` and the gradient
    # rect fills in canvas.shapes.rects make -- see `Canvas.write_pixel`
    # for the contract. Nothing pays for this until a clip path exists.
    if dst.has_clip_mask():
        for row in range(rh):
            var sy = ry + row - y
            var s_idx = sy * src_stride + (rx - x) * BYTES_PER_PIXEL
            var m_idx = sy * mask_w + (rx - x)
            for col in range(rw):
                var sa = sp[unsafe_offset=s_idx + 3]
                var effective_a = sa

                comptime if with_mask:
                    var cov = Int(mcov[unsafe_offset=m_idx])
                    if cov != 255:
                        effective_a = UInt8(_div255(Int(sa) * cov))
                    m_idx += 1
                if not full:
                    effective_a = UInt8(
                        _div255(Int(effective_a) * Int(opacity))
                    )
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

    # In linear light every translucent source pixel goes through
    # `write_pixel`, which owns the conversion; the opaque ones below
    # still replace outright.
    var linear = dst.color_space().is_linear()

    var dp = dst.pixels.unsafe_ptr()
    var dst_stride = dst.width * BYTES_PER_PIXEL

    # Process common opaque and transparent runs eight pixels at a time.
    # A run of opaque source
    # pixels at full opacity is a copy: OR-ing in 255 everywhere but
    # the alpha lanes leaves the vector all-255 exactly when all eight
    # alphas are. A run of fully transparent ones writes nothing at
    # all, whatever the opacity or the color space: masking to the
    # alpha lanes leaves zero exactly when all eight are zero. Either
    # way one compare replaces eight trips through the pixel loop,
    # which is otherwise unchanged. With a mask the same two questions
    # are put to its eight coverage bytes, which sit contiguously, and
    # the answers have to agree: a copy needs full coverage as well as
    # an opaque source, and a skip takes either an all-transparent
    # source or all-zero coverage.
    #
    # The test is not free -- a branch waiting on a horizontal minimum
    # is about six nanoseconds, and on a layer that is translucent
    # throughout it would be paid on every group for nothing. So a
    # failure suppresses it for the next `_COPY_RETRY` groups. A row
    # that is entirely one kind or the other, which is what a
    # composited layer usually is, pays it once either way, and the
    # counter restarts on every row so a sprite's transparent border
    # cannot switch off the rest of the image.
    comptime GROUP = _GROUP
    comptime GROUP_BYTES = _GROUP_BYTES
    comptime not_alpha = _NOT_ALPHA
    comptime alpha_only = _ALPHA_ONLY
    var fast = full and not linear

    for row in range(rh):
        var sy = ry + row - y
        var s_idx = sy * src_stride + (rx - x) * BYTES_PER_PIXEL
        var d_idx = (ry + row) * dst_stride + rx * BYTES_PER_PIXEL
        var m_idx = sy * mask_w + (rx - x)
        var col = 0
        var retry = 0
        while col < rw:
            # Four groups at once, classified by a single reduction.
            # Only without a mask: a mask asks a second question of its
            # own coverage bytes, and answering both wide is a separate
            # change. `retry` gates this the same way it gates the
            # per-group test, so a layer that is translucent throughout
            # stops paying for either.
            comptime if not with_mask:
                if fast and retry == 0 and rw - col >= _WIDE_PX:
                    var w0 = sp.unsafe_offset(s_idx).unsafe_load[
                        width=GROUP_BYTES
                    ]()
                    var w1 = sp.unsafe_offset(s_idx + GROUP_BYTES).unsafe_load[
                        width=GROUP_BYTES
                    ]()
                    var w2 = sp.unsafe_offset(
                        s_idx + 2 * GROUP_BYTES
                    ).unsafe_load[width=GROUP_BYTES]()
                    var w3 = sp.unsafe_offset(
                        s_idx + 3 * GROUP_BYTES
                    ).unsafe_load[width=GROUP_BYTES]()
                    if ((w0 & w1 & w2 & w3) | not_alpha).reduce_min() == 255:
                        # Every one of the 32 alphas is 255, so this is
                        # a copy, exactly as the per-group path would
                        # have decided four times over.
                        dp.unsafe_offset(d_idx).unsafe_store(w0)
                        dp.unsafe_offset(d_idx + GROUP_BYTES).unsafe_store(w1)
                        dp.unsafe_offset(d_idx + 2 * GROUP_BYTES).unsafe_store(
                            w2
                        )
                        dp.unsafe_offset(d_idx + 3 * GROUP_BYTES).unsafe_store(
                            w3
                        )
                        s_idx += _WIDE_BYTES
                        d_idx += _WIDE_BYTES
                        m_idx += _WIDE_PX
                        col += _WIDE_PX
                        continue
                    if ((w0 | w1 | w2 | w3) & alpha_only).reduce_or() == 0:
                        # Every one of the 32 alphas is zero: nothing to
                        # composite, and nothing written.
                        s_idx += _WIDE_BYTES
                        d_idx += _WIDE_BYTES
                        m_idx += _WIDE_PX
                        col += _WIDE_PX
                        continue
                    # Mixed somewhere in the 32. Fall through and let
                    # the per-group path find which groups are still
                    # uniform; it sets `retry` if they are not.

            var take = min(GROUP, rw - col)
            if take == GROUP:
                if retry > 0:
                    retry -= 1
                else:
                    var v = sp.unsafe_offset(s_idx).unsafe_load[
                        width=GROUP_BYTES
                    ]()
                    var cov_full = True
                    var cov_none = False

                    comptime if with_mask:
                        var cv = mcov.unsafe_offset(m_idx).unsafe_load[
                            width=GROUP
                        ]()
                        cov_full = cv.reduce_min() == 255
                        cov_none = cv.reduce_max() == 0
                    if (
                        fast
                        and cov_full
                        and (v | not_alpha).reduce_min() == 255
                    ):
                        dp.unsafe_offset(d_idx).unsafe_store(v)
                        s_idx += GROUP_BYTES
                        d_idx += GROUP_BYTES
                        m_idx += GROUP
                        col += GROUP
                        continue
                    if cov_none or (v & alpha_only).reduce_or() == 0:
                        # Nothing to composite. A zero source alpha, or
                        # zero coverage, writes nothing whatever the
                        # opacity or the color space.
                        s_idx += GROUP_BYTES
                        d_idx += GROUP_BYTES
                        m_idx += GROUP
                        col += GROUP
                        continue

                    # Mixed alphas: eight at a time when the
                    # destination is opaque, out of line so the copy
                    # and skip tests above keep a small loop body.
                    # A mask's coverage and a global opacity fold into
                    # the alpha before the blend, so neither one sends
                    # the group back to the per-pixel loop; only linear
                    # light does, since `write_pixel` owns that
                    # conversion.
                    if not linear:
                        var done: Bool

                        comptime if with_mask:
                            done = _blend_group_scaled[True](
                                dst, src, d_idx, s_idx, mask, m_idx, opacity
                            )
                        else:
                            if full:
                                # No coverage and no scaling: the
                                # original kernel, untouched.
                                done = _blend_group_opaque(
                                    dst, src, d_idx, s_idx
                                )
                            else:
                                done = _blend_group_scaled[False](
                                    dst, src, d_idx, s_idx, mask, m_idx, opacity
                                )
                        if done:
                            s_idx += GROUP_BYTES
                            d_idx += GROUP_BYTES
                            m_idx += GROUP
                            col += GROUP
                            continue
                    retry = _COPY_RETRY
            col += take
            for _ in range(take):
                var sa = sp[unsafe_offset=s_idx + 3]

                comptime if with_mask:
                    var cov = Int(mcov[unsafe_offset=m_idx])
                    if cov != 255:
                        sa = UInt8(_div255(Int(sa) * cov))
                    m_idx += 1
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
                        if linear:
                            dst.write_pixel(
                                (d_idx - (ry + row) * dst_stride)
                                // BYTES_PER_PIXEL,
                                ry + row,
                                source,
                            )
                        elif dp[unsafe_offset=d_idx + 3] == 255:
                            # Opaque destination, the common case: the
                            # division-free form `write_pixel` uses.
                            var over = source.blend_over_opaque(
                                dp[unsafe_offset=d_idx],
                                dp[unsafe_offset=d_idx + 1],
                                dp[unsafe_offset=d_idx + 2],
                            )
                            dp[unsafe_offset=d_idx] = over.r
                            dp[unsafe_offset=d_idx + 1] = over.g
                            dp[unsafe_offset=d_idx + 2] = over.b
                        else:
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


def draw_canvas(
    mut dst: Canvas,
    src: Canvas,
    matrix: Matrix2D,
    opacity: Float64 = 1.0,
    filter: Filter = Filter.BILINEAR,
) raises:
    """Draw `src` onto `dst` through `matrix`: scaled, rotated, skewed
    or mirrored, the equivalent of `cairo_set_source_surface` under the
    CTM or the HTML5 canvas's `drawImage` with a transform.

    `matrix` maps the source's texel space -- pixel (i, j) covering the
    unit square from (i, j) to (i + 1, j + 1), so a `w x h` source
    occupies [0, w] x [0, h] -- to destination pixels. When `dst`
    carries a transform, `matrix` is applied first and the canvas
    transform second, so `matrix` is read in the coordinates the caller
    is drawing in.

    Every destination pixel in the mapped rectangle's bounding box is
    mapped back through the inverse and sampled at that point, under
    `filter`. A pixel whose sample point falls outside the source is
    not drawn; along the outer edge, a bilinear sample's missing
    neighbors are the edge pixel itself.

    Bilinear interpolation weights each neighbor premultiplied by its
    alpha and divides the mix back out, so a transparent neighbor
    contributes its alpha and none of its color. Alpha itself is
    interpolated the same way the colors are.

    Writes go through the canvas's pixel-write path, so the active
    rectangle clip, clip path and blend mode all apply. A translation
    by whole pixels is composited by the integer blit above, which is
    what either filter samples there.

    Args:
        dst: Canvas drawn onto.
        src: Canvas to draw. Unchanged.
        matrix: Map from `src`'s texel space to destination pixels.
        opacity: Scales every source pixel's alpha, 1.0 for unchanged.
        filter: How the source is sampled between its pixels.

    Raises:
        Error: `matrix`, composed with the canvas transform, is
            singular, so it collapses the source to a line or a point.
    """
    dst._flush_batch()
    _draw_canvas_mapped(
        dst, src, 0, 0, src.width, src.height, matrix, opacity, filter
    )


def draw_canvas(
    mut dst: Canvas,
    src: Canvas,
    sx: Int,
    sy: Int,
    sw: Int,
    sh: Int,
    matrix: Matrix2D,
    opacity: Float64 = 1.0,
    filter: Filter = Filter.BILINEAR,
) raises:
    """`draw_canvas` through a matrix, drawing only the `sw x sh`
    rectangle of `src` at (sx, sy) -- one sprite out of a sheet, or one
    panel out of a rendered figure.

    `matrix` maps the *cropped* rectangle's own texel space, its
    top-left corner at (0, 0), so the crop and the placement are
    independent: changing (sx, sy) picks a different part of the source
    without moving where it lands. A rectangle reaching past an edge of
    `src` draws the part that exists, in the place that part maps to.

    Sampling, edge handling, opacity and clipping are the whole-source
    overload's.

    Args:
        dst: Canvas drawn onto.
        src: Canvas to draw from. Unchanged.
        sx: Left edge of the source rectangle, in source pixels.
        sy: Top edge of the source rectangle, in source pixels.
        sw: Width of the source rectangle, in source pixels.
        sh: Height of the source rectangle, in source pixels.
        matrix: Map from the rectangle's texel space to destination
            pixels.
        opacity: Scales every source pixel's alpha, 1.0 for unchanged.
        filter: How the source is sampled between its pixels.

    Raises:
        Error: `matrix`, composed with the canvas transform, is
            singular, so it collapses the source to a line or a point.
    """
    dst._flush_batch()
    _draw_canvas_mapped(dst, src, sx, sy, sw, sh, matrix, opacity, filter)


def draw_image(
    mut dst: Canvas,
    image: Canvas,
    x: Float64,
    y: Float64,
    width: Float64 = 0.0,
    height: Float64 = 0.0,
) raises:
    """Draw `image` as a block of cells with its top-left at (x, y),
    scaled to `width x height` (its own pixel size when 0), in the
    coordinates the shapes use and under the canvas transform:
    `DrawTarget.draw_image` on the raster backend, and the call for a
    heatmap, an image plot, or a rendered panel placed in a figure.

    Each image pixel is one cell of the block. A canvas pixel takes
    the cell its center falls in, so cells stay hard-edged at any
    scale and no color the image did not hold appears; a translucent
    cell blends source-over, as a shape would, and a clip applies. The
    matrix overloads of `draw_canvas` place a source by its pixel
    corners and this places one by the shapes' rule, pixel k spanning
    k - 0.5 to k + 0.5: under a scale and translation, including the
    supersampling recipe on `downsample`, every cell edge snaps as
    `fill_rect` snaps a rectangle's edge at the same coordinate, so
    the block covers the pixels a `fill_rect` per cell would. Under a
    rotation or shear the block is sampled through the matrix path
    with `Filter.NEAREST`, on the same convention.

    Args:
        dst: Canvas drawn onto.
        image: The cells to draw. Unchanged.
        x: Left edge, in user coordinates.
        y: Top edge.
        width: Drawn width, or 0 for `image.width`.
        height: Drawn height, or 0 for `image.height`.

    Raises:
        Error: The canvas transform is singular.
    """
    if image.width <= 0 or image.height <= 0:
        return
    var w = width if width > 0.0 else Float64(image.width)
    var h = height if height > 0.0 else Float64(image.height)
    dst._flush_batch()
    var m = Matrix2D.identity()
    if dst.has_transform():
        m = dst.current_transform()

    if not m.is_axis_aligned():
        # Cell (i, j) is the unit square at (i, j) in texel space; the
        # first map spreads the cells over the box, the second places
        # the box, the third is the canvas frame, and the last half
        # pixel moves from the shapes' pixel-center convention to the
        # corner convention the sampler works in.
        var texel = (
            Matrix2D.scaling(
                w / Float64(image.width), h / Float64(image.height)
            )
            .then(Matrix2D.translation(x, y))
            .then(m)
            .then(Matrix2D.translation(0.5, 0.5))
        )
        _draw_canvas_matrix(
            dst,
            image,
            0,
            0,
            image.width,
            image.height,
            texel,
            1.0,
            Filter.NEAREST,
        )
        return

    # Axis-aligned: every cell edge lands on a device column or row
    # boundary by `fill_rect`'s snap, and the cells tile the snapped
    # box, so the block is one nearest-cell resample followed by the
    # blit. Only the part on the canvas is built, since a cell can be
    # scaled far past the edges.
    var cols = _cell_edges(m.a, m.e, x, w, image.width)
    var rows = _cell_edges(m.d, m.f, y, h, image.height)
    var left = min(cols[0], cols[image.width])
    var right = max(cols[0], cols[image.width])
    var top = min(rows[0], rows[image.height])
    var bottom = max(rows[0], rows[image.height])
    if _cells_are_pixels(cols) and _cells_are_pixels(rows):
        _draw_canvas_device(dst, image, left, top, 255)
        return
    var x0 = max(left, 0)
    var x1 = min(right, dst.width)
    var y0 = max(top, 0)
    var y1 = min(bottom, dst.height)
    if x1 <= x0 or y1 <= y0:
        return
    var col_of = _cell_of_each(cols, x0, x1)
    var row_of = _cell_of_each(rows, y0, y1)
    var bw = x1 - x0
    var bh = y1 - y0
    var block = List[UInt8](unsafe_uninit_length=bw * bh * BYTES_PER_PIXEL)
    var bp = block.unsafe_ptr()
    var sp = image.pixels.unsafe_ptr()
    var stride = image.width * BYTES_PER_PIXEL
    var o = 0
    # Every (row_of, col_of) pair indexes a cell of `image`, since each
    # came from an edge list over its cells; the writes cover the
    # block exactly once, in order.
    for j in range(bh):
        var row_start = row_of[j] * stride
        for i in range(bw):
            bp.unsafe_offset(o).unsafe_store(
                sp.unsafe_offset(
                    row_start + col_of[i] * BYTES_PER_PIXEL
                ).unsafe_load[width=BYTES_PER_PIXEL]()
            )
            o += BYTES_PER_PIXEL
    var resampled = Canvas(bw, bh, block^)
    _draw_canvas_device(dst, resampled, x0, y0, 255)


def _cell_edges(
    scale: Float64, offset: Float64, start: Float64, span: Float64, n: Int
) -> List[Int]:
    """The device pixel boundary each of the `n + 1` cell edges of a
    block `span` wide from `start` snaps to, along one axis of an
    axis-aligned map `scale * u + offset`. The snap is `_snap_rect`'s:
    pixel k spans k - 0.5 to k + 0.5, so an edge rounds to the nearest
    half-integer boundary and the pixels from one edge's boundary to
    the next are the cell's. A mirroring scale gives the edges in
    descending order.
    """
    var edges = List[Int](capacity=n + 1)
    for i in range(n + 1):
        var u = start + span * Float64(i) / Float64(n)
        edges.append(round_to_int(scale * u + offset + 0.5))
    return edges^


def _cells_are_pixels(edges: List[Int]) -> Bool:
    """Whether every cell is exactly one device pixel in ascending
    order, so the block is the image itself and a blit places it.
    """
    for i in range(1, len(edges)):
        if edges[i] != edges[i - 1] + 1:
            return False
    return True


def _cell_of_each(edges: List[Int], v0: Int, v1: Int) -> List[Int]:
    """For each device column (or row) in [v0, v1), the index of the
    cell whose snapped edges enclose it. Consecutive cells share an
    edge, so the cells tile the range and every entry is written; the
    range is inside the block's snapped box.
    """
    var cell = List[Int](length=v1 - v0, fill=0)
    for i in range(len(edges) - 1):
        var c0 = max(min(edges[i], edges[i + 1]), v0)
        var c1 = min(max(edges[i], edges[i + 1]), v1)
        for k in range(c0, c1):
            cell[k - v0] = i
    return cell^


struct _MappedDraw(ImplicitlyCopyable, Movable):
    """What every band of a transformed draw needs but the rows it
    covers: the inverse map, where the source rectangle sits, and how a
    sampled pixel becomes a write.

    `u_lo`/`u_hi` and `v_lo`/`v_hi` bound the drawable part of the
    source in the rectangle's own texel coordinates, and stay in those
    coordinates when the rectangle was cut to the source's edge -- so
    `sx + floor(u)` is the source column a sample point `u` reads
    either way.
    """

    var inv: Matrix2D
    var sx: Int
    var sy: Int
    var u_lo: Float64
    var u_hi: Float64
    var v_lo: Float64
    var v_hi: Float64
    var opacity: Float64
    var nearest: Bool
    var masked: Bool

    def __init__(
        out self,
        inv: Matrix2D,
        sx: Int,
        sy: Int,
        u_lo: Float64,
        u_hi: Float64,
        v_lo: Float64,
        v_hi: Float64,
        opacity: Float64,
        nearest: Bool,
        masked: Bool,
    ):
        self.inv = inv
        self.sx = sx
        self.sy = sy
        self.u_lo = u_lo
        self.u_hi = u_hi
        self.v_lo = v_lo
        self.v_hi = v_hi
        self.opacity = opacity
        self.nearest = nearest
        self.masked = masked


def _to_byte(value: Float64) -> UInt8:
    """A 0-255 float channel as a rounded, clamped byte."""
    if value <= 0.0:
        return 0
    if value >= 255.0:
        return 255
    return UInt8(Int(value + 0.5))


def _scaled_alpha(a: UInt8, opacity: Float64) -> UInt8:
    """`a` faded by `opacity`. An opacity of 1.0 returns `a` itself
    rather than a rounded product of it.
    """
    if opacity >= 1.0:
        return a
    return _to_byte(Float64(a) * opacity)


def _clamped_pixel(
    src: Canvas,
    col: Int,
    row: Int,
    col_min: Int,
    col_max: Int,
    row_min: Int,
    row_max: Int,
) -> Color:
    """The source pixel at (col, row), clamped to the drawable
    rectangle: a bilinear sample near an edge reaches one pixel past
    it, and takes the edge pixel there.
    """
    var c = col
    if c < col_min:
        c = col_min
    elif c > col_max:
        c = col_max
    var r = row
    if r < row_min:
        r = row_min
    elif r > row_max:
        r = row_max
    return src.read_pixel(c, r)


def _draw_canvas_mapped(
    mut dst: Canvas,
    src: Canvas,
    sx: Int,
    sy: Int,
    sw: Int,
    sh: Int,
    matrix: Matrix2D,
    opacity: Float64,
    filter: Filter,
) raises:
    """The body both matrix overloads land in: compose with the canvas
    transform, then `_draw_canvas_matrix`.
    """
    var m = matrix
    if dst.has_transform():
        # The caller's map first, the canvas's frame second, so
        # `matrix` is read in the coordinates the caller draws in.
        m = matrix.then(dst.current_transform())
    _draw_canvas_matrix(dst, src, sx, sy, sw, sh, m, opacity, filter)


def _draw_canvas_matrix(
    mut dst: Canvas,
    src: Canvas,
    sx: Int,
    sy: Int,
    sw: Int,
    sh: Int,
    m: Matrix2D,
    opacity: Float64,
    filter: Filter,
) raises:
    """Draw through `m`, a map from the source rectangle's texel space
    straight to device pixels on the corner convention: take the blit
    when it is a whole-pixel shift of the whole source, and otherwise
    inverse-map the mapped rectangle's bounding box row by row.
    """
    if opacity <= 0.0 or sw <= 0 or sh <= 0:
        return

    # The source rectangle cut to the source. Its local origin stays
    # where the caller put it, so only the drawable range moves.
    var cx = max(0, sx)
    var cy = max(0, sy)
    var cw = min(sx + sw, src.width) - cx
    var ch = min(sy + sh, src.height) - cy
    if cw <= 0 or ch <= 0:
        return

    var scale = opacity
    if scale > 1.0:
        scale = 1.0

    var whole = cx == 0 and cy == 0 and cw == src.width and ch == src.height
    if whole and m.is_translation():
        var tx = round_to_int(m.e)
        var ty = round_to_int(m.f)
        if Float64(tx) == m.e and Float64(ty) == m.f:
            # A shift by whole pixels puts each source pixel on exactly
            # one destination pixel, which is what both filters sample
            # there, so this is the blit.
            _draw_canvas_device(dst, src, tx, ty, _to_byte(scale * 255.0))
            return

    var inv = m.inverse()

    var u_lo = Float64(cx - sx)
    var v_lo = Float64(cy - sy)
    var u_hi = u_lo + Float64(cw)
    var v_hi = v_lo + Float64(ch)

    # The mapped rectangle's bounding box in destination pixels, padded
    # by a pixel so no pixel whose center lands inside it is lost to
    # rounding. Pixels whose sample point falls outside the source are
    # dropped in the loop, so the padding costs a test.
    var p0 = m.apply(u_lo, v_lo)
    var min_x = p0.x
    var max_x = p0.x
    var min_y = p0.y
    var max_y = p0.y
    for corner in range(1, 4):
        var cu = u_hi if corner % 2 == 1 else u_lo
        var cv = v_hi if corner >= 2 else v_lo
        var p = m.apply(cu, cv)
        min_x = min(min_x, p.x)
        max_x = max(max_x, p.x)
        min_y = min(min_y, p.y)
        max_y = max(max_y, p.y)

    var x0 = Int(floor(min_x)) - 1
    var y0 = Int(floor(min_y)) - 1
    var x1 = Int(ceil(max_x)) + 1
    var y1 = Int(ceil(max_y)) + 1

    var region = dst.effective_fill_rect(x0, y0, x1 - x0, y1 - y0)
    var rx = region[0]
    var ry = region[1]
    var rw = region[2]
    var rh = region[3]
    if rw <= 0 or rh <= 0:
        return

    var job = _MappedDraw(
        inv,
        sx,
        sy,
        u_lo,
        u_hi,
        v_lo,
        v_hi,
        scale,
        filter == Filter.NEAREST,
        dst.has_clip_mask(),
    )

    # Bands write disjoint destination rows and only read the source.
    var bands = _bands_for(rw * rh, rh, dst.max_workers())

    if bands == 1:
        _mapped_band(dst, src, job, rx, rw, ry, ry + rh)
        return

    var per_band = (rh + bands - 1) // bands
    var tg = TaskGroup()
    for b in range(bands):
        var band_start = ry + b * per_band
        var band_end = band_start + per_band
        if band_end > ry + rh:
            band_end = ry + rh
        if band_start >= band_end:
            continue
        tg.create_task(
            _mapped_band_async(dst, src, job, rx, rw, band_start, band_end)
        )
    tg.wait()


async def _mapped_band_async(
    mut dst: Canvas,
    src: Canvas,
    job: _MappedDraw,
    first_col: Int,
    col_count: Int,
    first_row: Int,
    last_row: Int,
):
    """`_mapped_band` as a task, so the single-band path stays an
    ordinary call with no coroutine machinery around it.
    """
    _mapped_band(dst, src, job, first_col, col_count, first_row, last_row)


def _mapped_band(
    mut dst: Canvas,
    src: Canvas,
    job: _MappedDraw,
    first_col: Int,
    col_count: Int,
    first_row: Int,
    last_row: Int,
):
    """Sample the source into destination rows [first_row, last_row),
    columns [first_col, first_col + col_count).

    Every coordinate here came from `effective_fill_rect`, so it is on
    the canvas and inside the rectangle clip. A clip path is the one
    thing that cannot be folded into a range, and `job.masked` routes
    those writes through `set_pixel` for its per-pixel coverage.
    """
    var inv = job.inv
    var col_min = job.sx + Int(job.u_lo)
    var col_max = job.sx + Int(job.u_hi) - 1
    var row_min = job.sy + Int(job.v_lo)
    var row_max = job.sy + Int(job.v_hi) - 1

    for py in range(first_row, last_row):
        # The destination pixel's center, mapped back into the source.
        # Stepping u and v by the inverse map's first column walks the
        # row, since the map is affine.
        var yc = Float64(py) + 0.5
        var xc = Float64(first_col) + 0.5
        var u = inv.a * xc + inv.c * yc + inv.e
        var v = inv.b * xc + inv.d * yc + inv.f

        for px in range(first_col, first_col + col_count):
            if (
                u >= job.u_lo
                and u < job.u_hi
                and v >= job.v_lo
                and v < job.v_hi
            ):
                if job.nearest:
                    var color = _clamped_pixel(
                        src,
                        job.sx + Int(floor(u)),
                        job.sy + Int(floor(v)),
                        col_min,
                        col_max,
                        row_min,
                        row_max,
                    )
                    var alpha = _scaled_alpha(color.a, job.opacity)
                    if alpha != 0:
                        if job.masked:
                            dst.set_pixel(px, py, color.with_alpha(alpha))
                        else:
                            dst.write_pixel(px, py, color.with_alpha(alpha))
                else:
                    # The four pixels around the sample point. Their
                    # centers sit at half-integers, so subtracting half
                    # a pixel puts the point's own integer part on the
                    # first of them.
                    var fu = u - 0.5
                    var fv = v - 0.5
                    var i0 = Int(floor(fu))
                    var j0 = Int(floor(fv))
                    var tu = fu - Float64(i0)
                    var tv = fv - Float64(j0)
                    var c00 = _clamped_pixel(
                        src,
                        job.sx + i0,
                        job.sy + j0,
                        col_min,
                        col_max,
                        row_min,
                        row_max,
                    )
                    var c10 = _clamped_pixel(
                        src,
                        job.sx + i0 + 1,
                        job.sy + j0,
                        col_min,
                        col_max,
                        row_min,
                        row_max,
                    )
                    var c01 = _clamped_pixel(
                        src,
                        job.sx + i0,
                        job.sy + j0 + 1,
                        col_min,
                        col_max,
                        row_min,
                        row_max,
                    )
                    var c11 = _clamped_pixel(
                        src,
                        job.sx + i0 + 1,
                        job.sy + j0 + 1,
                        col_min,
                        col_max,
                        row_min,
                        row_max,
                    )
                    # Weighted premultiplied and divided back out
                    # below, so a neighbor with no alpha contributes
                    # its transparency and none of its color.
                    var wa00 = (1.0 - tu) * (1.0 - tv) * Float64(c00.a)
                    var wa10 = tu * (1.0 - tv) * Float64(c10.a)
                    var wa01 = (1.0 - tu) * tv * Float64(c01.a)
                    var wa11 = tu * tv * Float64(c11.a)
                    var acc_a = wa00 + wa10 + wa01 + wa11
                    if acc_a > 0.0:
                        var r = (
                            wa00 * Float64(c00.r)
                            + wa10 * Float64(c10.r)
                            + wa01 * Float64(c01.r)
                            + wa11 * Float64(c11.r)
                        ) / acc_a
                        var g = (
                            wa00 * Float64(c00.g)
                            + wa10 * Float64(c10.g)
                            + wa01 * Float64(c01.g)
                            + wa11 * Float64(c11.g)
                        ) / acc_a
                        var b = (
                            wa00 * Float64(c00.b)
                            + wa10 * Float64(c10.b)
                            + wa01 * Float64(c01.b)
                            + wa11 * Float64(c11.b)
                        ) / acc_a
                        var alpha = _to_byte(acc_a * job.opacity)
                        if alpha != 0:
                            var color = Color(
                                _to_byte(r), _to_byte(g), _to_byte(b), alpha
                            )
                            if job.masked:
                                dst.set_pixel(px, py, color)
                            else:
                                dst.write_pixel(px, py, color)
            u += inv.a
            v += inv.b
