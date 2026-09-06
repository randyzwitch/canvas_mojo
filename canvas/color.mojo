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
# package.
comptime _DIV255_MUL = 32897
comptime _DIV255_SHIFT = 23


@always_inline
def _div255(value: Int) -> Int:
    """`value // 255`, division-free. Valid for 0 <= value <= 65025,
    which is every numerator blend_over forms.
    """
    return (value * _DIV255_MUL) >> _DIV255_SHIFT


comptime _HEX_DIGITS = "0123456789abcdef"


def _hex_value(byte: UInt8) raises -> Int:
    """One ASCII hex digit's value, 0-15."""
    var c = Int(byte)
    if c >= ord("0") and c <= ord("9"):
        return c - ord("0")
    if c >= ord("a") and c <= ord("f"):
        return c - ord("a") + 10
    if c >= ord("A") and c <= ord("F"):
        return c - ord("A") + 10
    raise Error("Color(hex): '" + chr(c) + "' is not a hex digit")


def _hex_pair(high: UInt8, low: UInt8) raises -> Int:
    """Two ASCII hex digits as one 0-255 channel value."""
    return _hex_value(high) * 16 + _hex_value(low)


def _hex_byte(value: UInt8) -> String:
    """One channel as two lowercase hex digits.

    `_HEX_DIGITS` is a fixed, pure-ASCII literal, so a raw UTF-8 byte
    index (`[byte=...]`) is exactly the character it looks like. Mojo
    `String` has no plain positional `s[i]` indexing -- it indexes by
    `[byte=]`/`[codepoint=]`/`[grapheme=]`.
    """
    var v = Int(value)
    return String(_HEX_DIGITS[byte=v // 16]) + String(_HEX_DIGITS[byte=v % 16])


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

    def __init__(out self, hex: String) raises:
        """A color from a CSS-style hex string: `"#rrggbb"` or
        `"#rrggbbaa"`, with or without the leading `#`, in either case.
        Digits are two per channel; the 3-digit `#rgb` shorthand is not
        accepted.

        Args:
            hex: `"#rrggbb"` or `"#rrggbbaa"`. Alpha defaults to fully
                opaque when the string carries only six digits.

        Raises:
            Error: `hex` is not 6 or 8 hex digits, or contains a
                character that is not one.
        """
        var digits = String(hex[byte=1:]) if hex.startswith("#") else hex

        var bytes = digits.as_bytes()
        var count = len(bytes)
        if count != 6 and count != 8:
            raise Error(
                "Color(hex): expected 6 or 8 hex digits, optionally led by"
                " '#' (got '"
                + hex
                + "')"
            )

        self.r = UInt8(_hex_pair(bytes[0], bytes[1]))
        self.g = UInt8(_hex_pair(bytes[2], bytes[3]))
        self.b = UInt8(_hex_pair(bytes[4], bytes[5]))
        self.a = UInt8(_hex_pair(bytes[6], bytes[7])) if count == 8 else 255

    def with_alpha(self, a: UInt8) -> Color:
        """This color at a different alpha, its channels untouched --
        the usual way a palette entry is faded for a hover state or a
        de-emphasized series.

        Args:
            a: Alpha channel for the result, 0-255.

        Returns:
            The same r/g/b at alpha `a`.
        """
        return Color(self.r, self.g, self.b, a)

    def to_hex(self) -> String:
        """This color as `"#rrggbb"`, lowercase.

        Alpha is not included: the two consumers of a hex string here,
        SVG and CSS, both carry opacity in a separate attribute, and
        `svg.mojo` writes `self.a` into one. Read `.a` for it.

        Returns:
            `"#rrggbb"`.
        """
        return "#" + _hex_byte(self.r) + _hex_byte(self.g) + _hex_byte(self.b)

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
            # Both fully transparent: no color is defined, and
            # dividing by out_a below would be undefined too.
            return Color(0, 0, 0, 0)

        # Straight (non-premultiplied) src-over: each channel is the
        # alpha-weighted average of source and surviving background,
        # normalized by the output alpha. With an opaque background
        # dividing by `out_a` and by 255 coincide (bg_eff == inv,
        # out_a == 255), so this and `blend_over_opaque` agree.
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


struct ColorSpace(Copyable, Equatable, ImplicitlyCopyable, Movable, Writable):
    """The space colors are mixed in: where a blend or a gradient
    interpolation does its arithmetic.

    SRGB, the default, mixes the stored 8-bit channel values directly,
    as browsers, Cairo and most raster libraries do; LINEAR converts
    each channel through the sRGB transfer function to linear light
    first and back afterward, so that a 50% blend of black and white
    is the gray that reflects half the light (sRGB 188) rather than
    the one halfway up the byte scale (128), and a red-to-green
    gradient does not sag through a dark middle. `Canvas.set_color_space`
    and `GradientStops.set_color_space` choose it; see each for what
    it covers.
    """

    var _value: Int

    comptime SRGB = Self(0)
    comptime LINEAR = Self(1)

    def __init__(out self, value: Int):
        """Prefer the comptime constants over constructing one
        directly.

        Args:
            value: 0 SRGB, 1 LINEAR.
        """
        self._value = value

    def __eq__(self, other: Self) -> Bool:
        return self._value == other._value

    def is_linear(self) -> Bool:
        """Whether this is LINEAR."""
        return self._value == Self.LINEAR._value

    def write_to[W: Writer](self, mut writer: W):
        if self._value == Self.LINEAR._value:
            writer.write("LINEAR")
        else:
            writer.write("SRGB")


# Steps the linear-to-sRGB table resolves: 12 bits keeps every sRGB
# byte reachable, including the steep first few near black, and a
# byte round-trips through both tables unchanged.
comptime _LINEAR_STEPS = 4096


struct _Transfer(Copyable, Movable):
    """The sRGB transfer function (IEC 61966-2-1) both ways as lookup
    tables: `linear` takes a channel byte to linear light in [0, 1],
    `byte` takes linear light back to the nearest channel byte. Built
    on demand by `build`, since a `Canvas` or a `GradientStops` that
    never leaves SRGB should not pay for the 4096 `pow` calls.
    """

    var to_linear: List[Float32]
    var to_srgb: List[UInt8]
    var ready: Bool

    def __init__(out self):
        self.to_linear = List[Float32]()
        self.to_srgb = List[UInt8]()
        self.ready = False

    def build(mut self):
        if self.ready:
            return
        self.to_linear = List[Float32](length=256, fill=0.0)
        for i in range(256):
            var c = Float64(i) / 255.0
            var lin = c / 12.92
            if c > 0.04045:
                lin = ((c + 0.055) / 1.055) ** 2.4
            self.to_linear[i] = Float32(lin)
        self.to_srgb = List[UInt8](length=_LINEAR_STEPS + 1, fill=0)
        for i in range(_LINEAR_STEPS + 1):
            var lin = Float64(i) / Float64(_LINEAR_STEPS)
            var c = lin * 12.92
            if lin > 0.0031308:
                c = 1.055 * (lin ** (1.0 / 2.4)) - 0.055
            var v = Int(c * 255.0 + 0.5)
            if v > 255:
                v = 255
            self.to_srgb[i] = UInt8(v)
        self.ready = True

    @always_inline
    def linear(self, b: UInt8) -> Float32:
        """Channel byte to linear light. `build` must have run."""
        return self.to_linear.unsafe_ptr()[unsafe_offset=Int(b)]

    @always_inline
    def byte(self, v: Float32) -> UInt8:
        """Linear light to the nearest channel byte, clamped."""
        var x = v
        if x <= 0.0:
            return 0
        if x >= 1.0:
            return 255
        return self.to_srgb.unsafe_ptr()[
            unsafe_offset=Int(x * Float32(_LINEAR_STEPS) + 0.5)
        ]

    def blend_over_opaque(
        self, src: Color, bg_r: UInt8, bg_g: UInt8, bg_b: UInt8
    ) -> Color:
        """`Color.blend_over_opaque` with the channels mixed in linear
        light: the result is opaque, and each channel is the source's
        linear value weighted by its alpha plus the background's
        weighted by the rest, encoded back to a byte."""
        if src.a == 255:
            return Color(src.r, src.g, src.b)
        if src.a == 0:
            return Color(bg_r, bg_g, bg_b)
        var sa = Float32(src.a) / 255.0
        var inv = 1.0 - sa
        return Color(
            self.byte(self.linear(src.r) * sa + self.linear(bg_r) * inv),
            self.byte(self.linear(src.g) * sa + self.linear(bg_g) * inv),
            self.byte(self.linear(src.b) * sa + self.linear(bg_b) * inv),
        )

    def blend_over(self, src: Color, bg: Color) -> Color:
        """`Color.blend_over` with the channels mixed in linear light:
        straight-alpha source-over, the output alpha as in
        `Color.blend_over`, each channel the alpha-weighted mix of
        linear values divided back out by the output alpha."""
        if src.a == 255:
            return src
        if src.a == 0:
            return bg
        if bg.a == 255:
            return self.blend_over_opaque(src, bg.r, bg.g, bg.b)
        var sa = Float32(src.a) / 255.0
        var ba = Float32(bg.a) / 255.0 * (1.0 - sa)
        var oa = sa + ba
        if oa <= 0.0:
            return Color(0, 0, 0, 0)
        return Color(
            self.byte((self.linear(src.r) * sa + self.linear(bg.r) * ba) / oa),
            self.byte((self.linear(src.g) * sa + self.linear(bg.g) * ba) / oa),
            self.byte((self.linear(src.b) * sa + self.linear(bg.b) * ba) / oa),
            UInt8(Int(oa * 255.0 + 0.5)),
        )
