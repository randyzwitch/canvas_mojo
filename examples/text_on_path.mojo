"""Demo: draw_text_on_path() running a baseline along a curve, and
stroke_text() outlining glyphs instead of filling them.

Three things a straight filled label cannot do:

  - a donut segment labelled around its own arc, the label following
    the wedge rather than sitting beside it
  - a polar grid's angular axis labelled around its outer ring
  - a title over a busy background, outlined in the background's own
    ink so it reads against every part of it

Both go through the same shaping, kerning and font fallback draw_text
does -- a curved label kerns exactly as a straight one does.

Run with:
    pixi run example
"""

from std.math import cos, pi, sin

from canvas.buffer import Canvas
from canvas.color import Color
from canvas.io.bmp import write_bmp
from canvas.io.png import write_png
from canvas.path import Path
from canvas.shapes.arcs import fill_ring_sector_aa
from canvas.text.font_cache import FontCache
from canvas.text.font_discovery import FontWeight
from canvas.text.render import (
    draw_text,
    draw_text_on_path,
    measure_text,
    stroke_text,
    TextAlign,
)

comptime PAPER = Color(250, 250, 248)
comptime INK = Color(20, 24, 32)
comptime MUTED = Color(120, 128, 140)


def _arc_path(
    cx: Float64,
    cy: Float64,
    radius: Float64,
    start_angle: Float64,
    end_angle: Float64,
) raises -> Path:
    """A bare arc as a Path: the baseline a label runs along."""
    var p = Path()
    p.move_to(cx + radius * cos(start_angle), cy + radius * sin(start_angle))
    p.arc_to(cx, cy, radius, start_angle, end_angle)
    return p^


def _is_below(mid_angle: Float64) -> Bool:
    """Is a label centred on this angle below the circle's centre?

    Glyphs stand up from the baseline on the side the arc turns away
    from, so an arc swept with increasing angle reads the right way up
    across the top of a circle and upside down across the bottom. The
    two functions below both reverse the sweep here, and move the
    baseline out by roughly the text's height to compensate for the
    ink then sitting on the other side of it.
    """
    return sin(mid_angle) > 0.0


def _label_radius(
    radius: Float64, mid_angle: Float64, size: Float64
) -> Float64:
    """The baseline radius to place a label at, given the radius its
    ink should start from -- see `_is_below`.
    """
    if _is_below(mid_angle):
        return radius + 0.72 * size
    return radius


def _label_arc(
    cx: Float64,
    cy: Float64,
    radius: Float64,
    mid_angle: Float64,
    half_span: Float64,
) raises -> Path:
    """A label's baseline, centred on `mid_angle` and swept in
    whichever direction leaves the text the right way up. `radius` is
    `_label_radius`'s, not the ring's.
    """
    if _is_below(mid_angle):
        return _arc_path(
            cx, cy, radius, mid_angle + half_span, mid_angle - half_span
        )
    return _arc_path(
        cx, cy, radius, mid_angle - half_span, mid_angle + half_span
    )


def _donut(mut c: Canvas, mut cache: FontCache) raises:
    """A three-segment donut with each slice's name curved around it.

    The label sits on an arc drawn at the middle of the ring's
    thickness, centred on the middle of the slice: CENTER alignment
    against an offset of half the arc's length puts the string's own
    centre there, whatever its width.
    """
    var cx = 320.0
    var cy = 400.0
    var inner = 110.0
    var outer = 210.0
    var mid = (inner + outer) / 2.0

    var starts: List[Float64] = [-pi / 2.0, 0.35, 2.4]
    var ends: List[Float64] = [0.35, 2.4, 1.5 * pi]
    var fills: List[Color] = [
        Color(66, 112, 190),
        Color(224, 148, 62),
        Color(92, 168, 122),
    ]
    var names: List[String] = ["Direct", "Referral", "Organic"]

    for i in range(3):
        fill_ring_sector_aa(
            c, cx, cy, inner, outer, starts[i], ends[i], fills[i]
        )

    for i in range(3):
        var half_span = (ends[i] - starts[i]) / 2.0
        var mid_angle = starts[i] + half_span
        var baseline_radius = _label_radius(mid - 12.0, mid_angle, 34.0)
        var baseline = _label_arc(cx, cy, baseline_radius, mid_angle, half_span)
        # CENTER against half the arc's own length: the string's centre
        # lands on the middle of the slice whatever its width.
        draw_text_on_path(
            c,
            baseline,
            names[i],
            Color(255, 255, 255),
            34.0,
            baseline_radius * half_span,
            align=TextAlign.CENTER,
            weight=FontWeight.BOLD,
            cache=cache,
        )

    draw_text(
        c,
        cx,
        cy + 8.0,
        "Traffic",
        INK,
        30.0,
        align=TextAlign.CENTER,
        cache=cache,
    )


def _polar_grid(mut c: Canvas, mut cache: FontCache) raises:
    """A polar grid whose angular axis is labelled around its outer
    ring, each label upright against the ring at the angle it names.

    The rings themselves come from the DrawTarget trait's
    `draw_circle_aa`; the labels ride an arc drawn just outside the
    outermost one.
    """
    var cx = 1080.0
    var cy = 400.0
    var outer = 210.0

    for step in range(1, 5):
        var radius = outer * Float64(step) / 4.0
        c.draw_circle_aa(cx, cy, radius, Color(214, 218, 226), 1.5)
    for spoke in range(8):
        var angle = Float64(spoke) * pi / 4.0
        c.draw_line_aa(
            Int(cx),
            Int(cy),
            Int(cx + outer * cos(angle)),
            Int(cy + outer * sin(angle)),
            Color(226, 230, 238),
            1.5,
        )

    # A ring 26 px outside the grid, one label centred on each spoke.
    # The label arc is short and centred on the spoke's angle, so the
    # text reads left to right along the ring rather than upside down
    # on the far side.
    var label_radius = outer + 26.0
    var labels: List[String] = [
        "0",
        "45",
        "90",
        "135",
        "180",
        "225",
        "270",
        "315",
    ]
    for spoke in range(8):
        var angle = Float64(spoke) * pi / 4.0
        var width = measure_text(labels[spoke], 24.0, cache=cache).advance
        var radius = _label_radius(label_radius, angle, 24.0)
        # An arc twice the label's width, so the string sits well
        # inside it and its centre lands on the spoke.
        var half_span = width / radius
        var baseline = _label_arc(cx, cy, radius, angle, half_span)
        draw_text_on_path(
            c,
            baseline,
            labels[spoke],
            MUTED,
            24.0,
            radius * half_span,
            align=TextAlign.CENTER,
            cache=cache,
        )

    var series = Path()
    for spoke in range(9):
        var angle = Float64(spoke) * pi / 4.0
        var radius = outer * (0.35 + 0.15 * Float64(spoke % 3))
        var px = cx + radius * cos(angle)
        var py = cy + radius * sin(angle)
        if spoke == 0:
            series.move_to(px, py)
        else:
            series.line_to(px, py)
    series.close()
    c.stroke_path_aa(series, Color(66, 112, 190, 200), 3.0)


def _outlined_title(mut c: Canvas, mut cache: FontCache) raises:
    """A title over a background busy enough to swallow a plain filled
    one: the glyphs are filled white and then outlined in the
    background's own dark ink, so every edge has contrast whatever it
    crosses.
    """
    for i in range(28):
        var t = Float64(i) / 27.0
        var shade = Color(
            UInt8(40 + Int(120.0 * t)),
            UInt8(70 + Int(90.0 * t)),
            UInt8(120 + Int(60.0 * t)),
        )
        c.fill_rect(40 + i * 48, 660, 44, 120, shade)
    for i in range(9):
        c.fill_circle_aa(120 + i * 160, 720, 46, Color(255, 255, 255, 45))

    var title = String("Outlined over anything")
    # Fill first, then the outline over it: the stroke straddles the
    # contour, so drawing it second keeps the full stroke width rather
    # than letting the fill cover its inner half.
    draw_text(
        c,
        720.0,
        742.0,
        title,
        Color(255, 255, 255),
        56.0,
        align=TextAlign.CENTER,
        weight=FontWeight.BOLD,
        cache=cache,
    )
    stroke_text(
        c,
        720.0,
        742.0,
        title,
        Color(16, 20, 30),
        56.0,
        width=2.5,
        align=TextAlign.CENTER,
        weight=FontWeight.BOLD,
        cache=cache,
    )


def main() raises:
    var c = Canvas(1440, 820, PAPER)
    var cache = FontCache()

    draw_text(c, 40.0, 70.0, "Text along a path", INK, 44.0, cache=cache)
    draw_text(
        c,
        40.0,
        108.0,
        "draw_text_on_path() and stroke_text()",
        MUTED,
        26.0,
        cache=cache,
    )

    _donut(c, cache)
    _polar_grid(c, cache)
    _outlined_title(c, cache)

    write_bmp(c, "examples/out_text_on_path.bmp")
    write_png(c, "examples/out_text_on_path.png")
    print("wrote examples/out_text_on_path.bmp and .png")
