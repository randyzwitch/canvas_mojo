"""Font face, scaled font, and font option wrappers for Cairo text rendering."""

from std.ffi import c_char, c_double, c_int, c_uint
from . import _bindings as bindings
from .cairo_enums import (
    Antialias,
    ColorMode,
    HintMetrics,
    HintStyle,
    Status,
    SubpixelOrder,
    TextClusterFlags,
)
from .cairo_types import FontExtents, Glyph, Matrix2D, TextCluster, TextExtents
from .common import _ensure_success


@fieldwise_init
struct TextToGlyphsResult(Movable):
    var glyphs: List[Glyph]
    var clusters: List[TextCluster]
    var cluster_flags: TextClusterFlags


struct FontOptions(Movable):
    """Owns and configures a `cairo_font_options_t` handle.

    Use `FontOptions` to control text rasterization behavior before applying
    it to a drawing `Context` via `set_font_options()`.
    """

    var _ptr: UnsafePointer[bindings.cairo_font_options_t, MutExternalOrigin]

    def __init__(out self) raises:
        self._ptr = bindings.cairo_font_options_create()
        _ensure_success(
            bindings.cairo_font_options_status(self._ptr),
            "cairo_font_options_create",
        )

    def __del__(deinit self):
        try:
            bindings.cairo_font_options_destroy(self._ptr)
        except _:
            pass

    def status(self) raises -> Status:
        """Return the current Cairo status for these options.

        Returns:
            Status: Status code for this options object.
        """
        return Status._from_ffi(bindings.cairo_font_options_status(self._ptr))

    def set_antialias(self, antialias: Antialias) raises:
        """Set the antialiasing mode for font rendering.

        Args:
            antialias: Antialiasing strategy to use for glyph rasterization.

        Raises:
            Error: If Cairo rejects the new option value.
        """
        bindings.cairo_font_options_set_antialias(
            self._ptr, antialias._to_ffi()
        )
        _ensure_success(
            bindings.cairo_font_options_status(self._ptr),
            "cairo_font_options_set_antialias",
        )

    def antialias(self) raises -> Antialias:
        """Get the configured antialiasing mode."""
        return Antialias._from_ffi(
            bindings.cairo_font_options_get_antialias(self._ptr)
        )

    def set_subpixel_order(self, value: SubpixelOrder) raises:
        bindings.cairo_font_options_set_subpixel_order(
            self._ptr, value._to_ffi()
        )
        _ensure_success(
            bindings.cairo_font_options_status(self._ptr),
            "cairo_font_options_set_subpixel_order",
        )

    def subpixel_order(self) raises -> SubpixelOrder:
        return SubpixelOrder._from_ffi(
            bindings.cairo_font_options_get_subpixel_order(self._ptr)
        )

    def set_hint_style(self, value: HintStyle) raises:
        bindings.cairo_font_options_set_hint_style(self._ptr, value._to_ffi())
        _ensure_success(
            bindings.cairo_font_options_status(self._ptr),
            "cairo_font_options_set_hint_style",
        )

    def hint_style(self) raises -> HintStyle:
        return HintStyle._from_ffi(
            bindings.cairo_font_options_get_hint_style(self._ptr)
        )

    def set_hint_metrics(self, value: HintMetrics) raises:
        bindings.cairo_font_options_set_hint_metrics(self._ptr, value._to_ffi())
        _ensure_success(
            bindings.cairo_font_options_status(self._ptr),
            "cairo_font_options_set_hint_metrics",
        )

    def hint_metrics(self) raises -> HintMetrics:
        return HintMetrics._from_ffi(
            bindings.cairo_font_options_get_hint_metrics(self._ptr)
        )

    def set_variations(self, variations: String) raises:
        var variations_mut = variations.copy()
        var variations_ptr = (
            variations_mut.as_c_string_slice()
            .unsafe_ptr()
            .unsafe_origin_cast[ImmutExternalOrigin]()
        )
        bindings.cairo_font_options_set_variations(self._ptr, variations_ptr)
        _ensure_success(
            bindings.cairo_font_options_status(self._ptr),
            "cairo_font_options_set_variations",
        )

    def variations(self) raises -> UnsafePointer[c_char, ImmutExternalOrigin]:
        return bindings.cairo_font_options_get_variations(self._ptr)

    def set_color_mode(self, mode: ColorMode) raises:
        bindings.cairo_font_options_set_color_mode(self._ptr, mode._to_ffi())
        _ensure_success(
            bindings.cairo_font_options_status(self._ptr),
            "cairo_font_options_set_color_mode",
        )

    def color_mode(self) raises -> ColorMode:
        return ColorMode._from_ffi(
            bindings.cairo_font_options_get_color_mode(self._ptr)
        )

    def set_color_palette(self, index: Int) raises:
        bindings.cairo_font_options_set_color_palette(self._ptr, c_uint(index))
        _ensure_success(
            bindings.cairo_font_options_status(self._ptr),
            "cairo_font_options_set_color_palette",
        )

    def color_palette(self) raises -> Int:
        return Int(bindings.cairo_font_options_get_color_palette(self._ptr))

    def set_custom_palette_color(
        self, index: Int, red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8
    ) raises:
        bindings.cairo_font_options_set_custom_palette_color(
            self._ptr,
            c_uint(index),
            c_double(Float64(red) / 255.0),
            c_double(Float64(green) / 255.0),
            c_double(Float64(blue) / 255.0),
            c_double(Float64(alpha) / 255.0),
        )
        _ensure_success(
            bindings.cairo_font_options_status(self._ptr),
            "cairo_font_options_set_custom_palette_color",
        )

    def custom_palette_color(self, index: Int) raises -> List[Float64]:
        var red_ptr = alloc[c_double](1)
        var green_ptr = alloc[c_double](1)
        var blue_ptr = alloc[c_double](1)
        var alpha_ptr = alloc[c_double](1)
        _ensure_success(
            bindings.cairo_font_options_get_custom_palette_color(
                self._ptr,
                c_uint(index),
                red_ptr,
                green_ptr,
                blue_ptr,
                alpha_ptr,
            ),
            "cairo_font_options_get_custom_palette_color",
        )
        var out: List[Float64] = [
            Float64(red_ptr[]),
            Float64(green_ptr[]),
            Float64(blue_ptr[]),
            Float64(alpha_ptr[]),
        ]
        red_ptr.free()
        green_ptr.free()
        blue_ptr.free()
        alpha_ptr.free()
        return out^

    def unsafe_raw_ptr(
        self,
    ) -> UnsafePointer[bindings.cairo_font_options_t, MutExternalOrigin]:
        """Expose the underlying raw Cairo font-options pointer."""
        return self._ptr


struct FontFace(Movable):
    """Owns a `cairo_font_face_t` reference.

    This type wraps a Cairo font-face handle and manages reference counting for
    borrowed or owned pointers.
    """

    var _ptr: UnsafePointer[bindings.cairo_font_face_t, MutExternalOrigin]

    def __init__(
        out self,
        *,
        unsafe_raw_ptr: UnsafePointer[
            bindings.cairo_font_face_t, MutExternalOrigin
        ],
    ) raises:
        self._ptr = unsafe_raw_ptr
        _ensure_success(
            bindings.cairo_font_face_status(self._ptr), "cairo_get_font_face"
        )

    @staticmethod
    def unsafe_from_owned_raw(
        unsafe_raw_ptr: UnsafePointer[
            bindings.cairo_font_face_t, MutExternalOrigin
        ]
    ) raises -> Self:
        """Wrap an owned raw Cairo font-face pointer.

        Args:
            unsafe_raw_ptr: Owned pointer transferred to this wrapper.

        Returns:
            FontFace: Managed wrapper for the provided font face.
        """
        return Self(unsafe_raw_ptr=unsafe_raw_ptr)

    @staticmethod
    def unsafe_from_borrowed(
        unsafe_borrowed_ptr: UnsafePointer[
            bindings.cairo_font_face_t, MutExternalOrigin
        ]
    ) raises -> Self:
        """Create a managed reference from a borrowed font-face pointer.

        This increments the Cairo reference count before wrapping.
        """
        return Self(
            unsafe_raw_ptr=bindings.cairo_font_face_reference(
                unsafe_borrowed_ptr
            )
        )

    def status(self) raises -> Status:
        """Return the current Cairo status for this font face."""
        return Status._from_ffi(bindings.cairo_font_face_status(self._ptr))

    def unsafe_raw_ptr(
        self,
    ) -> UnsafePointer[bindings.cairo_font_face_t, MutExternalOrigin]:
        """Expose the underlying raw Cairo font-face pointer."""
        return self._ptr

    def __del__(deinit self):
        try:
            bindings.cairo_font_face_destroy(self._ptr)
        except _:
            pass


struct ScaledFont(Movable):
    """Wrapper around cairo_scaled_font_t for low-level text APIs."""

    var _ptr: UnsafePointer[bindings.cairo_scaled_font_t, MutExternalOrigin]

    def __init__(
        out self,
        *,
        unsafe_raw_ptr: UnsafePointer[
            bindings.cairo_scaled_font_t, MutExternalOrigin
        ],
    ) raises:
        self._ptr = unsafe_raw_ptr
        _ensure_success(
            bindings.cairo_scaled_font_status(self._ptr), "cairo_scaled_font"
        )

    def __init__(
        out self,
        ref font_face: FontFace,
        font_matrix: Matrix2D,
        ctm: Matrix2D,
        ref options: FontOptions,
    ) raises:
        var font_matrix_ptr = alloc[bindings.cairo_matrix_t](1)
        var ctm_ptr = alloc[bindings.cairo_matrix_t](1)
        font_matrix_ptr[] = font_matrix.to_ffi()
        ctm_ptr[] = ctm.to_ffi()
        var font_matrix_ro = font_matrix_ptr.unsafe_mut_cast[target_mut=False]()
        var ctm_ro = ctm_ptr.unsafe_mut_cast[target_mut=False]()
        self._ptr = bindings.cairo_scaled_font_create(
            font_face.unsafe_raw_ptr(),
            font_matrix_ro.unsafe_origin_cast[ImmutExternalOrigin](),
            ctm_ro.unsafe_origin_cast[ImmutExternalOrigin](),
            options.unsafe_raw_ptr().unsafe_mut_cast[target_mut=False](),
        )
        font_matrix_ptr.free()
        ctm_ptr.free()
        _ensure_success(
            bindings.cairo_scaled_font_status(self._ptr),
            "cairo_scaled_font_create",
        )

    @staticmethod
    def unsafe_from_borrowed(
        unsafe_borrowed_ptr: UnsafePointer[
            bindings.cairo_scaled_font_t, MutExternalOrigin
        ]
    ) raises -> Self:
        return Self(
            unsafe_raw_ptr=bindings.cairo_scaled_font_reference(
                unsafe_borrowed_ptr
            )
        )

    def __del__(deinit self):
        try:
            bindings.cairo_scaled_font_destroy(self._ptr)
        except _:
            pass

    def status(self) raises -> Status:
        return Status._from_ffi(bindings.cairo_scaled_font_status(self._ptr))

    def extents(self) raises -> FontExtents:
        var extents_ptr = alloc[bindings.cairo_font_extents_t](1)
        bindings.cairo_scaled_font_extents(self._ptr, extents_ptr)
        _ensure_success(
            bindings.cairo_scaled_font_status(self._ptr),
            "cairo_scaled_font_extents",
        )
        var out = FontExtents.from_ffi(extents_ptr[])
        extents_ptr.free()
        return out

    def text_extents(self, text: String) raises -> TextExtents:
        var text_mut = text.copy()
        var text_ptr = (
            text_mut.as_c_string_slice()
            .unsafe_ptr()
            .unsafe_origin_cast[ImmutExternalOrigin]()
        )
        var extents_ptr = alloc[bindings.cairo_text_extents_t](1)
        bindings.cairo_scaled_font_text_extents(
            self._ptr, text_ptr, extents_ptr
        )
        _ensure_success(
            bindings.cairo_scaled_font_status(self._ptr),
            "cairo_scaled_font_text_extents",
        )
        var out = TextExtents.from_ffi(extents_ptr[])
        extents_ptr.free()
        return out

    def text_to_glyphs(
        self, x: Float64, y: Float64, text: String
    ) raises -> TextToGlyphsResult:
        var text_mut = text.copy()
        var text_ptr = (
            text_mut.as_c_string_slice()
            .unsafe_ptr()
            .unsafe_origin_cast[ImmutExternalOrigin]()
        )
        var glyphs_ptr_ptr = alloc[
            UnsafePointer[bindings.cairo_glyph_t, MutExternalOrigin]
        ](1)
        var num_glyphs_ptr = alloc[c_int](1)
        var clusters_ptr_ptr = alloc[
            UnsafePointer[bindings.cairo_text_cluster_t, MutExternalOrigin]
        ](1)
        var num_clusters_ptr = alloc[c_int](1)
        var flags_ptr = alloc[bindings.cairo_text_cluster_flags_t](1)
        glyphs_ptr_ptr[] = UnsafePointer[
            bindings.cairo_glyph_t, MutExternalOrigin
        ]()
        num_glyphs_ptr[] = c_int(0)
        clusters_ptr_ptr[] = UnsafePointer[
            bindings.cairo_text_cluster_t, MutExternalOrigin
        ]()
        num_clusters_ptr[] = c_int(0)
        flags_ptr[] = bindings.cairo_text_cluster_flags_t(c_uint(0))
        _ensure_success(
            bindings.cairo_scaled_font_text_to_glyphs(
                self._ptr,
                c_double(x),
                c_double(y),
                text_ptr,
                c_int(text.byte_length()),
                glyphs_ptr_ptr,
                num_glyphs_ptr,
                clusters_ptr_ptr,
                num_clusters_ptr,
                flags_ptr,
            ),
            "cairo_scaled_font_text_to_glyphs",
        )
        var glyphs: List[Glyph] = []
        for i in range(Int(num_glyphs_ptr[])):
            glyphs.append(Glyph.from_ffi(glyphs_ptr_ptr[][i]))
        var clusters: List[TextCluster] = []
        for i in range(Int(num_clusters_ptr[])):
            clusters.append(TextCluster.from_ffi(clusters_ptr_ptr[][i]))
        if Int(num_glyphs_ptr[]) > 0:
            bindings.cairo_glyph_free(glyphs_ptr_ptr[])
        if Int(num_clusters_ptr[]) > 0:
            bindings.cairo_text_cluster_free(clusters_ptr_ptr[])
        var out = TextToGlyphsResult(
            glyphs=glyphs^,
            clusters=clusters^,
            cluster_flags=TextClusterFlags._from_ffi(flags_ptr[]),
        )
        glyphs_ptr_ptr.free()
        num_glyphs_ptr.free()
        clusters_ptr_ptr.free()
        num_clusters_ptr.free()
        flags_ptr.free()
        return out^

    def unsafe_raw_ptr(
        self,
    ) -> UnsafePointer[bindings.cairo_scaled_font_t, MutExternalOrigin]:
        return self._ptr
