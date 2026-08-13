"""Drawing context bindings and scoped context-state management."""

from std.ffi import c_double, c_int, c_ulong
from cairo_mojo import _bindings as bindings
from cairo_mojo.cairo_enums import (
    Antialias,
    FillRule,
    FontSlant,
    FontWeight,
    LineCap,
    LineJoin,
    Operator,
    Status,
    TextClusterFlags,
)
from cairo_mojo.cairo_types import (
    Extents2D,
    FontExtents,
    Glyph,
    Matrix2D,
    Point2D,
    TextCluster,
    TextExtents,
)
from cairo_mojo.common import (
    _alloc_double_pair,
    _alloc_double_quad,
    _ensure_success,
)
from cairo_mojo.fonts import FontFace, FontOptions, ScaledFont
from cairo_mojo.paths import Path
from cairo_mojo.patterns import Pattern
from cairo_mojo.surfaces import Surface, SurfaceLike


struct ContextStateGuard(Movable):
    """Scoped context-state guard returned by `Context.scoped_state()`.

    This guard snapshots the current Cairo graphics state on construction and
    restores it when the guard is dropped, unless `dismiss()` is called.
    """

    var _ctx_ptr: UnsafePointer[bindings.cairo_t, MutExternalOrigin]
    var active: Bool

    def __init__(
        out self,
        unsafe_ctx_ptr: UnsafePointer[bindings.cairo_t, MutExternalOrigin],
    ) raises:
        self._ctx_ptr = unsafe_ctx_ptr
        self.active = True
        bindings.cairo_save(self._ctx_ptr)
        _ensure_success(bindings.cairo_status(self._ctx_ptr), "cairo_save")

    def dismiss(mut self):
        """Disable automatic restore on guard destruction.

        Use this when you intentionally want to keep the modified state
        instead of rolling back at scope exit.
        """
        self.active = False

    def __del__(deinit self):
        if self.active:
            try:
                bindings.cairo_restore(self._ctx_ptr)
            except _:
                pass


struct Context(Movable):
    """Owning wrapper around a `cairo_t` drawing context.

    Use `Context` as the primary drawing entry-point for paths, paint sources,
    clipping, transformations, and text rendering.

    Example:
    `var surface = ImageSurface(320, 200); var ctx = Context(surface);`
    `ctx.rectangle(16.0, 16.0, 120.0, 80.0); ctx.fill();`
    `surface.write_to_png("context_example.png")`
    """

    var ptr: UnsafePointer[bindings.cairo_t, MutExternalOrigin]

    def __init__[T: SurfaceLike](out self, ref surface: T) raises:
        """Create a drawing context targeting `surface`.

        Args:
            surface: Any `SurfaceLike` backend to draw into.

        Raises:
            Error: If Cairo fails to create the context.
        """
        self.ptr = bindings.cairo_create(surface.unsafe_raw_surface_ptr())
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_create")

    def __del__(deinit self):
        try:
            bindings.cairo_destroy(self.ptr)
        except _:
            pass

    def unsafe_raw_ptr(
        self,
    ) -> UnsafePointer[bindings.cairo_t, MutExternalOrigin]:
        """Expose the underlying raw Cairo context pointer."""
        return self.ptr

    def status(self) raises -> Status:
        """Return the current Cairo status for this context.

        Returns:
            Status: Current status code reported by Cairo.
        """
        return Status._from_ffi(bindings.cairo_status(self.ptr))

    def set_source_rgb(self, r: Float64, g: Float64, b: Float64) raises:
        """Set the current source to an opaque RGB color.

        Args:
            r: Red channel in range `[0.0, 1.0]`.
            g: Green channel in range `[0.0, 1.0]`.
            b: Blue channel in range `[0.0, 1.0]`.

        Raises:
            Error: If Cairo rejects the source update.
        """
        bindings.cairo_set_source_rgb(
            self.ptr, c_double(r), c_double(g), c_double(b)
        )
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_set_source_rgb")

    def set_source_rgba(
        self, r: Float64, g: Float64, b: Float64, a: Float64
    ) raises:
        """Set the current source to an RGBA color.

        Args:
            r: Red channel in range `[0.0, 1.0]`.
            g: Green channel in range `[0.0, 1.0]`.
            b: Blue channel in range `[0.0, 1.0]`.
            a: Alpha channel in range `[0.0, 1.0]`.

        Raises:
            Error: If Cairo rejects the source update.
        """
        bindings.cairo_set_source_rgba(
            self.ptr, c_double(r), c_double(g), c_double(b), c_double(a)
        )
        _ensure_success(
            bindings.cairo_status(self.ptr), "cairo_set_source_rgba"
        )

    def set_source_surface[
        T: SurfaceLike
    ](self, ref surface: T, x: Float64 = 0.0, y: Float64 = 0.0) raises:
        """Set the current source from another surface with an offset.

        Args:
            surface: Source surface sampled during subsequent paint/fill/stroke.
            x: Horizontal offset in user-space units.
            y: Vertical offset in user-space units.

        Raises:
            Error: If Cairo cannot bind the source surface.
        """
        bindings.cairo_set_source_surface(
            self.ptr, surface.unsafe_raw_surface_ptr(), c_double(x), c_double(y)
        )
        _ensure_success(
            bindings.cairo_status(self.ptr), "cairo_set_source_surface"
        )

    def set_source_pattern(self, ref pattern: Pattern) raises:
        """Set the current source pattern.

        Args:
            pattern: Pattern used for subsequent drawing operations.

        Raises:
            Error: If Cairo fails while binding the pattern.
        """
        bindings.cairo_set_source(self.ptr, pattern.unsafe_raw_ptr())
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_set_source")

    def source_pattern(self) raises -> Pattern:
        """Get a managed reference to the current source pattern.

        Returns:
            Pattern: Referenced source pattern.
        """
        var borrowed = bindings.cairo_get_source(self.ptr)
        return Pattern.unsafe_from_borrowed(borrowed)

    def target_surface(self) raises -> Surface:
        """Get the current target surface."""
        var borrowed = bindings.cairo_get_target(self.ptr)
        return Surface.unsafe_from_borrowed(borrowed)

    def group_target_surface(self) raises -> Surface:
        """Get the current group target surface."""
        var borrowed = bindings.cairo_get_group_target(self.ptr)
        return Surface.unsafe_from_borrowed(borrowed)

    def paint(self) raises:
        """Paint the current source over the entire clip region.

        Raises:
            Error: If painting fails.
        """
        bindings.cairo_paint(self.ptr)
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_paint")

    def paint_with_alpha(self, alpha: Float64) raises:
        """Paint the current source with global alpha modulation."""
        bindings.cairo_paint_with_alpha(self.ptr, c_double(alpha))
        _ensure_success(
            bindings.cairo_status(self.ptr), "cairo_paint_with_alpha"
        )

    def save(self) raises:
        """Push the current graphics state onto the stack.

        Use with `restore()` to isolate temporary style/transform/clip changes.

        Raises:
            Error: If state cannot be saved.
        """
        bindings.cairo_save(self.ptr)
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_save")

    def scoped_state(self) raises -> ContextStateGuard:
        """Return an RAII state guard equivalent to `save`/`restore`.

        Returns:
            ContextStateGuard: Guard that restores state at scope exit.

        Raises:
            Error: If state cannot be saved for the guard.
        """
        return ContextStateGuard(self.ptr)

    def push_group(self) raises:
        """Redirect drawing to a temporary intermediate group."""
        bindings.cairo_push_group(self.ptr)
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_push_group")

    def pop_group(self) raises -> Pattern:
        """Pop the current group and return it as a source pattern."""
        var pattern_ptr = bindings.cairo_pop_group(self.ptr)
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_pop_group")
        return Pattern(unsafe_raw_ptr=pattern_ptr)

    def pop_group_to_source(self) raises:
        """Pop the current group and set it as the source pattern."""
        bindings.cairo_pop_group_to_source(self.ptr)
        _ensure_success(
            bindings.cairo_status(self.ptr), "cairo_pop_group_to_source"
        )

    def restore(self) raises:
        """Pop and restore the previous graphics state.

        Raises:
            Error: If no saved state is available or restoration fails.
        """
        bindings.cairo_restore(self.ptr)
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_restore")

    def set_operator(self, op: Operator) raises:
        """Set the compositing operator."""
        bindings.cairo_set_operator(self.ptr, op._to_ffi())
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_set_operator")

    def operator(self) raises -> Operator:
        """Return current compositing operator."""
        return Operator._from_ffi(bindings.cairo_get_operator(self.ptr))

    def set_antialias(self, antialias: Antialias) raises:
        """Set antialiasing mode for drawing."""
        bindings.cairo_set_antialias(self.ptr, antialias._to_ffi())
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_set_antialias")

    def antialias(self) raises -> Antialias:
        return Antialias._from_ffi(bindings.cairo_get_antialias(self.ptr))

    def set_line_width(self, width: Float64) raises:
        """Set stroke line width in user-space units."""
        bindings.cairo_set_line_width(self.ptr, c_double(width))
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_set_line_width")

    def line_width(self) raises -> Float64:
        return Float64(bindings.cairo_get_line_width(self.ptr))

    def set_hairline(self, enabled: Bool) raises:
        """Enable or disable hairline stroke mode."""
        bindings.cairo_set_hairline(
            self.ptr, bindings.cairo_bool_t(c_int(1 if enabled else 0))
        )
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_set_hairline")

    def hairline(self) raises -> Bool:
        """Return whether hairline stroke mode is enabled."""
        return Int(bindings.cairo_get_hairline(self.ptr)) != 0

    def set_line_cap(self, line_cap: LineCap) raises:
        """Set stroke line-cap style."""
        bindings.cairo_set_line_cap(self.ptr, line_cap._to_ffi())
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_set_line_cap")

    def line_cap(self) raises -> LineCap:
        return LineCap._from_ffi(bindings.cairo_get_line_cap(self.ptr))

    def set_line_join(self, line_join: LineJoin) raises:
        """Set stroke line-join style."""
        bindings.cairo_set_line_join(self.ptr, line_join._to_ffi())
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_set_line_join")

    def line_join(self) raises -> LineJoin:
        return LineJoin._from_ffi(bindings.cairo_get_line_join(self.ptr))

    def set_fill_rule(self, fill_rule: FillRule) raises:
        """Set the fill rule for path filling."""
        bindings.cairo_set_fill_rule(self.ptr, fill_rule._to_ffi())
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_set_fill_rule")

    def fill_rule(self) raises -> FillRule:
        return FillRule._from_ffi(bindings.cairo_get_fill_rule(self.ptr))

    def set_dash(self, ref dashes: List[Float64], offset: Float64 = 0.0) raises:
        """Set dash pattern for stroking."""
        if len(dashes) == 0:
            bindings.cairo_set_dash(
                self.ptr,
                UnsafePointer[c_double, ImmutExternalOrigin](),
                c_int(0),
                c_double(offset),
            )
        else:
            var dashes_ptr = (
                dashes.unsafe_ptr()
                .unsafe_mut_cast[target_mut=False]()
                .unsafe_origin_cast[ImmutExternalOrigin]()
            )
            bindings.cairo_set_dash(
                self.ptr, dashes_ptr, c_int(len(dashes)), c_double(offset)
            )
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_set_dash")

    def set_miter_limit(self, limit: Float64) raises:
        """Set the miter join limit for stroking."""
        bindings.cairo_set_miter_limit(self.ptr, c_double(limit))
        _ensure_success(
            bindings.cairo_status(self.ptr), "cairo_set_miter_limit"
        )

    def miter_limit(self) raises -> Float64:
        return Float64(bindings.cairo_get_miter_limit(self.ptr))

    def set_tolerance(self, tolerance: Float64) raises:
        """Set curve approximation tolerance."""
        bindings.cairo_set_tolerance(self.ptr, c_double(tolerance))
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_set_tolerance")

    def tolerance(self) raises -> Float64:
        return Float64(bindings.cairo_get_tolerance(self.ptr))

    def translate(self, tx: Float64, ty: Float64) raises:
        """Apply a translation to the current transformation matrix.

        Args:
            tx: Translation along the x-axis.
            ty: Translation along the y-axis.

        Raises:
            Error: If Cairo fails to update the matrix.
        """
        bindings.cairo_translate(self.ptr, c_double(tx), c_double(ty))
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_translate")

    def scale(self, sx: Float64, sy: Float64) raises:
        """Apply a scale to the current transformation matrix.

        Args:
            sx: Scale factor along the x-axis.
            sy: Scale factor along the y-axis.

        Raises:
            Error: If Cairo fails to update the matrix.
        """
        bindings.cairo_scale(self.ptr, c_double(sx), c_double(sy))
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_scale")

    def rotate(self, angle: Float64) raises:
        """Apply a rotation to the current transformation matrix.

        Args:
            angle: Rotation angle in radians.

        Raises:
            Error: If Cairo fails to update the matrix.
        """
        bindings.cairo_rotate(self.ptr, c_double(angle))
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_rotate")

    def identity_matrix(self) raises:
        """Reset the current transformation matrix to identity."""
        bindings.cairo_identity_matrix(self.ptr)
        _ensure_success(
            bindings.cairo_status(self.ptr), "cairo_identity_matrix"
        )

    def matrix(self) raises -> Matrix2D:
        """Return the current transformation matrix.

        Returns:
            Matrix2D: Current user-space to device-space transform.

        Raises:
            Error: If Cairo cannot read the transform.
        """
        var matrix_ptr = alloc[bindings.cairo_matrix_t](1)
        bindings.cairo_get_matrix(self.ptr, matrix_ptr)
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_get_matrix")
        var out = Matrix2D.from_ffi(matrix_ptr[])
        matrix_ptr.free()
        return out

    def set_matrix(self, matrix: Matrix2D) raises:
        """Replace the current transformation matrix.

        Args:
            matrix: New transform to install.

        Raises:
            Error: If Cairo cannot apply the transform.
        """
        var matrix_ptr = alloc[bindings.cairo_matrix_t](1)
        matrix_ptr[] = matrix.to_ffi()
        var matrix_ro_ptr = matrix_ptr.unsafe_mut_cast[target_mut=False]()
        bindings.cairo_set_matrix(self.ptr, matrix_ro_ptr)
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_set_matrix")
        matrix_ptr.free()

    def user_to_device(self, point: Point2D) raises -> Point2D:
        """Transform a user-space point into device space."""
        var x_ptr = alloc[c_double](1)
        var y_ptr = alloc[c_double](1)
        x_ptr[] = c_double(point.x)
        y_ptr[] = c_double(point.y)
        bindings.cairo_user_to_device(self.ptr, x_ptr, y_ptr)
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_user_to_device")
        var out = Point2D(Float64(x_ptr[]), Float64(y_ptr[]))
        x_ptr.free()
        y_ptr.free()
        return out

    def user_to_device_distance(self, distance: Point2D) raises -> Point2D:
        """Transform a user-space distance vector into device space."""
        var dx_ptr = alloc[c_double](1)
        var dy_ptr = alloc[c_double](1)
        dx_ptr[] = c_double(distance.x)
        dy_ptr[] = c_double(distance.y)
        bindings.cairo_user_to_device_distance(self.ptr, dx_ptr, dy_ptr)
        _ensure_success(
            bindings.cairo_status(self.ptr), "cairo_user_to_device_distance"
        )
        var out = Point2D(Float64(dx_ptr[]), Float64(dy_ptr[]))
        dx_ptr.free()
        dy_ptr.free()
        return out

    def device_to_user(self, point: Point2D) raises -> Point2D:
        """Transform a device-space point into user space."""
        var x_ptr = alloc[c_double](1)
        var y_ptr = alloc[c_double](1)
        x_ptr[] = c_double(point.x)
        y_ptr[] = c_double(point.y)
        bindings.cairo_device_to_user(self.ptr, x_ptr, y_ptr)
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_device_to_user")
        var out = Point2D(Float64(x_ptr[]), Float64(y_ptr[]))
        x_ptr.free()
        y_ptr.free()
        return out

    def device_to_user_distance(self, distance: Point2D) raises -> Point2D:
        """Transform a device-space distance vector into user space."""
        var dx_ptr = alloc[c_double](1)
        var dy_ptr = alloc[c_double](1)
        dx_ptr[] = c_double(distance.x)
        dy_ptr[] = c_double(distance.y)
        bindings.cairo_device_to_user_distance(self.ptr, dx_ptr, dy_ptr)
        _ensure_success(
            bindings.cairo_status(self.ptr), "cairo_device_to_user_distance"
        )
        var out = Point2D(Float64(dx_ptr[]), Float64(dy_ptr[]))
        dx_ptr.free()
        dy_ptr.free()
        return out

    def new_path(self) raises:
        """Clear the current path."""
        bindings.cairo_new_path(self.ptr)
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_new_path")

    def new_sub_path(self) raises:
        """Start a new disconnected sub-path."""
        bindings.cairo_new_sub_path(self.ptr)
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_new_sub_path")

    def copy_path(self) raises -> Path:
        """Copy current path including curves."""
        return Path.unsafe_from_owned_raw(bindings.cairo_copy_path(self.ptr))

    def copy_path_flat(self) raises -> Path:
        """Copy current path flattened to lines."""
        return Path.unsafe_from_owned_raw(
            bindings.cairo_copy_path_flat(self.ptr)
        )

    def append_path(self, ref path: Path) raises:
        """Append a copied path onto current path."""
        bindings.cairo_append_path(
            self.ptr,
            path.unsafe_raw_ptr()
            .unsafe_mut_cast[target_mut=False]()
            .unsafe_origin_cast[ImmutExternalOrigin](),
        )
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_append_path")

    def move_to(self, x: Float64, y: Float64) raises:
        """Begin a new sub-path at `(x, y)`.

        Args:
            x: Destination x coordinate in user space.
            y: Destination y coordinate in user space.

        Raises:
            Error: If Cairo fails to update the current path.
        """
        bindings.cairo_move_to(self.ptr, c_double(x), c_double(y))
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_move_to")

    def line_to(self, x: Float64, y: Float64) raises:
        """Add a line segment to `(x, y)`.

        Args:
            x: Endpoint x coordinate in user space.
            y: Endpoint y coordinate in user space.

        Raises:
            Error: If Cairo fails to update the current path.
        """
        bindings.cairo_line_to(self.ptr, c_double(x), c_double(y))
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_line_to")

    def curve_to(
        self,
        x1: Float64,
        y1: Float64,
        x2: Float64,
        y2: Float64,
        x3: Float64,
        y3: Float64,
    ) raises:
        """Add a cubic Bezier segment to the current path."""
        bindings.cairo_curve_to(
            self.ptr,
            c_double(x1),
            c_double(y1),
            c_double(x2),
            c_double(y2),
            c_double(x3),
            c_double(y3),
        )
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_curve_to")

    def arc(
        self,
        xc: Float64,
        yc: Float64,
        radius: Float64,
        angle1: Float64,
        angle2: Float64,
    ) raises:
        """Add a circular arc swept from `angle1` to `angle2`.

        Args:
            xc: Arc center x coordinate.
            yc: Arc center y coordinate.
            radius: Arc radius in user-space units.
            angle1: Start angle in radians.
            angle2: End angle in radians.

        Raises:
            Error: If Cairo fails to append the arc.
        """
        bindings.cairo_arc(
            self.ptr,
            c_double(xc),
            c_double(yc),
            c_double(radius),
            c_double(angle1),
            c_double(angle2),
        )
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_arc")

    def arc_negative(
        self,
        xc: Float64,
        yc: Float64,
        radius: Float64,
        angle1: Float64,
        angle2: Float64,
    ) raises:
        """Add a circular arc in negative-angle direction."""
        bindings.cairo_arc_negative(
            self.ptr,
            c_double(xc),
            c_double(yc),
            c_double(radius),
            c_double(angle1),
            c_double(angle2),
        )
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_arc_negative")

    def rel_move_to(self, dx: Float64, dy: Float64) raises:
        """Move the current point by a relative offset."""
        bindings.cairo_rel_move_to(self.ptr, c_double(dx), c_double(dy))
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_rel_move_to")

    def rel_line_to(self, dx: Float64, dy: Float64) raises:
        """Add a relative line segment to the current path."""
        bindings.cairo_rel_line_to(self.ptr, c_double(dx), c_double(dy))
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_rel_line_to")

    def rel_curve_to(
        self,
        dx1: Float64,
        dy1: Float64,
        dx2: Float64,
        dy2: Float64,
        dx3: Float64,
        dy3: Float64,
    ) raises:
        """Add a relative cubic Bezier segment."""
        bindings.cairo_rel_curve_to(
            self.ptr,
            c_double(dx1),
            c_double(dy1),
            c_double(dx2),
            c_double(dy2),
            c_double(dx3),
            c_double(dy3),
        )
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_rel_curve_to")

    def rectangle(
        self, x: Float64, y: Float64, width: Float64, height: Float64
    ) raises:
        """Add an axis-aligned rectangle to the current path.

        Args:
            x: Rectangle top-left x coordinate.
            y: Rectangle top-left y coordinate.
            width: Rectangle width.
            height: Rectangle height.

        Raises:
            Error: If Cairo fails to append the rectangle path.
        """
        bindings.cairo_rectangle(
            self.ptr,
            c_double(x),
            c_double(y),
            c_double(width),
            c_double(height),
        )
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_rectangle")

    def close_path(self) raises:
        """Close the current sub-path."""
        bindings.cairo_close_path(self.ptr)
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_close_path")

    def clip(self) raises:
        """Intersect the clip region with the current path."""
        bindings.cairo_clip(self.ptr)
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_clip")

    def clip_preserve(self) raises:
        """Apply clipping but preserve the current path."""
        bindings.cairo_clip_preserve(self.ptr)
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_clip_preserve")

    def reset_clip(self) raises:
        """Reset the clip region to its default."""
        bindings.cairo_reset_clip(self.ptr)
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_reset_clip")

    def clip_extents(self) raises -> Extents2D:
        """Return the extents of the current clip region."""
        var x1_ptr = UnsafePointer[c_double, MutExternalOrigin]()
        var y1_ptr = UnsafePointer[c_double, MutExternalOrigin]()
        var x2_ptr = UnsafePointer[c_double, MutExternalOrigin]()
        var y2_ptr = UnsafePointer[c_double, MutExternalOrigin]()
        _alloc_double_quad(x1_ptr, y1_ptr, x2_ptr, y2_ptr)
        bindings.cairo_clip_extents(self.ptr, x1_ptr, y1_ptr, x2_ptr, y2_ptr)
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_clip_extents")
        var out = Extents2D(
            Float64(x1_ptr[]),
            Float64(y1_ptr[]),
            Float64(x2_ptr[]),
            Float64(y2_ptr[]),
        )
        x1_ptr.free()
        y1_ptr.free()
        x2_ptr.free()
        y2_ptr.free()
        return out

    def fill(self) raises:
        """Fill the current path and clear it afterwards.

        Raises:
            Error: If filling fails.
        """
        bindings.cairo_fill(self.ptr)
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_fill")

    def fill_preserve(self) raises:
        """Fill the current path while preserving it."""
        bindings.cairo_fill_preserve(self.ptr)
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_fill_preserve")

    def stroke(self) raises:
        """Stroke the current path and clear it afterwards.

        Raises:
            Error: If stroking fails.
        """
        bindings.cairo_stroke(self.ptr)
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_stroke")

    def stroke_preserve(self) raises:
        """Stroke the current path while preserving it."""
        bindings.cairo_stroke_preserve(self.ptr)
        _ensure_success(
            bindings.cairo_status(self.ptr), "cairo_stroke_preserve"
        )

    def stroke_extents(self) raises -> Extents2D:
        """Return bounds that would be affected by stroking."""
        var x1_ptr = UnsafePointer[c_double, MutExternalOrigin]()
        var y1_ptr = UnsafePointer[c_double, MutExternalOrigin]()
        var x2_ptr = UnsafePointer[c_double, MutExternalOrigin]()
        var y2_ptr = UnsafePointer[c_double, MutExternalOrigin]()
        _alloc_double_quad(x1_ptr, y1_ptr, x2_ptr, y2_ptr)
        bindings.cairo_stroke_extents(self.ptr, x1_ptr, y1_ptr, x2_ptr, y2_ptr)
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_stroke_extents")
        var out = Extents2D(
            Float64(x1_ptr[]),
            Float64(y1_ptr[]),
            Float64(x2_ptr[]),
            Float64(y2_ptr[]),
        )
        x1_ptr.free()
        y1_ptr.free()
        x2_ptr.free()
        y2_ptr.free()
        return out

    def fill_extents(self) raises -> Extents2D:
        """Return bounds that would be affected by filling."""
        var x1_ptr = UnsafePointer[c_double, MutExternalOrigin]()
        var y1_ptr = UnsafePointer[c_double, MutExternalOrigin]()
        var x2_ptr = UnsafePointer[c_double, MutExternalOrigin]()
        var y2_ptr = UnsafePointer[c_double, MutExternalOrigin]()
        _alloc_double_quad(x1_ptr, y1_ptr, x2_ptr, y2_ptr)
        bindings.cairo_fill_extents(self.ptr, x1_ptr, y1_ptr, x2_ptr, y2_ptr)
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_fill_extents")
        var out = Extents2D(
            Float64(x1_ptr[]),
            Float64(y1_ptr[]),
            Float64(x2_ptr[]),
            Float64(y2_ptr[]),
        )
        x1_ptr.free()
        y1_ptr.free()
        x2_ptr.free()
        y2_ptr.free()
        return out

    def in_fill(self, x: Float64, y: Float64) raises -> Bool:
        """Return whether `(x, y)` lies within fill area."""
        return (
            Int(bindings.cairo_in_fill(self.ptr, c_double(x), c_double(y))) != 0
        )

    def in_stroke(self, x: Float64, y: Float64) raises -> Bool:
        """Return whether `(x, y)` lies within stroke area."""
        return (
            Int(bindings.cairo_in_stroke(self.ptr, c_double(x), c_double(y)))
            != 0
        )

    def in_clip(self, x: Float64, y: Float64) raises -> Bool:
        """Return whether `(x, y)` lies within the clip region."""
        return (
            Int(bindings.cairo_in_clip(self.ptr, c_double(x), c_double(y))) != 0
        )

    def has_current_point(self) raises -> Bool:
        """Return whether the context currently has a current point."""
        return Int(bindings.cairo_has_current_point(self.ptr)) != 0

    def current_point(self) raises -> Point2D:
        """Return the current point."""
        var x_ptr = UnsafePointer[c_double, MutExternalOrigin]()
        var y_ptr = UnsafePointer[c_double, MutExternalOrigin]()
        _alloc_double_pair(x_ptr, y_ptr)
        bindings.cairo_get_current_point(self.ptr, x_ptr, y_ptr)
        _ensure_success(
            bindings.cairo_status(self.ptr), "cairo_get_current_point"
        )
        var out = Point2D(Float64(x_ptr[]), Float64(y_ptr[]))
        x_ptr.free()
        y_ptr.free()
        return out

    def mask(self, ref pattern: Pattern) raises:
        """Mask paint operations using a pattern."""
        bindings.cairo_mask(self.ptr, pattern.unsafe_raw_ptr())
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_mask")

    def mask_surface[
        T: SurfaceLike
    ](self, ref surface: T, x: Float64 = 0.0, y: Float64 = 0.0) raises:
        """Mask paint operations using a surface."""
        bindings.cairo_mask_surface(
            self.ptr, surface.unsafe_raw_surface_ptr(), c_double(x), c_double(y)
        )
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_mask_surface")

    def copy_page(self) raises:
        """Emit current page while preserving page contents."""
        bindings.cairo_copy_page(self.ptr)
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_copy_page")

    def show_page(self) raises:
        """Emit current page and clear for next page."""
        bindings.cairo_show_page(self.ptr)
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_show_page")

    def tag_begin(self, tag_name: String, attributes: String = "") raises:
        """Begin a tagged content section."""
        var tag_name_mut = tag_name.copy()
        var tag_name_ptr = (
            tag_name_mut.as_c_string_slice()
            .unsafe_ptr()
            .unsafe_origin_cast[ImmutExternalOrigin]()
        )
        var attributes_mut = attributes.copy()
        var attributes_ptr = (
            attributes_mut.as_c_string_slice()
            .unsafe_ptr()
            .unsafe_origin_cast[ImmutExternalOrigin]()
        )
        bindings.cairo_tag_begin(self.ptr, tag_name_ptr, attributes_ptr)
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_tag_begin")

    def tag_end(self, tag_name: String) raises:
        """End a tagged content section."""
        var tag_name_mut = tag_name.copy()
        var tag_name_ptr = (
            tag_name_mut.as_c_string_slice()
            .unsafe_ptr()
            .unsafe_origin_cast[ImmutExternalOrigin]()
        )
        bindings.cairo_tag_end(self.ptr, tag_name_ptr)
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_tag_end")

    def select_font_face(
        self,
        family: String,
        slant: FontSlant = FontSlant.NORMAL,
        weight: FontWeight = FontWeight.NORMAL,
    ) raises:
        """Select a toy-font face by family, slant, and weight.

        Args:
            family: Font family name, for example `"Sans"` or `"Serif"`.
            slant: Font slant style.
            weight: Font weight style.

        Raises:
            Error: If Cairo fails to select the font face.
        """
        var family_mut = family.copy()
        var family_ptr = (
            family_mut.as_c_string_slice()
            .unsafe_ptr()
            .unsafe_origin_cast[ImmutExternalOrigin]()
        )
        bindings.cairo_select_font_face(
            self.ptr, family_ptr, slant._to_ffi(), weight._to_ffi()
        )
        _ensure_success(
            bindings.cairo_status(self.ptr), "cairo_select_font_face"
        )

    def set_font_size(self, size: Float64) raises:
        """Set current font size in user-space units.

        Args:
            size: Font size measured in user-space units.

        Raises:
            Error: If Cairo fails to update the font size.
        """
        bindings.cairo_set_font_size(self.ptr, c_double(size))
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_set_font_size")

    def set_font_options(self, ref options: FontOptions) raises:
        """Set rendering options for font rasterization."""
        bindings.cairo_set_font_options(self.ptr, options.unsafe_raw_ptr())
        _ensure_success(
            bindings.cairo_status(self.ptr), "cairo_set_font_options"
        )

    def set_scaled_font(self, ref scaled_font: ScaledFont) raises:
        bindings.cairo_set_scaled_font(
            self.ptr,
            scaled_font.unsafe_raw_ptr()
            .unsafe_mut_cast[target_mut=False]()
            .unsafe_origin_cast[ImmutExternalOrigin](),
        )
        _ensure_success(
            bindings.cairo_status(self.ptr), "cairo_set_scaled_font"
        )

    def scaled_font(self) raises -> ScaledFont:
        var borrowed = bindings.cairo_get_scaled_font(self.ptr)
        return ScaledFont.unsafe_from_borrowed(borrowed)

    def show_text(self, text: String) raises:
        """Draw UTF-8 text at the current point.

        Args:
            text: Text content encoded as UTF-8.

        Raises:
            Error: If Cairo text rendering fails.
        """
        var text_mut = text.copy()
        var text_ptr = (
            text_mut.as_c_string_slice()
            .unsafe_ptr()
            .unsafe_origin_cast[ImmutExternalOrigin]()
        )
        bindings.cairo_show_text(self.ptr, text_ptr)
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_show_text")

    def text_path(self, text: String) raises:
        """Add glyph outlines for text to the current path."""
        var text_mut = text.copy()
        var text_ptr = (
            text_mut.as_c_string_slice()
            .unsafe_ptr()
            .unsafe_origin_cast[ImmutExternalOrigin]()
        )
        bindings.cairo_text_path(self.ptr, text_ptr)
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_text_path")

    def font_face(self) raises -> FontFace:
        """Return the currently selected font face."""
        var borrowed = bindings.cairo_get_font_face(self.ptr)
        return FontFace.unsafe_from_borrowed(borrowed)

    def set_font_face(self, ref font_face: FontFace) raises:
        """Set the current font face."""
        bindings.cairo_set_font_face(self.ptr, font_face.unsafe_raw_ptr())
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_set_font_face")

    def text_extents(self, text: String) raises -> TextExtents:
        """Measure text extents for UTF-8 text.

        Args:
            text: Text to measure.

        Returns:
            TextExtents: Bearings, size, and advance metrics.

        Raises:
            Error: If Cairo cannot compute text metrics.
        """
        var text_mut = text.copy()
        var text_ptr = (
            text_mut.as_c_string_slice()
            .unsafe_ptr()
            .unsafe_origin_cast[ImmutExternalOrigin]()
        )
        var extents_ptr = alloc[bindings.cairo_text_extents_t](1)
        extents_ptr[] = bindings.cairo_text_extents_t(
            c_double(0.0),
            c_double(0.0),
            c_double(0.0),
            c_double(0.0),
            c_double(0.0),
            c_double(0.0),
        )
        bindings.cairo_text_extents(self.ptr, text_ptr, extents_ptr)
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_text_extents")
        var out = TextExtents.from_ffi(extents_ptr[])
        extents_ptr.free()
        return out

    def font_extents(self) raises -> FontExtents:
        """Return extents for the currently selected font.

        Returns:
            FontExtents: Ascent, descent, height, and max advance metrics.

        Raises:
            Error: If Cairo cannot compute font metrics.
        """
        var extents_ptr = alloc[bindings.cairo_font_extents_t](1)
        extents_ptr[] = bindings.cairo_font_extents_t(
            c_double(0.0),
            c_double(0.0),
            c_double(0.0),
            c_double(0.0),
            c_double(0.0),
        )
        bindings.cairo_font_extents(self.ptr, extents_ptr)
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_font_extents")
        var out = FontExtents.from_ffi(extents_ptr[])
        extents_ptr.free()
        return out

    def show_glyphs(self, ref glyphs: List[Glyph]) raises:
        var count = len(glyphs)
        if count == 0:
            return
        var glyph_ptr = alloc[bindings.cairo_glyph_t](count)
        for i in range(count):
            glyph_ptr[i] = bindings.cairo_glyph_t(
                index=c_ulong(glyphs[i].index),
                x=c_double(glyphs[i].x),
                y=c_double(glyphs[i].y),
            )
        bindings.cairo_show_glyphs(
            self.ptr,
            glyph_ptr.unsafe_mut_cast[target_mut=False]().unsafe_origin_cast[
                ImmutExternalOrigin
            ](),
            c_int(count),
        )
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_show_glyphs")
        glyph_ptr.free()

    def show_text_glyphs(
        self,
        text: String,
        ref glyphs: List[Glyph],
        ref clusters: List[TextCluster],
        cluster_flags: TextClusterFlags = TextClusterFlags.NONE,
    ) raises:
        var glyph_count = len(glyphs)
        var cluster_count = len(clusters)
        var glyph_ptr = alloc[bindings.cairo_glyph_t](glyph_count)
        var cluster_ptr = alloc[bindings.cairo_text_cluster_t](cluster_count)
        for i in range(glyph_count):
            glyph_ptr[i] = bindings.cairo_glyph_t(
                index=c_ulong(glyphs[i].index),
                x=c_double(glyphs[i].x),
                y=c_double(glyphs[i].y),
            )
        for i in range(cluster_count):
            cluster_ptr[i] = bindings.cairo_text_cluster_t(
                num_bytes=c_int(clusters[i].num_bytes),
                num_glyphs=c_int(clusters[i].num_glyphs),
            )
        var text_mut = text.copy()
        var text_ptr = (
            text_mut.as_c_string_slice()
            .unsafe_ptr()
            .unsafe_origin_cast[ImmutExternalOrigin]()
        )
        bindings.cairo_show_text_glyphs(
            self.ptr,
            text_ptr,
            c_int(text.byte_length()),
            glyph_ptr.unsafe_mut_cast[target_mut=False]().unsafe_origin_cast[
                ImmutExternalOrigin
            ](),
            c_int(glyph_count),
            cluster_ptr.unsafe_mut_cast[target_mut=False]().unsafe_origin_cast[
                ImmutExternalOrigin
            ](),
            c_int(cluster_count),
            cluster_flags._to_ffi(),
        )
        _ensure_success(
            bindings.cairo_status(self.ptr), "cairo_show_text_glyphs"
        )
        glyph_ptr.free()
        cluster_ptr.free()

    def glyph_extents(self, ref glyphs: List[Glyph]) raises -> TextExtents:
        var count = len(glyphs)
        if count == 0:
            return TextExtents(0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
        var glyph_ptr = alloc[bindings.cairo_glyph_t](count)
        for i in range(count):
            glyph_ptr[i] = bindings.cairo_glyph_t(
                index=c_ulong(glyphs[i].index),
                x=c_double(glyphs[i].x),
                y=c_double(glyphs[i].y),
            )
        var extents_ptr = alloc[bindings.cairo_text_extents_t](1)
        bindings.cairo_glyph_extents(
            self.ptr,
            glyph_ptr.unsafe_mut_cast[target_mut=False]().unsafe_origin_cast[
                ImmutExternalOrigin
            ](),
            c_int(count),
            extents_ptr,
        )
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_glyph_extents")
        var out = TextExtents.from_ffi(extents_ptr[])
        glyph_ptr.free()
        extents_ptr.free()
        return out

    def glyph_path(self, ref glyphs: List[Glyph]) raises:
        var count = len(glyphs)
        if count == 0:
            return
        var glyph_ptr = alloc[bindings.cairo_glyph_t](count)
        for i in range(count):
            glyph_ptr[i] = bindings.cairo_glyph_t(
                index=c_ulong(glyphs[i].index),
                x=c_double(glyphs[i].x),
                y=c_double(glyphs[i].y),
            )
        bindings.cairo_glyph_path(
            self.ptr,
            glyph_ptr.unsafe_mut_cast[target_mut=False]().unsafe_origin_cast[
                ImmutExternalOrigin
            ](),
            c_int(count),
        )
        _ensure_success(bindings.cairo_status(self.ptr), "cairo_glyph_path")
        glyph_ptr.free()
