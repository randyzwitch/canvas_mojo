"""What a `Canvas` batch records: the op, the batch holding them, and
the constructors for the ops with no geometry to gather.

These are the recording half of batching. They are plain data --
scalars and side lists, no `Canvas` -- so that recording an op is an
append and a batch of thousands of markers costs a few amortized
growths rather than an allocation each. `canvas.batch` is the other
half: it walks these per row band and draws them.

They live in their own module because both halves need them and
neither owns them: `canvas.buffer` records, `canvas.batch` renders,
and `canvas.shapes` reaches for the op constructors when a primitive
records itself instead of drawing.
"""

from std.math import ceil, floor

from canvas.aa_crossing import _EdgeTable
from canvas.color import Color
from canvas.fill_rule import FillRule
from canvas.geometry import FPoint, Matrix2D
from canvas.path import Path, PathCommand
from canvas.shapes.lines import LineCap, LineJoin


# What a `_BatchOp` holds: edges to rasterize, a closed-form disk or
# ellipse, a solid rectangle, or a stroke or path still to be built
# into edges when the batch is drawn.
comptime _OP_EDGES = 0
comptime _OP_DISK = 1
comptime _OP_ELLIPSE = 2
comptime _OP_RECT = 3
comptime _OP_STROKE = 4
comptime _OP_PATH = 5
# A cached glyph's coverage mask, recorded so that text inside a batch
# replays per band like every other op rather than forcing a flush
# (#391). The counts live in the batch's own `glyph_counts`.
comptime _OP_GLYPH = 6
# A rectangle clip pushed and popped inside a batch. Recorded rather
# than flushing, so a band applies it to its own clip stack and the
# shapes after it are clipped where they are drawn (#409 follow-up).
# A clip that is a coverage mask -- pushed under a rotation, or a path
# clip -- still flushes; only the rectangle form records.
# A whole bulk marker call: every centre of one `fill_circles_aa` as a
# range of the batch's points, replayed per band through the same band
# body the call's own threads use. One op rather than one per marker,
# because 2,000 separate ops replayed across 30 bands cost more than
# the buffer the region saves (#414).
comptime _OP_MARKERS = 9
# A whole `fill_mesh` call: `first_point`/`point_count` into `points`,
# `first_face`/`face_count` triples into `mesh_faces`, `first_dash`
# into `marker_colors` for the face colors (#425).
comptime _OP_MESH = 10
comptime _OP_PUSH_CLIP = 7
comptime _OP_POP_CLIP = 8


struct _BatchOp(Copyable, ImplicitlyCopyable, Movable):
    """One primitive recorded between `Canvas.begin_batch` and
    `end_batch`: its paint, the canvas rows it can touch (which a band
    reads to skip it), and either its closed-form parameters or
    indices into the batch's side lists (`_Batch`) for its geometry.
    Scalars only, so recording an op is an append and a batch of
    thousands owns a few allocations rather than one per op --
    allocation across many threads was most of what a batch of tiny
    shapes cost when each op held its own lists.

    An op is recorded as early in its primitive's pipeline as the
    canvas state allows, so that what follows can run in parallel when
    the batch is drawn: a stroke as its device-space points and stroke
    style (`_OP_STROKE`), a path fill as the path (`_OP_PATH`), both
    turned into edges by `canvas.batch` before the band pass; a
    polygon fill as the edges it already built (`_OP_EDGES`, exact
    area or the sampled sweep); a disk or ellipse small enough for the
    closed form; a rectangle already intersected with the clip. Each
    is what the primitive's raster stage would have consumed at the
    call, under the transform, clip, blend mode and color space then
    in force, so rendering it later, on any band, writes the pixels
    the call would have.
    """

    var kind: Int
    var color: Color
    var exact: Bool
    var fill_rule: FillRule
    var supersample: Int
    # An edge range's unpadded bounds; a rectangle's x, y and the
    # exclusive x + width, y + height; a disk's or ellipse's box.
    var min_x: Int
    var min_y: Int
    var max_x: Int
    var max_y: Int
    # The closed forms.
    var cx: Float64
    var cy: Float64
    var rx: Float64
    var ry: Float64
    # `_OP_EDGES`: edges [first_edge, last_edge) of the batch's table
    # `table`. A sampled op has a table of its own, whole.
    var table: Int
    var first_edge: Int
    var last_edge: Int
    # `_OP_STROKE`: `point_count` of the batch's points from
    # `first_point`, `dash_count` of its dashes from `first_dash`, and
    # the style, in the space `matrix` maps to the device.
    var first_point: Int
    var point_count: Int
    # `_OP_MESH`: index triples [first_face, first_face + 3 * face_count)
    # of the batch's `mesh_faces`, relative to `first_point`.
    var first_face: Int
    var face_count: Int
    # `_OP_MESH`: whether its colors are one per vertex, interpolated
    # across each face, rather than one per face (#426).
    var per_vertex: Bool
    var closed: Bool
    var half_width: Float64
    var first_dash: Int
    var dash_count: Int
    var dash_offset: Float64
    var cap: LineCap
    var join: LineJoin
    var miter_limit: Float64
    var matrix: Matrix2D
    # `_OP_PATH`: the batch's path `path`, its flattening, and about
    # how many vertices it flattens to.
    var first_command: Int
    var command_count: Int
    var curve_steps: Int
    var path_work: Int
    # Rows [first_row, last_row) the op can write, in canvas rows;
    # empty until a stroke or path is built.
    var first_row: Int
    var last_row: Int

    def __init__(out self, kind: Int, color: Color):
        """An op of `kind` with nothing else set; the builders below
        fill in what the kind needs."""
        self.kind = kind
        self.color = color
        self.exact = True
        self.fill_rule = FillRule.NONZERO
        self.supersample = 0
        self.min_x = 0
        self.min_y = 0
        self.max_x = 0
        self.max_y = 0
        self.cx = 0.0
        self.cy = 0.0
        self.rx = 0.0
        self.ry = 0.0
        self.table = 0
        self.first_edge = 0
        self.last_edge = 0
        self.first_point = 0
        self.point_count = 0
        self.first_face = 0
        self.face_count = 0
        self.per_vertex = False
        self.closed = False
        self.half_width = 0.0
        self.first_dash = 0
        self.dash_count = 0
        self.dash_offset = 0.0
        self.cap = LineCap.ROUND
        self.join = LineJoin.ROUND
        self.miter_limit = 4.0
        self.matrix = Matrix2D.identity()
        self.first_command = 0
        self.command_count = 0
        self.curve_steps = 0
        self.path_work = 0
        self.first_row = 0
        self.last_row = 0

    def set_edges(
        mut self,
        table: Int,
        first_edge: Int,
        last_edge: Int,
        min_x: Int,
        min_y: Int,
        max_x: Int,
        max_y: Int,
        exact: Bool,
    ):
        """Make the op an `_OP_EDGES` over that range of that table,
        with the unpadded bounds the sweep pads: the rows are the ones
        `_area_edges_aa` and the sampled sweep visit. An empty range
        leaves the op touching no row.
        """
        self.kind = _OP_EDGES
        self.exact = exact
        self.table = table
        self.first_edge = first_edge
        self.last_edge = last_edge
        if last_edge <= first_edge:
            self.first_row = 0
            self.last_row = 0
            return
        self.min_x = min_x
        self.min_y = min_y
        self.max_x = max_x
        self.max_y = max_y
        self.first_row = min_y - 1
        self.last_row = max_y + 2

    def geometry_work(self) -> Int:
        """How much building the op's edges will cost, in vertices:
        what the batch weighs against splitting the build across
        tasks. Zero for an op with nothing to build.
        """
        if self.kind == _OP_STROKE:
            return self.point_count
        if self.kind == _OP_PATH:
            return self.path_work
        return 0

    def work(self) -> Int:
        """About how many pixels rendering the op visits: its box.
        What the batch weighs against the parallel threshold.
        """
        var rows = self.last_row - self.first_row
        var cols = self.max_x - self.min_x + 3
        if rows <= 0 or cols <= 0:
            return 0
        return rows * cols


struct _Batch(Copyable, Movable):
    """Everything recorded since the outermost `Canvas.begin_batch`:
    the ops, and the side lists their indices point into -- the
    strokes' points and dash patterns, the paths, and the edge tables.
    Table 0 gathers the edges recorded ready-made (polygon fills and
    the strokes that reach `_rasterize_stroke` already built); a
    sampled op gets a table of its own, since the sampled sweep sorts
    and seeds a whole table; and drawing the batch adds one table per
    build task. `canvas.batch` renders one of these.
    """

    var ops: List[_BatchOp]
    var points: List[FPoint]
    var dashes: List[Float64]
    # Every recorded path's commands, end to end, each op holding its
    # own range. One list of commands rather than a `Path` per op, so
    # a batch of thousands of markers costs a few amortized growths
    # instead of an allocation and a free each (#390), which is what
    # #387 did for edges and points.
    var commands: List[PathCommand]
    # Every recorded glyph's coverage bytes, end to end, each op
    # holding its own range (#391).
    var glyph_counts: List[UInt8]
    # Per-marker colours for the recorded bulk calls that carry them,
    # and per-face colours for recorded meshes.
    var marker_colors: List[Color]
    # Every recorded mesh's index triples, end to end, each op holding
    # its own range; the vertices go into `points` (#425).
    var mesh_faces: List[Int]
    # Whether any op changes the clip. Those mutate the clip stack of
    # the canvas they replay onto, which is safe when every band has
    # its own scratch (a supersampled region) and a data race when the
    # bands share one canvas, so a batch holding them renders on one
    # band (#412).
    var has_clip_ops: Bool
    var tables: List[_EdgeTable]

    def __init__(out self):
        self.ops = List[_BatchOp]()
        self.points = List[FPoint]()
        self.dashes = List[Float64]()
        self.commands = List[PathCommand]()
        self.glyph_counts = List[UInt8]()
        self.marker_colors = List[Color]()
        self.mesh_faces = List[Int]()
        self.has_clip_ops = False
        self.tables = List[_EdgeTable]()
        self.tables.append(_EdgeTable())

    def reserve_like(mut self, other: _Batch):
        """Room for a batch the size of `other`: the next one usually
        is."""
        self.ops.reserve(len(other.ops))
        self.points.reserve(len(other.points))
        self.commands.reserve(len(other.commands))
        self.glyph_counts.reserve(len(other.glyph_counts))
        self.marker_colors.reserve(len(other.marker_colors))
        self.mesh_faces.reserve(len(other.mesh_faces))

    def record_edges(
        mut self,
        edges: _EdgeTable,
        min_x: Int,
        min_y: Int,
        max_x: Int,
        max_y: Int,
        color: Color,
        fill_rule: FillRule,
        supersample: Int,
        exact: Bool,
    ):
        """Edges already built, appended to table 0 when they
        rasterize by exact area and copied into a table of their own
        when they take the sampled sweep (already top-sorted then)."""
        var op = _BatchOp(_OP_EDGES, color)
        op.fill_rule = fill_rule
        op.supersample = supersample
        var table = 0
        var first = 0
        var last = len(edges.y_lo)
        if exact:
            first = len(self.tables[0].y_lo)
            self.tables[0].extend(edges)
            last = len(self.tables[0].y_lo)
        else:
            self.tables.append(edges.copy())
            table = len(self.tables) - 1
        op.set_edges(table, first, last, min_x, min_y, max_x, max_y, exact)
        self.ops.append(op)

    def record_stroke(
        mut self,
        points: List[FPoint],
        closed: Bool,
        half_width: Float64,
        cap: LineCap,
        dashes: List[Float64],
        dash_offset: Float64,
        join: LineJoin,
        miter_limit: Float64,
        matrix: Matrix2D,
        supersample: Int,
        color: Color,
    ):
        """A stroke as `_stroke_edges` takes it, to be built when the
        batch is drawn."""
        var op = _BatchOp(_OP_STROKE, color)
        op.first_point = len(self.points)
        op.point_count = len(points)
        for i in range(len(points)):
            self.points.append(points[i])
        op.closed = closed
        op.half_width = half_width
        op.cap = cap
        op.first_dash = len(self.dashes)
        op.dash_count = len(dashes)
        for i in range(len(dashes)):
            self.dashes.append(dashes[i])
        op.dash_offset = dash_offset
        op.join = join
        op.miter_limit = miter_limit
        op.matrix = matrix
        op.supersample = supersample
        self.ops.append(op)

    def record_path(
        mut self,
        path: Path,
        fill_rule: FillRule,
        supersample: Int,
        curve_steps: Int,
        color: Color,
    ):
        """A device-space path to fill, flattened and built when the
        batch is drawn. The commands are appended to the batch's own
        list and the op keeps their range, so recording a path is an
        extend rather than an allocation (#390)."""
        var op = _BatchOp(_OP_PATH, color)
        op.first_command = len(self.commands)
        op.command_count = len(path.commands)
        # Appended through the source's pointer: `extend` would take a
        # copy of the whole list first, which is the allocation this
        # change exists to remove. No `reserve` per record -- reserving
        # to an exact length every time grows the list by a few
        # commands at a time instead of geometrically, which made the
        # record slower than the copy it replaced.
        var cp = path.commands.unsafe_ptr()
        for k in range(op.command_count):
            self.commands.append(cp[unsafe_offset=k])
        op.path_work = op.command_count * 4
        op.fill_rule = fill_rule
        op.supersample = supersample
        op.curve_steps = curve_steps
        self.ops.append(op)


def _glyph_op(
    first: Int,
    count: Int,
    width: Int,
    height: Int,
    left: Int,
    top: Int,
    total_samples: Int,
    color: Color,
) -> _BatchOp:
    """A cached glyph's coverage mask placed at (left, top): `count`
    bytes of the batch's `glyph_counts` from `first`, `width` wide.
    """
    var op = _BatchOp(_OP_GLYPH, color)
    op.first_command = first
    op.command_count = count
    op.min_x = left
    op.min_y = top
    op.max_x = left + width
    op.max_y = top + height
    op.supersample = total_samples
    op.first_row = top
    op.last_row = top + height
    return op


def _clip_op(kind: Int, x: Int, y: Int, width: Int, height: Int) -> _BatchOp:
    """A recorded clip push or pop. The rows are the whole canvas, but
    a band applies these whatever its rows are: skipping one would
    leave the band's clip stack unbalanced for every op after it.
    """
    var op = _BatchOp(kind, Color(0, 0, 0, 0))
    op.min_x = x
    op.min_y = y
    op.max_x = x + width
    op.max_y = y + height
    return op


def _disk_op(
    cx: Float64, cy: Float64, radius: Float64, color: Color
) -> _BatchOp:
    """A closed-form disk; its rows are the ones `_fill_circle_aa_rows`
    visits."""
    var op = _BatchOp(_OP_DISK, color)
    op.cx = cx
    op.cy = cy
    op.rx = radius
    op.ry = radius
    op.min_x = Int(floor(cx - radius)) - 1
    op.max_x = Int(ceil(cx + radius)) + 2
    op.first_row = Int(floor(cy - radius)) - 1
    op.last_row = Int(ceil(cy + radius)) + 2
    return op


def _ellipse_op(
    cx: Float64, cy: Float64, rx: Float64, ry: Float64, color: Color
) -> _BatchOp:
    """A closed-form ellipse; its rows are the ones
    `_fill_ellipse_aa_rows` visits."""
    var op = _BatchOp(_OP_ELLIPSE, color)
    op.cx = cx
    op.cy = cy
    op.rx = rx
    op.ry = ry
    op.min_x = Int(floor(cx - rx)) - 1
    op.max_x = Int(ceil(cx + rx)) + 2
    op.first_row = Int(floor(cy - ry)) - 1
    op.last_row = Int(ceil(cy + ry)) + 2
    return op


def _rect_op(x: Int, y: Int, width: Int, height: Int, color: Color) -> _BatchOp:
    """A solid rectangle already intersected with the canvas and the
    rectangle clip, as `_fill_region` takes it."""
    var op = _BatchOp(_OP_RECT, color)
    op.min_x = x
    op.min_y = y
    op.max_x = x + width
    op.max_y = y + height
    op.first_row = y
    op.last_row = y + height
    return op
