"""Raster patterns as a fill source: `PatternSource`, a `ColorSource`
(gradient.mojo) that samples a small `Canvas` tile instead of
projecting onto a gradient axis. Consumed by `fill_path_pattern`/
`fill_path_pattern_aa` (path.mojo) and `fill_rect_pattern`
(canvas.shapes.rects), the pattern-fill counterparts of the gradient
fills those modules already carry.

`PatternSource` needs a `Canvas` to hold its tile, which is why it
lives in its own module rather than alongside `LinearGradient`/
`RadialGradient`/`ConicGradient` in gradient.mojo: those three only
ever need `Color`, and keeping that file free of a `Canvas` dependency
keeps it the lightweight thing every gradient-aware fill imports.

`hatch_tile` builds the tile for the common chart case -- diagonal
lines, a cross-hatch, dots, or axis-aligned lines -- rendered once to a
small canvas with the existing anti-aliased primitives, ready to hand
to `PatternSource`.
"""

from std.math import floor

from canvas.buffer import Canvas
from canvas.color import Color
from canvas.gradient import ColorSource
from canvas.shapes.circles import fill_circle_aa
from canvas.shapes.lines import LineCap, draw_line_aa


struct Extend(Copyable, Equatable, ImplicitlyCopyable, Movable, Writable):
    """How `PatternSource.color_at` samples outside the tile's own
    [0, width) x [0, height) bounds.

    REPEAT tiles the pattern in both directions. REFLECT tiles it too,
    mirroring alternate copies so adjacent tile edges match colors
    exactly (Cairo/CSS call this "mirrored repeat"). PAD extends the
    tile's own edge pixels outward, the way LinearGradient/
    RadialGradient extend past their axis. NONE paints nothing outside
    the tile: `color_at` returns transparent there.
    """

    var _value: Int

    comptime REPEAT = Self(0)
    comptime REFLECT = Self(1)
    comptime PAD = Self(2)
    comptime NONE = Self(3)

    def __init__(out self, value: Int):
        """Prefer the REPEAT/REFLECT/PAD/NONE comptime constants over
        constructing one directly.

        Args:
            value: 0 for REPEAT, 1 for REFLECT, 2 for PAD, 3 for NONE.
        """
        self._value = value

    def __eq__(self, other: Self) -> Bool:
        return self._value == other._value

    def write_to[W: Writer](self, mut writer: W):
        if self._value == Self.REPEAT._value:
            writer.write("REPEAT")
        elif self._value == Self.REFLECT._value:
            writer.write("REFLECT")
        elif self._value == Self.PAD._value:
            writer.write("PAD")
        elif self._value == Self.NONE._value:
            writer.write("NONE")
        else:
            writer.write("Extend(", self._value, ")")

    def __str__(self) -> String:
        var out = String()
        out.write(self)
        return out


def _wrap_index(i: Int, n: Int, extend: Extend) -> Int:
    """Map a tile-space coordinate to a valid pixel index under REPEAT
    or REFLECT, or clamp it under PAD. Never called for NONE, which
    `PatternSource.color_at` handles before reaching here.

    Mojo's `%` truncates toward zero, so a negative `i` needs its
    remainder nudged back into [0, n) rather than left negative --
    floor-based modulo, not truncation.
    """
    if extend == Extend.PAD:
        if i < 0:
            return 0
        if i >= n:
            return n - 1
        return i
    if extend == Extend.REFLECT:
        # Fold i into one period of the mirrored sequence
        # 0, 1, .., n-1, n-1, .., 1, 0, 0, 1, .. (period 2n): a value
        # in the second half of the period reads back-to-front.
        var period = 2 * n
        var m = i % period
        if m < 0:
            m += period
        if m >= n:
            return period - 1 - m
        return m
    var m = i % n
    if m < 0:
        m += n
    return m


struct PatternSource(ColorSource, Movable):
    """A `ColorSource` that samples a raster tile -- the fill source a
    pattern/image fill queries per pixel, mirroring how
    LinearGradient/RadialGradient/ConicGradient project a point onto a
    gradient axis instead.

    Holds its own copy of `tile`, so drawing into the caller's canvas
    afterward has no effect on a pattern already built from it.
    """

    var tile: Canvas
    var extend: Extend
    var ox: Float64
    var oy: Float64

    def __init__(
        out self,
        tile: Canvas,
        extend: Extend = Extend.REPEAT,
        ox: Float64 = 0.0,
        oy: Float64 = 0.0,
    ):
        """
        Args:
            tile: The pattern's raster tile. Copied into the source, so
                the caller's canvas remains independent afterward.
            extend: How to sample outside the tile's bounds -- see
                `Extend`.
            ox: Device-space x where the tile's own (0, 0) pixel sits.
            oy: Device-space y where the tile's own (0, 0) pixel sits.
        """
        self.tile = tile.copy()
        self.extend = extend
        self.ox = ox
        self.oy = oy

    def color_at(self, x: Float64, y: Float64) -> Color:
        """The tile's color at (x, y): shift by the offset, round to
        the nearest tile pixel, then wrap/clamp/reject that coordinate
        per `extend`.

        Args:
            x: Point x.
            y: Point y.

        Returns:
            The sampled tile pixel, or transparent black under
            `Extend.NONE` outside the tile, or if the tile is empty.
        """
        var tw = self.tile.width
        var th = self.tile.height
        if tw == 0 or th == 0:
            return Color(0, 0, 0, 0)

        var ix = Int(floor(x - self.ox + 0.5))
        var iy = Int(floor(y - self.oy + 0.5))

        if self.extend == Extend.NONE:
            if ix < 0 or ix >= tw or iy < 0 or iy >= th:
                return Color(0, 0, 0, 0)
            return self.tile.get_pixel(ix, iy)

        return self.tile.get_pixel(
            _wrap_index(ix, tw, self.extend), _wrap_index(iy, th, self.extend)
        )


struct Hatch(Copyable, Equatable, ImplicitlyCopyable, Movable, Writable):
    """Which pattern `hatch_tile` renders.

    DIAGONAL is one family of parallel lines at 45 degrees, top-left to
    bottom-right. CROSS adds the perpendicular 45-degree family,
    crossing the first. DOTS places a single dot at the tile's center.
    HORIZONTAL and VERTICAL are one axis-aligned line through the
    tile's center.
    """

    var _value: Int

    comptime DIAGONAL = Self(0)
    comptime CROSS = Self(1)
    comptime DOTS = Self(2)
    comptime HORIZONTAL = Self(3)
    comptime VERTICAL = Self(4)

    def __init__(out self, value: Int):
        """Prefer the DIAGONAL/CROSS/DOTS/HORIZONTAL/VERTICAL comptime
        constants over constructing one directly.

        Args:
            value: 0 for DIAGONAL, 1 for CROSS, 2 for DOTS, 3 for
                HORIZONTAL, 4 for VERTICAL.
        """
        self._value = value

    def __eq__(self, other: Self) -> Bool:
        return self._value == other._value

    def write_to[W: Writer](self, mut writer: W):
        if self._value == Self.DIAGONAL._value:
            writer.write("DIAGONAL")
        elif self._value == Self.CROSS._value:
            writer.write("CROSS")
        elif self._value == Self.DOTS._value:
            writer.write("DOTS")
        elif self._value == Self.HORIZONTAL._value:
            writer.write("HORIZONTAL")
        elif self._value == Self.VERTICAL._value:
            writer.write("VERTICAL")
        else:
            writer.write("Hatch(", self._value, ")")

    def __str__(self) -> String:
        var out = String()
        out.write(self)
        return out


def _draw_wrapped_diagonal(
    mut tile: Canvas, spacing: Int, width: Float64, color: Color, flip: Bool
):
    """A 45-degree stripe through the tile (bottom-left to top-right if
    `flip`, top-left to bottom-right otherwise), drawn so the tile
    repeats without a seam: the stripe itself, extended a full tile
    past each end, and the two neighbouring stripes of the repeated
    pattern, one tile to either side.

    Three lines rather than one because a tile shows more than its own
    stripe. Repeated, the pattern is the family of parallel lines one
    tile apart, and the tile's two off-diagonal corners lie within a
    line width of the neighbouring stripes -- at spacing 8 and width 2
    the corner pixel is 0.7 px from the next stripe's centre -- so
    their coverage has to be painted here for the corners of adjacent
    tiles to meet in ink. The stripes are a full diagonal apart, so no
    pixel is covered by two of them and nothing blends twice.

    Extending each line a full tile past its ends keeps every
    `LineCap.BUTT` end outside the canvas: a cap on the corner pixel
    would cover about half of it, where a continuous stripe needs full
    width.
    """
    var s = Float64(spacing)
    var last = s - 1.0
    var y0 = last if flip else 0.0
    var y1 = 0.0 if flip else last
    var y_step = -s if flip else s
    for k in range(-1, 2):
        var dx = Float64(k) * s
        draw_line_aa(
            tile,
            dx - s,
            y0 - y_step,
            dx + last + s,
            y1 + y_step,
            color,
            width=width,
            cap=LineCap.BUTT,
        )


def hatch_tile(
    spacing: Int, width: Float64, color: Color, background: Color, kind: Hatch
) raises -> Canvas:
    """Render a hatch pattern once into a `spacing` x `spacing` tile,
    ready to hand to `PatternSource` under `Extend.REPEAT`.

    Args:
        spacing: Tile side length, and the period of the pattern.
        width: Line width for DIAGONAL/CROSS/HORIZONTAL/VERTICAL, or
            dot diameter for DOTS.
        color: Ink color.
        background: Fill behind the ink.
        kind: Which pattern to render -- see `Hatch`.

    Returns:
        A new `spacing` x `spacing` canvas holding the rendered tile.
    """
    var tile = Canvas(spacing, spacing, background)
    if spacing <= 0:
        return tile^

    var center = (Float64(spacing) - 1.0) / 2.0
    var last = Float64(spacing) - 1.0

    if kind == Hatch.DIAGONAL:
        _draw_wrapped_diagonal(tile, spacing, width, color, False)
    elif kind == Hatch.CROSS:
        _draw_wrapped_diagonal(tile, spacing, width, color, False)
        _draw_wrapped_diagonal(tile, spacing, width, color, True)
    elif kind == Hatch.DOTS:
        fill_circle_aa(tile, center, center, width / 2.0, color)
    elif kind == Hatch.HORIZONTAL:
        draw_line_aa(
            tile,
            0.0,
            center,
            last,
            center,
            color,
            width=width,
            cap=LineCap.BUTT,
        )
    elif kind == Hatch.VERTICAL:
        draw_line_aa(
            tile,
            center,
            0.0,
            center,
            last,
            color,
            width=width,
            cap=LineCap.BUTT,
        )
    return tile^
