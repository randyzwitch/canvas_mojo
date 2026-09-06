"""Gaussian blur, approximated by three successive box blurs, and
`draw_shadowed`, the drop-shadow / glow composite built on it.

`blur()` operates directly on a `Canvas`'s pixel buffer -- unlike every
other whole-buffer operation in this package (`downsample`,
`draw_canvas`) it ignores the active clip and transform entirely, since
neither "blur the region inside this clip" nor "blur under a rotation"
has an obvious meaning, and the one caller that needs it
(`draw_shadowed`) always blurs a freshly made, unclipped, untransformed
layer.

`draw_shadowed` lives here rather than in `canvas.compose` because its
whole job is arranging a call to `blur()`: it tints a layer, blurs the
tint, and composites the result. Keeping it beside `blur()` keeps the
shadow-specific tinting step (`_tint_and_place`) out of `compose.mojo`,
which otherwise knows nothing about color beyond the straight-alpha
blend every composite already does.

Both of `draw_shadowed`'s composites need the active clip *and* blend
mode to apply -- a shadow multiplied onto its backdrop is a real use --
and `canvas.compose.draw_canvas` only guarantees the second for a
placement that actually needs resampling (a scale or a rotation): a
plain axis-aligned placement, translation-only under the default
SOURCE_OVER, takes a direct-pointer blit that composites with a fixed
straight-alpha source-over regardless of `dst`'s active blend mode (see
`_draw_canvas_device` in `compose.mojo`). `_composite_onto` below calls
`draw_canvas` for that common case and only falls back to a per-pixel
loop through `Canvas.set_pixel` -- the same call `draw_canvas` itself
makes under a clip path -- when the active blend mode isn't
SOURCE_OVER, so the common path stays exactly as fast as it already
was and the uncommon one is still correct.

## The three-box approximation

A single box blur is a poor stand-in for a Gaussian -- it has hard
corners in its frequency response that show up as ringing. Convolving
three box blurs together is a well-known fix: by the central limit
theorem three uniform (box) distributions summed already look close to
a Gaussian, and three passes stay cheap since a box blur's own cost is
independent of its width (see `_box_blur_line` below).

The box widths are derived from the desired standard deviation `sigma`
by P. Kovesi, "Fast Almost-Gaussian Filtering", DICTA 2010: for `n`
boxes,

    w_ideal = sqrt(12 * sigma^2 / n + 1)
    wl = w_ideal rounded down to the nearest odd number
    wu = wl + 2
    m  = round((12*sigma^2 - n*wl^2 - 4*n*wl - 3*n) / (-4*wl - 4))

and `m` boxes of width `wl` plus `n - m` of width `wu` (n=3 here)
approximate a Gaussian of standard deviation `sigma` to within about
3% of its peak error. Odd widths keep every box centered exactly on the
output pixel, so no half-pixel offset bookkeeping is needed between
passes.

`sigma` itself is derived from `radius` the way CSS's `blur()` filter
function defines its equivalent `feGaussianBlur`: standard deviation is
half the given radius (CSS Filter Effects Module Level 1,
`blurEquivalent`). `radius` plays the same role as the HTML5 canvas's
`shadowBlur`, and the box-blur widths below are three approximations of
a Gaussian at that resolution stacked on top of that mapping.

## Premultiplied alpha and edge handling

Both blur passes run on premultiplied color (`channel * alpha / 255`),
converted once at the start and divided back out once at the end, so
that a transparent pixel next to an opaque one contributes none of its
(otherwise meaningless) color to the average -- the same reasoning
`draw_canvas`'s bilinear sampler documents for interpolation.

Each 1-D box average clamps at the buffer's edge: the sample one step
past the last pixel is the last pixel again, repeated as many times as
the box reaches past the edge. This is the same choice `_clamped_pixel`
in `canvas.compose` makes for a bilinear sample near an edge.

## Layout and pass order

A working row holds one pixel as four consecutive Float32 (`_LANES`:
premultiplied r, g, b, then a), so a sliding-window step is one
four-wide vector add and subtract for all four channels; a plane per
channel cost four times the loop-carried latency for the same work.

Box blurs commute, so the three horizontal sweeps run back to back and
then the three vertical ones, rather than alternating. Away from the
edges the result is the same as alternating; at an edge the clamp
meets an intermediate rather than the original, a difference of at
most a few levels within the outermost `_shadow_pad` pixels
(`draw_shadowed` pads by that much, so its shadows are unaffected).

The whole blur is one task per band of rows (`_blur_band`), and each
band streams: a row is converted from a read-only copy of the pixels,
swept horizontally three times in a row-sized buffer, and pushed into
the first of three vertical stages (`_VStage`), each a sliding window
over a ring of its input rows that emits an output row the moment the
window's last row has arrived, into the next stage or, from the last,
back onto the canvas. The rings hold `2r + 2` rows apiece, so a band's
working set is a few hundred kilobytes whatever the canvas size, and
what crosses memory is the pixel bytes in and out. On a many-core
machine that traffic, not the arithmetic, is what a blur costs: the
earlier structure -- a plane per channel, one dispatch per sweep per
channel -- streamed twenty-four full-canvas planes. A band has to start `r0 + r1 + r2` rows above its
own so the vertical windows are full by its first row; those rows are
computed by two bands, so `_bands_for` keeps a band at least that
tall.
"""

from std.math import sqrt
from std.runtime.asyncrt import TaskGroup, parallelism_level

from canvas.aa_crossing import _MIN_PARALLEL_PIXELS
from canvas.buffer import Canvas, BYTES_PER_PIXEL
from canvas.color import Color, _div255
from canvas.compose import draw_canvas

# Values per pixel of the working plane: premultiplied r, g, b, and a.
comptime _LANES = 4
# The plane's element type. Float32 halves the bytes the sweeps move
# against Float64, and a sliding-window sum of byte-sized values keeps
# far more precision than the byte it rounds back to: a window of 2r+1
# pixels sums to at most 255 * (2r + 1), whose Float32 spacing is well
# under 0.01 for any radius a canvas can hold, and the sum's drift
# across a row is a random walk of steps that size.
comptime _PLANE = DType.float32
comptime _Lane = Scalar[_PLANE]
comptime _Pixel = SIMD[_PLANE, _LANES]


def _sigma_from_radius(radius: Float64) -> Float64:
    """Gaussian standard deviation for a `blur()`/`draw_shadowed` radius,
    half of `radius` -- see the module docstring's citation.
    """
    return radius / 2.0


def _box_radii(sigma: Float64) -> Tuple[Int, Int, Int]:
    """The three box-blur radii (each box is `2*r + 1` wide) that
    approximate a Gaussian of standard deviation `sigma`, after Kovesi
    2010 -- see the module docstring for the formula. `sigma <= 0`
    gives three zero radii, each a no-op box.
    """
    if sigma <= 0.0:
        return (0, 0, 0)

    comptime N = 3.0
    var w_ideal = sqrt(12.0 * sigma * sigma / N + 1.0)
    var wl = Int(w_ideal)
    if wl % 2 == 0:
        wl -= 1
    if wl < 1:
        wl = 1
    var wu = wl + 2

    var wlf = Float64(wl)
    var m_ideal = (
        12.0 * sigma * sigma - N * wlf * wlf - 4.0 * N * wlf - 3.0 * N
    ) / (-4.0 * wlf - 4.0)
    var m = Int(m_ideal + 0.5)
    if m < 0:
        m = 0
    if m > 3:
        m = 3

    var r_lo = (wl - 1) // 2
    var r_hi = (wu - 1) // 2

    var radii = List[Int]()
    for _ in range(m):
        radii.append(r_lo)
    for _ in range(3 - m):
        radii.append(r_hi)
    return (radii[0], radii[1], radii[2])


def _clamp_index(i: Int, count: Int) -> Int:
    """`i` clamped to `[0, count - 1]` -- the edge-repeat rule every box
    blur pass reads through.
    """
    if i < 0:
        return 0
    if i > count - 1:
        return count - 1
    return i


def _box_blur_line(
    src: List[_Lane],
    mut dst: List[_Lane],
    start: Int,
    stride: Int,
    count: Int,
    r: Int,
):
    """One edge-clamped box-blur sweep of `count` pixels starting at
    pixel `start` of `src`/`dst` and spaced `stride` pixels apart --
    stride 1 for a horizontal row. A pixel is `_LANES` consecutive
    values, blurred together as one vector.

    A sliding window sum: the sum for pixel `x` is the sum for `x - 1`
    plus the newly-included pixel and minus the one dropped, both
    already edge-clamped, so the whole sweep costs O(count) however
    wide the box (`r`). `r <= 0` is a box one pixel wide, which copies.

    Reads and writes go through pointers rather than `List`'s checked
    `[]`: every pixel index is `start + k * stride` for `k` in
    `[0, count)`, which the callers size to stay inside the plane.
    """
    var sp = src.unsafe_ptr()
    var dp = dst.unsafe_ptr()
    if r <= 0:
        for x in range(count):
            var o = (start + x * stride) * _LANES
            dp.unsafe_offset(o).unsafe_store(
                sp.unsafe_offset(o).unsafe_load[width=_LANES]()
            )
        return
    var inv_window = _Lane(1.0 / Float64(2 * r + 1))
    var sum = _Pixel(0.0)
    for i in range(-r, r + 1):
        sum += sp.unsafe_offset(
            (start + _clamp_index(i, count) * stride) * _LANES
        ).unsafe_load[width=_LANES]()
    dp.unsafe_offset(start * _LANES).unsafe_store(sum * inv_window)

    for x in range(1, count):
        var add = _clamp_index(x + r, count)
        var drop = _clamp_index(x - 1 - r, count)
        sum += (
            sp.unsafe_offset((start + add * stride) * _LANES).unsafe_load[
                width=_LANES
            ]()
            - sp.unsafe_offset((start + drop * stride) * _LANES).unsafe_load[
                width=_LANES
            ]()
        )
        dp.unsafe_offset((start + x * stride) * _LANES).unsafe_store(
            sum * inv_window
        )


def _premultiply_rows(
    source: List[UInt8],
    w: Int,
    first_row: Int,
    last_row: Int,
    mut plane: List[_Lane],
    plane_off: Int,
):
    """Fill `plane`, from its pixel `plane_off`, with rows
    [first_row, last_row) of the `w`-wide RGBA8 pixel buffer `source`,
    color premultiplied by alpha, `_LANES` values per pixel.

    Both buffers are indexed through pointers: `i` ranges over the
    rows' pixels, which the caller sizes `plane` to hold from
    `plane_off`, and `idx` stays inside `source` since it is
    `i * BYTES_PER_PIXEL` plus at most 3.
    """
    var p = source.unsafe_ptr()
    var out = plane.unsafe_ptr().unsafe_offset(plane_off * _LANES)
    var base = first_row * w
    for i in range(base, last_row * w):
        var v = (
            p.unsafe_offset(i * BYTES_PER_PIXEL)
            .unsafe_load[width=_LANES]()
            .cast[_PLANE]()
        )
        var a = v[3]
        var af = a / 255.0
        var scale = _Pixel(af, af, af, 1.0)
        out.unsafe_offset((i - base) * _LANES).unsafe_store(v * scale)


def _round_byte(value: _Lane) -> UInt8:
    """`value` rounded to the nearest integer and clamped to
    `[0, 255]`.
    """
    if value <= 0.0:
        return 0
    if value >= 255.0:
        return 255
    return UInt8(Int(value + 0.5))


def _unpremultiply_rows(
    mut canvas: Canvas,
    plane: List[_Lane],
    plane_off: Int,
    plane_first: Int,
    first_row: Int,
    last_row: Int,
):
    """Write canvas rows [first_row, last_row) of the (still
    premultiplied) `plane`, whose row at pixel `plane_off` is canvas
    row `plane_first`, back into `canvas` as straight RGBA, the
    inverse of `_premultiply_rows`. Indexed through pointers on the
    same bound.
    """
    var p = canvas.pixels.unsafe_ptr()
    var src = plane.unsafe_ptr().unsafe_offset(plane_off * _LANES)
    var w = canvas.width
    comptime ZERO = SIMD[DType.uint8, _LANES](0)
    for i in range(first_row * w, last_row * w):
        var idx = i * BYTES_PER_PIXEL
        var v = src.unsafe_offset((i - plane_first * w) * _LANES).unsafe_load[
            width=_LANES
        ]()
        var a = v[3]
        if _round_byte(a) == 0:
            p.unsafe_offset(idx).unsafe_store(ZERO)
            continue
        var straight = v * 255.0 / a
        straight[3] = a
        # `_round_byte` on every lane: the clamp keeps the cast in range.
        var bytes = (straight + 0.5).clamp(0.0, 255.0).cast[DType.uint8]()
        p.unsafe_offset(idx).unsafe_store(bytes)


struct _VStage(Movable):
    """One vertical box-blur sweep as a stream: rows arrive in order
    through `push`, and `emit` produces the next output row as soon as
    the rows its window needs have arrived, into `out`.

    The window for output row y is input rows y - r through y + r,
    clamped to the canvas: a row before the top counts as row 0 and
    one past the bottom as row h - 1. The running sum is kept as the
    window slides -- add the row entering, drop the row leaving -- so
    the cost per row is two vector operations per pixel however wide
    the box. The ring keeps the last `2r + 2` rows pushed, which is
    every row a drop can still name.
    """

    var r: Int
    var o_lo: Int
    var o_hi: Int
    var h: Int
    var stride: Int
    var slots: Int
    var ring: List[_Lane]
    var sum: List[_Lane]
    var out: List[_Lane]
    var inv_window: _Lane
    var next_out: Int
    # The highest window index the sum holds rows through, and the
    # last canvas row pushed.
    var filled: Int
    var last_in: Int

    def __init__(out self, r: Int, o_lo: Int, o_hi: Int, w: Int, h: Int):
        """A stage producing canvas rows [o_lo, o_hi) of a `w x h`
        plane with box radius `r`."""
        self.r = r
        self.o_lo = o_lo
        self.o_hi = o_hi
        self.h = h
        self.stride = w * _LANES
        self.slots = 2 * r + 2
        self.ring = List[_Lane](unsafe_uninit_length=self.slots * self.stride)
        self.sum = List[_Lane](length=self.stride, fill=0.0)
        self.out = List[_Lane](unsafe_uninit_length=self.stride)
        self.inv_window = _Lane(1.0 / Float64(2 * r + 1))
        self.next_out = o_lo
        self.filled = o_lo - r - 1
        self.last_in = -1

    @always_inline
    def _slot(self, row: Int) -> Int:
        return (row % self.slots) * self.stride

    def _add_row(mut self, row: Int, count: Int):
        """Add `count` copies of ring row `row` to the running sum."""
        var rp = self.ring.unsafe_ptr().unsafe_offset(self._slot(row))
        var sp = self.sum.unsafe_ptr()
        var k = _Lane(count)
        for c in range(0, self.stride, _LANES):
            var acc = sp.unsafe_offset(c).unsafe_load[width=_LANES]()
            acc += rp.unsafe_offset(c).unsafe_load[width=_LANES]() * k
            sp.unsafe_offset(c).unsafe_store(acc)

    def _drop_row(mut self, row: Int):
        var rp = self.ring.unsafe_ptr().unsafe_offset(self._slot(row))
        var sp = self.sum.unsafe_ptr()
        for c in range(0, self.stride, _LANES):
            var acc = sp.unsafe_offset(c).unsafe_load[width=_LANES]()
            acc -= rp.unsafe_offset(c).unsafe_load[width=_LANES]()
            sp.unsafe_offset(c).unsafe_store(acc)

    def push(mut self, row: List[_Lane], j: Int):
        """Canvas row `j`, the next in order, from `row`'s first
        `stride` values. The first row pushed stands in for every
        window index before it as well, which is the top clamp.
        """
        var rp = self.ring.unsafe_ptr().unsafe_offset(self._slot(j))
        var src = row.unsafe_ptr()
        for c in range(0, self.stride, _LANES):
            rp.unsafe_offset(c).unsafe_store(
                src.unsafe_offset(c).unsafe_load[width=_LANES]()
            )
        var count = 1
        if self.last_in < 0:
            count = j - self.filled
        self._add_row(j, count)
        self.filled = j
        self.last_in = j

    def emit(mut self) -> Bool:
        """Produce output row `next_out` into `out` if its window is
        complete, or can be completed by the bottom clamp because the
        last canvas row has been pushed. Returns whether it did; the
        row produced is then `next_out - 1`.
        """
        if self.next_out >= self.o_hi:
            return False
        var y = self.next_out
        var need = y + self.r
        if need > self.filled:
            if self.last_in != self.h - 1:
                return False
            self._add_row(self.h - 1, need - self.filled)
            self.filled = need
        var sp = self.sum.unsafe_ptr()
        var op = self.out.unsafe_ptr()
        for c in range(0, self.stride, _LANES):
            op.unsafe_offset(c).unsafe_store(
                sp.unsafe_offset(c).unsafe_load[width=_LANES]()
                * self.inv_window
            )
        self.next_out = y + 1
        self._drop_row(max(y - self.r, 0))
        return True


@always_inline
def _band_source_rows(y0: Int, y1: Int, halo: Int, h: Int) -> Tuple[Int, Int]:
    """The canvas rows [p0, p0_end) a band blurring rows [y0, y1) has
    to start from: `halo` rows past the band on either side, clamped
    to the canvas.
    """
    return (max(y0 - halo, 0), min(y1 + halo, h))


def _blur_band(
    mut canvas: Canvas,
    source: List[UInt8],
    r0: Int,
    r1: Int,
    r2: Int,
    y0: Int,
    y1: Int,
):
    """Blur canvas rows [y0, y1) from `source`, a copy of the pixels
    before any band wrote, into `canvas`. Bands write disjoint rows.

    The three vertical stages reach `r0 + r1 + r2` rows past the band
    on either side, so the band starts that many rows early
    (`_band_source_rows`); each stage produces one radius fewer of
    them than it consumes, down to the band's own rows. A row goes
    through conversion and the three horizontal sweeps in two
    row-sized buffers, then down the stages, each output row pushed
    on as soon as it is emitted.
    """
    var w = canvas.width
    var h = canvas.height
    var span0 = _band_source_rows(y0, y1, r0 + r1 + r2, h)
    var span1 = _band_source_rows(y0, y1, r1 + r2, h)
    var span2 = _band_source_rows(y0, y1, r2, h)
    var s1 = _VStage(r0, span1[0], span1[1], w, h)
    var s2 = _VStage(r1, span2[0], span2[1], w, h)
    var s3 = _VStage(r2, y0, y1, w, h)
    var ra = List[_Lane](unsafe_uninit_length=w * _LANES)
    var rb = List[_Lane](unsafe_uninit_length=w * _LANES)
    for j in range(span0[0], span0[1]):
        _premultiply_rows(source, w, j, j + 1, ra, 0)
        _box_blur_line(ra, rb, 0, 1, w, r0)
        _box_blur_line(rb, ra, 0, 1, w, r1)
        _box_blur_line(ra, rb, 0, 1, w, r2)
        s1.push(rb, j)
        while s1.emit():
            s2.push(s1.out, s1.next_out - 1)
            while s2.emit():
                s3.push(s2.out, s2.next_out - 1)
                while s3.emit():
                    var y = s3.next_out - 1
                    _unpremultiply_rows(canvas, s3.out, 0, y, y, y + 1)


async def _blur_band_async(
    mut canvas: Canvas,
    source: List[UInt8],
    r0: Int,
    r1: Int,
    r2: Int,
    y0: Int,
    y1: Int,
):
    """`_blur_band` as a task; see `_area_band_async` in
    `canvas.aa_area` for why the heap-owning `canvas`/`source` are
    passed by reference here rather than by value (#97).
    """
    _blur_band(canvas, source, r0, r1, r2, y0, y1)


def _bands_for(w: Int, h: Int, halo: Int) -> Int:
    """How many row bands to blur a `w x h` canvas in: one below
    `_MIN_PARALLEL_PIXELS`, otherwise the core count, capped so that
    a band is at least `halo` rows -- the rows a band computes over
    again for its neighbors are then at most twice its own, which
    measured as the point past which more bands stopped paying.
    """
    if w * h < _MIN_PARALLEL_PIXELS:
        return 1
    var bands = parallelism_level()
    var by_halo = h // max(halo, 1)
    if bands > by_halo:
        bands = by_halo
    if bands > h:
        bands = h
    if bands < 1:
        bands = 1
    return bands


def blur(mut canvas: Canvas, radius: Float64):
    """Blur `canvas` in place with a Gaussian of standard deviation
    `radius / 2`, approximated by three box blurs (see the module
    docstring).

    Ignores the active clip and transform: every pixel in the buffer is
    blurred, regardless of what is currently clipped or transformed.

    Args:
        canvas: Canvas blurred in place.
        radius: Blur radius; `radius <= 0` is a no-op.
    """
    if radius <= 0.0:
        return
    var w = canvas.width
    var h = canvas.height
    if w <= 0 or h <= 0:
        return

    var radii = _box_radii(_sigma_from_radius(radius))
    var r0 = radii[0]
    var r1 = radii[1]
    var r2 = radii[2]
    var halo = r0 + r1 + r2
    if halo <= 0:
        return

    # Every band reads its halo rows from the copy while its neighbors
    # write theirs into `canvas`.
    var source = canvas.pixels.copy()
    var bands = _bands_for(w, h, halo)
    if bands == 1:
        _blur_band(canvas, source, r0, r1, r2, 0, h)
        return
    var per_band = (h + bands - 1) // bands
    var tg = TaskGroup()
    for b in range(bands):
        var band_start = b * per_band
        var band_end = min(band_start + per_band, h)
        if band_start >= band_end:
            continue
        tg.create_task(
            _blur_band_async(canvas, source, r0, r1, r2, band_start, band_end)
        )
    tg.wait()
    # The tasks borrow `source` without the compiler counting it as a
    # use, so name it here to keep it alive past `wait` (#263).
    _ = len(source)


def _shadow_pad(radius: Float64) -> Int:
    """How far a `blur()` of `radius` can spread a pixel from its
    original position: the sum of the three box radii `_box_radii`
    derives from it. `draw_shadowed` pads the shadow layer by this much
    on every side so the blur's edge clamp lands on the padding it
    added, not on the shape's own silhouette.
    """
    if radius <= 0.0:
        return 0
    var radii = _box_radii(_sigma_from_radius(radius))
    return radii[0] + radii[1] + radii[2]


def _tint_and_place(
    mut shadow: Canvas, layer: Canvas, ox: Int, oy: Int, color: Color
):
    """Copy `layer` into `shadow` at (ox, oy), replacing every pixel's
    color with `color` and scaling its alpha by `color`'s own alpha --
    the "make a shadow layer" step of `draw_shadowed`. `shadow` is
    assumed fresh, transparent, and exactly `layer`'s size plus padding
    on every side, so every write below is in bounds.
    """
    for ly in range(layer.height):
        for lx in range(layer.width):
            var a = layer.read_pixel(lx, ly).a
            if a == 0:
                continue
            var tinted_a = UInt8(_div255(Int(a) * Int(color.a)))
            if tinted_a == 0:
                continue
            shadow.write_pixel(ox + lx, oy + ly, color.with_alpha(tinted_a))


def _composite_onto(mut dst: Canvas, src: Canvas, x: Int, y: Int):
    """Composite `src` onto `dst` at (x, y), honouring `dst`'s active
    clip and blend mode -- see the module docstring for why this isn't
    simply `draw_canvas`.
    """
    if dst.blend_mode().is_source_over():
        draw_canvas(dst, src, x, y)
        return
    for sy in range(src.height):
        for sx in range(src.width):
            var p = src.read_pixel(sx, sy)
            if p.a != 0:
                dst.set_pixel(x + sx, y + sy, p)


def draw_shadowed(
    mut dst: Canvas,
    layer: Canvas,
    x: Int,
    y: Int,
    shadow_color: Color,
    blur_radius: Float64,
    offset_x: Int,
    offset_y: Int,
) raises:
    """Composite `layer` onto `dst` at (x, y) with a blurred, tinted,
    offset copy of it underneath -- a drop shadow, or (with
    `offset_x = offset_y = 0`) a soft glow.

    Since a Mojo closure cannot capture a generic "draw my shape" call,
    the caller renders their shape into `layer` themselves, onto a
    transparent background, before calling this. `draw_shadowed` then:

    1. builds a shadow layer the same size as `layer` plus padding
       (see `_shadow_pad`), `layer`'s alpha tinted to `shadow_color`
       (color replaced, alpha multiplied by `shadow_color`'s own
       alpha);
    2. blurs the shadow layer by `blur_radius`;
    3. composites it onto `dst` at
       `(x + offset_x, y + offset_y)`, shifted back by the padding;
    4. composites `layer` itself onto `dst` at (x, y), unchanged, on
       top.

    Both composites go through `_composite_onto`, so `dst`'s active
    clip and blend mode apply to the shadow and the shape alike.

    Args:
        dst: Canvas composited onto.
        layer: The shape, already rendered onto a transparent
            background. Unchanged.
        x: Destination column for `layer`'s left edge.
        y: Destination row for `layer`'s top edge.
        shadow_color: Color of the shadow/glow.
        blur_radius: `blur()` radius applied to the shadow layer.
        offset_x: Horizontal shift of the shadow from the shape.
        offset_y: Vertical shift of the shadow from the shape.

    Raises:
        Error: `layer`'s dimensions are negative once padded (does not
            happen for a `layer` that was itself validly constructed).
    """
    var pad = _shadow_pad(blur_radius)
    var shadow = Canvas(
        layer.width + 2 * pad, layer.height + 2 * pad, Color(0, 0, 0, 0)
    )
    _tint_and_place(shadow, layer, pad, pad, shadow_color)
    blur(shadow, blur_radius)
    _composite_onto(dst, shadow, x - pad + offset_x, y - pad + offset_y)
    _composite_onto(dst, layer, x, y)
