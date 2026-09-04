"""The pixel raster buffer at the core of the canvas package."""

# Bytes per pixel: R, G, B, A, straight (non-premultiplied) alpha.
#
# The alpha channel is what lets a canvas have a transparent
# background -- `Canvas(w, h, Color(0, 0, 0, 0))` -- and therefore what
# lets `write_png` emit a PNG with real transparency and `read_png`
# keep the alpha of a file that has one.
#
# Straight rather than premultiplied, so `get_pixel` returns the colour
# a caller would recognise: premultiplying is the better representation
# for repeated compositing, but it makes every read lossy at low alpha
# and would change what every existing caller of `get_pixel` sees.
comptime BYTES_PER_PIXEL = 4

from std.sys import size_of

from canvas.color import Color, _div255
from canvas.gradient import LinearGradient
from canvas.vector.draw_target import DrawTarget
from canvas.fill_rule import FillRule
from canvas.geometry import Matrix2D, _mapped_bounds, _mapped_rect
from canvas.path import (
    Path,
    fill_path_aa,
    stroke_path_aa,
    _path_coverage_mask,
    _rect_path,
    _through,
)
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
    # For a rectangle push_clip turned into a clip path (a rotated or
    # skewed transform): how many clip masks were pushed before it, so
    # pop_clip can pop the mask along with this entry. -1 for a plain
    # rectangle.
    var mask_depth: Int

    def __init__(
        out self, x: Int, y: Int, width: Int, height: Int, mask_depth: Int = -1
    ):
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.mask_depth = mask_depth


struct _CanvasState(ImplicitlyCopyable, Movable):
    """What `Canvas.save` records and `Canvas.restore` puts back: the
    transform, and how deep the two clip stacks were.
    """

    var transform: Matrix2D
    var transformed: Bool
    var clip_depth: Int
    var mask_depth: Int

    def __init__(
        out self,
        transform: Matrix2D,
        transformed: Bool,
        clip_depth: Int,
        mask_depth: Int,
    ):
        self.transform = transform
        self.transformed = transformed
        self.clip_depth = clip_depth
        self.mask_depth = mask_depth


def _pack_rgba(color: Color) -> UInt32:
    """`color`'s four bytes as the one 32-bit word a pixel occupies in
    memory, so a solid fill is one store per pixel rather than four.

    Little-endian, r in the low byte, which is every platform this
    package builds for (linux-64, osx-arm64); a big-endian target would
    need the bytes swapped.
    """
    return (
        UInt32(color.r)
        | (UInt32(color.g) << 8)
        | (UInt32(color.b) << 16)
        | (UInt32(color.a) << 24)
    )


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
    """A width x height RGBA raster buffer, row-major, 4 bytes per pixel.

    Alpha is stored per-pixel and straight, not premultiplied (see
    BYTES_PER_PIXEL), so a canvas can carry a transparent background and
    `write_png` can emit real transparency.

    There is no `draw_text` method, since `DrawTarget` has none. Call
    `canvas.text.render.draw_text(canvas, ...)`.
    """

    var width: Int
    var height: Int
    var pixels: List[UInt8]
    var _clip_stack: List[_ClipRect]
    # Coverage masks pushed by push_clip_path, innermost last. Each is
    # width*height bytes: 255 fully inside the clip, 0 fully outside,
    # and the values between are what make a clip path's own edge
    # anti-aliased rather than a staircase.
    #
    # A stack of whole masks rather than one mask plus a stack of undo
    # information: a mask is w*h bytes, and nesting clips more than a
    # couple deep is not something a chart does, so the simpler
    # structure costs nothing that matters. Each pushed mask is already
    # intersected with its parent (see push_clip_path), so only the top
    # one is ever consulted -- the same arrangement clip_stack uses for
    # rectangles.
    var clip_masks: List[List[UInt8]]
    # len(clip_masks), mirrored as a plain Int. `set_pixel` tests this
    # once per pixel drawn anywhere in the package, and a bare field
    # load beats reaching into a List-of-Lists for its length.
    var _clip_mask_count: Int
    # Keeps the struct over 256 bytes, which is the line between a
    # `Canvas` argument being copied into the callee and being passed
    # by reference. `set_pixel` and the methods it calls take the
    # canvas once per pixel for every hard-edged primitive and every
    # clip-path blend, so at 256 bytes or less that copy is paid per
    # pixel and grows with the struct. Measured on the 800x600
    # benchmark, `draw_line solid full diagonal` is 7.2 us with the
    # struct at 96 bytes, 10.3 at 160, 12.9 at 224, 14.2 at 256, and
    # 4.2 at 264 and every size above; `fill_circle_aa x2000 under a
    # clip path` is 3.4 ms at 96 bytes and 2.1 ms at 264. Fields added
    # without crossing the line only make it worse, which is what
    # happened to an earlier clip-bounds cache (#145). The check in
    # `__init__` keeps it over the line as fields come and go. Measured
    # with Mojo 1.0 (#182); re-measure those two rows if a compiler
    # update changes how arguments are passed.
    var _layout_pad: InlineArray[UInt8, 176]
    # The current transform (see `save`), and whether it is anything
    # but the identity. Every drawing call tests the flag once, so it
    # is a field rather than six comparisons on the matrix.
    var _transform: Matrix2D
    var _transformed: Bool
    var _saved: List[_CanvasState]

    def __init__(
        out self, width: Int, height: Int, fill: Color = Color(255, 255, 255)
    ) raises:
        """Allocate a `width x height` canvas, every pixel set to `fill`.

        A zero width or height gives an empty canvas and is allowed; a
        negative one raises, since the allocation below sizes itself
        from `width * height * 4` and a negative length is not a
        buffer this type can represent.

        Args:
            width: Canvas width in pixels.
            height: Canvas height in pixels.
            fill: Initial color for every pixel.

        Raises:
            Error: `width` or `height` is negative.
        """
        if width < 0 or height < 0:
            raise Error(
                "Canvas(width, height, fill): dimensions must be"
                " non-negative (got "
                + String(width)
                + "x"
                + String(height)
                + ")"
            )
        self.width = width
        self.height = height

        # One 32-bit store per pixel of the packed colour (see
        # _pack_rgba and _store_packed). The buffer's base is
        # allocator-aligned and every pixel sits at a multiple of four
        # bytes, so the 32-bit stores are aligned; the vector stores
        # make no alignment assumption.
        var total = width * height * BYTES_PER_PIXEL
        self.pixels = List[UInt8](length=total, fill=0)
        self._clip_stack = List[_ClipRect]()
        self.clip_masks = List[List[UInt8]]()
        self._clip_mask_count = 0
        self._layout_pad = InlineArray[UInt8, 176](fill=0)
        comptime assert (
            size_of[Canvas]() > 256
        ), "Canvas must stay over 256 bytes -- see _layout_pad"
        self._transform = Matrix2D.identity()
        self._transformed = False
        self._saved = List[_CanvasState]()
        if total == 0:
            return

        self._store_packed(0, width * height, _pack_rgba(fill))

    def __init__(
        out self, width: Int, height: Int, var pixels: List[UInt8]
    ) raises:
        """Wrap an already-built RGBA pixel buffer, skipping the
        solid-fill loop the (width, height, fill) constructor pays for.
        For a caller about to write every pixel itself, such as
        `downsample()` in canvas/resize.mojo.

        Raises unless `pixels` is exactly width * height * 4 bytes (RGBA,
        row-major, the layout get_pixel/set_pixel assume); a wrong-sized
        buffer would corrupt every later index.

        Args:
            width: Canvas width in pixels.
            height: Canvas height in pixels.
            pixels: Row-major RGBA bytes, exactly width * height * 4
                long.

        Raises:
            Error: `pixels`' length isn't width * height * 4.
        """
        if len(pixels) != width * height * BYTES_PER_PIXEL:
            raise Error(
                "Canvas(width, height, pixels): pixels must be exactly"
                " width * height * 4 bytes (got "
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
        self._clip_stack = List[_ClipRect]()
        self.clip_masks = List[List[UInt8]]()
        self._clip_mask_count = 0
        self._layout_pad = InlineArray[UInt8, 176](fill=0)
        comptime assert (
            size_of[Canvas]() > 256
        ), "Canvas must stay over 256 bytes -- see _layout_pad"
        self._transform = Matrix2D.identity()
        self._transformed = False
        self._saved = List[_CanvasState]()

    def save(mut self):
        """Push the current transform and clip state, for `restore` to
        put back. The pair works as Cairo's `cairo_save`/`cairo_restore`
        and the HTML5 canvas's `save`/`restore` do: whatever
        `translate`, `rotate`, `scale`, `transform`, `set_transform`,
        `push_clip` or `push_clip_path` does between the two is undone
        by `restore`, so a caller can set up a local frame for one part
        of a drawing and leave the canvas as it found it.
        """
        self._saved.append(
            _CanvasState(
                self._transform,
                self._transformed,
                len(self._clip_stack),
                self._clip_mask_count,
            )
        )

    def restore(mut self):
        """Pop the state `save` pushed: the transform goes back to what
        it was, and every clip pushed since -- rectangle or path -- is
        popped. A no-op with nothing saved, matching `pop_clip`.
        """
        if len(self._saved) == 0:
            return
        var state = self._saved.pop()
        while self._clip_mask_count > state.mask_depth:
            self.pop_clip_path()
        while len(self._clip_stack) > state.clip_depth:
            _ = self._clip_stack.pop()
        self._transform = state.transform
        self._transformed = state.transformed

    def translate(mut self, tx: Float64, ty: Float64):
        """Shift the origin subsequent drawing is measured from by
        (tx, ty), in the current user space: after `scale(2.0, 2.0)`,
        `translate(10.0, 0.0)` moves it 20 pixels.

        Args:
            tx: Horizontal shift.
            ty: Vertical shift.
        """
        self.transform(Matrix2D.translation(tx, ty))

    def rotate(mut self, angle: Float64):
        """Turn subsequent drawing by `angle` radians about the current
        origin. Positive turns +x toward +y, clockwise on screen.

        Args:
            angle: Radians.
        """
        self.transform(Matrix2D.rotation(angle))

    def scale(mut self, sx: Float64, sy: Float64):
        """Scale subsequent drawing about the current origin, each axis
        by its own factor. A negative factor mirrors that axis --
        `scale(1.0, -1.0)` after a `translate` to the bottom of a plot
        area gives a y-up coordinate system.

        Args:
            sx: Horizontal factor.
            sy: Vertical factor.
        """
        self.transform(Matrix2D.scaling(sx, sy))

    def transform(mut self, matrix: Matrix2D):
        """Compose `matrix` into the current transform, applied to
        coordinates before everything already in place -- the same
        order `translate`/`rotate`/`scale` compose in, so a
        `Matrix2D(Transform2D(...))` slots in like any of them.

        Args:
            matrix: The map to apply first.
        """
        self._set_transform(matrix.then(self._transform))

    def set_transform(mut self, matrix: Matrix2D):
        """Replace the current transform outright.

        Args:
            matrix: The new map from user space to device pixels.
        """
        self._set_transform(matrix)

    def reset_transform(mut self):
        """Back to the identity: coordinates are device pixels again.
        Clips are left alone; `restore` undoes both.
        """
        self._set_transform(Matrix2D.identity())

    def current_transform(self) -> Matrix2D:
        """The map every drawing call currently applies.

        Returns:
            The current transform; the identity if none is set.
        """
        return self._transform

    def has_transform(self) -> Bool:
        """Whether the current transform is anything but the identity.
        Each drawing primitive checks this once and, when it is false,
        runs exactly as it did before transforms existed.

        Returns:
            True if drawing is being mapped.
        """
        return self._transformed

    def _set_transform(mut self, matrix: Matrix2D):
        self._transform = matrix
        self._transformed = not matrix.is_identity()

    def _take_transform(mut self) -> Matrix2D:
        """The current transform, with the canvas left at the identity:
        for a primitive that has mapped its own coordinates to device
        space and is about to call a drawing function that would
        otherwise map them again. Put it back with `_set_transform`.
        """
        var m = self._transform
        self._set_transform(Matrix2D.identity())
        return m

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
        primitive picks it up, since they all write through set_pixel.

        Intersects with the current effective clip and pushes the result,
        so nested clips compose: a child can restrict further but never
        escape its parent's region, even if its own rectangle extends
        past it. Pair with pop_clip(). A clip rectangle extending past
        the canvas bounds is fine; in_bounds still rejects anything
        outside the canvas.

        Under a canvas transform the rectangle is in user space. An
        axis-aligned transform maps it to another rectangle; a rotated
        or skewed one turns it into a clip path, with its bounding
        rectangle on this stack so `pop_clip` removes both together.

        Args:
            x: Clip rectangle's left edge.
            y: Clip rectangle's top edge.
            width: Clip rectangle's width.
            height: Clip rectangle's height.
        """
        if self._transformed:
            if self._transform.is_axis_aligned():
                var r = _mapped_rect(self._transform, x, y, width, height)
                self._push_clip_rect(r[0], r[1], r[2], r[3], -1)
                return
            var depth = self._clip_mask_count
            self._push_clip_mask(
                _through(_rect_path(x, y, width, height), self._transform),
                FillRule.EVEN_ODD,
                4,
                0,
            )
            var bb = _mapped_bounds(self._transform, x, y, width, height)
            self._push_clip_rect(bb[0], bb[1], bb[2], bb[3], depth)
            return
        self._push_clip_rect(x, y, width, height, -1)

    def _push_clip_rect(
        mut self, x: Int, y: Int, width: Int, height: Int, mask_depth: Int
    ):
        """Intersect a device-space rectangle with the current clip and
        push it; `mask_depth` is -1 or the mask count the entry owns
        from (see `_ClipRect`).
        """
        var new_rect = _ClipRect(x, y, width, height)
        if len(self._clip_stack) > 0:
            new_rect = _intersect_clip(
                self._clip_stack[len(self._clip_stack) - 1], new_rect
            )
        new_rect.mask_depth = mask_depth
        self._clip_stack.append(new_rect)

    def pop_clip(mut self):
        """Remove the most recently pushed clip, reverting to the parent
        clip if one exists or to the whole canvas if not.

        A no-op on an empty stack rather than an error, matching
        in_bounds' handling of out-of-range requests: a stack alone
        cannot distinguish an unbalanced pop from "nothing to undo".
        """
        if len(self._clip_stack) == 0:
            return
        var top = self._clip_stack.pop()
        if top.mask_depth >= 0:
            while self._clip_mask_count > top.mask_depth:
                self.pop_clip_path()

    def push_clip_path(
        mut self,
        path: Path,
        fill_rule: FillRule = FillRule.EVEN_ODD,
        supersample: Int = 4,
        curve_steps: Int = 0,
    ):
        """Restrict subsequent drawing to `path`'s interior -- the
        arbitrary-shape counterpart of `push_clip`. Costs one byte per
        pixel.

        The clip is *anti-aliased*, not a hard in/out test: the path's
        coverage becomes a 0-255 mask, and a pixel the path half covers
        lets half the drawing through.

        A new mask is multiplied into the current one, so a nested clip
        can only restrict further, never escape its parent. Rectangle
        clips still apply independently on top. Pair with
        `pop_clip_path`. Under a canvas transform `path` is in user
        space and is mapped before it is rasterized.

        Args:
            path: Shape to clip to. Its interior is what stays visible.
            fill_rule: EVEN_ODD (default) or NONZERO -- see FillRule.
                Governs the interior of a self-intersecting or
                multi-sub-path clip shape exactly as it does a fill.
            supersample: Sub-pixel grid side length used to compute the
                mask's edge coverage.
            curve_steps: Straight-line segments per quad/cubic Bezier.
                0 (the default) picks a count from the curvature.
        """
        if self._transformed:
            self._push_clip_mask(
                _through(path, self._transform),
                fill_rule,
                supersample,
                curve_steps,
            )
        else:
            self._push_clip_mask(path, fill_rule, supersample, curve_steps)

    def _push_clip_mask(
        mut self,
        path: Path,
        fill_rule: FillRule,
        supersample: Int,
        curve_steps: Int,
    ):
        """`push_clip_path` for a path already in device space."""
        var mask = _path_coverage_mask(
            path, self.width, self.height, fill_rule, supersample, curve_steps
        )
        if self._clip_mask_count > 0:
            # Intersect with the parent by multiplying coverages: a
            # pixel half-covered by an outer clip and half by an inner
            # one lets a quarter through, which is what nesting two
            # translucent stencils physically does.
            ref parent = self.clip_masks[self._clip_mask_count - 1]
            var mp = mask.unsafe_ptr()
            var pp = parent.unsafe_ptr()
            for i in range(self.width * self.height):
                var m = Int(mp[unsafe_offset=i])
                if m != 0:
                    mp[unsafe_offset=i] = UInt8(
                        _div255(m * Int(pp[unsafe_offset=i]))
                    )
        self.clip_masks.append(mask^)
        self._clip_mask_count += 1

    def has_clip_mask(self) -> Bool:
        """Whether a clip path is currently active.

        The check a caller writing through `write_pixel` needs: that
        method skips every per-pixel test, and a clip path's coverage is
        per-pixel by nature, so a bulk writer routes through `set_pixel`
        while one is pushed. See `write_pixel` and `_fill_region`.

        Returns:
            True if at least one clip path is pushed.
        """
        return self._clip_mask_count > 0

    def pop_clip_path(mut self):
        """Remove the most recently pushed clip path, reverting to the
        parent clip path if one exists or to no path clip if not.

        A no-op on an empty stack, matching `pop_clip`.
        """
        if self._clip_mask_count > 0:
            _ = self.clip_masks.pop()
            self._clip_mask_count -= 1

    def clip_coverage(self, x: Int, y: Int) -> UInt8:
        """How much of (x, y) the active clip paths let through: 255 if
        no clip path is active or the pixel is fully inside one, 0 if
        fully outside, in between on an anti-aliased boundary.

        Rectangle clips are not included; `in_clip` covers those, and
        `set_pixel` applies both.

        Args:
            x: Column to query.
            y: Row to query.

        Returns:
            Coverage 0-255.
        """
        if self._clip_mask_count == 0:
            return 255
        if not self.in_bounds(x, y):
            return 0
        return self.clip_masks[self._clip_mask_count - 1][y * self.width + x]

    def in_clip(self, x: Int, y: Int) -> Bool:
        """Whether (x, y) is inside the active clip region.

        Args:
            x: Column to check.
            y: Row to check.

        Returns:
            True if no clip is active, or (x, y) is inside the
            innermost pushed clip rectangle.
        """
        if len(self._clip_stack) == 0:
            return True
        # A reference, not a copy: this runs per pixel inside every
        # primitive's loop, and copying the entry is enough to push
        # set_pixel past what inlines there.
        ref top = self._clip_stack[len(self._clip_stack) - 1]
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
        if self._clip_mask_count != 0:
            self._set_pixel_masked(x, y, color)
            return
        self.write_pixel(x, y, color)

    def _set_pixel_masked(mut self, x: Int, y: Int, color: Color):
        """`set_pixel`'s clip-path branch, kept out of line.

        `set_pixel` runs once per pixel for every primitive here, so its
        common path has to stay small enough to inline into those loops.
        Keep this branch, and the plain-integer `_clip_mask_count` guard
        that gates it, out of `set_pixel`'s body; folding either inline
        measurably slows every fill.
        """
        var coverage = self.clip_masks[self._clip_mask_count - 1][
            y * self.width + x
        ]
        if coverage == 0:
            return
        if coverage == 255:
            self.write_pixel(x, y, color)
            return
        # Coverage scales the drawn colour's own alpha rather than
        # replacing it, so clipping a translucent fill compounds the two.
        self.write_pixel(
            x, y, color.with_alpha(UInt8(_div255(Int(color.a) * Int(coverage))))
        )

    def _store_packed(mut self, start: Int, count: Int, packed: UInt32):
        """Write `packed` (see `_pack_rgba`) to `count` consecutive
        pixels from pixel index `start`, eight at a time through vector
        stores and one at a time for the remainder. This is what a
        solid fill costs per row: no scratch span to build or free, and
        the wide stores keep a canvas-wide row at memcpy speed.
        """
        comptime LANES = 8
        var p32 = self.pixels.unsafe_ptr().unsafe_bitcast[UInt32]()
        var vec = SIMD[DType.uint32, LANES](packed)
        var idx = start
        var end = start + count
        while idx + LANES <= end:
            p32.unsafe_offset(idx).unsafe_store(vec)
            idx += LANES
        while idx < end:
            p32[unsafe_offset=idx] = packed
            idx += 1

    def write_pixel(mut self, x: Int, y: Int, color: Color):
        """Write `color` at (x, y) *without* set_pixel's in_bounds/
        in_clip checks. The caller must already know (x, y) is inside
        both the canvas and the active clip, typically from a range
        `effective_fill_rect` (below) intersected against both.

        It also skips the clip *path* mask, which `effective_fill_rect`
        cannot fold in: a rectangle clip is a range, but a path clip is a
        per-pixel coverage value. A bulk writer must therefore check
        `has_clip_mask()` and fall back to `set_pixel` when one is
        active, as `_fill_region` and the gradient rect fills in
        canvas.shapes.rects do.

        Writes go through `pixels.unsafe_ptr()`, unchecked. The index is
        computed from `width` and the caller's validated (x, y), so it
        cannot leave the buffer. The blend path reads the background
        bytes from the same pointer rather than through `get_pixel`.

        Args:
            x: Column to write. Must already be known in-bounds.
            y: Row to write. Must already be known in-bounds.
            color: Color to write, blended over the existing pixel if
                translucent.
        """
        var idx = (y * self.width + x) * BYTES_PER_PIXEL
        var p = self.pixels.unsafe_ptr()
        if color.a == 255:
            p[unsafe_offset=idx] = color.r
            p[unsafe_offset=idx + 1] = color.g
            p[unsafe_offset=idx + 2] = color.b
            p[unsafe_offset=idx + 3] = 255
            return

        var dst_a = p[unsafe_offset=idx + 3]
        if dst_a == 255:
            # The overwhelmingly common case -- anything drawn onto a
            # canvas with an opaque background -- and the one that
            # avoids a per-pixel division. See Color.blend_over_opaque.
            var opaque_blend = color.blend_over_opaque(
                p[unsafe_offset=idx],
                p[unsafe_offset=idx + 1],
                p[unsafe_offset=idx + 2],
            )
            p[unsafe_offset=idx] = opaque_blend.r
            p[unsafe_offset=idx + 1] = opaque_blend.g
            p[unsafe_offset=idx + 2] = opaque_blend.b
            p[unsafe_offset=idx + 3] = 255
            return

        var blended = color.blend_over(
            Color(
                p[unsafe_offset=idx],
                p[unsafe_offset=idx + 1],
                p[unsafe_offset=idx + 2],
                dst_a,
            )
        )
        p[unsafe_offset=idx] = blended.r
        p[unsafe_offset=idx + 1] = blended.g
        p[unsafe_offset=idx + 2] = blended.b
        p[unsafe_offset=idx + 3] = blended.a

    def effective_fill_rect(
        self, x: Int, y: Int, width: Int, height: Int
    ) -> Tuple[Int, Int, Int, Int]:
        """The (x, y, width, height) a rectangular fill covering
        [x, x+width) x [y, y+height) may actually touch, intersected
        against the canvas bounds and the active clip -- the same
        intersection set_pixel enforces per pixel, computed once for a
        caller about to loop over the whole region. Pair with
        write_pixel.

        A returned width/height of 0 means nothing in the requested
        rectangle is drawable; `range(0)` is a no-op, so callers need no
        separate check.

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
        if len(self._clip_stack) > 0:
            ref top_clip = self._clip_stack[len(self._clip_stack) - 1]
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
        return self.read_pixel(x, y)

    def read_pixel(self, x: Int, y: Int) -> Color:
        """Read (x, y) *without* `get_pixel`'s in_bounds check, the
        counterpart to `write_pixel` and subject to the same contract:
        the caller must already know the coordinate is on the canvas,
        typically because the loop bounds came from `width`/`height`.

        `get_pixel` stays the checked entry point, and returns opaque
        black off-canvas rather than reading out of range. Whole-image
        passes -- downsampling, encoding a file -- derive every
        coordinate from the canvas's dimensions, so the check
        re-establishes what the loop already guarantees.

        Args:
            x: Column to read. Must already be known in-bounds.
            y: Row to read. Must already be known in-bounds.

        Returns:
            The pixel's color.
        """
        var idx = (y * self.width + x) * BYTES_PER_PIXEL
        var p = self.pixels.unsafe_ptr()
        return Color(
            p[unsafe_offset=idx],
            p[unsafe_offset=idx + 1],
            p[unsafe_offset=idx + 2],
            p[unsafe_offset=idx + 3],
        )

    def fill(mut self, color: Color):
        """Fill the whole canvas (or the active clip region, if any)
        with `color`.

        Args:
            color: Color to fill with, blended over existing pixels if
                translucent.
        """
        var region = self.effective_fill_rect(0, 0, self.width, self.height)
        self._fill_region(region[0], region[1], region[2], region[3], color)

    def _fill_region(
        mut self, rx: Int, ry: Int, rw: Int, rh: Int, color: Color
    ):
        """Fill an already-clipped, already-bounds-checked rectangle --
        the region `effective_fill_rect` returns, so every coordinate in
        it is known drawable and no per-pixel check is needed.

        The translucent case blends per pixel but hoists what does not
        vary: the source colour's premultiplied terms and the
        complementary alpha are computed once for the whole rectangle,
        leaving one multiply-add and one `_div255` per channel where the
        destination is opaque. That branch is `blend_over_opaque`
        inlined, with the same arithmetic. A translucent destination
        falls back to `blend_over` and its per-pixel divide.
        """
        if rw <= 0 or rh <= 0:
            return

        # A clip path modulates each pixel individually, which neither
        # the bulk copy nor the hoisted blend below can express -- so
        # with one active this falls back to the checked per-pixel
        # path, which already consults the mask. Nothing pays for this
        # until a clip path is actually pushed.
        if self._clip_mask_count > 0:
            for y in range(ry, ry + rh):
                for x in range(rx, rx + rw):
                    self.set_pixel(x, y, color)
            return

        var p = self.pixels.unsafe_ptr()
        var stride = self.width * BYTES_PER_PIXEL

        if color.a == 255:
            # One 32-bit store per pixel of the packed colour, and no
            # scratch span to allocate per call -- fill_circle_aa and
            # fill_ellipse_aa call this once per interior row.
            var packed = _pack_rgba(color)
            for y in range(ry, ry + rh):
                self._store_packed(y * self.width + rx, rw, packed)
            return

        if color.a == 0:
            return

        # Unit-stride inner loop with the index carried along rather
        # than a strided `range`, which benchmarked slower (#78).
        var sa = Int(color.a)
        var inv = 255 - sa
        var cr = Int(color.r) * sa
        var cg = Int(color.g) * sa
        var cb = Int(color.b) * sa
        for y in range(ry, ry + rh):
            var idx = y * stride + rx * BYTES_PER_PIXEL
            for _ in range(rw):
                if p[unsafe_offset=idx + 3] == 255:
                    # Opaque destination: the hoisted division-free
                    # form, and the result stays opaque.
                    p[unsafe_offset=idx] = UInt8(
                        _div255(cr + Int(p[unsafe_offset=idx]) * inv)
                    )
                    p[unsafe_offset=idx + 1] = UInt8(
                        _div255(cg + Int(p[unsafe_offset=idx + 1]) * inv)
                    )
                    p[unsafe_offset=idx + 2] = UInt8(
                        _div255(cb + Int(p[unsafe_offset=idx + 2]) * inv)
                    )
                else:
                    # Translucent destination: the general src-over,
                    # which needs the per-pixel divide.
                    var blended = color.blend_over(
                        Color(
                            p[unsafe_offset=idx],
                            p[unsafe_offset=idx + 1],
                            p[unsafe_offset=idx + 2],
                            p[unsafe_offset=idx + 3],
                        )
                    )
                    p[unsafe_offset=idx] = blended.r
                    p[unsafe_offset=idx + 1] = blended.g
                    p[unsafe_offset=idx + 2] = blended.b
                    p[unsafe_offset=idx + 3] = blended.a
                idx += BYTES_PER_PIXEL

    def begin_annotated_group(mut self, title: String):
        """`DrawTarget`'s group label, which a raster canvas has
        nowhere to put: a no-op, so code written against the trait runs
        unchanged on either backend. `SvgCanvas` emits
        `<g><title>` here.

        Args:
            title: Ignored.
        """
        pass

    def end_annotated_group(mut self):
        """Closes what `begin_annotated_group` did not open: a no-op,
        for the same reason.
        """
        pass

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
