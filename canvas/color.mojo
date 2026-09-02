"""RGBA color type and basic blending."""


# floor(t / 255), exactly, for any t this file produces.
#
# Every division in blend_over below has a numerator bounded by
# 255 * 255 = 65025 (a channel times an alpha, plus a channel times the
# complementary alpha), and over [0, 65025] the identity
# (t * 32897) >> 23 == t // 255 holds for every single value -- checked
# exhaustively, not spot-checked, and the constants come from that
# search rather than from a rule of thumb.
#
# This is not the familiar `(t + 1 + (t >> 8)) >> 8` blend trick, which
# rounds rather than truncates and would therefore shift output values
# by one across the whole package. The point here is to remove the
# division while leaving every rendered pixel bit-for-bit unchanged.
comptime _DIV255_MUL = 32897
comptime _DIV255_SHIFT = 23


def _div255(value: Int) -> Int:
    """`value // 255`, division-free. Valid for 0 <= value <= 65025,
    which is every numerator blend_over forms.
    """
    return (value * _DIV255_MUL) >> _DIV255_SHIFT


struct Color(ImplicitlyCopyable, Movable):
    """An 8-bit-per-channel RGBA color."""

    var r: UInt8
    var g: UInt8
    var b: UInt8
    var a: UInt8

    def __init__(out self, r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255):
        """An 8-bit-per-channel RGBA color.

        Args:
            r: Red channel, 0-255.
            g: Green channel, 0-255.
            b: Blue channel, 0-255.
            a: Alpha channel, 0-255, 255 fully opaque.
        """
        self.r = r
        self.g = g
        self.b = b
        self.a = a

    def blend_over(self, bg: Color) -> Color:
        """Alpha-composite self over bg (straight-alpha src-over).

        Correct for a translucent background as well as an opaque one:
        a `Canvas` stores per-pixel alpha, so a caller drawing onto a
        transparent-background canvas composites onto pixels that are
        themselves partly transparent.

        Args:
            bg: Background color self is composited onto.

        Returns:
            The composited color.
        """
        if self.a == 255:
            return self
        if self.a == 0:
            return bg

        var sa = Int(self.a)
        var inv = 255 - sa

        # How much of the background survives: its own alpha, scaled by
        # what the source lets through. The output alpha is then just
        # the two contributions added.
        var bg_eff = _div255(Int(bg.a) * inv)
        var out_a = sa + bg_eff
        if out_a == 0:
            # Both fully transparent: no colour is defined, and
            # dividing by out_a below would be undefined too.
            return Color(0, 0, 0, 0)

        # Straight (non-premultiplied) src-over: each channel is the
        # alpha-weighted average of source and surviving background,
        # normalized by the output alpha. Dividing by `out_a` rather
        # than by 255 is what this had wrong before the canvas could
        # hold a translucent pixel -- with an opaque background the two
        # coincide (bg_eff == inv, out_a == 255), so no existing render
        # changes, which was checked across every (channel, alpha)
        # combination rather than argued.
        #
        # A real division, unlike the opaque path's `_div255`, because
        # the divisor varies per pixel. `blend_over_opaque` below is
        # the fast path for the case that is nearly always taken.
        return Color(
            UInt8((Int(self.r) * sa + Int(bg.r) * bg_eff) // out_a),
            UInt8((Int(self.g) * sa + Int(bg.g) * bg_eff) // out_a),
            UInt8((Int(self.b) * sa + Int(bg.b) * bg_eff) // out_a),
            UInt8(out_a),
        )

    def blend_over_opaque(self, bg_r: UInt8, bg_g: UInt8, bg_b: UInt8) -> Color:
        """`blend_over` specialized to a background already known
        opaque -- the overwhelmingly common case, since a canvas
        created with an opaque fill has every pixel at alpha 255 until
        something translucent is drawn onto it. `Canvas.write_pixel`
        checks the destination alpha and calls this when it is 255,
        falling back to `blend_over` when it is not (see buffer.mojo).

        Two things drop out of knowing that. The result's alpha is
        always exactly 255: with bg.a == 255 the general formula gives
        sa + (255 * inv) // 255 == sa + inv == 255, so the fourth
        division is not an approximation to skip but a value already
        determined. And the caller can pass the three background bytes
        it just read, instead of packing them into a `Color` for this
        to immediately take apart again.

        Returns exactly what `blend_over` would against
        `Color(bg_r, bg_g, bg_b)`.

        Args:
            bg_r: Background red channel.
            bg_g: Background green channel.
            bg_b: Background blue channel.

        Returns:
            The composited color, always fully opaque.
        """
        if self.a == 255:
            return Color(self.r, self.g, self.b)
        if self.a == 0:
            return Color(bg_r, bg_g, bg_b)

        var sa = Int(self.a)
        var inv = 255 - sa
        return Color(
            UInt8(_div255(Int(self.r) * sa + Int(bg_r) * inv)),
            UInt8(_div255(Int(self.g) * sa + Int(bg_g) * inv)),
            UInt8(_div255(Int(self.b) * sa + Int(bg_b) * inv)),
        )
