"""The rule that decides which regions of a self-intersecting or
multi-sub-path shape count as "inside" for fill_polygon/fill_path (and
their gradient variants).

EVEN_ODD (the default, used whenever this parameter isn't passed) counts
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
region gets exactly one set_pixel call, not two, so a translucent fill
doesn't double-blend where the shape crosses itself.
"""


struct FillRule(Copyable, ImplicitlyCopyable, Movable):
    var _value: Int

    comptime EVEN_ODD = Self(0)
    comptime NONZERO = Self(1)

    def __init__(out self, value: Int):
        """Prefer the `EVEN_ODD`/`NONZERO` comptime constants over
        constructing one directly.

        Args:
            value: 0 for EVEN_ODD, 1 for NONZERO.
        """
        self._value = value

    def __eq__(self, other: Self) -> Bool:
        return self._value == other._value


def _is_inside(winding: Int, fill_rule: FillRule) -> Bool:
    """Whether a signed winding number counts as "inside" under
    `fill_rule` -- the single place the two rules actually differ.

    Every fill in this package routes its membership decision through
    here, which is what makes a hard-edged fill and its anti-aliased
    counterpart agree on exactly where a boundary sits.

    Lives here rather than in `canvas.shapes.polygon_fill`, where it
    used to: `canvas.aa_crossing`'s shared AA sweep needs it too, and
    `polygon_fill` imports *from* that module, so reaching back the
    other way would be a cycle. This module imports nothing at all,
    which makes it the one place both can see.
    """
    if fill_rule == FillRule.NONZERO:
        return winding != 0
    var w = winding
    if w < 0:
        w = -w
    return w % 2 == 1
