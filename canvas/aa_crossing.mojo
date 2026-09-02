"""`_AACrossing` and its sort: one sub-scanline crossing at a
real-valued x -- polygon_fill's `_Crossing` with a fractional y, where
x stays `Float64` rather than rounding to `Int`, since an AA sweep
places a crossing between two supersample columns, not two whole
pixels -- plus the insertion sort `fill_polygon_aa` and `fill_path_aa`
both use to order a sub-scanline's crossings before their identical
left-to-right winding scan.

A leaf module so neither file imports it from the other: `path.mojo`
already imports drawing primitives *from* `polygon_fill`, so importing
`_AACrossing` back the other way would be a real cycle. This module
imports from neither, leaving a clean DAG (polygon_fill ->
aa_crossing, path -> aa_crossing, path -> polygon_fill).

Insertion sort, since a sub-scanline's crossing count is a handful,
not the whole path's point count -- the same reasoning
`polygon_fill`'s `_spans_from_crossings` uses for its own copy of this
sort over `_Crossing`/`Int`. Unifying the two behind one generic sort
would be a larger change than sharing this struct was.
"""


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

    The AA sweeps in `path.mojo` and `shapes/polygon_fill.mojo` both ask
    each sub-scanline which edges cross it -- four questions per pixel
    row at the default supersample. Asked against the caller's own point
    lists, each edge costs two bounds-checked reads, a modulo to wrap
    the closing edge, and two integer-to-float conversions, all before
    the y-range test that usually rejects it. None of that varies with
    the row.

    Built once per fill instead. The stored values are exactly the ones
    the crossing computation already used, so the arithmetic producing a
    crossing is unchanged and so is its result; only the work of
    rediscovering the edge each time is gone.

    Here rather than in either caller for the same reason `_AACrossing`
    is: `path.mojo` already imports from `polygon_fill`, so anything
    they share has to live where neither imports. Edges are added one at
    a time because the two callers describe their geometry differently
    -- one walks sub-paths, the other a single point ring -- while the
    scan over the result is identical.
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
        two the point lists cost, not less, which an earlier draft of
        this measured the hard way.
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
