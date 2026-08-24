"""The pixel raster buffer at the core of the canvas package."""

from canvas_mojo.color import Color
from canvas_mojo.gradient import LinearGradient
from canvas_mojo.vector.draw_target import DrawTarget
from canvas_mojo.path import Path, fill_path_aa, stroke_path_aa
from canvas_mojo.shapes.lines import draw_line_aa
from canvas_mojo.shapes.arcs import fill_arc_aa, fill_ring_sector_aa
from canvas_mojo.shapes.circles import fill_circle_aa
from canvas_mojo.shapes.rects import fill_rect, fill_rect_gradient


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

    Conforms to `DrawTarget` through the eight methods below `fill`,
    each a thin delegation to the matching free function in
    `canvas_mojo.shapes`/`canvas_mojo.path`, so a caller can render
    generically through a `Canvas` as through an `SvgCanvas`. Calling
    those free functions directly works the same; the methods are
    additive.

    No `draw_text` method, since `DrawTarget` has none -- raster and
    vector backends draw text through different mechanisms (see that
    trait). Call `canvas_mojo.text.draw_text(canvas, ...)` directly.
    """

    var width: Int
    var height: Int
    var pixels: List[UInt8]
    var clip_stack: List[_ClipRect]

    def __init__(out self, width: Int, height: Int, fill: Color = Color(255, 255, 255)):
        self.width = width
        self.height = height
        self.pixels = List[UInt8](capacity=width * height * 3)
        for _ in range(width * height):
            self.pixels.append(fill.r)
            self.pixels.append(fill.g)
            self.pixels.append(fill.b)
        # empty stack == no clip active == the clip region is the whole canvas
        self.clip_stack = List[_ClipRect]()

    def __init__(out self, width: Int, height: Int, var pixels: List[UInt8]) raises:
        """Wrap an already-built RGB pixel buffer, skipping the
        solid-fill loop the (width, height, fill) constructor pays for.
        For a caller about to write every pixel itself -- downsample()
        in canvas_mojo/resize.mojo, which computes and appends every
        output pixel before handing the canvas back -- filling first
        would double the call's pixel-write cost.

        Raises unless `pixels` is exactly width * height * 3 bytes
        (RGB, row-major, the layout get_pixel/set_pixel assume). A
        wrong size is a caller bug, and wrapping it anyway would
        corrupt every later index.
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
        """
        var new_rect = _ClipRect(x, y, width, height)
        if len(self.clip_stack) > 0:
            new_rect = _intersect_clip(self.clip_stack[len(self.clip_stack) - 1], new_rect)
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
        """
        var idx = (y * self.width + x) * 3
        if color.a == 255:
            self.pixels[idx] = color.r
            self.pixels[idx + 1] = color.g
            self.pixels[idx + 2] = color.b
        else:
            var bg = self.get_pixel(x, y)
            var blended = color.blend_over(bg)
            self.pixels[idx] = blended.r
            self.pixels[idx + 1] = blended.g
            self.pixels[idx + 2] = blended.b

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
        if not self.in_bounds(x, y):
            return Color(0, 0, 0)
        var idx = (y * self.width + x) * 3
        return Color(self.pixels[idx], self.pixels[idx + 1], self.pixels[idx + 2])

    def fill(mut self, color: Color):
        var region = self.effective_fill_rect(0, 0, self.width, self.height)
        var rx = region[0]
        var ry = region[1]
        var rw = region[2]
        var rh = region[3]
        for y in range(ry, ry + rh):
            for x in range(rx, rx + rw):
                self.write_pixel(x, y, color)

    def fill_rect(mut self, x: Int, y: Int, width: Int, height: Int, color: Color):
        fill_rect(self, x, y, width, height, color)

    def fill_rect_gradient(
        mut self, x: Int, y: Int, width: Int, height: Int, gradient: LinearGradient
    ):
        fill_rect_gradient(self, x, y, width, height, gradient)

    def draw_line_aa(
        mut self, x0: Int, y0: Int, x1: Int, y1: Int, color: Color, width: Float64 = 1.0
    ):
        draw_line_aa(self, x0, y0, x1, y1, color, width=width)

    def fill_circle_aa(mut self, cx: Int, cy: Int, radius: Int, color: Color):
        fill_circle_aa(self, cx, cy, radius, color)

    def fill_arc_aa(
        mut self,
        cx: Float64,
        cy: Float64,
        radius: Float64,
        start_angle: Float64,
        end_angle: Float64,
        color: Color,
    ):
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
        fill_ring_sector_aa(self, cx, cy, inner_radius, outer_radius, start_angle, end_angle, color)

    def stroke_path_aa(mut self, path: Path, color: Color, width: Float64 = 1.0):
        stroke_path_aa(self, path, color, width=width)

    def fill_path_aa(mut self, path: Path, color: Color):
        fill_path_aa(self, path, color)
