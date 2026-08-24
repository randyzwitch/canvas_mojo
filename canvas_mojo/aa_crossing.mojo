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
