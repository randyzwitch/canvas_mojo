"""Blend and composite modes: what a drawing operation does to the
pixels already there, beyond the source-over every primitive uses by
default.

`Canvas.set_blend_mode` sets the mode, `save`/`restore` carry it, and
every primitive picks it up, since they all reach the buffer through
`set_pixel`/`write_pixel`.

## The arithmetic

Channels and alphas are 0-255 integers throughout, and the canvas
stores straight (non-premultiplied) alpha, so each mode is written the
way `Color.blend_over` is: weights accumulate premultiplied, and one
division by the output alpha turns the result back into a straight
colour.

With `Cs`, `Cb` a source and backdrop channel and `as`, `ab` their
alphas, every mode here is the same Porter-Duff form,

    ao = as*Fa + ab*Fb
    Co = (as*Fa*Cs' + ab*Fb*Cb) / ao

over per-mode fractions `Fa`, `Fb` and a source channel `Cs'` that the
mode's blend function `B` has already mixed into the backdrop:

    Cs' = (1 - ab)*Cs + ab*B(Cb, Cs)

The Porter-Duff operators leave `B(Cb, Cs) = Cs`, so `Cs' = Cs`, and
differ only in the fractions:

    CLEAR             Fa = 0,      Fb = 0
    SOURCE            Fa = 1,      Fb = 0
    DESTINATION       Fa = 0,      Fb = 1
    SOURCE_OVER       Fa = 1,      Fb = 1 - as
    DESTINATION_OVER  Fa = 1 - ab, Fb = 1
    SOURCE_IN         Fa = ab,     Fb = 0
    DESTINATION_IN    Fa = 0,      Fb = as
    SOURCE_OUT        Fa = 1 - ab, Fb = 0
    DESTINATION_OUT   Fa = 0,      Fb = 1 - as
    SOURCE_ATOP       Fa = ab,     Fb = 1 - as
    DESTINATION_ATOP  Fa = 1 - ab, Fb = as
    XOR               Fa = 1 - ab, Fb = 1 - as
    ADD               Fa = 1,      Fb = 1

ADD is the one operator whose weights can sum past 1: `ao` and each
premultiplied channel are clamped to 1, which is the `lighter` of the
HTML5 canvas and Cairo's `ADD`.

The separable blend modes composite source-over (`Fa = 1`,
`Fb = 1 - as`) and differ only in `B`, applied per channel:

    MULTIPLY     B = Cb*Cs
    SCREEN       B = Cb + Cs - Cb*Cs
    OVERLAY      B = HARD_LIGHT(Cs, Cb)
    DARKEN       B = min(Cb, Cs)
    LIGHTEN      B = max(Cb, Cs)
    DIFFERENCE   B = |Cb - Cs|
    EXCLUSION    B = Cb + Cs - 2*Cb*Cs
    COLOR_DODGE  B = 0 if Cb = 0; 1 if Cs = 1; else min(1, Cb / (1 - Cs))
    COLOR_BURN   B = 1 if Cb = 1; 0 if Cs = 0; else 1 - min(1, (1 - Cb) / Cs)
    HARD_LIGHT   B = 2*Cb*Cs                  when Cs <= 0.5
                 B = 1 - 2*(1 - Cb)*(1 - Cs)  otherwise
    SOFT_LIGHT   B = Cb - (1 - 2*Cs)*Cb*(1 - Cb)   when Cs <= 0.5
                 B = Cb + (2*Cs - 1)*(D(Cb) - Cb)  otherwise, with
                 D(Cb) = ((16*Cb - 12)*Cb + 4)*Cb  when Cb <= 0.25
                 D(Cb) = sqrt(Cb)                  otherwise

The non-separable blend modes take the whole RGB triple, since each
moves one of hue, saturation and luminosity from one side to the other:

    HUE         B = SetLum(SetSat(Cs, Sat(Cb)), Lum(Cb))
    SATURATION  B = SetLum(SetSat(Cb, Sat(Cs)), Lum(Cb))
    COLOR       B = SetLum(Cs, Lum(Cb))
    LUMINOSITY  B = SetLum(Cb, Lum(Cs))

with `Lum(C) = 0.3*R + 0.59*G + 0.11*B`, `Sat(C) = max(C) - min(C)`,
and `SetLum`/`SetSat` the helpers of the same names in the W3C
compositing specification. These four and SOFT_LIGHT are computed in
floating point and rounded to the nearest channel value; every other
mode is integer arithmetic that truncates, the way `Color.blend_over`
does.

These are the formulas of the W3C compositing and blending
specification, which is what `globalCompositeOperation` on the HTML5
canvas and Cairo's operators both implement. SOURCE_OVER is the
identity case of both halves: `B(Cb, Cs) = Cs` gives `Cs' = Cs`, and
the fractions are the ones `Color.blend_over` already applies, so the
default mode is byte-for-byte the blend it always was.

## Scope

Three limits are worth knowing before reaching for the Porter-Duff
modes:

- A mode applies only where a shape actually draws. Cairo and the HTML5
  canvas apply an operator over the whole clip region, so
  `destination-in` there clears every pixel the source misses; here a
  pixel no primitive touches is left as it was. DESTINATION_IN is
  therefore "scale the alpha of what this shape covers", not "erase
  everything outside it", and CLEAR erases the shape, not the canvas.
- Coverage folds into the source alpha. An anti-aliased edge, and a
  clip path's own soft edge, reach the blend as a source whose alpha is
  scaled -- so a SOURCE fill writes a translucent pixel along its edge
  rather than a partial mix of source and backdrop.
- `draw_canvas` (canvas/compose.mojo) composites source-over whatever
  the canvas mode is: it blends buffer into buffer without going
  through `set_pixel`.

`SvgCanvas` expresses the blend modes as `mix-blend-mode`, which CSS
defines for every one of them. The Porter-Duff operators have no CSS
keyword and are raster-only: `SvgCanvas` draws source-over under any
of them.
"""

from std.math import sqrt

from canvas.color import Color, _div255


struct BlendMode(Copyable, ImplicitlyCopyable, Movable):
    """How a drawn colour combines with the pixel underneath.

    SOURCE_OVER, the default, is ordinary alpha compositing: the source
    covers the backdrop in proportion to its alpha. The rest are the
    other twelve Porter-Duff operators, the eleven separable blend
    modes and the four non-separable ones; see this module's docstring
    for the formula each one applies.
    """

    var _value: Int

    # Porter-Duff operators: B is the identity, the fractions differ.
    comptime SOURCE_OVER = Self(0)
    comptime SOURCE = Self(1)
    comptime DESTINATION_IN = Self(2)
    comptime DESTINATION_OUT = Self(3)
    comptime XOR = Self(4)
    comptime CLEAR = Self(5)
    comptime DESTINATION = Self(6)
    comptime DESTINATION_OVER = Self(7)
    comptime SOURCE_IN = Self(8)
    comptime SOURCE_OUT = Self(9)
    comptime SOURCE_ATOP = Self(10)
    comptime DESTINATION_ATOP = Self(11)
    comptime ADD = Self(12)

    # Separable blend modes: source-over fractions, B per channel.
    comptime MULTIPLY = Self(13)
    comptime SCREEN = Self(14)
    comptime OVERLAY = Self(15)
    comptime DARKEN = Self(16)
    comptime LIGHTEN = Self(17)
    comptime DIFFERENCE = Self(18)
    comptime EXCLUSION = Self(19)
    comptime COLOR_DODGE = Self(20)
    comptime COLOR_BURN = Self(21)
    comptime HARD_LIGHT = Self(22)
    comptime SOFT_LIGHT = Self(23)

    # Non-separable blend modes: source-over fractions, B on the triple.
    comptime HUE = Self(24)
    comptime SATURATION = Self(25)
    comptime COLOR = Self(26)
    comptime LUMINOSITY = Self(27)

    def __init__(out self, value: Int):
        """Prefer the comptime constants over constructing one
        directly.

        Args:
            value: 0 SOURCE_OVER, 1 SOURCE, 2 DESTINATION_IN,
                3 DESTINATION_OUT, 4 XOR, 5 CLEAR, 6 DESTINATION,
                7 DESTINATION_OVER, 8 SOURCE_IN, 9 SOURCE_OUT,
                10 SOURCE_ATOP, 11 DESTINATION_ATOP, 12 ADD,
                13 MULTIPLY, 14 SCREEN, 15 OVERLAY, 16 DARKEN,
                17 LIGHTEN, 18 DIFFERENCE, 19 EXCLUSION,
                20 COLOR_DODGE, 21 COLOR_BURN, 22 HARD_LIGHT,
                23 SOFT_LIGHT, 24 HUE, 25 SATURATION, 26 COLOR,
                27 LUMINOSITY.
        """
        self._value = value

    def __eq__(self, other: Self) -> Bool:
        return self._value == other._value

    def __ne__(self, other: Self) -> Bool:
        return self._value != other._value

    def is_source_over(self) -> Bool:
        """Whether this is the default mode.

        `write_pixel` and `_fill_region` ask this once per call before
        anything else, since it is what decides between the blend paths
        that were always there and the general one.

        Returns:
            True for SOURCE_OVER.
        """
        return self._value == 0

    def is_separable(self) -> Bool:
        """Whether this is one of the eleven separable blend modes,
        MULTIPLY through SOFT_LIGHT: a `B` applied to each channel on
        its own.

        Returns:
            True for the separable blend modes, False for the
            Porter-Duff operators and the non-separable modes.
        """
        return self._value >= 13 and self._value <= 23

    def is_non_separable(self) -> Bool:
        """Whether this is one of the four non-separable blend modes,
        HUE, SATURATION, COLOR and LUMINOSITY: a `B` that needs the
        whole RGB triple.

        Returns:
            True for the four non-separable modes.
        """
        return self._value >= 24


@always_inline
def _multiply(cb: Int, cs: Int) -> Int:
    return _div255(cb * cs)


@always_inline
def _screen(cb: Int, cs: Int) -> Int:
    return cb + cs - _div255(cb * cs)


@always_inline
def _difference(cb: Int, cs: Int) -> Int:
    return cb - cs if cb > cs else cs - cb


@always_inline
def _exclusion(cb: Int, cs: Int) -> Int:
    return cb + cs - 2 * _div255(cb * cs)


@always_inline
def _color_dodge(cb: Int, cs: Int) -> Int:
    if cb == 0:
        return 0
    if cs == 255:
        return 255
    return min(255, cb * 255 // (255 - cs))


@always_inline
def _color_burn(cb: Int, cs: Int) -> Int:
    if cb == 255:
        return 255
    if cs == 0:
        return 0
    return 255 - min(255, (255 - cb) * 255 // cs)


@always_inline
def _hard_light(cb: Int, cs: Int) -> Int:
    """Hard light: the source channel picks multiply or screen. Overlay
    is the same function with the operands swapped.
    """
    var d = 2 * cs
    if d <= 255:
        # multiply(Cb, 2*Cs). The guard is also what keeps the product
        # at or under 255 * 255, _div255's valid range.
        return _div255(cb * d)
    # screen(Cb, 2*Cs - 1).
    var t = d - 255
    return cb + t - _div255(cb * t)


@always_inline
def _soft_light(cb: Int, cs: Int) -> Int:
    """Soft light, in floating point: the formula has a square root
    and a cubic in it, and rounds to the nearest channel value.
    """
    var b = Float64(cb) / 255.0
    var s = Float64(cs) / 255.0
    var r: Float64
    if s <= 0.5:
        r = b - (1.0 - 2.0 * s) * b * (1.0 - b)
    else:
        var d: Float64
        if b <= 0.25:
            d = ((16.0 * b - 12.0) * b + 4.0) * b
        else:
            d = sqrt(b)
        r = b + (2.0 * s - 1.0) * (d - b)
    return Int(r * 255.0 + 0.5)


@always_inline
def _blend_channel[MODE: Int](cb: Int, cs: Int) -> Int:
    """`B(Cb, Cs)` for one channel of a separable mode, 0-255 in and
    out, with the mode a compile-time parameter so the choice folds
    away. The identity for anything else, which is what makes one
    `_blend_pixel` cover the Porter-Duff operators too.
    """

    @parameter
    if MODE == 13:
        return _multiply(cb, cs)
    elif MODE == 14:
        return _screen(cb, cs)
    elif MODE == 15:
        return _hard_light(cs, cb)
    elif MODE == 16:
        return min(cb, cs)
    elif MODE == 17:
        return max(cb, cs)
    elif MODE == 18:
        return _difference(cb, cs)
    elif MODE == 19:
        return _exclusion(cb, cs)
    elif MODE == 20:
        return _color_dodge(cb, cs)
    elif MODE == 21:
        return _color_burn(cb, cs)
    elif MODE == 22:
        return _hard_light(cb, cs)
    elif MODE == 23:
        return _soft_light(cb, cs)
    else:
        return cs


struct _Rgb(Copyable, ImplicitlyCopyable, Movable):
    """A colour as three 0-1 floats, the form the non-separable modes
    compute in.
    """

    var r: Float64
    var g: Float64
    var b: Float64

    def __init__(out self, r: Float64, g: Float64, b: Float64):
        self.r = r
        self.g = g
        self.b = b

    def __init__(out self, r: Int, g: Int, b: Int):
        self.r = Float64(r) / 255.0
        self.g = Float64(g) / 255.0
        self.b = Float64(b) / 255.0


@always_inline
def _lum(c: _Rgb) -> Float64:
    return 0.3 * c.r + 0.59 * c.g + 0.11 * c.b


@always_inline
def _sat(c: _Rgb) -> Float64:
    return max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b))


@always_inline
def _clip_color(c: _Rgb) -> _Rgb:
    """Pull a colour back into 0-1 without moving its luminosity, by
    scaling its distance from the grey of that luminosity.
    """
    var l = _lum(c)
    var n = min(c.r, min(c.g, c.b))
    var x = max(c.r, max(c.g, c.b))
    var r = c.r
    var g = c.g
    var b = c.b
    if n < 0.0:
        var k = l / (l - n)
        r = l + (r - l) * k
        g = l + (g - l) * k
        b = l + (b - l) * k
    if x > 1.0:
        var k = (1.0 - l) / (x - l)
        r = l + (r - l) * k
        g = l + (g - l) * k
        b = l + (b - l) * k
    return _Rgb(r, g, b)


@always_inline
def _set_lum(c: _Rgb, l: Float64) -> _Rgb:
    var d = l - _lum(c)
    return _clip_color(_Rgb(c.r + d, c.g + d, c.b + d))


@always_inline
def _set_sat(c: _Rgb, s: Float64) -> _Rgb:
    """Rescale a colour's channels so its saturation is `s`: the
    smallest channel goes to 0, the largest to `s`, and the middle one
    keeps its position between them.
    """
    var mx = max(c.r, max(c.g, c.b))
    var mn = min(c.r, min(c.g, c.b))
    if mx <= mn:
        return _Rgb(0.0, 0.0, 0.0)
    var k = s / (mx - mn)
    # The largest channel lands on exactly s and the smallest on 0
    # under the same scaling, so all three go through it.
    return _Rgb((c.r - mn) * k, (c.g - mn) * k, (c.b - mn) * k)


@always_inline
def _blend_triple[MODE: Int](cb: _Rgb, cs: _Rgb) -> _Rgb:
    """`B(Cb, Cs)` for a non-separable mode, on the whole colour."""

    @parameter
    if MODE == 24:
        return _set_lum(_set_sat(cs, _sat(cb)), _lum(cb))
    elif MODE == 25:
        return _set_lum(_set_sat(cb, _sat(cs)), _lum(cb))
    elif MODE == 26:
        return _set_lum(cs, _lum(cb))
    else:
        return _set_lum(cb, _lum(cs))


@always_inline
def _to_channel(v: Float64) -> Int:
    """A 0-1 float to the nearest 0-255 channel, clamped."""
    var c = Int(v * 255.0 + 0.5)
    return min(255, max(0, c))


@always_inline
def _mix_source(ba: Int, cs: Int, b: Int) -> Int:
    """`(1 - ab)*Cs + ab*B`, the backdrop-alpha mix of a source channel
    with its blended value. The two weights sum to 255, so the
    numerator stays at or under 255 * 255 and _div255 applies.
    """
    return _div255((255 - ba) * cs + ba * b)


@always_inline
def _blend_pixel[MODE: Int](src: Color, dst: Color) -> Color:
    """`_blend_pixel` with the mode a compile-time parameter: the
    fraction table and the blend function are chosen when this is
    instantiated, so a loop over pixels carries no mode branches. The
    runtime `_blend_pixel` and `_blend_span` reach the right
    instantiation once per call.
    """
    var sa = Int(src.a)
    var ba = Int(dst.a)

    # Fa and Fb as 0-255 fractions. Every mode not named here
    # composites source-over and carries its difference in
    # _blend_channel or _blend_triple instead.
    var fa = 255
    var fb = 255 - sa

    @parameter
    if MODE == 1:  # SOURCE
        fb = 0
    elif MODE == 2:  # DESTINATION_IN
        fa = 0
        fb = sa
    elif MODE == 3:  # DESTINATION_OUT
        fa = 0
    elif MODE == 4:  # XOR
        fa = 255 - ba
    elif MODE == 5:  # CLEAR
        fa = 0
        fb = 0
    elif MODE == 6:  # DESTINATION
        fa = 0
        fb = 255
    elif MODE == 7:  # DESTINATION_OVER
        fa = 255 - ba
        fb = 255
    elif MODE == 8:  # SOURCE_IN
        fa = ba
        fb = 0
    elif MODE == 9:  # SOURCE_OUT
        fa = 255 - ba
        fb = 0
    elif MODE == 10:  # SOURCE_ATOP
        fa = ba
    elif MODE == 11:  # DESTINATION_ATOP
        fa = 255 - ba
        fb = sa
    elif MODE == 12:  # ADD
        fb = 255

    # as*Fa and ab*Fb, the premultiplied weight each side contributes.
    # Their sum is the output alpha and, for every mode but ADD, never
    # exceeds 255: it is as + ab*(1 - as) for the source-over
    # fractions, and at most max(as, ab) for the others. ADD's sum is
    # as + ab outright and is clamped, along with each channel below.
    var wa = _div255(sa * fa)
    var wb = _div255(ba * fb)
    var out_a = min(255, wa + wb)
    if out_a == 0:
        # Nothing survives from either side, so no colour is defined --
        # and dividing by out_a below would not be either.
        return Color(0, 0, 0, 0)

    var dr = Int(dst.r)
    var dg = Int(dst.g)
    var db = Int(dst.b)
    var sr = Int(src.r)
    var sg = Int(src.g)
    var sb = Int(src.b)

    @parameter
    if MODE >= 24:
        var b = _blend_triple[MODE](_Rgb(dr, dg, db), _Rgb(sr, sg, sb))
        sr = _mix_source(ba, sr, _to_channel(b.r))
        sg = _mix_source(ba, sg, _to_channel(b.g))
        sb = _mix_source(ba, sb, _to_channel(b.b))
    elif MODE >= 13:
        sr = _mix_source(ba, sr, _blend_channel[MODE](dr, sr))
        sg = _mix_source(ba, sg, _blend_channel[MODE](dg, sg))
        sb = _mix_source(ba, sb, _blend_channel[MODE](db, sb))
    if wa + wb == 255:
        # An opaque result with unclamped weights, the common case
        # over an opaque backdrop: each numerator is at most 255 * 255,
        # so the division is _div255's exact shift and the clamp
        # cannot bind. ADD with weights summing past 255 takes the
        # general form below, where the clamp is what defines it.
        return Color(
            UInt8(_div255(wa * sr + wb * dr)),
            UInt8(_div255(wa * sg + wb * dg)),
            UInt8(_div255(wa * sb + wb * db)),
            255,
        )
    return Color(
        UInt8(min(255, (wa * sr + wb * dr) // out_a)),
        UInt8(min(255, (wa * sg + wb * dg) // out_a)),
        UInt8(min(255, (wa * sb + wb * db) // out_a)),
        UInt8(out_a),
    )


def _blend_pixel(mode: BlendMode, src: Color, dst: Color) -> Color:
    """`src` combined with `dst` under `mode`, straight alpha in and
    out -- the general path `Canvas.write_pixel` takes for any mode but
    SOURCE_OVER.

    Passing SOURCE_OVER returns exactly what `Color.blend_over` does;
    the buffer keeps its own source-over paths for speed, not for a
    different answer.
    """
    var v = mode._value
    if v == 1:
        return _blend_pixel[1](src, dst)
    elif v == 2:
        return _blend_pixel[2](src, dst)
    elif v == 3:
        return _blend_pixel[3](src, dst)
    elif v == 4:
        return _blend_pixel[4](src, dst)
    elif v == 5:
        return _blend_pixel[5](src, dst)
    elif v == 6:
        return _blend_pixel[6](src, dst)
    elif v == 7:
        return _blend_pixel[7](src, dst)
    elif v == 8:
        return _blend_pixel[8](src, dst)
    elif v == 9:
        return _blend_pixel[9](src, dst)
    elif v == 10:
        return _blend_pixel[10](src, dst)
    elif v == 11:
        return _blend_pixel[11](src, dst)
    elif v == 12:
        return _blend_pixel[12](src, dst)
    elif v == 13:
        return _blend_pixel[13](src, dst)
    elif v == 14:
        return _blend_pixel[14](src, dst)
    elif v == 15:
        return _blend_pixel[15](src, dst)
    elif v == 16:
        return _blend_pixel[16](src, dst)
    elif v == 17:
        return _blend_pixel[17](src, dst)
    elif v == 18:
        return _blend_pixel[18](src, dst)
    elif v == 19:
        return _blend_pixel[19](src, dst)
    elif v == 20:
        return _blend_pixel[20](src, dst)
    elif v == 21:
        return _blend_pixel[21](src, dst)
    elif v == 22:
        return _blend_pixel[22](src, dst)
    elif v == 23:
        return _blend_pixel[23](src, dst)
    elif v == 24:
        return _blend_pixel[24](src, dst)
    elif v == 25:
        return _blend_pixel[25](src, dst)
    elif v == 26:
        return _blend_pixel[26](src, dst)
    elif v == 27:
        return _blend_pixel[27](src, dst)
    return _blend_pixel[0](src, dst)


def _blend_span_impl[
    MODE: Int
](mut pixels: List[UInt8], start: Int, count: Int, src: Color):
    """`_blend_pixel` over `count` consecutive pixels of `pixels` from
    pixel index `start`, with the mode a compile-time parameter: the
    mode's branches fold away and the loop is the arithmetic and the
    loads and stores. One instantiation per mode, reached through
    `_blend_span`.
    """
    var p = pixels.unsafe_ptr()
    var idx = start * 4
    for _ in range(count):
        var out = _blend_pixel[MODE](
            src,
            Color(
                p[unsafe_offset=idx],
                p[unsafe_offset=idx + 1],
                p[unsafe_offset=idx + 2],
                p[unsafe_offset=idx + 3],
            ),
        )
        p[unsafe_offset=idx] = out.r
        p[unsafe_offset=idx + 1] = out.g
        p[unsafe_offset=idx + 2] = out.b
        p[unsafe_offset=idx + 3] = out.a
        idx += 4


def _blend_span(
    mode: BlendMode, mut pixels: List[UInt8], start: Int, count: Int, src: Color
):
    """Blend `src` onto `count` consecutive pixels of `pixels` from
    pixel index `start` under `mode`: the row loop of a filled region
    under any mode but SOURCE_OVER. The mode is resolved once here
    and the loop runs with it fixed; per pixel the result is exactly
    `_blend_pixel`'s.
    """
    var v = mode._value
    if v == 1:
        _blend_span_impl[1](pixels, start, count, src)
    elif v == 2:
        _blend_span_impl[2](pixels, start, count, src)
    elif v == 3:
        _blend_span_impl[3](pixels, start, count, src)
    elif v == 4:
        _blend_span_impl[4](pixels, start, count, src)
    elif v == 5:
        _blend_span_impl[5](pixels, start, count, src)
    elif v == 6:
        _blend_span_impl[6](pixels, start, count, src)
    elif v == 7:
        _blend_span_impl[7](pixels, start, count, src)
    elif v == 8:
        _blend_span_impl[8](pixels, start, count, src)
    elif v == 9:
        _blend_span_impl[9](pixels, start, count, src)
    elif v == 10:
        _blend_span_impl[10](pixels, start, count, src)
    elif v == 11:
        _blend_span_impl[11](pixels, start, count, src)
    elif v == 12:
        _blend_span_impl[12](pixels, start, count, src)
    elif v == 13:
        _blend_span_impl[13](pixels, start, count, src)
    elif v == 14:
        _blend_span_impl[14](pixels, start, count, src)
    elif v == 15:
        _blend_span_impl[15](pixels, start, count, src)
    elif v == 16:
        _blend_span_impl[16](pixels, start, count, src)
    elif v == 17:
        _blend_span_impl[17](pixels, start, count, src)
    elif v == 18:
        _blend_span_impl[18](pixels, start, count, src)
    elif v == 19:
        _blend_span_impl[19](pixels, start, count, src)
    elif v == 20:
        _blend_span_impl[20](pixels, start, count, src)
    elif v == 21:
        _blend_span_impl[21](pixels, start, count, src)
    elif v == 22:
        _blend_span_impl[22](pixels, start, count, src)
    elif v == 23:
        _blend_span_impl[23](pixels, start, count, src)
    elif v == 24:
        _blend_span_impl[24](pixels, start, count, src)
    elif v == 25:
        _blend_span_impl[25](pixels, start, count, src)
    elif v == 26:
        _blend_span_impl[26](pixels, start, count, src)
    elif v == 27:
        _blend_span_impl[27](pixels, start, count, src)
    else:
        _blend_span_impl[0](pixels, start, count, src)


def _css_blend_name(mode: BlendMode) -> String:
    """The CSS `mix-blend-mode` keyword for a blend mode, or `""` for
    a Porter-Duff operator, which CSS has no keyword for. `SvgCanvas`
    emits the attribute only when this is non-empty.
    """
    if mode == BlendMode.MULTIPLY:
        return "multiply"
    if mode == BlendMode.SCREEN:
        return "screen"
    if mode == BlendMode.OVERLAY:
        return "overlay"
    if mode == BlendMode.DARKEN:
        return "darken"
    if mode == BlendMode.LIGHTEN:
        return "lighten"
    if mode == BlendMode.DIFFERENCE:
        return "difference"
    if mode == BlendMode.EXCLUSION:
        return "exclusion"
    if mode == BlendMode.COLOR_DODGE:
        return "color-dodge"
    if mode == BlendMode.COLOR_BURN:
        return "color-burn"
    if mode == BlendMode.HARD_LIGHT:
        return "hard-light"
    if mode == BlendMode.SOFT_LIGHT:
        return "soft-light"
    if mode == BlendMode.HUE:
        return "hue"
    if mode == BlendMode.SATURATION:
        return "saturation"
    if mode == BlendMode.COLOR:
        return "color"
    if mode == BlendMode.LUMINOSITY:
        return "luminosity"
    return ""
