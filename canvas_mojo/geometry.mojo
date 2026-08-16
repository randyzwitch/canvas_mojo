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
        self.x = x
        self.y = y


def _round_to_int(value: Float64) -> Int:
    """Round-half-away-from-zero. Float64->Int truncates toward zero,
    so negative values need the opposite offset from positive ones to
    round correctly (e.g. -2.5 must become -3, not -2).

    Reused (imported, not re-derived) by path.mojo and primitives.mojo
    for the same rounding need -- a leading underscore here means
    "not part of the public canvas API," not "private to this file";
    Mojo doesn't restrict cross-module imports by name the way
    Python's convention-only privacy might suggest.
    """
    if value >= 0.0:
        return Int(value + 0.5)
    return Int(value - 0.5)


struct Transform2D(ImplicitlyCopyable, Movable):
    """An affine map from continuous data-space coordinates to integer
    pixel-space coordinates: scale, then rotate, then translate.

        pixel = rotate(data * scale, rotation) + translate

    Deliberately minimal beyond that one fixed pipeline: no general
    matrix composition, and no "map this data range onto this pixel
    range" convenience constructor. That domain/range awareness
    belongs one layer up, in whatever scale types a higher-level
    charting layer eventually provides (a linear scale and friends),
    which would compute a Transform2D's scale/translate from a domain
    and a range; this type only knows the raw affine math, matching
    canvas's low-level "no hidden state,
    no chart concepts" scope.

    scale_y is commonly negative in practice: pixel-space y increases
    downward while data-space y conventionally increases upward, so
    flipping a chart's vertical axis is exactly what a negative
    scale_y (with a matching translate_y) does.

    `rotation` is radians, applied around the origin of the *scaled*
    data space -- before translation, not around wherever translate_x/
    translate_y ends up placing that origin in pixel space. To rotate
    around a different pivot, shift the data coordinates (or
    translate_x/translate_y) the same way composing an extra
    translate-before-rotate-translate-back step would with a general
    matrix; this type doesn't take a separate pivot parameter, since
    nothing built on it has needed one yet. Defaults to 0.0 (no
    rotation), so every existing call site with 4 positional args
    keeps meaning exactly what it did before this field existed.

    This is a different feature from rotating a single rendered
    primitive (e.g. an angled axis-tick label) around its own anchor
    point -- that's draw_text's own `rotation` parameter (see
    canvas_mojo/text/render.mojo), unrelated to this data-to-pixel
    mapping. This type's
    rotation tilts the whole coordinate frame every data point passes
    through, useful for a rotated plot layout generally, not for
    angling one label while keeping everything else upright.
    """

    var scale_x: Float64
    var scale_y: Float64
    var translate_x: Float64
    var translate_y: Float64
    var rotation: Float64

    def __init__(
        out self,
        scale_x: Float64,
        scale_y: Float64,
        translate_x: Float64,
        translate_y: Float64,
        rotation: Float64 = 0.0,
    ):
        self.scale_x = scale_x
        self.scale_y = scale_y
        self.translate_x = translate_x
        self.translate_y = translate_y
        self.rotation = rotation

    def to_pixel(self, x: Float64, y: Float64) -> Point:
        """Map a data-space point to the nearest integer pixel."""
        var sx = x * self.scale_x
        var sy = y * self.scale_y

        var rx = sx
        var ry = sy
        if self.rotation != 0.0:
            var c = cos(self.rotation)
            var s = sin(self.rotation)
            rx = sx * c - sy * s
            ry = sx * s + sy * c

        var px = rx + self.translate_x
        var py = ry + self.translate_y
        return Point(_round_to_int(px), _round_to_int(py))
