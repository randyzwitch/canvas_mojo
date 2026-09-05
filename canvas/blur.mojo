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
which otherwise knows nothing about colour beyond the straight-alpha
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
3% of its peak error. Odd widths keep every box centred exactly on the
output pixel, so no half-pixel offset bookkeeping is needed between
passes.

`sigma` itself is derived from `radius` the way CSS's `blur()` filter
function defines its equivalent `feGaussianBlur`: standard deviation is
half the given radius (CSS Filter Effects Module Level 1,
`blurEquivalent`). `radius` plays the same role as the HTML5 canvas's
`shadowBlur`, and the box-blur widths below are three approximations of
a Gaussian at that resolution stacked on top of that mapping.

## Premultiplied alpha and edge handling

Both blur passes run on premultiplied colour (`channel * alpha / 255`),
converted once at the start and divided back out once at the end, so
that a transparent pixel next to an opaque one contributes none of its
(otherwise meaningless) colour to the average -- the same reasoning
`draw_canvas`'s bilinear sampler documents for interpolation.

Each 1-D box average clamps at the buffer's edge: the sample one step
past the last pixel is the last pixel again, repeated as many times as
the box reaches past the edge. This is the same choice `_clamped_pixel`
in `canvas.compose` makes for a bilinear sample near an edge.
"""

from std.math import sqrt
from std.runtime.asyncrt import TaskGroup, parallelism_level

from canvas.aa_crossing import _MIN_PARALLEL_PIXELS
from canvas.buffer import Canvas, BYTES_PER_PIXEL
from canvas.color import Color, _div255
from canvas.compose import draw_canvas


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
    src: List[Float64],
    mut dst: List[Float64],
    start: Int,
    stride: Int,
    count: Int,
    r: Int,
):
    """One edge-clamped box-blur sweep of `count` samples starting at
    `src[start]`/`dst[start]` and spaced `stride` apart -- stride 1 for
    a horizontal row, the plane's width for a vertical column.

    A sliding window sum: the sum for sample `x` is the sum for `x - 1`
    plus the newly-included sample and minus the one dropped, both
    already edge-clamped, so the whole sweep costs O(count) however
    wide the box (`r`) is. `r` is assumed positive; the caller skips
    zero-radius boxes as a no-op.

    Reads and writes go through pointers rather than `List`'s checked
    `[]`: every index is `start + k * stride` for `k` in `[0, count)`,
    which `_box_blur_h_band`/`_box_blur_v_band` size to stay inside the
    plane's length.
    """
    var sp = src.unsafe_ptr()
    var dp = dst.unsafe_ptr()
    var inv_window = 1.0 / Float64(2 * r + 1)
    var sum = 0.0
    for i in range(-r, r + 1):
        sum += sp[unsafe_offset=start + _clamp_index(i, count) * stride]
    dp[unsafe_offset=start] = sum * inv_window

    for x in range(1, count):
        var add = _clamp_index(x + r, count)
        var drop = _clamp_index(x - 1 - r, count)
        sum += (
            sp[unsafe_offset=start + add * stride]
            - sp[unsafe_offset=start + drop * stride]
        )
        dp[unsafe_offset=start + x * stride] = sum * inv_window


def _box_blur_h_band(
    src: List[Float64],
    mut dst: List[Float64],
    w: Int,
    r: Int,
    first_row: Int,
    last_row: Int,
):
    """`_box_blur_line` across rows [first_row, last_row) of a `w`-wide
    plane, one row at a time.
    """
    for row in range(first_row, last_row):
        _box_blur_line(src, dst, row * w, 1, w, r)


async def _box_blur_h_band_async(
    src: List[Float64],
    mut dst: List[Float64],
    w: Int,
    r: Int,
    first_row: Int,
    last_row: Int,
):
    """`_box_blur_h_band` as a task; see `_area_band_async` in
    `canvas.aa_area` for why the heap-owning `src`/`dst` are passed by
    reference here rather than by value (#97).
    """
    _box_blur_h_band(src, dst, w, r, first_row, last_row)


def _box_blur_v_band(
    src: List[Float64],
    mut dst: List[Float64],
    w: Int,
    h: Int,
    r: Int,
    first_col: Int,
    last_col: Int,
):
    """`_box_blur_line` down columns [first_col, last_col) of a `w x h`
    plane, one column at a time.
    """
    for col in range(first_col, last_col):
        _box_blur_line(src, dst, col, w, h, r)


async def _box_blur_v_band_async(
    src: List[Float64],
    mut dst: List[Float64],
    w: Int,
    h: Int,
    r: Int,
    first_col: Int,
    last_col: Int,
):
    """`_box_blur_v_band` as a task; see `_box_blur_h_band_async`."""
    _box_blur_v_band(src, dst, w, h, r, first_col, last_col)


def _box_blur_horizontal(
    src: List[Float64], mut dst: List[Float64], w: Int, h: Int, r: Int
):
    """Horizontal box-blur pass, `src` into `dst`: banded across rows
    above `_MIN_PARALLEL_PIXELS`, one task per row band.
    """
    var bands = 1
    if w * h >= _MIN_PARALLEL_PIXELS:
        bands = parallelism_level()
        if bands > h:
            bands = h
        if bands < 1:
            bands = 1

    if bands == 1:
        _box_blur_h_band(src, dst, w, r, 0, h)
        return

    var per_band = (h + bands - 1) // bands
    var tg = TaskGroup()
    for b in range(bands):
        var band_start = b * per_band
        var band_end = min(band_start + per_band, h)
        if band_start >= band_end:
            continue
        tg.create_task(
            _box_blur_h_band_async(src, dst, w, r, band_start, band_end)
        )
    tg.wait()


def _box_blur_vertical(
    src: List[Float64], mut dst: List[Float64], w: Int, h: Int, r: Int
):
    """Vertical box-blur pass, `src` into `dst`: banded across columns
    above `_MIN_PARALLEL_PIXELS`, one task per column band.
    """
    var bands = 1
    if w * h >= _MIN_PARALLEL_PIXELS:
        bands = parallelism_level()
        if bands > w:
            bands = w
        if bands < 1:
            bands = 1

    if bands == 1:
        _box_blur_v_band(src, dst, w, h, r, 0, w)
        return

    var per_band = (w + bands - 1) // bands
    var tg = TaskGroup()
    for b in range(bands):
        var band_start = b * per_band
        var band_end = min(band_start + per_band, w)
        if band_start >= band_end:
            continue
        tg.create_task(
            _box_blur_v_band_async(src, dst, w, h, r, band_start, band_end)
        )
    tg.wait()


def _box_blur_plane(
    mut plane: List[Float64], mut scratch: List[Float64], w: Int, h: Int, r: Int
):
    """Box-blur `plane` (row-major, `w x h`) in place by radius `r`:
    horizontal sweep into `scratch`, then vertical sweep back into
    `plane`. `scratch` is the caller's to reuse across the three
    approximation passes and the four colour planes, so this allocates
    nothing.

    Horizontal bands split disjoint rows; vertical bands split disjoint
    columns -- each band only ever reads and writes its own rows or
    columns, which is what lets them run as concurrent tasks (the same
    banding `canvas.resize.downsample` and `canvas.compose`'s matrix
    draw use).
    """
    if r <= 0:
        return
    _box_blur_horizontal(plane, scratch, w, h, r)
    _box_blur_vertical(scratch, plane, w, h, r)


def _premultiply_planes(
    canvas: Canvas,
    mut pr: List[Float64],
    mut pg: List[Float64],
    mut pb: List[Float64],
    mut pa: List[Float64],
):
    """Fill the four planes with `canvas`'s pixels, colour
    premultiplied by alpha. One pass, not banded: it runs once per
    `blur()` call, against the up-to-24 banded sweeps (3 boxes x 2
    directions x 4 channels) the convolution itself does, so it is not
    where the parallelism would pay for itself.

    Both the pixel buffer and the four planes are indexed through
    pointers: `i` ranges over `[0, canvas.width * canvas.height)`,
    which `blur()` sizes every plane to hold, and `idx` stays inside
    the pixel buffer since it is `i * BYTES_PER_PIXEL` plus at most 3.
    """
    var p = canvas.pixels.unsafe_ptr()
    var rp = pr.unsafe_ptr()
    var gp = pg.unsafe_ptr()
    var bp = pb.unsafe_ptr()
    var ap = pa.unsafe_ptr()
    for i in range(canvas.width * canvas.height):
        var idx = i * BYTES_PER_PIXEL
        var a = Float64(p[unsafe_offset=idx + 3])
        var af = a / 255.0
        rp[unsafe_offset=i] = Float64(p[unsafe_offset=idx]) * af
        gp[unsafe_offset=i] = Float64(p[unsafe_offset=idx + 1]) * af
        bp[unsafe_offset=i] = Float64(p[unsafe_offset=idx + 2]) * af
        ap[unsafe_offset=i] = a


def _round_byte(value: Float64) -> UInt8:
    """`value` rounded to the nearest integer and clamped to
    `[0, 255]`.
    """
    if value <= 0.0:
        return 0
    if value >= 255.0:
        return 255
    return UInt8(Int(value + 0.5))


def _unpremultiply_planes(
    mut canvas: Canvas,
    pr: List[Float64],
    pg: List[Float64],
    pb: List[Float64],
    pa: List[Float64],
):
    """Write the four (still premultiplied) planes back into `canvas`
    as straight RGBA, the inverse of `_premultiply_planes`.

    Indexed through pointers on the same bound `_premultiply_planes`
    documents: `i` ranges over `[0, canvas.width * canvas.height)`.
    """
    var p = canvas.pixels.unsafe_ptr()
    var rp = pr.unsafe_ptr()
    var gp = pg.unsafe_ptr()
    var bp = pb.unsafe_ptr()
    var ap = pa.unsafe_ptr()
    for i in range(canvas.width * canvas.height):
        var idx = i * BYTES_PER_PIXEL
        var a = ap[unsafe_offset=i]
        var a_byte = _round_byte(a)
        if a_byte == 0:
            p[unsafe_offset=idx] = 0
            p[unsafe_offset=idx + 1] = 0
            p[unsafe_offset=idx + 2] = 0
            p[unsafe_offset=idx + 3] = 0
            continue
        p[unsafe_offset=idx] = _round_byte(rp[unsafe_offset=i] * 255.0 / a)
        p[unsafe_offset=idx + 1] = _round_byte(gp[unsafe_offset=i] * 255.0 / a)
        p[unsafe_offset=idx + 2] = _round_byte(bp[unsafe_offset=i] * 255.0 / a)
        p[unsafe_offset=idx + 3] = a_byte


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
    if r0 <= 0 and r1 <= 0 and r2 <= 0:
        return

    var n = w * h
    var pr = List[Float64](length=n, fill=0.0)
    var pg = List[Float64](length=n, fill=0.0)
    var pb = List[Float64](length=n, fill=0.0)
    var pa = List[Float64](length=n, fill=0.0)
    _premultiply_planes(canvas, pr, pg, pb, pa)

    # Tuple elements can't be indexed by a loop variable (a comptime
    # subscript is required), so the three passes are unrolled rather
    # than looped over `radii`. `_box_blur_plane` itself is a no-op for
    # a radius of 0.
    var scratch = List[Float64](length=n, fill=0.0)
    for r in [r0, r1, r2]:
        _box_blur_plane(pr, scratch, w, h, r)
        _box_blur_plane(pg, scratch, w, h, r)
        _box_blur_plane(pb, scratch, w, h, r)
        _box_blur_plane(pa, scratch, w, h, r)

    _unpremultiply_planes(canvas, pr, pg, pb, pa)


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
    colour with `color` and scaling its alpha by `color`'s own alpha --
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
       (colour replaced, alpha multiplied by `shadow_color`'s own
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
        shadow_color: Colour of the shadow/glow.
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
