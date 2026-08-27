"""Minimal geometric types shared by the primitives that need more
than a single (x, y) pair -- polylines/polygons take a sequence of
points, where two parallel List[Int]s would be error-prone to keep in
sync.
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


def _round_to_int(value: Float64) -> Int:
    """Round-half-away-from-zero. Float64->Int truncates toward zero,
    so negative values need the opposite offset from positive ones to
    round correctly (e.g. -2.5 must become -3, not -2).

    Imported by path.mojo and canvas_mojo.shapes.arcs for the same
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

    Minimal beyond that fixed pipeline: no general matrix composition
    and no "map this data range onto this pixel range" constructor.
    Domain/range awareness belongs a layer up, in a charting layer's
    scale types, which would compute a Transform2D's scale/translate
    from a domain and a range. This type knows only the affine math.

    scale_y is commonly negative in practice: pixel-space y increases
    downward while data-space y conventionally increases upward, so
    flipping a chart's vertical axis is exactly what a negative
    scale_y (with a matching translate_y) does.

    `rotation` is radians, applied around the origin of the *scaled*
    data space -- before translation, not around wherever
    translate_x/translate_y places that origin in pixel space. There's
    no pivot parameter; to rotate around another point, shift the data
    coordinates or the translation the way a
    translate-rotate-translate-back composition would. Defaults to 0.0.

    Distinct from draw_text's `rotation`, which angles one rendered
    label around its own anchor. This tilts the whole coordinate frame
    every data point passes through.
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

    def to_pixel(self, x: Float64, y: Float64) -> Point:
        """Map a data-space point to the nearest integer pixel.

        Args:
            x: Data-space x.
            y: Data-space y.

        Returns:
            The transformed point, rounded to the nearest pixel.
        """
        var sx = x * self.scale_x
        var sy = y * self.scale_y

        var rx = sx
        var ry = sy
        if self.rotation != 0.0:
            rx = sx * self._cos_rotation - sy * self._sin_rotation
            ry = sx * self._sin_rotation + sy * self._cos_rotation

        var px = rx + self.translate_x
        var py = ry + self.translate_y
        return Point(_round_to_int(px), _round_to_int(py))
