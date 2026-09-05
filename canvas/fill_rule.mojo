"""Fill rules: how `fill_polygon`/`fill_path` and their gradient
variants decide which regions of a self-intersecting or multi-sub-path
shape count as inside.

EVEN_ODD, the default when the parameter is not passed, counts the edge
crossings to a point's left and calls the point inside when that count
is odd. Where two loops of the same shape overlap, the count is even, so
the overlap reads as outside and shows up as a hole.

NONZERO tracks a signed count instead: an edge contributes +1 or -1
depending on whether it crosses the scanline downward or upward, and a
point is inside whenever the total is nonzero. Same-direction loops fill
as their union, and each pixel of the overlap takes one set_pixel call
rather than two, so a translucent fill does not double-blend there.
"""


struct FillRule(Copyable, Equatable, ImplicitlyCopyable, Movable, Writable):
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

    def write_to[W: Writer](self, mut writer: W):
        if self._value == Self.EVEN_ODD._value:
            writer.write("EVEN_ODD")
        elif self._value == Self.NONZERO._value:
            writer.write("NONZERO")
        else:
            writer.write("FillRule(", self._value, ")")

    def __str__(self) -> String:
        var out = String()
        out.write(self)
        return out


def _is_inside(winding: Int, fill_rule: FillRule) -> Bool:
    """Whether a signed winding number counts as inside under
    `fill_rule` -- the one place the two rules differ. Every fill in the
    package routes its membership decision through here, so a hard-edged
    fill and its anti-aliased counterpart agree on where a boundary sits.
    """
    if fill_rule == FillRule.NONZERO:
        return winding != 0
    var w = winding
    if w < 0:
        w = -w
    return w % 2 == 1
