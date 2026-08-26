"""Glyph outlines and metrics, backed by the native TrueType parser
(`ttf.mojo`) -- job 2 of the three text-rendering jobs (font discovery
/ glyph resolution & metrics / rasterization). `font_discovery.mojo`
resolves a family/slant/weight to a file; `ttf.mojo` parses that
file's binary tables directly. This module is the thin adapter
between the two: it exposes the `LineMetrics`/`GlyphMetrics`/
`face_line_metrics`/`has_glyph`/`glyph_metrics`/`glyph_path` surface
`render.mojo` calls, implemented against `ttf.mojo`'s `TTFFace` --
no FFI, no C struct layouts, no linked library in this module at all.

No hinting: `ttf.mojo` implements no hinting bytecode interpreter, a
deliberate scope decision documented there. Every glyph renders
through `fill_path_aa`'s supersampled coverage AA regardless, which is
what keeps unhinted outlines correct at the sizes a chart uses.

Locked-in font values: DejaVu Sans reads
`units_per_EM`/`num_glyphs`/`ascender`/`descender` as
2048/6253/1901/-483, and capital "I" decomposes to 1 contour, 4
points, all on-curve -- both confirmed against `ttf.mojo`'s Python
oracle. Glyph metrics (advance/bearing/width/height) differ slightly
from what a hinting rasterizer such as FreeType reports for the same
glyph at the same size, since hinting rounds and this never does; see
tests/test_glyph_outline.mojo for the exact numbers.

TrueType outline space has y increasing upward, the
PDF/PostScript/font-design convention. `ttf.mojo`'s `outline_to_path`
applies the y-flip into this package's y-down raster space, so this
module doesn't repeat it.
"""

from canvas_mojo.path import Path
from canvas_mojo.text.font_discovery import resolve_font_file_for_char
from canvas_mojo.text.ttf import TTFFace, outline_to_path


struct LineMetrics(ImplicitlyCopyable, Movable):
    """This face's line metrics at its current size, in pixels.
    `ascender`/`descender` are signed, descender negative per `hhea`'s
    convention; `line_height` is the recommended baseline-to-baseline
    distance for stacked lines.
    """

    var ascender: Float64
    var descender: Float64
    var line_height: Float64

    def __init__(
        out self, ascender: Float64, descender: Float64, line_height: Float64
    ):
        self.ascender = ascender
        self.descender = descender
        self.line_height = line_height


def face_line_metrics(face: TTFFace) raises -> LineMetrics:
    """This face's line metrics at whatever pixel size
    `TTFFace.set_pixel_size` last set; raises if it was never called
    (see `TTFFace.scale`).
    """
    var scale = face.scale()
    var ascender = Float64(face.ascender) * scale
    var descender = Float64(face.descender) * scale
    var line_height = (
        Float64(face.ascender - face.descender + face.line_gap) * scale
    )
    return LineMetrics(ascender, descender, line_height)


struct GlyphMetrics(ImplicitlyCopyable, Movable):
    """One glyph's layout-relevant measurements, in pixels, at whatever
    size was last set.
    """

    var advance: Float64
    var bearing_x: Float64
    var bearing_y: Float64
    var width: Float64
    var height: Float64

    def __init__(
        out self,
        advance: Float64,
        bearing_x: Float64,
        bearing_y: Float64,
        width: Float64,
        height: Float64,
    ):
        self.advance = advance
        self.bearing_x = bearing_x
        self.bearing_y = bearing_y
        self.width = width
        self.height = height


def has_glyph(mut face: TTFFace, codepoint: Int) raises -> Bool:
    """Whether `face` has a real glyph for `codepoint`. Glyph index 0
    is TrueType's ".notdef", what `cmap` returns for any codepoint the
    font doesn't map. A plain `cmap` lookup with no outline decode, so
    it's cheaper than `glyph_metrics`/`glyph_path` for
    `render.mojo`'s fallback logic, which only needs to know whether to
    keep this face or resolve another.
    """
    return face.glyph_index_for_codepoint(codepoint) != 0


def glyph_metrics(mut face: TTFFace, codepoint: Int) raises -> GlyphMetrics:
    """This character's advance/bearing/size, in pixels."""
    var scale = face.scale()
    var glyph_index = face.glyph_index_for_codepoint(codepoint)
    var advance = Float64(face.advance_width(glyph_index)) * scale

    var outline = face.glyph_outline_shared(glyph_index)
    var bbox = outline[].bounding_box()
    var x_min = bbox[0]
    var y_min = bbox[1]
    var x_max = bbox[2]
    var y_max = bbox[3]

    # bearing_x/bearing_y/width/height follow FreeType's
    # FT_Glyph_Metrics convention, which this module's callers and
    # tests are written against: bearing_x is the ink bounding box's
    # left edge, bearing_y its top edge (baseline-relative, y-up
    # font-design sign), width/height its extent -- all from the
    # decoded outline's points rather than the `glyf` header's stored
    # bounding box (see `RawGlyphOutline.bounding_box`).
    return GlyphMetrics(
        advance,
        Float64(x_min) * scale,
        Float64(y_max) * scale,
        Float64(x_max - x_min) * scale,
        Float64(y_max - y_min) * scale,
    )


def glyph_path(
    mut face: TTFFace, codepoint: Int, pen_x: Float64, pen_y: Float64
) raises -> Path:
    """One character's outline as a `Path`, positioned so its local
    (0, 0) -- the glyph origin -- lands at (pen_x, pen_y) in pixel
    space. The caller advances the pen by
    `glyph_metrics(face, codepoint).advance` before the next character;
    this doesn't, matching Path's convention that the caller positions
    everything explicitly.

    A glyph with no outline (whitespace maps to a valid glyph index
    with zero contours) returns an empty Path rather than an error.
    """
    var scale = face.scale()
    var glyph_index = face.glyph_index_for_codepoint(codepoint)
    var outline = face.glyph_outline_shared(glyph_index)
    return outline_to_path(outline[], pen_x, pen_y, scale)
