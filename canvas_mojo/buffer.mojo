"""The pixel raster buffer at the core of the canvas package."""

from canvas_mojo.color import Color
from canvas_mojo.gradient import LinearGradient
from canvas_mojo.vector.draw_target import DrawTarget
from canvas_mojo.path import Path, fill_path_aa, stroke_path_aa
from canvas_mojo.primitives import (
    draw_line_aa,
    fill_arc_aa,
    fill_circle_aa,
    fill_rect,
    fill_rect_gradient,
    fill_ring_sector_aa,
)


struct _ClipRect(ImplicitlyCopyable, Movable):
    """A clip rectangle -- private to this module. Not the same type
    as canvas_mojo.geometry.Point/anything public; this is purely an
    implementation detail of Canvas's clip stack.
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
    """The overlapping region of two clip rects. A nested clip can
    only ever shrink the drawable region, never escape an ancestor's
    -- this is what makes that true: pushing a rect that extends past
    the current clip gets cut down to the overlap, not applied as-is.
    Disjoint rects produce a zero-size result (clamped, not negative),
    which in_clip's half-open bounds check then correctly treats as
    "nothing is inside this clip."
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

    Conforms to `DrawTarget` (see that trait's own docstring) via the
    six methods just below `fill` -- each a thin delegation to the
    matching free function in `canvas_mojo.primitives`/`canvas_mojo.path` (the
    exact functions every existing call site already calls directly,
    e.g. `draw_line_aa(canvas, ...)`, unchanged) so a caller can render
    generically through a `Canvas` the same way it can through an
    `SvgCanvas` (see `DrawTarget`, `canvas_mojo/vector/draw_target.mojo`).
    Free-function call sites keep working exactly as before -- these
    methods are additive, not a replacement.

    Deliberately does *not* include a `draw_text` method (`DrawTarget`
    itself has none either -- see that trait's own docstring for the
    current reasoning: raster and vector backends draw text through
    fundamentally different mechanisms, not a shared operation like
    this trait's other six methods). Use
    `canvas_mojo.text.draw_text(canvas, ...)` directly, exactly as every
    existing call site already does.
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

    def in_bounds(self, x: Int, y: Int) -> Bool:
        return x >= 0 and x < self.width and y >= 0 and y < self.height

    def push_clip(mut self, x: Int, y: Int, width: Int, height: Int):
        """Restrict subsequent drawing to this sub-rectangle -- every
        primitive gets this for free with no changes of its own, since
        they all write through set_pixel.

        Intersects with the current effective clip (the whole canvas,
        if nothing's been pushed yet) rather than replacing it, and
        pushes the *intersected* result -- so nested clips compose:
        a sub-plot's clip can restrict drawing further than its parent
        plot's, but can never let drawing escape the parent's region,
        even if the sub-plot's own rectangle extends past it. Pair
        with pop_clip() to remove exactly this level when done.

        A clip rectangle extending past the canvas's own bounds is
        fine; in_bounds still rejects anything outside the canvas.
        """
        var new_rect = _ClipRect(x, y, width, height)
        if len(self.clip_stack) > 0:
            new_rect = _intersect_clip(self.clip_stack[len(self.clip_stack) - 1], new_rect)
        self.clip_stack.append(new_rect)

    def pop_clip(mut self):
        """Remove the most recently pushed clip, reverting to whatever
        was active before it -- a parent clip if one exists, or no
        clip (the whole canvas) if this was the only one pushed.

        A no-op on an empty stack, not an error: matches in_bounds'
        existing philosophy elsewhere in this struct of failing safe
        on an out-of-range request rather than raising, since an
        unbalanced pop is a caller bug this can't distinguish from
        "nothing to undo" without more state than a stack alone gives.
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

    def get_pixel(self, x: Int, y: Int) -> Color:
        if not self.in_bounds(x, y):
            return Color(0, 0, 0)
        var idx = (y * self.width + x) * 3
        return Color(self.pixels[idx], self.pixels[idx + 1], self.pixels[idx + 2])

    def fill(mut self, color: Color):
        for y in range(self.height):
            for x in range(self.width):
                self.set_pixel(x, y, color)

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
