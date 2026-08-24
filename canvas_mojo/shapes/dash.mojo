"""Dash-pattern phase logic -- shared by every stroked shape in
canvas_mojo.shapes (lines, polylines/polygons, and indirectly arcs via
draw_polyline/draw_polyline_aa). Split into its own file since it has
no dependency on Canvas or any shape's geometry, unlike every other
file in this subpackage -- see canvas_mojo.shapes.lines for the
hard-edged vs. `_aa` naming convention every file here follows.
"""

from std.math import floor


def _is_dash_on(
    distance: Float64, dashes: List[Float64], offset: Float64
) -> Bool:
    """Is `distance` (measured along a path from wherever its dash
    phase starts) inside an "on" (drawn) segment of `dashes`, an
    alternating on/off/on/off/... list of lengths (index 0 is "on"),
    repeating indefinitely and shifted by `offset`?

    An empty `dashes` list -- the default everywhere this is called
    from -- means "no dash pattern," always on: a draw_line/
    draw_polyline/etc. call that doesn't pass dashes= draws solid.

    An odd-length list is doubled (Cairo's convention, matched
    here for anyone porting a pattern from it): [5, 2, 1] means the
    same as [5, 2, 1, 5, 2, 1] -- an odd count otherwise couldn't
    alternate on/off evenly around the repeat.
    """
    if len(dashes) == 0:
        return True

    var odd = len(dashes) % 2 == 1
    var pattern = List[Float64]()
    for d in dashes:
        pattern.append(d)
    if odd:
        for d in dashes:
            pattern.append(d)

    var total = 0.0
    for d in pattern:
        total += d
    if total <= 0.0:
        return True

    # floor-based modulo (not `%`/truncating remainder) so a negative
    # offset wraps correctly instead of landing outside [0, total).
    var raw = distance + offset
    var wrapped = raw - floor(raw / total) * total

    var cursor = 0.0
    for i in range(len(pattern)):
        cursor += pattern[i]
        if wrapped < cursor:
            return i % 2 == 0
    return True  # unreachable given wrapped < total by construction
