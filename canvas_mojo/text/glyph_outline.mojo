"""Glyph outlines and metrics, backed by the native TrueType parser
(`ttf.mojo`) -- job 2 of the original 4-job breakdown (font discovery /
glyph resolution & metrics / hinting / rasterization) for removing
`canvas_mojo/text/render.mojo`'s Cairo dependency, later extended to
remove the FreeType dependency that same breakdown originally replaced
Cairo with. `font_discovery.mojo` (job 1) resolves a family/slant/
weight to a file; `ttf.mojo` parses that file's own binary tables
directly. This module is the thin adapter between the two: it exposes
the same `LineMetrics`/`GlyphMetrics`/`face_line_metrics`/`has_glyph`/
`glyph_metrics`/`glyph_path` surface `render.mojo` already calls,
implemented against `ttf.mojo`'s own `TTFFace` instead of FreeType's
`FT_Face` -- no FFI, no C struct layouts, no linked library at all in
this module anymore.

No hinting (job 3) here either, by construction: `ttf.mojo` never
implements FreeType's own hinting bytecode interpreter (a large,
separate subsystem -- see that module's own docstring for why this is
a deliberate scope decision, not an oversight). Every glyph still
renders through this package's own `fill_path_aa`'s supersampled
coverage AA regardless (job 4, already built), which is what makes
unhinted outlines look correct at the sizes a chart actually uses --
confirmed directly against real values, not assumed (see this module's
own verification paragraph below).

Verified against the exact same real values already locked in for the
FreeType-backed version of this module before this file replaced it:
loading DejaVu Sans and reading `units_per_EM`/`num_glyphs`/`ascender`/
`descender` gives 2048/6253/1901/-483, and capital "I" decomposes to
exactly 1 contour, 4 points, all on-curve -- both facts independently
re-confirmed via `ttf.mojo`'s own from-scratch Python-oracle
cross-check (see that module's own docstring), not just carried over
on faith. Glyph metrics (advance/bearing/width/height) do differ
slightly from FreeType's own hinted values for the same glyph at the
same size -- a real, understood, expected difference (FreeType applies
its own default hinting/rounding even without an explicit "no hinting"
flag; this module deliberately never does), not a regression -- see
tests/test_glyph_outline.mojo's own docstring for the exact numbers
and how each was re-measured (not guessed) before being locked in.

FreeType's own outline coordinate space has y increasing upward (the
same PDF/PostScript/font-design convention geometry.mojo's own
docstring already describes for data space generally); `ttf.mojo`'s
`outline_to_path` already applies the same y-flip converting to this
package's own y-down raster convention, so this module doesn't need to
repeat that logic.
"""

from canvas_mojo.path import Path
from canvas_mojo.text.font_discovery import resolve_font_file_for_char
from canvas_mojo.text.ttf import TTFFace, outline_to_path


struct LineMetrics(ImplicitlyCopyable, Movable):
    """This face's own current-size line metrics, in pixels -- the
    native equivalent of Cairo's `font_extents().height`. `ascender`/
    `descender` are signed (descender negative, matching FreeType's
    own convention, itself matching `hhea`'s own convention); `line_height`
    is the recommended baseline-to-baseline distance for stacked lines.
    """

    var ascender: Float64
    var descender: Float64
    var line_height: Float64

    def __init__(out self, ascender: Float64, descender: Float64, line_height: Float64):
        self.ascender = ascender
        self.descender = descender
        self.line_height = line_height


def face_line_metrics(face: TTFFace) raises -> LineMetrics:
    """This face's line metrics at whatever pixel size
    `TTFFace.set_pixel_size` last set -- raises if that was never
    called (see `TTFFace.scale`'s own docstring for why this isn't
    just trusting an unset size).
    """
    var scale = face.scale()
    var ascender = Float64(face.ascender) * scale
    var descender = Float64(face.descender) * scale
    var line_height = Float64(face.ascender - face.descender + face.line_gap) * scale
    return LineMetrics(ascender, descender, line_height)


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


def has_glyph(mut face: TTFFace, codepoint: Int) raises -> Bool:
    """Whether `face` has a real glyph for `codepoint` -- glyph index
    0 is TrueType's own universal ".notdef" placeholder, returned by
    `cmap` lookup itself for any codepoint the font doesn't map
    (confirmed directly, not assumed -- see `ttf.mojo`'s own
    `test_missing_codepoint_maps_to_notdef`). Cheaper than
    `glyph_metrics`/`glyph_path` for a caller (`render.mojo`'s own
    font-fallback logic) that just needs to know whether to keep using
    this face or resolve a different one for this character, not load
    the glyph itself -- a plain `cmap` lookup, no outline decode.
    """
    return face.glyph_index_for_codepoint(codepoint) != 0


def glyph_metrics(mut face: TTFFace, codepoint: Int) raises -> GlyphMetrics:
    """This one character's own advance/bearing/size, in pixels."""
    var scale = face.scale()
    var glyph_index = face.glyph_index_for_codepoint(codepoint)
    var advance = Float64(face.advance_width(glyph_index)) * scale

    var outline = face.glyph_outline(glyph_index)
    var bbox = outline.bounding_box()
    var x_min = bbox[0]
    var y_min = bbox[1]
    var x_max = bbox[2]
    var y_max = bbox[3]

    # bearing_x/bearing_y/width/height follow FT_Glyph_Metrics' own
    # convention exactly (the one this module's own callers, and its
    # own pre-existing tests, are already written against): bearing_x
    # is the ink bounding box's own left edge, bearing_y its top edge
    # (relative to the baseline, y-up font-design-space sign), width/
    # height the bounding box's own extent -- all computed directly
    # from the decoded outline's real points (see `RawGlyphOutline.
    # bounding_box`'s own docstring for why that's used instead of the
    # `glyf` header's stored bounding box fields).
    return GlyphMetrics(
        advance,
        Float64(x_min) * scale,
        Float64(y_max) * scale,
        Float64(x_max - x_min) * scale,
        Float64(y_max - y_min) * scale,
    )


def glyph_path(mut face: TTFFace, codepoint: Int, pen_x: Float64, pen_y: Float64) raises -> Path:
    """One character's outline as a `Path`, positioned so its own
    local (0, 0) -- the glyph origin -- lands at (pen_x, pen_y) in
    pixel space. Advance the pen by this same call's own
    `glyph_metrics(face, codepoint).advance` before laying out the next
    character -- this function doesn't do that itself, matching
    `Path`'s own "caller positions everything explicitly" convention
    (see path.mojo's docstring).

    A glyph with no outline at all (whitespace -- a real font maps it
    to a valid glyph index with zero contours) returns an empty Path,
    the same "nothing to draw, not an error" convention `draw_text`'s
    own no-op cases already use.
    """
    var scale = face.scale()
    var glyph_index = face.glyph_index_for_codepoint(codepoint)
    var outline = face.glyph_outline(glyph_index)
    return outline_to_path(outline, pen_x, pen_y, scale)
