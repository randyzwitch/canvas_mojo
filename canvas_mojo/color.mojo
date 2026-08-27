"""RGBA color type and basic blending."""


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
        """Alpha-composite self over bg (src-over compositing).

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

        var out_r = (Int(self.r) * sa + Int(bg.r) * inv) // 255
        var out_g = (Int(self.g) * sa + Int(bg.g) * inv) // 255
        var out_b = (Int(self.b) * sa + Int(bg.b) * inv) // 255
        var out_a = sa + (Int(bg.a) * inv) // 255

        return Color(UInt8(out_r), UInt8(out_g), UInt8(out_b), UInt8(out_a))
