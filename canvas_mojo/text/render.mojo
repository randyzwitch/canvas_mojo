"""Text rendering, natively implemented: font matching (fontconfig,
`font_discovery.mojo`) is this module's only direct FFI dependency;
glyph outlines/metrics come from this package's own TrueType parser
(`ttf.mojo`, via `glyph_outline.mojo`) and rasterization from this
package's own `fill_path_aa` (`path.mojo`). See font_discovery.mojo's
own docstring for the three jobs (font discovery / glyph resolution &
metrics / rasterization) this completes. The glyph path is unhinted --
see ttf.mojo's own module docstring for what that means for exact
glyph metrics.

Glyphs fill directly onto the target `Canvas` through the same
`fill_path_aa` every other filled shape in this package uses, via the
same `set_pixel()` blending path -- translucent text composites
correctly for the same reason translucent fills do, not a
text-specific mechanism.

`draw_text`'s (x, y) is the text baseline's left end for LEFT
alignment -- matching every mainstream text API's own convention for
"where text goes," rather than a top-left-corner convention like
fill_rect's. CENTER/RIGHT shift each line's own horizontal position
relative to that same anchor -- see TextAlign.

Rotation and multi-line share one code path with the plain single-
line case, not three: `_layout_block` (measurement) and draw_text's
own render pass both walk each line's glyphs from a shared, anchor-
relative local layout; every glyph's own local pen position (and its
outline, via `glyph_outline.glyph_path`) gets rotated by the same
angle around the shared `(x, y)` anchor and translated into place in
one pass (`_place_glyph_path`), rather than setting a context-wide
transform before drawing. With one line and rotation=0.0, cos=1/sin=0
leaves every point unchanged, so this reduces exactly to what a
simpler single-purpose implementation would do -- confirmed by direct
comparison, not just argued (see tests/test_text.mojo).

Each line's own codepoints go through `bidi.visual_order` before
either measurement or drawing ever sees them (`_visual_codepoints`,
the one shared call site both use) -- mixed Hebrew/Arabic/Latin/digit
text lays out and renders in correct reading order (right-to-left
words, embedded digit runs staying left-to-right, mirrored
parens/brackets) without draw_text or _measure_line needing any
direction-handling logic of their own. See bidi.mojo's own docstring
for exactly what's covered (Hebrew renders fully correctly; Arabic
gets correct ordering and mirroring but not contextual letter-shaping
-- a separate, larger feature not attempted here) and what's
deliberately simplified relative to the full Unicode Bidirectional
Algorithm.

Every glyph also goes through font *fallback*, not just the single
family the caller requested (`_resolve_glyph`): if the requested
family's face has no real glyph for a codepoint (`glyph_outline.
has_glyph` -- distinguishing an actual glyph from the font's own
".notdef" placeholder, TrueType glyph index 0), a different font is
resolved for that one character via `font_discovery.
resolve_font_file_for_char`, which constrains fontconfig's own match
to a font that actually contains it -- the same real fallback
mechanism system text stacks rely on, not a hand-rolled substitute.
This matters concretely for a package with no bundled fonts of its
own: a CJK/Cyrillic/symbol character requested under a Latin-only
family renders via whatever font on the system actually has it, if one
is installed, instead of the requested font's own generic empty-box
placeholder -- confirmed directly via probe (a font missing a glyph
falls back to one that has it; a font that already has the glyph is
left alone; a character genuinely missing from every installed font
degrades gracefully to fontconfig's own best-effort match, not an
error). Resolved fallback faces are cached across calls the same as
the primary face is -- see _resolve_glyph's and font_cache.mojo's own
docstrings.

FontSlant/FontWeight are defined in font_discovery.mojo and
re-exported here, so both `from canvas_mojo.text.font_discovery import
FontSlant, FontWeight` and `from canvas_mojo.text.render import
FontSlant, FontWeight` work -- the same re-export convenience
TextAlign has for its home in text_align.mojo.
"""

from std.math import cos, sin
from std.memory import ArcPointer

from canvas_mojo.text.bidi import detect_base_level, visual_order
from canvas_mojo.buffer import Canvas
from canvas_mojo.color import Color
from canvas_mojo.text.font_cache import FontCache
from canvas_mojo.text.font_discovery import FontSlant, FontWeight
from canvas_mojo.text.glyph_outline import face_line_metrics, glyph_metrics, glyph_path, has_glyph, GlyphMetrics
from canvas_mojo.text.ttf import TTFFace
from canvas_mojo.path import (
    fill_path_aa,
    FPoint,
    Path,
    _CLOSE,
    _CUBIC_TO,
    _LINE_TO,
    _MOVE_TO,
    _QUAD_TO,
)
from canvas_mojo.text.text_align import TextAlign


struct TextMetrics(ImplicitlyCopyable, Movable):
    """A single line's measured size. `width`/`height` are its tight
    ink bounding box -- the same measurement draw_text itself sizes
    its scratch surface from. `advance` is the logical cursor-advance
    distance instead -- not the same number, since leading/trailing
    whitespace has zero ink width but nonzero advance; TextAlign's
    CENTER/RIGHT are computed from this, not from width.
    """

    var width: Float64
    var height: Float64
    var advance: Float64

    def __init__(out self, width: Float64, height: Float64, advance: Float64):
        self.width = width
        self.height = height
        self.advance = advance


struct _LineLayout(ImplicitlyCopyable, Movable):
    """One line's layout, computed once in draw_text's first pass and
    reused in its second -- a small struct instead of several parallel
    List[Float64]s (see geometry.mojo's own docstring for why: the
    same "error-prone to keep in sync" problem Point exists to avoid).
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
    """Every line's local layout plus the combined rotated bounding
    box around the shared (x, y) anchor -- computed once by
    _layout_block, shared by draw_text (which renders it) and
    measure_text_block (which reports it without rendering), so the
    two can never disagree about where a rotated block's footprint
    actually is. Bounds are in the same local (unrotated-anchor-
    relative, pre-rotation-applied) space _LineLayout's own x/y are:
    already-rotated corner positions, but not yet translated into
    canvas space.
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


def _load_sized_face(
    family: String, slant: FontSlant, weight: FontWeight, size: Float64, mut cache: FontCache
) raises -> ArcPointer[TTFFace]:
    """font_discovery.resolve_font_file (fontconfig, via `cache` -- see
    font_cache.mojo's own docstring) -> ttf.TTFFace (native TrueType
    parsing), sized to `size` pixels -- the one place every measuring/
    drawing entry point below goes to get a ready-to-use face. Both the
    resolved *path* and the parsed, sized face itself are cached (by
    `cache`, across every call sharing it) -- see FontCache.resolve_face's
    own docstring. Returns an `ArcPointer` rather than a `TTFFace`
    directly so a cache hit is a refcount bump, not a copy of the
    face's own multi-hundred-KB font-file buffer; every call site below
    dereferences it with `[]` to get at the `TTFFace` itself.
    """
    return cache.resolve_face(family, slant, weight, size)


struct _LineMetrics(ImplicitlyCopyable, Movable):
    """One line's full measurement -- ink bearing/width/height plus
    total cursor advance. `advance`, not `width`, is what TextAlign's CENTER/RIGHT actually
    center/right-align against (see TextMetrics' own docstring) --
    kept as its own field here rather than folded into _LineLayout,
    since _LineLayout itself never needs to remember it past the
    single x_offset computation that consumes it.
    """

    var x_bearing: Float64
    var y_bearing: Float64
    var width: Float64
    var height: Float64
    var advance: Float64

    def __init__(
        out self, x_bearing: Float64, y_bearing: Float64, width: Float64, height: Float64, advance: Float64
    ):
        self.x_bearing = x_bearing
        self.y_bearing = y_bearing
        self.width = width
        self.height = height
        self.advance = advance

    def has_ink(self) -> Bool:
        return self.width > 0.0 and self.height > 0.0


def _visual_codepoints(line_text: String) -> List[Int]:
    """`line_text`'s own codepoints, reordered left-to-right-drawable
    via `bidi.visual_order` -- both `_measure_line` and draw_text's
    own render pass walk this instead of `line_text.codepoints()`
    directly, so mixed Hebrew/Arabic/Latin/digit text lays out and
    draws correctly without either of them needing their own
    direction-handling logic (see bidi.mojo's own docstring for
    exactly what this does and doesn't cover). A pure left-to-right
    line's own bidi.visual_order call is a no-op (every codepoint
    stays at the same even level, so `_reorder_indices` never
    reverses anything) -- confirmed directly, not just argued (see
    tests/test_bidi.mojo).
    """
    var codepoints = List[Int](capacity=line_text.byte_length())
    for cp in line_text.codepoints():
        codepoints.append(Int(cp))
    var base_level = detect_base_level(codepoints)
    return visual_order(codepoints, base_level)


struct _PositionedGlyph(Movable):
    """One glyph's own metrics plus its outline, already positioned at
    the (pen_x, pen_y) it was resolved for -- see _resolve_glyph's own
    docstring for why these two are bundled into one result instead of
    two separate calls at each call site.
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
    """This one character's metrics and outline, from `primary` if it
    actually has a glyph for `codepoint`, or from a fallback font
    otherwise (`font_discovery.resolve_font_file_for_char`, via
    `cache` -- see that function's and font_cache.mojo's own
    docstrings for how fontconfig's own charset-aware matching picks a
    font that actually contains the character, e.g. CJK text requested
    under a Latin-only family). Both the resolved fallback *path* and
    the parsed fallback *face* are cached (by `cache`, across every
    call sharing it), so a string with several fallback glyphs for the
    same missing codepoint only asks fontconfig, and only parses that
    fallback font file, once -- see FontCache.resolve_face_for_char's
    own docstring.

    Metrics and outline are resolved together, from the same face, in
    one call -- not two separate has_glyph-gated calls at each of this
    module's own two glyph-walking sites (_measure_line, draw_text's
    render pass) -- so they can never disagree about which face's data
    they came from.
    """
    if has_glyph(primary, codepoint):
        return _PositionedGlyph(glyph_metrics(primary, codepoint), glyph_path(primary, codepoint, pen_x, pen_y))

    var fallback = cache.resolve_face_for_char(family, slant, weight, codepoint, size)
    return _PositionedGlyph(
        glyph_metrics(fallback[], codepoint), glyph_path(fallback[], codepoint, pen_x, pen_y)
    )


def _measure_line(
    mut face: TTFFace,
    line_text: String,
    family: String,
    slant: FontSlant,
    weight: FontWeight,
    size: Float64,
    mut cache: FontCache,
) raises -> _LineMetrics:
    """One line's ink bounding box (x_bearing/y_bearing/width/height,
    all zero for a blank/whitespace-only line) and total advance --
    walks every Unicode codepoint (in bidi visual order -- see _visual_codepoints),
    accumulating each glyph's own advance and combining every glyph
    that actually has ink into one tight bbox. `family`/`slant`/
    `weight`/`size`/`cache` are only needed for _resolve_glyph's own
    font-fallback lookup (see its own docstring) -- `face` itself
    already determines everything else.
    """
    var pen_x = 0.0
    var min_x = 1.0e18
    var max_x = -1.0e18
    var min_y = 1.0e18
    var max_y = -1.0e18
    var any_ink = False
    for cp in _visual_codepoints(line_text):
        var gm = _resolve_glyph(face, family, slant, weight, size, Int(cp), pen_x, 0.0, cache).metrics
        if gm.width > 0.0 and gm.height > 0.0:
            var left = pen_x + gm.bearing_x
            var right = left + gm.width
            # gm.bearing_y is positive *upward* from the baseline
            # (TrueType's own y-up font-design-unit convention, see
            # ttf.mojo); local layout space here is y-down (matching
            # every other pixel-space convention in this package), so
            # the ink's local top is the negated bearing.
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
    mut cache: FontCache,
) raises -> _BlockLayout:
    """The "two passes" layout math draw_text's own docstring
    describes: measure every "\\n"-separated line, compute each one's
    local anchor-relative position, then rotate every line's 4 ink
    corners around the shared anchor and combine into one bounding
    box. Extracted so draw_text and measure_text_block share the exact
    same math rather than one being a second, independently-
    maintained copy of the other -- confirmed by draw_text's own
    rotation/multi-line tests still passing unchanged once this
    extraction happened (long before this module went native; that
    property didn't change in the switch).
    """
    var raw_lines = text.split("\n")

    var face = _load_sized_face(family, slant, weight, size, cache)
    var line_height = face_line_metrics(face[]).line_height

    var lines = List[_LineLayout](capacity=len(raw_lines))
    var any_ink = False
    for i in range(len(raw_lines)):
        var line_text = String(raw_lines[i])
        var measured = _measure_line(face[], line_text, family, slant, weight, size, cache)
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
        var corners_u: List[Float64] = [bx, bx + line.width, bx, bx + line.width]
        var corners_v: List[Float64] = [by, by, by + line.height, by + line.height]
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

    return _BlockLayout(lines^, any_ink, rot_min_x, rot_max_x, rot_min_y, rot_max_y)


def measure_text(
    text: String,
    size: Float64,
    family: String = "Sans",
    slant: FontSlant = FontSlant.NORMAL,
    weight: FontWeight = FontWeight.NORMAL,
) raises -> TextMetrics:
    """Measure `text` at `size` points in `family` without drawing it
    -- the same measurement draw_text uses internally to size its
    scratch surface, exposed so a caller can lay text out (e.g. center
    it against something else entirely) before committing to draw it.

    Treats `text` as a single line, matching TextAlign's own single-
    line convention: no line-break handling for embedded "\\n". For a
    multi-line string's own per-line metrics, split on "\\n" and call
    this once per line yourself -- the same thing draw_text does
    internally via _measure_line.

    Resolves its own font fresh every call (see font_cache.mojo's own
    docstring on why that's real, measured cost, not a hypothetical
    one) -- for repeated calls sharing a font, use the `cache=`
    overload below instead, passing one `FontCache` you keep reusing.
    """
    var cache = FontCache()
    return measure_text(text, size, family, slant, weight, cache=cache)


def measure_text(
    text: String,
    size: Float64,
    family: String = "Sans",
    slant: FontSlant = FontSlant.NORMAL,
    weight: FontWeight = FontWeight.NORMAL,
    *,
    mut cache: FontCache,
) raises -> TextMetrics:
    """Like measure_text above, but resolving fonts through `cache`
    (see font_cache.mojo's own docstring) instead of fresh every call
    -- the call to reach for when measuring many strings that share a
    font, e.g. every tick label on one chart axis. Pass the same
    `FontCache` to every measure_text/draw_text/measure_text_block call
    in the batch to actually get the reuse.
    """
    var face = _load_sized_face(family, slant, weight, size, cache)
    var measured = _measure_line(face[], text, family, slant, weight, size, cache)
    return TextMetrics(measured.width, measured.height, measured.advance)


struct TextBlockBounds(ImplicitlyCopyable, Movable):
    """The axis-aligned bounding box draw_text's rendered ink would
    occupy for this exact text/rotation/align/font combination,
    anchor-relative: `x`/`y` are the box's top-left corner relative to
    draw_text's own `(x, y)` anchor (either can be negative -- e.g.
    TextAlign.RIGHT-aligned text extends left of the anchor, and a
    label rotated "upward" extends above it), `width`/`height` its
    size. `x + width`/`y + height` is the box's bottom-right corner,
    same anchor-relative convention.

    This is the exact rotated bounding box draw_text's own layout math
    computes internally (via the shared _layout_block -- see its own
    docstring for why that's shared rather than re-derived here), just
    reported instead of rendered: for axis-label layout decisions --
    how much margin a rotated tick label needs, whether it would
    overlap a neighboring label or the plot area -- made before
    committing to draw, the same "measure first" motivation
    measure_text already exists for, generalized to account for
    rotation and multi-line blocks, both of which change a text
    block's footprint in ways a single line's own unrotated
    width/height (TextMetrics) can't capture.
    """

    var x: Float64
    var y: Float64
    var width: Float64
    var height: Float64

    def __init__(out self, x: Float64, y: Float64, width: Float64, height: Float64):
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
) raises -> TextBlockBounds:
    """The bounding box draw_text(canvas, x, y, text, ..., rotation=
    rotation, align=align) would render into, anchor-relative and
    without actually drawing -- see TextBlockBounds' own docstring.

    An empty string, or one that's every line whitespace-only, has no
    ink at all -- returns a zero-sized box at the anchor (0, 0, 0, 0),
    matching draw_text's own no-op behavior for the identical input
    rather than reporting some nonzero "advance" box a caller might
    mistake for real ink.

    Resolves its own font fresh every call -- see measure_text's own
    docstring on the `cache=` overload below for repeated calls
    sharing a font.
    """
    var cache = FontCache()
    return measure_text_block(text, size, family, slant, weight, rotation, align, cache=cache)


def measure_text_block(
    text: String,
    size: Float64,
    family: String = "Sans",
    slant: FontSlant = FontSlant.NORMAL,
    weight: FontWeight = FontWeight.NORMAL,
    rotation: Float64 = 0.0,
    align: TextAlign = TextAlign.LEFT,
    *,
    mut cache: FontCache,
) raises -> TextBlockBounds:
    """Like measure_text_block above, but resolving fonts through
    `cache` (see font_cache.mojo's own docstring) instead of fresh
    every call -- see measure_text's own `cache=` overload docstring.
    """
    if text == "":
        return TextBlockBounds(0.0, 0.0, 0.0, 0.0)
    var block = _layout_block(text, size, family, slant, weight, rotation, align, cache)
    if not block.any_ink:
        return TextBlockBounds(0.0, 0.0, 0.0, 0.0)
    return TextBlockBounds(
        block.rot_min_x,
        block.rot_min_y,
        block.rot_max_x - block.rot_min_x,
        block.rot_max_y - block.rot_min_y,
    )


def _rotate_translate_x(x: Float64, y: Float64, c: Float64, s: Float64, tx: Float64) -> Float64:
    return tx + x * c - y * s


def _rotate_translate_y(x: Float64, y: Float64, c: Float64, s: Float64, ty: Float64) -> Float64:
    return ty + x * s + y * c


def _place_glyph_path(local_path: Path, c: Float64, s: Float64, anchor_x: Float64, anchor_y: Float64) raises -> Path:
    """Rotate every point of `local_path` (built in glyph-local,
    anchor-relative, unrotated space via glyph_outline.glyph_path) by
    the block's own rotation and translate by draw_text's `(x, y)`
    anchor -- composes the whole text block's rotation with its anchor
    position in one pass (see this module's own docstring). Path has
    no public "map every point" API and this is
    the only place that needs one -- reaches into Path.commands
    directly instead, the same established pattern svg.mojo's own SVG-
    emission code already uses for the identical reason.
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
) raises:
    """Render `text` (one or more "\\n"-separated lines) anchored at
    `(x, y)` in `family` at `size` points, compositing onto `canvas`
    in `color` (including `color.a` -- fill_path_aa's own per-pixel AA
    coverage combines with the requested color's own alpha through the
    identical set_pixel() blend every other filled shape in this
    package already uses, not a text-specific mechanism).

    `rotation` (radians) rotates the whole block -- every line
    together, not each independently -- around the `(x, y)` anchor.
    This is a different feature from Transform2D's own `rotation`
    (see geometry.mojo): that tilts an entire data-to-pixel coordinate
    mapping; this tilts one rendered text block around its own anchor,
    e.g. for an angled axis-tick label, with everything else on the
    canvas staying upright.

    Two passes: _layout_block first measures every line's ink extents
    and computes each one's local, anchor-relative baseline position
    (line index * line_height apart) and horizontal offset (see
    TextAlign) -- shared with measure_text_block so the two can never
    disagree about where a block's footprint is. Then every line's own
    glyphs are walked a second time, each one's outline built in local
    space (glyph_outline.glyph_path) and placed into canvas space in
    one rotate-plus-translate pass (_place_glyph_path) before filling
    directly onto `canvas` via fill_path_aa -- no intermediate scratch
    surface.

    Resolves its own font fresh, twice (once for each of the two
    passes above) -- see measure_text's own docstring on the `cache=`
    overload below, which also fixes that within-one-call duplication,
    not just repeat calls.
    """
    var cache = FontCache()
    draw_text(canvas, x, y, text, color, size, family, slant, weight, rotation, align, cache=cache)


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
    *,
    mut cache: FontCache,
) raises:
    """Like draw_text above, but resolving fonts through `cache` (see
    font_cache.mojo's own docstring) instead of fresh every call --
    see measure_text's own `cache=` overload docstring for when to
    reach for this. Also fixes a redundancy the uncached overload
    still has even for one single call: draw_text's own two passes
    (_layout_block's measuring pass, then the render pass below) each
    resolve the same face -- with `cache` shared between them, the
    second resolution is a cache hit instead of a second fontconfig
    round-trip.
    """
    if text == "":
        return

    # With exactly one line and rotation=0.0, cos=1/sin=0 leaves every
    # corner unchanged inside _layout_block, so this reduces to that
    # single line's own unrotated ink box -- one code path for both
    # cases, not two.
    var block = _layout_block(text, size, family, slant, weight, rotation, align, cache)
    if not block.any_ink:
        # Every line whitespace-only/empty -- nothing to draw.
        return

    var face = _load_sized_face(family, slant, weight, size, cache)
    var c = cos(rotation)
    var s = sin(rotation)
    var anchor_x = Float64(x)
    var anchor_y = Float64(y)

    for line in block.lines:
        if line.text == "":
            continue
        var pen_x = line.x
        for codepoint in _visual_codepoints(line.text):
            var g = _resolve_glyph(face[], family, slant, weight, size, codepoint, pen_x, line.y, cache)
            if g.metrics.width > 0.0 and g.metrics.height > 0.0:
                var placed = _place_glyph_path(g.path, c, s, anchor_x, anchor_y)
                fill_path_aa(canvas, placed, color)
            pen_x += g.metrics.advance
