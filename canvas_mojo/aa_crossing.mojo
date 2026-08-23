"""`_AACrossing` and its own sort -- one sub-scanline crossing at a
real-valued x (`canvas_mojo.shapes.polygon_fill`'s own `_Crossing`'s
fractional-y counterpart: x stays `Float64`, not rounded to `Int`,
since an AA sweep needs to place a crossing between two supersample
columns, not just two whole pixels), plus the insertion sort both
`fill_polygon_aa` (`canvas_mojo.shapes.polygon_fill`) and
`fill_path_aa` (`path.mojo`) use to order one sub-scanline's own
crossings by x before their identical left-to-right winding-number
scan.

A shared leaf module specifically so *neither* of those two files has
to import it from the other: `path.mojo` already imports *from*
`canvas_mojo.shapes.polygon_fill` (real drawing primitives, not just
this), so `canvas_mojo.shapes.polygon_fill` importing `_AACrossing`
back from `path.mojo` would be a genuine cycle (path -> polygon_fill
-> path), not just an inconvenience. This module imports from neither,
so both can depend on it with no cycle at all: polygon_fill ->
aa_crossing, path -> aa_crossing, path -> polygon_fill, a clean DAG.

Insertion sort, not a general-purpose one: one sub-scanline's own
crossing count is always small (a handful, not the whole polygon's/
path's point count) -- the same reasoning
`canvas_mojo.shapes.polygon_fill`'s own `_spans_from_crossings` (a
separate copy of this same insertion sort, over `_Crossing`/`Int`
rather than `_AACrossing`/`Float64`) relies on for its own identical
choice. Unifying the two into one generic sort would be a larger
change than sharing this struct was.
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
