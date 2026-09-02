"""Dash-pattern phase logic -- shared by every stroked shape in
canvas.shapes (lines, polylines/polygons, and indirectly arcs via
draw_polyline/draw_polyline_aa). Split into its own file since it has
no dependency on Canvas or any shape's geometry, unlike every other
file in this subpackage -- see canvas.shapes.lines for the
hard-edged vs. `_aa` naming convention every file here follows.
"""

from std.math import floor

# Stands in for "no next boundary" when there is no dash pattern. Far
# beyond any path length a canvas can hold, so callers that clamp it
# against a segment's end get the whole segment.
comptime _NO_BOUNDARY = 1.0e30


def _dash_cycle(dashes: List[Float64]) -> List[Float64]:
    """The pattern actually cycled: `dashes` as given, or doubled when
    its length is odd.

    Cairo's convention, matched here for anyone porting a pattern from
    it: [5, 2, 1] means [5, 2, 1, 5, 2, 1], since an odd count cannot
    otherwise alternate on/off evenly around the repeat. Factored out
    so `_is_dash_on` and `_dash_next_boundary` cannot disagree about
    what the repeat is.
    """
    var pattern = List[Float64]()
    for d in dashes:
        pattern.append(d)
    if len(dashes) % 2 == 1:
        for d in dashes:
            pattern.append(d)
    return pattern^


def _dash_next_boundary(
    distance: Float64, dashes: List[Float64], offset: Float64
) -> Float64:
    """The next distance strictly greater than `distance` at which the
    dash state flips.

    `_is_dash_on` answers "is this point drawn"; this answers "for how
    much longer", which is what lets a stroke be split into drawn
    pieces geometrically instead of tested per sample. Returns a very
    large value when there is no pattern, so a caller's `min(boundary,
    segment_end)` naturally yields the whole segment.
    """
    if len(dashes) == 0:
        return _NO_BOUNDARY

    var pattern = _dash_cycle(dashes)
    var total = 0.0
    for d in pattern:
        total += d
    if total <= 0.0:
        return _NO_BOUNDARY

    var raw = distance + offset
    var wrapped = raw - floor(raw / total) * total

    var cursor = 0.0
    for i in range(len(pattern)):
        cursor += pattern[i]
        if wrapped < cursor:
            return distance + (cursor - wrapped)
    return distance + (total - wrapped)


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

    var pattern = _dash_cycle(dashes)
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
