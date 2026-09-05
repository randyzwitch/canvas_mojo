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

from std.math import atan2, cos, sin, sqrt


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


def round_to_int(value: Float64) -> Int:
    """Round-half-away-from-zero, the rounding every primitive here
    applies when it takes a sub-pixel coordinate to a whole pixel.
    Float64->Int truncates toward zero, so negative values need the
    opposite offset from positive ones to round correctly (e.g. -2.5
    must become -3, not -2).

    Not the stdlib's `round`, which is round-half-to-even (2.5 -> 2,
    3.5 -> 4): that rule puts evenly spaced half-pixel coordinates on
    unevenly spaced pixels, so a shape drawn at x = 2.5 and its
    neighbour at 3.5 would sit two pixels apart instead of one.
    Replacing this with `Int(round(x))` changes where things land.

    Public because a caller laying out in `Float64` and drawing
    through the `Int`-taking primitives (`fill_rect`, `fill_circle_aa`)
    needs the same rounding the package uses, so the two agree on
    which pixel a coordinate lands in.

    Args:
        value: The coordinate to round.

    Returns:
        The nearest integer, halves rounded away from zero.
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
        return Point(round_to_int(p.x), round_to_int(p.y))

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


struct Matrix2D(ImplicitlyCopyable, Movable):
    """A general affine map of the plane.

        x' = a * x + c * y + e
        y' = b * x + d * y + f

    in the (a, b, c, d, e, f) layout SVG's `matrix()`, Cairo's
    `cairo_matrix_t` and the HTML5 canvas's `setTransform` share, so a
    matrix written for any of them reads the same here. `Canvas` keeps
    one as its current transform (see `Canvas.save`) and every drawing
    call maps its coordinates through it.

    Where `Transform2D`'s pipeline is fixed as scale, rotate, translate,
    a `Matrix2D` is closed under composition: `then` of any two is
    another `Matrix2D`, which is what lets a canvas accumulate
    `translate`/`rotate`/`scale` calls in any order. `Matrix2D(t)`
    converts a `Transform2D`, so a chart's data-to-pixel mapping can
    become the canvas transform.
    """

    var a: Float64
    var b: Float64
    var c: Float64
    var d: Float64
    var e: Float64
    var f: Float64

    def __init__(
        out self,
        a: Float64,
        b: Float64,
        c: Float64,
        d: Float64,
        e: Float64,
        f: Float64,
    ):
        """The matrix with these coefficients -- see the struct
        docstring for the layout.

        Args:
            a: Coefficient of x in x'.
            b: Coefficient of x in y'.
            c: Coefficient of y in x'.
            d: Coefficient of y in y'.
            e: Offset added to x'.
            f: Offset added to y'.
        """
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.e = e
        self.f = f

    def __init__(out self, transform: Transform2D):
        """The matrix of `transform`'s scale-then-rotate-then-translate
        pipeline: the same mapping `transform.to_point` computes.

        Args:
            transform: The mapping to express as a matrix.
        """
        var cs = cos(transform.rotation)
        var sn = sin(transform.rotation)
        self.a = transform.scale_x * cs
        self.b = transform.scale_x * sn
        self.c = -transform.scale_y * sn
        self.d = transform.scale_y * cs
        self.e = transform.translate_x
        self.f = transform.translate_y

    @staticmethod
    def identity() -> Matrix2D:
        """The map that leaves every point where it is.

        Returns:
            The identity matrix.
        """
        return Matrix2D(1.0, 0.0, 0.0, 1.0, 0.0, 0.0)

    @staticmethod
    def translation(tx: Float64, ty: Float64) -> Matrix2D:
        """A shift by (tx, ty).

        Args:
            tx: Horizontal shift.
            ty: Vertical shift.

        Returns:
            The translation matrix.
        """
        return Matrix2D(1.0, 0.0, 0.0, 1.0, tx, ty)

    @staticmethod
    def scaling(sx: Float64, sy: Float64) -> Matrix2D:
        """A scale about the origin, each axis by its own factor. A
        negative factor mirrors that axis.

        Args:
            sx: Horizontal factor.
            sy: Vertical factor.

        Returns:
            The scaling matrix.
        """
        return Matrix2D(sx, 0.0, 0.0, sy, 0.0, 0.0)

    @staticmethod
    def rotation(angle: Float64) -> Matrix2D:
        """A rotation about the origin by `angle` radians. Positive
        turns +x toward +y, which is clockwise on a y-down canvas.

        Args:
            angle: Radians.

        Returns:
            The rotation matrix.
        """
        var cs = cos(angle)
        var sn = sin(angle)
        return Matrix2D(cs, sn, -sn, cs, 0.0, 0.0)

    def apply(self, x: Float64, y: Float64) -> FPoint:
        """Map a point.

        Args:
            x: Point x.
            y: Point y.

        Returns:
            The mapped point.
        """
        return FPoint(
            self.a * x + self.c * y + self.e,
            self.b * x + self.d * y + self.f,
        )

    def then(self, other: Matrix2D) -> Matrix2D:
        """This map followed by `other`: `self.then(o).apply(p)` is
        `o.apply(self.apply(p))`.

        Args:
            other: The map applied second.

        Returns:
            The composed map.
        """
        return Matrix2D(
            other.a * self.a + other.c * self.b,
            other.b * self.a + other.d * self.b,
            other.a * self.c + other.c * self.d,
            other.b * self.c + other.d * self.d,
            other.a * self.e + other.c * self.f + other.e,
            other.b * self.e + other.d * self.f + other.f,
        )

    def determinant(self) -> Float64:
        """The area scale of the map, negative if it mirrors.

        Returns:
            The value a * d - b * c.
        """
        return self.a * self.d - self.b * self.c

    def inverse(self) raises -> Matrix2D:
        """The map that undoes this one.

        Returns:
            The inverse matrix.

        Raises:
            Error: The determinant is zero, so the map collapses the
                plane onto a line or point and cannot be undone.
        """
        var det = self.determinant()
        if det == 0.0:
            raise Error(
                "Matrix2D.inverse(): the matrix is singular (determinant"
                " 0), so it collapses the plane and cannot be undone"
            )
        return Matrix2D(
            self.d / det,
            -self.b / det,
            -self.c / det,
            self.a / det,
            (self.c * self.f - self.d * self.e) / det,
            (self.b * self.e - self.a * self.f) / det,
        )

    def is_identity(self) -> Bool:
        """Whether the map leaves every point where it is.

        Returns:
            True for the identity matrix exactly.
        """
        return (
            self.a == 1.0
            and self.b == 0.0
            and self.c == 0.0
            and self.d == 1.0
            and self.e == 0.0
            and self.f == 0.0
        )

    def is_translation(self) -> Bool:
        """Whether the map is a pure shift.

        Returns:
            True if the linear part is the identity.
        """
        return (
            self.a == 1.0 and self.b == 0.0 and self.c == 0.0 and self.d == 1.0
        )

    def is_axis_aligned(self) -> Bool:
        """Whether the map keeps axis-aligned rectangles axis-aligned:
        scale (possibly mirrored) and translation only, no rotation or
        shear.

        Returns:
            True if b and c are both zero.
        """
        return self.b == 0.0 and self.c == 0.0

    def is_similarity(self) -> Bool:
        """Whether the map keeps circles circular and angles intact: a
        rotation, a uniform scale and a translation, with no mirroring.

        Returns:
            True for such a map.
        """
        return (
            self.a == self.d
            and self.b == -self.c
            and (self.a != 0.0 or self.b != 0.0)
        )

    def scale_factor(self) -> Float64:
        """The map's length scale: the factor a similarity scales
        every length by, and the geometric mean of the two axis scales
        otherwise -- what a stroke width or dash length is multiplied
        by to follow the map.

        Returns:
            The square root of the absolute determinant.
        """
        return sqrt(abs(self.determinant()))

    def rotation_angle(self) -> Float64:
        """The angle the map turns the +x axis by, in radians.

        Returns:
            The angle atan2(b, a).
        """
        return atan2(self.b, self.a)


def _mapped_fpoints(m: Matrix2D, points: List[FPoint]) -> List[FPoint]:
    var out = List[FPoint](capacity=len(points))
    for p in points:
        out.append(m.apply(p.x, p.y))
    return out^


def _mapped_points(m: Matrix2D, points: List[Point]) -> List[Point]:
    """Whole-pixel points mapped and rounded back to whole pixels."""
    var out = List[Point](capacity=len(points))
    for p in points:
        var q = m.apply(Float64(p.x), Float64(p.y))
        out.append(Point(round_to_int(q.x), round_to_int(q.y)))
    return out^


def _mapped_points_to_fpoints(m: Matrix2D, points: List[Point]) -> List[FPoint]:
    var out = List[FPoint](capacity=len(points))
    for p in points:
        out.append(m.apply(Float64(p.x), Float64(p.y)))
    return out^


def _rounded_fpoints(m: Matrix2D, points: List[FPoint]) -> List[Point]:
    """Sub-pixel points mapped, then rounded to whole pixels for a
    hard-edged primitive."""
    var out = List[Point](capacity=len(points))
    for p in points:
        var q = m.apply(p.x, p.y)
        out.append(Point(round_to_int(q.x), round_to_int(q.y)))
    return out^


def _mapped_rect(
    m: Matrix2D, x: Int, y: Int, width: Int, height: Int
) -> Tuple[Int, Int, Int, Int]:
    """An axis-aligned map's image of a whole-pixel rectangle, as a
    whole-pixel (x, y, width, height): both corners mapped and rounded,
    ordered so a mirroring scale still gives a positive size.
    """
    var p0 = m.apply(Float64(x), Float64(y))
    var p1 = m.apply(Float64(x + width), Float64(y + height))
    var left = round_to_int(min(p0.x, p1.x))
    var right = round_to_int(max(p0.x, p1.x))
    var top = round_to_int(min(p0.y, p1.y))
    var bottom = round_to_int(max(p0.y, p1.y))
    return (left, top, right - left, bottom - top)


def _mapped_bounds(
    m: Matrix2D, x: Int, y: Int, width: Int, height: Int
) -> Tuple[Int, Int, Int, Int]:
    """The whole-pixel bounding box, as (x, y, width, height), of a
    rectangle's four corners under any map."""
    var xs = List[Float64]()
    var ys = List[Float64]()
    for corner in range(4):
        var cx = Float64(x + width) if corner % 2 == 1 else Float64(x)
        var cy = Float64(y + height) if corner >= 2 else Float64(y)
        var q = m.apply(cx, cy)
        xs.append(q.x)
        ys.append(q.y)
    var min_x = xs[0]
    var max_x = xs[0]
    var min_y = ys[0]
    var max_y = ys[0]
    for i in range(1, 4):
        min_x = min(min_x, xs[i])
        max_x = max(max_x, xs[i])
        min_y = min(min_y, ys[i])
        max_y = max(max_y, ys[i])
    var left = Int(min_x) if min_x >= 0.0 else Int(min_x) - 1
    var top = Int(min_y) if min_y >= 0.0 else Int(min_y) - 1
    var right = Int(max_x) + 1
    var bottom = Int(max_y) + 1
    return (left, top, right - left, bottom - top)


def _scaled_lengths(lengths: List[Float64], factor: Float64) -> List[Float64]:
    """Dash lengths given in user space, scaled to device pixels."""
    var out = List[Float64](capacity=len(lengths))
    for v in lengths:
        out.append(v * factor)
    return out^


def _inverse_or_identity(m: Matrix2D) -> Matrix2D:
    """`m.inverse()`, or the identity when `m` is singular. A singular
    transform draws nothing visible (every shape collapses to zero
    area), so what its gradients would have sampled does not matter.
    """
    try:
        return m.inverse()
    except e:
        return Matrix2D.identity()
