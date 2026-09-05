"""Text rendering: font matching from `font_discovery.mojo`, glyph
outlines and metrics from `ttf.mojo` via
`glyph_outline.mojo`, and rasterization from `fill_path_aa`
(`path.mojo`) under `FillRule.NONZERO`, the rule TrueType outlines are
drawn with, which also puts every glyph on the exact-area rasterizer
(`canvas.aa_area`). The glyph path is unhinted. Glyphs fill through
the same `fill_path_aa` every other shape uses, so translucent text
composites through `set_pixel` like any other fill.

Unrotated text goes through a glyph mask cache on the `FontCache`:
each (face, size, codepoint, sub-pixel offset) is rasterized once, as
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
from a shared anchor-relative local layout, and each glyph's pen
position and outline are rotated around `(x, y)` and translated in one
pass (`_place_glyph_path`). At rotation=0.0 with one line, cos=1/sin=0
leaves every point unchanged.

Each line's codepoints pass through `bidi.visual_order` first
(`_visual_codepoints`), so mixed Hebrew/Arabic/Latin/digit text lays out
in reading order without draw_text or _measure_line handling direction.

Adjacent glyphs kern against each other (`_kern_offset`), through the
font's `GPOS` pair adjustment or `kern` table (`ttf.mojo`). The
adjustment moves the pen between two glyphs and nothing else: it is
applied in the one loop each pass runs over a line's visual-order
codepoints, so `measure_text` and `draw_text` accumulate the same
positions, and the glyph mask cache -- which holds a glyph's coverage,
not its place on the line -- is keyed and filled exactly as before.
`kerning=False` on either restores the plain sum of `hmtx` advances.

Every glyph also goes through font fallback (`_resolve_glyph`). If the
requested family has no real glyph for a codepoint (`has_glyph`
distinguishes one from ".notdef", index 0), that character resolves
through `resolve_font_file_for_char`. This package bundles no fonts, so
a CJK/Cyrillic/symbol character requested under a Latin-only family
renders through whatever installed font has it; one missing everywhere
degrades to the unconstrained best match. Fallback faces cache alongside
the primary face.

FontSlant/FontWeight come from font_discovery.mojo and TextAlign from
text_align.mojo, both re-exported here.
"""

from std.math import ceil, cos, floor, sin

from canvas.text.bidi import detect_base_level, visual_order
from canvas.buffer import Canvas
from canvas.color import Color
from canvas.fill_rule import FillRule
from canvas.geometry import Matrix2D
from canvas.text.font_cache import _cache_key, _GlyphMask, FontCache
from canvas.text.font_discovery import FontSlant, FontWeight
from canvas.text.glyph_outline import (
    face_line_metrics,
    glyph_metrics,
    glyph_path,
    has_glyph,
    GlyphMetrics,
)
from canvas.text.ttf import TTFFace
from canvas.path import (
    fill_path_aa,
    Path,
    _CoverageMask,
    _path_coverage_counts,
    _through,
    _CLOSE,
    _CUBIC_TO,
    _LINE_TO,
    _MOVE_TO,
    _QUAD_TO,
)
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


struct _LineLayout(ImplicitlyCopyable, Movable):
    """One line's layout, computed in draw_text's first pass and reused
    in its second.
    """

    var text: String
    var x: Float64  # local (unrotated, anchor-relative) pen start X
    var y: Float64  # local (unrotated, anchor-relative) baseline Y
    var x_bearing: Float64
    var y_bearing: Float64
    var width: Float64
    var height: Float64

    def __init__(
        out self,
        text: String,
        x: Float64,
        y: Float64,
        x_bearing: Float64,
        y_bearing: Float64,
        width: Float64,
        height: Float64,
    ):
        self.text = text
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


def _visual_codepoints(line_text: String) -> List[Int]:
    """`line_text`'s codepoints in left-to-right drawable order, via
    `bidi.visual_order`. Both `_measure_line` and draw_text's render
    pass walk this rather than `line_text.codepoints()`, so neither
    needs direction-handling logic of its own. A pure left-to-right
    line comes back unchanged: every codepoint sits at the same even
    level, so nothing is reversed.
    """
    var codepoints = List[Int](capacity=line_text.byte_length())
    for cp in line_text.codepoints():
        codepoints.append(Int(cp))
    var base_level = detect_base_level(codepoints)
    return visual_order(codepoints, base_level)


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
    codepoint: Int,
    pen_x: Float64,
    pen_y: Float64,
    mut cache: FontCache,
) raises -> _PositionedGlyph:
    """This character's metrics and outline, from `primary` if it has a
    glyph for `codepoint`, otherwise from a fallback font resolved
    through `resolve_font_file_for_char` (codepoint-constrained
    matching -- e.g. CJK text requested under a Latin-only family).
    Both the fallback path and the parsed fallback face are cached by
    `cache`, so several fallback glyphs for the same codepoint cost one
    lookup and one parse.
    """
    if has_glyph(primary, codepoint):
        return _PositionedGlyph(
            glyph_metrics(primary, codepoint),
            glyph_path(primary, codepoint, pen_x, pen_y),
        )

    var fallback = cache.resolve_face_for_char(
        family, slant, weight, codepoint, size
    )
    return _PositionedGlyph(
        glyph_metrics(fallback[], codepoint),
        glyph_path(fallback[], codepoint, pen_x, pen_y),
    )


def _resolve_glyph_metrics(
    mut primary: TTFFace,
    family: String,
    slant: FontSlant,
    weight: FontWeight,
    size: Float64,
    codepoint: Int,
    mut cache: FontCache,
) raises -> GlyphMetrics:
    """`_resolve_glyph` without the outline: the same primary-or-
    fallback face choice, returning only the metrics. The measuring
    pass needs nothing else, so it skips building a Path per glyph that
    the render pass would build again anyway.
    """
    if has_glyph(primary, codepoint):
        return glyph_metrics(primary, codepoint)
    var fallback = cache.resolve_face_for_char(
        family, slant, weight, codepoint, size
    )
    return glyph_metrics(fallback[], codepoint)


def _kern_offset(
    mut face: TTFFace, left_codepoint: Int, right_codepoint: Int
) raises -> Float64:
    """The pair kerning between two adjacent codepoints, in pixels at
    `face`'s active size.

    Zero unless both codepoints have a glyph in `face`: a pair
    adjustment is defined between two glyphs of one font, so a
    character that fell back to another face kerns against neither of
    its neighbours. `glyph_index_for_codepoint` returning 0
    (".notdef") is exactly that test, and is already memoized.
    """
    if not face.has_kerning():
        return 0.0
    var left = face.glyph_index_for_codepoint(left_codepoint)
    if left == 0:
        return 0.0
    var right = face.glyph_index_for_codepoint(right_codepoint)
    if right == 0:
        return 0.0
    var units = face.kern_adjustment(left, right)
    if units == 0:
        return 0.0
    return Float64(units) * face.scale()


def _measure_line(
    mut face: TTFFace,
    line_text: String,
    family: String,
    slant: FontSlant,
    weight: FontWeight,
    size: Float64,
    kerning: Bool,
    mut cache: FontCache,
) raises -> _LineMetrics:
    """One line's ink bounding box (x_bearing/y_bearing/width/height,
    all zero for a blank/whitespace-only line) and total advance.
    Walks every codepoint in bidi visual order, accumulating advances
    and pair kerning and combining inked glyphs into one tight bbox.
    `family`/`slant`/`weight`/`size`/`cache` serve only
    _resolve_glyph's fallback lookup; `face` determines the rest.
    """
    var pen_x = 0.0
    var min_x = 1.0e18
    var max_x = -1.0e18
    var min_y = 1.0e18
    var max_y = -1.0e18
    var any_ink = False
    var previous = -1
    for cp in _visual_codepoints(line_text):
        var codepoint = Int(cp)
        if kerning and previous >= 0:
            pen_x += _kern_offset(face, previous, codepoint)
        previous = codepoint
        var gm = _resolve_glyph_metrics(
            face, family, slant, weight, size, codepoint, cache
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
        var line_text = String(raw_lines[i])
        var measured = _measure_line(
            face[], line_text, family, slant, weight, size, kerning, cache
        )
        var baseline_y = Float64(i) * line_height
        var x_offset = 0.0
        if align == TextAlign.CENTER:
            x_offset = -measured.advance / 2.0
        elif align == TextAlign.RIGHT:
            x_offset = -measured.advance
        var layout = _LineLayout(
            line_text,
            x_offset,
            baseline_y,
            measured.x_bearing,
            measured.y_bearing,
            measured.width,
            measured.height,
        )
        if layout.has_ink():
            any_ink = True
        lines.append(layout)

    var c = cos(rotation)
    var s = sin(rotation)
    var rot_min_x = 1.0e18
    var rot_max_x = -1.0e18
    var rot_min_y = 1.0e18
    var rot_max_y = -1.0e18
    for line in lines:
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

    Returns:
        `text`'s width/height/advance at that size.
    """
    var cache = FontCache()
    return measure_text(text, size, family, slant, weight, kerning, cache=cache)


def measure_text(
    text: String,
    size: Float64,
    family: String = "Sans",
    slant: FontSlant = FontSlant.NORMAL,
    weight: FontWeight = FontWeight.NORMAL,
    kerning: Bool = True,
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
        cache: Shared cache for font resolution and parsed faces.

    Returns:
        `text`'s width/height/advance at that size.
    """
    var face = cache.resolve_face(family, slant, weight, size)
    var measured = _measure_line(
        face[], text, family, slant, weight, size, kerning, cache
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
        cache: Shared cache for font resolution and parsed faces.

    Returns:
        The block's anchor-relative bounding box.
    """
    if text == "":
        return TextBlockBounds(0.0, 0.0, 0.0, 0.0)
    var block = _layout_block(
        text, size, family, slant, weight, rotation, align, kerning, cache
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
        if cmd.kind == _MOVE_TO:
            out.move_to(
                _rotate_translate_x(cmd.p1.x, cmd.p1.y, c, s, anchor_x),
                _rotate_translate_y(cmd.p1.x, cmd.p1.y, c, s, anchor_y),
            )
        elif cmd.kind == _LINE_TO:
            out.line_to(
                _rotate_translate_x(cmd.p1.x, cmd.p1.y, c, s, anchor_x),
                _rotate_translate_y(cmd.p1.x, cmd.p1.y, c, s, anchor_y),
            )
        elif cmd.kind == _QUAD_TO:
            out.quad_curve_to(
                _rotate_translate_x(cmd.p1.x, cmd.p1.y, c, s, anchor_x),
                _rotate_translate_y(cmd.p1.x, cmd.p1.y, c, s, anchor_y),
                _rotate_translate_x(cmd.p2.x, cmd.p2.y, c, s, anchor_x),
                _rotate_translate_y(cmd.p2.x, cmd.p2.y, c, s, anchor_y),
            )
        elif cmd.kind == _CUBIC_TO:
            out.cubic_curve_to(
                _rotate_translate_x(cmd.p1.x, cmd.p1.y, c, s, anchor_x),
                _rotate_translate_y(cmd.p1.x, cmd.p1.y, c, s, anchor_y),
                _rotate_translate_x(cmd.p2.x, cmd.p2.y, c, s, anchor_x),
                _rotate_translate_y(cmd.p2.x, cmd.p2.y, c, s, anchor_y),
                _rotate_translate_x(cmd.p3.x, cmd.p3.y, c, s, anchor_x),
                _rotate_translate_y(cmd.p3.x, cmd.p3.y, c, s, anchor_y),
            )
        else:  # _CLOSE
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
    mut cache: FontCache,
) raises:
    """`draw_text` under a canvas transform that is more than a
    translation. The block is laid out in user space exactly as the
    untransformed call lays it out, and each glyph's outline goes
    through one matrix -- the block rotation about the anchor, the
    anchor's translation, then the canvas transform -- and is filled
    directly. The glyph mask cache holds glyphs at one scale and
    orientation, so it is not used here.
    """
    var block = _layout_block(
        text, size, family, slant, weight, rotation, align, kerning, cache
    )
    if not block.any_ink:
        return
    var face = cache.resolve_face(family, slant, weight, size)
    var placement = (
        Matrix2D.rotation(rotation)
        .then(Matrix2D.translation(x, y))
        .then(matrix)
    )
    var saved = canvas._take_transform()
    try:
        for line in block.lines:
            if line.text == "":
                continue
            var pen_x = line.x
            var previous = -1
            for codepoint in _visual_codepoints(line.text):
                if kerning and previous >= 0:
                    pen_x += _kern_offset(face[], previous, codepoint)
                previous = codepoint
                var g = _resolve_glyph(
                    face[],
                    family,
                    slant,
                    weight,
                    size,
                    codepoint,
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
    except e:
        canvas._set_transform(saved)
        raise e
    canvas._set_transform(saved)


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
    var left = offset_x + mask.origin_x
    for row in range(mask.height):
        var py = offset_y + mask.origin_y + row
        var region = canvas.effective_fill_rect(left, py, mask.width, 1)
        if region[2] == 0 or region[3] == 0:
            continue
        var lo = region[0] - left
        var hi = lo + region[2]
        var base = row * mask.width
        for mx in range(lo, hi):
            var covered = Int(mask.counts[base + mx])
            if covered == 0:
                continue
            var alpha = UInt8(
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
    codepoint: Int,
    frac_x: Float64,
    frac_y: Float64,
    mut cache: FontCache,
) raises -> _GlyphMask:
    """A glyph's advance and coverage with its origin at (frac_x,
    frac_y), both in [0, 1): the outline `_resolve_glyph` would build
    for the render pass, swept with the same fill rule, sample grid and
    curve flattening `fill_path_aa` applies to it, kept as counts.
    """
    var g = _resolve_glyph(
        primary, family, slant, weight, size, codepoint, frac_x, frac_y, cache
    )
    if not (g.metrics.width > 0.0 and g.metrics.height > 0.0):
        return _GlyphMask(
            g.metrics.advance, _CoverageMask(List[UInt8](), 0, 0, 0, 0, 16)
        )
    return _GlyphMask(
        g.metrics.advance,
        _path_coverage_counts(g.path, FillRule.NONZERO, 4, 0),
    )


def _draw_cached_glyph(
    mut canvas: Canvas,
    mut primary: TTFFace,
    family: String,
    slant: FontSlant,
    weight: FontWeight,
    size: Float64,
    codepoint: Int,
    origin_x: Float64,
    origin_y: Float64,
    key_prefix: String,
    color: Color,
    mut cache: FontCache,
) raises -> Float64:
    """Composite one glyph with its origin at (origin_x, origin_y)
    through the cache, rasterizing it on a miss, and return its
    advance. The key is the face, size and codepoint plus the origin's
    sub-pixel part in 1/`_SUBPIXEL_STEPS` px; the whole-pixel part
    becomes the composite offset. A whole-pixel origin rasterizes at
    step 0, exactly where the direct fill would.
    """
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
    var key = (
        key_prefix
        + String(codepoint)
        + "|"
        + String(step_x)
        + "|"
        + String(step_y)
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
                codepoint,
                frac_x,
                frac_y,
                cache,
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
        text, size, family, slant, weight, rotation, align, kerning, cache
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
        for line in block.lines:
            if line.text == "":
                continue
            var pen_x = line.x
            var previous = -1
            for codepoint in _visual_codepoints(line.text):
                if kerning and previous >= 0:
                    pen_x += _kern_offset(face[], previous, codepoint)
                previous = codepoint
                pen_x += _draw_cached_glyph(
                    canvas,
                    face[],
                    family,
                    slant,
                    weight,
                    size,
                    codepoint,
                    x + pen_x,
                    y + line.y,
                    key_prefix,
                    color,
                    cache,
                )
        return

    var c = cos(rotation)
    var s = sin(rotation)
    var anchor_x = x
    var anchor_y = y

    for line in block.lines:
        if line.text == "":
            continue
        var pen_x = line.x
        var previous = -1
        for codepoint in _visual_codepoints(line.text):
            if kerning and previous >= 0:
                pen_x += _kern_offset(face[], previous, codepoint)
            previous = codepoint
            var g = _resolve_glyph(
                face[],
                family,
                slant,
                weight,
                size,
                codepoint,
                pen_x,
                line.y,
                cache,
            )
            if g.metrics.width > 0.0 and g.metrics.height > 0.0:
                var placed = _place_glyph_path(g.path, c, s, anchor_x, anchor_y)
                fill_path_aa(canvas, placed, color, FillRule.NONZERO)
            pen_x += g.metrics.advance
