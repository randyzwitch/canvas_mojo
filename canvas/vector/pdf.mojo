"""`PdfCanvas`: a `DrawTarget` that writes a one-page PDF, the third
backend beside `Canvas` (raster) and `SvgCanvas` (SVG markup), and
the one output a chart library's users ask for after PNG and SVG.

Every call appends operators to the page's content stream, in the
same coordinate space the other backends use: the stream opens with
`1 0 0 -1 0 h cm`, which flips PDF's bottom-left, y-up page onto the
canvas's top-left, y-down pixels, so a caller's numbers go through
unchanged and one unit is one point (1/72 inch). The page is
`width x height` points.

What maps onto PDF one to one: `Path` onto `m`/`l`/`c`/`h` (a quadratic
is raised to a cubic, an `arc_to` becomes cubic arcs of at most a
quarter turn each), the two fill rules onto `f` and `f*`, strokes onto
`w`/`J`/`j`/`M`/`d`/`S`, the transform onto `cm` inside a `q`/`Q` pair
around each element (as `SvgCanvas` writes a `transform` attribute per
element, so no CTM state has to be tracked), a translucent color or a
blend mode onto an `ExtGState` (`/ca`, `/CA`, `/BM`), a rectangle or
path clip onto `re W n` / `W n` inside a `q` that `pop_clip` closes
with `Q`, and a linear or radial gradient onto an axial or radial
shading (`sh`) with a stitching function over the stops, clipped to
the shape. Text is drawn as outlines through `canvas.text.text_path`,
so it needs no font embedding and looks exactly as the raster backend
draws it, at the cost of not being selectable; embedding a font subset
is the follow-up. The content stream is Flate-compressed through this
package's own `deflate`.

Not expressible here, and said so rather than approximated: the
Porter-Duff operators other than source-over (a PDF blend mode is a
separable or non-separable mode only), alpha on gradient stops (a
shading has no per-stop opacity), conic gradients, `ColorSpace.LINEAR`
(PDF has no linear-light compositing switch; the setting is kept for
`color_space` and otherwise ignored), and canvas-to-canvas image
drawing. Annotated groups become marked content
(`/Span << /Alt (title) >> BDC ... EMC`), which is what a PDF has for
"this run of drawing has a label".
"""

from std.math import cos, sin, pi, sqrt, ceil

from canvas.blend import BlendMode
from canvas.color import Color, ColorSpace
from canvas.fill_rule import FillRule
from canvas.geometry import Matrix2D, FPoint
from canvas.gradient import GradientStops, LinearGradient, RadialGradient
from canvas.io.deflate import deflate
from canvas.io.png import _adler32
from canvas.path import Path, PathOp
from canvas.shapes.lines import LineCap, LineJoin
from canvas.text.font_cache import FontCache
from canvas.text.font_discovery import FontSlant, FontWeight
from canvas.text.render import text_path
from canvas.text.text_align import TextAlign
from canvas.vector.draw_target import DrawTarget
from canvas.vector.svg import _write_svg_float

# Cubic Bezier control-point distance for a quarter circle of unit
# radius: 4/3 * tan(pi/8).
comptime _KAPPA = 0.5522847498307936


def _pdf_blend_name(mode: BlendMode) -> String:
    """The `/BM` name for a blend mode, or "" for SOURCE_OVER and the
    Porter-Duff operators PDF cannot express."""
    if mode == BlendMode.MULTIPLY:
        return "Multiply"
    if mode == BlendMode.SCREEN:
        return "Screen"
    if mode == BlendMode.OVERLAY:
        return "Overlay"
    if mode == BlendMode.DARKEN:
        return "Darken"
    if mode == BlendMode.LIGHTEN:
        return "Lighten"
    if mode == BlendMode.COLOR_DODGE:
        return "ColorDodge"
    if mode == BlendMode.COLOR_BURN:
        return "ColorBurn"
    if mode == BlendMode.HARD_LIGHT:
        return "HardLight"
    if mode == BlendMode.SOFT_LIGHT:
        return "SoftLight"
    if mode == BlendMode.DIFFERENCE:
        return "Difference"
    if mode == BlendMode.EXCLUSION:
        return "Exclusion"
    if mode == BlendMode.HUE:
        return "Hue"
    if mode == BlendMode.SATURATION:
        return "Saturation"
    if mode == BlendMode.COLOR:
        return "Color"
    if mode == BlendMode.LUMINOSITY:
        return "Luminosity"
    return ""


def _num(mut out: String, value: Float64):
    """Append `value` and a space, at three decimals."""
    _write_svg_float(out, value)
    out += " "


def _channel(mut out: String, byte: UInt8):
    _num(out, Float64(byte) / 255.0)


def _pdf_string(text: String) -> String:
    """`text` as a PDF literal string: parentheses and backslashes
    escaped, everything else as its bytes."""
    var out = String("(")
    for cp in text.codepoints():
        var c = Int(cp)
        if c == 40 or c == 41 or c == 92:
            out += "\\"
        if c < 128:
            out += chr(c)
        else:
            out += "?"
    out += ")"
    return out


struct _PdfState(ImplicitlyCopyable, Movable):
    """What `PdfCanvas.save` records and `restore` puts back."""

    var transform: Matrix2D
    var transformed: Bool
    var blend: BlendMode
    var space: ColorSpace
    var clip_depth: Int

    def __init__(
        out self,
        transform: Matrix2D,
        transformed: Bool,
        blend: BlendMode,
        space: ColorSpace,
        clip_depth: Int,
    ):
        self.transform = transform
        self.transformed = transformed
        self.blend = blend
        self.space = space
        self.clip_depth = clip_depth


struct PdfCanvas(DrawTarget, Movable):
    """A one-page PDF document built from `DrawTarget` calls; see the
    module docstring for what each becomes. `to_bytes` produces the
    file, `write_pdf` writes it.
    """

    var width: Int
    var height: Int
    var _content: String
    # ExtGState dictionaries by their body text, so two elements with
    # the same alpha and blend share one resource.
    var _gstates: List[String]
    # Shading dictionaries, one per gradient fill.
    var _shadings: List[String]
    var _transform: Matrix2D
    var _transformed: Bool
    var _blend: BlendMode
    var _space: ColorSpace
    var _clip_depth: Int
    var _saved: List[_PdfState]
    var _open_group: Bool
    var _title: String
    var _fonts: FontCache

    def __init__(out self, width: Int, height: Int) raises:
        """An empty page of `width x height` points.

        Args:
            width: Page width in points.
            height: Page height in points.
        """
        self.width = width
        self.height = height
        self._content = ""
        self._gstates = List[String]()
        self._shadings = List[String]()
        self._transform = Matrix2D.identity()
        self._transformed = False
        self._blend = BlendMode.SOURCE_OVER
        self._space = ColorSpace.SRGB
        self._clip_depth = 0
        self._saved = List[_PdfState]()
        self._open_group = False
        self._title = ""
        self._fonts = FontCache()

    # ---- state -------------------------------------------------------

    def save(mut self):
        """Push the transform, blend mode, color space and clip depth
        for `restore` to put back, as `Canvas.save` does."""
        self._saved.append(
            _PdfState(
                self._transform,
                self._transformed,
                self._blend,
                self._space,
                self._clip_depth,
            )
        )

    def restore(mut self):
        """Pop the state `save` pushed, closing every clip pushed
        since. A no-op with nothing saved."""
        if len(self._saved) == 0:
            return
        var state = self._saved.pop()
        while self._clip_depth > state.clip_depth:
            self.pop_clip()
        self._transform = state.transform
        self._transformed = state.transformed
        self._blend = state.blend
        self._space = state.space

    def _set_transform(mut self, matrix: Matrix2D):
        self._transform = matrix
        self._transformed = not matrix.is_identity()

    def translate(mut self, tx: Float64, ty: Float64):
        """Move the origin by (tx, ty) in the current user space."""
        self._set_transform(Matrix2D.translation(tx, ty).then(self._transform))

    def rotate(mut self, angle: Float64):
        """Rotate later drawing by `angle` radians about the origin."""
        self._set_transform(Matrix2D.rotation(angle).then(self._transform))

    def scale(mut self, sx: Float64, sy: Float64):
        """Scale later drawing by (sx, sy) about the origin."""
        self._set_transform(Matrix2D.scaling(sx, sy).then(self._transform))

    def transform(mut self, matrix: Matrix2D):
        """Apply `matrix` ahead of the current transform."""
        self._set_transform(matrix.then(self._transform))

    def set_transform(mut self, matrix: Matrix2D):
        """Replace the current transform with `matrix`."""
        self._set_transform(matrix)

    def reset_transform(mut self):
        """Back to the identity."""
        self._set_transform(Matrix2D.identity())

    def current_transform(self) -> Matrix2D:
        """The transform later drawing goes through."""
        return self._transform

    def has_transform(self) -> Bool:
        """Whether the current transform is not the identity."""
        return self._transformed

    def set_blend_mode(mut self, mode: BlendMode):
        """Set the blend mode later elements carry as an `ExtGState`
        `/BM`. The Porter-Duff operators have no PDF equivalent and
        draw source-over.

        Args:
            mode: The blend mode later elements carry.
        """
        self._blend = mode

    def blend_mode(self) -> BlendMode:
        """The blend mode later elements carry."""
        return self._blend

    def set_color_space(mut self, space: ColorSpace):
        """Recorded for `color_space` and `save`/`restore`; PDF has no
        linear-light compositing to ask for, so it changes nothing
        drawn.

        Args:
            space: The color space, kept but not applied.
        """
        self._space = space

    def color_space(self) -> ColorSpace:
        """The color space last set."""
        return self._space

    def set_title(mut self, title: String):
        """The document's `/Title`, in its `/Info` dictionary.

        Args:
            title: Document title.
        """
        self._title = title

    # ---- element framing ------------------------------------------

    def _gstate(mut self, alpha: UInt8, stroke: Bool) -> Int:
        """The index of the ExtGState for `alpha` under the current
        blend mode, made if new, or -1 when none is needed."""
        var bm = _pdf_blend_name(self._blend)
        if alpha == 255 and bm == "":
            return -1
        var body = String()
        if alpha != 255:
            body += "/CA " if stroke else "/ca "
            _channel(body, alpha)
        if bm != "":
            body += "/BM /" + bm + " "
        for i in range(len(self._gstates)):
            if self._gstates[i] == body:
                return i
        self._gstates.append(body)
        return len(self._gstates) - 1

    def _begin(mut self, color: Color, stroke: Bool):
        """`q`, the transform, the graphics state and the color for an
        element about to be painted."""
        self._content += "q "
        if self._transformed:
            self._write_cm()
        var gs = self._gstate(color.a, stroke)
        if gs >= 0:
            self._content += "/GS" + String(gs + 1) + " gs "
        _channel(self._content, color.r)
        _channel(self._content, color.g)
        _channel(self._content, color.b)
        self._content += "RG " if stroke else "rg "

    def _end(mut self):
        self._content += "Q\n"

    def _write_cm(mut self):
        var m = self._transform
        _num(self._content, m.a)
        _num(self._content, m.b)
        _num(self._content, m.c)
        _num(self._content, m.d)
        _num(self._content, m.e)
        _num(self._content, m.f)
        self._content += "cm "

    def _write_stroke_attrs(
        mut self,
        width: Float64,
        dashes: List[Float64],
        dash_offset: Float64,
        cap: LineCap,
        join: LineJoin,
        miter_limit: Float64,
    ):
        _num(self._content, width)
        self._content += "w "
        var j = 0
        if cap == LineCap.ROUND:
            j = 1
        elif cap == LineCap.SQUARE:
            j = 2
        self._content += String(j) + " J "
        var jn = 0
        if join == LineJoin.ROUND:
            jn = 1
        elif join == LineJoin.BEVEL:
            jn = 2
        self._content += String(jn) + " j "
        _num(self._content, miter_limit)
        self._content += "M "
        if len(dashes) > 0:
            self._content += "["
            for d in dashes:
                _num(self._content, d)
            self._content += "] "
            _num(self._content, dash_offset)
            self._content += "d "

    # ---- path construction ----------------------------------------

    def _arc_segments(
        mut self,
        cx: Float64,
        cy: Float64,
        radius: Float64,
        start_angle: Float64,
        end_angle: Float64,
        move: Bool,
    ):
        """Cubic arcs from `start_angle` to `end_angle` (radians, the
        canvas's clockwise-positive convention) on the circle at
        (cx, cy), each at most a quarter turn: a Bezier tracks a
        circle to within a few thousandths of the radius over that
        much. `move` starts a sub-path at the arc's first point;
        otherwise a line is drawn to it."""
        var sweep = end_angle - start_angle
        var steps = Int(ceil(abs(sweep) / (pi / 2.0) - 1.0e-9))
        if steps < 1:
            steps = 1
        var step = sweep / Float64(steps)
        var k = (
            4.0 / 3.0 * (1.0 - cos(step / 2.0)) / sin(step / 2.0) if step
            != 0.0 else 0.0
        )
        var a = start_angle
        var x0 = cx + radius * cos(a)
        var y0 = cy + radius * sin(a)
        _num(self._content, x0)
        _num(self._content, y0)
        self._content += "m " if move else "l "
        for _ in range(steps):
            var b = a + step
            var x1 = cx + radius * cos(b)
            var y1 = cy + radius * sin(b)
            var c1x = x0 - radius * k * sin(a)
            var c1y = y0 + radius * k * cos(a)
            var c2x = x1 + radius * k * sin(b)
            var c2y = y1 - radius * k * cos(b)
            _num(self._content, c1x)
            _num(self._content, c1y)
            _num(self._content, c2x)
            _num(self._content, c2y)
            _num(self._content, x1)
            _num(self._content, y1)
            self._content += "c "
            a = b
            x0 = x1
            y0 = y1

    def _ellipse(mut self, cx: Float64, cy: Float64, rx: Float64, ry: Float64):
        """A closed ellipse as four cubics."""
        var kx = rx * _KAPPA
        var ky = ry * _KAPPA
        _num(self._content, cx + rx)
        _num(self._content, cy)
        self._content += "m "
        self._cubic(cx + rx, cy + ky, cx + kx, cy + ry, cx, cy + ry)
        self._cubic(cx - kx, cy + ry, cx - rx, cy + ky, cx - rx, cy)
        self._cubic(cx - rx, cy - ky, cx - kx, cy - ry, cx, cy - ry)
        self._cubic(cx + kx, cy - ry, cx + rx, cy - ky, cx + rx, cy)
        self._content += "h "

    def _cubic(
        mut self,
        c1x: Float64,
        c1y: Float64,
        c2x: Float64,
        c2y: Float64,
        x: Float64,
        y: Float64,
    ):
        _num(self._content, c1x)
        _num(self._content, c1y)
        _num(self._content, c2x)
        _num(self._content, c2y)
        _num(self._content, x)
        _num(self._content, y)
        self._content += "c "

    def _write_path(mut self, path: Path):
        """`path`'s commands as PDF path construction operators. A
        quadratic is raised to the cubic with the same curve; an arc
        becomes quarter-turn cubics."""
        var cur_x = 0.0
        var cur_y = 0.0
        var start_x = 0.0
        var start_y = 0.0
        var have = False
        for cmd in path.commands:
            if cmd.op == PathOp.MOVE_TO:
                _num(self._content, cmd.p1.x)
                _num(self._content, cmd.p1.y)
                self._content += "m "
                cur_x = cmd.p1.x
                cur_y = cmd.p1.y
                start_x = cur_x
                start_y = cur_y
                have = True
            elif cmd.op == PathOp.LINE_TO:
                _num(self._content, cmd.p1.x)
                _num(self._content, cmd.p1.y)
                self._content += "l "
                cur_x = cmd.p1.x
                cur_y = cmd.p1.y
            elif cmd.op == PathOp.QUAD_TO:
                var c1x = cur_x + 2.0 / 3.0 * (cmd.p1.x - cur_x)
                var c1y = cur_y + 2.0 / 3.0 * (cmd.p1.y - cur_y)
                var c2x = cmd.p2.x + 2.0 / 3.0 * (cmd.p1.x - cmd.p2.x)
                var c2y = cmd.p2.y + 2.0 / 3.0 * (cmd.p1.y - cmd.p2.y)
                self._cubic(c1x, c1y, c2x, c2y, cmd.p2.x, cmd.p2.y)
                cur_x = cmd.p2.x
                cur_y = cmd.p2.y
            elif cmd.op == PathOp.CUBIC_TO:
                self._cubic(
                    cmd.p1.x, cmd.p1.y, cmd.p2.x, cmd.p2.y, cmd.p3.x, cmd.p3.y
                )
                cur_x = cmd.p3.x
                cur_y = cmd.p3.y
            elif cmd.op == PathOp.ARC_TO:
                var cx = cmd.p1.x
                var cy = cmd.p1.y
                var r = cmd.p2.x
                var a0 = cmd.p2.y
                var a1 = cmd.p3.x
                self._arc_segments(cx, cy, r, a0, a1, not have)
                if not have:
                    start_x = cx + r * cos(a0)
                    start_y = cy + r * sin(a0)
                    have = True
                cur_x = cx + r * cos(a1)
                cur_y = cy + r * sin(a1)
            else:  # CLOSE
                self._content += "h "
                cur_x = start_x
                cur_y = start_y

    def _fill_op(mut self, fill_rule: FillRule):
        self._content += "f* " if fill_rule == FillRule.EVEN_ODD else "f "

    # ---- primitives -----------------------------------------------

    def fill_rect(
        mut self, x: Int, y: Int, width: Int, height: Int, color: Color
    ):
        """A filled rectangle (`re f`).

        Args:
            x: Left edge.
            y: Top edge.
            width: Width.
            height: Height.
            color: Fill color.
        """
        self.fill_rect(
            Float64(x), Float64(y), Float64(width), Float64(height), color
        )

    def fill_rect(
        mut self,
        x: Float64,
        y: Float64,
        width: Float64,
        height: Float64,
        color: Color,
    ):
        """A filled rectangle at a geometric position.

        Args:
            x: Left edge.
            y: Top edge.
            width: Width.
            height: Height.
            color: Fill color.
        """
        if width <= 0.0 or height <= 0.0:
            return
        self._begin(color, False)
        _num(self._content, x)
        _num(self._content, y)
        _num(self._content, width)
        _num(self._content, height)
        self._content += "re f "
        self._end()

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
        """A stroked line segment.

        Args:
            x0: Start x.
            y0: Start y.
            x1: End x.
            y1: End y.
            color: Stroke color.
            width: Stroke width.
            dashes: On/off lengths; empty for solid.
            dash_offset: Distance into the dash pattern to start.
            cap: Line cap.
            join: Line join (unused on a single segment).
            miter_limit: Miter limit.
        """
        self.draw_line_aa(
            Float64(x0),
            Float64(y0),
            Float64(x1),
            Float64(y1),
            color,
            width,
            dashes,
            dash_offset,
            cap,
            join,
            miter_limit,
        )

    def draw_line_aa(
        mut self,
        x0: Float64,
        y0: Float64,
        x1: Float64,
        y1: Float64,
        color: Color,
        width: Float64 = 1.0,
        dashes: List[Float64] = List[Float64](),
        dash_offset: Float64 = 0.0,
        cap: LineCap = LineCap.ROUND,
        join: LineJoin = LineJoin.ROUND,
        miter_limit: Float64 = 4.0,
    ):
        """A stroked line segment at geometric endpoints.

        Args:
            x0: Start x.
            y0: Start y.
            x1: End x.
            y1: End y.
            color: Stroke color.
            width: Stroke width.
            dashes: On/off lengths; empty for solid.
            dash_offset: Distance into the dash pattern to start.
            cap: Line cap.
            join: Line join (unused on a single segment).
            miter_limit: Miter limit.
        """
        self._begin(color, True)
        self._write_stroke_attrs(
            width, dashes, dash_offset, cap, join, miter_limit
        )
        _num(self._content, x0)
        _num(self._content, y0)
        self._content += "m "
        _num(self._content, x1)
        _num(self._content, y1)
        self._content += "l S "
        self._end()

    def fill_circle_aa(mut self, cx: Int, cy: Int, radius: Int, color: Color):
        """A filled circle.

        Args:
            cx: Center x.
            cy: Center y.
            radius: Radius.
            color: Fill color.
        """
        self.fill_circle_aa(Float64(cx), Float64(cy), Float64(radius), color)

    def fill_circle_aa(
        mut self, cx: Float64, cy: Float64, radius: Float64, color: Color
    ):
        """A filled circle at a geometric center.

        Args:
            cx: Center x.
            cy: Center y.
            radius: Radius.
            color: Fill color.
        """
        if radius <= 0.0:
            return
        self._begin(color, False)
        self._ellipse(cx, cy, radius, radius)
        self._content += "f "
        self._end()

    def draw_circle_aa(
        mut self,
        cx: Float64,
        cy: Float64,
        radius: Float64,
        color: Color,
        width: Float64 = 1.0,
    ):
        """A stroked circle.

        Args:
            cx: Center x.
            cy: Center y.
            radius: Radius.
            color: Stroke color.
            width: Stroke width.
        """
        if radius <= 0.0:
            return
        self._begin(color, True)
        _num(self._content, width)
        self._content += "w "
        self._ellipse(cx, cy, radius, radius)
        self._content += "S "
        self._end()

    def fill_ellipse_aa(
        mut self, cx: Int, cy: Int, rx: Int, ry: Int, color: Color
    ):
        """A filled ellipse.

        Args:
            cx: Center x.
            cy: Center y.
            rx: Horizontal radius.
            ry: Vertical radius.
            color: Fill color.
        """
        self.fill_ellipse_aa(
            Float64(cx), Float64(cy), Float64(rx), Float64(ry), color
        )

    def fill_ellipse_aa(
        mut self,
        cx: Float64,
        cy: Float64,
        rx: Float64,
        ry: Float64,
        color: Color,
    ):
        """A filled ellipse at a geometric center.

        Args:
            cx: Center x.
            cy: Center y.
            rx: Horizontal radius.
            ry: Vertical radius.
            color: Fill color.
        """
        if rx <= 0.0 or ry <= 0.0:
            return
        self._begin(color, False)
        self._ellipse(cx, cy, rx, ry)
        self._content += "f "
        self._end()

    def draw_ellipse_aa(
        mut self, cx: Int, cy: Int, rx: Int, ry: Int, color: Color
    ):
        """A stroked ellipse, one unit wide.

        Args:
            cx: Center x.
            cy: Center y.
            rx: Horizontal radius.
            ry: Vertical radius.
            color: Stroke color.
        """
        self.draw_ellipse_aa(
            Float64(cx), Float64(cy), Float64(rx), Float64(ry), color, 1.0
        )

    def draw_ellipse_aa(
        mut self,
        cx: Float64,
        cy: Float64,
        rx: Float64,
        ry: Float64,
        color: Color,
        width: Float64 = 1.0,
    ):
        """A stroked ellipse.

        Args:
            cx: Center x.
            cy: Center y.
            rx: Horizontal radius.
            ry: Vertical radius.
            color: Stroke color.
            width: Stroke width.
        """
        if rx <= 0.0 or ry <= 0.0:
            return
        self._begin(color, True)
        _num(self._content, width)
        self._content += "w "
        self._ellipse(cx, cy, rx, ry)
        self._content += "S "
        self._end()

    def fill_arc_aa(
        mut self,
        cx: Float64,
        cy: Float64,
        radius: Float64,
        start_angle: Float64,
        end_angle: Float64,
        color: Color,
    ):
        """A filled pie wedge from `start_angle` to `end_angle`.

        Args:
            cx: Center x.
            cy: Center y.
            radius: Radius.
            start_angle: Start angle, radians.
            end_angle: End angle, radians.
            color: Fill color.
        """
        if radius <= 0.0 or end_angle <= start_angle:
            return
        self._begin(color, False)
        _num(self._content, cx)
        _num(self._content, cy)
        self._content += "m "
        self._arc_segments(cx, cy, radius, start_angle, end_angle, False)
        self._content += "h f "
        self._end()

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
        """A filled annular sector (donut segment).

        Args:
            cx: Center x.
            cy: Center y.
            inner_radius: Inner radius.
            outer_radius: Outer radius.
            start_angle: Start angle, radians.
            end_angle: End angle, radians.
            color: Fill color.
        """
        if outer_radius <= 0.0 or end_angle <= start_angle:
            return
        self._begin(color, False)
        self._arc_segments(cx, cy, outer_radius, start_angle, end_angle, True)
        if inner_radius > 0.0:
            self._arc_segments(
                cx, cy, inner_radius, end_angle, start_angle, False
            )
        else:
            _num(self._content, cx)
            _num(self._content, cy)
            self._content += "l "
        self._content += "h f "
        self._end()

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
        """Stroke `path`.

        Args:
            path: Path to stroke.
            color: Stroke color.
            width: Stroke width.
            dashes: On/off lengths; empty for solid.
            dash_offset: Distance into the dash pattern to start.
            cap: Line cap.
            join: Line join.
            miter_limit: Miter limit.
        """
        if len(path.commands) == 0:
            return
        self._begin(color, True)
        self._write_stroke_attrs(
            width, dashes, dash_offset, cap, join, miter_limit
        )
        self._write_path(path)
        self._content += "S "
        self._end()

    def fill_path_aa(
        mut self,
        path: Path,
        color: Color,
        fill_rule: FillRule = FillRule.EVEN_ODD,
    ):
        """Fill `path` under `fill_rule`.

        Args:
            path: Path to fill.
            color: Fill color.
            fill_rule: EVEN_ODD (`f*`) or NONZERO (`f`).
        """
        if len(path.commands) == 0:
            return
        self._begin(color, False)
        self._write_path(path)
        self._fill_op(fill_rule)
        self._end()

    # ---- gradients ------------------------------------------------

    def _function(self, stops: GradientStops) -> String:
        """A PDF function over the stops' offsets: one Type 2 between
        two stops, a Type 3 stitching of them between more. Alpha is
        dropped. Equal offsets (a hard step) are nudged apart, since
        `/Bounds` must increase strictly."""
        var n = len(stops)
        var offsets = List[Float64](capacity=n)
        for i in range(n):
            var t = stops[i].offset
            if i > 0 and t <= offsets[i - 1]:
                t = offsets[i - 1] + 1.0e-6
            offsets.append(t)
        var t0 = offsets[0]
        var t1 = offsets[n - 1]
        var out = String()
        if n == 2:
            out += "<< /FunctionType 2 /Domain ["
            _num(out, t0)
            _num(out, t1)
            out += "] /C0 ["
            _channel(out, stops[0].color.r)
            _channel(out, stops[0].color.g)
            _channel(out, stops[0].color.b)
            out += "] /C1 ["
            _channel(out, stops[1].color.r)
            _channel(out, stops[1].color.g)
            _channel(out, stops[1].color.b)
            out += "] /N 1 >>"
            return out
        out += "<< /FunctionType 3 /Domain ["
        _num(out, t0)
        _num(out, t1)
        out += "] /Functions ["
        for i in range(n - 1):
            out += "<< /FunctionType 2 /Domain [0 1] /C0 ["
            _channel(out, stops[i].color.r)
            _channel(out, stops[i].color.g)
            _channel(out, stops[i].color.b)
            out += "] /C1 ["
            _channel(out, stops[i + 1].color.r)
            _channel(out, stops[i + 1].color.g)
            _channel(out, stops[i + 1].color.b)
            out += "] /N 1 >> "
        out += "] /Bounds ["
        for i in range(1, n - 1):
            _num(out, offsets[i])
        out += "] /Encode ["
        for _ in range(n - 1):
            out += "0 1 "
        out += "] >>"
        return out

    def _axial_shading(mut self, gradient: LinearGradient) -> Int:
        """A Type 2 shading resource for `gradient`; returns its index,
        or -1 when the ramp has under two stops."""
        if len(gradient.stops) < 2:
            return -1
        var s = String("<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [")
        _num(s, gradient.x0)
        _num(s, gradient.y0)
        _num(s, gradient.x1)
        _num(s, gradient.y1)
        s += "] /Domain ["
        _num(s, gradient.stops[0].offset)
        _num(s, gradient.stops[len(gradient.stops) - 1].offset)
        s += "] /Function " + self._function(gradient.stops)
        s += " /Extend [true true] >>"
        self._shadings.append(s)
        return len(self._shadings) - 1

    def _radial_shading(mut self, gradient: RadialGradient) -> Int:
        """A Type 3 shading resource for `gradient`; returns its index,
        or -1 when the ramp has under two stops."""
        if len(gradient.stops) < 2:
            return -1
        var s = String("<< /ShadingType 3 /ColorSpace /DeviceRGB /Coords [")
        if gradient._focal:
            _num(s, gradient.fx)
            _num(s, gradient.fy)
            _num(s, gradient.fr)
        else:
            _num(s, gradient.cx)
            _num(s, gradient.cy)
            _num(s, 0.0)
        _num(s, gradient.cx)
        _num(s, gradient.cy)
        _num(s, gradient.radius)
        s += "] /Domain ["
        _num(s, gradient.stops[0].offset)
        _num(s, gradient.stops[len(gradient.stops) - 1].offset)
        s += "] /Function " + self._function(gradient.stops)
        s += " /Extend [true true] >>"
        self._shadings.append(s)
        return len(self._shadings) - 1

    def _paint_shading(mut self, index: Int):
        """`sh` the shading after the clip already written."""
        self._content += "/Sh" + String(index + 1) + " sh "

    def _begin_clip_element(mut self):
        self._content += "q "
        if self._transformed:
            self._write_cm()
        var gs = self._gstate(255, False)
        if gs >= 0:
            self._content += "/GS" + String(gs + 1) + " gs "

    def fill_rect_gradient(
        mut self,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        gradient: LinearGradient,
    ):
        """A rectangle filled with an axial shading.

        Args:
            x: Left edge.
            y: Top edge.
            width: Width.
            height: Height.
            gradient: The linear gradient, in page coordinates.
        """
        self.fill_rect_gradient(
            Float64(x), Float64(y), Float64(width), Float64(height), gradient
        )

    def fill_rect_gradient(
        mut self,
        x: Float64,
        y: Float64,
        width: Float64,
        height: Float64,
        gradient: LinearGradient,
    ):
        """A rectangle at a geometric position filled with an axial
        shading; a one-stop ramp fills solid with that color.

        Args:
            x: Left edge.
            y: Top edge.
            width: Width.
            height: Height.
            gradient: The linear gradient, in page coordinates.
        """
        if width <= 0.0 or height <= 0.0 or len(gradient.stops) == 0:
            return
        var sh = self._axial_shading(gradient)
        if sh < 0:
            self.fill_rect(x, y, width, height, gradient.stops[0].color)
            return
        self._begin_clip_element()
        _num(self._content, x)
        _num(self._content, y)
        _num(self._content, width)
        _num(self._content, height)
        self._content += "re W n "
        self._paint_shading(sh)
        self._end()

    def fill_rect_radial_gradient(
        mut self,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        gradient: RadialGradient,
    ):
        """A rectangle filled with a radial shading. Not on
        `DrawTarget`; call once a caller knows it holds a `PdfCanvas`.

        Args:
            x: Left edge.
            y: Top edge.
            width: Width.
            height: Height.
            gradient: The radial gradient, in page coordinates.
        """
        if width <= 0 or height <= 0 or len(gradient.stops) == 0:
            return
        var sh = self._radial_shading(gradient)
        if sh < 0:
            self.fill_rect(x, y, width, height, gradient.stops[0].color)
            return
        self._begin_clip_element()
        _num(self._content, Float64(x))
        _num(self._content, Float64(y))
        _num(self._content, Float64(width))
        _num(self._content, Float64(height))
        self._content += "re W n "
        self._paint_shading(sh)
        self._end()

    def fill_path_gradient_aa(
        mut self,
        path: Path,
        gradient: LinearGradient,
        fill_rule: FillRule = FillRule.EVEN_ODD,
    ):
        """`path` filled with an axial shading, clipped under
        `fill_rule`. Not on `DrawTarget`.

        Args:
            path: Path to fill.
            gradient: The linear gradient, in page coordinates.
            fill_rule: Clip rule for the path.
        """
        if len(path.commands) == 0 or len(gradient.stops) == 0:
            return
        var sh = self._axial_shading(gradient)
        if sh < 0:
            self.fill_path_aa(path, gradient.stops[0].color, fill_rule)
            return
        self._begin_clip_element()
        self._write_path(path)
        self._content += "W* n " if fill_rule == FillRule.EVEN_ODD else "W n "
        self._paint_shading(sh)
        self._end()

    def fill_path_radial_gradient_aa(
        mut self,
        path: Path,
        gradient: RadialGradient,
        fill_rule: FillRule = FillRule.EVEN_ODD,
    ):
        """`path` filled with a radial shading, clipped under
        `fill_rule`. Not on `DrawTarget`.

        Args:
            path: Path to fill.
            gradient: The radial gradient, in page coordinates.
            fill_rule: Clip rule for the path.
        """
        if len(path.commands) == 0 or len(gradient.stops) == 0:
            return
        var sh = self._radial_shading(gradient)
        if sh < 0:
            self.fill_path_aa(path, gradient.stops[0].color, fill_rule)
            return
        self._begin_clip_element()
        self._write_path(path)
        self._content += "W* n " if fill_rule == FillRule.EVEN_ODD else "W n "
        self._paint_shading(sh)
        self._end()

    # ---- clipping -------------------------------------------------

    def push_clip(mut self, x: Int, y: Int, width: Int, height: Int) raises:
        """Clip later drawing to a rectangle, intersected with any
        active clip, until `pop_clip`. Under a transform the rectangle
        is in the transformed space, as the other backends have it.

        Args:
            x: Left edge.
            y: Top edge.
            width: Width.
            height: Height.

        Raises:
            Error: Never for a rectangle; the signature is the path
                builder's.
        """
        self._content += "q "
        if self._transformed:
            var p = Path()
            p.rect(Float64(x), Float64(y), Float64(width), Float64(height))
            var m = self._transform
            self._write_mapped_path(p, m)
            self._content += "W n\n"
        else:
            _num(self._content, Float64(x))
            _num(self._content, Float64(y))
            _num(self._content, Float64(width))
            _num(self._content, Float64(height))
            self._content += "re W n\n"
        self._clip_depth += 1

    def pop_clip(mut self):
        """End the innermost clip. A no-op with none active."""
        if self._clip_depth == 0:
            return
        self._content += "Q\n"
        self._clip_depth -= 1

    def push_clip_path(
        mut self, path: Path, fill_rule: FillRule = FillRule.EVEN_ODD
    ) raises:
        """Clip later drawing to `path` under `fill_rule`, until
        `pop_clip_path`.

        Args:
            path: Clip outline.
            fill_rule: Which regions of the outline count as inside.

        Raises:
            Error: `path` is malformed under the transform (a segment
                before any move).
        """
        self._content += "q "
        if self._transformed:
            var m = self._transform
            self._write_mapped_path(path, m)
        else:
            self._write_path(path)
        self._content += "W* n\n" if fill_rule == FillRule.EVEN_ODD else "W n\n"
        self._clip_depth += 1

    def pop_clip_path(mut self):
        """End the innermost clip path; the same stack as `pop_clip`."""
        self.pop_clip()

    def _write_mapped_path(mut self, path: Path, m: Matrix2D) raises:
        """`path` with every point taken through `m` first: a clip is
        written outside any element's own `cm`, so the transform has
        to be baked into its points."""
        var mapped = Path()
        for cmd in path.commands:
            if cmd.op == PathOp.MOVE_TO:
                var p = m.apply(cmd.p1.x, cmd.p1.y)
                mapped.move_to(p.x, p.y)
            elif cmd.op == PathOp.LINE_TO:
                var p = m.apply(cmd.p1.x, cmd.p1.y)
                mapped.line_to(p.x, p.y)
            elif cmd.op == PathOp.QUAD_TO:
                var c = m.apply(cmd.p1.x, cmd.p1.y)
                var p = m.apply(cmd.p2.x, cmd.p2.y)
                mapped.quad_curve_to(c.x, c.y, p.x, p.y)
            elif cmd.op == PathOp.CUBIC_TO:
                var c1 = m.apply(cmd.p1.x, cmd.p1.y)
                var c2 = m.apply(cmd.p2.x, cmd.p2.y)
                var p = m.apply(cmd.p3.x, cmd.p3.y)
                mapped.cubic_curve_to(c1.x, c1.y, c2.x, c2.y, p.x, p.y)
            elif cmd.op == PathOp.ARC_TO:
                # An arc under a general transform is no longer an
                # arc: it is sampled into line segments, which the
                # transform maps exactly.
                var steps = 32
                var a0 = cmd.p2.y
                var a1 = cmd.p3.x
                for i in range(steps + 1):
                    var a = a0 + (a1 - a0) * Float64(i) / Float64(steps)
                    var q = m.apply(
                        cmd.p1.x + cmd.p2.x * cos(a),
                        cmd.p1.y + cmd.p2.x * sin(a),
                    )
                    if i == 0 and len(mapped.commands) == 0:
                        mapped.move_to(q.x, q.y)
                    else:
                        mapped.line_to(q.x, q.y)
            else:
                mapped.close()
        self._write_path(mapped)

    # ---- text -----------------------------------------------------

    def draw_text(
        mut self,
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
    ) raises:
        """Draw `text` as filled glyph outlines (`canvas.text.text_path`),
        laid out exactly as the raster `draw_text` lays it out. Not on
        `DrawTarget`, which excludes text.

        Args:
            x: Anchor x -- baseline left end for LEFT alignment.
            y: Anchor y -- baseline.
            text: Text to draw, "\\\\n"-separated lines.
            color: Fill color.
            size: Font size in points.
            family: Font family name or generic alias.
            slant: Requested upright/italic/oblique style.
            weight: Requested normal/bold weight.
            rotation: Radians, rotating the block around the anchor.
            align: Horizontal alignment of each line.

        Raises:
            Error: No font could be resolved for `family`.
        """
        var outline = text_path(
            x,
            y,
            text,
            size,
            family,
            slant,
            weight,
            rotation,
            align,
            cache=self._fonts,
        )
        self.fill_path_aa(outline, color, FillRule.NONZERO)

    def stroke_text(
        mut self,
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
    ) raises:
        """Outline `text` rather than fill it; see `draw_text`.

        Args:
            x: Anchor x.
            y: Anchor y -- baseline.
            text: Text to outline.
            color: Stroke color.
            size: Font size in points.
            width: Stroke width.
            family: Font family name or generic alias.
            slant: Requested upright/italic/oblique style.
            weight: Requested normal/bold weight.
            rotation: Radians, rotating the block around the anchor.
            align: Horizontal alignment of each line.
            join: Line join.
            miter_limit: Miter limit.

        Raises:
            Error: No font could be resolved for `family`.
        """
        var outline = text_path(
            x,
            y,
            text,
            size,
            family,
            slant,
            weight,
            rotation,
            align,
            cache=self._fonts,
        )
        self.stroke_path_aa(
            outline, color, width, join=join, miter_limit=miter_limit
        )

    # ---- groups ---------------------------------------------------

    def begin_annotated_group(mut self, title: String):
        """Open a marked-content sequence labeled `title`
        (`/Span << /Alt (title) >> BDC`), closed by
        `end_annotated_group`. Groups do not nest.

        Args:
            title: Human-readable label; parentheses and backslashes
                are escaped here.
        """
        if self._open_group:
            self.end_annotated_group()
        self._content += "/Span << /Alt " + _pdf_string(title) + " >> BDC\n"
        self._open_group = True

    def end_annotated_group(mut self):
        """Close the open marked-content sequence, if any."""
        if not self._open_group:
            return
        self._content += "EMC\n"
        self._open_group = False

    # ---- output ---------------------------------------------------

    def content(self) -> String:
        """The page's content stream operators as written so far,
        without the flip that opens the stream in the file: what a
        test reads to see what a call became."""
        return self._content

    def to_bytes(self, compress: Bool = True) raises -> List[UInt8]:
        """The complete PDF file.

        Args:
            compress: Flate-compress the content stream (the default);
                False leaves it readable.

        Returns:
            The file's bytes.
        """
        var stream = String("1 0 0 -1 0 ")
        _num(stream, Float64(self.height))
        stream += "cm\n" + self._content
        if self._open_group:
            stream += "EMC\n"
        for _ in range(self._clip_depth):
            stream += "Q\n"
        var raw = List[UInt8]()
        for b in stream.as_bytes():
            raw.append(b)
        var body = List[UInt8]()
        if compress:
            var packed = deflate(raw)
            body.append(0x78)
            body.append(0x9C)
            body.extend(packed^)
            var adler = _adler32(raw)
            body.append(UInt8((adler >> 24) & 0xFF))
            body.append(UInt8((adler >> 16) & 0xFF))
            body.append(UInt8((adler >> 8) & 0xFF))
            body.append(UInt8(adler & 0xFF))
        else:
            body = raw^

        var out = List[UInt8]()
        var offsets = List[Int]()
        _append_text(out, "%PDF-1.4\n%")
        out.append(0xE2)
        out.append(0xE3)
        out.append(0xCF)
        out.append(0xD3)
        _append_text(out, "\n")

        offsets.append(len(out))
        _append_text(
            out, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"
        )
        offsets.append(len(out))
        _append_text(
            out, "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n"
        )
        offsets.append(len(out))
        var page = String(
            "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 "
        )
        page += String(self.width) + " " + String(self.height) + "]"
        page += " /Contents 4 0 R /Resources << "
        if len(self._gstates) > 0:
            page += "/ExtGState << "
            for i in range(len(self._gstates)):
                page += (
                    "/GS" + String(i + 1) + " << " + self._gstates[i] + ">> "
                )
            page += ">> "
        if len(self._shadings) > 0:
            page += "/Shading << "
            for i in range(len(self._shadings)):
                page += "/Sh" + String(i + 1) + " " + self._shadings[i] + " "
            page += ">> "
        page += ">> >>\nendobj\n"
        _append_text(out, page)
        offsets.append(len(out))
        _append_text(out, "4 0 obj\n<< /Length " + String(len(body)))
        if compress:
            _append_text(out, " /Filter /FlateDecode")
        _append_text(out, " >>\nstream\n")
        out.extend(body^)
        _append_text(out, "\nendstream\nendobj\n")
        var count = 5
        if self._title != "":
            offsets.append(len(out))
            _append_text(
                out,
                "5 0 obj\n<< /Title "
                + _pdf_string(self._title)
                + " >>\nendobj\n",
            )
            count = 6
        var xref = len(out)
        var table = (
            String("xref\n0 ") + String(count) + "\n0000000000 65535 f \n"
        )
        for off in offsets:
            table += _pad10(off) + " 00000 n \n"
        table += "trailer\n<< /Size " + String(count) + " /Root 1 0 R"
        if self._title != "":
            table += " /Info 5 0 R"
        table += " >>\nstartxref\n" + String(xref) + "\n%%EOF\n"
        _append_text(out, table)
        return out^


def _pad10(n: Int) -> String:
    var s = String(n)
    var out = String()
    for _ in range(10 - s.byte_length()):
        out += "0"
    return out + s


def _append_text(mut out: List[UInt8], text: String):
    for b in text.as_bytes():
        out.append(b)


def write_pdf(pdf: PdfCanvas, path: String) raises:
    """Write `pdf` to `path`, the PDF counterpart to `write_png` and
    `write_svg`.

    Args:
        pdf: Document to write.
        path: File path to write to.

    Raises:
        Error: `path` can't be opened for writing.
    """
    var f = open(path, "w")
    f.write_bytes(Span(pdf.to_bytes()))
    f.close()
