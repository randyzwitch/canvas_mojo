"""Demo: how a stroke ends, and how it turns a corner.

`LineCap` decides what happens at an open stroke's two ends; `LineJoin`
decides what happens where it changes direction. Both are visible at
chart-sized stroke widths: a 6px round cap makes an axis rule overshoot
its own ticks by 3px at each end, and a mitred corner on a plot frame
reads as a frame where a round one reads as a lozenge.

Top row: the three caps on a thick horizontal bar, with tick marks
showing where the stroke was actually asked to start and stop. Only
BUTT lands on them.

Bottom row: the three joins on a right-angle corner, plus a sharp corner
where MITER exceeds its limit and falls back to BEVEL -- without that
fallback the spike would run off the canvas.

Writes examples/out_joins.png.
"""

from canvas.buffer import Canvas
from canvas.color import Color
from canvas.geometry import FPoint
from canvas.io.png import write_png
from canvas.shapes.lines import (
    LineCap,
    LineJoin,
    draw_line_aa,
    draw_polyline_aa,
)
from canvas.text.font_cache import FontCache
from canvas.text.render import draw_text

comptime W = 820
comptime H = 400
comptime INK = Color(45, 55, 75)
comptime ACCENT = Color(220, 95, 70)
comptime GUIDE = Color(150, 160, 175)


def main() raises:
    var c = Canvas(W, H, Color(252, 252, 250))
    var cache = FontCache()

    var caps: List[LineCap] = [LineCap.BUTT, LineCap.ROUND, LineCap.SQUARE]
    var cap_names: List[String] = ["BUTT", "ROUND", "SQUARE"]
    for i in range(3):
        var y = 60.0 + Float64(i) * 46.0
        # Tick marks at the stroke's requested endpoints.
        draw_line_aa(c, 150.0, y - 18.0, 150.0, y + 18.0, GUIDE, 1.0)
        draw_line_aa(c, 330.0, y - 18.0, 330.0, y + 18.0, GUIDE, 1.0)
        draw_line_aa(c, 150.0, y, 330.0, y, INK, 14.0, cap=caps[i])
        draw_text(c, 360.0, y + 5.0, cap_names[i], INK, size=15.0, cache=cache)

    draw_text(
        c,
        60.0,
        30.0,
        "caps -- only BUTT stops on the ticks",
        Color(90, 100, 120),
        size=14.0,
        cache=cache,
    )
    draw_text(
        c,
        60.0,
        232.0,
        "joins -- the last two are one sharp corner at two miter limits",
        Color(90, 100, 120),
        size=14.0,
        cache=cache,
    )

    # The three styles at a right angle, then the same *sharp* corner
    # twice: once with a generous miter limit so the spike survives,
    # once at the default 4 where it is cut back to a bevel. Using one
    # corner for both is the point -- the limit is what differs, not
    # the geometry.
    var joins: List[LineJoin] = [
        LineJoin.BEVEL,
        LineJoin.ROUND,
        LineJoin.MITER,
        LineJoin.MITER,
        LineJoin.MITER,
    ]
    var limits: List[Float64] = [4.0, 4.0, 4.0, 12.0, 4.0]
    var join_names: List[String] = [
        "BEVEL",
        "ROUND",
        "MITER",
        "limit 12",
        "limit 4",
    ]
    for i in range(5):
        var ox = 60.0 + Float64(i) * 152.0
        var oy = 300.0
        var pts = List[FPoint]()
        if i < 3:
            pts.append(FPoint(ox, oy + 60.0))
            pts.append(FPoint(ox, oy))
            pts.append(FPoint(ox + 70.0, oy))
        else:
            # A ~156 degree turn: the miter ratio here is about 5.3, so
            # the default limit of 4 rejects it and 12 accepts it.
            pts.append(FPoint(ox + 4.0, oy + 62.0))
            pts.append(FPoint(ox + 62.0, oy + 4.0))
            pts.append(FPoint(ox + 30.0, oy + 56.0))
        draw_polyline_aa(
            c,
            pts,
            ACCENT if i >= 3 else INK,
            16.0,
            join=joins[i],
            miter_limit=limits[i],
        )
        draw_text(c, ox, oy + 92.0, join_names[i], INK, size=15.0, cache=cache)

    write_png(c, "examples/out_joins.png")
