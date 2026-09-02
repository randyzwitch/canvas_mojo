"""The pixel raster buffer at the core of the canvas package."""

from canvas.color import Color
from canvas.gradient import LinearGradient
from canvas.vector.draw_target import DrawTarget
from canvas.path import Path, fill_path_aa, stroke_path_aa
from canvas.shapes.lines import draw_line_aa
from canvas.shapes.arcs import fill_arc_aa, fill_ring_sector_aa
from canvas.shapes.circles import fill_circle_aa
from canvas.shapes.ellipses import draw_ellipse_aa, fill_ellipse_aa
from canvas.shapes.rects import fill_rect, fill_rect_gradient


struct _ClipRect(ImplicitlyCopyable, Movable):
    """A clip rectangle, private to this module: an implementation
    detail of Canvas's clip stack, unrelated to any public type.
    """

    var x: Int
    var y: Int
    var width: Int
    var height: Int

    def __init__(out self, x: Int, y: Int, width: Int, height: Int):
        self.x = x
        self.y = y
        self.width = width
        self.height = height


def _intersect_clip(a: _ClipRect, b: _ClipRect) -> _ClipRect:
    """The overlapping region of two clip rects. This is what keeps a
    nested clip from escaping an ancestor's: a rect extending past the
    current clip is cut down to the overlap. Disjoint rects give a
    zero-size result, clamped rather than negative, which in_clip's
    half-open check reads as "nothing is inside this clip."
    """
    var left = max(a.x, b.x)
    var top = max(a.y, b.y)
    var right = min(a.x + a.width, b.x + b.width)
    var bottom = min(a.y + a.height, b.y + b.height)
    return _ClipRect(left, top, max(0, right - left), max(0, bottom - top))


struct Canvas(Copyable, DrawTarget, Movable):
    """A width x height RGB raster buffer, row-major, 3 bytes per pixel.

    Alpha is used for blending on write but is not stored per-pixel; the
    backing buffer holds the composited RGB result.

    Conforms to `DrawTarget` through the ten methods below `fill`,
    each a thin delegation to the matching free function in
    `canvas.shapes`/`canvas.path`, so a caller can render
    generically through a `Canvas` as through an `SvgCanvas`. Calling
    those free functions directly works the same; the methods are
    additive.

    No `draw_text` method, since `DrawTarget` has none -- raster and
    vector backends draw text through different mechanisms (see that
    trait). Call `canvas.text.draw_text(canvas, ...)` directly.
    """

    var width: Int
    var height: Int
    var pixels: List[UInt8]
    var clip_stack: List[_ClipRect]

    def __init__(
        out self, width: Int, height: Int, fill: Color = Color(255, 255, 255)
    ):
        """Allocate a `width x height` canvas, every pixel set to `fill`.

        Args:
            width: Canvas width in pixels.
            height: Canvas height in pixels.
            fill: Initial color for every pixel.
        """
        self.width = width
        self.height = height
        self.pixels = List[UInt8](capacity=width * height * 3)
        for _ in range(width * height):
            self.pixels.append(fill.r)
            self.pixels.append(fill.g)
            self.pixels.append(fill.b)
        # empty stack == no clip active == the clip region is the whole canvas
        self.clip_stack = List[_ClipRect]()

    def __init__(
        out self, width: Int, height: Int, var pixels: List[UInt8]
    ) raises:
        """Wrap an already-built RGB pixel buffer, skipping the
        solid-fill loop the (width, height, fill) constructor pays for.
        For a caller about to write every pixel itself -- downsample()
        in canvas/resize.mojo, which computes and appends every
        output pixel before handing the canvas back -- filling first
        would double the call's pixel-write cost.

        Raises unless `pixels` is exactly width * height * 3 bytes
        (RGB, row-major, the layout get_pixel/set_pixel assume). A
        wrong size is a caller bug, and wrapping it anyway would
        corrupt every later index.

        Args:
            width: Canvas width in pixels.
            height: Canvas height in pixels.
            pixels: Row-major RGB bytes, exactly width * height * 3
                long.

        Raises:
            Error: `pixels`' length isn't width * height * 3.
        """
        if len(pixels) != width * height * 3:
            raise Error(
                "Canvas(width, height, pixels): pixels must be exactly"
                " width * height * 3 bytes (got "
                + String(len(pixels))
                + " for a "
                + String(width)
                + "x"
                + String(height)
                + " canvas)"
            )
        self.width = width
        self.height = height
        self.pixels = pixels^
        self.clip_stack = List[_ClipRect]()

    def in_bounds(self, x: Int, y: Int) -> Bool:
        """Whether (x, y) is a real pixel on this canvas.

        Args:
            x: Column to check.
            y: Row to check.

        Returns:
            True if 0 <= x < width and 0 <= y < height.
        """
        return x >= 0 and x < self.width and y >= 0 and y < self.height

    def push_clip(mut self, x: Int, y: Int, width: Int, height: Int):
        """Restrict subsequent drawing to this sub-rectangle. Every
        primitive gets this for free, since they all write through
        set_pixel.

        Intersects with the current effective clip rather than
        replacing it, and pushes the intersected result, so nested
        clips compose: a sub-plot can restrict drawing further than its
        parent but never escape the parent's region, even if its own
        rectangle extends past it. Pair with pop_clip().

        A clip rectangle extending past the canvas bounds is fine;
        in_bounds still rejects anything outside the canvas.

        Args:
            x: Clip rectangle's left edge.
            y: Clip rectangle's top edge.
            width: Clip rectangle's width.
            height: Clip rectangle's height.
        """
        var new_rect = _ClipRect(x, y, width, height)
        if len(self.clip_stack) > 0:
            new_rect = _intersect_clip(
                self.clip_stack[len(self.clip_stack) - 1], new_rect
            )
        self.clip_stack.append(new_rect)

    def pop_clip(mut self):
        """Remove the most recently pushed clip, reverting to the parent
        clip if one exists or to the whole canvas if not.

        A no-op on an empty stack rather than an error, matching
        in_bounds' fail-safe handling of out-of-range requests: a stack
        alone can't distinguish an unbalanced pop from "nothing to
        undo".
        """
        if len(self.clip_stack) > 0:
            _ = self.clip_stack.pop()

    def in_clip(self, x: Int, y: Int) -> Bool:
        """Whether (x, y) is inside the active clip region.

        Args:
            x: Column to check.
            y: Row to check.

        Returns:
            True if no clip is active, or (x, y) is inside the
            innermost pushed clip rectangle.
        """
        if len(self.clip_stack) == 0:
            return True
        var top = self.clip_stack[len(self.clip_stack) - 1]
        return (
            x >= top.x
            and x < top.x + top.width
            and y >= top.y
            and y < top.y + top.height
        )

    def set_pixel(mut self, x: Int, y: Int, color: Color):
        """Write `color` at (x, y), a no-op if it's off-canvas or
        outside the active clip.

        Args:
            x: Column to write.
            y: Row to write.
            color: Color to write, blended over the existing pixel if
                translucent.
        """
        if not self.in_bounds(x, y):
            return
        if not self.in_clip(x, y):
            return
        self.write_pixel(x, y, color)

    def write_pixel(mut self, x: Int, y: Int, color: Color):
        """Write `color` at (x, y) *without* set_pixel's in_bounds/
        in_clip checks. The caller must already know (x, y) is inside
        both the canvas and the active clip, typically from a range
        effective_fill_rect (below) intersected against both.

        set_pixel stays the checked entry point for pixel-at-a-time
        primitives (draw_line_aa, fill_circle_aa, ...), which have no
        single valid region to precompute the way a rectangular fill
        does.

        Writes through `pixels.unsafe_ptr()` rather than indexing the
        `List`. Checked indexing costs about 1.7ns per byte against
        0.26ns unchecked, measured directly, and at three bytes a pixel
        that bounds check was roughly half the cost of a solid fill.
        It was also redundant with this method's own contract: a caller
        that has not already established the coordinate is in range is
        misusing it, and `set_pixel` above is the entry point that
        establishes exactly that. The index is computed from `width`
        and the caller's validated (x, y), so it cannot leave the
        buffer.

        The blend path reads the background bytes straight from the
        same pointer instead of going through `get_pixel`, which would
        recompute the identical index and build a `Color` only to have
        it immediately destructured.

        Args:
            x: Column to write. Must already be known in-bounds.
            y: Row to write. Must already be known in-bounds.
            color: Color to write, blended over the existing pixel if
                translucent.
        """
        var idx = (y * self.width + x) * 3
        var p = self.pixels.unsafe_ptr()
        if color.a == 255:
            p[unsafe_offset=idx] = color.r
            p[unsafe_offset=idx + 1] = color.g
            p[unsafe_offset=idx + 2] = color.b
        else:
            var bg = Color(
                p[unsafe_offset=idx],
                p[unsafe_offset=idx + 1],
                p[unsafe_offset=idx + 2],
            )
            var blended = color.blend_over(bg)
            p[unsafe_offset=idx] = blended.r
            p[unsafe_offset=idx + 1] = blended.g
            p[unsafe_offset=idx + 2] = blended.b

    def effective_fill_rect(
        self, x: Int, y: Int, width: Int, height: Int
    ) -> Tuple[Int, Int, Int, Int]:
        """The (x, y, width, height) a rectangular fill covering
        [x, x+width) x [y, y+height) may actually touch, intersected
        against the canvas bounds and the active clip -- the same
        intersection set_pixel enforces one pixel at a time, computed
        once for a caller about to loop over the whole region
        (fill_rect/fill_rect_gradient/fill below). Pair with
        write_pixel to skip straight to the write.

        A returned width/height of 0 means nothing in the requested
        rectangle is drawable. `range(0)` is already a no-op, so
        callers need no separate check.

        Args:
            x: Requested rectangle's left edge.
            y: Requested rectangle's top edge.
            width: Requested rectangle's width.
            height: Requested rectangle's height.

        Returns:
            (x, y, width, height) of the sub-rectangle actually
            touchable, clamped to the canvas and the active clip.
        """
        var left = max(0, x)
        var top = max(0, y)
        var right = min(self.width, x + width)
        var bottom = min(self.height, y + height)
        if len(self.clip_stack) > 0:
            var top_clip = self.clip_stack[len(self.clip_stack) - 1]
            left = max(left, top_clip.x)
            top = max(top, top_clip.y)
            right = min(right, top_clip.x + top_clip.width)
            bottom = min(bottom, top_clip.y + top_clip.height)
        return (left, top, max(0, right - left), max(0, bottom - top))

    def get_pixel(self, x: Int, y: Int) -> Color:
        """Read the color at (x, y).

        Args:
            x: Column to read.
            y: Row to read.

        Returns:
            The pixel's color, or opaque black if (x, y) is off-canvas.
        """
        if not self.in_bounds(x, y):
            return Color(0, 0, 0)
        var idx = (y * self.width + x) * 3
        return Color(
            self.pixels[idx], self.pixels[idx + 1], self.pixels[idx + 2]
        )

    def read_pixel(self, x: Int, y: Int) -> Color:
        """Read (x, y) *without* `get_pixel`'s in_bounds check, the
        counterpart to `write_pixel` and subject to the same contract:
        the caller must already know the coordinate is on the canvas,
        typically because the loop bounds came from `width`/`height`.

        `get_pixel` stays the checked entry point, and returns opaque
        black off-canvas rather than reading out of range. This exists
        because whole-image passes -- downsampling, encoding a file --
        derive every coordinate from the canvas's own dimensions, so
        the check re-establishes what the loop already guarantees, and
        at three bytes a pixel it is most of what such a pass costs.

        Args:
            x: Column to read. Must already be known in-bounds.
            y: Row to read. Must already be known in-bounds.

        Returns:
            The pixel's color.
        """
        var idx = (y * self.width + x) * 3
        var p = self.pixels.unsafe_ptr()
        return Color(
            p[unsafe_offset=idx],
            p[unsafe_offset=idx + 1],
            p[unsafe_offset=idx + 2],
        )

    def fill(mut self, color: Color):
        """Fill the whole canvas (or the active clip region, if any)
        with `color`.

        Args:
            color: Color to fill with, blended over existing pixels if
                translucent.
        """
        var region = self.effective_fill_rect(0, 0, self.width, self.height)
        var rx = region[0]
        var ry = region[1]
        var rw = region[2]
        var rh = region[3]
        for y in range(ry, ry + rh):
            for x in range(rx, rx + rw):
                self.write_pixel(x, y, color)

    def fill_rect(
        mut self, x: Int, y: Int, width: Int, height: Int, color: Color
    ):
        """Same as `canvas.shapes.rects.fill_rect`, callable as a
        method.

        Args:
            x: Rectangle's left edge.
            y: Rectangle's top edge.
            width: Rectangle's width.
            height: Rectangle's height.
            color: Fill color.
        """
        fill_rect(self, x, y, width, height, color)

    def fill_rect_gradient(
        mut self,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        gradient: LinearGradient,
    ):
        """Same as `canvas.shapes.rects.fill_rect_gradient`,
        callable as a method.

        Args:
            x: Rectangle's left edge.
            y: Rectangle's top edge.
            width: Rectangle's width.
            height: Rectangle's height.
            gradient: Fill source, projected across the rectangle.
        """
        fill_rect_gradient(self, x, y, width, height, gradient)

    def draw_line_aa(
        mut self,
        x0: Int,
        y0: Int,
        x1: Int,
        y1: Int,
        color: Color,
        width: Float64 = 1.0,
    ):
        """Same as `canvas.shapes.lines.draw_line_aa`, callable as
        a method.

        Args:
            x0: Start point's x.
            y0: Start point's y.
            x1: End point's x.
            y1: End point's y.
            color: Stroke color.
            width: Stroke width in pixels.
        """
        draw_line_aa(self, x0, y0, x1, y1, color, width=width)

    def fill_circle_aa(mut self, cx: Int, cy: Int, radius: Int, color: Color):
        """Same as `canvas.shapes.circles.fill_circle_aa`,
        callable as a method.

        Args:
            cx: Center x.
            cy: Center y.
            radius: Circle radius in pixels.
            color: Fill color.
        """
        fill_circle_aa(self, cx, cy, radius, color)

    def fill_ellipse_aa(
        mut self, cx: Int, cy: Int, rx: Int, ry: Int, color: Color
    ):
        """Same as `canvas.shapes.ellipses.fill_ellipse_aa`,
        callable as a method.

        Args:
            cx: Center x.
            cy: Center y.
            rx: Horizontal radius in pixels.
            ry: Vertical radius in pixels.
            color: Fill color.
        """
        fill_ellipse_aa(self, cx, cy, rx, ry, color)

    def draw_ellipse_aa(
        mut self, cx: Int, cy: Int, rx: Int, ry: Int, color: Color
    ):
        """Same as `canvas.shapes.ellipses.draw_ellipse_aa`,
        callable as a method.

        Args:
            cx: Center x.
            cy: Center y.
            rx: Horizontal radius in pixels.
            ry: Vertical radius in pixels.
            color: Outline color.
        """
        draw_ellipse_aa(self, cx, cy, rx, ry, color)

    def fill_arc_aa(
        mut self,
        cx: Float64,
        cy: Float64,
        radius: Float64,
        start_angle: Float64,
        end_angle: Float64,
        color: Color,
    ):
        """Same as `canvas.shapes.arcs.fill_arc_aa`, callable as a
        method.

        Args:
            cx: Center x.
            cy: Center y.
            radius: Wedge radius in pixels.
            start_angle: Sweep start, radians, 0 pointing along +x.
            end_angle: Sweep end, radians.
            color: Fill color.
        """
        fill_arc_aa(self, cx, cy, radius, start_angle, end_angle, color)

    def fill_ring_sector_aa(
        mut self,
        cx: Float64,
        cy: Float64,
        inner_radius: Float64,
        outer_radius: Float64,
        start_angle: Float64,
        end_angle: Float64,
        color: Color,
    ):
        """Same as `canvas.shapes.arcs.fill_ring_sector_aa`,
        callable as a method.

        Args:
            cx: Center x.
            cy: Center y.
            inner_radius: Ring's inner edge, in pixels.
            outer_radius: Ring's outer edge, in pixels.
            start_angle: Sweep start, radians, 0 pointing along +x.
            end_angle: Sweep end, radians.
            color: Fill color.
        """
        fill_ring_sector_aa(
            self,
            cx,
            cy,
            inner_radius,
            outer_radius,
            start_angle,
            end_angle,
            color,
        )

    def stroke_path_aa(
        mut self, path: Path, color: Color, width: Float64 = 1.0
    ):
        """Same as `canvas.path.stroke_path_aa`, callable as a
        method.

        Args:
            path: Path to stroke.
            color: Stroke color.
            width: Stroke width in pixels.
        """
        stroke_path_aa(self, path, color, width=width)

    def fill_path_aa(mut self, path: Path, color: Color):
        """Same as `canvas.path.fill_path_aa`, callable as a
        method.

        Args:
            path: Path to fill.
            color: Fill color.
        """
        fill_path_aa(self, path, color)
