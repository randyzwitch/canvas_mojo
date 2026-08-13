"""Text rendering -- the one place `canvas` reaches outside the stdlib.

Everywhere else in this package is hand-rolled, stdlib-only, understood
end to end (see the root README.md). Text is the deliberate exception:
rendering real system fonts well -- hinting, correct font matching,
Unicode shaping -- is its own large, mature subsystem, not worth
rebuilding from scratch (an earlier from-scratch TrueType parser/
rasterizer was explored and then deleted once this existed -- see
the wiki's `text.mojo` entry). Instead this wraps
`third_party/cairo_mojo` (a vendored, third-party Mojo binding to
Cairo -- see its VENDORED.md for provenance and why it's vendored
rather than a pixi dependency), which reaches real system fonts via
Cairo's "toy" text API (font-name matching through fontconfig,
rasterization and hinting through FreeType) -- both already installed
as transitive dependencies on this machine, not new system
requirements introduced by this package.

Cairo renders into its own ARGB32 surface; this module's real job is
converting that into canvas pixels (unpremultiplying Cairo's
premultiplied-alpha output and blitting it onto a Canvas through the
same set_pixel() every other primitive uses, so translucent text
composites correctly over whatever's already on the canvas), plus
layout Cairo's own toy text API doesn't do for you: multi-line text
(Cairo has no line-break handling -- "\\n" measures as whatever glyph
the font maps it to, not a break) and per-line alignment.

`draw_text`'s (x, y) is the text baseline's left end for LEFT
alignment -- Cairo's own `move_to` + `show_text` convention, kept as
the anchor's meaning rather than inventing a top-left-corner
convention like fill_rect's, because baseline positioning is what
every text API (and every font) actually means by "where text goes."
CENTER/RIGHT shift each line's own horizontal position relative to
that same anchor -- see TextAlign.

Rotation and multi-line share one code path with the plain single-
line case, not three: every line's ink corners get rotated around the
shared (x, y) anchor and combined into one bounding box that sizes a
single scratch surface, then every line is drawn into that same
rotated Cairo transform. With one line and rotation=0.0, this
reduces exactly to what a simpler single-purpose implementation would
have done -- confirmed by direct comparison, not just argued (see
canvas_mojo/tests/test_text.mojo).

A second real, confirmed bug, independent of the unsafe_data_ptr() one
documented below, and root-caused this time, not just empirically
patched around: `Context.text_extents(text: String)` and
`Context.show_text(text: String)` -- cairo_mojo's own convenience
wrappers -- silently measure/draw as empty (extents come back
width=height=0, nothing gets drawn) for any String that isn't a
compile-time literal, once its length crosses roughly 20 bytes. A
Mojo String's own byte_length() and printed content are completely
correct the entire time -- this isn't a corrupted String, only a
String that these two specific wrapper methods' internal
`text.as_c_string_slice().unsafe_ptr()` marshaling mishandles. Traced
by elimination: confirmed present regardless of *how* the String was
built (`.split()`, manual byte-range slicing, char-by-char
concatenation, even a deliberately over-capacity fresh allocation all
still triggered it) as long as it wasn't a literal -- ruling out every
one of those construction methods as the cause, not just the first
one tried. The actual fix skips both wrapper methods entirely for
text content: `_c_string()` manually builds a NUL-terminated
`UnsafePointer[c_char]` buffer, and `_text_extents()`/`_show_text()`
call cairo_mojo's own *raw* FFI bindings (`_bindings.cairo_text_extents`/
`cairo_show_text`) directly with it, bypassing `as_c_string_slice()`
altogether. Verified deterministic and correct across repeated runs,
for both a previously-broken 23-byte string and a previously-working
1-byte one together, not just whichever one motivated the fix.
"""

from std.ffi import c_char, c_uchar
from std.math import ceil, cos, floor, sin

from cairo_mojo import Context, FontSlant, FontWeight, Format, ImageSurface, TextExtents
from cairo_mojo._bindings import (
    cairo_show_text as _raw_cairo_show_text,
    cairo_text_extents as _raw_cairo_text_extents,
    cairo_text_extents_t as _RawTextExtents,
)

from canvas_mojo.buffer import Canvas
from canvas_mojo.color import Color
from canvas_mojo.text_align import TextAlign

# Padding (pixels) around Cairo's own ink extents when sizing the
# scratch surface glyphs are rendered into. Ink extents are a tight
# bound on non-AA-fringe coverage; without margin, antialiased pixels
# right at the ink's edge would be clipped by the surface boundary.
#
# Also stands between real ink and a real, confirmed bug (see
# _BORDER_ROWS_TO_DISTRUST below) -- keep these two margin constants
# in sync; _INK_MARGIN must stay >= _BORDER_ROWS_TO_DISTRUST + 1 so
# glyph ink is never placed in a row this module refuses to read back.
comptime _INK_MARGIN = 3

# unsafe_data_ptr()'s first 16 bytes read back as non-deterministic
# garbage on *every* ImageSurface tested -- confirmed via a probe on a
# surface that was never drawn to at all (should be all-zero per
# Cairo's own documented guarantee), reproduced across surface sizes
# from 9x34 up to 200x200, with different random-looking bytes each
# run at the same fixed offsets. write_to_png (which reads the same
# buffer natively in Cairo's own C code, not through this Mojo
# pointer) round-trips clean, so the real pixel data is correct -- the
# bug is specifically in reading it back through unsafe_data_ptr(),
# either in this vendored binding or in Mojo's own UnsafePointer
# indexing at a freshly-returned pointer's boundary. Root cause not
# confirmed; the fix here is deliberately narrow and empirical rather
# than a guess: don't trust the first or last row of the buffer at
# all. A smaller surface in the same probe also showed one bad pixel
# near the buffer's tail end, which a larger one didn't -- so both
# ends, not just the start, are treated as untrustworthy.
comptime _BORDER_ROWS_TO_DISTRUST = 1


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
    var x: Float64  # local (unrotated, anchor-relative) move_to X
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
    extraction happened.
    """
    var raw_lines = text.split("\n")

    var probe_surface = ImageSurface(1, 1, Format.ARGB32)
    var probe_ctx = Context(probe_surface)
    probe_ctx.select_font_face(family, slant=slant, weight=weight)
    probe_ctx.set_font_size(size)
    var line_height = probe_ctx.font_extents().height

    var lines = List[_LineLayout](capacity=len(raw_lines))
    var any_ink = False
    for i in range(len(raw_lines)):
        var line_text = String(raw_lines[i])
        var e = _text_extents(probe_ctx, line_text)
        var baseline_y = Float64(i) * line_height
        var x_offset = 0.0
        if align == TextAlign.CENTER:
            x_offset = -e.x_advance / 2.0
        elif align == TextAlign.RIGHT:
            x_offset = -e.x_advance
        var layout = _LineLayout(
            line_text, x_offset, baseline_y, e.x_bearing, e.y_bearing, e.width, e.height
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


def _c_string(text: String) -> UnsafePointer[c_char, MutExternalOrigin]:
    """Manually build a NUL-terminated C string buffer from `text`,
    byte by byte -- see this module's own docstring for the real,
    root-caused bug this exists to route around:
    Context.text_extents()/show_text()'s own `as_c_string_slice()`-
    based marshaling silently mishandles non-literal Strings past
    ~20 bytes. Caller owns the returned buffer and must free() it.
    """
    var bytes = text.as_bytes()
    var n = len(bytes)
    var buf = alloc[c_char](n + 1)
    for i in range(n):
        buf[i] = c_char(bytes[i])
    buf[n] = c_char(0)
    return buf


def _text_extents(ctx: Context, text: String) raises -> TextExtents:
    """`Context.text_extents()`, but through cairo_mojo's raw FFI
    binding with a manually-built C string (see _c_string) instead of
    that method's own broken String marshaling.
    """
    var buf = _c_string(text)
    var extents_ptr = alloc[_RawTextExtents](1)
    _raw_cairo_text_extents(
        ctx.unsafe_raw_ptr(),
        buf.unsafe_mut_cast[target_mut=False]().unsafe_origin_cast[ImmutExternalOrigin](),
        extents_ptr,
    )
    var result = TextExtents.from_ffi(extents_ptr[])
    buf.free()
    extents_ptr.free()
    return result


def _show_text(ctx: Context, text: String) raises:
    """`Context.show_text()`, but through cairo_mojo's raw FFI binding
    -- see _text_extents, same reason.
    """
    var buf = _c_string(text)
    _raw_cairo_show_text(
        ctx.unsafe_raw_ptr(),
        buf.unsafe_mut_cast[target_mut=False]().unsafe_origin_cast[ImmutExternalOrigin](),
    )
    buf.free()


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

    Treats `text` as a single line, matching Cairo's own text_extents:
    no line-break handling for embedded "\\n". For a multi-line
    string's own per-line metrics, split on "\\n" and call this once
    per line yourself -- the same thing draw_text does internally.
    """
    var probe_surface = ImageSurface(1, 1, Format.ARGB32)
    var probe_ctx = Context(probe_surface)
    probe_ctx.select_font_face(family, slant=slant, weight=weight)
    probe_ctx.set_font_size(size)
    var extents = _text_extents(probe_ctx, text)
    return TextMetrics(extents.width, extents.height, extents.x_advance)


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
    in `color` (including `color.a` -- Cairo does the alpha-blended
    rasterization itself, combining requested opacity with per-pixel
    glyph-edge coverage in one pass, rather than this module doing a
    second blend on top of Cairo's).

    `rotation` (radians) rotates the whole block -- every line
    together, not each independently -- around the `(x, y)` anchor.
    This is a different feature from Transform2D's own `rotation`
    (see geometry.mojo): that tilts an entire data-to-pixel coordinate
    mapping; this tilts one rendered text block around its own anchor,
    e.g. for an angled axis-tick label, with everything else on the
    canvas staying upright.

    Two passes, both per line: first measure every line's ink extents
    (Cairo has no "give me the bounding box" query that doesn't
    require a real context) and compute each one's local, anchor-
    relative baseline position (line index * font_extents().height
    apart) and horizontal offset (see TextAlign); combine every line's
    rotated ink corners into one shared bounding box, since a rotated
    multi-line block's overall footprint isn't just each line's own
    unrotated box stacked vertically. Then render everything into one
    scratch surface sized to that box, translated and rotated once,
    with each line drawn via its own precomputed local position -- so
    the whole block rotates together as a rigid unit, not line-by-line
    around each line's own baseline.
    """
    if text == "":
        return

    # With exactly one line and rotation=0.0, cos=1/sin=0 leaves every
    # corner unchanged inside _layout_block, so this reduces to that
    # single line's own unrotated ink box -- one code path for both
    # cases, not two.
    var block = _layout_block(text, size, family, slant, weight, rotation, align)
    if not block.any_ink:
        # Every line whitespace-only/empty -- nothing to blit.
        return
    var rot_min_x = block.rot_min_x
    var rot_max_x = block.rot_max_x
    var rot_min_y = block.rot_min_y
    var rot_max_y = block.rot_max_y

    var render_width = Int(ceil(rot_max_x - rot_min_x)) + 2 * _INK_MARGIN
    var render_height = Int(ceil(rot_max_y - rot_min_y)) + 2 * _INK_MARGIN

    var surface = ImageSurface(render_width, render_height, Format.ARGB32)
    var ctx = Context(surface)
    ctx.select_font_face(family, slant=slant, weight=weight)
    ctx.set_font_size(size)
    ctx.set_source_rgba(
        Float64(color.r) / 255.0,
        Float64(color.g) / 255.0,
        Float64(color.b) / 255.0,
        Float64(color.a) / 255.0,
    )
    # Translate so the anchor's rotated-bbox-relative position lands
    # at (_INK_MARGIN, _INK_MARGIN), THEN rotate -- translate-before-
    # rotate means "rotate around the point just translated to,"
    # confirmed against Cairo's actual behavior via probe, not assumed
    # from the API docs alone.
    ctx.translate(Float64(_INK_MARGIN) - rot_min_x, Float64(_INK_MARGIN) - rot_min_y)
    if rotation != 0.0:
        ctx.rotate(rotation)
    for line in block.lines:
        if line.text == "":
            continue
        ctx.move_to(line.x, line.y)
        _show_text(ctx, line.text)
    surface.flush()

    # Where the scratch surface's (0, 0) lands in canvas space: the
    # combined ink's nominal top-left, offset back by the margin,
    # rounded to whole canvas pixels (canvas has no sub-pixel
    # positioning anywhere else either -- Transform2D.to_pixel() also
    # lands on Points).
    var origin_x = Int(floor(Float64(x) + rot_min_x)) - _INK_MARGIN
    var origin_y = Int(floor(Float64(y) + rot_min_y)) - _INK_MARGIN

    var data = surface.unsafe_data_ptr()
    var stride = surface.stride()

    for sy in range(_BORDER_ROWS_TO_DISTRUST, render_height - _BORDER_ROWS_TO_DISTRUST):
        var row = sy * stride
        for sx in range(render_width):
            var idx = row + sx * 4
            # Cairo ARGB32: premultiplied alpha, native-endian 32-bit
            # words. This machine (and every platform Mojo currently
            # targets) is little-endian, so in memory that's byte
            # order B, G, R, A.
            var b = UInt8(data[idx])
            var g = UInt8(data[idx + 1])
            var r = UInt8(data[idx + 2])
            var a = UInt8(data[idx + 3])
            if a == 0:
                continue
            var unpremul_r = r
            var unpremul_g = g
            var unpremul_b = b
            if a != 255:
                unpremul_r = UInt8((Int(r) * 255) // Int(a))
                unpremul_g = UInt8((Int(g) * 255) // Int(a))
                unpremul_b = UInt8((Int(b) * 255) // Int(a))
            canvas.set_pixel(
                origin_x + sx,
                origin_y + sy,
                Color(unpremul_r, unpremul_g, unpremul_b, a),
            )
