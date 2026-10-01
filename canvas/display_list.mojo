"""Owned, reusable DrawTarget commands in a local coordinate system.

DisplayList records drawing without rasterizing it. Replay composes the
recording's transforms after the destination baseline, and restores the
incoming graphics state on success or error. Pixels/elements emitted before
an error are not rolled back. Fonts resolve at replay through the supplied
cache (PDF retains its own cache and SVG keeps CSS font descriptions).

Recordings preserve a fixed layout. A different destination scale scales
that layout; changing ticks, wrapping or legend placement requires recording
again. Paths, images, gradients, strings and list arguments are copied once
per distinct resource value; commands contain only scalars and resource IDs.
"""

from std.collections import List
from std.math import isfinite
from std.sys import size_of
from canvas.blend import BlendMode
from canvas.bounds import BoundsTarget
from canvas.buffer import Canvas
from canvas.color import Color, ColorSpace
from canvas.fill_rule import FillRule
from canvas.geometry import FPoint, Matrix2D
from canvas.gradient import LinearGradient, GradientStop, _Interval
from canvas.path import Path, PathCommand, PathOp
from canvas.shapes.lines import LineCap, LineJoin
from canvas.text.font_cache import FontCache
from canvas.text.font_discovery import FontSlant, FontWeight
from canvas.text.text_align import TextAlign
from canvas.text.text_run import TextRun
from canvas.vector.draw_target import DrawTarget
from canvas.vector.svg import SvgCanvas
from canvas.vector.pdf import PdfCanvas

comptime _DL_FILL_RECT_0 = 0
comptime _DL_FILL_RECT_1 = 1
comptime _DL_FILL_RECT_GRADIENT_2 = 2
comptime _DL_FILL_RECT_GRADIENT_3 = 3
comptime _DL_DRAW_LINE_AA_4 = 4
comptime _DL_DRAW_LINE_AA_5 = 5
comptime _DL_FILL_CIRCLE_AA_6 = 6
comptime _DL_FILL_CIRCLE_AA_7 = 7
comptime _DL_FILL_CIRCLES_AA_8 = 8
comptime _DL_FILL_CIRCLES_AA_9 = 9
comptime _DL_FILL_MESH_10 = 10
comptime _DL_FILL_MESH_SHADED_11 = 11
comptime _DL_FILL_ELLIPSES_AA_12 = 12
comptime _DL_FILL_ELLIPSES_AA_13 = 13
comptime _DL_DRAW_CIRCLE_AA_14 = 14
comptime _DL_FILL_ELLIPSE_AA_15 = 15
comptime _DL_FILL_ELLIPSE_AA_16 = 16
comptime _DL_DRAW_ELLIPSE_AA_17 = 17
comptime _DL_DRAW_ELLIPSE_AA_18 = 18
comptime _DL_FILL_ARC_AA_19 = 19
comptime _DL_FILL_ARCS_AA_20 = 20
comptime _DL_FILL_ARCS_AA_21 = 21
comptime _DL_FILL_RING_SECTOR_AA_22 = 22
comptime _DL_STROKE_PATH_AA_23 = 23
comptime _DL_FILL_PATH_AA_24 = 24
comptime _DL_DRAW_IMAGE_25 = 25
comptime _DL_DRAW_TEXT_26 = 26
comptime _DL_DRAW_TEXT_RUNS_27 = 27
comptime _DL_PUSH_CLIP_28 = 28
comptime _DL_POP_CLIP_29 = 29
comptime _DL_PUSH_CLIP_PATH_30 = 30
comptime _DL_POP_CLIP_PATH_31 = 31
comptime _DL_BEGIN_ANNOTATED_GROUP_32 = 32
comptime _DL_END_ANNOTATED_GROUP_33 = 33
comptime _DL_BEGIN_BATCH_34 = 34
comptime _DL_END_BATCH_35 = 35
comptime _DL_SAVE_36 = 36
comptime _DL_RESTORE_37 = 37
comptime _DL_TRANSLATE_38 = 38
comptime _DL_ROTATE_39 = 39
comptime _DL_SCALE_40 = 40
comptime _DL_TRANSFORM_41 = 41
comptime _DL_SET_TRANSFORM_42 = 42
comptime _DL_RESET_TRANSFORM_43 = 43
comptime _DL_SET_BLEND_MODE_44 = 44
comptime _DL_SET_COLOR_SPACE_45 = 45


struct _Command(Copyable, Movable):
    var op: Int
    var numbers: Array[Float64, 8]
    var ids: Array[Int, 8]
    var color: Color

    def __init__(out self, op: Int):
        self.op = op
        self.numbers = Array[Float64, 8](fill=0.0)
        self.ids = Array[Int, 8](fill=0)
        self.color = Color(0, 0, 0, 0)


struct _LocalState(ImplicitlyCopyable, Movable):
    var matrix: Matrix2D
    var blend: BlendMode
    var space: ColorSpace

    def __init__(
        out self, matrix: Matrix2D, blend: BlendMode, space: ColorSpace
    ):
        self.matrix = matrix
        self.blend = blend
        self.space = space


struct DisplayListBounds(ImplicitlyCopyable, Movable):
    """Conservative logical ink, or an explicit unknown result.

    If known is false, repaint the widget rather than rejecting damage
    against this box. An empty known result has has_ink false. Coordinates
    include a half-pixel fringe for raster coverage. Font resolution is
    environment-dependent: recompute bounds when font configuration changes.
    """

    var known: Bool
    var has_ink: Bool
    var min_x: Float64
    var min_y: Float64
    var max_x: Float64
    var max_y: Float64

    def __init__(
        out self,
        known: Bool = False,
        has_ink: Bool = False,
        min_x: Float64 = 0.0,
        min_y: Float64 = 0.0,
        max_x: Float64 = 0.0,
        max_y: Float64 = 0.0,
    ):
        self.known = known
        self.has_ink = has_ink
        self.min_x = min_x
        self.min_y = min_y
        self.max_x = max_x
        self.max_y = max_y


struct _ReplayScope(ImplicitlyCopyable, Movable):
    var saves: Int
    var batches: Int
    var group: Bool

    def __init__(out self):
        self.saves = 0
        self.batches = 0
        self.group = False


struct DisplayList(DrawTarget, Movable):
    """A movable scene that owns commands and deduplicated resources.

    Record with the DrawTarget methods, then replay(target, cache=cache).
    Balance saves, batches and annotated groups before replay. Mixed clips
    must pop in reverse order with the matching pop method; restore may
    discard clips pushed within its save scope. Invalid scopes raise before
    touching a replay destination. End a destination annotated group before
    replay, since DrawTarget groups do not nest.

    Source images must have their batches finished before recording, just
    as for draw_image. Recorded caches are ignored; replay resolves fonts.
    Content-based resource interning compares existing values and is linear
    in the retained resource count, so record once and reuse the result.
    """

    var _commands: List[_Command]
    var _matrix: Matrix2D
    var _blend: BlendMode
    var _space: ColorSpace
    var _saved: List[_LocalState]
    var _finite_state: Bool
    var _paths: List[Path]
    var _images: List[Canvas]
    var _gradients: List[LinearGradient]
    var _strings: List[String]
    var _points: List[List[FPoint]]
    var _indices: List[List[Int]]
    var _dashes: List[List[Float64]]
    var _colors: List[List[Color]]
    var _runs: List[List[TextRun]]

    def __init__(out self):
        self._commands = List[_Command]()
        self._matrix = Matrix2D.identity()
        self._blend = BlendMode.SOURCE_OVER
        self._space = ColorSpace.SRGB
        self._saved = List[_LocalState]()
        self._finite_state = True
        self._paths = List[Path]()
        self._images = List[Canvas]()
        self._gradients = List[LinearGradient]()
        self._strings = List[String]()
        self._points = List[List[FPoint]]()
        self._indices = List[List[Int]]()
        self._dashes = List[List[Float64]]()
        self._colors = List[List[Color]]()
        self._runs = List[List[TextRun]]()

    def _append(mut self, var command: _Command):
        var m = self._matrix
        self._finite_state = (
            self._finite_state
            and isfinite(m.a)
            and isfinite(m.b)
            and isfinite(m.c)
            and isfinite(m.d)
            and isfinite(m.e)
            and isfinite(m.f)
        )
        self._commands.append(command^)

    def command_count(self) -> Int:
        """Number of commands, including state operations."""
        return len(self._commands)

    def reserve_commands(mut self, count: Int):
        """Reserve inline command slots before recording a known-size scene."""
        self._commands.reserve(count)

    def resource_count(self) -> Int:
        """Distinct owned aggregates; scalar-only primitives need none."""
        return (
            len(self._paths)
            + len(self._images)
            + len(self._gradients)
            + len(self._strings)
            + len(self._points)
            + len(self._indices)
            + len(self._dashes)
            + len(self._colors)
            + len(self._runs)
        )

    def _intern_paths(mut self, value: Path) -> Int:
        for i in range(len(self._paths)):
            ref other = self._paths[i]
            if len(other.commands) != len(value.commands):
                continue
            var same = True
            for j in range(len(value.commands)):
                var a = other.commands[j]
                var b = value.commands[j]
                if (
                    a.op != b.op
                    or a.p1.x != b.p1.x
                    or a.p1.y != b.p1.y
                    or a.p2.x != b.p2.x
                    or a.p2.y != b.p2.y
                    or a.p3.x != b.p3.x
                    or a.p3.y != b.p3.y
                ):
                    same = False
                    break
            if same:
                return i
        self._paths.append(value.copy())
        return len(self._paths) - 1

    def _intern_images(mut self, value: Canvas) raises -> Int:
        if value._batch_depth != 0 or value._supersample != 0:
            raise Error(
                "DisplayList: finish source image batch or supersampled region"
                " before recording"
            )
        for i in range(len(self._images)):
            ref other = self._images[i]
            var same = (
                other.width == value.width
                and other.height == value.height
                and other.pixels == value.pixels
            )
            if same:
                return i
        self._images.append(
            Canvas(value.width, value.height, value.pixels.copy())
        )
        return len(self._images) - 1

    def _intern_gradients(mut self, value: LinearGradient) -> Int:
        for i in range(len(self._gradients)):
            ref other = self._gradients[i]
            var same = (
                other.x0 == value.x0
                and other.y0 == value.y0
                and other.x1 == value.x1
                and other.y1 == value.y1
                and other.color_space() == value.color_space()
                and len(other.stops) == len(value.stops)
            )
            if same:
                for j in range(len(value.stops)):
                    if (
                        other.stops[j].offset != value.stops[j].offset
                        or other.stops[j].color != value.stops[j].color
                    ):
                        same = False
                        break
            if same:
                return i
        var snapshot = LinearGradient(value.x0, value.y0, value.x1, value.y1)
        snapshot.stops = value.stops.copy()
        self._gradients.append(snapshot^)
        return len(self._gradients) - 1

    def _intern_strings(mut self, value: String) -> Int:
        for i in range(len(self._strings)):
            ref other = self._strings[i]
            if other == value:
                return i
        self._strings.append(String(value))
        return len(self._strings) - 1

    def _intern_points(mut self, value: List[FPoint]) -> Int:
        for i in range(len(self._points)):
            ref other = self._points[i]
            if len(other) != len(value):
                continue
            var same = True
            for j in range(len(value)):
                if other[j].x != value[j].x or other[j].y != value[j].y:
                    same = False
                    break
            if same:
                return i
        self._points.append(value.copy())
        return len(self._points) - 1

    def _intern_indices(mut self, value: List[Int]) -> Int:
        for i in range(len(self._indices)):
            ref other = self._indices[i]
            if len(other) != len(value):
                continue
            var same = True
            for j in range(len(value)):
                if other[j] != value[j]:
                    same = False
                    break
            if same:
                return i
        self._indices.append(value.copy())
        return len(self._indices) - 1

    def _intern_dashes(mut self, value: List[Float64]) -> Int:
        for i in range(len(self._dashes)):
            ref other = self._dashes[i]
            if len(other) != len(value):
                continue
            var same = True
            for j in range(len(value)):
                if other[j] != value[j]:
                    same = False
                    break
            if same:
                return i
        self._dashes.append(value.copy())
        return len(self._dashes) - 1

    def _intern_colors(mut self, value: List[Color]) -> Int:
        for i in range(len(self._colors)):
            ref other = self._colors[i]
            if len(other) != len(value):
                continue
            var same = True
            for j in range(len(value)):
                if other[j] != value[j]:
                    same = False
                    break
            if same:
                return i
        self._colors.append(value.copy())
        return len(self._colors) - 1

    def _intern_runs(mut self, value: List[TextRun]) -> Int:
        for i in range(len(self._runs)):
            ref other = self._runs[i]
            if len(other) != len(value):
                continue
            var same = True
            for j in range(len(value)):
                if (
                    other[j].text != value[j].text
                    or other[j].size != value[j].size
                    or other[j].slant != value[j].slant
                    or other[j].dx != value[j].dx
                    or other[j].dy != value[j].dy
                ):
                    same = False
                    break
            if same:
                return i
        self._runs.append(value.copy())
        return len(self._runs) - 1

    def current_transform(self) -> Matrix2D:
        return self._matrix

    def has_transform(self) -> Bool:
        return not self._matrix.is_identity()

    def blend_mode(self) -> BlendMode:
        return self._blend

    def color_space(self) -> ColorSpace:
        return self._space

    def fill_rect(
        mut self, x: Int, y: Int, width: Int, height: Int, color: Color
    ):
        """Record `fill_rect` with owned arguments."""
        var command = _Command(_DL_FILL_RECT_0)
        command.ids[0] = x
        command.ids[1] = y
        command.ids[2] = width
        command.ids[3] = height
        command.color = color
        self._append(command^)

    def fill_rect(
        mut self,
        x: Float64,
        y: Float64,
        width: Float64,
        height: Float64,
        color: Color,
    ):
        """Record `fill_rect` with owned arguments."""
        var command = _Command(_DL_FILL_RECT_1)
        command.numbers[0] = x
        command.numbers[1] = y
        command.numbers[2] = width
        command.numbers[3] = height
        command.color = color
        self._append(command^)

    def fill_rect_gradient(
        mut self,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        gradient: LinearGradient,
    ):
        """Record `fill_rect_gradient` with owned arguments."""
        var command = _Command(_DL_FILL_RECT_GRADIENT_2)
        command.ids[0] = x
        command.ids[1] = y
        command.ids[2] = width
        command.ids[3] = height
        command.ids[4] = self._intern_gradients(gradient)
        self._append(command^)

    def fill_rect_gradient(
        mut self,
        x: Float64,
        y: Float64,
        width: Float64,
        height: Float64,
        gradient: LinearGradient,
    ):
        """Record `fill_rect_gradient` with owned arguments."""
        var command = _Command(_DL_FILL_RECT_GRADIENT_3)
        command.numbers[0] = x
        command.numbers[1] = y
        command.numbers[2] = width
        command.numbers[3] = height
        command.ids[0] = self._intern_gradients(gradient)
        self._append(command^)

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
        """Record `draw_line_aa` with owned arguments."""
        var command = _Command(_DL_DRAW_LINE_AA_4)
        command.ids[0] = x0
        command.ids[1] = y0
        command.ids[2] = x1
        command.ids[3] = y1
        command.color = color
        command.numbers[0] = width
        command.ids[4] = self._intern_dashes(dashes)
        command.numbers[1] = dash_offset
        command.ids[5] = cap._value
        command.ids[6] = join._value
        command.numbers[2] = miter_limit
        self._append(command^)

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
        """Record `draw_line_aa` with owned arguments."""
        var command = _Command(_DL_DRAW_LINE_AA_5)
        command.numbers[0] = x0
        command.numbers[1] = y0
        command.numbers[2] = x1
        command.numbers[3] = y1
        command.color = color
        command.numbers[4] = width
        command.ids[0] = self._intern_dashes(dashes)
        command.numbers[5] = dash_offset
        command.ids[1] = cap._value
        command.ids[2] = join._value
        command.numbers[6] = miter_limit
        self._append(command^)

    def fill_circle_aa(mut self, cx: Int, cy: Int, radius: Int, color: Color):
        """Record `fill_circle_aa` with owned arguments."""
        var command = _Command(_DL_FILL_CIRCLE_AA_6)
        command.ids[0] = cx
        command.ids[1] = cy
        command.ids[2] = radius
        command.color = color
        self._append(command^)

    def fill_circle_aa(
        mut self, cx: Float64, cy: Float64, radius: Float64, color: Color
    ):
        """Record `fill_circle_aa` with owned arguments."""
        var command = _Command(_DL_FILL_CIRCLE_AA_7)
        command.numbers[0] = cx
        command.numbers[1] = cy
        command.numbers[2] = radius
        command.color = color
        self._append(command^)

    def fill_circles_aa(
        mut self,
        centers: List[FPoint],
        radius: Float64,
        color: Color,
    ) raises:
        """Record `fill_circles_aa` with owned arguments."""
        var command = _Command(_DL_FILL_CIRCLES_AA_8)
        command.ids[0] = self._intern_points(centers)
        command.numbers[0] = radius
        command.color = color
        self._append(command^)

    def fill_circles_aa(
        mut self,
        centers: List[FPoint],
        radius: Float64,
        colors: List[Color],
    ) raises:
        """Record `fill_circles_aa` with owned arguments."""
        var command = _Command(_DL_FILL_CIRCLES_AA_9)
        command.ids[0] = self._intern_points(centers)
        command.numbers[0] = radius
        command.ids[1] = self._intern_colors(colors)
        self._append(command^)

    def fill_mesh(
        mut self,
        points: List[FPoint],
        faces: List[Int],
        colors: List[Color],
    ) raises:
        """Record `fill_mesh` with owned arguments."""
        var command = _Command(_DL_FILL_MESH_10)
        command.ids[0] = self._intern_points(points)
        command.ids[1] = self._intern_indices(faces)
        command.ids[2] = self._intern_colors(colors)
        self._append(command^)

    def fill_mesh_shaded(
        mut self,
        points: List[FPoint],
        faces: List[Int],
        vertex_colors: List[Color],
    ) raises:
        """Record `fill_mesh_shaded` with owned arguments."""
        var command = _Command(_DL_FILL_MESH_SHADED_11)
        command.ids[0] = self._intern_points(points)
        command.ids[1] = self._intern_indices(faces)
        command.ids[2] = self._intern_colors(vertex_colors)
        self._append(command^)

    def fill_ellipses_aa(
        mut self,
        centers: List[FPoint],
        rx: Float64,
        ry: Float64,
        color: Color,
    ) raises:
        """Record `fill_ellipses_aa` with owned arguments."""
        var command = _Command(_DL_FILL_ELLIPSES_AA_12)
        command.ids[0] = self._intern_points(centers)
        command.numbers[0] = rx
        command.numbers[1] = ry
        command.color = color
        self._append(command^)

    def fill_ellipses_aa(
        mut self,
        centers: List[FPoint],
        rx: Float64,
        ry: Float64,
        colors: List[Color],
    ) raises:
        """Record `fill_ellipses_aa` with owned arguments."""
        var command = _Command(_DL_FILL_ELLIPSES_AA_13)
        command.ids[0] = self._intern_points(centers)
        command.numbers[0] = rx
        command.numbers[1] = ry
        command.ids[1] = self._intern_colors(colors)
        self._append(command^)

    def draw_circle_aa(
        mut self,
        cx: Float64,
        cy: Float64,
        radius: Float64,
        color: Color,
        width: Float64 = 1.0,
    ):
        """Record `draw_circle_aa` with owned arguments."""
        var command = _Command(_DL_DRAW_CIRCLE_AA_14)
        command.numbers[0] = cx
        command.numbers[1] = cy
        command.numbers[2] = radius
        command.color = color
        command.numbers[3] = width
        self._append(command^)

    def fill_ellipse_aa(
        mut self, cx: Int, cy: Int, rx: Int, ry: Int, color: Color
    ):
        """Record `fill_ellipse_aa` with owned arguments."""
        var command = _Command(_DL_FILL_ELLIPSE_AA_15)
        command.ids[0] = cx
        command.ids[1] = cy
        command.ids[2] = rx
        command.ids[3] = ry
        command.color = color
        self._append(command^)

    def fill_ellipse_aa(
        mut self,
        cx: Float64,
        cy: Float64,
        rx: Float64,
        ry: Float64,
        color: Color,
    ):
        """Record `fill_ellipse_aa` with owned arguments."""
        var command = _Command(_DL_FILL_ELLIPSE_AA_16)
        command.numbers[0] = cx
        command.numbers[1] = cy
        command.numbers[2] = rx
        command.numbers[3] = ry
        command.color = color
        self._append(command^)

    def draw_ellipse_aa(
        mut self, cx: Int, cy: Int, rx: Int, ry: Int, color: Color
    ):
        """Record `draw_ellipse_aa` with owned arguments."""
        var command = _Command(_DL_DRAW_ELLIPSE_AA_17)
        command.ids[0] = cx
        command.ids[1] = cy
        command.ids[2] = rx
        command.ids[3] = ry
        command.color = color
        self._append(command^)

    def draw_ellipse_aa(
        mut self,
        cx: Float64,
        cy: Float64,
        rx: Float64,
        ry: Float64,
        color: Color,
        width: Float64 = 1.0,
    ):
        """Record `draw_ellipse_aa` with owned arguments."""
        var command = _Command(_DL_DRAW_ELLIPSE_AA_18)
        command.numbers[0] = cx
        command.numbers[1] = cy
        command.numbers[2] = rx
        command.numbers[3] = ry
        command.color = color
        command.numbers[4] = width
        self._append(command^)

    def fill_arc_aa(
        mut self,
        cx: Float64,
        cy: Float64,
        radius: Float64,
        start_angle: Float64,
        end_angle: Float64,
        color: Color,
    ):
        """Record `fill_arc_aa` with owned arguments."""
        var command = _Command(_DL_FILL_ARC_AA_19)
        command.numbers[0] = cx
        command.numbers[1] = cy
        command.numbers[2] = radius
        command.numbers[3] = start_angle
        command.numbers[4] = end_angle
        command.color = color
        self._append(command^)

    def fill_arcs_aa(
        mut self,
        centers: List[FPoint],
        radius: Float64,
        start_angle: Float64,
        end_angle: Float64,
        color: Color,
    ) raises:
        """Record `fill_arcs_aa` with owned arguments."""
        var command = _Command(_DL_FILL_ARCS_AA_20)
        command.ids[0] = self._intern_points(centers)
        command.numbers[0] = radius
        command.numbers[1] = start_angle
        command.numbers[2] = end_angle
        command.color = color
        self._append(command^)

    def fill_arcs_aa(
        mut self,
        centers: List[FPoint],
        radius: Float64,
        start_angle: Float64,
        end_angle: Float64,
        colors: List[Color],
    ) raises:
        """Record `fill_arcs_aa` with owned arguments."""
        var command = _Command(_DL_FILL_ARCS_AA_21)
        command.ids[0] = self._intern_points(centers)
        command.numbers[0] = radius
        command.numbers[1] = start_angle
        command.numbers[2] = end_angle
        command.ids[1] = self._intern_colors(colors)
        self._append(command^)

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
        """Record `fill_ring_sector_aa` with owned arguments."""
        var command = _Command(_DL_FILL_RING_SECTOR_AA_22)
        command.numbers[0] = cx
        command.numbers[1] = cy
        command.numbers[2] = inner_radius
        command.numbers[3] = outer_radius
        command.numbers[4] = start_angle
        command.numbers[5] = end_angle
        command.color = color
        self._append(command^)

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
        """Record `stroke_path_aa` with owned arguments."""
        var command = _Command(_DL_STROKE_PATH_AA_23)
        command.ids[0] = self._intern_paths(path)
        command.color = color
        command.numbers[0] = width
        command.ids[1] = self._intern_dashes(dashes)
        command.numbers[1] = dash_offset
        command.ids[2] = cap._value
        command.ids[3] = join._value
        command.numbers[2] = miter_limit
        self._append(command^)

    def fill_path_aa(
        mut self,
        path: Path,
        color: Color,
        fill_rule: FillRule = FillRule.EVEN_ODD,
    ):
        """Record `fill_path_aa` with owned arguments."""
        var command = _Command(_DL_FILL_PATH_AA_24)
        command.ids[0] = self._intern_paths(path)
        command.color = color
        command.ids[1] = fill_rule._value
        self._append(command^)

    def draw_image(
        mut self,
        image: Canvas,
        x: Float64,
        y: Float64,
        width: Float64 = 0.0,
        height: Float64 = 0.0,
    ) raises:
        """Record `draw_image` with owned arguments."""
        var command = _Command(_DL_DRAW_IMAGE_25)
        command.ids[0] = self._intern_images(image)
        command.numbers[0] = x
        command.numbers[1] = y
        command.numbers[2] = width
        command.numbers[3] = height
        self._append(command^)

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
        *,
        mut cache: FontCache,
    ) raises:
        """Record `draw_text` with owned arguments."""
        var command = _Command(_DL_DRAW_TEXT_26)
        command.numbers[0] = x
        command.numbers[1] = y
        command.ids[0] = self._intern_strings(text)
        command.color = color
        command.numbers[2] = size
        command.ids[1] = self._intern_strings(family)
        command.ids[2] = slant._value
        command.ids[3] = weight._value
        command.numbers[3] = rotation
        command.ids[4] = align._value
        self._append(command^)

    def draw_text_runs(
        mut self,
        x: Float64,
        y: Float64,
        runs: List[TextRun],
        color: Color,
        family: String = "Sans",
        weight: FontWeight = FontWeight.NORMAL,
        rotation: Float64 = 0.0,
        align: TextAlign = TextAlign.LEFT,
        *,
        mut cache: FontCache,
    ) raises:
        """Record `draw_text_runs` with owned arguments."""
        var command = _Command(_DL_DRAW_TEXT_RUNS_27)
        command.numbers[0] = x
        command.numbers[1] = y
        command.ids[0] = self._intern_runs(runs)
        command.color = color
        command.ids[1] = self._intern_strings(family)
        command.ids[2] = weight._value
        command.numbers[2] = rotation
        command.ids[3] = align._value
        self._append(command^)

    def push_clip(mut self, x: Int, y: Int, width: Int, height: Int):
        """Record `push_clip` with owned arguments."""
        var command = _Command(_DL_PUSH_CLIP_28)
        command.ids[0] = x
        command.ids[1] = y
        command.ids[2] = width
        command.ids[3] = height
        self._append(command^)

    def pop_clip(mut self):
        """Record `pop_clip` with owned arguments."""
        var command = _Command(_DL_POP_CLIP_29)
        self._append(command^)

    def push_clip_path(
        mut self, path: Path, fill_rule: FillRule = FillRule.EVEN_ODD
    ) raises:
        """Record `push_clip_path` with owned arguments."""
        var command = _Command(_DL_PUSH_CLIP_PATH_30)
        command.ids[0] = self._intern_paths(path)
        command.ids[1] = fill_rule._value
        self._append(command^)

    def pop_clip_path(mut self):
        """Record `pop_clip_path` with owned arguments."""
        var command = _Command(_DL_POP_CLIP_PATH_31)
        self._append(command^)

    def begin_annotated_group(mut self, title: String):
        """Record `begin_annotated_group` with owned arguments."""
        var command = _Command(_DL_BEGIN_ANNOTATED_GROUP_32)
        command.ids[0] = self._intern_strings(title)
        self._append(command^)

    def end_annotated_group(mut self):
        """Record `end_annotated_group` with owned arguments."""
        var command = _Command(_DL_END_ANNOTATED_GROUP_33)
        self._append(command^)

    def begin_batch(mut self):
        """Record `begin_batch` with owned arguments."""
        var command = _Command(_DL_BEGIN_BATCH_34)
        self._append(command^)

    def end_batch(mut self):
        """Record `end_batch` with owned arguments."""
        var command = _Command(_DL_END_BATCH_35)
        self._append(command^)

    def save(mut self):
        """Record `save` with owned arguments."""
        var command = _Command(_DL_SAVE_36)
        self._saved.append(_LocalState(self._matrix, self._blend, self._space))
        self._append(command^)

    def restore(mut self):
        """Record `restore` with owned arguments."""
        var command = _Command(_DL_RESTORE_37)
        if len(self._saved) > 0:
            var state = self._saved.pop()
            self._matrix = state.matrix
            self._blend = state.blend
            self._space = state.space
        self._append(command^)

    def translate(mut self, tx: Float64, ty: Float64):
        """Record `translate` with owned arguments."""
        var command = _Command(_DL_TRANSLATE_38)
        command.numbers[0] = tx
        command.numbers[1] = ty
        self._matrix = Matrix2D.translation(tx, ty).then(self._matrix)
        self._append(command^)

    def rotate(mut self, angle: Float64):
        """Record `rotate` with owned arguments."""
        var command = _Command(_DL_ROTATE_39)
        command.numbers[0] = angle
        self._matrix = Matrix2D.rotation(angle).then(self._matrix)
        self._append(command^)

    def scale(mut self, sx: Float64, sy: Float64):
        """Record `scale` with owned arguments."""
        var command = _Command(_DL_SCALE_40)
        command.numbers[0] = sx
        command.numbers[1] = sy
        self._matrix = Matrix2D.scaling(sx, sy).then(self._matrix)
        self._append(command^)

    def transform(mut self, matrix: Matrix2D):
        """Record `transform` with owned arguments."""
        var command = _Command(_DL_TRANSFORM_41)
        command.numbers[0] = matrix.a
        command.numbers[1] = matrix.b
        command.numbers[2] = matrix.c
        command.numbers[3] = matrix.d
        command.numbers[4] = matrix.e
        command.numbers[5] = matrix.f
        self._matrix = matrix.then(self._matrix)
        self._append(command^)

    def set_transform(mut self, matrix: Matrix2D):
        """Record `set_transform` with owned arguments."""
        var command = _Command(_DL_SET_TRANSFORM_42)
        command.numbers[0] = matrix.a
        command.numbers[1] = matrix.b
        command.numbers[2] = matrix.c
        command.numbers[3] = matrix.d
        command.numbers[4] = matrix.e
        command.numbers[5] = matrix.f
        self._matrix = matrix
        self._append(command^)

    def reset_transform(mut self):
        """Record `reset_transform` with owned arguments."""
        var command = _Command(_DL_RESET_TRANSFORM_43)
        self._matrix = Matrix2D.identity()
        self._append(command^)

    def set_blend_mode(mut self, mode: BlendMode):
        """Record `set_blend_mode` with owned arguments."""
        var command = _Command(_DL_SET_BLEND_MODE_44)
        command.ids[0] = mode._value
        self._blend = mode
        self._append(command^)

    def set_color_space(mut self, space: ColorSpace):
        """Record `set_color_space` with owned arguments."""
        var command = _Command(_DL_SET_COLOR_SPACE_45)
        command.ids[0] = space._value
        self._space = space
        self._append(command^)

    def _finite(self) -> Bool:
        if not self._finite_state:
            return False
        for command_index in range(len(self._commands)):
            ref command = self._commands[command_index]
            for i in range(8):
                if not isfinite(command.numbers[i]):
                    return False
        for points_index in range(len(self._points)):
            ref points = self._points[points_index]
            for p in points:
                if not isfinite(p.x) or not isfinite(p.y):
                    return False
        for path_index in range(len(self._paths)):
            ref path = self._paths[path_index]
            for command in path.commands:
                if (
                    not isfinite(command.p1.x)
                    or not isfinite(command.p1.y)
                    or not isfinite(command.p2.x)
                    or not isfinite(command.p2.y)
                    or not isfinite(command.p3.x)
                    or not isfinite(command.p3.y)
                ):
                    return False
        for dashes_index in range(len(self._dashes)):
            ref dashes = self._dashes[dashes_index]
            for dash in dashes:
                if not isfinite(dash):
                    return False
        for runs_index in range(len(self._runs)):
            ref runs = self._runs[runs_index]
            for run_index in range(len(runs)):
                ref run = runs[run_index]
                if (
                    not isfinite(run.size)
                    or not isfinite(run.dx)
                    or not isfinite(run.dy)
                ):
                    return False
        for gradient_index in range(len(self._gradients)):
            ref gradient = self._gradients[gradient_index]
            if (
                not isfinite(gradient.x0)
                or not isfinite(gradient.y0)
                or not isfinite(gradient.x1)
                or not isfinite(gradient.y1)
            ):
                return False
            for i in range(len(gradient.stops)):
                if not isfinite(gradient.stops[i].offset):
                    return False
        return True

    def validate(self) raises:
        """Reject unbalanced scopes, malformed paths and nonfinite coordinates.

        Called before replay changes its destination. Primitive-specific
        validation remains the destination's responsibility; a later drawing
        error restores graphics state but may leave earlier ink behind.
        """
        if not self._finite():
            raise Error("DisplayList: nonfinite geometry")
        # A malformed mapped PDF clip can raise after writing a graphics
        # scope opener. Reject invalid path structure before any playback.
        for path_index in range(len(self._paths)):
            ref path = self._paths[path_index]
            var current = False
            for command in path.commands:
                if command.op == PathOp.MOVE_TO:
                    current = True
                elif (
                    not current
                    or command.op._value < 0
                    or command.op._value > 5
                ):
                    raise Error("DisplayList: malformed path command sequence")
        var clips = List[Int]()
        var saved = List[Int]()
        var batches = 0
        var group = False
        for command_index in range(len(self._commands)):
            ref command = self._commands[command_index]
            if command.op == _DL_SAVE_36:
                saved.append(len(clips))
            elif command.op == _DL_RESTORE_37:
                if len(saved) == 0:
                    raise Error("DisplayList: restore without save")
                var depth = saved.pop()
                while len(clips) > depth:
                    _ = clips.pop()
            elif command.op == _DL_PUSH_CLIP_28:
                clips.append(0)
            elif command.op == _DL_PUSH_CLIP_PATH_30:
                clips.append(1)
            elif (
                command.op == _DL_POP_CLIP_29
                or command.op == _DL_POP_CLIP_PATH_31
            ):
                var expected = 0 if command.op == _DL_POP_CLIP_29 else 1
                if len(clips) == 0 or clips[len(clips) - 1] != expected:
                    raise Error("DisplayList: mismatched clip pop")
                if len(saved) > 0 and len(clips) <= saved[len(saved) - 1]:
                    raise Error("DisplayList: clip pop crosses save boundary")
                _ = clips.pop()
            elif command.op == _DL_BEGIN_BATCH_34:
                batches += 1
            elif command.op == _DL_END_BATCH_35:
                if batches == 0:
                    raise Error("DisplayList: end_batch without begin_batch")
                batches -= 1
            elif command.op == _DL_BEGIN_ANNOTATED_GROUP_32:
                group = True
            elif command.op == _DL_END_ANNOTATED_GROUP_33:
                group = False
        if len(saved) != 0 or len(clips) != 0 or batches != 0 or group:
            raise Error("DisplayList: unbalanced recording scopes")

    def _play[
        T: DrawTarget
    ](
        self,
        mut target: T,
        baseline: Matrix2D,
        mut scope: _ReplayScope,
        mut cache: FontCache,
    ) raises:
        for command_index in range(len(self._commands)):
            ref command = self._commands[command_index]
            if command.op == _DL_FILL_RECT_0:
                target.fill_rect(
                    command.ids[0],
                    command.ids[1],
                    command.ids[2],
                    command.ids[3],
                    command.color,
                )
            elif command.op == _DL_FILL_RECT_1:
                target.fill_rect(
                    command.numbers[0],
                    command.numbers[1],
                    command.numbers[2],
                    command.numbers[3],
                    command.color,
                )
            elif command.op == _DL_FILL_RECT_GRADIENT_2:
                target.fill_rect_gradient(
                    command.ids[0],
                    command.ids[1],
                    command.ids[2],
                    command.ids[3],
                    self._gradients[command.ids[4]],
                )
            elif command.op == _DL_FILL_RECT_GRADIENT_3:
                target.fill_rect_gradient(
                    command.numbers[0],
                    command.numbers[1],
                    command.numbers[2],
                    command.numbers[3],
                    self._gradients[command.ids[0]],
                )
            elif command.op == _DL_DRAW_LINE_AA_4:
                target.draw_line_aa(
                    command.ids[0],
                    command.ids[1],
                    command.ids[2],
                    command.ids[3],
                    command.color,
                    command.numbers[0],
                    self._dashes[command.ids[4]],
                    command.numbers[1],
                    LineCap(command.ids[5]),
                    LineJoin(command.ids[6]),
                    command.numbers[2],
                )
            elif command.op == _DL_DRAW_LINE_AA_5:
                target.draw_line_aa(
                    command.numbers[0],
                    command.numbers[1],
                    command.numbers[2],
                    command.numbers[3],
                    command.color,
                    command.numbers[4],
                    self._dashes[command.ids[0]],
                    command.numbers[5],
                    LineCap(command.ids[1]),
                    LineJoin(command.ids[2]),
                    command.numbers[6],
                )
            elif command.op == _DL_FILL_CIRCLE_AA_6:
                target.fill_circle_aa(
                    command.ids[0],
                    command.ids[1],
                    command.ids[2],
                    command.color,
                )
            elif command.op == _DL_FILL_CIRCLE_AA_7:
                target.fill_circle_aa(
                    command.numbers[0],
                    command.numbers[1],
                    command.numbers[2],
                    command.color,
                )
            elif command.op == _DL_FILL_CIRCLES_AA_8:
                target.fill_circles_aa(
                    self._points[command.ids[0]],
                    command.numbers[0],
                    command.color,
                )
            elif command.op == _DL_FILL_CIRCLES_AA_9:
                target.fill_circles_aa(
                    self._points[command.ids[0]],
                    command.numbers[0],
                    self._colors[command.ids[1]],
                )
            elif command.op == _DL_FILL_MESH_10:
                target.fill_mesh(
                    self._points[command.ids[0]],
                    self._indices[command.ids[1]],
                    self._colors[command.ids[2]],
                )
            elif command.op == _DL_FILL_MESH_SHADED_11:
                target.fill_mesh_shaded(
                    self._points[command.ids[0]],
                    self._indices[command.ids[1]],
                    self._colors[command.ids[2]],
                )
            elif command.op == _DL_FILL_ELLIPSES_AA_12:
                target.fill_ellipses_aa(
                    self._points[command.ids[0]],
                    command.numbers[0],
                    command.numbers[1],
                    command.color,
                )
            elif command.op == _DL_FILL_ELLIPSES_AA_13:
                target.fill_ellipses_aa(
                    self._points[command.ids[0]],
                    command.numbers[0],
                    command.numbers[1],
                    self._colors[command.ids[1]],
                )
            elif command.op == _DL_DRAW_CIRCLE_AA_14:
                target.draw_circle_aa(
                    command.numbers[0],
                    command.numbers[1],
                    command.numbers[2],
                    command.color,
                    command.numbers[3],
                )
            elif command.op == _DL_FILL_ELLIPSE_AA_15:
                target.fill_ellipse_aa(
                    command.ids[0],
                    command.ids[1],
                    command.ids[2],
                    command.ids[3],
                    command.color,
                )
            elif command.op == _DL_FILL_ELLIPSE_AA_16:
                target.fill_ellipse_aa(
                    command.numbers[0],
                    command.numbers[1],
                    command.numbers[2],
                    command.numbers[3],
                    command.color,
                )
            elif command.op == _DL_DRAW_ELLIPSE_AA_17:
                target.draw_ellipse_aa(
                    command.ids[0],
                    command.ids[1],
                    command.ids[2],
                    command.ids[3],
                    command.color,
                )
            elif command.op == _DL_DRAW_ELLIPSE_AA_18:
                target.draw_ellipse_aa(
                    command.numbers[0],
                    command.numbers[1],
                    command.numbers[2],
                    command.numbers[3],
                    command.color,
                    command.numbers[4],
                )
            elif command.op == _DL_FILL_ARC_AA_19:
                target.fill_arc_aa(
                    command.numbers[0],
                    command.numbers[1],
                    command.numbers[2],
                    command.numbers[3],
                    command.numbers[4],
                    command.color,
                )
            elif command.op == _DL_FILL_ARCS_AA_20:
                target.fill_arcs_aa(
                    self._points[command.ids[0]],
                    command.numbers[0],
                    command.numbers[1],
                    command.numbers[2],
                    command.color,
                )
            elif command.op == _DL_FILL_ARCS_AA_21:
                target.fill_arcs_aa(
                    self._points[command.ids[0]],
                    command.numbers[0],
                    command.numbers[1],
                    command.numbers[2],
                    self._colors[command.ids[1]],
                )
            elif command.op == _DL_FILL_RING_SECTOR_AA_22:
                target.fill_ring_sector_aa(
                    command.numbers[0],
                    command.numbers[1],
                    command.numbers[2],
                    command.numbers[3],
                    command.numbers[4],
                    command.numbers[5],
                    command.color,
                )
            elif command.op == _DL_STROKE_PATH_AA_23:
                target.stroke_path_aa(
                    self._paths[command.ids[0]],
                    command.color,
                    command.numbers[0],
                    self._dashes[command.ids[1]],
                    command.numbers[1],
                    LineCap(command.ids[2]),
                    LineJoin(command.ids[3]),
                    command.numbers[2],
                )
            elif command.op == _DL_FILL_PATH_AA_24:
                target.fill_path_aa(
                    self._paths[command.ids[0]],
                    command.color,
                    FillRule(command.ids[1]),
                )
            elif command.op == _DL_DRAW_IMAGE_25:
                target.draw_image(
                    self._images[command.ids[0]],
                    command.numbers[0],
                    command.numbers[1],
                    command.numbers[2],
                    command.numbers[3],
                )
            elif command.op == _DL_DRAW_TEXT_26:
                target.draw_text(
                    command.numbers[0],
                    command.numbers[1],
                    self._strings[command.ids[0]],
                    command.color,
                    command.numbers[2],
                    self._strings[command.ids[1]],
                    FontSlant(command.ids[2]),
                    FontWeight(command.ids[3]),
                    command.numbers[3],
                    TextAlign(command.ids[4]),
                    cache=cache,
                )
            elif command.op == _DL_DRAW_TEXT_RUNS_27:
                target.draw_text_runs(
                    command.numbers[0],
                    command.numbers[1],
                    self._runs[command.ids[0]],
                    command.color,
                    self._strings[command.ids[1]],
                    FontWeight(command.ids[2]),
                    command.numbers[2],
                    TextAlign(command.ids[3]),
                    cache=cache,
                )
            elif command.op == _DL_PUSH_CLIP_28:
                target.push_clip(
                    command.ids[0],
                    command.ids[1],
                    command.ids[2],
                    command.ids[3],
                )
            elif command.op == _DL_POP_CLIP_29:
                target.pop_clip()
            elif command.op == _DL_PUSH_CLIP_PATH_30:
                target.push_clip_path(
                    self._paths[command.ids[0]], FillRule(command.ids[1])
                )
            elif command.op == _DL_POP_CLIP_PATH_31:
                target.pop_clip_path()
            elif command.op == _DL_BEGIN_ANNOTATED_GROUP_32:
                target.begin_annotated_group(self._strings[command.ids[0]])
                scope.group = True
            elif command.op == _DL_END_ANNOTATED_GROUP_33:
                target.end_annotated_group()
                scope.group = False
            elif command.op == _DL_BEGIN_BATCH_34:
                target.begin_batch()
                scope.batches += 1
            elif command.op == _DL_END_BATCH_35:
                target.end_batch()
                scope.batches -= 1
            elif command.op == _DL_SAVE_36:
                target.save()
                scope.saves += 1
            elif command.op == _DL_RESTORE_37:
                target.restore()
                scope.saves -= 1
            elif command.op == _DL_TRANSLATE_38:
                target.translate(command.numbers[0], command.numbers[1])
            elif command.op == _DL_ROTATE_39:
                target.rotate(command.numbers[0])
            elif command.op == _DL_SCALE_40:
                target.scale(command.numbers[0], command.numbers[1])
            elif command.op == _DL_TRANSFORM_41:
                target.transform(
                    Matrix2D(
                        command.numbers[0],
                        command.numbers[1],
                        command.numbers[2],
                        command.numbers[3],
                        command.numbers[4],
                        command.numbers[5],
                    )
                )
            elif command.op == _DL_SET_TRANSFORM_42:
                target.set_transform(
                    Matrix2D(
                        command.numbers[0],
                        command.numbers[1],
                        command.numbers[2],
                        command.numbers[3],
                        command.numbers[4],
                        command.numbers[5],
                    ).then(baseline)
                )
            elif command.op == _DL_RESET_TRANSFORM_43:
                target.set_transform(baseline)
            elif command.op == _DL_SET_BLEND_MODE_44:
                target.set_blend_mode(BlendMode(command.ids[0]))
            elif command.op == _DL_SET_COLOR_SPACE_45:
                target.set_color_space(ColorSpace(command.ids[0]))

    def _unwind[T: DrawTarget](self, mut target: T, scope: _ReplayScope):
        if scope.group:
            target.end_annotated_group()
        for _ in range(scope.batches):
            target.end_batch()
        for _ in range(scope.saves):
            target.restore()
        target.restore()

    def replay[
        T: DrawTarget
    ](self, mut target: T, *, mut cache: FontCache) raises:
        """Replay in order, relative to the incoming destination state.

        Recorded set_transform composes its matrix after the baseline;
        reset_transform returns to the baseline. Incoming clips stay active.
        Balanced recorded batches nest within an incoming raster batch.
        End any incoming annotated group first; groups cannot nest.

        Args:
            target: Destination; graphics state is restored on error too.
            cache: Font resolution/cache for this replay, never retained.

        Raises:
            Error: Invalid recording scopes, an open destination annotated
                group on SVG/PDF, or a destination drawing error.
        """
        self.validate()
        comptime if T == SvgCanvas:
            if rebind[SvgCanvas](target)._open_group:
                raise Error(
                    "DisplayList: end destination annotated group before replay"
                )
        elif T == PdfCanvas:
            if rebind[PdfCanvas](target)._open_group:
                raise Error(
                    "DisplayList: end destination annotated group before replay"
                )
        var baseline = target.current_transform()
        var scope = _ReplayScope()
        target.save()
        try:
            self._play(target, baseline, scope, cache)
        except e:
            self._unwind(target, scope)
            raise e
        self._unwind(target, scope)

    def bounds(self, *, mut cache: FontCache) raises -> DisplayListBounds:
        """Measure conservative logical ink using the supplied font cache.

        Uses an unbounded BoundsTarget, including stroke styles, text blocks,
        image boxes and ordinary line geometry used for math rules. Nonfinite
        geometry, failed font resolution, or nonfinite resulting extents
        return unknown bounds. Recompute when replay font configuration changes.
        """
        if not self._finite():
            return DisplayListBounds()
        self.validate()
        var target = BoundsTarget()
        try:
            self.replay(target, cache=cache)
        except:
            return DisplayListBounds()
        if not target.has_ink():
            return DisplayListBounds(known=True)
        var box = target.ink_bounds()
        if (
            not isfinite(box[0])
            or not isfinite(box[1])
            or not isfinite(box[2])
            or not isfinite(box[3])
        ):
            return DisplayListBounds()
        return DisplayListBounds(
            True, True, box[0] - 0.5, box[1] - 0.5, box[2] + 0.5, box[3] + 0.5
        )

    def storage_bytes(self) -> Int:
        """Retained storage estimate: object, list capacities and string bytes.

        Excludes allocator headers/rounding and string spare capacity. Includes
        command spare capacity. Fonts, caller caches and transient replay
        allocations are excluded because the recording does not retain them.
        """
        var result = (
            size_of[Self]() + self._commands.capacity() * size_of[_Command]()
        )
        result += self._saved.capacity() * size_of[_LocalState]()
        result += self._paths.capacity() * size_of[Path]()
        result += self._images.capacity() * size_of[Canvas]()
        result += self._gradients.capacity() * size_of[LinearGradient]()
        result += self._strings.capacity() * size_of[String]()
        result += self._points.capacity() * size_of[List[FPoint]]()
        result += self._indices.capacity() * size_of[List[Int]]()
        result += self._dashes.capacity() * size_of[List[Float64]]()
        result += self._colors.capacity() * size_of[List[Color]]()
        result += self._runs.capacity() * size_of[List[TextRun]]()
        for path_index in range(len(self._paths)):
            ref path = self._paths[path_index]
            result += path.commands.capacity() * size_of[PathCommand]()
        for image_index in range(len(self._images)):
            ref image = self._images[image_index]
            result += image.pixels.capacity()
        for string_index in range(len(self._strings)):
            ref string = self._strings[string_index]
            result += string.byte_length() + 1
        for gradient_index in range(len(self._gradients)):
            ref gradient = self._gradients[gradient_index]
            result += gradient.stops._stops.capacity() * size_of[GradientStop]()
            result += (
                gradient.stops._intervals.capacity() * size_of[_Interval]()
            )
            result += (
                gradient.stops._transfer.to_linear.capacity()
                * size_of[Float32]()
            )
            result += gradient.stops._transfer.to_srgb.capacity()
        for values_index in range(len(self._points)):
            ref values = self._points[values_index]
            result += values.capacity() * size_of[FPoint]()
        for values_index in range(len(self._indices)):
            ref values = self._indices[values_index]
            result += values.capacity() * size_of[Int]()
        for values_index in range(len(self._dashes)):
            ref values = self._dashes[values_index]
            result += values.capacity() * size_of[Float64]()
        for values_index in range(len(self._colors)):
            ref values = self._colors[values_index]
            result += values.capacity() * size_of[Color]()
        for values_index in range(len(self._runs)):
            ref values = self._runs[values_index]
            result += values.capacity() * size_of[TextRun]()
        for runs_index in range(len(self._runs)):
            ref runs = self._runs[runs_index]
            for run_index in range(len(runs)):
                ref run = runs[run_index]
                result += run.text.byte_length() + 1
        return result

    def list_buffer_count(self) -> Int:
        """Retained List backing buffers, including resource tables.

        Excludes String internals and allocator metadata; this counts live
        backing buffers rather than allocation calls made during recording.
        Scalar commands share one buffer instead of owning one each.
        """
        var result = Int(self._commands.capacity() > 0) + Int(
            self._saved.capacity() > 0
        )
        result += Int(self._paths.capacity() > 0)
        result += Int(self._images.capacity() > 0)
        result += Int(self._gradients.capacity() > 0)
        result += Int(self._strings.capacity() > 0)
        result += Int(self._points.capacity() > 0)
        result += Int(self._indices.capacity() > 0)
        result += Int(self._dashes.capacity() > 0)
        result += Int(self._colors.capacity() > 0)
        result += Int(self._runs.capacity() > 0)
        for path_index in range(len(self._paths)):
            ref path = self._paths[path_index]
            result += Int(path.commands.capacity() > 0)
        for image_index in range(len(self._images)):
            ref image = self._images[image_index]
            result += Int(image.pixels.capacity() > 0)
        for gradient_index in range(len(self._gradients)):
            ref gradient = self._gradients[gradient_index]
            result += Int(gradient.stops._stops.capacity() > 0)
            result += Int(gradient.stops._intervals.capacity() > 0)
            result += Int(gradient.stops._transfer.to_linear.capacity() > 0)
            result += Int(gradient.stops._transfer.to_srgb.capacity() > 0)
        for values_index in range(len(self._points)):
            ref values = self._points[values_index]
            result += Int(values.capacity() > 0)
        for values_index in range(len(self._indices)):
            ref values = self._indices[values_index]
            result += Int(values.capacity() > 0)
        for values_index in range(len(self._dashes)):
            ref values = self._dashes[values_index]
            result += Int(values.capacity() > 0)
        for values_index in range(len(self._colors)):
            ref values = self._colors[values_index]
            result += Int(values.capacity() > 0)
        for values_index in range(len(self._runs)):
            ref values = self._runs[values_index]
            result += Int(values.capacity() > 0)
        return result
