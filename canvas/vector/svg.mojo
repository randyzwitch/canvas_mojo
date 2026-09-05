"""SvgCanvas: a vector `DrawTarget` that accumulates SVG markup instead
of rasterizing into a pixel buffer. No anti-aliasing math, no coverage
sampling, no fill-rule scanline algorithm -- an SVG renderer (browser,
image viewer, PDF exporter) does all of that at whatever resolution it
displays at, so content drawn through this carries no fixed pixel size.

The surface implements every `DrawTarget` method. It is not a
general-purpose SVG builder: no gradients beyond `fill_rect_gradient`'s,
no clipping, and no groups beyond `begin_annotated_group`.

The transform state (`save`/`restore`, `translate`/`rotate`/`scale`)
is carried as a `transform="matrix(a b c d e f)"` attribute on each
element drawn while a transform is set, rather than as nested `<g>`
groups: an attribute per element cannot interleave badly with the
annotated groups, and `restore` has nothing to close. `draw_text`'s own
`rotation` composes after it in the same attribute. SVG applies
`stroke-width` in the element's user space, so a stroke under a scale
widens with it, as it does on `Canvas`.

`set_blend_mode` is carried the same way, as a
`style="mix-blend-mode:..."` attribute. CSS names the separable and
non-separable blend modes and nothing else, so the Porter-Duff
operators past the default -- SOURCE, DESTINATION_IN, XOR and the
rest -- emit no attribute and render as ordinary source-over.
"""

from std.math import cos, pi, sin

from canvas.blend import BlendMode, _css_blend_name
from canvas.color import Color
from canvas.fill_rule import FillRule
from canvas.geometry import Matrix2D
from canvas.gradient import LinearGradient
from canvas.vector.draw_target import DrawTarget
from canvas.geometry import round_to_int
from canvas.path import (
    Path,
    PathOp,
)
from canvas.shapes.lines import LineCap, LineJoin
from canvas.text.font_discovery import FontWeight
from canvas.text.text_align import TextAlign


# Decimal places every Float64 coordinate/width/size is formatted to.
comptime _SVG_DECIMALS = 3


def _write_svg_float(mut out: String, value: Float64):
    """Append `value` to `out` at exactly `_SVG_DECIMALS` decimal places.
    Plain `String(Float64)` is not safe for SVG coordinates: the same
    `cx + radius * cos(angle)` expression can land one ULP apart
    depending on compilation context, and shortest-round-trip
    formatting turns that into a different *string* even though both
    values are the same point on any display. Rounding to millipixels
    -- far finer than a display resolves -- collapses the two. See the
    wiki for the full case.

    Written straight into `out`: an element's dozen numbers are the
    bulk of its text, and a String per number was most of what an
    element cost to emit (#193).
    """
    # 1000, 100, 10: 10 ** _SVG_DECIMALS and the pad thresholds below it.
    var scaled = round_to_int(value * 1000.0)
    var digits = scaled
    if scaled < 0:
        out.write("-")
        digits = -scaled
    var frac = digits % 1000
    out.write(digits // 1000, ".")
    if frac < 100:
        out.write("0")
    if frac < 10:
        out.write("0")
    out.write(frac)


def _format_svg_float(value: Float64) -> String:
    """`_write_svg_float` into a fresh String, for a caller that needs
    the number on its own.
    """
    var out = String()
    _write_svg_float(out, value)
    return out


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


def _to_hex(color: Color) -> String:
    """`Color.to_hex()`, as a function so the emitters below read the
    same as the other `_`-prefixed formatting helpers here.
    """
    return color.to_hex()


def _write_opacity(mut out: String, name: StaticString, color: Color):
    """Append a ` fill-opacity="..."` / ` stroke-opacity="..."`
    attribute for `color`'s alpha, or nothing when it is fully opaque.

    SVG carries alpha in a separate attribute, since `#rrggbb` has
    nowhere to put it. Omitted entirely at `a == 255`, and written as a
    0-1 fraction at `_write_svg_float`'s 3 decimals.
    """
    if color.a == 255:
        return
    out.write(" ", name, '-opacity="')
    _write_svg_float(out, Float64(color.a) / 255.0)
    out.write('"')


def _cap_name(cap: LineCap) -> StaticString:
    if cap == LineCap.BUTT:
        return "butt"
    if cap == LineCap.SQUARE:
        return "square"
    return "round"


def _join_name(join: LineJoin) -> StaticString:
    if join == LineJoin.BEVEL:
        return "bevel"
    if join == LineJoin.MITER:
        return "miter"
    return "round"


def _anchor_name(align: TextAlign) -> StaticString:
    """`text-anchor`'s three values, which are TextAlign's three."""
    if align == TextAlign.CENTER:
        return "middle"
    if align == TextAlign.RIGHT:
        return "end"
    return "start"


def _write_stroke_attrs(
    mut out: String,
    width: Float64,
    dashes: List[Float64],
    dash_offset: Float64,
    cap: LineCap,
    join: LineJoin,
    miter_limit: Float64,
    has_corners: Bool,
):
    """Append the stroke-style attributes of a stroked element: width
    and cap always; join and, for a MITER join at a non-default limit,
    miter-limit when the element has corners; dash array and, when
    non-zero, dash offset when there are dashes. SVG's own defaults
    for the omitted attributes are the same as the trait's, so a
    default call emits exactly what it did before the style existed.
    """
    out.write(' stroke-width="')
    _write_svg_float(out, width)
    out.write('" stroke-linecap="', _cap_name(cap), '"')
    if has_corners:
        out.write(' stroke-linejoin="', _join_name(join), '"')
        if join == LineJoin.MITER and miter_limit != 4.0:
            out.write(' stroke-miterlimit="')
            _write_svg_float(out, miter_limit)
            out.write('"')
    if len(dashes) > 0:
        out.write(' stroke-dasharray="')
        for i in range(len(dashes)):
            if i > 0:
                out.write(" ")
            _write_svg_float(out, dashes[i])
        out.write('"')
        if dash_offset != 0.0:
            out.write(' stroke-dashoffset="')
            _write_svg_float(out, dash_offset)
            out.write('"')


def _write_path_d(mut out: String, path: Path):
    """Append Path.commands as an SVG `d` attribute value, one-to-one
    (M/L/Q/C/A/Z): Path's six command kinds are already SVG path's
    move/line/quadratic/cubic/elliptical-arc/close, absolute both ways,
    so nothing is translated. arc_to's sweep flag follows the sign of
    its sweep with no flip -- SVG's space is y-down like the raster
    canvas's, so increasing angle is clockwise (`sweep_flag=1`) in both
    and a decreasing angle is `sweep_flag=0`.
    """
    var is_first = True
    for cmd in path.commands:
        if not is_first:
            out += " "
        is_first = False
        if cmd.op == PathOp.MOVE_TO:
            out.write("M")
            _write_svg_float(out, cmd.p1.x)
            out.write(",")
            _write_svg_float(out, cmd.p1.y)
        elif cmd.op == PathOp.LINE_TO:
            out.write("L")
            _write_svg_float(out, cmd.p1.x)
            out.write(",")
            _write_svg_float(out, cmd.p1.y)
        elif cmd.op == PathOp.QUAD_TO:
            out.write("Q")
            _write_svg_float(out, cmd.p1.x)
            out.write(",")
            _write_svg_float(out, cmd.p1.y)
            out.write(" ")
            _write_svg_float(out, cmd.p2.x)
            out.write(",")
            _write_svg_float(out, cmd.p2.y)
        elif cmd.op == PathOp.CUBIC_TO:
            out.write("C")
            _write_svg_float(out, cmd.p1.x)
            out.write(",")
            _write_svg_float(out, cmd.p1.y)
            out.write(" ")
            _write_svg_float(out, cmd.p2.x)
            out.write(",")
            _write_svg_float(out, cmd.p2.y)
            out.write(" ")
            _write_svg_float(out, cmd.p3.x)
            out.write(",")
            _write_svg_float(out, cmd.p3.y)
        elif cmd.op == PathOp.ARC_TO:
            # cmd.p1 = (cx, cy), cmd.p2 = (radius, start_angle),
            # cmd.p3.x = end_angle (see PathCommand in path.mojo). No
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
            var sweep = end_angle - cmd.p2.y
            var large_arc_flag = 1 if abs(sweep) > pi else 0
            var sweep_flag = 1 if sweep >= 0.0 else 0
            out.write("A")
            _write_svg_float(out, radius)
            out.write(",")
            _write_svg_float(out, radius)
            out.write(" 0 ", large_arc_flag, ",", sweep_flag, " ")
            _write_svg_float(out, x1)
            out.write(",")
            _write_svg_float(out, y1)
        else:  # PathOp.CLOSE
            out += "Z"


struct _SvgState(ImplicitlyCopyable, Movable):
    """What `SvgCanvas.save` records and `restore` puts back: this
    backend's whole drawing state, which is the transform and the
    blend mode.
    """

    var transform: Matrix2D
    var blend: BlendMode

    def __init__(out self, transform: Matrix2D, blend: BlendMode):
        self.transform = transform
        self.blend = blend


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
    # How many text paths this document has emitted, minting a fresh
    # `<defs>` id ("tp" + String(...)) per draw_text_on_path call the
    # way `_gradient_count` does for gradients.
    var _text_path_count: Int
    # Whether a `<g>` opened by begin_annotated_group is still waiting
    # for its `</g>`. Groups do not nest, so one flag is the whole
    # state; `to_string` consults it so an unclosed group cannot reach
    # a file as malformed markup.
    var _open_group: Bool
    # The current transform (see `save`), whether it is anything but
    # the identity, and the current blend mode.
    var _transform: Matrix2D
    var _transformed: Bool
    var _blend: BlendMode
    # What `save` pushes: everything above that `restore` puts back.
    var _saved: List[_SvgState]
    # The document title and description `set_title` stored, emitted
    # by `to_string` on the root element; empty until set.
    var _title: String
    var _description: String

    def __init__(out self, width: Int, height: Int):
        """An empty `width x height` SVG document.

        Args:
            width: Document width in pixels.
            height: Document height in pixels.
        """
        self.width = width
        self.height = height
        self._body = ""
        self._title = ""
        self._description = ""
        self._gradient_count = 0
        self._text_path_count = 0
        self._open_group = False
        self._transform = Matrix2D.identity()
        self._transformed = False
        self._blend = BlendMode.SOURCE_OVER
        self._saved = List[_SvgState]()

    def _write_transform(mut self):
        """Append the `transform` attribute for an element drawn now:
        nothing at the identity, otherwise the current matrix.
        """
        if not self._transformed:
            return
        self._body.write(' transform="')
        self._write_matrix()
        self._body.write('"')

    def _write_blend(mut self):
        """Append the `style` attribute carrying `mix-blend-mode` for
        an element drawn now: nothing under SOURCE_OVER, and nothing
        under a Porter-Duff mode, which CSS cannot express.
        """
        var name = _css_blend_name(self._blend)
        if name == "":
            return
        self._body.write(' style="mix-blend-mode:', name, '"')

    def _write_matrix(mut self):
        """`matrix(a b c d e f)` for the current transform, appended."""
        var m = self._transform
        self._body.write("matrix(")
        _write_svg_float(self._body, m.a)
        self._body.write(" ")
        _write_svg_float(self._body, m.b)
        self._body.write(" ")
        _write_svg_float(self._body, m.c)
        self._body.write(" ")
        _write_svg_float(self._body, m.d)
        self._body.write(" ")
        _write_svg_float(self._body, m.e)
        self._body.write(" ")
        _write_svg_float(self._body, m.f)
        self._body.write(")")

    def save(mut self):
        """Push the current transform and blend mode for `restore` to
        put back. This backend has no clip state, so those two are all
        it holds.
        """
        self._saved.append(_SvgState(self._transform, self._blend))

    def restore(mut self):
        """Pop the state `save` pushed. A no-op with nothing saved,
        matching `Canvas.restore`.
        """
        if len(self._saved) == 0:
            return
        var state = self._saved.pop()
        self._set_transform(state.transform)
        self._blend = state.blend

    def translate(mut self, tx: Float64, ty: Float64):
        """Shift subsequent elements by (tx, ty) in the current user
        space -- see `Canvas.translate`.

        Args:
            tx: Horizontal shift.
            ty: Vertical shift.
        """
        self.transform(Matrix2D.translation(tx, ty))

    def rotate(mut self, angle: Float64):
        """Turn subsequent elements by `angle` radians about the
        current origin -- see `Canvas.rotate`.

        Args:
            angle: Radians.
        """
        self.transform(Matrix2D.rotation(angle))

    def scale(mut self, sx: Float64, sy: Float64):
        """Scale subsequent elements about the current origin -- see
        `Canvas.scale`.

        Args:
            sx: Horizontal factor.
            sy: Vertical factor.
        """
        self.transform(Matrix2D.scaling(sx, sy))

    def transform(mut self, matrix: Matrix2D):
        """Compose `matrix` into the current transform, applied first
        -- the order `Canvas.transform` composes in.

        Args:
            matrix: The map to apply first.
        """
        self._set_transform(matrix.then(self._transform))

    def set_transform(mut self, matrix: Matrix2D):
        """Replace the current transform outright.

        Args:
            matrix: The new map from user space to document pixels.
        """
        self._set_transform(matrix)

    def reset_transform(mut self):
        """Back to the identity: elements carry no `transform`."""
        self._set_transform(Matrix2D.identity())

    def current_transform(self) -> Matrix2D:
        """The map every element drawn now carries.

        Returns:
            The current transform; the identity if none is set.
        """
        return self._transform

    def has_transform(self) -> Bool:
        """Whether elements drawn now carry a `transform` attribute.

        Returns:
            True if the current transform is not the identity.
        """
        return self._transformed

    def set_blend_mode(mut self, mode: BlendMode):
        """Set how elements drawn from here on combine with what is
        already painted, the counterpart of `Canvas.set_blend_mode`.

        A blend mode (MULTIPLY through LUMINOSITY) becomes a
        `style="mix-blend-mode:..."` attribute on each element. CSS
        has no keyword for the Porter-Duff operators -- SOURCE,
        DESTINATION_IN, XOR, ADD and the rest -- so those emit no
        attribute at all and render as ordinary source-over. A caller
        needing them has to use the raster backend.

        `save`/`restore` carry the mode, as they do the transform.

        Args:
            mode: The blend mode later elements carry.
        """
        self._blend = mode

    def blend_mode(self) -> BlendMode:
        """The blend mode elements drawn now carry.

        Returns:
            The current mode, `BlendMode.SOURCE_OVER` until
            `set_blend_mode` says otherwise.
        """
        return self._blend

    def _set_transform(mut self, matrix: Matrix2D):
        self._transform = matrix
        self._transformed = not matrix.is_identity()

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
        self._body.write(
            '<rect x="',
            x,
            '" y="',
            y,
            '" width="',
            width,
            '" height="',
            height,
            '" fill="',
            _to_hex(color),
            '"',
        )
        _write_opacity(self._body, "fill", color)
        self._write_transform()
        self._write_blend()
        self._body.write("/>\n")

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
        self._body.write(
            '<defs><linearGradient id="grad',
            self._gradient_count,
            '" gradientUnits="userSpaceOnUse" x1="',
        )
        _write_svg_float(self._body, gradient.x0)
        self._body.write('" y1="')
        _write_svg_float(self._body, gradient.y0)
        self._body.write('" x2="')
        _write_svg_float(self._body, gradient.x1)
        self._body.write('" y2="')
        _write_svg_float(self._body, gradient.y1)
        self._body.write('">')
        # `LinearGradient.stops` is kept sorted by offset on insert,
        # which is what SVG needs: `<stop>` clamps each offset to be no
        # less than the previous sibling's, so descending offsets would
        # flatten the gradient to one colour in every viewer.
        for stop in gradient.stops:
            self._body.write('<stop offset="')
            _write_svg_float(self._body, stop.offset)
            self._body.write(
                '" stop-color="', _to_hex(stop.color), '" stop-opacity="'
            )
            _write_svg_float(self._body, Float64(stop.color.a) / 255.0)
            self._body.write('"/>')
        self._body.write("</linearGradient></defs>\n")
        self._body.write(
            '<rect x="',
            x,
            '" y="',
            y,
            '" width="',
            width,
            '" height="',
            height,
            '" fill="url(#grad',
            self._gradient_count,
            ')"',
        )
        self._write_transform()
        self._write_blend()
        self._body.write("/>\n")

    def draw_line_aa(
        mut self,
        x0: Int,
        y0: Int,
        x1: Int,
        y1: Int,
        color: Color,
        width: Float64 = 1.0,
        dashes: List[Float64] = List[Float64](),
        dash_offset: Float64 = 0.0,
        cap: LineCap = LineCap.ROUND,
        join: LineJoin = LineJoin.ROUND,
        miter_limit: Float64 = 4.0,
    ):
        """Emit a `<line>` element, round-capped by default.

        Args:
            x0: Start point x.
            y0: Start point y.
            x1: End point x.
            y1: End point y.
            color: Line color.
            width: Stroke width in pixels.
            dashes: On/off segment lengths in user-space pixels, cycled
                along the line. Empty (default) draws a solid line.
            dash_offset: Distance into the dash pattern the line starts
                at.
            cap: How the two ends are finished -- see LineCap.
            join: Unused for a single segment, which has no corners.
            miter_limit: Unused for a single segment.
        """
        self._body.write(
            '<line x1="',
            x0,
            '" y1="',
            y0,
            '" x2="',
            x1,
            '" y2="',
            y1,
            '" stroke="',
            _to_hex(color),
            '"',
        )
        _write_opacity(self._body, "stroke", color)
        _write_stroke_attrs(
            self._body,
            width,
            dashes,
            dash_offset,
            cap,
            join,
            miter_limit,
            False,
        )
        self._write_transform()
        self._write_blend()
        self._body.write("/>\n")

    def fill_circle_aa(mut self, cx: Int, cy: Int, radius: Int, color: Color):
        """Emit a `<circle>` element.

        Args:
            cx: Center x.
            cy: Center y.
            radius: Circle radius in pixels.
            color: Fill color.
        """
        self._body.write(
            '<circle cx="',
            cx,
            '" cy="',
            cy,
            '" r="',
            radius,
            '" fill="',
            _to_hex(color),
            '"',
        )
        _write_opacity(self._body, "fill", color)
        self._write_transform()
        self._write_blend()
        self._body.write("/>\n")

    def draw_circle_aa(
        mut self,
        cx: Float64,
        cy: Float64,
        radius: Float64,
        color: Color,
        width: Float64 = 1.0,
    ):
        """Emit an unfilled `<circle>` element, at a sub-pixel center
        and radius.

        Args:
            cx: Center x, sub-pixel.
            cy: Center y, sub-pixel.
            radius: Circle radius in pixels, to the middle of the
                stroke.
            color: Outline color.
            width: Stroke width in pixels.
        """
        self._body.write('<circle cx="')
        _write_svg_float(self._body, cx)
        self._body.write('" cy="')
        _write_svg_float(self._body, cy)
        self._body.write('" r="')
        _write_svg_float(self._body, radius)
        self._body.write('" fill="none" stroke="', _to_hex(color), '"')
        _write_opacity(self._body, "stroke", color)
        _write_stroke_attrs(
            self._body,
            width,
            List[Float64](),
            0.0,
            LineCap.ROUND,
            LineJoin.ROUND,
            4.0,
            False,
        )
        self._write_transform()
        self._write_blend()
        self._body.write("/>\n")

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
        self._body.write(
            '<ellipse cx="',
            cx,
            '" cy="',
            cy,
            '" rx="',
            rx,
            '" ry="',
            ry,
            '" fill="',
            _to_hex(color),
            '"',
        )
        _write_opacity(self._body, "fill", color)
        self._write_transform()
        self._write_blend()
        self._body.write("/>\n")

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
        self._body.write(
            '<ellipse cx="',
            cx,
            '" cy="',
            cy,
            '" rx="',
            rx,
            '" ry="',
            ry,
            '" fill="none" stroke="',
            _to_hex(color),
            '"',
        )
        _write_opacity(self._body, "stroke", color)
        self._body.write(' stroke-width="1"')
        self._write_transform()
        self._write_blend()
        self._body.write("/>\n")

    def draw_ellipse_aa(
        mut self,
        cx: Float64,
        cy: Float64,
        rx: Float64,
        ry: Float64,
        color: Color,
        width: Float64 = 1.0,
    ):
        """Emit an unfilled `<ellipse>` element, at a sub-pixel center
        and radii.

        Args:
            cx: Center x, sub-pixel.
            cy: Center y, sub-pixel.
            rx: Horizontal radius in pixels, to the middle of the
                stroke.
            ry: Vertical radius in pixels, to the middle of the
                stroke.
            color: Outline color.
            width: Stroke width in pixels.
        """
        self._body.write('<ellipse cx="')
        _write_svg_float(self._body, cx)
        self._body.write('" cy="')
        _write_svg_float(self._body, cy)
        self._body.write('" rx="')
        _write_svg_float(self._body, rx)
        self._body.write('" ry="')
        _write_svg_float(self._body, ry)
        self._body.write('" fill="none" stroke="', _to_hex(color), '"')
        _write_opacity(self._body, "stroke", color)
        _write_stroke_attrs(
            self._body,
            width,
            List[Float64](),
            0.0,
            LineCap.ROUND,
            LineJoin.ROUND,
            4.0,
            False,
        )
        self._write_transform()
        self._write_blend()
        self._body.write("/>\n")

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
        self._body.write('<path d="M')
        _write_svg_float(self._body, cx)
        self._body.write(",")
        _write_svg_float(self._body, cy)
        self._body.write(" L")
        _write_svg_float(self._body, x0)
        self._body.write(",")
        _write_svg_float(self._body, y0)
        self._body.write(" A")
        _write_svg_float(self._body, radius)
        self._body.write(",")
        _write_svg_float(self._body, radius)
        self._body.write(" 0 ", large_arc_flag, ",1 ")
        _write_svg_float(self._body, x1)
        self._body.write(",")
        _write_svg_float(self._body, y1)
        self._body.write(' Z" fill="', _to_hex(color), '"')
        _write_opacity(self._body, "fill", color)
        self._write_transform()
        self._write_blend()
        self._body.write("/>\n")

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
        self._body.write('<path d="M')
        _write_svg_float(self._body, outer_x0)
        self._body.write(",")
        _write_svg_float(self._body, outer_y0)
        self._body.write(" A")
        _write_svg_float(self._body, outer_radius)
        self._body.write(",")
        _write_svg_float(self._body, outer_radius)
        self._body.write(" 0 ", large_arc_flag, ",1 ")
        _write_svg_float(self._body, outer_x1)
        self._body.write(",")
        _write_svg_float(self._body, outer_y1)
        self._body.write(" L")
        _write_svg_float(self._body, inner_x1)
        self._body.write(",")
        _write_svg_float(self._body, inner_y1)
        self._body.write(" A")
        _write_svg_float(self._body, inner_radius)
        self._body.write(",")
        _write_svg_float(self._body, inner_radius)
        self._body.write(" 0 ", large_arc_flag, ",0 ")
        _write_svg_float(self._body, inner_x0)
        self._body.write(",")
        _write_svg_float(self._body, inner_y0)
        self._body.write(' Z" fill="', _to_hex(color), '"')
        _write_opacity(self._body, "fill", color)
        self._write_transform()
        self._write_blend()
        self._body.write("/>\n")

    def stroke_path_aa(
        mut self,
        path: Path,
        color: Color,
        width: Float64 = 1.0,
        dashes: List[Float64] = List[Float64](),
        dash_offset: Float64 = 0.0,
        cap: LineCap = LineCap.ROUND,
        join: LineJoin = LineJoin.ROUND,
        miter_limit: Float64 = 4.0,
    ):
        """Emit a `<path>` element, stroked only.

        Args:
            path: Path to stroke.
            color: Stroke color.
            width: Stroke width in pixels.
            dashes: On/off segment lengths in user-space pixels, cycled
                along the stroke. Empty (default) draws a solid line.
            dash_offset: Distance into the dash pattern the stroke
                starts at.
            cap: How an open sub-path's two ends are finished -- see
                LineCap.
            join: How corners are turned -- see LineJoin.
            miter_limit: Ratio past which a MITER join falls back to
                BEVEL, as a multiple of half the stroke width.
        """
        self._body.write('<path d="')
        _write_path_d(self._body, path)
        self._body.write('" fill="none" stroke="', _to_hex(color), '"')
        _write_opacity(self._body, "stroke", color)
        _write_stroke_attrs(
            self._body, width, dashes, dash_offset, cap, join, miter_limit, True
        )
        self._write_transform()
        self._write_blend()
        self._body.write("/>\n")

    def fill_path_aa(
        mut self,
        path: Path,
        color: Color,
        fill_rule: FillRule = FillRule.EVEN_ODD,
    ):
        """Emit a `<path>` element, filled only. The default rule is
        written out as `fill-rule="evenodd"`, since SVG's own default
        is nonzero and the raster backend's is even-odd; a path with a
        hole has to come out the same on both. NONZERO adds nothing,
        being what a renderer does when the attribute is absent.

        Args:
            path: Path to fill.
            color: Fill color.
            fill_rule: EVEN_ODD (default) or NONZERO -- see FillRule.
        """
        var rule = ""
        if fill_rule == FillRule.EVEN_ODD:
            rule = ' fill-rule="evenodd"'
        self._body.write('<path d="')
        _write_path_d(self._body, path)
        self._body.write('" fill="', _to_hex(color), '"', rule)
        _write_opacity(self._body, "fill", color)
        self._write_transform()
        self._write_blend()
        self._body.write("/>\n")

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
        self._body.write("<g>\n<title>", _escape_xml_text(title), "</title>\n")
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
        var anchor = _anchor_name(align)
        var font_weight = ""
        if weight == FontWeight.BOLD:
            font_weight = ' font-weight="bold"'
        self._body.write('<text x="', x, '" y="', y, '" font-size="')
        _write_svg_float(self._body, size)
        self._body.write(
            '" font-family="',
            escaped_family,
            '"',
            font_weight,
            ' fill="',
            _to_hex(color),
            '"',
        )
        _write_opacity(self._body, "fill", color)
        self._body.write(' text-anchor="', anchor, '"')
        # A transform list applies right to left, so the canvas
        # transform goes first and the label's own rotation about its
        # anchor happens before it, as on Canvas.
        if self._transformed or rotation != 0.0:
            self._body.write(' transform="')
            if self._transformed:
                self._write_matrix()
            if rotation != 0.0:
                if self._transformed:
                    self._body.write(" ")
                self._body.write("rotate(")
                _write_svg_float(self._body, rotation * (180.0 / pi))
                self._body.write(" ", x, " ", y, ")")
            self._body.write('"')
        self._write_blend()
        self._body.write(">", _escape_xml_text(text), "</text>\n")

    def stroke_text(
        mut self,
        x: Int,
        y: Int,
        text: String,
        color: Color,
        size: Float64,
        align: TextAlign,
        width: Float64 = 1.0,
        family: String = "sans-serif",
        rotation: Float64 = 0.0,
        weight: FontWeight = FontWeight.NORMAL,
        join: LineJoin = LineJoin.ROUND,
        miter_limit: Float64 = 4.0,
    ):
        """Draw a `<text>` element outlined rather than filled:
        `fill="none"` plus the stroke attributes. The vector
        counterpart of raster `stroke_text`, and like `draw_text` not
        part of `DrawTarget`.

        Everything `draw_text` says about `(x, y)`, `family`, `align`,
        `rotation` and `weight` holds here unchanged; only the paint
        differs.

        No `stroke-linecap` is emitted: a glyph outline is a set of
        closed contours, so it has no ends to cap, and the raster side
        takes no `cap` parameter for the same reason.

        SVG applies `stroke-width` in the element's user space, so an
        outlined label under a scale thickens with it, as on `Canvas`.

        Args:
            x: Anchor x -- baseline left end for TextAlign.LEFT.
            y: Anchor y -- baseline.
            text: Text to draw. No line-break handling for embedded
                "\\n".
            color: Stroke color.
            size: Font size in pixels.
            align: Horizontal alignment relative to (x, y).
            width: Stroke width in user-space pixels.
            family: A literal CSS `font-family` value, not a
                font-matching query -- see draw_text.
            rotation: Radians, rotating the whole `<text>` element
                around (x, y).
            weight: Normal/bold weight.
            join: How a corner of the outline is turned -- see
                LineJoin.
            miter_limit: Ratio past which a MITER join falls back to
                BEVEL, as a multiple of half the stroke width.
        """
        var escaped_family = _escape_xml_attr(family)
        var anchor = _anchor_name(align)
        var font_weight = ""
        if weight == FontWeight.BOLD:
            font_weight = ' font-weight="bold"'
        self._body.write('<text x="', x, '" y="', y, '" font-size="')
        _write_svg_float(self._body, size)
        self._body.write(
            '" font-family="',
            escaped_family,
            '"',
            font_weight,
            ' fill="none" stroke="',
            _to_hex(color),
            '"',
        )
        _write_opacity(self._body, "stroke", color)
        self._body.write(' stroke-width="')
        _write_svg_float(self._body, width)
        self._body.write('" stroke-linejoin="', _join_name(join), '"')
        if join == LineJoin.MITER and miter_limit != 4.0:
            self._body.write(' stroke-miterlimit="')
            _write_svg_float(self._body, miter_limit)
            self._body.write('"')
        self._body.write(' text-anchor="', anchor, '"')
        # A transform list applies right to left, so the canvas
        # transform goes first and the label's own rotation about its
        # anchor happens before it, as in draw_text.
        if self._transformed or rotation != 0.0:
            self._body.write(' transform="')
            if self._transformed:
                self._write_matrix()
            if rotation != 0.0:
                if self._transformed:
                    self._body.write(" ")
                self._body.write("rotate(")
                _write_svg_float(self._body, rotation * (180.0 / pi))
                self._body.write(" ", x, " ", y, ")")
            self._body.write('"')
        self._write_blend()
        self._body.write(">", _escape_xml_text(text), "</text>\n")

    def draw_text_on_path(
        mut self,
        path: Path,
        text: String,
        color: Color,
        size: Float64,
        align: TextAlign,
        offset: Float64 = 0.0,
        family: String = "sans-serif",
        weight: FontWeight = FontWeight.NORMAL,
    ):
        """Draw `text` along `path`, as a `<textPath>` referring to a
        `<path>` in a `<defs>` block emitted just before it. The vector
        counterpart of raster `draw_text_on_path`.

        Each call mints a fresh id (`tpN`), so two calls never collide
        and a path drawn as well as labelled is written twice rather
        than shared -- the visible path carries its own paint.

        `offset` becomes `startOffset`, a distance along the path, for
        all three alignments: SVG anchors a `<textPath>` at
        `startOffset` and then applies `text-anchor` about it, which is
        exactly what the raster side's `align` does.

        A renderer drops the glyphs that do not fit on the path, the
        rule the raster side applies to a glyph whose centre falls past
        an end.

        Args:
            path: Curve the baseline follows.
            text: Text to draw, one line.
            color: Text color.
            size: Font size in pixels.
            align: Where `offset` sits in the string -- its start,
                middle or end.
            offset: Distance along the path the string is placed at.
            family: A literal CSS `font-family` value, not a
                font-matching query -- see draw_text.
            weight: Normal/bold weight.
        """
        self._text_path_count += 1
        self._body.write('<defs><path id="tp', self._text_path_count, '" d="')
        _write_path_d(self._body, path)
        self._body.write('"/></defs>\n')

        var escaped_family = _escape_xml_attr(family)
        var font_weight = ""
        if weight == FontWeight.BOLD:
            font_weight = ' font-weight="bold"'
        self._body.write('<text font-size="')
        _write_svg_float(self._body, size)
        self._body.write(
            '" font-family="',
            escaped_family,
            '"',
            font_weight,
            ' fill="',
            _to_hex(color),
            '"',
        )
        _write_opacity(self._body, "fill", color)
        self._body.write(' text-anchor="', _anchor_name(align), '"')
        self._write_transform()
        self._write_blend()
        self._body.write('><textPath href="#tp', self._text_path_count)
        self._body.write('" startOffset="')
        _write_svg_float(self._body, offset)
        self._body.write('">', _escape_xml_text(text), "</textPath></text>\n")

    def set_title(mut self, title: String, description: String = ""):
        """Give the document an accessible title: the root `<svg>` gains
        `role="img"` and `aria-label`, and `<title>` (and `<desc>` when
        `description` is non-empty) become its first children, which is
        what screen readers that walk an SVG's accessible tree look
        for. The document-level counterpart of `begin_annotated_group`.

        Both strings are escaped here; pass them raw. Calling again
        replaces the previous title. An empty `title` removes it.

        This helps where the SVG's accessible tree is walked: inline
        markup, a standalone file, or an `<object>`/`<iframe>` embed.
        A plain `<img src="chart.svg">` treats the SVG as an opaque
        image and reads the `<img>`'s `alt` text instead.

        Args:
            title: Short accessible name for the whole document.
            description: Longer description, optional.
        """
        self._title = title
        self._description = description

    def _root_open(self) -> String:
        """The opening `<svg>` tag plus the title children `set_title`
        asked for, if any.
        """
        var out = (
            '<svg xmlns="http://www.w3.org/2000/svg" width="'
            + String(self.width)
            + '" height="'
            + String(self.height)
            + '" viewBox="0 0 '
            + String(self.width)
            + " "
            + String(self.height)
            + '"'
        )
        if self._title.byte_length() == 0:
            return out + ">\n"
        out += (
            ' role="img" aria-label="'
            + _escape_xml_attr(self._title)
            + '">\n<title>'
            + _escape_xml_text(self._title)
            + "</title>\n"
        )
        if self._description.byte_length() > 0:
            out += "<desc>" + _escape_xml_text(self._description) + "</desc>\n"
        return out

    def to_string(self) -> String:
        return (
            self._root_open()
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
