"""Signed-area anti-aliasing for nonzero path and stroke fills.

Pixel `(px, py)` spans `[px - 0.5, px + 0.5]` on each axis. Each edge
deposits signed coverage into the cells it crosses; a row prefix sum
converts those deposits to coverage. Even-odd fills use the sampled
sweep in `aa_crossing.mojo` instead.
"""

from std.math import ceil, floor
from std.runtime.asyncrt import TaskGroup

from canvas.aa_crossing import _EdgeTable, _MIN_PARALLEL_PIXELS
from canvas.workers import _bands_for_work
from canvas.buffer import Canvas
from canvas.color import Color


# Minimum accumulator cells assigned to each band.
comptime _CELLS_PER_BAND = 5000

# Minimum empty-cell run written through `Canvas._fill_region`.
comptime _RUN_MIN = 4


struct _RowSpans(Movable):
    """First and last accumulator cell touched in each row.

    A row no edge crosses has `hi < lo`.
    """

    var lo: List[Int]
    var hi: List[Int]

    def __init__(out self, rows: Int, width: Int):
        self.lo = List[Int](length=rows, fill=width)
        self.hi = List[Int](length=rows, fill=-1)

    def cells(self) -> Int:
        """Cells across every row's span: the resolve's work."""
        var total = 0
        for r in range(len(self.lo)):
            var span = self.hi[r] - self.lo[r] + 1
            if span > 0:
                total += span
        return total


@always_inline
def _edge_row_columns(xa: Float64, xb: Float64, limit: Int) -> Tuple[Int, Int]:
    """The first and last accumulator column the segment of an edge
    running from x `xa` to `xb` inside one row deposits into, as
    (c0, c1) clamped to `[0, limit]`: `_deposit_edge` writes cells
    `c0` through `min(max(c1, c0 + 1), limit)` and nothing else, and
    `_row_spans` widens the row's span by exactly that.
    """
    var c0 = Int(floor(min(xa, xb)))
    var c1 = Int(ceil(max(xa, xb)))
    if c0 < 0:
        c0 = 0
    if c1 > limit:
        c1 = limit
    return (c0, c1)


def _row_spans(
    edges: _EdgeTable,
    first_row: Int,
    last_row: Int,
    row_first_px: Int,
    acc_width: Int,
) -> _RowSpans:
    """The span of cells each row's deposits will reach, for rows
    [first_row, last_row): the walk `_deposit_edge` makes over every
    edge's rows, keeping only the columns it lands in. The half-pixel
    shift and the clamps are the ones `_deposit_all` and
    `_deposit_edge` apply, so the spans are exact.
    """
    var spans = _RowSpans(last_row - first_row, acc_width)
    var lo = spans.lo.unsafe_ptr()
    var hi = spans.hi.unsafe_ptr()
    var limit = acc_width - 1
    var n = len(edges.y_lo)
    for i in range(n):
        var y_lo = edges.y_lo[i] + 0.5
        var y_hi = edges.y_hi[i] + 0.5
        if y_hi <= Float64(first_row) or y_lo >= Float64(last_row):
            continue
        var x0 = edges.x0[i] + 0.5 - Float64(row_first_px)
        var y0 = edges.y0[i] + 0.5
        var dxdy = edges.dx[i] / edges.dy[i]
        var r_start = max(Int(floor(y_lo)), first_row)
        var r_end = min(Int(ceil(y_hi)), last_row)
        for r in range(r_start, r_end):
            var y_top = max(Float64(r), y_lo)
            var y_bot = min(Float64(r + 1), y_hi)
            if y_bot - y_top <= 0.0:
                continue
            var xa = x0 + (y_top - y0) * dxdy
            var xb = x0 + (y_bot - y0) * dxdy
            var cols = _edge_row_columns(xa, xb, limit)
            var c0 = cols[0]
            var c1 = min(max(cols[1], c0 + 1), limit)
            var row = r - first_row
            if c0 < lo[unsafe_offset=row]:
                lo[unsafe_offset=row] = c0
            if c1 > hi[unsafe_offset=row]:
                hi[unsafe_offset=row] = c1
    return spans^


struct _Accumulator(Movable):
    """A band's area accumulator: `rows * width` cells, row 0 standing
    for row `first` of the region's `_RowSpans`. Only the cells inside
    each row's span are zeroed; the rest are never written or read.
    """

    var cells: List[Float32]
    var width: Int
    var rows: Int
    var first: Int

    def __init__(out self, spans: _RowSpans, first: Int, rows: Int, width: Int):
        self.width = width
        self.rows = rows
        self.first = first
        self.cells = List[Float32](unsafe_uninit_length=rows * width)
        var p = self.cells.unsafe_ptr()
        for r in range(rows):
            var lo = spans.lo[first + r]
            var hi = spans.hi[first + r]
            var base = r * width
            for c in range(lo, hi + 1):
                p[unsafe_offset=base + c] = 0.0


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
    sum along the row come out right. Every cell written lies in the
    span `_row_spans` found for the row, which is what zeroed it.
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
        var cols = _edge_row_columns(xa, xb, limit)
        var c0 = cols[0]
        var c1 = cols[1]
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


def _bands_for(work: Int, row_count: Int, max_workers: Int = 0) -> Int:
    """How many row bands to spread `work` cells over: one below
    `_MIN_PARALLEL_WORK`, otherwise `_CELLS_PER_BAND` cells each,
    never more than the caller's worker cap or the row count.
    """
    return _bands_for_work(work, row_count, _CELLS_PER_BAND, max_workers)


@always_inline
def _run_end(cells: List[Float32], base: Int, c: Int, hi: Int) -> Int:
    """The cell after the run starting at `c`: cell `c` and every
    following cell before `hi` that nothing was deposited into. Such a
    cell leaves the prefix sum where it is, so the whole run has cell
    `c`'s coverage.
    """
    var p = cells.unsafe_ptr()
    var end = c + 1
    while end < hi and p[unsafe_offset=base + end] == 0.0:
        end += 1
    return end


def _resolve_rows(
    mut canvas: Canvas,
    acc: _Accumulator,
    spans: _RowSpans,
    first_row: Int,
    row_first_px: Int,
    row_width: Int,
    color: Color,
):
    """Write `acc`, whose row 0 is canvas row `first_row`, onto
    `canvas` as exact-area coverage. Rows are already inside the
    canvas; columns meet the canvas and the rectangle clip per row, as
    `_sweep_band` does. A run of cells with one coverage -- the inside
    of a shape, where nothing was deposited -- goes to
    `Canvas._fill_region` as a span when it is `_RUN_MIN` or longer;
    the rest go through `write_pixel`, or `set_pixel` under a clip
    path.
    """
    var masked = canvas.has_clip_mask()
    var alpha_scale = Float32(color.a)
    var acc_width = acc.width
    var p = acc.cells.unsafe_ptr()
    for r in range(acc.rows):
        var py = first_row + r
        var span_lo = spans.lo[acc.first + r]
        var span_hi = spans.hi[acc.first + r]
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
        var c = max(lo, span_lo)
        while c < hi:
            winding += p[unsafe_offset=base + c]
            var end = _run_end(acc.cells, base, c, hi)
            var cov = abs(winding)
            if cov > 1.0:
                cov = 1.0
            var alpha = Int(cov * alpha_scale + 0.5)
            if alpha != 0:
                var run_color = color.with_alpha(UInt8(alpha))
                if end - c >= _RUN_MIN:
                    canvas._fill_region(
                        row_first_px + c, py, end - c, 1, run_color
                    )
                elif masked:
                    for k in range(c, end):
                        canvas.set_pixel(row_first_px + k, py, run_color)
                else:
                    for k in range(c, end):
                        canvas.write_pixel(row_first_px + k, py, run_color)
            c = end


def _area_band(
    mut canvas: Canvas,
    edges: _EdgeTable,
    spans: _RowSpans,
    region_first_row: Int,
    band_start: Int,
    band_end: Int,
    row_first_px: Int,
    row_width: Int,
    color: Color,
):
    """Rows [band_start, band_end) of a region whose first row is
    `region_first_row`: an accumulator of the band's own, the deposit
    of every edge reaching it, and the resolve onto `canvas`.
    """
    var acc = _Accumulator(
        spans,
        band_start - region_first_row,
        band_end - band_start,
        row_width + 2,
    )
    _deposit_all(acc, edges, band_start, band_end, row_first_px)
    _resolve_rows(
        canvas, acc, spans, band_start, row_first_px, row_width, color
    )


async def _area_band_async(
    mut canvas: Canvas,
    edges: _EdgeTable,
    spans: _RowSpans,
    region_first_row: Int,
    band_start: Int,
    band_end: Int,
    row_first_px: Int,
    row_width: Int,
    color: Color,
):
    """`_area_band` as a task; see `_sweep_band_async`."""
    _area_band(
        canvas,
        edges,
        spans,
        region_first_row,
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
    clamp_lo: Int = 0,
    clamp_hi: Int = -1,
):
    """`_sweep_edges_aa` for `FillRule.NONZERO`, rasterized by area.
    Rows outside the canvas are dropped before any work is done on
    them; columns are kept whole, since a row's prefix sum has to
    start at the shape's left edge.

    The spans are found first, over every row, and the cells they add
    up to decide the banding; each band then deposits and resolves its
    own rows (`_area_band`). Deciding on the bounding box instead
    fanned a thin diagonal out over every core for a few thousand
    cells of work.
    """
    # `clamp_lo`/`clamp_hi` bound the rows written, past the outward
    # padding above. A batch that bands the canvas needs that: the
    # padding would otherwise carry a shape one row below and two
    # above its band, so two bands would write the same pixels and a
    # translucent marker would be composited twice. Defaults leave the
    # whole canvas, which is every existing caller.
    #
    # Safe because the area sweep carries no state between rows: each
    # row's winding prefix sum starts at zero at the shape's left
    # edge, so the rows written are the same whether the sweep is
    # given all of them or a slice.
    var hi_bound = canvas.height if clamp_hi < 0 else min(
        clamp_hi, canvas.height
    )
    var row_first_px = min_x - 1
    var row_width = (max_x + 2) - row_first_px
    var first_row = max(max(min_y - 1, 0), clamp_lo)
    var last_row = min(min(max_y + 2, canvas.height), hi_bound)
    var row_count = last_row - first_row
    if row_count <= 0 or row_width <= 0:
        return

    var spans = _row_spans(
        edges, first_row, last_row, row_first_px, row_width + 2
    )
    var bands = _bands_for(spans.cells(), row_count, canvas.max_workers())
    if bands == 1:
        _area_band(
            canvas,
            edges,
            spans,
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
            _area_band_async(
                canvas,
                edges,
                spans,
                first_row,
                band_start,
                band_end,
                row_first_px,
                row_width,
                color,
            )
        )
    tg.wait()
    # Mojo destroys a value right after its last use, and the tasks
    # borrow `spans` without the compiler counting that as one: named
    # for the last time inside the loop, it would be freed before
    # `wait` returned. Naming it here moves its last use past
    # the tasks.
    _ = len(spans.lo)


def _resolve_mask_rows(
    mut mask: List[UInt8],
    mask_width: Int,
    origin_x: Int,
    origin_y: Int,
    acc: _Accumulator,
    spans: _RowSpans,
    first_row: Int,
    row_first_px: Int,
    row_width: Int,
    full_coverage: Int,
):
    """Write `acc`, whose row 0 is canvas row `first_row`, into
    `mask`, `full_coverage` for a fully covered pixel. Rows are in
    canvas coordinates and already inside the mask; columns are
    clipped to it here. Runs of one coverage are written as such, as
    `_resolve_rows` does.
    """
    var scale = Float32(full_coverage)
    var acc_width = acc.width
    var p = acc.cells.unsafe_ptr()
    var mp = mask.unsafe_ptr()
    for r in range(acc.rows):
        var py = first_row + r
        var span_lo = spans.lo[acc.first + r]
        var span_hi = spans.hi[acc.first + r]
        if span_hi < span_lo:
            continue
        var row_base = (py - origin_y) * mask_width
        var base = r * acc_width
        var hi = min(span_hi + 1, row_width)
        var winding = Float32(0.0)
        var c = span_lo
        while c < hi:
            winding += p[unsafe_offset=base + c]
            var end = _run_end(acc.cells, base, c, hi)
            var cov = abs(winding)
            if cov > 1.0:
                cov = 1.0
            var value = Int(cov * scale + 0.5)
            if value != 0:
                var mx0 = max(row_first_px + c - origin_x, 0)
                var mx1 = min(row_first_px + end - origin_x, mask_width)
                for mx in range(mx0, mx1):
                    mp[unsafe_offset=row_base + mx] = UInt8(value)
            c = end


def _area_mask_band(
    mut mask: List[UInt8],
    mask_width: Int,
    origin_x: Int,
    origin_y: Int,
    edges: _EdgeTable,
    spans: _RowSpans,
    region_first_row: Int,
    band_start: Int,
    band_end: Int,
    row_first_px: Int,
    row_width: Int,
    full_coverage: Int,
):
    """`_area_band` writing into a mask."""
    var acc = _Accumulator(
        spans,
        band_start - region_first_row,
        band_end - band_start,
        row_width + 2,
    )
    _deposit_all(acc, edges, band_start, band_end, row_first_px)
    _resolve_mask_rows(
        mask,
        mask_width,
        origin_x,
        origin_y,
        acc,
        spans,
        band_start,
        row_first_px,
        row_width,
        full_coverage,
    )


async def _area_mask_band_async(
    mut mask: List[UInt8],
    mask_width: Int,
    origin_x: Int,
    origin_y: Int,
    edges: _EdgeTable,
    spans: _RowSpans,
    region_first_row: Int,
    band_start: Int,
    band_end: Int,
    row_first_px: Int,
    row_width: Int,
    full_coverage: Int,
):
    """`_area_mask_band` as a task; see `_sweep_band_async`."""
    _area_mask_band(
        mask,
        mask_width,
        origin_x,
        origin_y,
        edges,
        spans,
        region_first_row,
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
    max_workers: Int = 0,
):
    """`_area_edges_aa` writing coverage into a mask instead of
    blending onto a canvas: the same spans first, and the same banding
    of the deposit and resolve by the cells they add up to.
    """
    var row_first_px = min_x - 1
    var row_width = (max_x + 2) - row_first_px
    var first_row = max(min_y - 1, origin_y)
    var last_row = min(max_y + 2, origin_y + mask_height)
    var row_count = last_row - first_row
    if row_count <= 0 or row_width <= 0:
        return

    var spans = _row_spans(
        edges, first_row, last_row, row_first_px, row_width + 2
    )
    var bands = _bands_for(spans.cells(), row_count, max_workers)
    if bands == 1:
        _area_mask_band(
            mask,
            mask_width,
            origin_x,
            origin_y,
            edges,
            spans,
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
            _area_mask_band_async(
                mask,
                mask_width,
                origin_x,
                origin_y,
                edges,
                spans,
                first_row,
                band_start,
                band_end,
                row_first_px,
                row_width,
                full_coverage,
            )
        )
    tg.wait()
    _ = len(spans.lo)  # last use past the tasks; see `_area_edges_aa`


def _rect_coverage_to_mask(
    mut mask: List[UInt8],
    mask_width: Int,
    mask_height: Int,
    origin_x: Int,
    origin_y: Int,
    x0: Float64,
    y0: Float64,
    x1: Float64,
    y1: Float64,
    full_coverage: Int,
):
    """Coverage of the axis-aligned rectangle `[x0, x1] x [y0, y1]`,
    written straight into `mask` without an edge sweep.

    A rectangle's coverage separates: a pixel's covered area is its
    overlap on x times its overlap on y, so the x overlaps are computed
    once for the row and every row reuses them. Only the two columns
    the vertical edges cut through are partial, so a row is two pixels
    and a run of one value -- which is what makes this closed form
    rather than a sweep over the interior.

    Pixel `(px, py)` spans `[px - 0.5, px + 0.5]`, this module's
    convention, and coverage rounds exactly as `_resolve_to_mask` does
    so a rectangle clip lands where the sweep would put it.

    `mask` is `mask_width * mask_height` bytes covering canvas pixels
    from (`origin_x`, `origin_y`), already zeroed; pixels the rectangle
    misses keep their zero.
    """
    if x1 <= x0 or y1 <= y0:
        return

    # Columns with any overlap: px + 0.5 > x0 and px - 0.5 < x1.
    var col_lo = max(Int(floor(x0 + 0.5)), origin_x)
    var col_hi = min(Int(ceil(x1 + 0.5)), origin_x + mask_width)
    if col_hi <= col_lo:
        return

    # The run whose columns lie wholly inside: px - 0.5 >= x0 and
    # px + 0.5 <= x1.
    var run_lo = max(Int(ceil(x0 + 0.5)), col_lo)
    var run_hi = min(Int(floor(x1 - 0.5)) + 1, col_hi)
    if run_hi < run_lo:
        run_hi = run_lo

    var scale = Float32(full_coverage)
    var mp = mask.unsafe_ptr()

    var row_lo = max(Int(floor(y0 + 0.5)), origin_y)
    var row_hi = min(Int(ceil(y1 + 0.5)), origin_y + mask_height)

    for py in range(row_lo, row_hi):
        var top = max(y0, Float64(py) - 0.5)
        var bottom = min(y1, Float64(py) + 0.5)
        var yov = bottom - top
        if yov <= 0.0:
            continue
        if yov > 1.0:
            yov = 1.0
        var yf = Float32(yov)
        var row_base = (py - origin_y) * mask_width

        for px in range(col_lo, run_lo):
            var left = max(x0, Float64(px) - 0.5)
            var right = min(x1, Float64(px) + 0.5)
            var xov = right - left
            if xov <= 0.0:
                continue
            var cov = Float32(xov) * yf
            if cov > 1.0:
                cov = 1.0
            var value = Int(cov * scale + 0.5)
            if value != 0:
                mp[unsafe_offset=row_base + px - origin_x] = UInt8(value)

        if run_hi > run_lo:
            var full = Int(yf * scale + 0.5)
            if full != 0:
                var v = UInt8(full)
                for px in range(run_lo, run_hi):
                    mp[unsafe_offset=row_base + px - origin_x] = v

        for px in range(run_hi, col_hi):
            var left = max(x0, Float64(px) - 0.5)
            var right = min(x1, Float64(px) + 0.5)
            var xov = right - left
            if xov <= 0.0:
                continue
            var cov = Float32(xov) * yf
            if cov > 1.0:
                cov = 1.0
            var value = Int(cov * scale + 0.5)
            if value != 0:
                mp[unsafe_offset=row_base + px - origin_x] = UInt8(value)
