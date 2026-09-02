"""Color gradients: `LinearGradient` and `RadialGradient`, consumed by
fill_rect_gradient/fill_path_gradient and their radial counterparts
(canvas.shapes.rects, path.mojo). Those four are the only
gradient-aware fills; circle/ellipse/polygon variants aren't built.

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


def _color_at_t(
    stops: List[_GradientStop],
    lowest: _GradientStop,
    highest: _GradientStop,
    t_in: Float64,
) -> Color:
    """The "given a projected position, what color" half both
    LinearGradient.color_at and RadialGradient.color_at share. `t_in`
    arrives already clamped to [0, 1]: each gradient kind clamps
    differently (a radial distance can't go negative to begin with), so
    the clamp stays with the projection.

    `lowest`/`highest` -- the smallest- and largest-offset stops --
    come in already found. They never change for a fixed stop list, and
    color_at runs once per pixel of a gradient fill, so each gradient
    tracks them incrementally in add_stop rather than rescanning here.
    """
    if len(stops) == 0:
        return Color(0, 0, 0, 0)
    if len(stops) == 1:
        return stops[0].color

    var t = t_in
    if t < 0.0:
        t = 0.0
    elif t > 1.0:
        t = 1.0

    if t <= lowest.offset:
        return lowest.color
    if t >= highest.offset:
        return highest.color

    # The bracketing pair: the highest-offset stop at or below t,
    # and the lowest-offset stop at or above t.
    var before = lowest
    var after = highest
    for s in stops:
        if s.offset <= t and s.offset >= before.offset:
            before = s
        if s.offset >= t and s.offset <= after.offset:
            after = s

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


struct LinearGradient(Movable):
    """A linear gradient along the axis from (x0, y0) to (x1, y1).
    Add stops with add_stop(), then pass to fill_rect_gradient/
    fill_path_gradient (or query color_at() directly).

    Stops need not be added in offset order: color_at() finds the
    bracketing pair by scanning all stops, typically 2-4 for a chart
    fill, which is too few to be worth a sorted-insertion invariant.
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
    # The smallest-/largest-offset stop so far, tracked incrementally
    # rather than rescanned per call; see _color_at_t.
    var _lowest: _GradientStop
    var _highest: _GradientStop

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
        # Overwritten by the first add_stop(); _color_at_t never reads
        # these below len(stops) >= 2, so this transparent-black
        # sentinel is never observed.
        self._lowest = _GradientStop(0.0, Color(0, 0, 0, 0))
        self._highest = self._lowest

    def add_stop(mut self, offset: Float64, color: Color):
        """Add a color stop at `offset` (0.0 to 1.0 along the axis).

        Args:
            offset: Position along the axis, 0.0 at (x0, y0), 1.0 at
                (x1, y1). Stops need not be added in offset order.
            color: This stop's color.
        """
        var stop = _GradientStop(offset, color)
        if len(self.stops) == 0 or offset < self._lowest.offset:
            self._lowest = stop
        if len(self.stops) == 0 or offset > self._highest.offset:
            self._highest = stop
        self.stops.append(stop)

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
        return _color_at_t(self.stops, self._lowest, self._highest, t)


struct RadialGradient(Movable):
    """A radial gradient centered at (cx, cy) with the given radius:
    offset 0.0 is the center, offset 1.0 is the circle at `radius`.
    Add stops with add_stop(), then pass to fill_rect_radial_gradient/
    fill_path_radial_gradient (or query color_at() directly).

    The simple single-circle form (center + radius), not the
    two-circle form SVG/Cairo/HTML5 Canvas offer, where the focal point
    can sit off-center with its own radius. That generality mostly
    fakes a 3D-lit-sphere look; bubble centers, donut centers and
    radial legend swatches all want a concentric gradient.

    Stops need not be in insertion order, as in LinearGradient; both
    share `_color_at_t`.
    """

    var cx: Float64
    var cy: Float64
    var radius: Float64
    var stops: List[_GradientStop]
    # Same incremental lowest-/highest-offset tracking LinearGradient
    # does.
    var _lowest: _GradientStop
    var _highest: _GradientStop

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
        # Overwritten by the first add_stop(); see
        # LinearGradient.__init__.
        self._lowest = _GradientStop(0.0, Color(0, 0, 0, 0))
        self._highest = self._lowest

    def add_stop(mut self, offset: Float64, color: Color):
        """Add a color stop at `offset` (0.0 at the center, 1.0 at
        `radius`).

        Args:
            offset: Position from the center, 0.0 to 1.0. Stops need
                not be added in offset order.
            color: This stop's color.
        """
        var stop = _GradientStop(offset, color)
        if len(self.stops) == 0 or offset < self._lowest.offset:
            self._lowest = stop
        if len(self.stops) == 0 or offset > self._highest.offset:
            self._highest = stop
        self.stops.append(stop)

    def color_at(self, x: Float64, y: Float64) -> Color:
        """The gradient's color at (x, y): project onto [0, 1] as
        `distance_from_center / radius`, clamp ("pad" extend -- a
        distance is never negative, so only the far end ever clamps),
        then the stop lookup LinearGradient.color_at uses.

        radius == 0.0 collapses every stop's circle to one point.
        Rather than dividing by zero, that resolves to t=1.0 -- a solid
        fill of the highest-offset stop's color -- just as a
        LinearGradient with coincident endpoints (len2 == 0.0) resolves
        to t=0.0's stop.

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
        return _color_at_t(self.stops, self._lowest, self._highest, t)
