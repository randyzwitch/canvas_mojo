"""The anti-aliased scanline sweep and its parts: `_AACrossing` (one
sub-scanline crossing at a real-valued x, kept `Float64` since an AA
sweep places a crossing between two supersample columns rather than two
whole pixels), the insertion sort that orders a sub-scanline's
crossings, the `_EdgeTable` they are read out of, and `_sweep_edges_aa`
-- the coverage sweep `fill_path_aa` and `fill_polygon_aa` both run over
whatever edges their caller hands in.

The two fills differ only in how they describe their geometry: one walks
sub-paths, the other a single point ring. Everything after that is
identical.

This is a near-leaf module, which is what lets both callers share it:
`path.mojo` already imports drawing primitives *from* `polygon_fill`, so
shared code has to live where neither imports. Nothing here imports
either of them -- `_is_inside` comes from `fill_rule.mojo`, which
imports nothing -- leaving the DAG polygon_fill -> aa_crossing,
path -> aa_crossing, path -> polygon_fill.

The sort is insertion sort: a sub-scanline's crossing count is a handful,
not the whole shape's point count.

A sub-scanline's crossings come from an active list rather than a scan
of every edge: `_EdgeTable.sort_by_top` orders the edges by where they
begin, and `crossings_at` admits and retires them as a band walks
downward, so each sub-scanline touches only the edges near it.
"""

from std.math import ceil, floor
from std.runtime.asyncrt import TaskGroup, parallelism_level

from canvas.buffer import Canvas
from canvas.color import Color
from canvas.fill_rule import FillRule, _is_inside


struct _AACrossing(Comparable, ImplicitlyCopyable, Movable):
    var x: Float64
    var direction: Int

    def __init__(out self, x: Float64, direction: Int):
        self.x = x
        self.direction = direction

    def __lt__(self, other: Self) -> Bool:
        return self.x < other.x

    def __le__(self, other: Self) -> Bool:
        return self.x <= other.x

    def __gt__(self, other: Self) -> Bool:
        return self.x > other.x

    def __ge__(self, other: Self) -> Bool:
        return self.x >= other.x

    def __eq__(self, other: Self) -> Bool:
        return self.x == other.x

    def __ne__(self, other: Self) -> Bool:
        return self.x != other.x


# Above this many crossings on one sub-scanline, `_sort_aa_crossings_by_x`
# hands an *unordered* list to the library sort instead of insertion
# sort. A glyph's sub-scanline has a handful of crossings, where
# insertion sort's setup-free loop wins either way. Crossings from a
# scan of the edge table arrive in edge order, which for a stroked
# series is nearly x order already, and insertion sort finishes that
# in linear time; crossings from the active list arrive in admission
# order, where insertion sort goes quadratic.
comptime _INSERTION_SORT_LIMIT = 16


def _sort_aa_crossings_by_x(mut crossings: List[_AACrossing], unordered: Bool):
    if unordered and len(crossings) > _INSERTION_SORT_LIMIT:
        sort(crossings)
        return
    for i in range(1, len(crossings)):
        var key = crossings[i]
        var j = i - 1
        while j >= 0 and crossings[j].x > key.x:
            crossings[j + 1] = crossings[j]
            j -= 1
        crossings[j + 1] = key


def _sample_x(x0: Float64, g: Int, s: Int) -> Float64:
    """The x of sub-sample `g`, counting across a whole row rather than
    per pixel: `x0` is the row's left edge and samples sit at the
    centers of `s` equal slices of each pixel. Identical to the
    per-pixel `px + (sx + 0.5)/s - 0.5`, re-indexed so a run of samples
    is a contiguous integer range -- which is what lets `fill_path_aa`
    and `fill_polygon_aa` count an inside run instead of testing each
    position in it.
    """
    return x0 + (Float64(g) + 0.5) / Float64(s)


struct _EdgeTable(Movable):
    """Every non-horizontal edge of a shape, as flat arrays, plus
    `order`, the edge indices by ascending `y_lo` once `sort_by_top`
    has run. The order lives on the table rather than travelling as a
    separate argument because the table is what the sweep's band tasks
    already receive; a List of its own handed to `create_task` is the
    #97 failure.
    """

    var y_lo: List[Float64]
    var y_hi: List[Float64]
    var x0: List[Float64]
    var y0: List[Float64]
    var dx: List[Float64]
    var dy: List[Float64]
    var direction: List[Int]
    # Filled by `sort_by_top`: edge indices in ascending order of the
    # whole row their top lands in, and that row for each entry.
    var order: List[Int]
    var order_row: List[Int]

    def __init__(out self):
        self.y_lo = List[Float64]()
        self.y_hi = List[Float64]()
        self.x0 = List[Float64]()
        self.y0 = List[Float64]()
        self.dx = List[Float64]()
        self.dy = List[Float64]()
        self.direction = List[Int]()
        self.order = List[Int]()
        self.order_row = List[Int]()

    def add_edge(mut self, ax: Float64, ay: Float64, bx: Float64, by: Float64):
        """Record one edge. Horizontal edges are dropped: they never
        cross a scanline, so keeping them would only cost a rejected
        test on every sub-scanline for the life of the fill.
        """
        if ay == by:
            return
        self.y_lo.append(min(ay, by))
        self.y_hi.append(max(ay, by))
        self.x0.append(ax)
        self.y0.append(ay)
        self.dx.append(bx - ax)
        self.dy.append(by - ay)
        self.direction.append(1 if by > ay else -1)

    def sort_by_top(mut self):
        """Fill `order` with the edge indices bucketed by the whole row
        their `y_lo` falls in, ascending -- the order `crossings_at`
        admits them in -- and `order_row` with that row per entry. Run
        once, after the last `add_edge` and before the sweep.

        A counting sort over rows rather than a comparison sort over
        `y_lo`: it is linear in the edge count, and a stroked series
        has tens of thousands of edges. Sorting to whole rows only is
        enough because `crossings_at` skips an admitted edge until
        `fy` actually reaches its `y_lo`, so an edge admitted a fraction
        of a row early costs one test per sub-scanline and nothing else.
        """
        var n = len(self.y_lo)
        self.order = List[Int](length=n, fill=0)
        self.order_row = List[Int](length=n, fill=0)
        if n == 0:
            return
        var ylo = self.y_lo.unsafe_ptr()
        var rows_of = List[Int](length=n, fill=0)
        var rp = rows_of.unsafe_ptr()
        var min_row = Int(floor(ylo[unsafe_offset=0]))
        var max_row = min_row
        for i in range(n):
            var row = Int(floor(ylo[unsafe_offset=i]))
            rp[unsafe_offset=i] = row
            if row < min_row:
                min_row = row
            if row > max_row:
                max_row = row
        var rows = max_row - min_row + 1

        # counts[r + 1] is how many edges start in row r; after the
        # prefix sum, counts[r] is where row r's run begins in `order`.
        var counts = List[Int](length=rows + 1, fill=0)
        var cp = counts.unsafe_ptr()
        for i in range(n):
            cp[unsafe_offset=rp[unsafe_offset=i] - min_row + 1] += 1
        for r in range(rows):
            cp[unsafe_offset=r + 1] += cp[unsafe_offset=r]
        var op = self.order.unsafe_ptr()
        var orow = self.order_row.unsafe_ptr()
        for i in range(n):
            var r = rp[unsafe_offset=i] - min_row
            var slot = cp[unsafe_offset=r]
            cp[unsafe_offset=r] = slot + 1
            op[unsafe_offset=slot] = i
            orow[unsafe_offset=slot] = r + min_row

    def crossings_at(
        self,
        fy: Float64,
        mut cursor: Int,
        mut active: List[Int],
        mut crossings: List[_AACrossing],
    ):
        """Every edge crossing y=fy, unordered, into a caller-owned
        list.

        Incremental rather than a scan of every edge. `cursor` is how
        many of `order` have been admitted to `active`, and `active`
        holds the admitted edges not yet passed. An edge is admitted
        once its top row is at or above `fy`'s row, skipped while
        `fy < y_lo` (at most a fraction of a row, since `order` is
        sorted to whole rows), and dropped for good once `fy >= y_hi`
        -- together the same `y_lo <= fy < y_hi` test the scan made,
        applied only to the edges near the sub-scanline. That needs
        sub-scanlines in non-decreasing `fy`, which a band's
        row-by-row, sub-row-by-sub-row walk provides; a band starts
        with `cursor` at 0 and `active` empty. The order crossings
        come out in differs from the scan's, but they are sorted by x
        before use and two crossings at the same x bound an empty run,
        so the coverage counts are unchanged.

        Read through pointers: the arrays are built once per fill and
        never resized while the sweep runs, and every index came out of
        `order`, which was built from the same count. Checked reads
        would defeat the point -- seven bounds checks per edge is more
        work than the two the point lists cost, not less.
        """
        crossings.clear()
        var ylo = self.y_lo.unsafe_ptr()
        var yhi = self.y_hi.unsafe_ptr()
        var ex0 = self.x0.unsafe_ptr()
        var ey0 = self.y0.unsafe_ptr()
        var edx = self.dx.unsafe_ptr()
        var edy = self.dy.unsafe_ptr()
        var edir = self.direction.unsafe_ptr()
        if len(self.order) == 0:
            # Not top-sorted: scan every edge. `_sweep_edges_aa` sorts
            # only for a single-banded sweep -- see its docstring.
            for i in range(len(self.y_lo)):
                if fy >= ylo[unsafe_offset=i] and fy < yhi[unsafe_offset=i]:
                    var t = (fy - ey0[unsafe_offset=i]) / edy[unsafe_offset=i]
                    crossings.append(
                        _AACrossing(
                            ex0[unsafe_offset=i] + t * edx[unsafe_offset=i],
                            edir[unsafe_offset=i],
                        )
                    )
            return
        var op = self.order.unsafe_ptr()
        var orow = self.order_row.unsafe_ptr()
        var count = len(self.order)
        var row = Int(floor(fy))
        while cursor < count and orow[unsafe_offset=cursor] <= row:
            active.append(op[unsafe_offset=cursor])
            cursor += 1
        var i = 0
        while i < len(active):
            var e = active[i]
            if fy >= yhi[unsafe_offset=e]:
                # Below this edge for the rest of the band: swap-remove.
                active[i] = active[len(active) - 1]
                _ = active.pop()
                continue
            if fy >= ylo[unsafe_offset=e]:
                var t = (fy - ey0[unsafe_offset=e]) / edy[unsafe_offset=e]
                crossings.append(
                    _AACrossing(
                        ex0[unsafe_offset=e] + t * edx[unsafe_offset=e],
                        edir[unsafe_offset=e],
                    )
                )
            i += 1


# Below this many pixels in a fill's bounding box, the sweep runs
# inline rather than dispatching tasks: task setup is not free and the
# shapes this package fills most often are glyph-sized. Set by
# benchmark (#92) -- re-benchmark before changing it.
comptime _MIN_PARALLEL_PIXELS = 40000


struct _CoverageAlpha(Movable):
    """The alpha a covered-sample count maps to, tabulated once per
    fill. Entry `covered` is
    `Int(Float64(covered) / Float64(total_samples) * Float64(alpha) + 0.5)`,
    the expression the sampled primitives (circles, ellipses, arcs)
    evaluate for each pixel they touch; tabulating it replaces a
    divide, a multiply and a float-to-int per pixel with one load, and
    produces the same bytes.

    The edge sweep below keeps the inline expression: through the table
    it measured slower, not faster (#125), so it is not used there.
    """

    var _table: List[UInt8]

    def __init__(out self, total_samples: Int, alpha: UInt8):
        self._table = List[UInt8](capacity=total_samples + 1)
        for covered in range(total_samples + 1):
            self._table.append(
                UInt8(
                    Int(
                        Float64(covered)
                        / Float64(total_samples)
                        * Float64(alpha)
                        + 0.5
                    )
                )
            )

    def __getitem__(self, covered: Int) -> UInt8:
        """Alpha for `covered` samples, 0 <= covered <= total_samples.
        Unchecked: a coverage count cannot exceed the grid it was
        counted on.
        """
        return self._table.unsafe_ptr()[unsafe_offset=covered]


def _accumulate_row_coverage(
    edges: _EdgeTable,
    mut cursor: Int,
    mut active: List[Int],
    py: Int,
    supersample: Int,
    row_first_px: Int,
    row_width: Int,
    fill_rule: FillRule,
    mut row_covered: List[Int],
    mut crossings: List[_AACrossing],
    mut suffix: List[Int],
):
    """Sub-sample coverage counts for one pixel row of `edges`, written
    into `row_covered` (which the caller has already cleared and sized to
    `row_width`).

    `crossings` and `suffix` are caller-owned scratch, reused across
    every row of a sweep rather than reallocated per row; `cursor` and
    `active` are the band's incremental edge state -- see
    `_EdgeTable.crossings_at`.
    """
    var s = supersample
    var step = 1.0 / Float64(s)
    for sy in range(s):
        var fy = Float64(py) + (Float64(sy) + 0.5) * step - 0.5
        edges.crossings_at(fy, cursor, active, crossings)
        _sort_aa_crossings_by_x(crossings, len(edges.order) != 0)
        var k = len(crossings)

        # suffix[i] is the signed winding contributed by every
        # crossing from index i onward -- what the reference ray
        # cast's `x > fx` test sums fresh per sample. Precomputing
        # it per sub-scanline is what removes the `* edges` factor.
        # Grown to fit, never shrunk, so a later sub-scanline with
        # fewer crossings reuses the same storage.
        while len(suffix) < k + 1:
            suffix.append(0)
        suffix[k] = 0
        for i in range(k - 1, -1, -1):
            suffix[i] = suffix[i + 1] + crossings[i].direction

        # Inside/outside is constant between consecutive
        # crossings, and the sub-sample x positions are uniformly
        # spaced -- fx(g) = x0 + (g + 0.5)/s for a sample index g
        # running across the whole row. So each inside run maps to
        # a contiguous range of g, and the samples in it can be
        # counted rather than tested one at a time: a pixel wholly
        # inside a run takes `+= s` in one step, and a pixel in no
        # run is never touched at all.
        #
        # Exactly the same counts as testing each position -- the
        # positions themselves are unchanged, only the way they're
        # counted is -- so every hand-derived coverage value in the
        # tests still holds. That is the check that this stayed
        # exact rather than merely close.
        var total_g = row_width * s
        var x0 = Float64(row_first_px) - 0.5
        for i in range(k + 1):
            if not _is_inside(suffix[i], fill_rule):
                continue

            # First sample at or after this run's left edge.
            var g_start = 0
            if i > 0:
                var lo = crossings[i - 1].x
                g_start = Int(ceil((lo - x0) * Float64(s) - 0.5))
                # `ceil` on a float expression can land a step off
                # at a boundary; nudge to the exact first sample
                # rather than trust it.
                while g_start > 0 and _sample_x(x0, g_start - 1, s) >= lo:
                    g_start -= 1
                while g_start < total_g and _sample_x(x0, g_start, s) < lo:
                    g_start += 1
                if g_start < 0:
                    g_start = 0

            # Last sample strictly before this run's right edge.
            var g_end = total_g - 1
            if i < k:
                var hi = crossings[i].x
                g_end = Int(ceil((hi - x0) * Float64(s) - 0.5)) - 1
                while g_end >= 0 and _sample_x(x0, g_end, s) >= hi:
                    g_end -= 1
                while g_end + 1 < total_g and _sample_x(x0, g_end + 1, s) < hi:
                    g_end += 1
                if g_end > total_g - 1:
                    g_end = total_g - 1

            # Walk the run a pixel at a time, taking every sample
            # that pixel contributes in one add.
            var g = g_start
            while g <= g_end:
                var pxi = g // s
                var upper = (pxi + 1) * s - 1
                if g_end < upper:
                    upper = g_end
                row_covered[pxi] += upper - g + 1
                g = upper + 1


def _sweep_edges_aa(
    mut canvas: Canvas,
    mut edges: _EdgeTable,
    min_x: Int,
    min_y: Int,
    max_x: Int,
    max_y: Int,
    color: Color,
    fill_rule: FillRule,
    supersample: Int,
):
    """Rasterize `edges` into `canvas` with supersampled coverage AA:
    for every pixel in the padded bounding box, sample an NxN sub-pixel
    grid and turn the covered fraction into that pixel's alpha. Each
    output pixel is written exactly once, so a translucent color does not
    double-blend anywhere, including where a shape crosses itself.

    `fill_path_aa` and `fill_polygon_aa` are the callers; each builds its
    own `_EdgeTable` and bounding box and then runs this.
    `min_x`/`min_y`/`max_x`/`max_y` are unpadded integer bounds -- the
    one-pixel AA skirt is added here.

    `edges` is `mut` so a single-banded sweep can store `sort_by_top`'s
    order on the table; keep it a reference. Making it `var` hands `create_task` an
    aggregate owned by this frame, which makes the golden suite hang or
    render wrong output nondeterministically -- canvas_mojo#97, filed
    upstream as modular/modular#7075, which carries the run-by-run
    detail. A separate List argument to the band task fails the same
    way, which is why the order is a field of the table.
    """
    var s = supersample
    var row_first_px = min_x - 1
    var row_width = (max_x + 2) - row_first_px  # px range length
    var first_row = min_y - 1
    var last_row = max_y + 2  # exclusive
    var row_count = last_row - first_row
    if row_count <= 0 or row_width <= 0:
        return

    # Rows are independent -- each derives its own crossings from the
    # shared, immutable edge table and writes only its own pixels -- so
    # a large fill is split into bands, one task per band.
    #
    # Only a large one. See _MIN_PARALLEL_PIXELS: dispatching for a
    # glyph costs more than sweeping it inline.
    var bands = 1
    if row_count * row_width >= _MIN_PARALLEL_PIXELS:
        bands = parallelism_level()
        if bands > row_count:
            bands = row_count
        if bands < 1:
            bands = 1

    if bands == 1:
        # Top-sort the edges so each sub-scanline touches only the
        # edges near it (see `_EdgeTable.crossings_at`). Single-banded
        # sweeps only: the sort is serial work ahead of the sweep, and
        # with the sweep spread over every core a stroked series of
        # tens of thousands of short edges measured slower sorted than
        # scanned (#133), while a glyph-sized or single-banded fill
        # measured faster.
        edges.sort_by_top()
        _sweep_band(
            canvas,
            edges,
            first_row,
            last_row,
            row_first_px,
            row_width,
            color,
            fill_rule,
            s,
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
            _sweep_band_async(
                canvas,
                edges,
                band_start,
                band_end,
                row_first_px,
                row_width,
                color,
                fill_rule,
                s,
            )
        )
    tg.wait()


async def _sweep_band_async(
    mut canvas: Canvas,
    edges: _EdgeTable,
    first_row: Int,
    last_row: Int,
    row_first_px: Int,
    row_width: Int,
    color: Color,
    fill_rule: FillRule,
    supersample: Int,
):
    """`_sweep_band` as a task. Separate from the plain function so the
    single-band path keeps an ordinary call with no coroutine
    machinery around it.
    """
    _sweep_band(
        canvas,
        edges,
        first_row,
        last_row,
        row_first_px,
        row_width,
        color,
        fill_rule,
        supersample,
    )


def _sweep_band(
    mut canvas: Canvas,
    edges: _EdgeTable,
    first_row: Int,
    last_row: Int,
    row_first_px: Int,
    row_width: Int,
    color: Color,
    fill_rule: FillRule,
    supersample: Int,
):
    """Sweep rows [first_row, last_row) of `edges` onto `canvas`.

    Bands write disjoint rows, so no two ever touch the same pixel.
    `canvas` is shared mutably between them on exactly that basis.
    """
    var s = supersample
    var total_samples = s * s

    # Buffers for the whole band, not per row and per sub-scanline.
    # A glyph-sized path is small enough that allocating a crossing
    # list, a suffix list and a coverage row per sub-scanline costs more
    # than the sampling does (#73). `_draw_polyline_core_aa` reuses its
    # per-row buffers the same way.
    var row_covered = List[Int](capacity=row_width)
    for _ in range(row_width):
        row_covered.append(0)
    var crossings = List[_AACrossing]()
    var suffix = List[Int]()
    var cursor = 0
    var active = List[Int]()

    for py in range(first_row, last_row):
        for pxi in range(row_width):
            row_covered[pxi] = 0

        _accumulate_row_coverage(
            edges,
            cursor,
            active,
            py,
            s,
            row_first_px,
            row_width,
            fill_rule,
            row_covered,
            crossings,
            suffix,
        )

        for pxi in range(row_width):
            var covered = row_covered[pxi]
            if covered > 0:
                var px = row_first_px + pxi
                var alpha = UInt8(
                    Int(
                        Float64(covered)
                        / Float64(total_samples)
                        * Float64(color.a)
                        + 0.5
                    )
                )
                canvas.set_pixel(
                    px, py, Color(color.r, color.g, color.b, alpha)
                )


def _sweep_edges_to_mask(
    mut mask: List[UInt8],
    mask_width: Int,
    mask_height: Int,
    origin_x: Int,
    origin_y: Int,
    mut edges: _EdgeTable,
    min_x: Int,
    min_y: Int,
    max_x: Int,
    max_y: Int,
    fill_rule: FillRule,
    supersample: Int,
):
    """`_sweep_edges_aa`'s counterpart for a clip mask: the same
    coverage, written as a per-pixel 0-255 byte into `mask` instead of
    blended onto a canvas as alpha.

    `mask` is expected to be `mask_width * mask_height` bytes, already
    zeroed, covering canvas pixels [origin_x, origin_x + mask_width) x
    [origin_y, origin_y + mask_height). Anything the shape does not
    cover keeps its zero, which is what makes the mask read as "clipped
    out" there.

    Banded across cores above `_MIN_PARALLEL_PIXELS` exactly as
    `_sweep_edges_aa` is, with the same single-band-only top-sort:
    bands write disjoint rows of `mask` and only read `edges`.
    """
    var s = supersample
    var row_first_px = min_x - 1
    var row_width = (max_x + 2) - row_first_px
    # The sweep's padded rows, cut to the rows the mask can hold.
    var first_row = max(min_y - 1, origin_y)
    var last_row = min(max_y + 2, origin_y + mask_height)  # exclusive
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
        edges.sort_by_top()
        _mask_band(
            mask,
            mask_width,
            origin_x,
            origin_y,
            edges,
            first_row,
            last_row,
            row_first_px,
            row_width,
            fill_rule,
            s,
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
            _mask_band_async(
                mask,
                mask_width,
                origin_x,
                origin_y,
                edges,
                band_start,
                band_end,
                row_first_px,
                row_width,
                fill_rule,
                s,
            )
        )
    tg.wait()


async def _mask_band_async(
    mut mask: List[UInt8],
    mask_width: Int,
    origin_x: Int,
    origin_y: Int,
    edges: _EdgeTable,
    first_row: Int,
    last_row: Int,
    row_first_px: Int,
    row_width: Int,
    fill_rule: FillRule,
    supersample: Int,
):
    """`_mask_band` as a task; see `_sweep_band_async`."""
    _mask_band(
        mask,
        mask_width,
        origin_x,
        origin_y,
        edges,
        first_row,
        last_row,
        row_first_px,
        row_width,
        fill_rule,
        supersample,
    )


def _mask_band(
    mut mask: List[UInt8],
    mask_width: Int,
    origin_x: Int,
    origin_y: Int,
    edges: _EdgeTable,
    first_row: Int,
    last_row: Int,
    row_first_px: Int,
    row_width: Int,
    fill_rule: FillRule,
    supersample: Int,
):
    """Write rows [first_row, last_row) of `edges`' coverage into
    `mask`. Rows are in canvas coordinates and already inside the
    mask; columns are still clipped to it here.
    """
    var s = supersample
    var total_samples = s * s

    var row_covered = List[Int](capacity=row_width)
    for _ in range(row_width):
        row_covered.append(0)
    var crossings = List[_AACrossing]()
    var suffix = List[Int]()
    var cursor = 0
    var active = List[Int]()

    for py in range(first_row, last_row):
        for pxi in range(row_width):
            row_covered[pxi] = 0

        _accumulate_row_coverage(
            edges,
            cursor,
            active,
            py,
            s,
            row_first_px,
            row_width,
            fill_rule,
            row_covered,
            crossings,
            suffix,
        )

        var row_base = (py - origin_y) * mask_width
        for pxi in range(row_width):
            var covered = row_covered[pxi]
            if covered == 0:
                continue
            var mx = row_first_px + pxi - origin_x
            if mx < 0 or mx >= mask_width:
                continue
            mask[row_base + mx] = UInt8(
                Int(Float64(covered) / Float64(total_samples) * 255.0 + 0.5)
            )
