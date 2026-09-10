"""Rendering a `Canvas` batch: the primitives recorded between
`begin_batch` and `end_batch`, drawn in one banded pass.

Every op was recorded in device space under the state in force when
it was called (`_BatchOp`), so rendering is one walk over the ops per
row band, in submission order, each op restricted to the band's rows
by the row-restricted body its shape already had: the area
accumulator's band, the sampled sweep's band, the closed-form disk and
ellipse rows, `_fill_region` on a rectangle's rows. Bands own disjoint
rows and read the op list only, which is the whole safety argument,
the same one `fill_circles_aa` makes. Order within a band is what
makes overlapping translucent shapes come out as drawing them one at
a time would.

A row's pixels do not depend on which band computes it -- each row
body starts from the op's own geometry -- so the bytes are those of
drawing every op at once, at any band count (`tests/test_batch.mojo`).
"""

from std.runtime.asyncrt import TaskGroup

from canvas.aa_area import _CELLS_PER_BAND, _area_edges_rows
from canvas.aa_crossing import _sweep_edges_sampled_rows
from canvas.buffer import (
    Canvas,
    _BatchOp,
    _OP_DISK,
    _OP_EDGES,
    _OP_ELLIPSE,
    _OP_RECT,
)
from canvas.shapes.circles import _fill_circle_aa_rows
from canvas.shapes.ellipses import _fill_ellipse_aa_rows
from canvas.workers import _bands_for_work


def _batch_band(
    mut canvas: Canvas, ops: List[_BatchOp], row_lo: Int, row_hi: Int
):
    """Every op reaching rows [row_lo, row_hi), in submission order,
    each drawing only those rows. Bands write disjoint rows.
    """
    for i in range(len(ops)):
        ref op = ops[i]
        if op.last_row <= row_lo or op.first_row >= row_hi:
            continue
        if op.kind == _OP_EDGES:
            if op.exact:
                _area_edges_rows(
                    canvas,
                    op.edges,
                    op.min_x,
                    op.min_y,
                    op.max_x,
                    op.max_y,
                    op.color,
                    row_lo,
                    row_hi,
                )
            else:
                _sweep_edges_sampled_rows(
                    canvas,
                    op.edges,
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
        else:
            var y0 = max(op.min_y, row_lo)
            var y1 = min(op.max_y, row_hi)
            if y1 > y0:
                canvas._fill_region(
                    op.min_x, y0, op.max_x - op.min_x, y1 - y0, op.color
                )


async def _batch_band_async(
    mut canvas: Canvas, ops: List[_BatchOp], row_lo: Int, row_hi: Int
):
    """`_batch_band` as a task. `ops` is borrowed, never owned: a
    heap-backed aggregate handed to `create_task` by value is
    canvas_mojo#97.
    """
    _batch_band(canvas, ops, row_lo, row_hi)


def _render_batch(mut canvas: Canvas, ops: List[_BatchOp]):
    """Draw `ops` onto `canvas`, across row bands when their boxes add
    up to enough work (`_bands_for_work`, at least `_CELLS_PER_BAND`
    per band), inline otherwise.
    """
    if len(ops) == 0:
        return
    var work = 0
    for i in range(len(ops)):
        work += ops[i].work()
    var bands = _bands_for_work(
        work, canvas.height, _CELLS_PER_BAND, canvas.max_workers()
    )
    if bands <= 1:
        _batch_band(canvas, ops, 0, canvas.height)
        return
    var per_band = (canvas.height + bands - 1) // bands
    var tg = TaskGroup()
    for b in range(bands):
        var row_lo = b * per_band
        var row_hi = min(row_lo + per_band, canvas.height)
        if row_lo >= row_hi:
            continue
        tg.create_task(_batch_band_async(canvas, ops, row_lo, row_hi))
    tg.wait()
    # A task's borrow is not a use the compiler counts: named here so
    # the list outlives the bands (#263).
    _ = len(ops)
