"""Exact-area anti-aliasing for nonzero fills: the signed-area
accumulation rasterizer that font renderers use (FreeType's smooth
renderer, font-rs, stb_truetype's v2 rasterizer), as the alternative
to `aa_crossing.mojo`'s supersampled sweep.

Each edge deposits, into every pixel it crosses, the signed area it
cuts off (`_deposit_edge`), plus a carry into the pixel to its right
for the rest of the row. Pixel (px, py) is the square
[px - 0.5, px + 0.5] x [py - 0.5, py + 0.5], the convention every
rasterizer in this package shares (the sweep samples at
`px + (g + 0.5) / s - 0.5`); the deposit arithmetic works on
[px, px + 1) cells, so `_deposit_all` shifts each edge by half a pixel
on the way in. A prefix sum along the row then turns the
deposits into each pixel's accumulated winding, a real number whose
magnitude is the pixel's covered fraction: exact where one edge
crosses the pixel, and the sum of the pieces where several do. The
cost is proportional to edge length plus the cells touched, not to a
sample count or to the bounding box: each row of the accumulator
tracks the span its edges deposited into (`_Accumulator`), and only
that span is zeroed and resolved, so a diagonal line across a wide
box costs its own width per row. The coverage has 256 levels rather
than the sweep's 17, which is the difference on a near-horizontal edge
or a thin stem.

The accumulated winding is a real number, so `min(1, |w|)` recovers
the nonzero rule -- a self-overlapping outline fills as its union, and
opposite windings cancel -- but not even-odd, which needs the discrete
winding at each sample. `FillRule.EVEN_ODD` therefore stays on the
sweep; `_sweep_edges_aa` and `_sweep_edges_to_mask` dispatch here for
`FillRule.NONZERO`.

Strokes come here as outlines, when they can be simple ones. Where
two pieces of a shape overlap inside one edge pixel an accumulation
adds their coverages and clamps rather than taking their union, so
the union of pieces the sweep fills a stroke with (a quad per segment,
a disk per joint) over-covers every vertex here: a joint disk's sliver
on top of a quad's 0.2 makes 0.26, and a dense series reads wider than
drawn. `_stroke_edges` builds one simple polygon per drawn run
instead, so there is nothing to add -- and where it cannot (a hairpin
or a reversal, whose bodies overlap each other) the stroke stays on
the sampled sweep. A fill's sub-paths overlap only where the caller
drew them so, and that is the trade every accumulation rasterizer
(FreeType included) makes for glyphs.

The deposit runs once over every row; the resolve is banded across
cores like the sweep when the cells the deposit reached number
`_MIN_PARALLEL_PIXELS` or more, each band writing only its own rows
and reading the accumulator and the edge table read-only (#97 applies
as it does there).
"""

from std.math import ceil, floor
from std.runtime.asyncrt import TaskGroup, parallelism_level

from canvas.aa_crossing import _EdgeTable, _MIN_PARALLEL_PIXELS
from canvas.buffer import Canvas
from canvas.color import Color


# Accumulators at or above this many cells track the span each row's
# deposits reached and zero only that; smaller ones are zeroed whole,
# since the memset of a few kilobytes costs less than the per-deposit
# bookkeeping. Set by benchmark (#251, which has the numbers): a
# glyph-sized fill is unchanged, a diagonal across a full canvas is
# not zeroing and walking its whole box.
comptime _TRACK_SPANS_FROM = 4096


struct _Accumulator(Movable):
    """A band's area accumulator: `rows * width` cells, and per row the
    span of cells anything has been deposited into.

    Above `_TRACK_SPANS_FROM` cells the cells are left uninitialised
    and zeroed only as a row's span grows (`touch`), and the resolve
    walks only the span: for a thin shape across a wide box -- a
    diagonal line, a big outline -- that is a few cells per row rather
    than the box's width. Outside the span every row's prefix sum is
    zero on the left and the row's total, zero for a closed shape, on
    the right, so nothing there would have been written. Below the
    threshold the cells are zeroed up front and every row's span is
    the whole row.
    """

    var cells: List[Float32]
    var width: Int
    var rows: Int
    # Per row, lo at 2r and hi at 2r + 1; empty when not tracking.
    var spans: List[Int]
    var tracking: Bool

    def __init__(out self, rows: Int, width: Int):
        self.width = width
        self.rows = rows
        if rows * width >= _TRACK_SPANS_FROM:
            self.cells = List[Float32](unsafe_uninit_length=rows * width)
            self.spans = List[Int](length=2 * rows, fill=-1)
            for r in range(rows):
                self.spans[2 * r] = width
            self.tracking = True
        else:
            self.cells = List[Float32](length=rows * width, fill=0.0)
            self.spans = List[Int]()
            self.tracking = False

    @always_inline
    def span_lo(self, row: Int) -> Int:
        return self.spans[2 * row] if self.tracking else 0

    @always_inline
    def span_hi(self, row: Int) -> Int:
        return self.spans[2 * row + 1] if self.tracking else self.width - 1

    @always_inline
    def touch(mut self, row: Int, c0: Int, c1: Int):
        """Make cells `c0` through `c1` of `row` part of its span,
        zeroing the ones that were not. A no-op when not tracking.
        """
        if not self.tracking:
            return
        var lo = self.spans[2 * row]
        var hi = self.spans[2 * row + 1]
        var p = self.cells.unsafe_ptr()
        var base = row * self.width
        if hi < lo:
            for c in range(c0, c1 + 1):
                p[unsafe_offset=base + c] = 0.0
            self.spans[2 * row] = c0
            self.spans[2 * row + 1] = c1
            return
        if c0 < lo:
            for c in range(c0, lo):
                p[unsafe_offset=base + c] = 0.0
            self.spans[2 * row] = c0
        if c1 > hi:
            for c in range(hi + 1, c1 + 1):
                p[unsafe_offset=base + c] = 0.0
            self.spans[2 * row + 1] = c1


def _deposit_edge(
    mut acc: _Accumulator,
    first_row: Int,
    last_row: Int,
    row_first_px: Int,
    x0: Float64,
    y0: Float64,
    dx: Float64,
    dy: Float64,
    y_lo: Float64,
    y_hi: Float64,
    direction: Int,
):
    """Deposit one edge's signed area into `acc` for the rows it
    crosses within [first_row, last_row). `acc` holds
    `(last_row - first_row) * acc_width` cells, column c standing for
    pixel `row_first_px + c`.

    Per row, the edge's segment inside that row runs from x_top to
    x_bottom over a height `dy_row`; its winding contribution is
    `d = dy_row * direction`. The area formulas are the standard ones:
    a segment inside one pixel column leaves `d * (1 - mid)` in that
    pixel, where `mid` is the segment's mean x within the pixel, and
    carries `d * mid` to the next; a segment spanning several columns
    leaves the triangle it cuts from the first, the trapezoids from the
    middle ones, and the remainder from the last, with the carry after
    it. Each row's deposits sum to `d`, which is what makes the prefix
    sum along the row come out right.
    """
    var dxdy = dx / dy
    var r_start = max(Int(floor(y_lo)), first_row)
    var r_end = min(Int(ceil(y_hi)), last_row)
    var acc_width = acc.width
    var limit = acc_width - 1
    var p = acc.cells.unsafe_ptr()
    for r in range(r_start, r_end):
        var y_top = max(Float64(r), y_lo)
        var y_bot = min(Float64(r + 1), y_hi)
        var dy_row = y_bot - y_top
        if dy_row <= 0.0:
            continue
        var xa = x0 + (y_top - y0) * dxdy - Float64(row_first_px)
        var xb = x0 + (y_bot - y0) * dxdy - Float64(row_first_px)
        var d = Float32(dy_row * Float64(direction))
        var xl = min(xa, xb)
        var xr = max(xa, xb)
        var base = (r - first_row) * acc_width
        var xl_floor = floor(xl)
        var c0 = Int(xl_floor)
        var c1 = Int(ceil(xr))
        if c0 < 0:
            c0 = 0
        if c1 > limit:
            c1 = limit
        # Every cell the two branches below write lies in this span.
        acc.touch(r - first_row, c0, min(max(c1, c0 + 1), limit))
        if c1 <= c0 + 1:
            # Inside one column (or exactly on its right border).
            var mid = Float32(0.5 * (xa + xb) - xl_floor)
            p[unsafe_offset=base + c0] += d - d * mid
            p[unsafe_offset=base + min(c0 + 1, limit)] += d * mid
        else:
            var s = Float32(1.0 / (xr - xl))
            var xlf = Float32(xl - xl_floor)
            var a0 = 0.5 * s * (1.0 - xlf) * (1.0 - xlf)
            var xrf = Float32(xr - Float64(c1) + 1.0)
            var am = 0.5 * s * xrf * xrf
            p[unsafe_offset=base + c0] += d * a0
            if c1 == c0 + 2:
                p[unsafe_offset=base + c0 + 1] += d * (1.0 - a0 - am)
            else:
                var a1 = s * (1.5 - xlf)
                p[unsafe_offset=base + c0 + 1] += d * (a1 - a0)
                for c in range(c0 + 2, c1 - 1):
                    p[unsafe_offset=base + c] += d * s
                var a2 = a1 + Float32(c1 - c0 - 3) * s
                p[unsafe_offset=base + c1 - 1] += d * (1.0 - a2 - am)
            p[unsafe_offset=base + min(c1, limit)] += d * am


def _deposit_all(
    mut acc: _Accumulator,
    edges: _EdgeTable,
    first_row: Int,
    last_row: Int,
    row_first_px: Int,
):
    """Every edge of `edges` into `acc`, rows [first_row, last_row).

    The half-pixel shift is what puts the edges in cell coordinates:
    pixel py's square starts at py - 0.5 in the path's space, which is
    cell row py's start once 0.5 is added; likewise for columns.
    """
    var n = len(edges.y_lo)
    for i in range(n):
        var y_lo = edges.y_lo[i] + 0.5
        var y_hi = edges.y_hi[i] + 0.5
        if y_hi <= Float64(first_row):
            continue
        if y_lo >= Float64(last_row):
            continue
        _deposit_edge(
            acc,
            first_row,
            last_row,
            row_first_px,
            edges.x0[i] + 0.5,
            edges.y0[i] + 0.5,
            edges.dx[i],
            edges.dy[i],
            y_lo,
            y_hi,
            edges.direction[i],
        )


def _touched_cells(acc: _Accumulator) -> Int:
    """How many cells the deposits reached, summed over rows: the work
    the resolve has ahead of it, and what decides whether it is worth
    banding across cores.
    """
    if not acc.tracking:
        return acc.rows * acc.width
    var total = 0
    for r in range(acc.rows):
        var span = acc.span_hi(r) - acc.span_lo(r) + 1
        if span > 0:
            total += span
    return total


def _bands_for(work: Int, row_count: Int) -> Int:
    """How many row bands to resolve `work` cells over: one below
    `_MIN_PARALLEL_PIXELS`, otherwise the core count, never more than
    there are rows.
    """
    if work < _MIN_PARALLEL_PIXELS:
        return 1
    var bands = parallelism_level()
    if bands > row_count:
        bands = row_count
    if bands < 1:
        bands = 1
    return bands


def _resolve_rows(
    mut canvas: Canvas,
    acc: _Accumulator,
    first_row: Int,
    band_start: Int,
    band_end: Int,
    row_first_px: Int,
    row_width: Int,
    color: Color,
):
    """Write rows [band_start, band_end) of `acc`, whose row 0 is
    canvas row `first_row`, onto `canvas` as exact-area coverage. Rows
    are already inside the canvas; columns meet the canvas and the
    rectangle clip per row, as `_sweep_band` does, and go through
    `write_pixel`, or `set_pixel` under a clip path.
    """
    var masked = canvas.has_clip_mask()
    var alpha_scale = Float32(color.a)
    var acc_width = acc.width
    var p = acc.cells.unsafe_ptr()
    for py in range(band_start, band_end):
        var r = py - first_row
        var span_lo = acc.span_lo(r)
        var span_hi = acc.span_hi(r)
        if span_hi < span_lo:
            continue
        var region = canvas.effective_fill_rect(row_first_px, py, row_width, 1)
        if region[2] == 0 or region[3] == 0:
            continue
        var lo = region[0] - row_first_px
        var hi = min(lo + region[2], span_hi + 1)
        var base = r * acc_width
        # The prefix sum starts at the span's first cell, which is the
        # first non-zero one, even when the clip starts further right:
        # the winding there is what the cells before `lo` add up to.
        var winding = Float32(0.0)
        for c in range(span_lo, min(lo, hi)):
            winding += p[unsafe_offset=base + c]
        for c in range(max(lo, span_lo), hi):
            winding += p[unsafe_offset=base + c]
            var cov = abs(winding)
            if cov > 1.0:
                cov = 1.0
            var alpha = Int(cov * alpha_scale + 0.5)
            if alpha == 0:
                continue
            var px = row_first_px + c
            if masked:
                canvas.set_pixel(px, py, color.with_alpha(UInt8(alpha)))
            else:
                canvas.write_pixel(px, py, color.with_alpha(UInt8(alpha)))


async def _resolve_rows_async(
    mut canvas: Canvas,
    acc: _Accumulator,
    first_row: Int,
    band_start: Int,
    band_end: Int,
    row_first_px: Int,
    row_width: Int,
    color: Color,
):
    """`_resolve_rows` as a task; see `_sweep_band_async`."""
    _resolve_rows(
        canvas,
        acc,
        first_row,
        band_start,
        band_end,
        row_first_px,
        row_width,
        color,
    )


def _area_edges_aa(
    mut canvas: Canvas,
    edges: _EdgeTable,
    min_x: Int,
    min_y: Int,
    max_x: Int,
    max_y: Int,
    color: Color,
):
    """`_sweep_edges_aa` for `FillRule.NONZERO`, rasterized by area.
    Rows outside the canvas are dropped before any work is done on
    them; columns are kept whole, since a row's prefix sum has to
    start at the shape's left edge.

    The deposit runs once, over every row; only then is the work
    known, as the cells the edges reached, and the resolve is banded
    across cores when that reaches `_MIN_PARALLEL_PIXELS`. Deciding on
    the bounding box instead fanned a thin diagonal out over every
    core for a few thousand cells of work, and each band rescanned the
    whole edge table.
    """
    var row_first_px = min_x - 1
    var row_width = (max_x + 2) - row_first_px
    var first_row = max(min_y - 1, 0)
    var last_row = min(max_y + 2, canvas.height)
    var row_count = last_row - first_row
    if row_count <= 0 or row_width <= 0:
        return

    var acc = _Accumulator(row_count, row_width + 2)
    _deposit_all(acc, edges, first_row, last_row, row_first_px)

    var bands = _bands_for(_touched_cells(acc), row_count)
    if bands == 1:
        _resolve_rows(
            canvas,
            acc,
            first_row,
            first_row,
            last_row,
            row_first_px,
            row_width,
            color,
        )
        return

    var per_band = (row_count + bands - 1) // bands
    var tg = TaskGroup()
    for b in range(bands):
        var band_start = first_row + b * per_band
        var band_end = band_start + per_band
        if band_end > last_row:
            band_end = last_row
        if band_start >= band_end:
            continue
        tg.create_task(
            _resolve_rows_async(
                canvas,
                acc,
                first_row,
                band_start,
                band_end,
                row_first_px,
                row_width,
                color,
            )
        )
    tg.wait()


def _resolve_mask_rows(
    mut mask: List[UInt8],
    mask_width: Int,
    origin_x: Int,
    origin_y: Int,
    acc: _Accumulator,
    first_row: Int,
    band_start: Int,
    band_end: Int,
    row_first_px: Int,
    row_width: Int,
    full_coverage: Int,
):
    """Write rows [band_start, band_end) of `acc`, whose row 0 is
    canvas row `first_row`, into `mask`, `full_coverage` for a fully
    covered pixel. Rows are in canvas coordinates and already inside
    the mask; columns are clipped to it here.
    """
    var scale = Float32(full_coverage)
    var acc_width = acc.width
    var p = acc.cells.unsafe_ptr()
    for py in range(band_start, band_end):
        var r = py - first_row
        var span_lo = acc.span_lo(r)
        var span_hi = acc.span_hi(r)
        if span_hi < span_lo:
            continue
        var row_base = (py - origin_y) * mask_width
        var base = r * acc_width
        var winding = Float32(0.0)
        for c in range(span_lo, min(span_hi + 1, row_width)):
            winding += p[unsafe_offset=base + c]
            var cov = abs(winding)
            if cov > 1.0:
                cov = 1.0
            var value = Int(cov * scale + 0.5)
            if value == 0:
                continue
            var mx = row_first_px + c - origin_x
            if mx < 0 or mx >= mask_width:
                continue
            mask[row_base + mx] = UInt8(value)


async def _resolve_mask_rows_async(
    mut mask: List[UInt8],
    mask_width: Int,
    origin_x: Int,
    origin_y: Int,
    acc: _Accumulator,
    first_row: Int,
    band_start: Int,
    band_end: Int,
    row_first_px: Int,
    row_width: Int,
    full_coverage: Int,
):
    """`_resolve_mask_rows` as a task; see `_sweep_band_async`."""
    _resolve_mask_rows(
        mask,
        mask_width,
        origin_x,
        origin_y,
        acc,
        first_row,
        band_start,
        band_end,
        row_first_px,
        row_width,
        full_coverage,
    )


def _area_edges_to_mask(
    mut mask: List[UInt8],
    mask_width: Int,
    mask_height: Int,
    origin_x: Int,
    origin_y: Int,
    edges: _EdgeTable,
    min_x: Int,
    min_y: Int,
    max_x: Int,
    max_y: Int,
    full_coverage: Int,
):
    """`_area_edges_aa` writing coverage into a mask instead of
    blending onto a canvas: the same one-pass deposit, and the same
    banding of the resolve by the cells the edges reached.
    """
    var row_first_px = min_x - 1
    var row_width = (max_x + 2) - row_first_px
    var first_row = max(min_y - 1, origin_y)
    var last_row = min(max_y + 2, origin_y + mask_height)
    var row_count = last_row - first_row
    if row_count <= 0 or row_width <= 0:
        return

    var acc = _Accumulator(row_count, row_width + 2)
    _deposit_all(acc, edges, first_row, last_row, row_first_px)

    var bands = _bands_for(_touched_cells(acc), row_count)
    if bands == 1:
        _resolve_mask_rows(
            mask,
            mask_width,
            origin_x,
            origin_y,
            acc,
            first_row,
            first_row,
            last_row,
            row_first_px,
            row_width,
            full_coverage,
        )
        return

    var per_band = (row_count + bands - 1) // bands
    var tg = TaskGroup()
    for b in range(bands):
        var band_start = first_row + b * per_band
        var band_end = band_start + per_band
        if band_end > last_row:
            band_end = last_row
        if band_start >= band_end:
            continue
        tg.create_task(
            _resolve_mask_rows_async(
                mask,
                mask_width,
                origin_x,
                origin_y,
                acc,
                first_row,
                band_start,
                band_end,
                row_first_px,
                row_width,
                full_coverage,
            )
        )
    tg.wait()
