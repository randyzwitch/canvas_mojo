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
from std.runtime.asyncrt import TaskGroup, parallelism_level

from canvas.aa_crossing import _MIN_PARALLEL_PIXELS
from canvas.buffer import Canvas, BYTES_PER_PIXEL
from canvas.color import Color, _div255
from canvas.geometry import Matrix2D, round_to_int
from canvas.mask import Mask, apply_mask


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
    draw_canvas(dst, apply_mask(src, mask), x, y, 255)


def _draw_canvas_device(
    mut dst: Canvas, src: Canvas, x: Int, y: Int, opacity: UInt8
):
    """`draw_canvas` for device-space arguments: the body every
    call lands in. It has no transform check of its own, so its
    loops compile with nothing ahead of them and it never calls
    back into the public function.
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
    _draw_canvas_mapped(dst, src, sx, sy, sw, sh, matrix, opacity, filter)


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
    transform, take the blit when the result is a whole-pixel shift of
    the whole source, and otherwise inverse-map the mapped rectangle's
    bounding box row by row.
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

    var m = matrix
    if dst.has_transform():
        # The caller's map first, the canvas's frame second, so
        # `matrix` is read in the coordinates the caller draws in.
        m = matrix.then(dst.current_transform())

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

    # Bands write disjoint destination rows and only read the source,
    # the basis the fill sweep bands on, and the same threshold: below
    # it the tasks cost more than the rows do.
    var bands = 1
    if rw * rh >= _MIN_PARALLEL_PIXELS:
        bands = parallelism_level()
        if bands > rh:
            bands = rh
        if bands < 1:
            bands = 1

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
