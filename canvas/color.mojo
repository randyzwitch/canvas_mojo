"""RGBA color type and basic blending."""


# floor(t / 255), exactly, for any t this file produces.
#
# Every division in blend_over below has a numerator bounded by
# 255 * 255 = 65025, and over [0, 65025] the identity
# (t * 32897) >> 23 == t // 255 holds for every value -- checked
# exhaustively.
#
# Not the familiar `(t + 1 + (t >> 8)) >> 8` trick, which rounds rather
# than truncates and would shift output values by one across the whole
# package. This removes the division leaving every pixel unchanged.
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
        # normalized by the output alpha. With an opaque background
        # dividing by `out_a` and by 255 coincide (bg_eff == inv,
        # out_a == 255), so no existing render changes.
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
        opaque. `Canvas.write_pixel` checks the destination alpha and
        calls this when it is 255, falling back to `blend_over` when it
        is not (see buffer.mojo).

        With bg.a == 255 the general formula's output alpha reduces to
        sa + (255 * inv) // 255 == sa + inv == 255, so the result is
        always fully opaque and the per-pixel division drops out. The
        caller passes the three background bytes it already read rather
        than packing them into a `Color`. The result is exactly what
        `blend_over` returns against `Color(bg_r, bg_g, bg_b)`.

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
