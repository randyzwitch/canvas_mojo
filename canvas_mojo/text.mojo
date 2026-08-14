"""Text rendering -- once the one place `canvas` reached outside the
stdlib, now fully native: font matching (fontconfig, `font_discovery.
mojo`), glyph outlines/metrics (FreeType, `glyph_outline.mojo`), and
rasterization (this package's own `fill_path_aa`, `path.mojo`) are all
direct, hand-verified code, not a wrapped third-party rendering
engine. `third_party/cairo_mojo` is no longer a dependency of this
module -- see the wiki's `text.mojo` entry for the earlier from-scratch
TrueType exploration this supersedes a second time, and font_discovery.
mojo's own docstring for the 4-job breakdown (font discovery / glyph
resolution & metrics / hinting / rasterization) this completes: hinting
came for free at `FT_Load_Glyph`'s default flags (see glyph_outline.
mojo), and rasterization was already built for other shapes before
text needed it.

Removing Cairo also removes a whole category of workaround code that
used to live here: no scratch ARGB32 surface, no premultiply/
unpremultiply dance, no `unsafe_data_ptr()` boundary-garbage bug to
route around, no `as_c_string_slice()` String-marshaling bug to route
around either. Glyphs fill directly onto the target `Canvas` through
the same `fill_path_aa` every other filled shape in this package uses,
via the same `set_pixel()` blending path -- translucent text composites
correctly for the same reason translucent fills always have here, not
a text-specific mechanism.

`draw_text`'s (x, y) is the text baseline's left end for LEFT
alignment -- matching every mainstream text API's own convention for
"where text goes," kept as the anchor's meaning rather than inventing
a top-left-corner convention like fill_rect's. CENTER/RIGHT shift each
line's own horizontal position relative to that same anchor -- see
TextAlign.

Rotation and multi-line share one code path with the plain single-
line case, not three: `_layout_block` (measurement) and draw_text's
own render pass both walk each line's glyphs from a shared, anchor-
relative local layout; every glyph's own local pen position (and its
outline, via `glyph_outline.glyph_path`) gets rotated by the same
angle around the shared `(x, y)` anchor and translated into place in
one pass (`_place_glyph_path`), rather than Cairo's own approach of
setting a context-wide transform before drawing. With one line and
rotation=0.0, cos=1/sin=0 leaves every point unchanged, so this
reduces exactly to what a simpler single-purpose implementation would
have done -- confirmed by direct comparison, not just argued (see
canvas_mojo/tests/test_text.mojo).

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

Public FontSlant/FontWeight (re-exported here from font_discovery.mojo)
replace what used to be cairo_mojo's own identically-shaped types --
same NORMAL/ITALIC/OBLIQUE and NORMAL/BOLD values, just no longer
imported from a third-party binding. Any existing call site that did
`from cairo_mojo import FontSlant, FontWeight` needs to switch to
`from canvas_mojo.font_discovery import FontSlant, FontWeight` (or
`from canvas_mojo.text import FontSlant, FontWeight` -- both work, the
same re-export convenience TextAlign's own docstring already
established for its move into text_align.mojo).
"""

from std.math import ceil, cos, sin

from canvas_mojo.bidi import detect_base_level, visual_order
from canvas_mojo.buffer import Canvas
from canvas_mojo.color import Color
from canvas_mojo.font_discovery import FontSlant, FontWeight, resolve_font_file
from canvas_mojo.freetype_face import FreeTypeFace
from canvas_mojo.glyph_outline import face_line_metrics, glyph_metrics, glyph_path
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
from canvas_mojo.text_align import TextAlign


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


def _load_sized_face(family: String, slant: FontSlant, weight: FontWeight, size: Float64) raises -> FreeTypeFace:
    """font_discovery.resolve_font_file (fontconfig) -> freetype_face.
    FreeTypeFace (FreeType), sized to `size` pixels -- the one place
    every measuring/drawing entry point below goes to get a ready-to-
    use face. A fresh face per call, not a shared/cached one -- the
    same "no global handle available yet" constraint font_discovery.
    mojo's own loader already documents, not a new limitation this
    introduces.
    """
    var font_path = resolve_font_file(family, slant, weight)
    var face = FreeTypeFace(font_path)
    face.set_pixel_size(Int(ceil(size)))
    return face^


struct _LineMetrics(ImplicitlyCopyable, Movable):
    """One line's full measurement -- ink bearing/width/height plus
    total cursor advance, the native equivalent of Cairo's own
    `TextExtents` (x_bearing/y_bearing/width/height/x_advance).
    `advance`, not `width`, is what TextAlign's CENTER/RIGHT actually
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
    canvas_mojo/tests/test_bidi.mojo).
    """
    var codepoints = List[Int](capacity=line_text.byte_length())
    for cp in line_text.codepoints():
        codepoints.append(Int(cp))
    var base_level = detect_base_level(codepoints)
    return visual_order(codepoints, base_level)


def _measure_line(mut face: FreeTypeFace, line_text: String) raises -> _LineMetrics:
    """One line's ink bounding box (x_bearing/y_bearing/width/height,
    all zero for a blank/whitespace-only line) and total advance,
    native equivalent of Cairo's own `text_extents()` -- walks every
    Unicode codepoint (in bidi visual order -- see _visual_codepoints),
    accumulating each glyph's own advance and combining every glyph
    that actually has ink into one tight bbox.
    """
    var pen_x = 0.0
    var min_x = 1.0e18
    var max_x = -1.0e18
    var min_y = 1.0e18
    var max_y = -1.0e18
    var any_ink = False
    for cp in _visual_codepoints(line_text):
        var gm = glyph_metrics(face, Int(cp))
        if gm.width > 0.0 and gm.height > 0.0:
            var left = pen_x + gm.bearing_x
            var right = left + gm.width
            # FreeType's horiBearingY is positive *upward* from the
            # baseline; local layout space here is y-down (matching
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

    var face = _load_sized_face(family, slant, weight, size)
    var line_height = face_line_metrics(face).line_height

    var lines = List[_LineLayout](capacity=len(raw_lines))
    var any_ink = False
    for i in range(len(raw_lines)):
        var line_text = String(raw_lines[i])
        var measured = _measure_line(face, line_text)
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
    """
    var face = _load_sized_face(family, slant, weight, size)
    var measured = _measure_line(face, text)
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
    """
    if text == "":
        return TextBlockBounds(0.0, 0.0, 0.0, 0.0)
    var block = _layout_block(text, size, family, slant, weight, rotation, align)
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
    position in one pass, the native equivalent of Cairo's own
    translate-then-rotate context transform (see this module's own
    docstring). Path has no public "map every point" API and this is
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
    surface, unlike the Cairo-backed version this replaced.
    """
    if text == "":
        return

    # With exactly one line and rotation=0.0, cos=1/sin=0 leaves every
    # corner unchanged inside _layout_block, so this reduces to that
    # single line's own unrotated ink box -- one code path for both
    # cases, not two.
    var block = _layout_block(text, size, family, slant, weight, rotation, align)
    if not block.any_ink:
        # Every line whitespace-only/empty -- nothing to draw.
        return

    var face = _load_sized_face(family, slant, weight, size)
    var c = cos(rotation)
    var s = sin(rotation)
    var anchor_x = Float64(x)
    var anchor_y = Float64(y)

    for line in block.lines:
        if line.text == "":
            continue
        var pen_x = line.x
        for codepoint in _visual_codepoints(line.text):
            var gm = glyph_metrics(face, codepoint)
            if gm.width > 0.0 and gm.height > 0.0:
                var local_path = glyph_path(face, codepoint, pen_x, line.y)
                var placed = _place_glyph_path(local_path, c, s, anchor_x, anchor_y)
                fill_path_aa(canvas, placed, color)
            pen_x += gm.advance
