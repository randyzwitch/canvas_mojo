"""SvgCanvas: a vector `DrawTarget` that accumulates SVG markup instead
of rasterizing into a pixel buffer. No anti-aliasing math, no coverage
sampling, no fill-rule scanline algorithm -- an SVG renderer (browser,
image viewer, PDF exporter) does all of that at whatever resolution it
displays at. Content drawn through this has no fixed pixel size to get
wrong the way a raster target, which must pick a resolution up front,
can when scaled after the fact.

Minimal, matching `DrawTarget`'s six methods one for one. Not a
general-purpose SVG builder: no gradients, no general groups or
transforms, no clipping. `draw_text`'s `rotation` is the one exception,
a per-`<text>` `transform="rotate(...)"` rather than a transform stack,
because a chart's rotated y-axis title needs it.
"""

from std.math import cos, pi, sin

from canvas_mojo.color import Color
from canvas_mojo.gradient import LinearGradient, _GradientStop
from canvas_mojo.vector.draw_target import DrawTarget
from canvas_mojo.geometry import _round_to_int
from canvas_mojo.path import Path, _ARC_TO, _CLOSE, _CUBIC_TO, _LINE_TO, _MOVE_TO, _QUAD_TO
from canvas_mojo.text.font_discovery import FontWeight
from canvas_mojo.text.text_align import TextAlign

comptime _HEX_DIGITS = "0123456789abcdef"

# Decimal places every Float64 coordinate/width/size is formatted to;
# see _format_svg_float for why this rounding exists.
comptime _SVG_DECIMALS = 3


def _hex_byte(value: UInt8) -> String:
    var v = Int(value)
    # `_HEX_DIGITS` is a fixed, pure-ASCII literal, so a raw UTF-8 byte
    # index (`[byte=...]`) is exactly the character it looks like.
    # Mojo `String` has no plain positional `s[i]` indexing -- it
    # indexes by `[byte=]`/`[codepoint=]`/`[grapheme=]`.
    return String(_HEX_DIGITS[byte=v // 16]) + String(_HEX_DIGITS[byte=v % 16])


def _format_svg_float(value: Float64) -> String:
    """Format `value` to exactly `_SVG_DECIMALS` decimal places. Plain
    `String(Float64)` is not safe for SVG coordinates: the same
    `cx + radius * cos(angle)` expression can land one ULP apart
    depending on compilation context, and shortest-round-trip
    formatting turns that into a different *string* even though both
    values are the same point on any display. Rounding to millipixels
    -- far finer than a display resolves -- collapses the two. See the
    wiki for the full case.
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
    """Escape XML-significant characters in text *content*. `"`/`'`
    need no escaping outside quoted attributes, and label text never
    goes into one. `&` is escaped first, since escaping the others
    introduces literal `&`s a later pass would mangle.
    """
    var result = text.replace("&", "&amp;")
    result = result.replace("<", "&lt;")
    result = result.replace(">", "&gt;")
    return result


def _escape_xml_attr(value: String) -> String:
    """Escape a string headed into a *double-quoted attribute value*.
    draw_text's `family` is the caller-supplied string that needs this:
    a real CSS font stack (`"Helvetica Neue", Arial, sans-serif`)
    contains literal `"` characters, which `_escape_xml_text` leaves
    alone. `&` first, for the reason `_escape_xml_text` gives.
    """
    var result = value.replace("&", "&amp;")
    result = result.replace('"', "&quot;")
    result = result.replace("<", "&lt;")
    return result


def _hex_color(color: Color) -> String:
    return "#" + _hex_byte(color.r) + _hex_byte(color.g) + _hex_byte(color.b)


def _stops_sorted_by_offset(stops: List[_GradientStop]) -> List[_GradientStop]:
    """`LinearGradient.stops` in ascending-offset order. `add_stop`
    guarantees insertion order doesn't matter, and the raster lookup
    honors that, but SVG's `<stop>` clamps each offset to be no less
    than the previous sibling's -- so descending offsets would emit
    every stop after the first at the first stop's offset, flattening
    the gradient to one color in every viewer. Sorting here, right
    before emitting, keeps that guarantee without touching add_stop's
    contract or LinearGradient's storage.

    Insertion sort rather than stdlib `sort()`: `stops` is typically
    2-4 entries, and stability matters -- two stops at the same offset
    are a deliberate hard color transition, and a merely
    offset-correct sort could swap which color owns which side of it.
    """
    var sorted_stops = List[_GradientStop](capacity=len(stops))
    for stop in stops:
        var insert_at = len(sorted_stops)
        while insert_at > 0 and sorted_stops[insert_at - 1].offset > stop.offset:
            insert_at -= 1
        sorted_stops.insert(insert_at, stop)
    return sorted_stops^


def _path_d(path: Path) -> String:
    """Path.commands -> an SVG `d` attribute string, one-to-one
    (M/L/Q/C/A/Z): Path's six command kinds are already SVG path's
    move/line/quadratic/cubic/elliptical-arc/close, absolute both ways,
    so nothing is translated. arc_to emits `sweep_flag=1` with no sign
    flip -- SVG's space is y-down like the raster canvas's, and
    increasing angle sweeps clockwise in both.
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
        elif cmd.kind == _ARC_TO:
            # cmd.p1 = (cx, cy), cmd.p2 = (radius, start_angle),
            # cmd.p3.x = end_angle (see _PathCommand in path.mojo). No
            # leading `L` to the arc's start the way fill_arc_aa's
            # standalone wedge needs: arc_to is always one segment
            # inside a larger path, continuing from the current point
            # already is (arc_to puts that contract on
            # the caller), the same as the L/Q/C branches above.
            var cx = cmd.p1.x
            var cy = cmd.p1.y
            var radius = cmd.p2.x
            var end_angle = cmd.p3.x
            var x1 = cx + radius * cos(end_angle)
            var y1 = cy + radius * sin(end_angle)
            var large_arc_flag = 1 if (end_angle - cmd.p2.y) > 3.14159265358979 else 0
            d += (
                "A"
                + _format_svg_float(radius)
                + ","
                + _format_svg_float(radius)
                + " 0 "
                + String(large_arc_flag)
                + ",1 "
                + _format_svg_float(x1)
                + ","
                + _format_svg_float(y1)
            )
        else:  # _CLOSE
            d += "Z"
    return d


struct SvgCanvas(DrawTarget, Movable):
    """Accumulates SVG body markup for a `width x height` document.
    `width`/`height` are public fields, as on `Canvas`.
    """

    var width: Int
    var height: Int
    var _body: String
    # How many gradients this document has emitted, used only to mint
    # a fresh `<defs>` id ("grad" + String(...)) per call so two
    # fill_rect_gradient calls never collide.
    var _gradient_count: Int

    def __init__(out self, width: Int, height: Int):
        self.width = width
        self.height = height
        self._body = ""
        self._gradient_count = 0

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

    def fill_rect_gradient(
        mut self, x: Int, y: Int, width: Int, height: Int, gradient: LinearGradient
    ):
        """A real SVG `<linearGradient>` with
        `gradientUnits="userSpaceOnUse"`, not a per-pixel raster fill.
        `LinearGradient`'s (x0, y0)-(x1, y1) axis already lives in the
        same absolute pixel space as this document's `<rect>`, so
        `userSpaceOnUse` -- SVG's escape from its default shape-relative
        `objectBoundingBox` units -- carries that axis over untranslated.

        Emits a fresh `<defs><linearGradient id="gradN">` per call
        rather than deduping a gradient reused across calls. That
        duplicates markup, but SVG readers dedupe identical `<defs>`
        at parse time, and a chart draws a given gradient once per
        legend or bar anyway.

        `<stop>` elements come out in ascending-offset order regardless
        of insertion order -- see _stops_sorted_by_offset.
        """
        self._gradient_count += 1
        var gid = "grad" + String(self._gradient_count)
        var defs = (
            '<defs><linearGradient id="'
            + gid
            + '" gradientUnits="userSpaceOnUse" x1="'
            + _format_svg_float(gradient.x0)
            + '" y1="'
            + _format_svg_float(gradient.y0)
            + '" x2="'
            + _format_svg_float(gradient.x1)
            + '" y2="'
            + _format_svg_float(gradient.y1)
            + '">'
        )
        for stop in _stops_sorted_by_offset(gradient.stops):
            defs += (
                '<stop offset="'
                + _format_svg_float(stop.offset)
                + '" stop-color="'
                + _hex_color(stop.color)
                + '" stop-opacity="'
                + _format_svg_float(Float64(stop.color.a) / 255.0)
                + '"/>'
            )
        defs += "</linearGradient></defs>\n"
        self._body += defs
        self._body += (
            '<rect x="'
            + String(x)
            + '" y="'
            + String(y)
            + '" width="'
            + String(width)
            + '" height="'
            + String(height)
            + '" fill="url(#'
            + gid
            + ')"/>\n'
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
        """A wedge, drawn as `M center L start-point A ... end-point Z`:
        the same "line out to the arc, sweep it, line back to center"
        boundary `fill_arc_aa`'s raster coverage math uses.
        `sweep_flag=1` with no sign flip, since SVG's space is y-down
        like the raster canvas's and increasing angle sweeps clockwise
        in both.
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
        A ... inner-start Z`. The outer arc sweeps forward
        (`sweep_flag=1`, as in `fill_arc_aa`), then a radial line
        inward, then the inner arc sweeps *backward* (`sweep_flag=0`)
        back to the start angle, closing the ring in one loop -- the
        boundary `fill_ring_sector` builds from two point-sampled
        polylines, expressed as two SVG arc commands.
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
        family: String = "sans-serif",
        rotation: Float64 = 0.0,
        weight: FontWeight = FontWeight.NORMAL,
    ):
        """Not part of `DrawTarget`, which excludes text -- call this
        directly once a caller knows it holds an `SvgCanvas`, the way
        raster code calls `canvas_mojo.text.draw_text` on a `Canvas`.

        `family` becomes a literal `font-family` attribute, always
        emitted: without one, a viewer falls back to its own undefined
        default (some pick a serif face), which reads as inconsistent
        with the raster `draw_text`, where fontconfig always resolves a
        real font. Defaults to `"sans-serif"`, a generic CSS keyword
        every viewer supports.

        This `family` is a different kind of value from raster
        draw_text's, despite the shared name and position: raster's is
        a fontconfig alias resolved to one concrete font *file*; this
        is a literal CSS `font-family` -- keyword, face name, or
        comma-separated stack -- interpreted by whatever renders the
        SVG. A caller driving both backends needs its own mapping
        between the two.

        `(x, y)` is the baseline anchor, matching raster draw_text:
        SVG `<text>` anchors `y` to the alphabetic baseline already, so
        nothing adjusts for glyph tops. `text-anchor`
        (`start`/`middle`/`end`) is the direct equivalent of `align`'s
        three values, also measured from `(x, y)`.

        `rotation` is radians, as in raster draw_text, and rotates the
        whole `<text>` around its `(x, y)` anchor via
        `transform="rotate(<degrees> <x> <y>)"`. Omitted entirely at
        0.0. No sign flip: raster space and SVG's viewport space both
        put y downward, so a positive angle is clockwise in both.

        `weight` mirrors raster draw_text's `weight` -- same
        `FontWeight`, same `NORMAL` default -- so one call site can
        drive both backends. Emits `font-weight="bold"` for
        FontWeight.BOLD (SVG/CSS's two-value keyword; `FontWeight`
        distinguishes nothing finer), omitted at `NORMAL`.
        """
        var escaped_family = _escape_xml_attr(family)
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
        var font_weight = ""
        if weight == FontWeight.BOLD:
            font_weight = ' font-weight="bold"'
        self._body += (
            '<text x="'
            + String(x)
            + '" y="'
            + String(y)
            + '" font-size="'
            + _format_svg_float(size)
            + '" font-family="'
            + escaped_family
            + '"'
            + font_weight
            + ' fill="'
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
    """Write `svg`'s accumulated markup to `path`, the SVG counterpart
    to `write_bmp`/`write_png`.
    """
    var f = open(path, "w")
    f.write(svg.to_string())
    f.close()
