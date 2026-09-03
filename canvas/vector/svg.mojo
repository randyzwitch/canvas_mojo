"""SvgCanvas: a vector `DrawTarget` that accumulates SVG markup instead
of rasterizing into a pixel buffer. No anti-aliasing math, no coverage
sampling, no fill-rule scanline algorithm -- an SVG renderer (browser,
image viewer, PDF exporter) does all of that at whatever resolution it
displays at, so content drawn through this carries no fixed pixel size.

The surface implements every `DrawTarget` method. It is not a
general-purpose SVG builder: no gradients beyond `fill_rect_gradient`'s,
no transforms, no clipping, and no groups beyond `begin_annotated_group`. `draw_text`'s `rotation`
is the one exception, a per-`<text>` `transform="rotate(...)"` rather
than a transform stack, for a chart's rotated y-axis title.
"""

from std.math import cos, pi, sin

from canvas.color import Color
from canvas.gradient import LinearGradient, _GradientStop
from canvas.vector.draw_target import DrawTarget
from canvas.geometry import _round_to_int
from canvas.path import (
    Path,
    _ARC_TO,
    _CLOSE,
    _CUBIC_TO,
    _LINE_TO,
    _MOVE_TO,
    _QUAD_TO,
)
from canvas.text.font_discovery import FontWeight
from canvas.text.text_align import TextAlign


def _hex_byte(value: UInt8) -> String:
    comptime _HEX_DIGITS = "0123456789abcdef"

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
    # Decimal places every Float64 coordinate/width/size is formatted
    # to.
    comptime _SVG_DECIMALS = 3

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


def _opacity_attr(name: String, color: Color) -> String:
    """A ` fill-opacity="..."` / ` stroke-opacity="..."` attribute for
    `color`'s alpha, or `""` when it is fully opaque.

    SVG carries alpha in a separate attribute, since `#rrggbb` has
    nowhere to put it. Omitted entirely at `a == 255`, and written as a
    0-1 fraction at `_format_svg_float`'s 3 decimals.
    """
    if color.a == 255:
        return ""
    return (
        " "
        + name
        + '-opacity="'
        + _format_svg_float(Float64(color.a) / 255.0)
        + '"'
    )


def _stops_sorted_by_offset(stops: List[_GradientStop]) -> List[_GradientStop]:
    """`LinearGradient.stops` in ascending-offset order. `add_stop`
    accepts any order, but SVG's `<stop>` clamps each offset to be no
    less than the previous sibling's, so descending offsets would flatten
    the gradient to one color in every viewer.

    The sort must be stable: two stops at the same offset are a hard
    color transition, and swapping them swaps which color owns which
    side.
    """
    var sorted_stops = List[_GradientStop](capacity=len(stops))
    for stop in stops:
        var insert_at = len(sorted_stops)
        while (
            insert_at > 0 and sorted_stops[insert_at - 1].offset > stop.offset
        ):
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
            d += (
                "M"
                + _format_svg_float(cmd.p1.x)
                + ","
                + _format_svg_float(cmd.p1.y)
            )
        elif cmd.kind == _LINE_TO:
            d += (
                "L"
                + _format_svg_float(cmd.p1.x)
                + ","
                + _format_svg_float(cmd.p1.y)
            )
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
            var large_arc_flag = 1 if (end_angle - cmd.p2.y) > pi else 0
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
    # Whether a `<g>` opened by begin_annotated_group is still waiting
    # for its `</g>`. Groups do not nest, so one flag is the whole
    # state; `to_string` consults it so an unclosed group cannot reach
    # a file as malformed markup.
    var _open_group: Bool

    def __init__(out self, width: Int, height: Int):
        """An empty `width x height` SVG document.

        Args:
            width: Document width in pixels.
            height: Document height in pixels.
        """
        self.width = width
        self.height = height
        self._body = ""
        self._gradient_count = 0
        self._open_group = False

    def fill_rect(
        mut self, x: Int, y: Int, width: Int, height: Int, color: Color
    ):
        """Emit a `<rect>` element.

        Args:
            x: Rectangle's left edge.
            y: Rectangle's top edge.
            width: Rectangle's width.
            height: Rectangle's height.
            color: Fill color.
        """
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
            + '"'
            + _opacity_attr("fill", color)
            + "/>\n"
        )

    def fill_rect_gradient(
        mut self,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        gradient: LinearGradient,
    ):
        """An SVG `<linearGradient>` with
        `gradientUnits="userSpaceOnUse"`. `LinearGradient`'s
        (x0, y0)-(x1, y1) axis is already in the same absolute pixel
        space as this document's `<rect>`, so `userSpaceOnUse` carries it
        over untranslated instead of SVG's default shape-relative
        `objectBoundingBox` units.

        Emits a fresh `<defs><linearGradient id="gradN">` per call;
        `<stop>` elements come out in ascending-offset order.

        Args:
            x: Rectangle's left edge.
            y: Rectangle's top edge.
            width: Rectangle's width.
            height: Rectangle's height.
            gradient: Fill source, projected across the rectangle.
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
        mut self,
        x0: Int,
        y0: Int,
        x1: Int,
        y1: Int,
        color: Color,
        width: Float64 = 1.0,
    ):
        """Emit a `<line>` element with round end caps.

        Args:
            x0: Start point x.
            y0: Start point y.
            x1: End point x.
            y1: End point y.
            color: Line color.
            width: Stroke width in pixels.
        """
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
            + '"'
            + _opacity_attr("stroke", color)
            + ' stroke-width="'
            + _format_svg_float(width)
            + '" stroke-linecap="round"/>\n'
        )

    def fill_circle_aa(mut self, cx: Int, cy: Int, radius: Int, color: Color):
        """Emit a `<circle>` element.

        Args:
            cx: Center x.
            cy: Center y.
            radius: Circle radius in pixels.
            color: Fill color.
        """
        self._body += (
            '<circle cx="'
            + String(cx)
            + '" cy="'
            + String(cy)
            + '" r="'
            + String(radius)
            + '" fill="'
            + _hex_color(color)
            + '"'
            + _opacity_attr("fill", color)
            + "/>\n"
        )

    def fill_ellipse_aa(
        mut self, cx: Int, cy: Int, rx: Int, ry: Int, color: Color
    ):
        """Emit an `<ellipse>` element.

        Args:
            cx: Center x.
            cy: Center y.
            rx: Horizontal radius in pixels.
            ry: Vertical radius in pixels.
            color: Fill color.
        """
        self._body += (
            '<ellipse cx="'
            + String(cx)
            + '" cy="'
            + String(cy)
            + '" rx="'
            + String(rx)
            + '" ry="'
            + String(ry)
            + '" fill="'
            + _hex_color(color)
            + '"'
            + _opacity_attr("fill", color)
            + "/>\n"
        )

    def draw_ellipse_aa(
        mut self, cx: Int, cy: Int, rx: Int, ry: Int, color: Color
    ):
        """Emit an unfilled `<ellipse>` element, ~1px stroke.

        Args:
            cx: Center x.
            cy: Center y.
            rx: Horizontal radius in pixels.
            ry: Vertical radius in pixels.
            color: Outline color.
        """
        # stroke-width 1 to match the raster primitive, which draws a
        # fixed ~1px outline and takes no width (see DrawTarget).
        self._body += (
            '<ellipse cx="'
            + String(cx)
            + '" cy="'
            + String(cy)
            + '" rx="'
            + String(rx)
            + '" ry="'
            + String(ry)
            + '" fill="none" stroke="'
            + _hex_color(color)
            + '"'
            + _opacity_attr("stroke", color)
            + ' stroke-width="1"/>\n'
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
        """A wedge, drawn as `M center L start-point A ... end-point Z`.
        `sweep_flag=1` with no sign flip: SVG's space is y-down like the
        raster canvas's, so increasing angle sweeps clockwise in both.

        Args:
            cx: Center x.
            cy: Center y.
            radius: Wedge radius in pixels.
            start_angle: Sweep start, radians, 0 pointing along +x.
            end_angle: Sweep end, radians. Must be >= start_angle.
            color: Fill color.
        """
        var x0 = cx + radius * cos(start_angle)
        var y0 = cy + radius * sin(start_angle)
        var x1 = cx + radius * cos(end_angle)
        var y1 = cy + radius * sin(end_angle)
        var large_arc_flag = 1 if (end_angle - start_angle) > pi else 0
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
            + '"'
            + _opacity_attr("fill", color)
            + "/>\n"
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
        (`sweep_flag=1`), a radial line runs inward, then the inner arc
        sweeps backward (`sweep_flag=0`), closing the ring in one loop.

        Args:
            cx: Center x.
            cy: Center y.
            inner_radius: Ring's inner edge, in pixels.
            outer_radius: Ring's outer edge, in pixels. Must exceed
                inner_radius.
            start_angle: Sweep start, radians, 0 pointing along +x.
            end_angle: Sweep end, radians. Must be >= start_angle.
            color: Fill color.
        """
        var outer_x0 = cx + outer_radius * cos(start_angle)
        var outer_y0 = cy + outer_radius * sin(start_angle)
        var outer_x1 = cx + outer_radius * cos(end_angle)
        var outer_y1 = cy + outer_radius * sin(end_angle)
        var inner_x1 = cx + inner_radius * cos(end_angle)
        var inner_y1 = cy + inner_radius * sin(end_angle)
        var inner_x0 = cx + inner_radius * cos(start_angle)
        var inner_y0 = cy + inner_radius * sin(start_angle)
        var large_arc_flag = 1 if (end_angle - start_angle) > pi else 0
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
            + '"'
            + _opacity_attr("fill", color)
            + "/>\n"
        )

    def stroke_path_aa(
        mut self, path: Path, color: Color, width: Float64 = 1.0
    ):
        """Emit a `<path>` element, stroked only.

        Args:
            path: Path to stroke.
            color: Stroke color.
            width: Stroke width in pixels.
        """
        self._body += (
            '<path d="'
            + _path_d(path)
            + '" fill="none" stroke="'
            + _hex_color(color)
            + '"'
            + _opacity_attr("stroke", color)
            + ' stroke-width="'
            + _format_svg_float(width)
            + '" stroke-linecap="round" stroke-linejoin="round"/>\n'
        )

    def fill_path_aa(mut self, path: Path, color: Color):
        """Emit a `<path>` element, filled only.

        Args:
            path: Path to fill.
            color: Fill color.
        """
        self._body += (
            '<path d="'
            + _path_d(path)
            + '" fill="'
            + _hex_color(color)
            + '"'
            + _opacity_attr("fill", color)
            + "/>\n"
        )

    def begin_annotated_group(mut self, title: String):
        """Open `<g><title>title</title>`, labelling every element
        emitted until `end_annotated_group`. Browsers show a `<title>`
        inside a `<g>` as a hover tooltip over anything in the group,
        which is what gives a chart per-datum tooltips without any
        scripting.

        `title` is escaped as element content, so it may contain `&`,
        `<` and `>` freely.

        Groups do not nest: opening one while another is open closes
        the first. See the `DrawTarget` docstring for why the operation
        is scoped rather than a parameter on each primitive.

        Args:
            title: Human-readable label, escaped here. Pass it raw.
        """
        if self._open_group:
            self._body += "</g>\n"
        self._body += "<g>\n<title>" + _escape_xml_text(title) + "</title>\n"
        self._open_group = True

    def end_annotated_group(mut self):
        """Close the group `begin_annotated_group` opened, a no-op when
        none is open. Emitting a stray `</g>` would make the document
        malformed, which is worse than ignoring an unbalanced call, and
        it matches `Canvas.pop_clip` treating an unbalanced close as
        nothing to undo.
        """
        if self._open_group:
            self._body += "</g>\n"
            self._open_group = False

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
        """Draw a `<text>` element. Not part of `DrawTarget`, which
        excludes text -- call this directly once a caller knows it holds
        an `SvgCanvas`, the way raster code calls
        `canvas.text.render.draw_text` on a `Canvas`.

        `family` is always emitted, defaulting to `"sans-serif"`, since
        a viewer without one falls back to its own varying default. Note
        it is a different kind of value from raster draw_text's `family`
        despite the shared name: raster's resolves to one concrete font
        *file*, while this is a literal CSS `font-family` -- keyword, face
        name, or comma-separated stack -- interpreted by whatever renders
        the SVG. A caller driving both backends maps between them itself.

        `(x, y)` is the baseline anchor, matching raster draw_text, since
        SVG `<text>` anchors `y` to the alphabetic baseline already.
        `text-anchor` (`start`/`middle`/`end`) is the equivalent of
        `align`'s three values.

        `rotation` is radians and rotates the whole `<text>` around its
        `(x, y)` anchor via `transform="rotate(<degrees> <x> <y>)"`,
        omitted at 0.0. No sign flip: raster and SVG viewport space both
        put y downward.

        `weight` emits `font-weight="bold"` for FontWeight.BOLD and is
        omitted at `NORMAL`.

        Args:
            x: Anchor x -- baseline left end for TextAlign.LEFT.
            y: Anchor y -- baseline.
            text: Text to draw. No line-break handling for embedded
                "\\n".
            color: Text color.
            size: Font size in pixels.
            align: Horizontal alignment relative to (x, y).
            family: A literal CSS `font-family` value (keyword, face
                name, or comma-separated stack), not a font-matching
                query.
            rotation: Radians, rotating the whole `<text>` element
                around (x, y).
            weight: Normal/bold weight.
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
            + '"'
            + _opacity_attr("fill", color)
            + ' text-anchor="'
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
            # A group the caller never closed: closed here rather than
            # emitted unbalanced, so `to_string` and `write_svg` always
            # produce well-formed markup.
            + ("</g>\n" if self._open_group else "")
            + "</svg>\n"
        )


def write_svg(svg: SvgCanvas, path: String) raises:
    """Write `svg`'s accumulated markup to `path`, the SVG counterpart
    to `write_bmp`/`write_png`.

    Args:
        svg: Document to write.
        path: File path to write to.

    Raises:
        Error: `path` can't be opened for writing.
    """
    var f = open(path, "w")
    f.write(svg.to_string())
    f.close()
