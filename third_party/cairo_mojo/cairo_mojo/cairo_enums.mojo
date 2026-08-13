"""Typed enum wrappers for Cairo constants and status values."""

from std.ffi import c_int, c_uint
from . import _bindings as bindings


@fieldwise_init
struct Status(Copyable, ImplicitlyCopyable, Movable, RegisterPassable):
    """Cairo status/error codes."""

    var _value: Int

    comptime SUCCESS = Self(0)
    comptime NO_MEMORY = Self(1)
    comptime INVALID_RESTORE = Self(2)
    comptime INVALID_POP_GROUP = Self(3)
    comptime NO_CURRENT_POINT = Self(4)
    comptime INVALID_MATRIX = Self(5)
    comptime INVALID_STATUS = Self(6)
    comptime NULL_POINTER = Self(7)
    comptime INVALID_STRING = Self(8)
    comptime INVALID_PATH_DATA = Self(9)
    comptime READ_ERROR = Self(10)
    comptime WRITE_ERROR = Self(11)
    comptime SURFACE_FINISHED = Self(12)
    comptime SURFACE_TYPE_MISMATCH = Self(13)
    comptime PATTERN_TYPE_MISMATCH = Self(14)
    comptime INVALID_CONTENT = Self(15)
    comptime INVALID_FORMAT = Self(16)
    comptime INVALID_VISUAL = Self(17)
    comptime FILE_NOT_FOUND = Self(18)
    comptime INVALID_DASH = Self(19)
    comptime INVALID_DSC_COMMENT = Self(20)
    comptime INVALID_INDEX = Self(21)
    comptime CLIP_NOT_REPRESENTABLE = Self(22)
    comptime TEMP_FILE_ERROR = Self(23)
    comptime INVALID_STRIDE = Self(24)
    comptime FONT_TYPE_MISMATCH = Self(25)
    comptime USER_FONT_IMMUTABLE = Self(26)
    comptime USER_FONT_ERROR = Self(27)
    comptime NEGATIVE_COUNT = Self(28)
    comptime INVALID_CLUSTERS = Self(29)
    comptime INVALID_SLANT = Self(30)
    comptime INVALID_WEIGHT = Self(31)
    comptime INVALID_SIZE = Self(32)
    comptime USER_FONT_NOT_IMPLEMENTED = Self(33)
    comptime DEVICE_TYPE_MISMATCH = Self(34)
    comptime DEVICE_ERROR = Self(35)
    comptime INVALID_MESH_CONSTRUCTION = Self(36)
    comptime DEVICE_FINISHED = Self(37)
    comptime JBIG2_GLOBAL_MISSING = Self(38)
    comptime PNG_ERROR = Self(39)
    comptime FREETYPE_ERROR = Self(40)
    comptime WIN32_GDI_ERROR = Self(41)
    comptime TAG_ERROR = Self(42)
    comptime LAST_STATUS = Self(43)

    @staticmethod
    def _from_ffi(value: bindings.cairo_status_t) -> Self:
        return Self(Int(value.value))

    def _to_ffi(self) -> bindings.cairo_status_t:
        return bindings.cairo_status_t(c_uint(self._value))


@fieldwise_init
struct Format(Copyable, ImplicitlyCopyable, Movable, RegisterPassable):
    """Pixel formats used by Cairo image surfaces."""

    var _value: Int

    comptime ARGB32 = Self(0)
    comptime RGB24 = Self(1)
    comptime A8 = Self(2)
    comptime A1 = Self(3)
    comptime RGB16_565 = Self(4)
    comptime RGB30 = Self(5)

    @staticmethod
    def _from_ffi(value: bindings.cairo_format_t) -> Self:
        return Self(Int(value.value))

    def _to_ffi(self) -> bindings.cairo_format_t:
        return bindings.cairo_format_t(c_int(self._value))


@fieldwise_init
struct Operator(Copyable, ImplicitlyCopyable, Movable, RegisterPassable):
    """Compositing operators used for drawing."""

    var _value: Int

    comptime SOURCE = Self(1)
    comptime OVER = Self(2)
    comptime ADD = Self(12)
    comptime MULTIPLY = Self(14)
    comptime SCREEN = Self(15)

    @staticmethod
    def _from_ffi(value: bindings.cairo_operator_t) -> Self:
        return Self(Int(value.value))

    def _to_ffi(self) -> bindings.cairo_operator_t:
        return bindings.cairo_operator_t(c_uint(self._value))


@fieldwise_init
struct Antialias(Copyable, ImplicitlyCopyable, Movable, RegisterPassable):
    """Antialiasing modes for rasterization."""

    var _value: Int

    comptime DEFAULT = Self(0)
    comptime NONE = Self(1)
    comptime GRAY = Self(2)
    comptime BEST = Self(6)

    @staticmethod
    def _from_ffi(value: bindings.cairo_antialias_t) -> Self:
        return Self(Int(value.value))

    def _to_ffi(self) -> bindings.cairo_antialias_t:
        return bindings.cairo_antialias_t(c_uint(self._value))


@fieldwise_init
struct LineCap(Copyable, ImplicitlyCopyable, Movable, RegisterPassable):
    """Stroke line-cap styles."""

    var _value: Int

    comptime BUTT = Self(0)
    comptime ROUND = Self(1)
    comptime SQUARE = Self(2)

    @staticmethod
    def _from_ffi(value: bindings.cairo_line_cap_t) -> Self:
        return Self(Int(value.value))

    def _to_ffi(self) -> bindings.cairo_line_cap_t:
        return bindings.cairo_line_cap_t(c_uint(self._value))


@fieldwise_init
struct LineJoin(Copyable, ImplicitlyCopyable, Movable, RegisterPassable):
    """Stroke line-join styles."""

    var _value: Int

    comptime MITER = Self(0)
    comptime ROUND = Self(1)
    comptime BEVEL = Self(2)

    @staticmethod
    def _from_ffi(value: bindings.cairo_line_join_t) -> Self:
        return Self(Int(value.value))

    def _to_ffi(self) -> bindings.cairo_line_join_t:
        return bindings.cairo_line_join_t(c_uint(self._value))


@fieldwise_init
struct FillRule(Copyable, ImplicitlyCopyable, Movable, RegisterPassable):
    """Rules for determining filled interior regions."""

    var _value: Int

    comptime WINDING = Self(0)
    comptime EVEN_ODD = Self(1)

    @staticmethod
    def _from_ffi(value: bindings.cairo_fill_rule_t) -> Self:
        return Self(Int(value.value))

    def _to_ffi(self) -> bindings.cairo_fill_rule_t:
        return bindings.cairo_fill_rule_t(c_uint(self._value))


@fieldwise_init
struct Content(Copyable, ImplicitlyCopyable, Movable, RegisterPassable):
    """Surface content types (color and/or alpha)."""

    var _value: Int

    comptime COLOR = Self(4096)
    comptime ALPHA = Self(8192)
    comptime COLOR_ALPHA = Self(12288)

    @staticmethod
    def _from_ffi(value: bindings.cairo_content_t) -> Self:
        return Self(Int(value.value))

    def _to_ffi(self) -> bindings.cairo_content_t:
        return bindings.cairo_content_t(c_uint(self._value))


@fieldwise_init
struct PatternType(Copyable, ImplicitlyCopyable, Movable, RegisterPassable):
    """Kinds of Cairo source patterns."""

    var _value: Int

    comptime SOLID = Self(0)
    comptime SURFACE = Self(1)
    comptime LINEAR = Self(2)
    comptime RADIAL = Self(3)
    comptime MESH = Self(4)
    comptime RASTER_SOURCE = Self(5)

    @staticmethod
    def _from_ffi(value: bindings.cairo_pattern_type_t) -> Self:
        return Self(Int(value.value))

    def _to_ffi(self) -> bindings.cairo_pattern_type_t:
        return bindings.cairo_pattern_type_t(c_uint(self._value))


@fieldwise_init
struct FontSlant(Copyable, ImplicitlyCopyable, Movable, RegisterPassable):
    """Font slant styles for toy text API."""

    var _value: Int

    comptime NORMAL = Self(0)
    comptime ITALIC = Self(1)
    comptime OBLIQUE = Self(2)

    @staticmethod
    def _from_ffi(value: bindings.cairo_font_slant_t) -> Self:
        return Self(Int(value.value))

    def _to_ffi(self) -> bindings.cairo_font_slant_t:
        return bindings.cairo_font_slant_t(c_uint(self._value))


@fieldwise_init
struct FontWeight(Copyable, ImplicitlyCopyable, Movable, RegisterPassable):
    """Font weight styles for toy text API."""

    var _value: Int

    comptime NORMAL = Self(0)
    comptime BOLD = Self(1)

    @staticmethod
    def _from_ffi(value: bindings.cairo_font_weight_t) -> Self:
        return Self(Int(value.value))

    def _to_ffi(self) -> bindings.cairo_font_weight_t:
        return bindings.cairo_font_weight_t(c_uint(self._value))


@fieldwise_init
struct Extend(Copyable, ImplicitlyCopyable, Movable, RegisterPassable):
    """Out-of-bounds extension behavior for patterns."""

    var _value: Int

    comptime NONE = Self(0)
    comptime REPEAT = Self(1)
    comptime REFLECT = Self(2)
    comptime PAD = Self(3)

    @staticmethod
    def _from_ffi(value: bindings.cairo_extend_t) -> Self:
        return Self(Int(value.value))

    def _to_ffi(self) -> bindings.cairo_extend_t:
        return bindings.cairo_extend_t(c_uint(self._value))


@fieldwise_init
struct Filter(Copyable, ImplicitlyCopyable, Movable, RegisterPassable):
    """Sampling filters applied when patterns are transformed."""

    var _value: Int

    comptime FAST = Self(0)
    comptime GOOD = Self(1)
    comptime BEST = Self(2)
    comptime NEAREST = Self(3)
    comptime BILINEAR = Self(4)

    @staticmethod
    def _from_ffi(value: bindings.cairo_filter_t) -> Self:
        return Self(Int(value.value))

    def _to_ffi(self) -> bindings.cairo_filter_t:
        return bindings.cairo_filter_t(c_uint(self._value))


@fieldwise_init
struct SubpixelOrder(Copyable, ImplicitlyCopyable, Movable, RegisterPassable):
    var _value: Int
    comptime DEFAULT = Self(0)
    comptime RGB = Self(1)
    comptime BGR = Self(2)
    comptime VRGB = Self(3)
    comptime VBGR = Self(4)

    @staticmethod
    def _from_ffi(value: bindings.cairo_subpixel_order_t) -> Self:
        return Self(Int(value.value))

    def _to_ffi(self) -> bindings.cairo_subpixel_order_t:
        return bindings.cairo_subpixel_order_t(c_uint(self._value))


@fieldwise_init
struct HintStyle(Copyable, ImplicitlyCopyable, Movable, RegisterPassable):
    var _value: Int
    comptime DEFAULT = Self(0)
    comptime NONE = Self(1)
    comptime SLIGHT = Self(2)
    comptime MEDIUM = Self(3)
    comptime FULL = Self(4)

    @staticmethod
    def _from_ffi(value: bindings.cairo_hint_style_t) -> Self:
        return Self(Int(value.value))

    def _to_ffi(self) -> bindings.cairo_hint_style_t:
        return bindings.cairo_hint_style_t(c_uint(self._value))


@fieldwise_init
struct HintMetrics(Copyable, ImplicitlyCopyable, Movable, RegisterPassable):
    var _value: Int
    comptime DEFAULT = Self(0)
    comptime OFF = Self(1)
    comptime ON = Self(2)

    @staticmethod
    def _from_ffi(value: bindings.cairo_hint_metrics_t) -> Self:
        return Self(Int(value.value))

    def _to_ffi(self) -> bindings.cairo_hint_metrics_t:
        return bindings.cairo_hint_metrics_t(c_uint(self._value))


@fieldwise_init
struct PathDataType(Copyable, ImplicitlyCopyable, Movable, RegisterPassable):
    var _value: Int
    comptime MOVE_TO = Self(0)
    comptime LINE_TO = Self(1)
    comptime CURVE_TO = Self(2)
    comptime CLOSE_PATH = Self(3)

    @staticmethod
    def _from_ffi(value: bindings.cairo_path_data_type_t) -> Self:
        return Self(Int(value.value))

    def _to_ffi(self) -> bindings.cairo_path_data_type_t:
        return bindings.cairo_path_data_type_t(c_uint(self._value))


@fieldwise_init
struct RegionOverlap(Copyable, ImplicitlyCopyable, Movable, RegisterPassable):
    var _value: Int
    comptime IN = Self(0)
    comptime OUT = Self(1)
    comptime PART = Self(2)

    @staticmethod
    def _from_ffi(value: bindings.cairo_region_overlap_t) -> Self:
        return Self(Int(value.value))

    def _to_ffi(self) -> bindings.cairo_region_overlap_t:
        return bindings.cairo_region_overlap_t(c_uint(self._value))


@fieldwise_init
struct TextClusterFlags(
    Copyable, ImplicitlyCopyable, Movable, RegisterPassable
):
    var _value: Int
    comptime NONE = Self(0)
    comptime BACKWARD = Self(1)

    @staticmethod
    def _from_ffi(value: bindings.cairo_text_cluster_flags_t) -> Self:
        return Self(Int(value.value))

    def _to_ffi(self) -> bindings.cairo_text_cluster_flags_t:
        return bindings.cairo_text_cluster_flags_t(c_uint(self._value))


@fieldwise_init
struct SurfaceObserverMode(
    Copyable, ImplicitlyCopyable, Movable, RegisterPassable
):
    var _value: Int
    comptime NORMAL = Self(0)
    comptime RECORD_OPERATIONS = Self(1)

    @staticmethod
    def _from_ffi(value: bindings.cairo_surface_observer_mode_t) -> Self:
        return Self(Int(value.value))

    def _to_ffi(self) -> bindings.cairo_surface_observer_mode_t:
        return bindings.cairo_surface_observer_mode_t(c_uint(self._value))


@fieldwise_init
struct PSLevel(Copyable, ImplicitlyCopyable, Movable, RegisterPassable):
    var _value: Int
    comptime LEVEL_2 = Self(0)
    comptime LEVEL_3 = Self(1)

    @staticmethod
    def _from_ffi(value: bindings.cairo_ps_level_t) -> Self:
        return Self(Int(value.value))

    def _to_ffi(self) -> bindings.cairo_ps_level_t:
        return bindings.cairo_ps_level_t(c_uint(self._value))


@fieldwise_init
struct PDFVersion(Copyable, ImplicitlyCopyable, Movable, RegisterPassable):
    var _value: Int
    comptime V1_4 = Self(0)
    comptime V1_5 = Self(1)
    comptime V1_6 = Self(2)
    comptime V1_7 = Self(3)

    @staticmethod
    def _from_ffi(value: bindings.cairo_pdf_version_t) -> Self:
        return Self(Int(value.value))

    def _to_ffi(self) -> bindings.cairo_pdf_version_t:
        return bindings.cairo_pdf_version_t(c_uint(self._value))


@fieldwise_init
struct SVGVersion(Copyable, ImplicitlyCopyable, Movable, RegisterPassable):
    var _value: Int
    comptime V1_1 = Self(0)
    comptime V1_2 = Self(1)

    @staticmethod
    def _from_ffi(value: bindings.cairo_svg_version_t) -> Self:
        return Self(Int(value.value))

    def _to_ffi(self) -> bindings.cairo_svg_version_t:
        return bindings.cairo_svg_version_t(c_uint(self._value))


@fieldwise_init
struct ScriptMode(Copyable, ImplicitlyCopyable, Movable, RegisterPassable):
    var _value: Int
    comptime ASCII = Self(0)
    comptime BINARY = Self(1)


@fieldwise_init
struct PDFOutlineFlags(Copyable, ImplicitlyCopyable, Movable, RegisterPassable):
    var _value: Int
    comptime OPEN = Self(1)
    comptime BOLD = Self(2)
    comptime ITALIC = Self(4)

    @staticmethod
    def _from_ffi(value: bindings.cairo_pdf_outline_flags_t) -> Self:
        return Self(Int(value.value))

    def _to_ffi(self) -> bindings.cairo_pdf_outline_flags_t:
        return bindings.cairo_pdf_outline_flags_t(value=c_uint(self._value))


@fieldwise_init
struct SVGUnit(Copyable, ImplicitlyCopyable, Movable, RegisterPassable):
    var _value: Int
    comptime USER = Self(0)
    comptime EM = Self(1)
    comptime EX = Self(2)
    comptime PX = Self(3)
    comptime IN = Self(4)
    comptime CM = Self(5)
    comptime MM = Self(6)
    comptime PT = Self(7)
    comptime PC = Self(8)
    comptime PERCENT = Self(9)

    @staticmethod
    def _from_ffi(value: bindings.cairo_svg_unit_t) -> Self:
        return Self(Int(value.value))

    def _to_ffi(self) -> bindings.cairo_svg_unit_t:
        return bindings.cairo_svg_unit_t(c_uint(self._value))


@fieldwise_init
struct PDFMetadata(Copyable, ImplicitlyCopyable, Movable, RegisterPassable):
    var _value: Int
    comptime TITLE = Self(0)
    comptime AUTHOR = Self(1)
    comptime SUBJECT = Self(2)
    comptime KEYWORDS = Self(3)
    comptime CREATOR = Self(4)
    comptime CREATE_DATE = Self(5)
    comptime MOD_DATE = Self(6)

    @staticmethod
    def _from_ffi(value: bindings.cairo_pdf_metadata_t) -> Self:
        return Self(Int(value.value))

    def _to_ffi(self) -> bindings.cairo_pdf_metadata_t:
        return bindings.cairo_pdf_metadata_t(c_uint(self._value))


@fieldwise_init
struct ColorMode(Copyable, ImplicitlyCopyable, Movable, RegisterPassable):
    var _value: Int
    comptime DEFAULT = Self(0)
    comptime RGB = Self(1)
    comptime GRAY = Self(2)

    @staticmethod
    def _from_ffi(value: bindings.cairo_color_mode_t) -> Self:
        return Self(Int(value.value))

    def _to_ffi(self) -> bindings.cairo_color_mode_t:
        return bindings.cairo_color_mode_t(c_uint(self._value))


@fieldwise_init
struct Dither(Copyable, ImplicitlyCopyable, Movable, RegisterPassable):
    var _value: Int
    comptime DEFAULT = Self(0)
    comptime NONE = Self(1)
    comptime FAST = Self(2)
    comptime GOOD = Self(3)
    comptime BEST = Self(4)

    @staticmethod
    def _from_ffi(value: bindings.cairo_dither_t) -> Self:
        return Self(Int(value.value))

    def _to_ffi(self) -> bindings.cairo_dither_t:
        return bindings.cairo_dither_t(c_uint(self._value))
