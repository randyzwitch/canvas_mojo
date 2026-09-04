"""Color gradients: `LinearGradient` and `RadialGradient`, consumed by
the gradient fills in canvas.shapes.rects (`fill_rect_gradient`,
`fill_rect_radial_gradient`) and path.mojo (`fill_path_gradient`,
`fill_path_radial_gradient` and their `_aa` variants). Those are the
only gradient-aware fills; circle/ellipse/polygon variants aren't built.

Both kinds reduce a point to a projected position `t` -- distance along
an axis (linear) or from a center relative to a radius (radial) -- then
share `_color_at_t` for stop lookup and interpolation. Only the
projection differs, so only the projection lives on each struct.

Extend behavior is "pad" only: a point past either endpoint or outside
the radius takes that edge's color, clamped. No repeat or reflect.
"""

from std.math import sqrt

from canvas.color import Color


struct _GradientStop(ImplicitlyCopyable, Movable):
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


def _insert_stop(mut stops: List[_GradientStop], offset: Float64, color: Color):
    """Add a stop, keeping `stops` sorted by offset with insertion
    order preserved among equal offsets.

    Two stops at one offset are a hard color transition, and which was
    added first decides which side of it owns which color -- so the
    insert goes *after* any stop already at this offset, and
    `_color_at_t` reads the run's ends accordingly.
    """
    var at = len(stops)
    while at > 0 and stops[at - 1].offset > offset:
        at -= 1
    stops.insert(at, _GradientStop(offset, color))


def _color_at_t(stops: List[_GradientStop], t_in: Float64) -> Color:
    """The "given a projected position, what color" half both
    LinearGradient.color_at and RadialGradient.color_at share. `t_in`
    is clamped to [0, 1] here -- the "pad" extend -- so neither
    projection has to.

    `stops` is sorted by offset (see `_insert_stop`), so the
    bracketing pair comes from a binary search rather than a scan of
    every stop.
    """
    var count = len(stops)
    if count == 0:
        return Color(0, 0, 0, 0)
    if count == 1:
        return stops[0].color

    var t = t_in
    if t < 0.0:
        t = 0.0
    elif t > 1.0:
        t = 1.0

    if t <= stops[0].offset:
        return stops[0].color
    if t >= stops[count - 1].offset:
        return stops[count - 1].color

    # The last stop at or below t. `lo` ends on it: the loop keeps
    # `stops[lo].offset <= t < stops[hi].offset`, which holds at entry
    # because the two clamps above ruled out both ends.
    var lo = 0
    var hi = count - 1
    while hi - lo > 1:
        var mid = (lo + hi) // 2
        if stops[mid].offset <= t:
            lo = mid
        else:
            hi = mid

    var before = stops[lo]
    # t landing exactly on a stop takes that stop's color. With
    # several at the offset, `lo` is the last of them -- the one that
    # owns the far side of a hard transition.
    if before.offset == t:
        return before.color
    var after = stops[hi]

    if before.offset == after.offset:
        return before.color

    var local_t = (t - before.offset) / (after.offset - before.offset)
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
    """Anything that can answer "what colour is at this point?" -- the
    fill source a gradient-filled shape queries per pixel.

    Conformance is nominal per Mojo's trait rule, so a new fill source
    has to declare `ColorSource` explicitly to be usable as one.
    """

    def color_at(self, x: Float64, y: Float64) -> Color:
        """This source's colour at (x, y), in canvas pixel
        coordinates.

        Args:
            x: Point x.
            y: Point y.

        Returns:
            The colour to paint at that point.
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
    var stops: List[_GradientStop]
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
        self.stops = List[_GradientStop]()
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
        _insert_stop(self.stops, offset, color)

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
        return _color_at_t(self.stops, t)


struct RadialGradient(ColorSource, Movable):
    """A radial gradient centered at (cx, cy) with the given radius:
    offset 0.0 is the center, offset 1.0 is the circle at `radius`.
    Add stops with add_stop(), then pass to fill_rect_radial_gradient/
    fill_path_radial_gradient (or query color_at() directly).

    The single-circle form (center + radius) only, not the two-circle
    form SVG/Cairo/HTML5 Canvas offer with an off-center focal point.
    """

    var cx: Float64
    var cy: Float64
    var radius: Float64
    var stops: List[_GradientStop]

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
        self.stops = List[_GradientStop]()

    def add_stop(mut self, offset: Float64, color: Color):
        """Add a color stop at `offset` (0.0 at the center, 1.0 at
        `radius`).

        Args:
            offset: Position from the center, 0.0 to 1.0. Stops need
                not be added in offset order; each is inserted into
                place.
            color: This stop's color.
        """
        _insert_stop(self.stops, offset, color)

    def color_at(self, x: Float64, y: Float64) -> Color:
        """The gradient's color at (x, y): project onto [0, 1] as
        `distance_from_center / radius`, clamp ("pad" extend -- a
        distance is never negative, so only the far end ever clamps),
        then the stop lookup LinearGradient.color_at uses.

        radius == 0.0 collapses every stop's circle to one point and
        resolves to t=1.0, a solid fill of the highest-offset stop's
        color, rather than dividing by zero.

        Args:
            x: Point x.
            y: Point y.

        Returns:
            The interpolated color, transparent black if no stops have
            been added yet.
        """
        var dx = x - self.cx
        var dy = y - self.cy
        var dist = sqrt(dx * dx + dy * dy)
        var t = 1.0
        if self.radius != 0.0:
            t = dist / self.radius
        return _color_at_t(self.stops, t)
