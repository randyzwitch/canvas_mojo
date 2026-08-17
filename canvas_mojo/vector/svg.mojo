"""SvgCanvas -- a vector `DrawTarget` (see that trait's own docstring)
that accumulates SVG markup instead of rasterizing into a pixel
buffer. No anti-aliasing math, no coverage sampling, no fill-rule
scanline algorithm -- an SVG renderer (a browser, an image viewer, a
PDF exporter) does all of that itself, at whatever resolution it's
displayed at, which is the entire point: content drawn through this
has no fixed pixel size to get wrong the way `canvas_mojo.Canvas`'s raster
output can (a raster target has to pick a resolution and can blur or
alias when scaled after the fact; a vector target sidesteps that
entirely).

Deliberately minimal, matching `DrawTarget`'s own six methods one for
one -- this is not a general-purpose SVG builder (no gradients, no
general groups/transforms, no clipping); grow it if and when something
concrete needs more of SVG's own surface, the same restraint every
other part of this project has held to. `draw_text`'s own `rotation`
parameter is the one narrow exception -- a per-`<text>`-element
`transform="rotate(...)"`, not a general transform stack -- added when
a real caller (a chart's rotated y-axis title) needed it; see that
method's own docstring.
"""

from std.math import cos, pi, sin

from canvas_mojo.color import Color
from canvas_mojo.vector.draw_target import DrawTarget
from canvas_mojo.geometry import _round_to_int
from canvas_mojo.path import Path, _CLOSE, _CUBIC_TO, _LINE_TO, _MOVE_TO, _QUAD_TO
from canvas_mojo.text.text_align import TextAlign

comptime _HEX_DIGITS = "0123456789abcdef"

# Decimal places every Float64 coordinate/width/size gets formatted
# to -- see _format_svg_float's own docstring for why this exists at
# all (a real, reproducible bug it fixes, not just a tidiness choice).
comptime _SVG_DECIMALS = 3


def _hex_byte(value: UInt8) -> String:
    var v = Int(value)
    # `_HEX_DIGITS` is a fixed, pure-ASCII literal, so a raw UTF-8 byte
    # index (`[byte=...]`) is exactly the character it looks like --
    # plain positional `s[i]` indexing was removed for Mojo `String` in
    # favor of `[byte=]`/`[codepoint=]`/`[grapheme=]` (see the wiki's
    # entry on the Mojo 1.0.0 upgrade this fixed).
    return String(_HEX_DIGITS[byte=v // 16]) + String(_HEX_DIGITS[byte=v % 16])


def _format_svg_float(value: Float64) -> String:
    """Format `value` to exactly `_SVG_DECIMALS` decimal places --
    plain `String(Float64)` isn't safe to use for SVG coordinates: a
    real, reproducible bug, not a hypothetical one, caught by a hand-
    derived test that compared an exact-string assertion against live
    output and failed even though the *math* was right -- the same
    `cx + radius * cos(angle)` expression, compiled as part of this
    larger file rather than a small standalone probe, produced a
    float one ULP away from the value the identical formula gave in
    isolation (confirmed via `python3` and cross-checked against an
    isolated Mojo probe first -- see the wiki for additional information).
    `String(Float64)`'s shortest-round-trip formatting makes that 1-
    ULP difference visible as a different *string*, even though both
    values are the same point to any real display. Rounding to a
    fixed, coarse decimal precision (millipixels -- far finer than any
    real display needs) makes the two collapse to the identical
    string -- the same fixed-precision-rounding fix works for any
    caller hitting `String(Float64)`'s own drift (e.g. `0.1 + 0.2`
    printing extra trailing digits) for tick-label formatting or
    similar, but isn't factored out to be shared with a caller here:
    this package has no downstream dependents of its own to share code
    with (the dependency, if any exists, only ever runs the other way).
    """
    var scale = 1000.0  # 10 ** _SVG_DECIMALS
    var scaled = _round_to_int(value * scale)
    var sign = "-" if scaled < 0 else ""
    var digits = scaled if scaled >= 0 else -scaled
    var int_part = digits // 1000
    var frac_part = digits % 1000

    var frac_str = String(frac_part)
    while frac_str.byte_length() < _SVG_DECIMALS:
        frac_str = "0" + frac_str

    return sign + String(int_part) + "." + frac_str


def _escape_xml_text(text: String) -> String:
    """Escape the five XML-significant characters in text *content*
    (not an attribute value -- `"`/`'` don't need escaping here, only
    inside quoted attributes, which SvgCanvas never puts label text
    into) -- `&` first, always, since escaping the other four each
    introduces a literal `&` of its own that a second `&`-pass would
    then mangle.
    """
    var result = text.replace("&", "&amp;")
    result = result.replace("<", "&lt;")
    result = result.replace(">", "&gt;")
    return result


def _hex_color(color: Color) -> String:
    return "#" + _hex_byte(color.r) + _hex_byte(color.g) + _hex_byte(color.b)


def _path_d(path: Path) -> String:
    """Path.commands -> an SVG `d` attribute string -- a direct
    one-to-one mapping (M/L/Q/C/Z), not a re-derivation: Path's own
    five command kinds are already exactly SVG path's own move/line/
    quadratic/cubic/close commands, absolute coordinates both ways
    (see Path's own docstring: "All coordinates are absolute"),
    so no coordinate-system translation is needed either.
    """
    var d = String("")
    var is_first = True
    for cmd in path.commands:
        if not is_first:
            d += " "
        is_first = False
        if cmd.kind == _MOVE_TO:
            d += "M" + _format_svg_float(cmd.p1.x) + "," + _format_svg_float(cmd.p1.y)
        elif cmd.kind == _LINE_TO:
            d += "L" + _format_svg_float(cmd.p1.x) + "," + _format_svg_float(cmd.p1.y)
        elif cmd.kind == _QUAD_TO:
            d += (
                "Q"
                + _format_svg_float(cmd.p1.x)
                + ","
                + _format_svg_float(cmd.p1.y)
                + " "
                + _format_svg_float(cmd.p2.x)
                + ","
                + _format_svg_float(cmd.p2.y)
            )
        elif cmd.kind == _CUBIC_TO:
            d += (
                "C"
                + _format_svg_float(cmd.p1.x)
                + ","
                + _format_svg_float(cmd.p1.y)
                + " "
                + _format_svg_float(cmd.p2.x)
                + ","
                + _format_svg_float(cmd.p2.y)
                + " "
                + _format_svg_float(cmd.p3.x)
                + ","
                + _format_svg_float(cmd.p3.y)
            )
        else:  # _CLOSE
            d += "Z"
    return d


struct SvgCanvas(DrawTarget, Movable):
    """Accumulates SVG body markup for a `width x height` document.
    `width`/`height` are public fields, the same shape `Canvas`'s own
    are -- `render_svg()`'s ox1/oy1 sentinel resolution reads them the
    same way `render()` reads `Canvas.width`/`.height`.
    """

    var width: Int
    var height: Int
    var _body: String

    def __init__(out self, width: Int, height: Int):
        self.width = width
        self.height = height
        self._body = ""

    def fill_rect(mut self, x: Int, y: Int, width: Int, height: Int, color: Color):
        self._body += (
            '<rect x="'
            + String(x)
            + '" y="'
            + String(y)
            + '" width="'
            + String(width)
            + '" height="'
            + String(height)
            + '" fill="'
            + _hex_color(color)
            + '"/>\n'
        )

    def draw_line_aa(
        mut self, x0: Int, y0: Int, x1: Int, y1: Int, color: Color, width: Float64 = 1.0
    ):
        self._body += (
            '<line x1="'
            + String(x0)
            + '" y1="'
            + String(y0)
            + '" x2="'
            + String(x1)
            + '" y2="'
            + String(y1)
            + '" stroke="'
            + _hex_color(color)
            + '" stroke-width="'
            + _format_svg_float(width)
            + '" stroke-linecap="round"/>\n'
        )

    def fill_circle_aa(mut self, cx: Int, cy: Int, radius: Int, color: Color):
        self._body += (
            '<circle cx="'
            + String(cx)
            + '" cy="'
            + String(cy)
            + '" r="'
            + String(radius)
            + '" fill="'
            + _hex_color(color)
            + '"/>\n'
        )

    def fill_arc_aa(
        mut self,
        cx: Float64,
        cy: Float64,
        radius: Float64,
        start_angle: Float64,
        end_angle: Float64,
        color: Color,
    ):
        """A wedge, drawn as `M center L start-point A ... end-point Z`
        -- the same "line out to the arc, sweep it, line back to
        center" shape `fill_arc_aa`'s own raster coverage math treats
        as the wedge's boundary. `sweep_flag=1` (positive-angle
        direction) with no sign flip: SVG's own coordinate space is
        y-down by default, the same as `canvas`'s, and increasing
        angle already sweeps clockwise in that space (confirmed
        directly for `Mark.ARC`'s own wedges -- see plot.mojo's own
        docstring), so the two conventions already agree.
        """
        var x0 = cx + radius * cos(start_angle)
        var y0 = cy + radius * sin(start_angle)
        var x1 = cx + radius * cos(end_angle)
        var y1 = cy + radius * sin(end_angle)
        var large_arc_flag = 1 if (end_angle - start_angle) > 3.14159265358979 else 0
        self._body += (
            '<path d="M'
            + _format_svg_float(cx)
            + ","
            + _format_svg_float(cy)
            + " L"
            + _format_svg_float(x0)
            + ","
            + _format_svg_float(y0)
            + " A"
            + _format_svg_float(radius)
            + ","
            + _format_svg_float(radius)
            + " 0 "
            + String(large_arc_flag)
            + ",1 "
            + _format_svg_float(x1)
            + ","
            + _format_svg_float(y1)
            + ' Z" fill="'
            + _hex_color(color)
            + '"/>\n'
        )

    def fill_ring_sector_aa(
        mut self,
        cx: Float64,
        cy: Float64,
        inner_radius: Float64,
        outer_radius: Float64,
        start_angle: Float64,
        end_angle: Float64,
        color: Color,
    ):
        """A donut wedge: `M outer-start A ... outer-end L inner-end
        A ... inner-start Z` -- the outer arc swept forward
        (`sweep_flag=1`, same direction/reasoning as `fill_arc_aa`'s
        own), then a radial line inward, then the inner arc swept
        *backward* (`sweep_flag=0`) back to the start angle, closing
        the ring boundary in one continuous loop -- the same "outer
        arc forward + inner arc backward, combined into one boundary"
        shape `canvas_mojo.primitives.fill_ring_sector`'s own docstring
        describes for the raster path, expressed as two SVG arc
        commands instead of two point-sampled polylines. Hand-derived
        (and cross-checked via python3) against a concrete 90-degree
        wedge before trusting this shape -- see tests/test_svg.
        mojo's own test.
        """
        var outer_x0 = cx + outer_radius * cos(start_angle)
        var outer_y0 = cy + outer_radius * sin(start_angle)
        var outer_x1 = cx + outer_radius * cos(end_angle)
        var outer_y1 = cy + outer_radius * sin(end_angle)
        var inner_x1 = cx + inner_radius * cos(end_angle)
        var inner_y1 = cy + inner_radius * sin(end_angle)
        var inner_x0 = cx + inner_radius * cos(start_angle)
        var inner_y0 = cy + inner_radius * sin(start_angle)
        var large_arc_flag = 1 if (end_angle - start_angle) > 3.14159265358979 else 0
        self._body += (
            '<path d="M'
            + _format_svg_float(outer_x0)
            + ","
            + _format_svg_float(outer_y0)
            + " A"
            + _format_svg_float(outer_radius)
            + ","
            + _format_svg_float(outer_radius)
            + " 0 "
            + String(large_arc_flag)
            + ",1 "
            + _format_svg_float(outer_x1)
            + ","
            + _format_svg_float(outer_y1)
            + " L"
            + _format_svg_float(inner_x1)
            + ","
            + _format_svg_float(inner_y1)
            + " A"
            + _format_svg_float(inner_radius)
            + ","
            + _format_svg_float(inner_radius)
            + " 0 "
            + String(large_arc_flag)
            + ",0 "
            + _format_svg_float(inner_x0)
            + ","
            + _format_svg_float(inner_y0)
            + ' Z" fill="'
            + _hex_color(color)
            + '"/>\n'
        )

    def stroke_path_aa(mut self, path: Path, color: Color, width: Float64 = 1.0):
        self._body += (
            '<path d="'
            + _path_d(path)
            + '" fill="none" stroke="'
            + _hex_color(color)
            + '" stroke-width="'
            + _format_svg_float(width)
            + '" stroke-linecap="round" stroke-linejoin="round"/>\n'
        )

    def fill_path_aa(mut self, path: Path, color: Color):
        self._body += '<path d="' + _path_d(path) + '" fill="' + _hex_color(color) + '"/>\n'

    def draw_text(
        mut self,
        x: Int,
        y: Int,
        text: String,
        color: Color,
        size: Float64,
        align: TextAlign,
        rotation: Float64 = 0.0,
    ):
        """Not part of `DrawTarget` (see that trait's own docstring
        for why text is excluded) -- meant to be called directly by a
        caller's own SVG-rendering path once it already knows it's
        holding an `SvgCanvas`, the same way `canvas_mojo.text.draw_text`
        would be called directly by a raster-rendering path once it
        knows it's holding a `Canvas`.

        `(x, y)` is the text baseline anchor, matching `canvas_mojo.text.
        draw_text`'s own convention exactly -- SVG `<text>` already
        anchors its own `y` to the alphabetic baseline by default, so
        no baseline-vs-top-of-glyph adjustment is needed here the way
        a raster API without that default might need. `text-anchor`
        (`start`/`middle`/`end`) is the direct SVG equivalent of
        `align`'s own three values, also both measured from `(x, y)`.

        `rotation` (radians, matching `canvas_mojo.text.draw_text`'s own
        convention exactly -- not degrees) rotates the whole `<text>`
        element around its own `(x, y)` anchor, via SVG's `transform=
        "rotate(<degrees> <x> <y>)"` -- omitted entirely when `rotation
        == 0.0` (the overwhelming common case), so every pre-existing
        `draw_text` call/output stays byte-for-byte unchanged. No sign
        flip needed converting from `canvas_mojo.text.draw_text`'s own
        Cairo-rotation convention: both Cairo's user space and SVG's
        viewport space put y pointing *down*, so a positive angle reads
        as clockwise-on-screen in both -- confirmed directly (not just
        argued) by this method's own hand-derived rotation test, not
        assumed to carry over from the raster path unchanged just
        because the reasoning sounds right.
        """
        var anchor = "start"
        if align == TextAlign.CENTER:
            anchor = "middle"
        elif align == TextAlign.RIGHT:
            anchor = "end"
        var transform = ""
        if rotation != 0.0:
            var degrees = rotation * (180.0 / pi)
            transform = (
                ' transform="rotate('
                + _format_svg_float(degrees)
                + " "
                + String(x)
                + " "
                + String(y)
                + ')"'
            )
        self._body += (
            '<text x="'
            + String(x)
            + '" y="'
            + String(y)
            + '" font-size="'
            + _format_svg_float(size)
            + '" fill="'
            + _hex_color(color)
            + '" text-anchor="'
            + anchor
            + '"'
            + transform
            + ">"
            + _escape_xml_text(text)
            + "</text>\n"
        )

    def to_string(self) -> String:
        return (
            '<svg xmlns="http://www.w3.org/2000/svg" width="'
            + String(self.width)
            + '" height="'
            + String(self.height)
            + '" viewBox="0 0 '
            + String(self.width)
            + " "
            + String(self.height)
            + '">\n'
            + self._body
            + "</svg>\n"
        )


def write_svg(svg: SvgCanvas, path: String) raises:
    """Write `svg`'s accumulated markup to `path` -- the SVG
    counterpart to `canvas_mojo.io.bmp.write_bmp`/`canvas_mojo.io.png.write_png`.
    """
    var f = open(path, "w")
    f.write(svg.to_string())
    f.close()
