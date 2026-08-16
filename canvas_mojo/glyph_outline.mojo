"""Glyph outlines and metrics via direct FreeType FFI -- job 2 of the
4-job breakdown (font discovery / glyph resolution & metrics / hinting
/ rasterization) for removing canvas_mojo/text.mojo's Cairo dependency.
`font_discovery.mojo` (job 1) resolves a family/slant/weight to a file;
`freetype_face.mojo` loads that file into an `FT_Face`. This module
reads a loaded `FT_Face`'s own glyph data directly -- no more Cairo
involved from here on: `glyph_path()` turns one glyph's outline into
this package's own `Path` (`canvas_mojo/path.mojo`), ready for
`fill_path_aa` (job 4, already built) to rasterize, with zero Cairo
round-trip (no scratch ARGB32 surface, no premultiply/unpremultiply,
none of the `unsafe_data_ptr()` boundary-garbage workaround
canvas_mojo/text.mojo's own docstring documents -- that whole category
of bug doesn't exist for a path filled directly onto `Canvas`).

Hinting (job 3) comes along for free at default `FT_Load_Glyph` flags
-- FreeType hints internally unless `FT_LOAD_NO_HINTING` is passed,
which this module never does. No separate hinting code needed here.

Struct layouts below (`FT_FaceRec`, `FT_GlyphSlotRec`, `FT_Outline`,
`FT_Glyph_Metrics`, `FT_SizeRec`/`FT_Size_Metrics`, `FT_BBox`,
`FT_Generic`, `FT_Bitmap`, `FT_Vector`) are transcribed field-for-field
from FreeType 2.13.2's own public headers (`freetype.h`/`ftimage.h`),
not guessed at or reconstructed from documentation prose -- direct
struct access is FreeType's own normal usage pattern in C (there's no
accessor-function API for glyph outline data), so this is the
standard way to use this library, not a workaround. Fields this module
never reads (`driver`, `memory`, `stream`, internal bookkeping, ...)
are omitted from the end of each struct -- Mojo/C struct layout only
depends on the fields that exist and their order, not on a struct
being "complete", so a same-prefix partial struct reads its declared
fields correctly as long as nothing after them is touched.

Verified against real values before trusting any of this, not assumed
correct because it compiles: loading DejaVu Sans and reading
`units_per_EM`/`num_glyphs`/`ascender`/`descender` gave 2048/6253/
1901/-483 -- matching this exact font's well-known real metrics.
Loading capital "I" gave exactly 1 contour, 4 points, all on-curve
(tag & 3 == 1) -- correct for a glyph that's just a rectangle, no
curves. See canvas_mojo/tests/test_glyph_outline.mojo for the
locked-in versions of these same checks.

Outline decomposition (`_decompose_contour`) is a direct translation
of FreeType's own `FT_Outline_Decompose` (`src/base/ftoutln.c`, FTL-
licensed, same permissive category as the direct-FFI approach
font_discovery.mojo's own docstring already justifies) -- not
independently re-derived from memory, since the on-curve/off-curve/
implied-midpoint interpretation of a TrueType-style outline has
several easy-to-get-subtly-wrong edge cases (a contour starting on an
off-curve point, a contour with zero on-curve points at all, running
out of points mid-curve) that FreeType's own reference implementation
already gets right. Translated control-flow (`goto Close` in the C
original) into an explicit `closed` flag instead, since Mojo has no
goto -- same resulting behavior, confirmed by the same "I" and a
curved glyph ("O") both decomposing into a visually correct shape
(see the test file).

FreeType's own outline coordinate space has y increasing upward (the
same PDF/PostScript/font-design convention geometry.mojo's own
docstring already describes for data space generally); every emitted
Path coordinate negates y relative to a caller-supplied pen position,
converting to this package's own y-down raster convention -- the same
flip Transform2D's own negative `scale_y` performs for data-to-pixel
mapping, applied here for font-design-space-to-pixel mapping instead.
"""

from std.ffi import c_char, c_int, c_long, c_short, c_uint, c_ushort
from std.memory import MutOpaquePointer

from canvas_mojo.freetype_face import FreeTypeFace, _open_freetype_library
from canvas_mojo.path import Path


@fieldwise_init
struct FT_Generic(Copyable, ImplicitlyCopyable, Movable):
    var data: MutOpaquePointer[MutUntrackedOrigin]
    var finalizer: MutOpaquePointer[MutUntrackedOrigin]


@fieldwise_init
struct FT_BBox(Copyable, ImplicitlyCopyable, Movable):
    var xMin: c_long
    var yMin: c_long
    var xMax: c_long
    var yMax: c_long


@fieldwise_init
struct FT_Vector(Copyable, ImplicitlyCopyable, Movable):
    var x: c_long
    var y: c_long


@fieldwise_init
struct FT_Glyph_Metrics(Copyable, ImplicitlyCopyable, Movable):
    var width: c_long
    var height: c_long
    var horiBearingX: c_long
    var horiBearingY: c_long
    var horiAdvance: c_long
    var vertBearingX: c_long
    var vertBearingY: c_long
    var vertAdvance: c_long


@fieldwise_init
struct FT_Bitmap(Copyable, ImplicitlyCopyable, Movable):
    var rows: c_uint
    var width: c_uint
    var pitch: c_int
    var buffer: MutOpaquePointer[MutUntrackedOrigin]
    var num_grays: c_ushort
    var pixel_mode: UInt8
    var palette_mode: UInt8
    var palette: MutOpaquePointer[MutUntrackedOrigin]


@fieldwise_init
struct FT_Outline(Copyable, ImplicitlyCopyable, Movable):
    var n_contours: c_short
    var n_points: c_short
    var points: Pointer[FT_Vector, MutUntrackedOrigin]
    var tags: Pointer[Int8, MutUntrackedOrigin]
    var contours: Pointer[c_short, MutUntrackedOrigin]
    var flags: c_int


@fieldwise_init
struct FT_GlyphSlotRec(Copyable, ImplicitlyCopyable, Movable):
    var library: MutOpaquePointer[MutUntrackedOrigin]
    var face: MutOpaquePointer[MutUntrackedOrigin]
    var next: MutOpaquePointer[MutUntrackedOrigin]
    var glyph_index: c_uint
    var generic: FT_Generic
    var metrics: FT_Glyph_Metrics
    var linearHoriAdvance: c_long
    var linearVertAdvance: c_long
    var advance: FT_Vector
    var format: c_int
    var bitmap: FT_Bitmap
    var bitmap_left: c_int
    var bitmap_top: c_int
    var outline: FT_Outline


@fieldwise_init
struct FT_Size_Metrics(Copyable, ImplicitlyCopyable, Movable):
    var x_ppem: c_ushort
    var y_ppem: c_ushort
    var x_scale: c_long
    var y_scale: c_long
    var ascender: c_long
    var descender: c_long
    var height: c_long
    var max_advance: c_long


@fieldwise_init
struct FT_SizeRec(Copyable, ImplicitlyCopyable, Movable):
    var face: MutOpaquePointer[MutUntrackedOrigin]
    var generic: FT_Generic
    var metrics: FT_Size_Metrics


@fieldwise_init
struct _FT_FaceRec_full(Copyable, ImplicitlyCopyable, Movable):
    """Same struct `freetype_face.mojo`'s own opaque `_FT_FaceRec`
    marks as a pointer target, but with its real field prefix declared
    -- this module needs to actually read `glyph`/`size`/`units_per_EM`,
    not just pass the pointer through to Cairo the way `freetype_face.
    mojo` alone needs to.
    """

    var num_faces: c_long
    var face_index: c_long
    var face_flags: c_long
    var style_flags: c_long
    var num_glyphs: c_long
    var family_name: Pointer[c_char, MutUntrackedOrigin]
    var style_name: Pointer[c_char, MutUntrackedOrigin]
    var num_fixed_sizes: c_int
    var available_sizes: MutOpaquePointer[MutUntrackedOrigin]
    var num_charmaps: c_int
    var charmaps: MutOpaquePointer[MutUntrackedOrigin]
    var generic: FT_Generic
    var bbox: FT_BBox
    var units_per_EM: c_ushort
    var ascender: c_short
    var descender: c_short
    var height: c_short
    var max_advance_width: c_short
    var max_advance_height: c_short
    var underline_position: c_short
    var underline_thickness: c_short
    var glyph: Pointer[FT_GlyphSlotRec, MutUntrackedOrigin]
    var size: Pointer[FT_SizeRec, MutUntrackedOrigin]
    var charmap: MutOpaquePointer[MutUntrackedOrigin]


def _as_full(face: FreeTypeFace) -> Pointer[_FT_FaceRec_full, MutUntrackedOrigin]:
    """Reinterpret freetype_face.mojo's opaque `_FT_FaceRec` pointer as
    this module's own fully-fielded `_FT_FaceRec_full` -- both name the
    exact same underlying `FT_Face`; the opaque version just doesn't
    declare fields this module needs and that one doesn't.
    """
    return face.unsafe_raw_face_ptr().unsafe_bitcast[_FT_FaceRec_full]()


struct LineMetrics(ImplicitlyCopyable, Movable):
    """This face's own current-size line metrics, in pixels -- the
    native equivalent of Cairo's `font_extents().height`. `ascender`/
    `descender` are signed (descender negative, matching FreeType's
    own convention); `line_height` is the recommended baseline-to-
    baseline distance for stacked lines.
    """

    var ascender: Float64
    var descender: Float64
    var line_height: Float64

    def __init__(out self, ascender: Float64, descender: Float64, line_height: Float64):
        self.ascender = ascender
        self.descender = descender
        self.line_height = line_height


def _require_active_size(full: Pointer[_FT_FaceRec_full, MutUntrackedOrigin]) raises -> FT_Size_Metrics:
    """Confirmed necessary via probe, not assumed: reading metrics
    before `FreeTypeFace.set_pixel_size` is ever called doesn't crash
    or raise on its own -- it silently returns zeroed line metrics and
    a wrong-but-plausible-looking small glyph size instead (whatever
    FreeType's own unset-size default happens to be), a real "silently
    disagrees" trap this checks for explicitly rather than leaving
    every caller to discover it independently. `x_ppem == 0` is the
    signal: no real caller ever legitimately wants a zero-pixel size.
    """
    var metrics = full[].size[].metrics
    if Int(metrics.x_ppem) == 0:
        raise Error(
            "glyph_outline: no active pixel size on this FreeTypeFace -- call"
            " set_pixel_size() before measuring or loading glyphs"
        )
    return metrics


def face_line_metrics(face: FreeTypeFace) raises -> LineMetrics:
    """This face's line metrics at whatever pixel size
    `FreeTypeFace.set_pixel_size` last set -- raises if that was never
    called (see `_require_active_size`'s own docstring for why this
    isn't just trusting FreeType's own unset-size default).
    """
    var metrics = _require_active_size(_as_full(face))
    return LineMetrics(
        Float64(Int(metrics.ascender)) / 64.0,
        Float64(Int(metrics.descender)) / 64.0,
        Float64(Int(metrics.height)) / 64.0,
    )


struct GlyphMetrics(ImplicitlyCopyable, Movable):
    """One glyph's own layout-relevant measurements, in pixels, at
    whatever size was last set -- the native equivalent of a single
    character's contribution to Cairo's `text_extents()`.
    """

    var advance: Float64
    var bearing_x: Float64
    var bearing_y: Float64
    var width: Float64
    var height: Float64

    def __init__(
        out self, advance: Float64, bearing_x: Float64, bearing_y: Float64, width: Float64, height: Float64
    ):
        self.advance = advance
        self.bearing_x = bearing_x
        self.bearing_y = bearing_y
        self.width = width
        self.height = height


def has_glyph(mut face: FreeTypeFace, codepoint: Int) raises -> Bool:
    """Whether `face` has a real glyph for `codepoint` -- glyph index
    0 is FreeType's own universal ".notdef" placeholder (confirmed
    directly, not assumed: 'A' against DejaVu Sans returns a real
    index, a CJK character against the same face returns exactly 0).
    Checked via `FT_Get_Char_Index` alone, without `FT_Load_Glyph` --
    cheaper than `glyph_metrics`/`glyph_path` for a caller (`text.mojo`'s
    own font-fallback logic) that just needs to know whether to keep
    using this face or resolve a different one for this character,
    not load the glyph itself.
    """
    var handle = _open_freetype_library()
    var full = _as_full(face)
    var glyph_index = handle.call[
        "FT_Get_Char_Index", c_uint, Pointer[_FT_FaceRec_full, MutUntrackedOrigin], c_long
    ](full, c_long(codepoint))
    return Int(glyph_index) != 0


def _load_glyph(mut face: FreeTypeFace, codepoint: Int) raises -> Pointer[FT_GlyphSlotRec, MutUntrackedOrigin]:
    """`FT_Get_Char_Index` (Unicode codepoint -> glyph index, via this
    face's own cmap, set to Unicode by FT_New_Face automatically when
    the font has one) then `FT_Load_Glyph` (default flags -- hinted,
    scaled to the active pixel size). Returns the populated glyph
    slot; a missing character maps to glyph index 0 (".notdef"),
    FreeType's own documented behavior, not an error this function
    raises for.
    """
    var handle = _open_freetype_library()
    var full = _as_full(face)
    _ = _require_active_size(full)

    var glyph_index = handle.call[
        "FT_Get_Char_Index", c_uint, Pointer[_FT_FaceRec_full, MutUntrackedOrigin], c_long
    ](full, c_long(codepoint))

    var load_err = handle.call[
        "FT_Load_Glyph", c_int, Pointer[_FT_FaceRec_full, MutUntrackedOrigin], c_uint, c_int
    ](full, glyph_index, c_int(0))
    if Int(load_err) != 0:
        raise Error(String("FT_Load_Glyph failed for codepoint ", codepoint, " with error code ", Int(load_err)))

    return full[].glyph


def glyph_metrics(mut face: FreeTypeFace, codepoint: Int) raises -> GlyphMetrics:
    """This one character's own advance/bearing/size, in pixels."""
    var slot = _load_glyph(face, codepoint)
    var m = slot[].metrics
    return GlyphMetrics(
        Float64(Int(slot[].advance.x)) / 64.0,
        Float64(Int(m.horiBearingX)) / 64.0,
        Float64(Int(m.horiBearingY)) / 64.0,
        Float64(Int(m.width)) / 64.0,
        Float64(Int(m.height)) / 64.0,
    )


def _px(pen_x: Float64, v: c_long) -> Float64:
    return pen_x + Float64(Int(v)) / 64.0


def _py(pen_y: Float64, v: c_long) -> Float64:
    # Font-design space has y increasing upward; canvas pixel space
    # has y increasing downward -- see this module's own docstring.
    return pen_y - Float64(Int(v)) / 64.0


def _decompose_contour(
    outline: FT_Outline, first: Int, last: Int, mut path: Path, pen_x: Float64, pen_y: Float64
) raises:
    """One contour of `_Outline_Decompose`'s own algorithm (see this
    module's own docstring) -- appends move_to/line_to/quad_curve_to/
    cubic_curve_to/close calls for contour points [first, last]
    (inclusive) to `path`, in pixel space relative to (pen_x, pen_y).
    """
    if last < first:
        return

    var v_start_raw = outline.points[unsafe_offset=first]
    var v_last_raw = outline.points[unsafe_offset=last]

    var limit = last
    var point_idx = first
    var start_tag = Int(outline.tags[unsafe_offset=first]) & 3

    var v_start_x: c_long
    var v_start_y: c_long

    if start_tag == 0:  # FT_CURVE_TAG_CONIC -- contour starts on a control point
        var last_tag = Int(outline.tags[unsafe_offset=last]) & 3
        if last_tag == 1:  # FT_CURVE_TAG_ON
            v_start_x = v_last_raw.x
            v_start_y = v_last_raw.y
            limit -= 1
        else:
            v_start_x = (v_start_raw.x + v_last_raw.x) // 2
            v_start_y = (v_start_raw.y + v_last_raw.y) // 2
        point_idx -= 1
    else:
        v_start_x = v_start_raw.x
        v_start_y = v_start_raw.y

    path.move_to(_px(pen_x, v_start_x), _py(pen_y, v_start_y))

    var v_control_x = v_start_x
    var v_control_y = v_start_y
    var closed = False

    while point_idx < limit and not closed:
        point_idx += 1
        var p = outline.points[unsafe_offset=point_idx]
        var tag = Int(outline.tags[unsafe_offset=point_idx]) & 3

        if tag == 1:  # ON
            path.line_to(_px(pen_x, p.x), _py(pen_y, p.y))
        elif tag == 0:  # CONIC
            v_control_x = p.x
            v_control_y = p.y
            var emitted = False
            while point_idx < limit:
                point_idx += 1
                var p2 = outline.points[unsafe_offset=point_idx]
                var tag2 = Int(outline.tags[unsafe_offset=point_idx]) & 3
                if tag2 == 1:  # ON -- ends this conic run
                    path.quad_curve_to(_px(pen_x, v_control_x), _py(pen_y, v_control_y), _px(pen_x, p2.x), _py(pen_y, p2.y))
                    emitted = True
                    break
                # Two consecutive conic points: the implied on-curve
                # point is their midpoint (the classic TrueType
                # quadratic-spline encoding trick).
                var mid_x = (v_control_x + p2.x) // 2
                var mid_y = (v_control_y + p2.y) // 2
                path.quad_curve_to(_px(pen_x, v_control_x), _py(pen_y, v_control_y), _px(pen_x, mid_x), _py(pen_y, mid_y))
                v_control_x = p2.x
                v_control_y = p2.y
            if not emitted:
                # Ran out of points still holding a pending control
                # point -- close back to v_start via one final conic
                # segment (FT's own "goto Close" from inside Do_Conic).
                path.quad_curve_to(_px(pen_x, v_control_x), _py(pen_y, v_control_y), _px(pen_x, v_start_x), _py(pen_y, v_start_y))
                closed = True
        else:  # CUBIC -- always a pair of consecutive off-curve points
            var c1x = p.x
            var c1y = p.y
            point_idx += 1
            var p_c2 = outline.points[unsafe_offset=point_idx]
            var c2x = p_c2.x
            var c2y = p_c2.y
            if point_idx < limit:
                point_idx += 1
                var p3 = outline.points[unsafe_offset=point_idx]
                path.cubic_curve_to(_px(pen_x, c1x), _py(pen_y, c1y), _px(pen_x, c2x), _py(pen_y, c2y), _px(pen_x, p3.x), _py(pen_y, p3.y))
            else:
                path.cubic_curve_to(_px(pen_x, c1x), _py(pen_y, c1y), _px(pen_x, c2x), _py(pen_y, c2y), _px(pen_x, v_start_x), _py(pen_y, v_start_y))
                closed = True

    if not closed:
        path.line_to(_px(pen_x, v_start_x), _py(pen_y, v_start_y))
    path.close()


def glyph_path(mut face: FreeTypeFace, codepoint: Int, pen_x: Float64, pen_y: Float64) raises -> Path:
    """One character's outline as a `Path`, positioned so its own
    local (0, 0) -- the glyph origin FreeType's outline coordinates
    are relative to -- lands at (pen_x, pen_y) in pixel space. Advance
    the pen by this same call's own `glyph_metrics(face, codepoint)
    .advance` before laying out the next character -- this function
    doesn't do that itself, matching Path's own "caller positions
    everything explicitly" convention (see path.mojo's docstring).

    A glyph with no outline at all (whitespace -- FT_Load_Glyph
    succeeds with n_contours == 0) returns an empty Path, the same
    "nothing to draw, not an error" convention draw_text's own no-op
    cases already use.
    """
    var slot = _load_glyph(face, codepoint)
    var outline = slot[].outline

    var path = Path()
    var last = -1
    for n in range(Int(outline.n_contours)):
        var first = last + 1
        last = Int(outline.contours[unsafe_offset=n])
        _decompose_contour(outline, first, last, path, pen_x, pen_y)
    return path^
