"""Color gradients -- the minimal fill-source abstractions that justify
existing: fill_rect_gradient/fill_path_gradient (LinearGradient) and
fill_rect_radial_gradient/fill_path_radial_gradient (RadialGradient)
are the only gradient-aware fill entry points (see canvas_mojo.shapes.
rects/path.mojo), not every fill_* primitive retrofitted with a gradient
variant. Narrower than that on purpose: these cover the concrete
chart use cases (bar/area fills, and radial ones like bubble/donut
centers or a radial legend swatch) this exists for; circle/ellipse/
polygon gradient variants are easy to add later if something concrete
needs one, not built speculatively now.

Both gradient kinds reduce a point to a single projected position `t`
(LinearGradient: distance along an axis; RadialGradient: distance from
a center, relative to a radius) and then do the *identical* stop
lookup and interpolation on that `t` -- factored into the shared
`_color_at_t` below rather than duplicated, since that part of the
math has nothing gradient-shape-specific about it. The projection
itself stays on each struct, not shared, since it's the one part that
actually differs; kept as two separate structs/functions rather than
one generic "Gradient" type, matching this codebase's existing
preference for distinct named functions over a shared type dispatched
by a flag or trait (the same reason `LinearGradient` got its own
`fill_*_gradient` functions instead of being folded into `fill_rect`/
`fill_path` in the first place).

Only "pad" extend behavior is supported for both -- a point beyond
either endpoint (linear) or outside the radius (radial) gets that
endpoint's/edge's own color, clamped, not tiled or mirrored
(repeat/reflect extend modes real gradient APIs also offer) -- the
common case for a bar/area/bubble fill, where "the gradient's edges
are the shape's own edges" is what's actually wanted, not a repeating
pattern.
"""

from std.math import sqrt

from canvas_mojo.color import Color


struct _GradientStop(ImplicitlyCopyable, Movable):
    var offset: Float64
    var color: Color

    def __init__(out self, offset: Float64, color: Color):
        self.offset = offset
        self.color = color


def _round_channel(value: Float64) -> UInt8:
    # Channel values are always non-negative here (interpolated
    # between two UInt8s), so a plain +0.5 truncation is standard
    # round-to-nearest -- no away-from-zero complexity needed the way
    # geometry.py's pixel coordinates (which can be negative) require.
    return UInt8(value + 0.5)


def _color_at_t(
    stops: List[_GradientStop], lowest: _GradientStop, highest: _GradientStop, t_in: Float64
) -> Color:
    """The shared "given a projected position, what color" logic
    behind both LinearGradient.color_at and RadialGradient.color_at --
    see this module's own docstring for why the projection itself
    stays separate but this part is shared. `t_in` is expected already
    clamped to [0, 1] by the caller (each gradient kind's own "pad"
    extend rule is about *how* it clamps -- e.g. radial clamps a
    distance that can't go negative in the first place -- not about
    this shared lookup, so the clamp itself isn't duplicated here).

    `lowest`/`highest` (the stops with the smallest/largest offset)
    are passed in already found, not rescanned from `stops` here --
    they never change for a given gradient's fixed stop list, so
    LinearGradient/RadialGradient each track them incrementally in
    their own add_stop instead of this function re-scanning the whole
    list on every single call, which color_at made once per pixel of
    every gradient fill (fill_rect_gradient/fill_path_gradient and
    their radial counterparts, canvas_mojo/shapes/rects.mojo and
    canvas_mojo/path.mojo) -- a hot enough path that an O(stops) scan
    repeated per pixel was pure waste for a value that's the same
    every time.
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

    Stops don't need to be added in offset order -- color_at() finds
    the bracketing pair by scanning all stops each call, a linear scan
    over what's typically 2-4 stops for a chart fill, not worth
    maintaining a sorted-insertion invariant for this size.
    """

    var x0: Float64
    var y0: Float64
    var x1: Float64
    var y1: Float64
    var stops: List[_GradientStop]
    # Cached once from x0/y0/x1/y1 (which never change after
    # construction -- there's no setter) instead of recomputed by
    # color_at on every call: color_at runs once per pixel of a
    # gradient fill, and this axis/length math only ever depends on
    # the endpoints, never on the query point.
    var _axis_x: Float64
    var _axis_y: Float64
    var _len2: Float64
    # The smallest-/largest-offset stop so far -- tracked incrementally
    # here instead of scanned from `stops` by _color_at_t on every
    # call; see that function's own docstring for why.
    var _lowest: _GradientStop
    var _highest: _GradientStop

    def __init__(out self, x0: Float64, y0: Float64, x1: Float64, y1: Float64):
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1
        self.stops = List[_GradientStop]()
        self._axis_x = x1 - x0
        self._axis_y = y1 - y0
        self._len2 = self._axis_x * self._axis_x + self._axis_y * self._axis_y
        # Overwritten by the first real add_stop() call; _color_at_t
        # never reads these unless len(stops) >= 2, so this placeholder
        # (transparent black at offset 0.0) is never actually observed.
        self._lowest = _GradientStop(0.0, Color(0, 0, 0, 0))
        self._highest = self._lowest

    def add_stop(mut self, offset: Float64, color: Color):
        """Add a color stop at `offset` (0.0 to 1.0 along the axis)."""
        var stop = _GradientStop(offset, color)
        if len(self.stops) == 0 or offset < self._lowest.offset:
            self._lowest = stop
        if len(self.stops) == 0 or offset > self._highest.offset:
            self._highest = stop
        self.stops.append(stop)

    def color_at(self, x: Float64, y: Float64) -> Color:
        """The gradient's color at (x, y): project onto the axis,
        clamp to [0, 1] ("pad" extend -- see this module's own
        docstring), then linearly interpolate between whichever two
        stops that projected position falls between.
        """
        var t = 0.0
        if self._len2 != 0.0:
            t = ((x - self.x0) * self._axis_x + (y - self.y0) * self._axis_y) / self._len2
        return _color_at_t(self.stops, self._lowest, self._highest, t)


struct RadialGradient(Movable):
    """A radial gradient centered at (cx, cy) with the given radius:
    offset 0.0 is the center, offset 1.0 is the circle at `radius`.
    Add stops with add_stop(), then pass to fill_rect_radial_gradient/
    fill_path_radial_gradient (or query color_at() directly).

    Deliberately the simple single-circle form (center + radius), not
    the general two-circle "focal point can differ from the center,
    can itself have a nonzero radius" gradient real vector graphics
    APIs (SVG, Cairo, HTML5 Canvas) also offer -- that generality
    exists mainly to fake a 3D-lit-sphere look via an off-center focal
    point, not a chart need identified so far (bubble/donut centers
    and radial legend swatches all want a plain concentric gradient).
    Easy to widen later if something concrete asks for it.

    Same "stops don't need insertion order" scan as LinearGradient --
    see its own docstring; both share `_color_at_t` for that part.
    """

    var cx: Float64
    var cy: Float64
    var radius: Float64
    var stops: List[_GradientStop]
    # Same incremental lowest-/highest-offset tracking as
    # LinearGradient's own fields -- see that struct's and
    # _color_at_t's own docstrings for why.
    var _lowest: _GradientStop
    var _highest: _GradientStop

    def __init__(out self, cx: Float64, cy: Float64, radius: Float64):
        self.cx = cx
        self.cy = cy
        self.radius = radius
        self.stops = List[_GradientStop]()
        # Overwritten by the first real add_stop() call -- see
        # LinearGradient.__init__'s own comment on this placeholder.
        self._lowest = _GradientStop(0.0, Color(0, 0, 0, 0))
        self._highest = self._lowest

    def add_stop(mut self, offset: Float64, color: Color):
        """Add a color stop at `offset` (0.0 at the center, 1.0 at
        `radius`)."""
        var stop = _GradientStop(offset, color)
        if len(self.stops) == 0 or offset < self._lowest.offset:
            self._lowest = stop
        if len(self.stops) == 0 or offset > self._highest.offset:
            self._highest = stop
        self.stops.append(stop)

    def color_at(self, x: Float64, y: Float64) -> Color:
        """The gradient's color at (x, y): project onto [0, 1] as
        `distance_from_center / radius`, clamp ("pad" extend -- see
        this module's own docstring; a distance is never negative to
        begin with, so this side only ever clamps the far end), then
        the same stop lookup/interpolation LinearGradient.color_at
        uses.

        radius == 0.0 is a degenerate gradient (every stop's circle
        has collapsed to the same point) -- treated as "everywhere is
        at least at the outer edge" (t=1.0) rather than dividing by
        zero, so it renders as a solid fill of the highest-offset
        stop's color, the same as a LinearGradient whose two endpoints
        coincide (len2 == 0.0 above) always projects to t=0.0's stop --
        both are "the axis/radius collapsed" degenerate case, resolved
        by picking a fixed, documented `t` rather than crashing.
        """
        var dx = x - self.cx
        var dy = y - self.cy
        var dist = sqrt(dx * dx + dy * dy)
        var t = 1.0
        if self.radius != 0.0:
            t = dist / self.radius
        return _color_at_t(self.stops, self._lowest, self._highest, t)
