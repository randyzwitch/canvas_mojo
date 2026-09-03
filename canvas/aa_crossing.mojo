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
"""

from std.math import ceil
from std.runtime.asyncrt import TaskGroup, parallelism_level

from canvas.buffer import Canvas
from canvas.color import Color
from canvas.fill_rule import FillRule, _is_inside


struct _AACrossing(ImplicitlyCopyable, Movable):
    var x: Float64
    var direction: Int

    def __init__(out self, x: Float64, direction: Int):
        self.x = x
        self.direction = direction


def _sort_aa_crossings_by_x(mut crossings: List[_AACrossing]):
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

    Here rather than in either caller for the same reason `_AACrossing`
    is: `path.mojo` already imports from `polygon_fill`, so anything
    they share has to live somewhere neither imports.
    """
    return x0 + (Float64(g) + 0.5) / Float64(s)


struct _EdgeTable(Movable):
    """Every non-horizontal edge of a shape, as flat arrays.

    Both AA sweeps ask each sub-scanline which edges cross it -- four
    questions per pixel row at the default supersample. Read from the
    caller's own point lists, each edge would cost two bounds-checked
    reads, a modulo to wrap the closing edge and two integer-to-float
    conversions per row, none of it varying with the row. The table
    hoists that out once per fill, storing the values the crossing
    computation already used.

    Edges are added one at a time, since the two callers describe their
    geometry differently -- one walks sub-paths, the other a single point
    ring -- while the scan over the result is identical.
    """

    var y_lo: List[Float64]
    var y_hi: List[Float64]
    var x0: List[Float64]
    var y0: List[Float64]
    var dx: List[Float64]
    var dy: List[Float64]
    var direction: List[Int]

    def __init__(out self):
        self.y_lo = List[Float64]()
        self.y_hi = List[Float64]()
        self.x0 = List[Float64]()
        self.y0 = List[Float64]()
        self.dx = List[Float64]()
        self.dy = List[Float64]()
        self.direction = List[Int]()

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

    def crossings_at(self, fy: Float64, mut crossings: List[_AACrossing]):
        """Every edge crossing y=fy, unordered, into a caller-owned
        list.

        Read through pointers: the arrays are built once per fill and
        never resized while the sweep runs, and every index is bounded
        by the same count the loop iterates. Checked reads would defeat
        the point -- seven bounds checks per edge is more work than the
        two the point lists cost, not less.
        """
        crossings.clear()
        var count = len(self.y_lo)
        var ylo = self.y_lo.unsafe_ptr()
        var yhi = self.y_hi.unsafe_ptr()
        var ex0 = self.x0.unsafe_ptr()
        var ey0 = self.y0.unsafe_ptr()
        var edx = self.dx.unsafe_ptr()
        var edy = self.dy.unsafe_ptr()
        var edir = self.direction.unsafe_ptr()
        for i in range(count):
            if fy >= ylo[unsafe_offset=i] and fy < yhi[unsafe_offset=i]:
                var t = (fy - ey0[unsafe_offset=i]) / edy[unsafe_offset=i]
                crossings.append(
                    _AACrossing(
                        ex0[unsafe_offset=i] + t * edx[unsafe_offset=i],
                        edir[unsafe_offset=i],
                    )
                )


# Below this many pixels in a fill's bounding box, the sweep runs
# inline rather than dispatching tasks. Task setup is not free and the
# shapes this package fills most often are glyph-sized.
comptime _MIN_PARALLEL_PIXELS = 40000


def _accumulate_row_coverage(
    edges: _EdgeTable,
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

    Separate from its two consumers so both can share it:
    `_sweep_edges_aa` blends the counts onto a canvas as alpha, and
    `_sweep_edges_to_mask` stores them as a clip mask.

    `crossings` and `suffix` are caller-owned scratch, reused across
    every row of a sweep rather than reallocated per row.
    """
    var s = supersample
    var step = 1.0 / Float64(s)
    for sy in range(s):
        var fy = Float64(py) + (Float64(sy) + 0.5) * step - 0.5
        edges.crossings_at(fy, crossings)
        _sort_aa_crossings_by_x(crossings)
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
    edges: _EdgeTable,
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

    The sweep runs per sub-scanline, not per sub-pixel sample. Rescanning
    every edge per sub-sample, as the reference tests `_point_in_subpaths`
    and `_point_in_polygon` do, is O(pixels * supersample^2 * edges).
    Collecting a sub-scanline's crossings once removes the `* edges`
    factor: sort by x, precompute each crossing's suffix winding sum, then
    sweep every sub-sample's x -- strictly increasing across the row --
    against that sorted list with one forward-only pointer. The math per
    sample is the same ray cast either way.

    Keep `edges` borrowed. Making it `var` hands `create_task` an
    aggregate owned by this frame, which makes the golden suite hang or
    render wrong output nondeterministically -- canvas_mojo#97, filed
    upstream as modular/modular#7075, which carries the run-by-run
    detail. Preprocess in the caller, or take the parameter `mut`.
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

    One band of a fill. Every buffer here is local to the band rather
    than shared across the whole sweep, which is what makes bands
    independent -- and costs nothing, since the allocation was always
    per-sweep and there are only ever a handful of bands.

    Bands write disjoint rows, so no two ever touch the same pixel.
    `canvas` is shared mutably between them on exactly that basis.
    """
    var s = supersample
    var total_samples = s * s

    # Buffers for the whole band, not per row and per sub-scanline.
    # A glyph-sized path is small enough that allocating a crossing
    # list, a suffix list and a coverage row for every sub-scanline
    # costs more than the sampling does -- measured at roughly 5x the
    # per-pixel cost of a large shape. `_draw_polyline_core_aa` already
    # reuses its per-row buffers this way; these match it.
    var row_covered = List[Int](capacity=row_width)
    for _ in range(row_width):
        row_covered.append(0)
    var crossings = List[_AACrossing]()
    var suffix = List[Int]()

    for py in range(first_row, last_row):
        for pxi in range(row_width):
            row_covered[pxi] = 0

        _accumulate_row_coverage(
            edges,
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
    edges: _EdgeTable,
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
    zeroed. Anything the shape does not cover keeps its zero, which is
    what makes the mask read as "clipped out" there.

    Coverage, not a hard in/out test, is the point: a clip path's own
    edge is anti-aliased exactly as a filled path's would be, so
    clipping a shape to a circle gives a smooth boundary rather than a
    staircase.
    """
    var s = supersample
    var total_samples = s * s
    var row_first_px = min_x - 1
    var row_width = (max_x + 2) - row_first_px

    var row_covered = List[Int](capacity=row_width)
    for _ in range(row_width):
        row_covered.append(0)
    var crossings = List[_AACrossing]()
    var suffix = List[Int]()

    for py in range(min_y - 1, max_y + 2):
        if py < 0 or py >= mask_height:
            continue
        for pxi in range(row_width):
            row_covered[pxi] = 0

        _accumulate_row_coverage(
            edges,
            py,
            s,
            row_first_px,
            row_width,
            fill_rule,
            row_covered,
            crossings,
            suffix,
        )

        var row_base = py * mask_width
        for pxi in range(row_width):
            var covered = row_covered[pxi]
            if covered == 0:
                continue
            var px = row_first_px + pxi
            if px < 0 or px >= mask_width:
                continue
            mask[row_base + px] = UInt8(
                Int(Float64(covered) / Float64(total_samples) * 255.0 + 0.5)
            )
