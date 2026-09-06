"""Color gradients: `LinearGradient`, `RadialGradient` and
`ConicGradient`, consumed by the gradient fills in canvas.shapes.rects
(`fill_rect_gradient`, `fill_rect_radial_gradient`) and path.mojo
(`fill_path_gradient`, `fill_path_radial_gradient`,
`fill_path_conic_gradient` and their `_aa` variants). Those are the
only gradient-aware fills; circle/ellipse/polygon variants aren't
built, and `ConicGradient` has no rect fill of its own.

All three reduce a point to a projected position `t` -- distance along
an axis (linear), from a center relative to a radius (radial), or the
angle around a center relative to a full turn (conic) -- then hand it
to a `GradientStops` for stop lookup and interpolation. Only the
projection differs, so only the projection lives on each struct, and
`GradientStops` stands on its own as a color ramp for a caller that
has already normalized a value to [0, 1].

Linear and radial extend "pad" only: a point past either endpoint or
outside the radius takes that edge's color, clamped. No repeat or
reflect. A conic gradient has no such edge -- its projection wraps
around a full turn instead of clamping, so `t` is already in [0, 1)
before it reaches the ramp.
"""

from std.math import atan2, floor, pi, sqrt

from canvas.color import Color, ColorSpace, _Transfer


struct GradientStop(ImplicitlyCopyable, Movable):
    """One color stop: the color a ramp holds at `offset`, 0.0 to
    1.0.
    """

    var offset: Float64
    var color: Color

    def __init__(out self, offset: Float64, color: Color):
        self.offset = offset
        self.color = color


def _round_channel(value: Float64) -> UInt8:
    # Channel values are non-negative here (interpolated between two
    # UInt8s), so +0.5 truncation is round-to-nearest -- none of the
    # away-from-zero handling geometry.mojo's signed pixel coordinates
    # need.
    return UInt8(value + 0.5)


struct GradientStops(Copyable, Movable, Sized):
    """A one-dimensional color ramp: stops sorted by offset, and the
    interpolated color at any position in [0, 1]. The half of every
    gradient that does not depend on geometry, and on its own the
    color scale a data value maps through once it is normalized.

    Index, measure and iterate it like a list: `len(stops)`,
    `stops[i]` and `for stop in stops`.
    """

    var _stops: List[GradientStop]
    # The space `color_at` interpolates in (see `set_color_space`),
    # and the transfer tables, built when it first becomes LINEAR.
    var _space: ColorSpace
    var _transfer: _Transfer

    def __init__(out self):
        """A ramp with no stops yet; `color_at` returns transparent
        black until one is added.
        """
        self._stops = List[GradientStop]()
        self._space = ColorSpace.SRGB
        self._transfer = _Transfer()

    def set_color_space(mut self, space: ColorSpace):
        """Set the space `color_at` interpolates in: SRGB, the default,
        mixes the stops' channel bytes directly; LINEAR mixes them in
        linear light (see `ColorSpace`), which keeps a ramp between two
        saturated colors from sagging through a dark middle. Alpha
        interpolates the same way in both. `SvgCanvas` writes a
        LINEAR ramp with `color-interpolation="linearRGB"`.

        Args:
            space: The space the ramp interpolates in.
        """
        self._space = space
        if space.is_linear():
            self._transfer.build()

    def color_space(self) -> ColorSpace:
        """The space `color_at` interpolates in.

        Returns:
            The current space, `ColorSpace.SRGB` until
            `set_color_space` says otherwise.
        """
        return self._space

    def __len__(self) -> Int:
        return len(self._stops)

    def __getitem__(self, i: Int) -> GradientStop:
        return self._stops[i]

    def __iter__(ref self) -> type_of(self._stops.__iter__()):
        return self._stops.__iter__()

    def add_stop(mut self, offset: Float64, color: Color):
        """Add a stop, keeping the ramp sorted by offset with insertion
        order preserved among equal offsets.

        Two stops at one offset are a hard color transition, and which
        was added first decides which side of it owns which color --
        so the insert goes *after* any stop already at this offset,
        and `color_at` reads the run's ends accordingly.

        Args:
            offset: Position 0.0 to 1.0. Stops need not be added in
                order.
            color: This stop's color.
        """
        var at = len(self._stops)
        while at > 0 and self._stops[at - 1].offset > offset:
            at -= 1
        self._stops.insert(at, GradientStop(offset, color))

    def color_at(self, t_in: Float64) -> Color:
        """The ramp's color at `t_in`, clamped to [0, 1] first (the
        "pad" extend), interpolated between the two stops bracketing
        it. The bracketing pair comes from a binary search over the
        sorted stops.

        This runs once per pixel of every gradient fill, so the stops
        are read through a pointer rather than copied out of the list
        per probe; the arithmetic is unchanged.

        Args:
            t_in: Position along the ramp.

        Returns:
            The interpolated color, transparent black if no stops have
            been added yet.
        """
        var count = len(self._stops)
        if count == 0:
            return Color(0, 0, 0, 0)
        var sp = self._stops.unsafe_ptr()
        if count == 1:
            return sp[unsafe_offset=0].color

        var t = t_in
        if t < 0.0:
            t = 0.0
        elif t > 1.0:
            t = 1.0

        if t <= sp[unsafe_offset=0].offset:
            return sp[unsafe_offset=0].color
        if t >= sp[unsafe_offset=count - 1].offset:
            return sp[unsafe_offset=count - 1].color

        # The last stop at or below t. `lo` ends on it: the loop keeps
        # `stops[lo].offset <= t < stops[hi].offset`, which holds at entry
        # because the two clamps above ruled out both ends.
        var lo = 0
        var hi = count - 1
        while hi - lo > 1:
            var mid = (lo + hi) // 2
            if sp[unsafe_offset=mid].offset <= t:
                lo = mid
            else:
                hi = mid

        ref before = sp[unsafe_offset=lo]
        # t landing exactly on a stop takes that stop's color. With
        # several at the offset, `lo` is the last of them -- the one that
        # owns the far side of a hard transition.
        if before.offset == t:
            return before.color
        ref after = sp[unsafe_offset=hi]

        if before.offset == after.offset:
            return before.color

        var local_t = (t - before.offset) / (after.offset - before.offset)
        if self._space.is_linear():
            var lt = Float32(local_t)
            ref tr = self._transfer
            return Color(
                tr.byte(
                    tr.linear(before.color.r)
                    + lt
                    * (tr.linear(after.color.r) - tr.linear(before.color.r))
                ),
                tr.byte(
                    tr.linear(before.color.g)
                    + lt
                    * (tr.linear(after.color.g) - tr.linear(before.color.g))
                ),
                tr.byte(
                    tr.linear(before.color.b)
                    + lt
                    * (tr.linear(after.color.b) - tr.linear(before.color.b))
                ),
                _round_channel(
                    Float64(before.color.a)
                    + local_t
                    * (Float64(after.color.a) - Float64(before.color.a))
                ),
            )
        var br = Float64(before.color.r)
        var bg = Float64(before.color.g)
        var bb = Float64(before.color.b)
        var ba = Float64(before.color.a)
        var ar = Float64(after.color.r)
        var ag = Float64(after.color.g)
        var ab = Float64(after.color.b)
        var aa = Float64(after.color.a)
        return Color(
            _round_channel(br + local_t * (ar - br)),
            _round_channel(bg + local_t * (ag - bg)),
            _round_channel(bb + local_t * (ab - bb)),
            _round_channel(ba + local_t * (aa - ba)),
        )


trait ColorSource:
    """Anything that can answer "what color is at this point?" -- the
    fill source a gradient-filled shape queries per pixel.

    Conformance is nominal per Mojo's trait rule, so a new fill source
    has to declare `ColorSource` explicitly to be usable as one.
    """

    def color_at(self, x: Float64, y: Float64) -> Color:
        """This source's color at (x, y), in canvas pixel
        coordinates.

        Args:
            x: Point x.
            y: Point y.

        Returns:
            The color to paint at that point.
        """
        ...


struct LinearGradient(ColorSource, Movable):
    """A linear gradient along the axis from (x0, y0) to (x1, y1).
    Add stops with add_stop(), then pass to fill_rect_gradient/
    fill_path_gradient (or query color_at() directly).

    Stops need not be added in offset order: `add_stop` inserts each
    into place, so `stops` is always sorted by offset and color_at()
    finds its bracketing pair by binary search.
    """

    var x0: Float64
    var y0: Float64
    var x1: Float64
    var y1: Float64
    var stops: GradientStops
    # Cached from x0/y0/x1/y1, which never change after construction:
    # color_at runs per pixel, and this axis/length math depends only
    # on the endpoints, never the query point.
    var _axis_x: Float64
    var _axis_y: Float64
    var _len2: Float64

    def __init__(out self, x0: Float64, y0: Float64, x1: Float64, y1: Float64):
        """A gradient with no stops yet -- add at least one with
        add_stop() before calling color_at().

        Args:
            x0: Axis start x, offset 0.0.
            y0: Axis start y, offset 0.0.
            x1: Axis end x, offset 1.0.
            y1: Axis end y, offset 1.0.
        """
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1
        self.stops = GradientStops()
        self._axis_x = x1 - x0
        self._axis_y = y1 - y0
        self._len2 = self._axis_x * self._axis_x + self._axis_y * self._axis_y

    def add_stop(mut self, offset: Float64, color: Color):
        """Add a color stop at `offset` (0.0 to 1.0 along the axis).

        Args:
            offset: Position along the axis, 0.0 at (x0, y0), 1.0 at
                (x1, y1). Stops need not be added in offset order;
                each is inserted into place.
            color: This stop's color.
        """
        self.stops.add_stop(offset, color)

    def set_color_space(mut self, space: ColorSpace):
        """Set the space the ramp interpolates in; see
        `GradientStops.set_color_space`.

        Args:
            space: The space the ramp interpolates in.
        """
        self.stops.set_color_space(space)

    def color_space(self) -> ColorSpace:
        """The space the ramp interpolates in.

        Returns:
            The current space, `ColorSpace.SRGB` by default.
        """
        return self.stops.color_space()

    def color_at(self, x: Float64, y: Float64) -> Color:
        """The gradient's color at (x, y): project onto the axis, clamp
        to [0, 1] ("pad" extend), then interpolate between the two
        stops bracketing that position.

        Args:
            x: Point x.
            y: Point y.

        Returns:
            The interpolated color, transparent black if no stops have
            been added yet.
        """
        var t = 0.0
        if self._len2 != 0.0:
            t = (
                (x - self.x0) * self._axis_x + (y - self.y0) * self._axis_y
            ) / self._len2
        return self.stops.color_at(t)


struct RadialGradient(ColorSource, Movable):
    """A radial gradient centered at (cx, cy) with the given radius:
    offset 0.0 is the center, offset 1.0 is the circle at `radius`.
    Add stops with add_stop(), then pass to fill_rect_radial_gradient/
    fill_path_radial_gradient (or query color_at() directly).

    The two-circle form of SVG, Cairo and the HTML5 canvas is the
    keyword constructor: offset 0.0 is then the focal circle at
    (fx, fy) with radius `fr`, offset 1.0 the outer circle, and the
    stops in between lie on the circles interpolated from one to the
    other. The focal circle has to lie inside the outer one; the
    constructor raises otherwise. The plain constructor is the
    special case fx = cx, fy = cy, fr = 0.
    """

    var cx: Float64
    var cy: Float64
    var radius: Float64
    var fx: Float64
    var fy: Float64
    var fr: Float64
    var stops: GradientStops
    # Whether the focal circle differs from the center point, which
    # is what decides between the distance formula and the quadratic.
    var _focal: Bool

    def __init__(out self, cx: Float64, cy: Float64, radius: Float64):
        """A gradient with no stops yet -- add at least one with
        add_stop() before calling color_at().

        Args:
            cx: Center x, offset 0.0.
            cy: Center y, offset 0.0.
            radius: Distance at which offset reaches 1.0.
        """
        self.cx = cx
        self.cy = cy
        self.radius = radius
        self.fx = cx
        self.fy = cy
        self.fr = 0.0
        self.stops = GradientStops()
        self._focal = False

    def __init__(
        out self,
        cx: Float64,
        cy: Float64,
        radius: Float64,
        *,
        fx: Float64,
        fy: Float64,
        fr: Float64 = 0.0,
    ) raises:
        """The two-circle form: offset 0.0 is the focal circle, offset
        1.0 the outer circle at (cx, cy, radius).

        Args:
            cx: Outer circle's center x.
            cy: Outer circle's center y.
            radius: Outer circle's radius, where offset reaches 1.0.
            fx: Focal circle's center x, where offset is 0.0.
            fy: Focal circle's center y.
            fr: Focal circle's radius, 0 (the default) for a focal
                point.

        Raises:
            If `fr` is negative, or the focal circle reaches outside
            the outer circle: the extended-cone form those describe
            is not supported.
        """
        if fr < 0.0:
            raise Error("RadialGradient: fr must be >= 0, got " + String(fr))
        var dx = fx - cx
        var dy = fy - cy
        if sqrt(dx * dx + dy * dy) + fr > radius:
            raise Error(
                "RadialGradient: the focal circle ("
                + String(fx)
                + ", "
                + String(fy)
                + ", r="
                + String(fr)
                + ") reaches outside the outer circle ("
                + String(cx)
                + ", "
                + String(cy)
                + ", r="
                + String(radius)
                + ")"
            )
        self.cx = cx
        self.cy = cy
        self.radius = radius
        self.fx = fx
        self.fy = fy
        self.fr = fr
        self.stops = GradientStops()
        self._focal = fx != cx or fy != cy or fr != 0.0

    def add_stop(mut self, offset: Float64, color: Color):
        """Add a color stop at `offset` (0.0 at the center, 1.0 at
        `radius`).

        Args:
            offset: Position from the center, 0.0 to 1.0. Stops need
                not be added in offset order; each is inserted into
                place.
            color: This stop's color.
        """
        self.stops.add_stop(offset, color)

    def set_color_space(mut self, space: ColorSpace):
        """Set the space the ramp interpolates in; see
        `GradientStops.set_color_space`.

        Args:
            space: The space the ramp interpolates in.
        """
        self.stops.set_color_space(space)

    def color_space(self) -> ColorSpace:
        """The space the ramp interpolates in.

        Returns:
            The current space, `ColorSpace.SRGB` by default.
        """
        return self.stops.color_space()

    def color_at(self, x: Float64, y: Float64) -> Color:
        """The gradient's color at (x, y): project onto [0, 1] as
        `distance_from_center / radius`, clamp ("pad" extend -- a
        distance is never negative, so only the far end ever clamps),
        then the stop lookup LinearGradient.color_at uses.

        radius == 0.0 collapses every stop's circle to one point and
        resolves to t=1.0, a solid fill of the highest-offset stop's
        color, rather than dividing by zero.

        With a focal circle, t is the largest offset whose
        interpolated circle passes through (x, y): with the center
        c(t) = f + t*(c - f) and radius r(t) = fr + t*(radius - fr),
        the larger root of |p - c(t)| = r(t). A point inside the focal
        circle has both roots negative and pads to 0.

        Args:
            x: Point x.
            y: Point y.

        Returns:
            The interpolated color, transparent black if no stops have
            been added yet.
        """
        if self._focal:
            return self.stops.color_at(self._focal_t(x, y))
        var dx = x - self.cx
        var dy = y - self.cy
        var dist = sqrt(dx * dx + dy * dy)
        var t = 1.0
        if self.radius != 0.0:
            t = dist / self.radius
        return self.stops.color_at(t)

    def _focal_t(self, x: Float64, y: Float64) -> Float64:
        """The two-circle offset at (x, y), before the pad clamp.

        Writing everything relative to the focal center, with
        cd = c - f, dr = radius - fr and pd = p - f, the circle
        condition |pd - t*cd|^2 = (fr + t*dr)^2 is the quadratic

            a*t^2 - 2*b*t + k = 0
            a = cd.cd - dr^2,  b = pd.cd + fr*dr,  k = pd.pd - fr^2

        The focal circle lies inside the outer one, so dr > |cd| and
        a < 0: the roots are real for every point and the larger one
        is (b - sqrt(b^2 - a*k)) / a. a == 0 only when the focal
        circle touches the outer one from inside, where the equation
        is linear.
        """
        var cdx = self.cx - self.fx
        var cdy = self.cy - self.fy
        var dr = self.radius - self.fr
        var pdx = x - self.fx
        var pdy = y - self.fy
        var a = cdx * cdx + cdy * cdy - dr * dr
        var b = pdx * cdx + pdy * cdy + self.fr * dr
        var k = pdx * pdx + pdy * pdy - self.fr * self.fr
        if a == 0.0:
            # b == 0 is the focal point itself (k == 0, offset 0) or
            # the tangent line through it, which no circle reaches;
            # the half-plane behind that line pads to 0, so it does.
            if b == 0.0:
                return 0.0
            return k / (2.0 * b)
        var disc = b * b - a * k
        if disc < 0.0:
            return 1.0
        var root = sqrt(disc)
        var t1 = (b + root) / a
        var t2 = (b - root) / a
        return max(t1, t2)


struct ConicGradient(ColorSource, Movable):
    """A conic (angular) gradient centered at (cx, cy): offset 0.0 sits
    at `start_angle`, and sweeping clockwise around the center reaches
    offset 1.0 back at `start_angle`, a full turn later. Add stops with
    add_stop(), then pass to fill_path_conic_gradient/
    fill_path_conic_gradient_aa (or query color_at() directly).

    `start_angle` is in radians, in the convention HTML5 Canvas's
    `createConicGradient` uses: 0.0 points along +x, and the sweep
    increases clockwise on screen. This package's pixel y already
    increases downward, so that convention falls directly out of
    `atan2(dy, dx)` -- no sign flip needed, unlike a gradient defined
    in a y-up math frame.

    There is no rect fill for this gradient: a rectangle has no
    natural center to sweep around the way RadialGradient's highlight
    use does, so only the path fills exist.
    """

    var cx: Float64
    var cy: Float64
    var start_angle: Float64
    var stops: GradientStops

    def __init__(out self, cx: Float64, cy: Float64, start_angle: Float64):
        """A gradient with no stops yet -- add at least one with
        add_stop() before calling color_at().

        Args:
            cx: Center x.
            cy: Center y.
            start_angle: Angle in radians where offset 0.0 (and 1.0)
                sit, measured from +x, increasing clockwise.
        """
        self.cx = cx
        self.cy = cy
        self.start_angle = start_angle
        self.stops = GradientStops()

    def add_stop(mut self, offset: Float64, color: Color):
        """Add a color stop at `offset` (0.0 at `start_angle`, 1.0 a
        full clockwise turn later, back at `start_angle`).

        Args:
            offset: Position around the sweep, 0.0 to 1.0. Stops need
                not be added in offset order; each is inserted into
                place.
            color: This stop's color.
        """
        self.stops.add_stop(offset, color)

    def set_color_space(mut self, space: ColorSpace):
        """Set the space the ramp interpolates in; see
        `GradientStops.set_color_space`.

        Args:
            space: The space the ramp interpolates in.
        """
        self.stops.set_color_space(space)

    def color_space(self) -> ColorSpace:
        """The space the ramp interpolates in.

        Returns:
            The current space, `ColorSpace.SRGB` by default.
        """
        return self.stops.color_space()

    def color_at(self, x: Float64, y: Float64) -> Color:
        """The gradient's color at (x, y): the clockwise angle from
        `start_angle` to (x, y) around the center, as a fraction of a
        full turn, then the stop lookup LinearGradient.color_at uses.

        (cx, cy) itself has no angle to measure. `atan2(0, 0)` is
        conventionally 0, but resolving the center that way would tie
        its color to `start_angle` rather than leaving it undefined,
        so the center pixel is fixed at t=0.0 (the first stop's color)
        regardless of `start_angle`.

        Args:
            x: Point x.
            y: Point y.

        Returns:
            The interpolated color, transparent black if no stops have
            been added yet.
        """
        var dx = x - self.cx
        var dy = y - self.cy
        var t = 0.0
        if dx != 0.0 or dy != 0.0:
            var turns = (atan2(dy, dx) - self.start_angle) / (2.0 * pi)
            t = turns - floor(turns)
        return self.stops.color_at(t)
