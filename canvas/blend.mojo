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

The four Porter-Duff modes leave `B(Cb, Cs) = Cs`, so `Cs' = Cs`, and
differ only in the fractions:

    SOURCE_OVER       Fa = 1,      Fb = 1 - as
    SOURCE            Fa = 1,      Fb = 0
    DESTINATION_IN    Fa = 0,      Fb = as
    DESTINATION_OUT   Fa = 0,      Fb = 1 - as
    XOR               Fa = 1 - ab, Fb = 1 - as

The six separable blend modes composite source-over (`Fa = 1`,
`Fb = 1 - as`) and differ only in `B`:

    MULTIPLY    B = Cb*Cs
    SCREEN      B = Cb + Cs - Cb*Cs
    OVERLAY     B = 2*Cb*Cs                  when Cb <= 0.5
                B = 1 - 2*(1 - Cb)*(1 - Cs)  otherwise
    DARKEN      B = min(Cb, Cs)
    LIGHTEN     B = max(Cb, Cs)
    DIFFERENCE  B = |Cb - Cs|

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
  everything outside it".
- Coverage folds into the source alpha. An anti-aliased edge, and a
  clip path's own soft edge, reach the blend as a source whose alpha is
  scaled -- so a SOURCE fill writes a translucent pixel along its edge
  rather than a partial mix of source and backdrop.
- `draw_canvas` (canvas/compose.mojo) composites source-over whatever
  the canvas mode is: it blends buffer into buffer without going
  through `set_pixel`.
"""

from canvas.color import Color, _div255


struct BlendMode(Copyable, ImplicitlyCopyable, Movable):
    """How a drawn colour combines with the pixel underneath.

    SOURCE_OVER, the default, is ordinary alpha compositing: the source
    covers the backdrop in proportion to its alpha. The other ten are
    the four remaining Porter-Duff operators the HTML5 canvas exposes
    and the six separable blend modes; see this module's docstring for
    the formula each one applies.
    """

    var _value: Int

    comptime SOURCE_OVER = Self(0)
    comptime SOURCE = Self(1)
    comptime DESTINATION_IN = Self(2)
    comptime DESTINATION_OUT = Self(3)
    comptime XOR = Self(4)
    comptime MULTIPLY = Self(5)
    comptime SCREEN = Self(6)
    comptime OVERLAY = Self(7)
    comptime DARKEN = Self(8)
    comptime LIGHTEN = Self(9)
    comptime DIFFERENCE = Self(10)

    def __init__(out self, value: Int):
        """Prefer the comptime constants over constructing one
        directly.

        Args:
            value: 0 SOURCE_OVER, 1 SOURCE, 2 DESTINATION_IN,
                3 DESTINATION_OUT, 4 XOR, 5 MULTIPLY, 6 SCREEN,
                7 OVERLAY, 8 DARKEN, 9 LIGHTEN, 10 DIFFERENCE.
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
        """Whether this is one of the six separable blend modes --
        MULTIPLY, SCREEN, OVERLAY, DARKEN, LIGHTEN, DIFFERENCE -- as
        opposed to a Porter-Duff operator. The separable modes are the
        ones with a `B` other than the identity, and the ones SVG can
        express as `mix-blend-mode`.

        Returns:
            True for the six blend modes, False for the five
            Porter-Duff operators.
        """
        return self._value >= 5


def _blend_channel(mode: BlendMode, cb: Int, cs: Int) -> Int:
    """`B(Cb, Cs)` for one channel, 0-255 in and out. The identity for
    a Porter-Duff mode, which is what makes one `_blend_pixel` cover
    both halves of the list.
    """
    if mode == BlendMode.MULTIPLY:
        return _div255(cb * cs)
    if mode == BlendMode.SCREEN:
        return cb + cs - _div255(cb * cs)
    if mode == BlendMode.OVERLAY:
        var d = 2 * cb
        if d <= 255:
            # multiply(Cs, 2*Cb). The guard is also what keeps the
            # product at or under 255 * 255, _div255's valid range.
            return _div255(cs * d)
        # screen(Cs, 2*Cb - 1), the other half of hard-light.
        var t = d - 255
        return cs + t - _div255(cs * t)
    if mode == BlendMode.DARKEN:
        return min(cb, cs)
    if mode == BlendMode.LIGHTEN:
        return max(cb, cs)
    if mode == BlendMode.DIFFERENCE:
        return cb - cs if cb > cs else cs - cb
    return cs


def _blend_source_channel(mode: BlendMode, ba: Int, cb: Int, cs: Int) -> Int:
    """`Cs'`: the source channel with the mode's blend function mixed
    in against the backdrop, in proportion to the backdrop's own alpha.
    A transparent backdrop leaves the source colour alone, which is why
    a blend mode does nothing over an untouched transparent canvas.
    """
    if not mode.is_separable():
        return cs
    var b = _blend_channel(mode, cb, cs)
    # The two weights sum to 255, so the numerator stays at or under
    # 255 * 255 and _div255 applies.
    return _div255((255 - ba) * cs + ba * b)


def _blend_pixel(mode: BlendMode, src: Color, dst: Color) -> Color:
    """`src` combined with `dst` under `mode`, straight alpha in and
    out -- the general path `Canvas.write_pixel` takes for any mode but
    SOURCE_OVER.

    Passing SOURCE_OVER returns exactly what `Color.blend_over` does;
    the buffer keeps its own source-over paths for speed, not for a
    different answer.
    """
    var sa = Int(src.a)
    var ba = Int(dst.a)

    # Fa and Fb as 0-255 fractions. Every mode not named here
    # composites source-over and carries its difference in
    # _blend_channel instead.
    var fa = 255
    var fb = 255 - sa
    if mode == BlendMode.SOURCE:
        fb = 0
    elif mode == BlendMode.DESTINATION_IN:
        fa = 0
        fb = sa
    elif mode == BlendMode.DESTINATION_OUT:
        fa = 0
    elif mode == BlendMode.XOR:
        fa = 255 - ba

    # as*Fa and ab*Fb, the premultiplied weight each side contributes.
    # Their sum is the output alpha and never exceeds 255: it is
    # as + ab*(1 - as) for the source-over fractions, and at most
    # max(as, ab) for the others.
    var wa = _div255(sa * fa)
    var wb = _div255(ba * fb)
    var out_a = wa + wb
    if out_a == 0:
        # Nothing survives from either side, so no colour is defined --
        # and dividing by out_a below would not be either.
        return Color(0, 0, 0, 0)

    var sr = _blend_source_channel(mode, ba, Int(dst.r), Int(src.r))
    var sg = _blend_source_channel(mode, ba, Int(dst.g), Int(src.g))
    var sb = _blend_source_channel(mode, ba, Int(dst.b), Int(src.b))
    return Color(
        UInt8((wa * sr + wb * Int(dst.r)) // out_a),
        UInt8((wa * sg + wb * Int(dst.g)) // out_a),
        UInt8((wa * sb + wb * Int(dst.b)) // out_a),
        UInt8(out_a),
    )


def _css_blend_name(mode: BlendMode) -> String:
    """The CSS `mix-blend-mode` keyword for a separable mode, or `""`
    for a Porter-Duff one, which CSS has no keyword for. `SvgCanvas`
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
    return ""
