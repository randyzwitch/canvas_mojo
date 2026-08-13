"""The rule that decides which regions of a self-intersecting or
multi-sub-path shape count as "inside" for fill_polygon/fill_path (and
their gradient variants).

EVEN_ODD (the default, matching every fill_* function's original,
still-unchanged behavior when this parameter isn't passed) counts
crossings to a point's left and calls it inside when that count is
odd -- simple, and the right answer for the overwhelming majority of
shapes (anything simple/non-self-intersecting, where the two rules
always agree), but for a shape that overlaps itself, it treats an
overlap region as "outside" again wherever it's crossed an even number
of times -- a hole appears exactly where two loops of the same shape
cover each other.

NONZERO instead tracks a signed running count (each edge contributes
+1 or -1 depending on whether it crosses a scanline going down or up)
and calls a point inside whenever that signed count is nonzero. For a
self-overlapping shape built from same-direction loops, this fills the
union solid -- no hole in the overlap, and critically, that overlap
region gets exactly one set_pixel call, not two: this is the actual
fix for the double-blending fill_polygon's own docstring used to warn
about for self-intersecting input, not a workaround bolted on
separately.
"""


struct FillRule(Copyable, ImplicitlyCopyable, Movable):
    var _value: Int

    comptime EVEN_ODD = Self(0)
    comptime NONZERO = Self(1)

    def __init__(out self, value: Int):
        self._value = value

    def __eq__(self, other: Self) -> Bool:
        return self._value == other._value
