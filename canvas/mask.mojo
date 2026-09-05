"""Alpha masks: a per-pixel coverage, 0-255, that a fill is painted
through, a layer is composited through, or drawing is clipped to --
the shape of an operation separated from how the shape was made.

`Canvas.push_clip_path` already rasterizes a path into exactly this
kind of coverage and keeps it on the clip stack. A `Mask` is that
coverage as a value: built from a path (`Mask.from_path`), from a
canvas's alpha channel (`Mask.from_alpha`, so a blurred disk becomes
a soft-edged stencil) or from its luminance (`Mask.from_luminance`,
so a white-on-black painting is one), then used any number of times:

- `fill_mask` paints a colour through it, and `fill_mask_source` any
  `ColorSource` -- a gradient or a pattern -- so a mask is what makes
  a gradient take an arbitrary soft shape.
- `push_clip_mask` puts it on the clip stack, where it nests with
  clip paths and rectangles the way `push_clip_path` does.
- `apply_mask` scales a canvas's alpha by it, and the `draw_canvas`
  overload taking a mask composites a layer through it.

A mask is in device space: it is placed at a pixel offset, and the
canvas transform does not apply to it. Masks are raster-only; a
consumer wanting the same silhouette on `SvgCanvas` clips to the path
the mask came from (`push_clip_path`, which both backends have) rather
than painting through a mask. Coverage scales the alpha of
whatever passes through it, so a translucent colour through a
half-covered pixel lands at a quarter, as a clip path's edge does.
"""

from canvas.buffer import Canvas, BYTES_PER_PIXEL
from canvas.color import Color, _div255
from canvas.fill_rule import FillRule
from canvas.gradient import ColorSource
from canvas.path import Path, _path_coverage_mask


struct Mask(Copyable, Movable):
    """A `width x height` grid of 0-255 coverage, row-major, one byte
    per pixel: 255 lets everything through, 0 nothing.
    """

    var width: Int
    var height: Int
    var coverage: List[UInt8]

    def __init__(out self, width: Int, height: Int, fill: UInt8 = 0):
        """A mask of uniform coverage.

        Args:
            width: Mask width in pixels.
            height: Mask height in pixels.
            fill: Coverage of every pixel, 0 (the default) for a mask
                that lets nothing through until it is drawn into.
        """
        self.width = width
        self.height = height
        self.coverage = List[UInt8](length=width * height, fill=fill)

    def __init__(
        out self, width: Int, height: Int, var coverage: List[UInt8]
    ) raises:
        """A mask over existing coverage bytes, taken by value.

        Args:
            width: Mask width in pixels.
            height: Mask height in pixels.
            coverage: `width * height` bytes, row-major.

        Raises:
            If `coverage` is not `width * height` long.
        """
        if len(coverage) != width * height:
            raise Error(
                "Mask: coverage has "
                + String(len(coverage))
                + " bytes, expected "
                + String(width * height)
                + " for "
                + String(width)
                + "x"
                + String(height)
            )
        self.width = width
        self.height = height
        self.coverage = coverage^

    @staticmethod
    def from_path(
        path: Path,
        width: Int,
        height: Int,
        fill_rule: FillRule = FillRule.EVEN_ODD,
        supersample: Int = 4,
        curve_steps: Int = 0,
    ) -> Mask:
        """`path`'s anti-aliased interior over a `width x height` grid:
        the coverage `push_clip_path` would keep, and the coverage
        `fill_path_aa` would blend by, so a mask's edge lands where the
        fill's does.

        Args:
            path: Shape whose interior is the mask.
            width: Mask width in pixels.
            height: Mask height in pixels.
            fill_rule: EVEN_ODD (default) or NONZERO -- see FillRule.
            supersample: Sub-pixel grid side length for the edge
                coverage.
            curve_steps: Straight-line segments per quad/cubic Bezier;
                0 (the default) picks a count from the curvature.

        Returns:
            The mask.
        """
        var out = Mask(width, height)
        out.coverage = _path_coverage_mask(
            path, width, height, fill_rule, supersample, curve_steps
        )
        return out^

    @staticmethod
    def from_alpha(canvas: Canvas) -> Mask:
        """A canvas's alpha channel as a mask of its size: an opaque
        pixel is 255, a transparent one 0. Draw a shape onto a
        transparent canvas and blur it, and this is a soft-edged
        stencil of it.

        Args:
            canvas: Canvas whose alpha is read. Unchanged.

        Returns:
            The mask.
        """
        var out = Mask(canvas.width, canvas.height)
        var p = canvas.pixels.unsafe_ptr()
        var m = out.coverage.unsafe_ptr()
        for i in range(canvas.width * canvas.height):
            m[unsafe_offset=i] = p[unsafe_offset=i * BYTES_PER_PIXEL + 3]
        return out^

    @staticmethod
    def from_luminance(canvas: Canvas) -> Mask:
        """A canvas's brightness as a mask of its size, scaled by its
        alpha: opaque white is 255, black or transparent 0. The
        luminance is `0.30 R + 0.59 G + 0.11 B`, the weighting
        canvas/blend.mojo's non-separable modes use.

        Args:
            canvas: Canvas whose pixels are read. Unchanged.

        Returns:
            The mask.
        """
        var out = Mask(canvas.width, canvas.height)
        var p = canvas.pixels.unsafe_ptr()
        var m = out.coverage.unsafe_ptr()
        for i in range(canvas.width * canvas.height):
            var idx = i * BYTES_PER_PIXEL
            var r = Int(p[unsafe_offset=idx])
            var g = Int(p[unsafe_offset=idx + 1])
            var b = Int(p[unsafe_offset=idx + 2])
            var a = Int(p[unsafe_offset=idx + 3])
            var luma = (30 * r + 59 * g + 11 * b) // 100
            m[unsafe_offset=i] = UInt8(_div255(luma * a))
        return out^

    def coverage_at(self, x: Int, y: Int) -> UInt8:
        """The coverage at (x, y), 0 outside the mask.

        Args:
            x: Column to query.
            y: Row to query.

        Returns:
            Coverage 0-255.
        """
        if x < 0 or y < 0 or x >= self.width or y >= self.height:
            return 0
        return self.coverage[y * self.width + x]

    def inverted(self) -> Mask:
        """The complement: `255 - coverage` everywhere, so what this
        mask hides the result shows.

        Returns:
            The inverted mask.
        """
        var out = Mask(self.width, self.height)
        var s = self.coverage.unsafe_ptr()
        var d = out.coverage.unsafe_ptr()
        for i in range(self.width * self.height):
            d[unsafe_offset=i] = 255 - s[unsafe_offset=i]
        return out^


def _through(color: Color, coverage: UInt8) -> Color:
    """`color` with its alpha scaled by `coverage`."""
    if coverage == 255:
        return color
    return color.with_alpha(UInt8(_div255(Int(color.a) * Int(coverage))))


def fill_mask(
    mut canvas: Canvas, mask: Mask, color: Color, x: Int = 0, y: Int = 0
):
    """Paint `color` through `mask`, its top-left corner at (x, y):
    each pixel the mask covers is written with the colour's alpha
    scaled by the coverage there. Goes through `set_pixel`, so the
    active clip and blend mode apply, and the part of the mask off the
    canvas is skipped.

    Args:
        canvas: Canvas painted into.
        mask: Coverage to paint through.
        color: Colour painted. Its own alpha compounds with the
            coverage.
        x: Canvas column of the mask's left edge.
        y: Canvas row of the mask's top edge.
    """
    var m = mask.coverage.unsafe_ptr()
    for j in range(mask.height):
        var py = y + j
        if py < 0 or py >= canvas.height:
            continue
        for i in range(mask.width):
            var px = x + i
            if px < 0 or px >= canvas.width:
                continue
            var c = m[unsafe_offset=j * mask.width + i]
            if c == 0:
                continue
            canvas.set_pixel(px, py, _through(color, c))


def fill_mask_source[
    S: ColorSource
](mut canvas: Canvas, mask: Mask, source: S, x: Int = 0, y: Int = 0):
    """`fill_mask` taking each pixel's colour from `source` -- a
    gradient or a pattern -- instead of one flat colour. The source is
    queried in canvas pixel coordinates, as the gradient fills do.

    Args:
        canvas: Canvas painted into.
        mask: Coverage to paint through.
        source: Fill source, asked for its colour at every covered
            pixel.
        x: Canvas column of the mask's left edge.
        y: Canvas row of the mask's top edge.
    """
    var m = mask.coverage.unsafe_ptr()
    for j in range(mask.height):
        var py = y + j
        if py < 0 or py >= canvas.height:
            continue
        for i in range(mask.width):
            var px = x + i
            if px < 0 or px >= canvas.width:
                continue
            var c = m[unsafe_offset=j * mask.width + i]
            if c == 0:
                continue
            var color = source.color_at(Float64(px), Float64(py))
            canvas.set_pixel(px, py, _through(color, c))


def push_clip_mask(mut canvas: Canvas, mask: Mask, x: Int = 0, y: Int = 0):
    """Restrict subsequent drawing to `mask`, its top-left corner at
    (x, y) -- `push_clip_path` for a coverage built elsewhere. Pixels
    the mask does not reach are clipped out. Nests with the clip paths
    and rectangles already pushed, multiplying into the current mask,
    and is removed by `pop_clip_path`.

    Args:
        canvas: Canvas whose clip stack the mask joins.
        mask: Coverage that stays drawable.
        x: Canvas column of the mask's left edge.
        y: Canvas row of the mask's top edge.
    """
    var coverage = List[UInt8](length=canvas.width * canvas.height, fill=0)
    var m = mask.coverage.unsafe_ptr()
    var d = coverage.unsafe_ptr()
    for j in range(mask.height):
        var py = y + j
        if py < 0 or py >= canvas.height:
            continue
        for i in range(mask.width):
            var px = x + i
            if px < 0 or px >= canvas.width:
                continue
            d[unsafe_offset=py * canvas.width + px] = m[
                unsafe_offset=j * mask.width + i
            ]
    canvas.push_clip_coverage(coverage^)


def apply_mask(canvas: Canvas, mask: Mask) -> Canvas:
    """A copy of `canvas` with every pixel's alpha scaled by the
    mask's coverage at the same position; pixels the mask does not
    reach become transparent. Colour channels are untouched.

    Args:
        canvas: Canvas to copy. Unchanged.
        mask: Coverage aligned with the canvas's top-left corner.

    Returns:
        The masked copy, the same size as `canvas`.
    """
    var out = canvas.copy()
    var p = out.pixels.unsafe_ptr()
    for y in range(out.height):
        for x in range(out.width):
            var c = mask.coverage_at(x, y)
            if c == 255:
                continue
            var idx = (y * out.width + x) * BYTES_PER_PIXEL + 3
            if c == 0:
                p[unsafe_offset=idx] = 0
            else:
                p[unsafe_offset=idx] = UInt8(
                    _div255(Int(p[unsafe_offset=idx]) * Int(c))
                )
    return out^
