"""Text rendering: font matching from `font_discovery.mojo`, glyph
outlines and metrics from `ttf.mojo` via
`glyph_outline.mojo`, and rasterization from `fill_path_aa`
(`path.mojo`) under `FillRule.NONZERO`, the rule TrueType outlines are
drawn with, which also puts every glyph on the exact-area rasterizer
(`canvas.aa_area`). The glyph path is unhinted. Glyphs fill through
the same `fill_path_aa` every other shape uses, so translucent text
composites through `set_pixel` like any other fill.

Unrotated text goes through a glyph mask cache on the `FontCache`:
each (face, size, glyph, sub-pixel offset) is rasterized once, as
the sub-sample counts `fill_path_aa`'s sweep computes, and every later
occurrence composites the cached counts through the sweep's own alpha
arithmetic (`_composite_glyph_mask`), so the pixels are the ones a
direct fill writes. The sub-pixel offset is the glyph origin's
fractional part rounded to 1/64 px (`_SUBPIXEL_STEPS`): whole-pixel
anchors are unchanged, and a fractional anchor places each glyph
within 1/128 px of where the unrounded outline would go, well inside
the sweep's 1/4 px sample spacing. Rotated text still fills each
glyph's outline directly (#170).

`draw_text`'s (x, y) is the baseline's left end for LEFT alignment, not
a top-left corner like fill_rect's. CENTER/RIGHT shift each line
horizontally against that same anchor.

Rotation and multi-line share one code path with the single-line case.
`_layout_block` and draw_text's render pass both walk each line's glyphs
from a shared anchor-relative local layout. A rotated block, and a
block under a canvas transform that is a similarity, places each glyph
by mapping its pen position through one matrix and compositing a mask
cached at that orientation and scale (`_draw_block_similarity`); a
non-uniform scale or skew fills each mapped outline directly
(`_draw_block_direct`). At rotation=0.0 with one line the layout's
cos=1/sin=0 leaves every point unchanged.

One shaping step (`_shape_line`) turns each line's text into the glyph
sequence every pass then walks, which is what keeps `measure_text` and
`draw_text` from disagreeing. It splits the line into bidi runs
(`bidi.visual_runs`), shapes each run in *logical* order, and
concatenates the runs left to right with a right-to-left run's glyphs
reversed. Shaping per run in logical order is what the order has to
be: joining and ligature formation are defined between the characters
typed either side of a letter, which in a right-to-left run are not
the ones drawn either side of it.

Shaping a run maps each character through `cmap` and applies the
font's `GSUB` features for the run's script (`ttf.mojo`). A Latin run
gets `ccmp` and `liga`, so "f" and "i" become the one "fi" glyph a
font that has it draws. An Arabic run additionally classifies each
letter's contextual form from its logical neighbours
(`joining.mojo`) and enables that one of `isol`/`init`/`medi`/`fina`
on that one glyph, then runs `rlig`, `liga` and `calt`; so "بسم"
draws as initial beh, medial seen, final meem rather than three
isolated letters. `ligatures=False` skips substitution entirely and
lays out one glyph per character, which for Arabic is the isolated
forms -- one flag rather than two, because joining and ligatures are
the same machinery and an Arabic font's `rlig` is not optional once
the letters are joined.

Adjacent glyphs kern against each other in the same per-run pass,
through the font's `GPOS` pair adjustment or `kern` table
(`_apply_run_kerning`). Kerning is between the *substituted* glyphs,
the order a shaper applies the two tables in: a pair adjustment
written for "f" does not apply across an "fi" ligature, because the
ligature is what sits on the line. The pair is looked up in logical
order, since that is the order a font states an adjustment for, and
the result rides on the glyph a pass reaches second
(`_ShapedGlyph.kern_before`) -- for a right-to-left run that is the
*first* of the two logically, because reversing the run swaps which
one is drawn second. Kerning stops at a run boundary. The adjustment
moves the pen between two glyphs and nothing else, so the glyph mask
cache -- which holds a glyph's coverage, not its place on the line --
is untouched by it. `kerning=False` leaves every `kern_before` at zero,
restoring the plain sum of `hmtx` advances.

Shaping only substitutes among characters the primary face has glyphs
for, since a ligature is defined over glyphs of one font. Everything
else goes through font fallback (`_resolve_glyph`): a codepoint the
requested family has no real glyph for (glyph index 0, ".notdef")
resolves through `resolve_font_file_for_char`. This package bundles no
fonts, so a CJK/Cyrillic/symbol character requested under a Latin-only
family renders through whatever installed font has it; one missing
everywhere degrades to the unconstrained best match. Fallback faces
cache alongside the primary face.

Two entry points draw the same layout differently. `stroke_text` hands
each glyph's outline to `stroke_path_aa` instead of filling it, which
is a label that reads over a busy background. `draw_text_on_path` puts
the baseline on a curve: the string is laid out straight, then each
glyph is placed at its own arc length along the path
(`_ArcLengthPath`) and turned to the tangent there. Neither is a
different layout -- both walk what `_shape_line` produced, so text on
a curve kerns and ligates exactly as straight text does.

FontSlant/FontWeight come from font_discovery.mojo and TextAlign from
text_align.mojo, both re-exported here.
"""

from std.math import ceil, cos, floor, sin

from canvas.text.bidi import (
    detect_base_level,
    visual_runs,
    _mirror_codepoint,
)
from canvas.text.joining import (
    is_arabic,
    joining_forms,
    _FORM_FINAL,
    _FORM_INITIAL,
    _FORM_ISOLATED,
    _FORM_MEDIAL,
)
from canvas.buffer import Canvas
from canvas.color import Color
from canvas.compose import Filter, draw_canvas
from canvas.fill_rule import FillRule
from canvas.geometry import Matrix2D
from canvas.text.font_cache import _cache_key, _GlyphMask, FontCache
from canvas.text.font_discovery import FontSlant, FontWeight
from canvas.text.glyph_outline import (
    face_line_metrics,
    glyph_index_metrics,
    glyph_index_path,
    glyph_metrics,
    glyph_path,
    GlyphMetrics,
)
from canvas.text.ttf import (
    ShapedRun,
    TTFFace,
    _FEATURE_CALT,
    _FEATURE_CCMP,
    _FEATURE_FINA,
    _FEATURE_INIT,
    _FEATURE_ISOL,
    _FEATURE_LIGA,
    _FEATURE_MEDI,
    _FEATURE_RLIG,
    _SCRIPT_ARABIC,
    _SCRIPT_DEFAULT,
)
from canvas.path import (
    fill_path_aa,
    stroke_path_aa,
    Path,
    _ArcLengthPath,
    _CoverageMask,
    _path_coverage_counts,
    _through,
    PathOp,
)
from canvas.shapes.lines import LineJoin
from canvas.text.text_align import TextAlign

# Sub-pixel positions per pixel the glyph mask cache distinguishes.
# Two anchors whose fractional parts differ only in floating-point
# rounding (10.3 + advance against 42.3 + advance) round to the same
# step and share a mask; without this, exact-bit keys missed on nearly
# every fractional anchor (#170).
comptime _SUBPIXEL_STEPS = 64


struct TextMetrics(ImplicitlyCopyable, Movable):
    """A single line's measured size. `width`/`height` are its tight
    ink bounding box; `advance` is the logical cursor-advance distance,
    which differs whenever leading/trailing whitespace contributes
    advance but no ink. TextAlign's CENTER/RIGHT use `advance`.
    """

    var width: Float64
    var height: Float64
    var advance: Float64

    def __init__(out self, width: Float64, height: Float64, advance: Float64):
        """A single line's measured size.

        Args:
            width: Ink bounding box width.
            height: Ink bounding box height.
            advance: Logical cursor-advance distance.
        """
        self.width = width
        self.height = height
        self.advance = advance


struct _LineLayout(Movable):
    """One line's layout, computed in draw_text's first pass and reused
    in its second, including the shaped glyphs both passes place: the
    measuring pass is what shapes them, so the render pass neither
    repeats that work nor can disagree with it.
    """

    var glyphs: List[_ShapedGlyph]
    var x: Float64  # local (unrotated, anchor-relative) pen start X
    var y: Float64  # local (unrotated, anchor-relative) baseline Y
    var x_bearing: Float64
    var y_bearing: Float64
    var width: Float64
    var height: Float64

    def __init__(
        out self,
        var glyphs: List[_ShapedGlyph],
        x: Float64,
        y: Float64,
        x_bearing: Float64,
        y_bearing: Float64,
        width: Float64,
        height: Float64,
    ):
        self.glyphs = glyphs^
        self.x = x
        self.y = y
        self.x_bearing = x_bearing
        self.y_bearing = y_bearing
        self.width = width
        self.height = height

    def has_ink(self) -> Bool:
        return self.width > 0.0 and self.height > 0.0


struct _BlockLayout(Movable):
    """Every line's local layout plus the combined rotated bounding box
    around the (x, y) anchor. Computed by _layout_block and shared by
    draw_text (which renders it) and measure_text_block (which reports
    it), so the two can't disagree about a rotated block's footprint.
    Bounds are rotated corner positions in local anchor-relative space,
    not yet translated into canvas space.
    """

    var lines: List[_LineLayout]
    var any_ink: Bool
    var rot_min_x: Float64
    var rot_max_x: Float64
    var rot_min_y: Float64
    var rot_max_y: Float64

    def __init__(
        out self,
        var lines: List[_LineLayout],
        any_ink: Bool,
        rot_min_x: Float64,
        rot_max_x: Float64,
        rot_min_y: Float64,
        rot_max_y: Float64,
    ):
        self.lines = lines^
        self.any_ink = any_ink
        self.rot_min_x = rot_min_x
        self.rot_max_x = rot_max_x
        self.rot_min_y = rot_min_y
        self.rot_max_y = rot_max_y


struct _LineMetrics(ImplicitlyCopyable, Movable):
    """One line's ink bearing/width/height plus total cursor advance.
    TextAlign's CENTER/RIGHT align against `advance`, not `width` (see
    TextMetrics).
    """

    var x_bearing: Float64
    var y_bearing: Float64
    var width: Float64
    var height: Float64
    var advance: Float64

    def __init__(
        out self,
        x_bearing: Float64,
        y_bearing: Float64,
        width: Float64,
        height: Float64,
        advance: Float64,
    ):
        self.x_bearing = x_bearing
        self.y_bearing = y_bearing
        self.width = width
        self.height = height
        self.advance = advance

    def has_ink(self) -> Bool:
        return self.width > 0.0 and self.height > 0.0


struct _ShapedGlyph(ImplicitlyCopyable, Movable):
    """One layout unit: the glyph the passes place, the character it
    came from, and the pair kerning that precedes it.

    `glyph` is an index into the primary face, or 0 when the primary
    face has no glyph for `codepoint` and the character resolves
    through font fallback instead. `codepoint` is -1 when a `GSUB`
    substitution produced `glyph`, since a ligature stands for several
    characters and a substituted single glyph is no longer the one its
    character maps to -- either way the codepoint has stopped naming
    the glyph.

    `kern_before` is in pixels at the face's active size, and a pass
    adds it to the pen before placing this glyph. Carrying it here
    rather than recomputing it per pass is what lets the pair be looked
    up in logical order while the passes walk visual order.
    """

    var glyph: Int
    var codepoint: Int
    var kern_before: Float64

    def __init__(out self, glyph: Int, codepoint: Int):
        self.glyph = glyph
        self.codepoint = codepoint
        self.kern_before = 0.0


def _script_tag(codepoints: List[Int]) -> String:
    """The OpenType script tag to shape a run under: `arab` as soon as
    one Arabic character is in it, otherwise the default (`latn`,
    falling back to the font's `DFLT`). A run is one embedding level of
    one line, so a mixed Latin/Arabic line asks this once per run and
    gets a different answer for each.
    """
    for cp in codepoints:
        if is_arabic(cp):
            return _SCRIPT_ARABIC
    return _SCRIPT_DEFAULT


def _feature_mask(form: Int) -> Int:
    """The `GSUB` features enabled on one Arabic glyph: the ones that
    apply to every glyph of the run, plus the single joining feature
    its contextual form selects.
    """
    var mask = _FEATURE_CCMP | _FEATURE_RLIG | _FEATURE_LIGA | _FEATURE_CALT
    if form == _FORM_ISOLATED:
        return mask | _FEATURE_ISOL
    if form == _FORM_INITIAL:
        return mask | _FEATURE_INIT
    if form == _FORM_MEDIAL:
        return mask | _FEATURE_MEDI
    if form == _FORM_FINAL:
        return mask | _FEATURE_FINA
    return mask


def _shape_run(
    mut face: TTFFace, codepoints: List[Int], ligatures: Bool
) raises -> List[_ShapedGlyph]:
    """One bidi run's characters, in *logical* order, as glyphs: mapped
    through `cmap`, then substituted under the run's script.

    An Arabic run additionally classifies each character's joining form
    (`joining.mojo`) and hands `substitute_glyphs` a per-glyph feature
    mask, so `init`/`medi`/`fina` reach only the letters they belong
    on. Logical order is what makes that work at all -- a letter's form
    comes from the letters typed either side of it, which for a
    right-to-left run are not the ones drawn either side of it.

    Only glyphs of the primary face substitute, since a ligature is
    defined over glyphs of one font. A character that falls back to
    another font maps to glyph 0 here, which `substitute_glyphs` leaves
    alone and no ligature absorbs, and it keeps its own codepoint so
    the fallback lookup still finds it.
    """
    var count = len(codepoints)
    var glyphs = List[Int](capacity=count)
    for i in range(count):
        glyphs.append(face.glyph_index_for_codepoint(codepoints[i]))

    var script = _script_tag(codepoints)
    var out = List[_ShapedGlyph](capacity=count)
    if not (ligatures and face.has_substitutions(script)):
        for i in range(count):
            out.append(_ShapedGlyph(glyphs[i], codepoints[i]))
        return out^

    var shaped: ShapedRun
    if script == _SCRIPT_ARABIC:
        var forms = joining_forms(codepoints)
        var masks = List[Int](capacity=count)
        for i in range(count):
            masks.append(_feature_mask(forms[i]))
        shaped = face.substitute_glyphs(glyphs, masks, script)
    else:
        shaped = face.substitute_glyphs(glyphs)

    if not shaped.changed:
        for i in range(count):
            out.append(_ShapedGlyph(glyphs[i], codepoints[i]))
        return out^

    var source = 0
    for i in range(len(shaped.glyphs)):
        # An untouched glyph keeps its codepoint; anything the lookups
        # rewrote or merged no longer has one.
        if shaped.clusters[i] == 1 and shaped.glyphs[i] == glyphs[source]:
            out.append(_ShapedGlyph(shaped.glyphs[i], codepoints[source]))
        else:
            out.append(_ShapedGlyph(shaped.glyphs[i], -1))
        source += shaped.clusters[i]
    return out^


def _apply_run_kerning(
    mut face: TTFFace, mut glyphs: List[_ShapedGlyph], rtl: Bool
) raises:
    """Fill each glyph's `kern_before` for one run, whose glyphs are
    still in logical order.

    A `GPOS` pair adjustment is stated for the pair as *written*, so it
    is looked up as (logical i, logical i + 1) whichever way the run
    draws. Where it then lands differs: in a left-to-right run the
    second of the two is drawn second, and in a right-to-left run the
    first is, since reversing the run puts logical i to the right of
    logical i + 1. Either way the adjustment sits on the glyph a pass
    reaches second and moves the pen between the same two glyphs.

    Looking the pair up in visual order instead would ask the font for
    (V, A) where it states (A, V), which most fonts answer with no
    adjustment at all.
    """
    for i in range(len(glyphs) - 1):
        var adjustment = _kern_offset(
            face, glyphs[i].glyph, glyphs[i + 1].glyph
        )
        if adjustment == 0.0:
            continue
        if rtl:
            glyphs[i].kern_before = adjustment
        else:
            glyphs[i + 1].kern_before = adjustment


def _shape_line(
    mut face: TTFFace, line_text: String, ligatures: Bool, kerning: Bool
) raises -> List[_ShapedGlyph]:
    """One line's characters as the glyph sequence every pass lays out,
    each glyph carrying the kerning that precedes it.

    The line splits into bidi runs (`bidi.visual_runs`), each is shaped
    and kerned in logical order, and the runs are concatenated left to
    right with a right-to-left run's glyphs reversed. Shaping has to
    come before the reordering: an Arabic word shaped after reversal
    would join each letter to the wrong side, and a pair looked up
    after reversal is the pair the font does not state.

    Kerning stops at a run boundary, since a pair adjustment between
    two scripts' glyphs is not something a font states either.

    A pure left-to-right line is one run at level 0, so it comes out of
    this exactly as `cmap` plus substitution over the whole line, with
    each glyph's `kern_before` the adjustment against the glyph before
    it.
    """
    var codepoints = List[Int](capacity=line_text.byte_length())
    for cp in line_text.codepoints():
        codepoints.append(Int(cp))
    var base_level = detect_base_level(codepoints)

    var runs = visual_runs(codepoints, base_level)
    # The common case: one left-to-right run covering the line, which
    # is every line of Latin/Cyrillic/CJK text and every line with no
    # strongly right-to-left character in it. Shaping it in place skips
    # copying the codepoints into a run buffer.
    if len(runs) == 1 and not runs[0].is_rtl():
        var only = _shape_run(face, codepoints, ligatures)
        if kerning:
            _apply_run_kerning(face, only, False)
        return only^

    var out = List[_ShapedGlyph](capacity=len(codepoints))
    for run in runs:
        var run_codepoints = List[Int](capacity=run.length)
        for i in range(run.start, run.start + run.length):
            # bidi rule L4: a paired character inside an RTL run draws
            # its mirror image.
            if run.is_rtl():
                run_codepoints.append(_mirror_codepoint(codepoints[i]))
            else:
                run_codepoints.append(codepoints[i])
        var shaped = _shape_run(face, run_codepoints, ligatures)
        if kerning:
            _apply_run_kerning(face, shaped, run.is_rtl())
        if run.is_rtl():
            for i in range(len(shaped) - 1, -1, -1):
                out.append(shaped[i])
        else:
            out.extend(shaped^)
    return out^


struct _PositionedGlyph(Movable):
    """One glyph's metrics plus its outline, positioned at the
    (pen_x, pen_y) it was resolved for.
    """

    var metrics: GlyphMetrics
    var path: Path

    def __init__(out self, var metrics: GlyphMetrics, var path: Path):
        self.metrics = metrics^
        self.path = path^


def _resolve_glyph(
    mut primary: TTFFace,
    family: String,
    slant: FontSlant,
    weight: FontWeight,
    size: Float64,
    shaped: _ShapedGlyph,
    pen_x: Float64,
    pen_y: Float64,
    mut cache: FontCache,
) raises -> _PositionedGlyph:
    """This layout unit's metrics and outline, from `primary` when
    shaping found it a glyph there, otherwise from a fallback font
    resolved through `resolve_font_file_for_char` (codepoint-
    constrained matching -- e.g. CJK text requested under a Latin-only
    family). Both the fallback path and the parsed fallback face are
    cached by `cache`, so several fallback glyphs for the same
    codepoint cost one lookup and one parse.
    """
    if shaped.glyph != 0:
        return _PositionedGlyph(
            glyph_index_metrics(primary, shaped.glyph),
            glyph_index_path(primary, shaped.glyph, pen_x, pen_y),
        )

    var fallback = cache.resolve_face_for_char(
        family, slant, weight, shaped.codepoint, size
    )
    return _PositionedGlyph(
        glyph_metrics(fallback[], shaped.codepoint),
        glyph_path(fallback[], shaped.codepoint, pen_x, pen_y),
    )


def _resolve_glyph_metrics(
    mut primary: TTFFace,
    family: String,
    slant: FontSlant,
    weight: FontWeight,
    size: Float64,
    shaped: _ShapedGlyph,
    mut cache: FontCache,
) raises -> GlyphMetrics:
    """`_resolve_glyph` without the outline: the same primary-or-
    fallback face choice, returning only the metrics. The measuring
    pass needs nothing else, so it skips building a Path per glyph that
    the render pass would build again anyway.
    """
    if shaped.glyph != 0:
        return glyph_index_metrics(primary, shaped.glyph)
    var fallback = cache.resolve_face_for_char(
        family, slant, weight, shaped.codepoint, size
    )
    return glyph_metrics(fallback[], shaped.codepoint)


def _kern_offset(mut face: TTFFace, left: Int, right: Int) raises -> Float64:
    """The pair kerning between two adjacent glyphs of `face`, in
    pixels at its active size.

    The arguments are glyph indices, not codepoints, so a pair kerns as
    the glyphs shaping produced rather than as the characters typed:
    once "f" and "i" become one ligature glyph, an "f" pair adjustment
    no longer applies across it. Glyph 0 (".notdef") is the sentinel
    for "no glyph here", which covers both the start of a line and a
    character that fell back to another face -- a pair adjustment is
    defined between two glyphs of one font.
    """
    if left == 0 or right == 0:
        return 0.0
    if not face.has_kerning():
        return 0.0
    var units = face.kern_adjustment(left, right)
    if units == 0:
        return 0.0
    return Float64(units) * face.scale()


def _measure_line(
    mut face: TTFFace,
    glyphs: List[_ShapedGlyph],
    family: String,
    slant: FontSlant,
    weight: FontWeight,
    size: Float64,
    mut cache: FontCache,
) raises -> _LineMetrics:
    """One line's ink bounding box (x_bearing/y_bearing/width/height,
    all zero for a blank/whitespace-only line) and total advance, from
    the glyphs `_shape_line` produced for it. Accumulates each glyph's
    kerning and advance and combines the inked ones into one tight
    bbox. `family`/`slant`/`weight`/`size`/`cache` serve only
    _resolve_glyph's fallback lookup; `face` determines the rest.
    """
    var pen_x = 0.0
    var min_x = 1.0e18
    var max_x = -1.0e18
    var min_y = 1.0e18
    var max_y = -1.0e18
    var any_ink = False
    for shaped in glyphs:
        pen_x += shaped.kern_before
        var gm = _resolve_glyph_metrics(
            face, family, slant, weight, size, shaped, cache
        )
        if gm.width > 0.0 and gm.height > 0.0:
            var left = pen_x + gm.bearing_x
            var right = left + gm.width
            # gm.bearing_y is positive upward from the baseline
            # (TrueType's y-up design-unit convention); local layout
            # space is y-down, so the ink's local top is the negated
            # bearing.
            var top = -gm.bearing_y
            var bottom = top + gm.height
            if left < min_x:
                min_x = left
            if right > max_x:
                max_x = right
            if top < min_y:
                min_y = top
            if bottom > max_y:
                max_y = bottom
            any_ink = True
        pen_x += gm.advance

    if not any_ink:
        return _LineMetrics(0.0, 0.0, 0.0, 0.0, pen_x)
    return _LineMetrics(min_x, min_y, max_x - min_x, max_y - min_y, pen_x)


def _layout_block(
    text: String,
    size: Float64,
    family: String,
    slant: FontSlant,
    weight: FontWeight,
    rotation: Float64,
    align: TextAlign,
    kerning: Bool,
    ligatures: Bool,
    mut cache: FontCache,
) raises -> _BlockLayout:
    """The two-pass layout math: measure every "\\n"-separated line,
    compute each line's local anchor-relative position, then rotate
    every line's 4 ink corners around the anchor and combine them into
    one bounding box. draw_text and measure_text_block both call this,
    so neither carries its own copy.
    """
    var raw_lines = text.split("\n")

    var face = cache.resolve_face(family, slant, weight, size)
    var line_height = face_line_metrics(face[]).line_height

    var lines = List[_LineLayout](capacity=len(raw_lines))
    var any_ink = False
    for i in range(len(raw_lines)):
        var glyphs = _shape_line(
            face[], String(raw_lines[i]), ligatures, kerning
        )
        var measured = _measure_line(
            face[], glyphs, family, slant, weight, size, cache
        )
        var baseline_y = Float64(i) * line_height
        var x_offset = 0.0
        if align == TextAlign.CENTER:
            x_offset = -measured.advance / 2.0
        elif align == TextAlign.RIGHT:
            x_offset = -measured.advance
        var layout = _LineLayout(
            glyphs^,
            x_offset,
            baseline_y,
            measured.x_bearing,
            measured.y_bearing,
            measured.width,
            measured.height,
        )
        if layout.has_ink():
            any_ink = True
        lines.append(layout^)

    var c = cos(rotation)
    var s = sin(rotation)
    var rot_min_x = 1.0e18
    var rot_max_x = -1.0e18
    var rot_min_y = 1.0e18
    var rot_max_y = -1.0e18
    for i in range(len(lines)):
        ref line = lines[i]
        if not line.has_ink():
            continue
        var bx = line.x + line.x_bearing
        var by = line.y + line.y_bearing
        var corners_u: List[Float64] = [
            bx,
            bx + line.width,
            bx,
            bx + line.width,
        ]
        var corners_v: List[Float64] = [
            by,
            by,
            by + line.height,
            by + line.height,
        ]
        for k in range(4):
            var u = corners_u[k]
            var v = corners_v[k]
            var ru = u * c - v * s
            var rv = u * s + v * c
            if ru < rot_min_x:
                rot_min_x = ru
            if ru > rot_max_x:
                rot_max_x = ru
            if rv < rot_min_y:
                rot_min_y = rv
            if rv > rot_max_y:
                rot_max_y = rv

    return _BlockLayout(
        lines^, any_ink, rot_min_x, rot_max_x, rot_min_y, rot_max_y
    )


def measure_text(
    text: String,
    size: Float64,
    family: String = "Sans",
    slant: FontSlant = FontSlant.NORMAL,
    weight: FontWeight = FontWeight.NORMAL,
    kerning: Bool = True,
    ligatures: Bool = True,
) raises -> TextMetrics:
    """Measure `text` at `size` points in `family` without drawing it.

    Treats `text` as a single line: embedded "\\n" gets no line-break
    handling. Split on "\\n" and call this per line for a multi-line
    string.

    Builds a `FontCache` per call, which rescans every font file
    installed on the machine -- tens of milliseconds, against tens of
    microseconds once a cache exists. Fine for a one-off string; for
    more than a couple, construct one `FontCache` and use the `cache=`
    overload below.

    Args:
        text: Text to measure, treated as a single line.
        size: Font size in points.
        family: Font family name or generic alias.
        slant: Requested upright/italic/oblique style.
        weight: Requested normal/bold weight.
        kerning: Apply the font's pair kerning between adjacent glyphs.
        ligatures: Apply the font's `GSUB` shaping -- ligatures and
            Arabic contextual forms. False lays out one glyph per
            character.

    Returns:
        `text`'s width/height/advance at that size.
    """
    var cache = FontCache()
    return measure_text(
        text, size, family, slant, weight, kerning, ligatures, cache=cache
    )


def measure_text(
    text: String,
    size: Float64,
    family: String = "Sans",
    slant: FontSlant = FontSlant.NORMAL,
    weight: FontWeight = FontWeight.NORMAL,
    kerning: Bool = True,
    ligatures: Bool = True,
    *,
    mut cache: FontCache,
) raises -> TextMetrics:
    """Like measure_text above, but resolving fonts through `cache`.
    Pass the same `FontCache` to every call in a batch.

    Args:
        text: Text to measure, treated as a single line.
        size: Font size in points.
        family: Font family name or generic alias.
        slant: Requested upright/italic/oblique style.
        weight: Requested normal/bold weight.
        kerning: Apply the font's pair kerning between adjacent glyphs.
        ligatures: Apply the font's `GSUB` shaping -- ligatures and
            Arabic contextual forms. False lays out one glyph per
            character.
        cache: Shared cache for font resolution and parsed faces.

    Returns:
        `text`'s width/height/advance at that size.
    """
    var face = cache.resolve_face(family, slant, weight, size)
    var glyphs = _shape_line(face[], text, ligatures, kerning)
    var measured = _measure_line(
        face[], glyphs, family, slant, weight, size, cache
    )
    return TextMetrics(measured.width, measured.height, measured.advance)


struct TextBlockBounds(ImplicitlyCopyable, Movable):
    """The axis-aligned bounding box draw_text's ink would occupy for a
    given text/rotation/align/font, anchor-relative: `x`/`y` are the
    top-left corner relative to draw_text's `(x, y)` anchor, and either
    can be negative (RIGHT-aligned text extends left of the anchor; a
    label rotated upward extends above it). `x + width`/`y + height` is
    the bottom-right corner.

    Rotation and multi-line change a block's footprint in ways a single
    line's unrotated width/height (TextMetrics) can't capture, so this
    reports the same box _layout_block computes for rendering.
    """

    var x: Float64
    var y: Float64
    var width: Float64
    var height: Float64

    def __init__(
        out self, x: Float64, y: Float64, width: Float64, height: Float64
    ):
        """The bounding box draw_text's ink would occupy, anchor-
        relative -- see the struct docstring above.

        Args:
            x: Top-left corner x, relative to draw_text's anchor. Can
                be negative.
            y: Top-left corner y, relative to draw_text's anchor. Can
                be negative.
            width: Bounding box width.
            height: Bounding box height.
        """
        self.x = x
        self.y = y
        self.width = width
        self.height = height


def measure_text_block(
    text: String,
    size: Float64,
    family: String = "Sans",
    slant: FontSlant = FontSlant.NORMAL,
    weight: FontWeight = FontWeight.NORMAL,
    rotation: Float64 = 0.0,
    align: TextAlign = TextAlign.LEFT,
    kerning: Bool = True,
    ligatures: Bool = True,
) raises -> TextBlockBounds:
    """The bounding box draw_text(canvas, x, y, text, ..., rotation=
    rotation, align=align) would render into, anchor-relative and
    without drawing -- see TextBlockBounds.

    A string with no ink (empty, or every line whitespace-only) returns
    a zero-sized box at the anchor, matching draw_text's no-op.

    Builds a `FontCache` per call, which rescans every font file
    installed on the machine. See the `cache=` overload below, and
    `draw_text` for what the difference costs.

    Args:
        text: Text to lay out, "\\n"-separated lines.
        size: Font size in points.
        family: Font family name or generic alias.
        slant: Requested upright/italic/oblique style.
        weight: Requested normal/bold weight.
        rotation: Radians, rotating the whole block around the anchor.
        align: Horizontal alignment of each line.
        kerning: Apply the font's pair kerning between adjacent glyphs.
        ligatures: Apply the font's `GSUB` shaping -- ligatures and
            Arabic contextual forms. False lays out one glyph per
            character.

    Returns:
        The block's anchor-relative bounding box.
    """
    var cache = FontCache()
    return measure_text_block(
        text,
        size,
        family,
        slant,
        weight,
        rotation,
        align,
        kerning,
        ligatures,
        cache=cache,
    )


def measure_text_block(
    text: String,
    size: Float64,
    family: String = "Sans",
    slant: FontSlant = FontSlant.NORMAL,
    weight: FontWeight = FontWeight.NORMAL,
    rotation: Float64 = 0.0,
    align: TextAlign = TextAlign.LEFT,
    kerning: Bool = True,
    ligatures: Bool = True,
    *,
    mut cache: FontCache,
) raises -> TextBlockBounds:
    """Like measure_text_block above, but resolving fonts through
    `cache` rather than fresh every call.

    Args:
        text: Text to lay out, "\\n"-separated lines.
        size: Font size in points.
        family: Font family name or generic alias.
        slant: Requested upright/italic/oblique style.
        weight: Requested normal/bold weight.
        rotation: Radians, rotating the whole block around the anchor.
        align: Horizontal alignment of each line.
        kerning: Apply the font's pair kerning between adjacent glyphs.
        ligatures: Apply the font's `GSUB` shaping -- ligatures and
            Arabic contextual forms. False lays out one glyph per
            character.
        cache: Shared cache for font resolution and parsed faces.

    Returns:
        The block's anchor-relative bounding box.
    """
    if text == "":
        return TextBlockBounds(0.0, 0.0, 0.0, 0.0)
    var block = _layout_block(
        text,
        size,
        family,
        slant,
        weight,
        rotation,
        align,
        kerning,
        ligatures,
        cache,
    )
    if not block.any_ink:
        return TextBlockBounds(0.0, 0.0, 0.0, 0.0)
    return TextBlockBounds(
        block.rot_min_x,
        block.rot_min_y,
        block.rot_max_x - block.rot_min_x,
        block.rot_max_y - block.rot_min_y,
    )


def _rotate_translate_x(
    x: Float64, y: Float64, c: Float64, s: Float64, tx: Float64
) -> Float64:
    return tx + x * c - y * s


def _rotate_translate_y(
    x: Float64, y: Float64, c: Float64, s: Float64, ty: Float64
) -> Float64:
    return ty + x * s + y * c


def _place_glyph_path(
    local_path: Path,
    c: Float64,
    s: Float64,
    anchor_x: Float64,
    anchor_y: Float64,
) raises -> Path:
    """Rotate every point of `local_path` (glyph-local, anchor-relative,
    unrotated) by the block's rotation and translate by draw_text's
    `(x, y)` anchor, in one pass. Path exposes no "map every point"
    API, so this reads `Path.commands` directly, as svg.mojo's emitter
    does.
    """
    var out = Path()
    for cmd in local_path.commands:
        if cmd.op == PathOp.MOVE_TO:
            out.move_to(
                _rotate_translate_x(cmd.p1.x, cmd.p1.y, c, s, anchor_x),
                _rotate_translate_y(cmd.p1.x, cmd.p1.y, c, s, anchor_y),
            )
        elif cmd.op == PathOp.LINE_TO:
            out.line_to(
                _rotate_translate_x(cmd.p1.x, cmd.p1.y, c, s, anchor_x),
                _rotate_translate_y(cmd.p1.x, cmd.p1.y, c, s, anchor_y),
            )
        elif cmd.op == PathOp.QUAD_TO:
            out.quad_curve_to(
                _rotate_translate_x(cmd.p1.x, cmd.p1.y, c, s, anchor_x),
                _rotate_translate_y(cmd.p1.x, cmd.p1.y, c, s, anchor_y),
                _rotate_translate_x(cmd.p2.x, cmd.p2.y, c, s, anchor_x),
                _rotate_translate_y(cmd.p2.x, cmd.p2.y, c, s, anchor_y),
            )
        elif cmd.op == PathOp.CUBIC_TO:
            out.cubic_curve_to(
                _rotate_translate_x(cmd.p1.x, cmd.p1.y, c, s, anchor_x),
                _rotate_translate_y(cmd.p1.x, cmd.p1.y, c, s, anchor_y),
                _rotate_translate_x(cmd.p2.x, cmd.p2.y, c, s, anchor_x),
                _rotate_translate_y(cmd.p2.x, cmd.p2.y, c, s, anchor_y),
                _rotate_translate_x(cmd.p3.x, cmd.p3.y, c, s, anchor_x),
                _rotate_translate_y(cmd.p3.x, cmd.p3.y, c, s, anchor_y),
            )
        else:  # PathOp.CLOSE
            out.close()
    return out^


def draw_text(
    mut canvas: Canvas,
    x: Int,
    y: Int,
    text: String,
    color: Color,
    size: Float64,
    family: String = "Sans",
    slant: FontSlant = FontSlant.NORMAL,
    weight: FontWeight = FontWeight.NORMAL,
    rotation: Float64 = 0.0,
    align: TextAlign = TextAlign.LEFT,
    kerning: Bool = True,
    ligatures: Bool = True,
) raises:
    """Render `text` (one or more "\\n"-separated lines) anchored at
    `(x, y)` in `family` at `size` points, compositing onto `canvas` in
    `color`. AA coverage combines with `color.a` through the same
    set_pixel() blend every other filled shape uses.

    `rotation` (radians) rotates the whole block -- every line together
    -- around the `(x, y)` anchor. Transform2D's `rotation`
    (geometry.mojo) instead tilts a whole data-to-pixel mapping.

    Builds a `FontCache` per call and throws it away, so every call
    rescans every font file installed on the machine. That scan is tens
    of milliseconds where a cached label is tens of microseconds, and it
    does not shrink with the length of the string -- a chart labelling
    its axes through this overload spends nearly all of its time in font
    discovery. Construct one `FontCache` and pass it to the `cache=`
    overload below for anything past a couple of strings.

    Args:
        canvas: Canvas to draw into.
        x: Anchor x -- baseline left end for LEFT alignment.
        y: Anchor y -- baseline.
        text: Text to draw, "\\n"-separated lines.
        color: Text color.
        size: Font size in points.
        family: Font family name or generic alias.
        slant: Requested upright/italic/oblique style.
        weight: Requested normal/bold weight.
        rotation: Radians, rotating the whole block around the anchor.
        align: Horizontal alignment of each line.
        kerning: Apply the font's pair kerning between adjacent glyphs.
        ligatures: Apply the font's `GSUB` shaping -- ligatures and
            Arabic contextual forms. False lays out one glyph per
            character.
    """
    var cache = FontCache()
    draw_text(
        canvas,
        x,
        y,
        text,
        color,
        size,
        family,
        slant,
        weight,
        rotation,
        align,
        kerning,
        ligatures,
        cache=cache,
    )


def draw_text(
    mut canvas: Canvas,
    x: Int,
    y: Int,
    text: String,
    color: Color,
    size: Float64,
    family: String = "Sans",
    slant: FontSlant = FontSlant.NORMAL,
    weight: FontWeight = FontWeight.NORMAL,
    rotation: Float64 = 0.0,
    align: TextAlign = TextAlign.LEFT,
    kerning: Bool = True,
    ligatures: Bool = True,
    *,
    mut cache: FontCache,
) raises:
    """Like draw_text above, but resolving fonts through `cache` rather
    than fresh every call. Whole-pixel anchor; delegates to the
    sub-pixel overload below.

    Args:
        canvas: Canvas to draw into.
        x: Anchor x -- baseline left end for LEFT alignment.
        y: Anchor y -- baseline.
        text: Text to draw, "\\n"-separated lines.
        color: Text color.
        size: Font size in points.
        family: Font family name or generic alias.
        slant: Requested upright/italic/oblique style.
        weight: Requested normal/bold weight.
        rotation: Radians, rotating the whole block around the anchor.
        align: Horizontal alignment of each line.
        kerning: Apply the font's pair kerning between adjacent glyphs.
        ligatures: Apply the font's `GSUB` shaping -- ligatures and
            Arabic contextual forms. False lays out one glyph per
            character.
        cache: Shared cache for font resolution and parsed faces.
    """
    draw_text(
        canvas,
        Float64(x),
        Float64(y),
        text,
        color,
        size,
        family,
        slant,
        weight,
        rotation,
        align,
        kerning,
        ligatures,
        cache=cache,
    )


def draw_text(
    mut canvas: Canvas,
    x: Float64,
    y: Float64,
    text: String,
    color: Color,
    size: Float64,
    family: String = "Sans",
    slant: FontSlant = FontSlant.NORMAL,
    weight: FontWeight = FontWeight.NORMAL,
    rotation: Float64 = 0.0,
    align: TextAlign = TextAlign.LEFT,
    kerning: Bool = True,
    ligatures: Bool = True,
) raises:
    """`draw_text` anchored at a sub-pixel position, resolving fonts
    fresh. See the sub-pixel cached overload below for what the anchor
    buys, and the whole-pixel overload above for what resolving fresh
    costs.

    Args:
        canvas: Canvas to draw into.
        x: Anchor x, sub-pixel -- baseline left end for LEFT alignment.
        y: Anchor y, sub-pixel -- baseline.
        text: Text to draw, "\\n"-separated lines.
        color: Text color.
        size: Font size in points.
        family: Font family name or generic alias.
        slant: Requested upright/italic/oblique style.
        weight: Requested normal/bold weight.
        rotation: Radians, rotating the whole block around the anchor.
        align: Horizontal alignment of each line.
        kerning: Apply the font's pair kerning between adjacent glyphs.
        ligatures: Apply the font's `GSUB` shaping -- ligatures and
            Arabic contextual forms. False lays out one glyph per
            character.
    """
    var cache = FontCache()
    draw_text(
        canvas,
        x,
        y,
        text,
        color,
        size,
        family,
        slant,
        weight,
        rotation,
        align,
        kerning,
        ligatures,
        cache=cache,
    )


def _draw_text_transformed(
    mut canvas: Canvas,
    matrix: Matrix2D,
    x: Float64,
    y: Float64,
    text: String,
    color: Color,
    size: Float64,
    family: String,
    slant: FontSlant,
    weight: FontWeight,
    rotation: Float64,
    align: TextAlign,
    kerning: Bool,
    ligatures: Bool,
    mut cache: FontCache,
) raises:
    """`draw_text` under a canvas transform that is more than a
    translation. The block is laid out in user space exactly as the
    untransformed call lays it out, and each glyph goes through one
    matrix -- the block rotation about the anchor, the anchor's
    translation, then the canvas transform. When that placement is a
    similarity (a uniform scale and a rotation: supersampling, rotated
    labels) the glyphs are composited from the mask cache at the placed
    size and orientation; a non-uniform scale or a skew fills each
    outline directly.
    """
    var block = _layout_block(
        text,
        size,
        family,
        slant,
        weight,
        rotation,
        align,
        kerning,
        ligatures,
        cache,
    )
    if not block.any_ink:
        return
    var placement = (
        Matrix2D.rotation(rotation)
        .then(Matrix2D.translation(x, y))
        .then(matrix)
    )
    var saved = canvas._take_transform()
    if placement.is_similarity():
        try:
            _draw_block_similarity(
                canvas,
                block,
                placement,
                color,
                size,
                family,
                slant,
                weight,
                cache,
            )
        except e:
            canvas._set_transform(saved)
            raise e
        canvas._set_transform(saved)
        return
    try:
        _draw_block_direct(
            canvas, block, placement, color, size, family, slant, weight, cache
        )
    except e:
        canvas._set_transform(saved)
        raise e
    canvas._set_transform(saved)


def _draw_block_direct(
    mut canvas: Canvas,
    block: _BlockLayout,
    placement: Matrix2D,
    color: Color,
    size: Float64,
    family: String,
    slant: FontSlant,
    weight: FontWeight,
    mut cache: FontCache,
) raises:
    """Draw a laid-out block by filling each glyph's outline through
    `placement` directly: the path for a placement that is not a
    similarity (a non-uniform scale, a skew), which the mask cache
    cannot hold at one size and orientation. The canvas transform is
    expected to be taken off already. The reference the cached
    similarity path is tested against.
    """
    var face = cache.resolve_face(family, slant, weight, size)
    for i in range(len(block.lines)):
        ref line = block.lines[i]
        var pen_x = line.x
        for shaped in line.glyphs:
            pen_x += shaped.kern_before
            if _try_color_glyph(
                canvas,
                face[],
                family,
                slant,
                weight,
                size,
                shaped,
                Matrix2D.translation(pen_x, line.y).then(placement),
                color,
                cache,
            ):
                pen_x += _resolve_glyph_metrics(
                    face[], family, slant, weight, size, shaped, cache
                ).advance
                continue
            var g = _resolve_glyph(
                face[],
                family,
                slant,
                weight,
                size,
                shaped,
                pen_x,
                line.y,
                cache,
            )
            if g.metrics.width > 0.0 and g.metrics.height > 0.0:
                fill_path_aa(
                    canvas,
                    _through(g.path, placement),
                    color,
                    FillRule.NONZERO,
                )
            pen_x += g.metrics.advance


def _linear_key(m: Matrix2D) -> String:
    """The cache-key spelling of a linear map: its four entries in
    1/4096ths, so two placements that differ by less than that share
    masks, and a glyph is never scaled by more than that much from
    what its key says.
    """
    return (
        "m"
        + String(Int(floor(m.a * 4096.0 + 0.5)))
        + ","
        + String(Int(floor(m.b * 4096.0 + 0.5)))
        + ","
        + String(Int(floor(m.c * 4096.0 + 0.5)))
        + ","
        + String(Int(floor(m.d * 4096.0 + 0.5)))
        + "|"
    )


def _draw_block_similarity(
    mut canvas: Canvas,
    block: _BlockLayout,
    placement: Matrix2D,
    color: Color,
    size: Float64,
    family: String,
    slant: FontSlant,
    weight: FontWeight,
    mut cache: FontCache,
) raises:
    """Draw a laid-out block whose placement is a similarity -- a
    uniform scale and a rotation about the anchor, then a translation
    -- through the glyph mask cache, each glyph's mask rasterized once
    at the placed size and orientation and composited at its placed
    origin. The pen advances in layout space; only the origin is
    mapped. This is what a supersampling `scale()` and a rotated label
    take, so neither pays the direct outline fill per glyph.
    """
    var face = cache.resolve_face(family, slant, weight, size)
    var linear = Matrix2D(
        placement.a, placement.b, placement.c, placement.d, 0.0, 0.0
    )
    var key_prefix = (
        _cache_key(family, slant, weight)
        + "@"
        + String(Int(ceil(size)))
        + "|"
        + _linear_key(linear)
    )
    for i in range(len(block.lines)):
        ref line = block.lines[i]
        var pen_x = line.x
        for shaped in line.glyphs:
            pen_x += shaped.kern_before
            var origin = placement.apply(pen_x, line.y)
            pen_x += _draw_cached_glyph(
                canvas,
                face[],
                family,
                slant,
                weight,
                size,
                shaped,
                origin.x,
                origin.y,
                key_prefix,
                color,
                cache,
                linear,
            )


def _composite_glyph_mask(
    mut canvas: Canvas,
    mask: _CoverageMask,
    offset_x: Int,
    offset_y: Int,
    color: Color,
):
    """Blend a cached glyph's coverage onto `canvas` with the mask's
    origin shifted by (offset_x, offset_y). Each row is intersected once
    with the canvas and the rectangle clip and written through
    `write_pixel`, the arrangement `_sweep_band` uses; under a clip path
    the per-pixel mask applies, so those rows go through `set_pixel`.
    The alpha arithmetic is `_sweep_band`'s, on the same counts, so the
    result matches a direct `fill_path_aa` of the glyph.
    """
    var masked = canvas.has_clip_mask()
    var total = Float64(mask.total_samples)
    # An opaque colour over an exact-area mask, which is every glyph a
    # NONZERO fill rasterizes: the count is in 255ths, so it is the
    # alpha, and the general form below rounds back to it for every
    # count. Skipping the divide there is most of the compositing cost
    # of a small label.
    var direct = color.a == 255 and mask.total_samples == 255
    var cp = mask.counts.unsafe_ptr()
    var left = offset_x + mask.origin_x
    for row in range(mask.height):
        var py = offset_y + mask.origin_y + row
        var region = canvas.effective_fill_rect(left, py, mask.width, 1)
        if region[2] == 0 or region[3] == 0:
            continue
        var lo = region[0] - left
        var hi = lo + region[2]
        var base = row * mask.width
        if direct and not masked:
            # The counts are the alphas: hand the row to the buffer.
            canvas.composite_alpha_row(
                left + lo, py, mask.counts, base + lo, hi - lo, color
            )
            continue
        for mx in range(lo, hi):
            var covered = Int(cp[unsafe_offset=base + mx])
            if covered == 0:
                continue
            var alpha: UInt8
            if direct:
                alpha = UInt8(covered)
            else:
                alpha = UInt8(
                    Int(Float64(covered) / total * Float64(color.a) + 0.5)
                )
            if masked:
                canvas.set_pixel(left + mx, py, color.with_alpha(alpha))
            else:
                canvas.write_pixel(left + mx, py, color.with_alpha(alpha))


def _rasterize_glyph(
    mut primary: TTFFace,
    family: String,
    slant: FontSlant,
    weight: FontWeight,
    size: Float64,
    shaped: _ShapedGlyph,
    frac_x: Float64,
    frac_y: Float64,
    mut cache: FontCache,
    linear: Matrix2D = Matrix2D.identity(),
) raises -> _GlyphMask:
    """A glyph's advance and coverage with its origin at (frac_x,
    frac_y), both in [0, 1): the outline `_resolve_glyph` would build
    for the render pass, swept with the same fill rule, sample grid and
    curve flattening `fill_path_aa` applies to it, kept as counts.

    `linear` is the map the outline goes through about its origin
    before the sub-pixel shift -- a uniform scale, a rotation -- for a
    glyph drawn under a similarity transform. The identity takes the
    outline as resolved. The advance is the untransformed one either
    way: the pen advances in the space the text was laid out in.
    """
    if linear.is_identity():
        var g = _resolve_glyph(
            primary, family, slant, weight, size, shaped, frac_x, frac_y, cache
        )
        if not (g.metrics.width > 0.0 and g.metrics.height > 0.0):
            return _GlyphMask(
                g.metrics.advance, _CoverageMask(List[UInt8](), 0, 0, 0, 0, 16)
            )
        return _GlyphMask(
            g.metrics.advance,
            _path_coverage_counts(g.path, FillRule.NONZERO, 4, 0),
        )
    var g = _resolve_glyph(
        primary, family, slant, weight, size, shaped, 0.0, 0.0, cache
    )
    if not (g.metrics.width > 0.0 and g.metrics.height > 0.0):
        return _GlyphMask(
            g.metrics.advance, _CoverageMask(List[UInt8](), 0, 0, 0, 0, 16)
        )
    var placed = _through(
        g.path, linear.then(Matrix2D.translation(frac_x, frac_y))
    )
    return _GlyphMask(
        g.metrics.advance,
        _path_coverage_counts(placed, FillRule.NONZERO, 4, 0),
    )


def _draw_color_glyph(
    mut canvas: Canvas,
    mut face: TTFFace,
    glyph_index: Int,
    placement: Matrix2D,
    opacity: Float64,
) raises -> Bool:
    """Draw `glyph_index`'s color bitmap, if the face has one for it,
    through `placement` (glyph origin space to device space), scaled
    from the strike's pixels to the face's size and composited with
    bilinear sampling. Returns whether anything was drawn; a glyph
    without a bitmap is left to the outline path.
    """
    if not face.has_color_bitmaps():
        return False
    var bm = face.color_bitmap_metrics(glyph_index)
    if not bm.found:
        return False
    var s = face.scale() * Float64(face.units_per_em) / Float64(bm.ppem)
    var bitmap = face.color_bitmap(glyph_index)
    var m = (
        Matrix2D.scaling(s, s)
        .then(
            Matrix2D.translation(
                Float64(bm.bearing_x) * s, -Float64(bm.bearing_y) * s
            )
        )
        .then(placement)
    )
    draw_canvas(canvas, bitmap[], m, opacity, Filter.BILINEAR)
    return True


def _try_color_glyph(
    mut canvas: Canvas,
    mut primary: TTFFace,
    family: String,
    slant: FontSlant,
    weight: FontWeight,
    size: Float64,
    shaped: _ShapedGlyph,
    placement: Matrix2D,
    color: Color,
    mut cache: FontCache,
) raises -> Bool:
    """`_draw_color_glyph` for a shaped glyph, on the primary face or
    the fallback face that owns its codepoint. The text color's alpha
    is the bitmap's opacity; its RGB does not apply, the bitmap having
    colors of its own.
    """
    var opacity = Float64(color.a) / 255.0
    if shaped.glyph != 0:
        return _draw_color_glyph(
            canvas, primary, shaped.glyph, placement, opacity
        )
    var fallback = cache.resolve_face_for_char(
        family, slant, weight, shaped.codepoint, size
    )
    if not fallback[].has_color_bitmaps():
        return False
    var gid = fallback[].glyph_index_for_codepoint(shaped.codepoint)
    return _draw_color_glyph(canvas, fallback[], gid, placement, opacity)


def _draw_cached_glyph(
    mut canvas: Canvas,
    mut primary: TTFFace,
    family: String,
    slant: FontSlant,
    weight: FontWeight,
    size: Float64,
    shaped: _ShapedGlyph,
    origin_x: Float64,
    origin_y: Float64,
    key_prefix: String,
    color: Color,
    mut cache: FontCache,
    linear: Matrix2D = Matrix2D.identity(),
) raises -> Float64:
    """Composite one glyph with its origin at (origin_x, origin_y)
    through the cache, rasterizing it on a miss, and return its
    advance. The key is the face and size (`key_prefix`, which also
    names `linear` when it is not the identity), then the glyph's
    identity, then the origin's sub-pixel part in 1/`_SUBPIXEL_STEPS`
    px; the whole-pixel part becomes the composite offset. A
    whole-pixel origin rasterizes at step 0, exactly where the direct
    fill would.

    A glyph's identity is its codepoint where it still has one, and
    "g" plus a primary-face glyph index where a `GSUB` substitution
    took it away -- two disjoint spellings, since a codepoint is
    written as decimal digits alone. Keying the substituted glyphs by
    index gives a ligature its own mask; keying everything else by
    codepoint keeps the fallback glyphs, which have no index in the
    primary face, distinguishable from each other and every unshaped
    glyph's key what it was.
    """
    # A color bitmap glyph is an image, not a coverage mask.
    if _try_color_glyph(
        canvas,
        primary,
        family,
        slant,
        weight,
        size,
        shaped,
        linear.then(Matrix2D.translation(origin_x, origin_y)),
        color,
        cache,
    ):
        return _resolve_glyph_metrics(
            primary, family, slant, weight, size, shaped, cache
        ).advance
    var ix = Int(floor(origin_x))
    var iy = Int(floor(origin_y))
    var step_x = Int(floor((origin_x - Float64(ix)) * _SUBPIXEL_STEPS + 0.5))
    var step_y = Int(floor((origin_y - Float64(iy)) * _SUBPIXEL_STEPS + 0.5))
    # A fraction that rounds up to the next whole pixel is that pixel.
    if step_x == _SUBPIXEL_STEPS:
        ix += 1
        step_x = 0
    if step_y == _SUBPIXEL_STEPS:
        iy += 1
        step_y = 0
    var frac_x = Float64(step_x) / _SUBPIXEL_STEPS
    var frac_y = Float64(step_y) / _SUBPIXEL_STEPS
    var identity = String(
        shaped.codepoint
    ) if shaped.codepoint >= 0 else "g" + String(shaped.glyph)
    var key = (
        key_prefix + identity + "|" + String(step_x) + "|" + String(step_y)
    )
    if key not in cache._glyph_masks:
        cache._store_glyph_mask(
            key,
            _rasterize_glyph(
                primary,
                family,
                slant,
                weight,
                size,
                shaped,
                frac_x,
                frac_y,
                cache,
                linear,
            ),
        )
    ref entry = cache._glyph_masks[key]
    if entry.mask.has_ink():
        _composite_glyph_mask(canvas, entry.mask, ix, iy, color)
    return entry.advance


def draw_text(
    mut canvas: Canvas,
    x: Float64,
    y: Float64,
    text: String,
    color: Color,
    size: Float64,
    family: String = "Sans",
    slant: FontSlant = FontSlant.NORMAL,
    weight: FontWeight = FontWeight.NORMAL,
    rotation: Float64 = 0.0,
    align: TextAlign = TextAlign.LEFT,
    kerning: Bool = True,
    ligatures: Bool = True,
    *,
    mut cache: FontCache,
) raises:
    """The implementation every other `draw_text` overload delegates to:
    sub-pixel anchor, fonts resolved through `cache` rather than fresh
    every call.

    A sub-pixel anchor places a label against something itself at a
    fractional position -- a tick at x = 103.7, a label centered on a bar
    whose midpoint is not a whole pixel. Rounding the anchor first shifts
    the whole string.

    Resolving through the cache collapses the two resolutions a single
    call makes, the measuring pass and the render pass, into one lookup
    plus a hit.

    Args:
        canvas: Canvas to draw into.
        x: Anchor x -- baseline left end for LEFT alignment.
        y: Anchor y -- baseline.
        text: Text to draw, "\\n"-separated lines.
        color: Text color.
        size: Font size in points.
        family: Font family name or generic alias.
        slant: Requested upright/italic/oblique style.
        weight: Requested normal/bold weight.
        rotation: Radians, rotating the whole block around the anchor.
        align: Horizontal alignment of each line.
        kerning: Apply the font's pair kerning between adjacent glyphs.
        ligatures: Apply the font's `GSUB` shaping -- ligatures and
            Arabic contextual forms. False lays out one glyph per
            character.
        cache: Shared cache for font resolution and parsed faces.
    """
    if canvas.has_transform():
        var m = canvas.current_transform()
        if not m.is_translation():
            _draw_text_transformed(
                canvas,
                m,
                x,
                y,
                text,
                color,
                size,
                family,
                slant,
                weight,
                rotation,
                align,
                kerning,
                ligatures,
                cache,
            )
            return
        # A pure translation keeps every glyph at its size and
        # orientation, so the anchor moves and the cache still applies.
        var saved = canvas._take_transform()
        try:
            draw_text(
                canvas,
                x + m.e,
                y + m.f,
                text,
                color,
                size,
                family,
                slant,
                weight,
                rotation,
                align,
                kerning,
                ligatures,
                cache=cache,
            )
        except e:
            canvas._set_transform(saved)
            raise e
        canvas._set_transform(saved)
        return
    if text == "":
        return

    # With one line and rotation=0.0, cos=1/sin=0 leaves every corner
    # unchanged inside _layout_block, reducing to that line's
    # unrotated ink box.
    var block = _layout_block(
        text,
        size,
        family,
        slant,
        weight,
        rotation,
        align,
        kerning,
        ligatures,
        cache,
    )
    if not block.any_ink:
        # Every line whitespace-only/empty -- nothing to draw.
        return

    var face = cache.resolve_face(family, slant, weight, size)

    if rotation == 0.0:
        # Faces are shared per (font file, whole pixel size), so the
        # mask key follows the same rounding of `size`.
        var key_prefix = (
            _cache_key(family, slant, weight)
            + "@"
            + String(Int(ceil(size)))
            + "|"
        )
        for i in range(len(block.lines)):
            ref line = block.lines[i]
            var pen_x = line.x
            for shaped in line.glyphs:
                pen_x += shaped.kern_before
                pen_x += _draw_cached_glyph(
                    canvas,
                    face[],
                    family,
                    slant,
                    weight,
                    size,
                    shaped,
                    x + pen_x,
                    y + line.y,
                    key_prefix,
                    color,
                    cache,
                )
        return

    # A rotated block is a similarity placement: rotate about the
    # anchor, then move to it. Its glyphs are cached at that
    # orientation, keyed by it.
    _draw_block_similarity(
        canvas,
        block,
        Matrix2D.rotation(rotation).then(Matrix2D.translation(x, y)),
        color,
        size,
        family,
        slant,
        weight,
        cache,
    )


def stroke_text(
    mut canvas: Canvas,
    x: Float64,
    y: Float64,
    text: String,
    color: Color,
    size: Float64,
    width: Float64 = 1.0,
    family: String = "Sans",
    slant: FontSlant = FontSlant.NORMAL,
    weight: FontWeight = FontWeight.NORMAL,
    rotation: Float64 = 0.0,
    align: TextAlign = TextAlign.LEFT,
    join: LineJoin = LineJoin.ROUND,
    miter_limit: Float64 = 4.0,
    kerning: Bool = True,
    ligatures: Bool = True,
) raises:
    """`draw_text`'s outline instead of its fill, resolving fonts fresh
    every call. See the `cache=` overload below for the parameters and
    `draw_text` for what resolving fresh costs.

    Args:
        canvas: Canvas to draw into.
        x: Anchor x -- baseline left end for LEFT alignment.
        y: Anchor y -- baseline.
        text: Text to draw, "\\n"-separated lines.
        color: Stroke color.
        size: Font size in points.
        width: Stroke width in pixels.
        family: Font family name or generic alias.
        slant: Requested upright/italic/oblique style.
        weight: Requested normal/bold weight.
        rotation: Radians, rotating the whole block around the anchor.
        align: Horizontal alignment of each line.
        join: How a corner of the outline is turned -- see LineJoin.
        miter_limit: Ratio past which a MITER join falls back to
            BEVEL, as a multiple of half the stroke width.
        kerning: Apply the font's pair kerning between adjacent glyphs.
        ligatures: Apply the font's `GSUB` shaping -- ligatures and
            Arabic contextual forms. False lays out one glyph per
            character.
    """
    var cache = FontCache()
    stroke_text(
        canvas,
        x,
        y,
        text,
        color,
        size,
        width,
        family,
        slant,
        weight,
        rotation,
        align,
        join,
        miter_limit,
        kerning,
        ligatures,
        cache=cache,
    )


def stroke_text(
    mut canvas: Canvas,
    x: Float64,
    y: Float64,
    text: String,
    color: Color,
    size: Float64,
    width: Float64 = 1.0,
    family: String = "Sans",
    slant: FontSlant = FontSlant.NORMAL,
    weight: FontWeight = FontWeight.NORMAL,
    rotation: Float64 = 0.0,
    align: TextAlign = TextAlign.LEFT,
    join: LineJoin = LineJoin.ROUND,
    miter_limit: Float64 = 4.0,
    kerning: Bool = True,
    ligatures: Bool = True,
    *,
    mut cache: FontCache,
) raises:
    """Outline `text` rather than filling it: the layout `draw_text`
    produces, with each glyph's outline handed to `stroke_path_aa`
    instead of `fill_path_aa`. Cairo's `text_path` + `stroke` and the
    HTML5 canvas's `strokeText`; an outlined label reads over a busy
    background where a filled one does not.

    Everything but the rasterization step is `draw_text`'s: the same
    shaping, kerning, line breaking, alignment and rotation about the
    `(x, y)` anchor, so a stroked string and a filled one sit on the
    same baseline and occupy the same box, give or take half a stroke
    width of outline on each side.

    No glyph mask cache. It holds a glyph's *coverage*, which is a
    property of the filled shape; the stroke around that shape is a
    different figure and would need a cache keyed by width, join and
    limit as well.

    `cap` is not a parameter: every TrueType contour is closed
    (`ttf.mojo`'s `outline_to_path` closes each one), so a glyph
    outline has no ends to finish and `stroke_path_aa` would ignore
    the value.

    The canvas transform applies through `stroke_path_aa`, so the
    stroke width is in user space and scales with the transform, as it
    does for any other stroked path.

    Args:
        canvas: Canvas to draw into.
        x: Anchor x -- baseline left end for LEFT alignment.
        y: Anchor y -- baseline.
        text: Text to draw, "\\n"-separated lines.
        color: Stroke color.
        size: Font size in points.
        width: Stroke width in pixels.
        family: Font family name or generic alias.
        slant: Requested upright/italic/oblique style.
        weight: Requested normal/bold weight.
        rotation: Radians, rotating the whole block around the anchor.
        align: Horizontal alignment of each line.
        join: How a corner of the outline is turned -- see LineJoin.
        miter_limit: Ratio past which a MITER join falls back to
            BEVEL, as a multiple of half the stroke width.
        kerning: Apply the font's pair kerning between adjacent glyphs.
        ligatures: Apply the font's `GSUB` shaping -- ligatures and
            Arabic contextual forms. False lays out one glyph per
            character.
        cache: Shared cache for font resolution and parsed faces.
    """
    if text == "":
        return
    var block = _layout_block(
        text,
        size,
        family,
        slant,
        weight,
        rotation,
        align,
        kerning,
        ligatures,
        cache,
    )
    if not block.any_ink:
        return
    var face = cache.resolve_face(family, slant, weight, size)
    var c = cos(rotation)
    var s = sin(rotation)

    for i in range(len(block.lines)):
        ref line = block.lines[i]
        var pen_x = line.x
        for shaped in line.glyphs:
            pen_x += shaped.kern_before
            var g = _resolve_glyph(
                face[],
                family,
                slant,
                weight,
                size,
                shaped,
                pen_x,
                line.y,
                cache,
            )
            if g.metrics.width > 0.0 and g.metrics.height > 0.0:
                stroke_path_aa(
                    canvas,
                    _place_glyph_path(g.path, c, s, x, y),
                    color,
                    width,
                    join=join,
                    miter_limit=miter_limit,
                )
            pen_x += g.metrics.advance


struct _PlacedGlyph(ImplicitlyCopyable, Movable):
    """One glyph positioned on a curve: the glyph itself, the origin
    its baseline sits at, and the unit tangent of the curve there,
    which is the direction the glyph's own baseline runs in.
    """

    var shaped: _ShapedGlyph
    var x: Float64
    var y: Float64
    var tx: Float64
    var ty: Float64

    def __init__(
        out self,
        shaped: _ShapedGlyph,
        x: Float64,
        y: Float64,
        tx: Float64,
        ty: Float64,
    ):
        self.shaped = shaped
        self.x = x
        self.y = y
        self.tx = tx
        self.ty = ty


def _text_on_path_placements(
    text: String,
    path: Path,
    size: Float64,
    offset: Float64,
    family: String,
    slant: FontSlant,
    weight: FontWeight,
    align: TextAlign,
    kerning: Bool,
    ligatures: Bool,
    mut cache: FontCache,
) raises -> List[_PlacedGlyph]:
    """Where each of `text`'s glyphs lands on `path` -- the whole of
    draw_text_on_path that is layout rather than rasterization.

    The line is laid out straight first, through the same
    `_shape_line` pass every other text call uses, which
    gives each glyph a pen offset and an advance. A glyph is then
    placed by its *centre*: the point at arc length
    `start + pen + advance/2` along the path, rotated to the tangent
    there, with its origin backed off half an advance along that same
    tangent. Cairo/Pango and SVG's `textPath` place a glyph the same
    way, and it is what keeps a glyph upright on a curve that turns
    under it rather than pivoting about its left edge.

    `start` is where the string begins along the path: `offset` for
    LEFT, `offset` minus half the total advance for CENTER, `offset`
    minus the whole advance for RIGHT.

    A glyph whose centre falls outside [0, the path's length] is left
    out entirely, SVG's rule -- the alternative, clamping it to an end,
    stacks the overflow into an unreadable pile there. A glyph with no
    ink is left out too, having nothing to draw.

    On a straight horizontal path this reduces exactly to draw_text's
    own placement rather than approximately: the tangent is (1, 0) bit
    for bit, so `sample` returns the path's start x plus the arc length
    unrounded, and backing off half an advance recovers the pen
    position, every term being a multiple of the font's design-unit
    pixel size.
    """
    var face = cache.resolve_face(family, slant, weight, size)
    var glyphs = _shape_line(face[], text, ligatures, kerning)
    var count = len(glyphs)

    # One metrics pass: the pen position each glyph starts at, its
    # advance, and whether it has ink. The total advance is what
    # CENTER/RIGHT align against, so it has to be known before the
    # first glyph is placed.
    var pens = List[Float64](capacity=count)
    var advances = List[Float64](capacity=count)
    var inked = List[Bool](capacity=count)
    var pen = 0.0
    for shaped in glyphs:
        pen += shaped.kern_before
        var gm = _resolve_glyph_metrics(
            face[], family, slant, weight, size, shaped, cache
        )
        pens.append(pen)
        advances.append(gm.advance)
        inked.append(gm.width > 0.0 and gm.height > 0.0)
        pen += gm.advance

    var start = offset
    if align == TextAlign.CENTER:
        start = offset - pen / 2.0
    elif align == TextAlign.RIGHT:
        start = offset - pen

    var curve = _ArcLengthPath(path)
    var placed = List[_PlacedGlyph]()
    for i in range(count):
        if not inked[i]:
            continue
        var half = advances[i] / 2.0
        var centre = start + pens[i] + half
        if centre < 0.0 or centre > curve.total:
            continue
        var s = curve.sample(centre)
        placed.append(
            _PlacedGlyph(
                glyphs[i], s.x - half * s.tx, s.y - half * s.ty, s.tx, s.ty
            )
        )
    return placed^


def _draw_placed_glyphs(
    mut canvas: Canvas,
    matrix: Matrix2D,
    placements: List[_PlacedGlyph],
    color: Color,
    size: Float64,
    family: String,
    slant: FontSlant,
    weight: FontWeight,
    mut cache: FontCache,
) raises:
    """Fill every glyph `_text_on_path_placements` produced, under
    `matrix` -- the canvas transform, already taken off the canvas by
    the caller so nothing applies it twice.

    A glyph whose tangent is exactly (1, 0) under a matrix that is no
    more than a translation is an unrotated glyph at a translated
    anchor, which is what draw_text's glyph mask cache is for, and it
    goes through the same `_draw_cached_glyph`. That is what makes a
    straight horizontal path draw pixel for pixel what draw_text draws:
    a cached composite and a direct fill of one outline agree within a
    coverage step, not exactly. Every other glyph is rotated, so it
    fills directly, as rotated text does.
    """
    var face = cache.resolve_face(family, slant, weight, size)
    # Faces are shared per (font file, whole pixel size), so the mask
    # key follows the same rounding of `size` draw_text's does.
    var key_prefix = (
        _cache_key(family, slant, weight) + "@" + String(Int(ceil(size))) + "|"
    )
    var translation = matrix.is_translation()
    for i in range(len(placements)):
        ref p = placements[i]
        if translation and p.tx == 1.0 and p.ty == 0.0:
            _ = _draw_cached_glyph(
                canvas,
                face[],
                family,
                slant,
                weight,
                size,
                p.shaped,
                p.x + matrix.e,
                p.y + matrix.f,
                key_prefix,
                color,
                cache,
            )
            continue
        var g = _resolve_glyph(
            face[], family, slant, weight, size, p.shaped, 0.0, 0.0, cache
        )
        # The glyph is built at its own origin and placed by one
        # matrix: turn to the tangent, translate onto the curve, then
        # the canvas transform.
        var placement = Matrix2D(p.tx, p.ty, -p.ty, p.tx, p.x, p.y).then(matrix)
        fill_path_aa(
            canvas, _through(g.path, placement), color, FillRule.NONZERO
        )


def draw_text_on_path(
    mut canvas: Canvas,
    path: Path,
    text: String,
    color: Color,
    size: Float64,
    offset: Float64 = 0.0,
    family: String = "Sans",
    slant: FontSlant = FontSlant.NORMAL,
    weight: FontWeight = FontWeight.NORMAL,
    align: TextAlign = TextAlign.LEFT,
    kerning: Bool = True,
    ligatures: Bool = True,
) raises:
    """Text along a curve, resolving fonts fresh every call. See the
    `cache=` overload below for the parameters and `draw_text` for what
    resolving fresh costs.

    Args:
        canvas: Canvas to draw into.
        path: Curve the baseline follows.
        text: Text to draw, treated as a single line.
        color: Text color.
        size: Font size in points.
        offset: Distance along the path the string is placed at.
        family: Font family name or generic alias.
        slant: Requested upright/italic/oblique style.
        weight: Requested normal/bold weight.
        align: Where `offset` sits in the string -- its start, middle
            or end.
        kerning: Apply the font's pair kerning between adjacent glyphs.
        ligatures: Apply the font's `GSUB` shaping -- ligatures and
            Arabic contextual forms. False lays out one glyph per
            character.
    """
    var cache = FontCache()
    draw_text_on_path(
        canvas,
        path,
        text,
        color,
        size,
        offset,
        family,
        slant,
        weight,
        align,
        kerning,
        ligatures,
        cache=cache,
    )


def draw_text_on_path(
    mut canvas: Canvas,
    path: Path,
    text: String,
    color: Color,
    size: Float64,
    offset: Float64 = 0.0,
    family: String = "Sans",
    slant: FontSlant = FontSlant.NORMAL,
    weight: FontWeight = FontWeight.NORMAL,
    align: TextAlign = TextAlign.LEFT,
    kerning: Bool = True,
    ligatures: Bool = True,
    *,
    mut cache: FontCache,
) raises:
    """Draw `text` with its baseline running along `path`: a label
    around a donut segment, a curved axis label on a polar grid.

    `path` replaces draw_text's `(x, y)` anchor and its `rotation`
    both: `offset` is a distance measured along the path rather than a
    point, and each glyph turns to the path's tangent where it sits,
    so a string on a circle leans round it. `align` says where `offset`
    falls in the string -- LEFT starts it there, CENTER centres its
    total advance about it, RIGHT ends it there.

    Arc length is measured over the path flattened the way
    `stroke_path_aa` flattens it, so the distance a glyph is placed at
    is a distance along the curve that gets drawn. Sub-paths add end to
    end with no distance between them.

    A glyph whose centre falls before the start or past the end of the
    path is not drawn (SVG's `textPath` rule): text longer than the
    curve loses its overflow rather than piling it up at the end. A
    string with no glyphs left on the path draws nothing.

    `text` is one line -- an embedded "\\n" gets no line-break
    handling, since a path gives no second baseline to break onto.

    Args:
        canvas: Canvas to draw into.
        path: Curve the baseline follows.
        text: Text to draw, treated as a single line.
        color: Text color.
        size: Font size in points.
        offset: Distance along the path the string is placed at.
        family: Font family name or generic alias.
        slant: Requested upright/italic/oblique style.
        weight: Requested normal/bold weight.
        align: Where `offset` sits in the string -- its start, middle
            or end.
        kerning: Apply the font's pair kerning between adjacent glyphs.
        ligatures: Apply the font's `GSUB` shaping -- ligatures and
            Arabic contextual forms. False lays out one glyph per
            character.
        cache: Shared cache for font resolution and parsed faces.
    """
    if text == "":
        return
    var placements = _text_on_path_placements(
        text,
        path,
        size,
        offset,
        family,
        slant,
        weight,
        align,
        kerning,
        ligatures,
        cache,
    )
    if len(placements) == 0:
        return
    # The placement matrix carries the canvas transform itself, so it
    # comes off the canvas for the duration -- fill_path_aa would
    # otherwise apply it a second time, and the cached-glyph path
    # writes device pixels and would not apply it at all.
    var matrix = Matrix2D.identity()
    if canvas.has_transform():
        matrix = canvas._take_transform()
    try:
        _draw_placed_glyphs(
            canvas,
            matrix,
            placements,
            color,
            size,
            family,
            slant,
            weight,
            cache,
        )
    except e:
        canvas._set_transform(matrix)
        raise e
    canvas._set_transform(matrix)
