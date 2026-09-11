"""Rendering a `Canvas` batch: the primitives recorded between
`begin_batch` and `end_batch`, drawn in one banded pass.

Every op was recorded under the state in force when it was called
(`_BatchOp`), so rendering is one walk over the ops per row band, in
submission order, each op restricted to the band's rows by the
row-restricted body its shape already had: the area accumulator's
band, the sampled sweep's band, the closed-form disk and ellipse
rows, `_fill_region` on a rectangle's rows. Bands own disjoint rows
and read the batch only, which is the whole safety argument, the same
one `fill_circles_aa` makes. Order within a band is what makes
overlapping translucent shapes come out as drawing them one at a time
would.

A row's pixels do not depend on which band computes it -- each row
body starts from the op's own geometry -- so the bytes are those of
drawing every op at once, at any band count (`tests/test_batch.mojo`).

Before the band pass, the strokes and paths recorded as geometry are
built into edges (`_build_ops`), in parallel over the ops. Drawn one
call at a time, that build ran on one core ahead of every stroke's
raster stage; it is the serial prologue #383 and #373 measured. Each
build task appends what it builds into one edge table of its own,
allocated and filled by the same thread and read by the bands, so a
batch of thousands of small shapes costs a few allocations rather
than several per op: with one table per op the parallel build spent
its time in the allocator and the teardown ran serially over
thousands of tables, and a batch of 2,000 small paths was slower than
drawing them one at a time.
"""

from std.runtime.asyncrt import TaskGroup

from canvas.aa_area import _AreaScratch, _CELLS_PER_BAND, _area_edges_rows
from canvas.aa_crossing import (
    _EdgeTable,
    _rules_agree,
    _sweep_edges_sampled_rows,
)
from canvas.buffer import (
    Canvas,
    _Batch,
    _BatchOp,
    _OP_DISK,
    _OP_EDGES,
    _OP_ELLIPSE,
    _OP_PATH,
    _OP_RECT,
    _OP_STROKE,
)
from canvas.fill_rule import FillRule
from canvas.geometry import FPoint
from canvas.path import Path, PathCommand, _FillEdges, _flatten_commands
from canvas.shapes.circles import _fill_circle_aa_rows
from canvas.shapes.ellipses import _fill_ellipse_aa_rows
from canvas.shapes.lines import _stroke_edges
from canvas.compose import draw_canvas, draw_image
from canvas.resize import downsample
from canvas.workers import _bands_for_work, _worker_limit

# Below this many vertices across the batch's strokes and paths, they
# are built inline; a task costs about as much as a small stroke.
comptime _MIN_PARALLEL_GEOMETRY = 512
# Vertices each build task should have at least.
comptime _GEOMETRY_PER_TASK = 256


struct _Built(Movable):
    """What building one stroke or path op yields: its edges, whether
    they rasterize by exact area, and the unpadded bounds the sweep
    would have padded."""

    var edges: _EdgeTable
    var exact: Bool
    var min_x: Int
    var min_y: Int
    var max_x: Int
    var max_y: Int

    def __init__(
        out self,
        var edges: _EdgeTable,
        exact: Bool,
        b: Tuple[Int, Int, Int, Int],
    ):
        self.edges = edges^
        self.exact = exact
        self.min_x = b[0]
        self.min_y = b[1]
        self.max_x = b[2]
        self.max_y = b[3]


def _build_geometry(
    op: _BatchOp,
    points: List[FPoint],
    dashes: List[Float64],
    commands: List[PathCommand],
) -> _Built:
    """The edges of a stroke or path op, built as its primitive would
    have built them ahead of the raster stage, with the same
    functions, so the table is the same. `_rules_agree` needs the
    table mutable and sorts it as a side effect; a sampled result is
    sorted for the sweep.
    """
    if op.kind == _OP_STROKE:
        var pts = List[FPoint](capacity=op.point_count)
        for i in range(op.first_point, op.first_point + op.point_count):
            pts.append(points[i])
        var dash = List[Float64](capacity=op.dash_count)
        for i in range(op.first_dash, op.first_dash + op.dash_count):
            dash.append(dashes[i])
        var shape = _stroke_edges(
            pts,
            op.closed,
            op.half_width,
            op.cap,
            dash,
            op.dash_offset,
            op.join,
            op.miter_limit,
            op.matrix,
        )
        var exact = shape.exact
        if not exact:
            shape.edges.sort_by_top()
        var b = shape.edges.bounds()
        return _Built(shape.edges.copy(), exact, b)
    var subpaths = _flatten_commands(
        commands, op.first_command, op.command_count, op.curve_steps
    )
    if len(subpaths) == 0:
        return _Built(_EdgeTable(), True, (0, 0, 0, 0))
    var fe = _FillEdges(subpaths)
    var exact = op.fill_rule == FillRule.NONZERO or _rules_agree(
        fe.edges, fe.min_y, fe.max_y
    )
    if not exact:
        fe.edges.sort_by_top()
    return _Built(
        fe.edges.copy(), exact, (fe.min_x, fe.min_y, fe.max_x, fe.max_y)
    )


def _build_into(
    mut ops: List[_BatchOp],
    i: Int,
    mut table: _EdgeTable,
    table_index: Int,
    points: List[FPoint],
    dashes: List[Float64],
    commands: List[PathCommand],
) -> Bool:
    """Build op `i` and, when it rasterizes by exact area, append its
    edges to `table` and point the op at that range. A sampled result
    is left for the caller, which returns False; a table of its own
    has to be added to the batch, and a task cannot grow the batch's
    lists.
    """
    var built = _build_geometry(ops[i], points, dashes, commands)
    if len(built.edges.y_lo) == 0:
        ops[i].set_edges(table_index, 0, 0, 0, 0, 0, 0, True)
        return True
    if not built.exact:
        return False
    var first = len(table.y_lo)
    table.extend(built.edges)
    ops[i].set_edges(
        table_index,
        first,
        len(table.y_lo),
        built.min_x,
        built.min_y,
        built.max_x,
        built.max_y,
        True,
    )
    return True


async def _build_task_async(
    mut ops: List[_BatchOp],
    mut tables: List[_EdgeTable],
    table_index: Int,
    task: Int,
    tasks: Int,
    points: List[FPoint],
    dashes: List[Float64],
    commands: List[PathCommand],
):
    """Build the stroke and path ops whose index is `task` modulo
    `tasks` into `tables[table_index]`: the interleaving spreads a
    batch's few large strokes over the tasks. Tasks write disjoint
    slots of `ops` and disjoint tables, and grow neither list. Every
    argument is borrowed, never owned (#97).
    """
    var i = task
    var n = len(ops)
    while i < n:
        if ops[i].geometry_work() > 0:
            _ = _build_into(
                ops,
                i,
                tables[table_index],
                table_index,
                points,
                dashes,
                commands,
            )
        i += tasks


def _build_ops(mut batch: _Batch, cap: Int):
    """Build every stroke's and path's edges, across tasks when there
    is enough to build, each task into a table of its own; then the
    few ops the sampled sweep will draw, which need a whole table
    each, on the calling thread.
    """
    var work = 0
    var pending = 0
    for i in range(len(batch.ops)):
        var w = batch.ops[i].geometry_work()
        if w > 0:
            work += w
            pending += 1
    if pending == 0:
        return
    var tasks = 1
    if work >= _MIN_PARALLEL_GEOMETRY:
        tasks = min(
            _worker_limit(cap), min(pending, work // _GEOMETRY_PER_TASK)
        )
    if tasks < 1:
        tasks = 1
    var base = len(batch.tables)
    for _ in range(tasks):
        batch.tables.append(_EdgeTable())
    if tasks == 1:
        for i in range(len(batch.ops)):
            if batch.ops[i].geometry_work() > 0:
                _ = _build_into(
                    batch.ops,
                    i,
                    batch.tables[base],
                    base,
                    batch.points,
                    batch.dashes,
                    batch.commands,
                )
    else:
        var tg = TaskGroup()
        for t in range(tasks):
            tg.create_task(
                _build_task_async(
                    batch.ops,
                    batch.tables,
                    base + t,
                    t,
                    tasks,
                    batch.points,
                    batch.dashes,
                    batch.commands,
                )
            )
        tg.wait()
        _ = len(batch.ops)  # last use past the tasks (#263)
    # Whatever is still geometry takes the sampled sweep: a whole,
    # sorted table each.
    for i in range(len(batch.ops)):
        if batch.ops[i].geometry_work() == 0:
            continue
        var built = _build_geometry(
            batch.ops[i], batch.points, batch.dashes, batch.commands
        )
        var n = len(built.edges.y_lo)
        var min_x = built.min_x
        var min_y = built.min_y
        var max_x = built.max_x
        var max_y = built.max_y
        batch.tables.append(built.edges.copy())
        batch.ops[i].set_edges(
            len(batch.tables) - 1, 0, n, min_x, min_y, max_x, max_y, False
        )


def _batch_band(mut canvas: Canvas, batch: _Batch, row_lo: Int, row_hi: Int):
    """Every op reaching rows [row_lo, row_hi), in submission order,
    each drawing only those rows. Bands write disjoint rows.
    """
    var scratch = _AreaScratch()
    for i in range(len(batch.ops)):
        # Bound by reference: most ops do not reach this band, so the
        # loop is mostly a rejection scan, and binding by value copied
        # the whole `_BatchOp` -- about 250 bytes -- to read two
        # fields and skip. Worth about 4% of a flush of 2,000 disks at
        # 64 bands, where it was 128,000 copies; nothing on a batch of
        # a few hundred ops (#389).
        ref op = batch.ops[i]
        if op.last_row <= row_lo or op.first_row >= row_hi:
            continue
        if op.kind == _OP_EDGES:
            if op.exact:
                _area_edges_rows(
                    canvas,
                    batch.tables[op.table],
                    op.first_edge,
                    op.last_edge,
                    op.min_x,
                    op.min_y,
                    op.max_x,
                    op.max_y,
                    op.color,
                    row_lo,
                    row_hi,
                    scratch,
                )
            else:
                _sweep_edges_sampled_rows(
                    canvas,
                    batch.tables[op.table],
                    op.min_x,
                    op.min_y,
                    op.max_x,
                    op.max_y,
                    op.color,
                    op.fill_rule,
                    op.supersample,
                    row_lo,
                    row_hi,
                )
        elif op.kind == _OP_DISK:
            _fill_circle_aa_rows(
                canvas, op.cx, op.cy, op.rx, op.color, row_lo, row_hi
            )
        elif op.kind == _OP_ELLIPSE:
            _fill_ellipse_aa_rows(
                canvas, op.cx, op.cy, op.rx, op.ry, op.color, row_lo, row_hi
            )
        elif op.kind == _OP_RECT:
            var y0 = max(op.min_y, row_lo)
            var y1 = min(op.max_y, row_hi)
            if y1 > y0:
                canvas._fill_region(
                    op.min_x, y0, op.max_x - op.min_x, y1 - y0, op.color
                )


async def _batch_band_async(
    mut canvas: Canvas, batch: _Batch, row_lo: Int, row_hi: Int
):
    """`_batch_band` as a task. `batch` is borrowed, never owned: a
    heap-backed aggregate handed to `create_task` by value is
    canvas_mojo#97.
    """
    _batch_band(canvas, batch, row_lo, row_hi)


def _render_batch(mut canvas: Canvas, mut batch: _Batch):
    """Draw `batch` onto `canvas`: build what is still geometry
    (`_build_ops`), then rasterize across row bands when the ops'
    boxes add up to enough work (`_bands_for_work`, at least
    `_CELLS_PER_BAND` per band), inline otherwise.
    """
    if len(batch.ops) == 0:
        return
    _build_ops(batch, canvas.max_workers())
    var work = 0
    for i in range(len(batch.ops)):
        ref op = batch.ops[i]
        work += op.work()
    var bands = _bands_for_work(
        work, canvas.height, _CELLS_PER_BAND, canvas.max_workers()
    )
    if bands <= 1:
        _batch_band(canvas, batch, 0, canvas.height)
        return
    var per_band = (canvas.height + bands - 1) // bands
    var tg = TaskGroup()
    for b in range(bands):
        var row_lo = b * per_band
        var row_hi = min(row_lo + per_band, canvas.height)
        if row_lo >= row_hi:
            continue
        tg.create_task(_batch_band_async(canvas, batch, row_lo, row_hi))
    tg.wait()
    # A task's borrow is not a use the compiler counts: named here so
    # the batch outlives the bands (#263).
    _ = len(batch.ops)


# Output rows per band of a supersampled replay. Each band holds a
# scratch of `width * factor` by `rows * factor` pixels, so this trades
# scratch size against the number of bands: twenty rows at factor 3
# over an 800-wide canvas is a 576 KB scratch, which stays inside the
# L2 the band's own core owns while giving a 600-row canvas thirty
# bands to spread over.
comptime _SUPERSAMPLE_BAND_ROWS = 20


def _supersampled_band(
    mut canvas: Canvas,
    batch: _Batch,
    factor: Int,
    y0: Int,
    rows: Int,
    background: Color,
) raises:
    """One output band of a supersampled region: a scratch holding
    only this band's enlarged rows, seeded with what the canvas
    already shows there, drawn into by the recorded ops restricted to
    those rows, downsampled, and written back.

    Bands write disjoint output rows and read only their own, which is
    the whole safety argument, the same one `_batch_band` makes.
    """
    # The band starts from the region's background, which is what the
    # two-step recipe's own scratch starts from. Seeding it instead
    # from what the canvas already shows costs more than the region
    # saves: a copy per pixel and a nearest-neighbour upscale were
    # both measured and both lost.
    var scratch = Canvas(canvas.width * factor, rows * factor, background)
    scratch.set_max_workers(1)
    # The geometry was recorded in the enlarged space; this scratch
    # holds the slice of it starting at `y0 * factor`.
    scratch._row_origin = y0 * factor
    scratch._virtual_width = canvas.width * factor
    scratch._virtual_height = canvas.height * factor
    _batch_band(scratch, batch, y0 * factor, (y0 + rows) * factor)
    scratch._row_origin = 0
    scratch._virtual_height = rows * factor

    var small = downsample(scratch, factor)
    draw_canvas(canvas, small, 0, y0)


async def _supersampled_band_async(
    mut canvas: Canvas,
    batch: _Batch,
    factor: Int,
    y0: Int,
    rows: Int,
    background: Color,
):
    """`_supersampled_band` as a task; `batch` is borrowed, never
    owned (canvas_mojo#97)."""
    try:
        _supersampled_band(canvas, batch, factor, y0, rows, background)
    except:
        pass


def _replay_supersampled(
    mut canvas: Canvas, mut batch: _Batch, factor: Int, background: Color
) raises:
    """Draw what `Canvas.begin_supersampled` recorded: the geometry is
    in a space `factor` times this canvas, and never materializes at
    that size. Each output band is one task, which is where the
    parallelism belongs -- a band that fanned out inside its own
    `downsample` measured 2.2x slower than not banding at all (#391).
    """
    if len(batch.ops) == 0:
        return
    _build_ops(batch, canvas.max_workers())
    var bands = (canvas.height + _SUPERSAMPLE_BAND_ROWS - 1) // (
        _SUPERSAMPLE_BAND_ROWS
    )
    if bands <= 1:
        _supersampled_band(canvas, batch, factor, 0, canvas.height, background)
        return
    var tg = TaskGroup()
    var y = 0
    while y < canvas.height:
        var rows = min(_SUPERSAMPLE_BAND_ROWS, canvas.height - y)
        tg.create_task(
            _supersampled_band_async(canvas, batch, factor, y, rows, background)
        )
        y += rows
    tg.wait()
    # A task's borrow is not a use the compiler counts (#263).
    _ = len(batch.ops)
