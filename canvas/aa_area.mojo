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

Each band of rows deposits into an accumulator of its own and resolves
it, in one task: the same core writes the cells and reads them back,
so nothing crosses between caches. Which cells a row's deposits will
reach is found first, by walking every edge over the rows it crosses
(`_row_spans`); that is what sizes the work before any of it is done,
decides the banding, and tells each band which cells to zero. The
tasks read the edge table and the spans read-only and write only their
own rows of the canvas (#97 applies as it does in the sweep).
"""

from std.math import ceil, floor
from std.runtime.asyncrt import TaskGroup, parallelism_level

from canvas.aa_crossing import _EdgeTable, _MIN_PARALLEL_PIXELS
from canvas.buffer import Canvas
from canvas.color import Color


# Cells of work a band takes on at least. Creating a task costs about
# 1.2us and the bands only start once the last one is created, so a
# band with fewer cells than this spends more of its time being
# dispatched than resolving; `_bands_for` divides the work by it before
# capping at the core count. Below `_MIN_PARALLEL_PIXELS` there is one
# band.
comptime _CELLS_PER_BAND = 5000

# A run of at least this many cells nothing was deposited into is
# written as one span through `Canvas._fill_region`; a shorter one is
# not worth the call over `write_pixel`.
comptime _RUN_MIN = 4


struct _RowSpans(Movable):
    """Per row of a region, the first and last accumulator cell the
    deposit will write, found by `_row_spans` before any area is
    deposited. A row no edge crosses has `hi < lo`.

    Known up front, the spans settle three things: how many cells the
    resolve has ahead of it, which decides the banding; which cells
    each band's accumulator zeroes, so the rest stay uninitialised; and
    how far each row's prefix sum walks. Outside a row's span the
    deposits are zero on the left and add up to the row's total, zero
    for a closed shape, on the right, so nothing there would have been
    written.
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


def _bands_for(work: Int, row_count: Int) -> Int:
    """How many row bands to spread `work` cells over: one below
    `_MIN_PARALLEL_PIXELS`, otherwise `_CELLS_PER_BAND` cells each,
    never more than the core count or the row count.
    """
    if work < _MIN_PARALLEL_PIXELS:
        return 1
    var bands = work // _CELLS_PER_BAND
    var cores = parallelism_level()
    if bands > cores:
        bands = cores
    if bands > row_count:
        bands = row_count
    if bands < 1:
        bands = 1
    return bands


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
                    canvas._fill_region(row_first_px + c, py, end - c, 1, run_color)
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
        spans, band_start - region_first_row, band_end - band_start, row_width + 2
    )
    _deposit_all(acc, edges, band_start, band_end, row_first_px)
    _resolve_rows(canvas, acc, spans, band_start, row_first_px, row_width, color)


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
    var row_first_px = min_x - 1
    var row_width = (max_x + 2) - row_first_px
    var first_row = max(min_y - 1, 0)
    var last_row = min(max_y + 2, canvas.height)
    var row_count = last_row - first_row
    if row_count <= 0 or row_width <= 0:
        return

    var spans = _row_spans(edges, first_row, last_row, row_first_px, row_width + 2)
    var bands = _bands_for(spans.cells(), row_count)
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
    # `wait` returned (#263). Naming it here moves its last use past
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
        spans, band_start - region_first_row, band_end - band_start, row_width + 2
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

    var spans = _row_spans(edges, first_row, last_row, row_first_px, row_width + 2)
    var bands = _bands_for(spans.cells(), row_count)
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
