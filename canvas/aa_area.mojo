"""Exact-area anti-aliasing for nonzero fills: the signed-area
accumulation rasterizer that font renderers use (FreeType's smooth
renderer, font-rs, stb_truetype's v2 rasterizer), as the alternative
to `aa_crossing.mojo`'s supersampled sweep.

Each edge deposits, into every pixel it crosses, the signed area it
cuts off (`_deposit_edge`), plus a carry into the pixel to its right
for the rest of the row. A prefix sum along the row then turns the
deposits into each pixel's accumulated winding, a real number whose
magnitude is the pixel's covered fraction: exact where one edge
crosses the pixel, and the sum of the pieces where several do. The
cost is proportional to edge length plus the area swept, not to a
sample count, and the coverage has 256 levels rather than the sweep's
17, which is the difference on a near-horizontal edge or a thin stem.

The accumulated winding is a real number, so `min(1, |w|)` recovers
the nonzero rule -- a self-overlapping outline fills as its union, and
opposite windings cancel -- but not even-odd, which needs the discrete
winding at each sample. `FillRule.EVEN_ODD` therefore stays on the
sweep; `_sweep_edges_aa` and `_sweep_edges_to_mask` dispatch here for
`FillRule.NONZERO`.

Strokes do not come here, although they fill under NONZERO. A stroke
is built as overlapping pieces, a quad per segment and a disk at every
vertex (`_stroke_edges`), and where two pieces overlap inside one edge
pixel their coverages add and clamp rather than union: the disk's
sliver on top of the quad's 0.2 makes 0.26, and along a dense series
the edge saturates and the line reads wider than drawn. The sweep's
per-sample winding test has no such term. Exact-area strokes need a
non-overlapping outline or a per-piece max-merge; until then they take
`_sweep_edges_sampled_aa`. A fill's sub-paths overlap only where the
caller drew them so, and this is the trade every accumulation
rasterizer (FreeType included) makes for glyphs.

Banded across cores above `_MIN_PARALLEL_PIXELS` like the sweep: a
band deposits only into its own rows and writes only those, with the
edge table shared read-only (#97 applies as it does there).
"""

from std.math import ceil, floor
from std.runtime.asyncrt import TaskGroup, parallelism_level

from canvas.aa_crossing import _EdgeTable, _MIN_PARALLEL_PIXELS
from canvas.buffer import Canvas
from canvas.color import Color


def _deposit_edge(
    mut acc: List[Float32],
    acc_width: Int,
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
    var limit = acc_width - 1
    var p = acc.unsafe_ptr()
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
    mut acc: List[Float32],
    acc_width: Int,
    edges: _EdgeTable,
    first_row: Int,
    last_row: Int,
    row_first_px: Int,
):
    """Every edge of `edges` into `acc`, rows [first_row, last_row)."""
    var n = len(edges.y_lo)
    for i in range(n):
        if edges.y_hi[i] <= Float64(first_row):
            continue
        if edges.y_lo[i] >= Float64(last_row):
            continue
        _deposit_edge(
            acc,
            acc_width,
            first_row,
            last_row,
            row_first_px,
            edges.x0[i],
            edges.y0[i],
            edges.dx[i],
            edges.dy[i],
            edges.y_lo[i],
            edges.y_hi[i],
            edges.direction[i],
        )


def _area_band(
    mut canvas: Canvas,
    edges: _EdgeTable,
    first_row: Int,
    last_row: Int,
    row_first_px: Int,
    row_width: Int,
    color: Color,
):
    """Rasterize rows [first_row, last_row) of `edges` onto `canvas`
    with exact-area coverage. Rows are already inside the canvas;
    columns meet the canvas and the rectangle clip per row, as
    `_sweep_band` does, and go through `write_pixel`, or `set_pixel`
    under a clip path.
    """
    var rows = last_row - first_row
    if rows <= 0 or row_width <= 0:
        return
    var acc_width = row_width + 2
    var acc = List[Float32](length=rows * acc_width, fill=0.0)
    _deposit_all(acc, acc_width, edges, first_row, last_row, row_first_px)

    var masked = canvas.has_clip_mask()
    var alpha_scale = Float32(color.a)
    var p = acc.unsafe_ptr()
    for r in range(rows):
        var py = first_row + r
        var region = canvas.effective_fill_rect(row_first_px, py, row_width, 1)
        if region[2] == 0 or region[3] == 0:
            continue
        var lo = region[0] - row_first_px
        var hi = lo + region[2]
        var base = r * acc_width
        # The prefix sum has to start at the row's left edge even when
        # the clip starts further right: the winding there is what the
        # cells before `lo` add up to.
        var winding = Float32(0.0)
        for c in range(lo):
            winding += p[unsafe_offset=base + c]
        for c in range(lo, hi):
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


async def _area_band_async(
    mut canvas: Canvas,
    edges: _EdgeTable,
    first_row: Int,
    last_row: Int,
    row_first_px: Int,
    row_width: Int,
    color: Color,
):
    """`_area_band` as a task; see `_sweep_band_async`."""
    _area_band(
        canvas, edges, first_row, last_row, row_first_px, row_width, color
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
    """`_sweep_edges_aa` for `FillRule.NONZERO`: the same padded
    bounding box and banding, rasterized by area. Rows outside the
    canvas are dropped before any work is done on them; columns are
    kept whole, since a row's prefix sum has to start at the shape's
    left edge.
    """
    var row_first_px = min_x - 1
    var row_width = (max_x + 2) - row_first_px
    var first_row = max(min_y - 1, 0)
    var last_row = min(max_y + 2, canvas.height)
    var row_count = last_row - first_row
    if row_count <= 0 or row_width <= 0:
        return

    var bands = 1
    if row_count * row_width >= _MIN_PARALLEL_PIXELS:
        bands = parallelism_level()
        if bands > row_count:
            bands = row_count
        if bands < 1:
            bands = 1

    if bands == 1:
        _area_band(
            canvas, edges, first_row, last_row, row_first_px, row_width, color
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
                band_start,
                band_end,
                row_first_px,
                row_width,
                color,
            )
        )
    tg.wait()


def _area_mask_band(
    mut mask: List[UInt8],
    mask_width: Int,
    origin_x: Int,
    origin_y: Int,
    edges: _EdgeTable,
    first_row: Int,
    last_row: Int,
    row_first_px: Int,
    row_width: Int,
    full_coverage: Int,
):
    """Write rows [first_row, last_row) of `edges`' exact-area coverage
    into `mask`, `full_coverage` for a fully covered pixel. Rows are
    in canvas coordinates and already inside the mask; columns are
    clipped to it here.
    """
    var rows = last_row - first_row
    if rows <= 0 or row_width <= 0:
        return
    var acc_width = row_width + 2
    var acc = List[Float32](length=rows * acc_width, fill=0.0)
    _deposit_all(acc, acc_width, edges, first_row, last_row, row_first_px)

    var scale = Float32(full_coverage)
    var p = acc.unsafe_ptr()
    for r in range(rows):
        var py = first_row + r
        var row_base = (py - origin_y) * mask_width
        var base = r * acc_width
        var winding = Float32(0.0)
        for c in range(row_width):
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


async def _area_mask_band_async(
    mut mask: List[UInt8],
    mask_width: Int,
    origin_x: Int,
    origin_y: Int,
    edges: _EdgeTable,
    first_row: Int,
    last_row: Int,
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
        first_row,
        last_row,
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
    """`_sweep_edges_to_mask` for `FillRule.NONZERO`: exact-area
    coverage into a mask covering canvas pixels
    [origin_x, origin_x + mask_width) x [origin_y, origin_y +
    mask_height), banded like the canvas version.
    """
    var row_first_px = min_x - 1
    var row_width = (max_x + 2) - row_first_px
    var first_row = max(min_y - 1, origin_y)
    var last_row = min(max_y + 2, origin_y + mask_height)
    var row_count = last_row - first_row
    if row_count <= 0 or row_width <= 0:
        return

    var bands = 1
    if row_count * row_width >= _MIN_PARALLEL_PIXELS:
        bands = parallelism_level()
        if bands > row_count:
            bands = row_count
        if bands < 1:
            bands = 1

    if bands == 1:
        _area_mask_band(
            mask,
            mask_width,
            origin_x,
            origin_y,
            edges,
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
                band_start,
                band_end,
                row_first_px,
                row_width,
                full_coverage,
            )
        )
    tg.wait()
