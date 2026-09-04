"""Geometric types shared by the primitives that take more than a
single (x, y) pair.

Two point types, because the package rasterizes at two precisions.
`Point` is whole pixels, what the hard-edged primitives address.
`FPoint` is sub-pixel, what the anti-aliased ones need: an edge crossing
a pixel at x = 10.4 has to stay at 10.4 all the way to the coverage
sweep.

`FPoint` lives here rather than in `path.mojo`, which still re-exports
it, because `canvas.shapes.arcs` samples arcs at sub-pixel precision too
and `path.mojo` imports *from* arcs, so the shared type has to sit below
both.
"""

from std.math import cos, sin


struct Point(ImplicitlyCopyable, Movable):
    """An integer 2D coordinate."""

    var x: Int
    var y: Int

    def __init__(out self, x: Int, y: Int):
        """An integer 2D coordinate.

        Args:
            x: Column.
            y: Row.
        """
        self.x = x
        self.y = y


struct FPoint(ImplicitlyCopyable, Movable):
    """A floating-point 2D coordinate: the sub-pixel counterpart of
    `Point`, and what every anti-aliased path/arc sampler carries
    through to the coverage sweep.
    """

    var x: Float64
    var y: Float64

    def __init__(out self, x: Float64, y: Float64):
        """A floating-point 2D coordinate.

        Args:
            x: Column, sub-pixel precision.
            y: Row, sub-pixel precision.
        """
        self.x = x
        self.y = y


def _round_to_int(value: Float64) -> Int:
    """Round-half-away-from-zero. Float64->Int truncates toward zero,
    so negative values need the opposite offset from positive ones to
    round correctly (e.g. -2.5 must become -3, not -2).

    Imported by path.mojo and canvas.shapes.arcs for the same
    rounding need: the leading underscore means "not part of the public
    API," not "private to this file."
    """
    if value >= 0.0:
        return Int(value + 0.5)
    return Int(value - 0.5)


struct Transform2D(ImplicitlyCopyable, Movable):
    """An affine map from continuous data-space coordinates to integer
    pixel-space coordinates: scale, then rotate, then translate.

        pixel = rotate(data * scale, rotation) + translate

    scale_y is commonly negative: pixel-space y increases downward while
    data-space y conventionally increases upward, so a negative scale_y
    with a matching translate_y flips a vertical axis.

    `rotation` is radians, applied around the origin of the *scaled* data
    space -- before translation, not around wherever
    translate_x/translate_y puts that origin in pixel space. There is no
    pivot parameter; to rotate around another point, shift the data
    coordinates or the translation. Defaults to 0.0.
    """

    var scale_x: Float64
    var scale_y: Float64
    var translate_x: Float64
    var translate_y: Float64
    var rotation: Float64
    # cos(rotation)/sin(rotation), cached rather than recomputed per
    # to_pixel call: rotation is fixed for a Transform2D's lifetime,
    # and to_pixel runs once per data point -- thousands of times for a
    # scatter plot.
    var _cos_rotation: Float64
    var _sin_rotation: Float64

    def __init__(
        out self,
        scale_x: Float64,
        scale_y: Float64,
        translate_x: Float64,
        translate_y: Float64,
        rotation: Float64 = 0.0,
    ):
        """Scale, then rotate, then translate -- see the struct
        docstring above for the full pipeline.

        Args:
            scale_x: Horizontal scale applied before rotation.
            scale_y: Vertical scale applied before rotation. Commonly
                negative to flip a data-space y axis that increases
                upward into pixel-space y, which increases downward.
            translate_x: Horizontal offset applied after rotation.
            translate_y: Vertical offset applied after rotation.
            rotation: Radians, applied around the scaled space's
                origin, before translation.
        """
        self.scale_x = scale_x
        self.scale_y = scale_y
        self.translate_x = translate_x
        self.translate_y = translate_y
        self.rotation = rotation
        self._cos_rotation = cos(rotation)
        self._sin_rotation = sin(rotation)

    def to_point(self, x: Float64, y: Float64) -> FPoint:
        """Map a data-space point to sub-pixel canvas space.

        The same pipeline `to_pixel` applies, without the final
        rounding -- what the anti-aliased primitives want, so a marker at
        y = 44.3 is drawn there rather than at 44. `to_pixel` rounds this
        result, so the two cannot drift apart.

        Args:
            x: Data-space x.
            y: Data-space y.

        Returns:
            The transformed point, unrounded.
        """
        var sx = x * self.scale_x
        var sy = y * self.scale_y

        var rx = sx
        var ry = sy
        if self.rotation != 0.0:
            rx = sx * self._cos_rotation - sy * self._sin_rotation
            ry = sx * self._sin_rotation + sy * self._cos_rotation

        return FPoint(rx + self.translate_x, ry + self.translate_y)

    def to_pixel(self, x: Float64, y: Float64) -> Point:
        """Map a data-space point to the nearest integer pixel.

        Args:
            x: Data-space x.
            y: Data-space y.

        Returns:
            The transformed point, rounded to the nearest pixel.
        """
        var p = self.to_point(x, y)
        return Point(_round_to_int(p.x), _round_to_int(p.y))

    def inverse_point(self, px: Float64, py: Float64) raises -> FPoint:
        """Map a pixel-space point back to the data-space point
        `to_point` would have produced it from -- the exact inverse of
        `to_point`, for hit-testing or cursor readout against a chart's
        own coordinate transform.

        Undoes the pipeline in reverse: subtracts the translation,
        rotates by -rotation, then divides each axis by its own scale.

        Returns a point rather than another `Transform2D`: this
        transform's pipeline is fixed as scale-then-rotate, and the
        exact inverse of an anisotropic (scale_x != scale_y), rotated
        instance is a rotate-then-scale map, which is a different
        matrix in general and does not fit that same shape.

        Args:
            px: Pixel-space x.
            py: Pixel-space y.

        Returns:
            The data-space point.

        Raises:
            Error: `scale_x` or `scale_y` is zero, which collapses
                that axis and cannot be undone.
        """
        if self.scale_x == 0.0 or self.scale_y == 0.0:
            raise Error(
                "Transform2D.inverse_point(): scale_x and scale_y must both"
                " be non-zero to invert (got "
                + String(self.scale_x)
                + ", "
                + String(self.scale_y)
                + ")"
            )

        var ux = px - self.translate_x
        var uy = py - self.translate_y

        var sx = ux
        var sy = uy
        if self.rotation != 0.0:
            sx = ux * self._cos_rotation + uy * self._sin_rotation
            sy = -ux * self._sin_rotation + uy * self._cos_rotation

        return FPoint(sx / self.scale_x, sy / self.scale_y)
