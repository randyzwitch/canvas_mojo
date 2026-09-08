"""How many pixels each bench row is obliged to change.

The floor for a drawing operation is the pixels whose value must
differ afterwards; everything beyond that is the implementation's
choice of how much to scan. Scenes are copied from bench_canvas.mojo
so the counts line up row for row.
"""
from std.math import cos, pi, sin

from canvas.buffer import Canvas, BYTES_PER_PIXEL
from canvas.color import Color
from canvas.compose import Filter, draw_canvas
from canvas.fill_rule import FillRule
from canvas.geometry import FPoint, Matrix2D
from canvas.gradient import LinearGradient
from canvas.mask import Mask
from canvas.path import (
    Path,
    fill_path_aa,
    fill_path_gradient_aa,
    stroke_path_aa,
)
from canvas.shapes.arcs import fill_arc_aa, fill_ring_sector_aa
from canvas.shapes.circles import fill_circle_aa, fill_circles_aa
from canvas.shapes.ellipses import fill_ellipse_aa, fill_ellipses_aa
from canvas.shapes.lines import draw_line, draw_line_aa, draw_polyline_aa
from canvas.shapes.polygon_fill import fill_polygon_aa
from canvas.shapes.rects import fill_rect
from canvas.text.font_cache import FontCache
from canvas.text.render import draw_text, draw_text_on_path

comptime W = 800
comptime H = 600
comptime WHITE = Color(255, 255, 255)
comptime INK = Color(30, 40, 60)


def _changed(base: Canvas, after: Canvas) -> Int:
    var a = base.pixels.unsafe_ptr()
    var b = after.pixels.unsafe_ptr()
    var n = 0
    for i in range(W * H):
        var o = i * 4
        if (
            a[unsafe_offset=o] != b[unsafe_offset=o]
            or a[unsafe_offset=o + 1] != b[unsafe_offset=o + 1]
            or a[unsafe_offset=o + 2] != b[unsafe_offset=o + 2]
            or a[unsafe_offset=o + 3] != b[unsafe_offset=o + 3]
        ):
            n += 1
    return n


def _say(name: String, px: Int):
    print(name, "\t", px)


def main() raises:
    var base = Canvas(W, H, WHITE)

    # --- markers ---
    var c = Canvas(W, H, WHITE)
    for i in range(2000):
        fill_circle_aa(
            c,
            20.0 + Float64((i * 37) % 760),
            20.0 + Float64((i * 53) % 560),
            3.5,
            INK,
        )
    _say("fill_circle_aa x2000 markers (r=3.5)", _changed(base, c))

    var centers = List[FPoint](capacity=2000)
    for i in range(2000):
        centers.append(
            FPoint(
                20.0 + Float64((i * 37) % 7600) * 0.1,
                20.0 + Float64((i * 53) % 5600) * 0.1,
            )
        )
    c = Canvas(W, H, WHITE)
    fill_circles_aa(c, centers, 3.5, INK)
    _say("fill_circles_aa x2000 markers batched (r=3.5)", _changed(base, c))

    c = Canvas(W, H, WHITE)
    fill_circle_aa(c, 400.0, 300.0, 250.0, INK)
    _say("fill_circle_aa one large (r=250)", _changed(base, c))

    c = Canvas(W, H, WHITE)
    fill_ellipse_aa(c, 400.0, 300.0, 340.0, 220.0, INK)
    _say("fill_ellipse_aa one large (340x220)", _changed(base, c))

    c = Canvas(W, H, WHITE)
    for i in range(2000):
        fill_ellipse_aa(
            c,
            20.0 + Float64((i * 37) % 760),
            20.0 + Float64((i * 53) % 560),
            5.0,
            3.0,
            INK,
        )
    _say("fill_ellipse_aa x2000 small (5x3)", _changed(base, c))

    var ell_centers = List[FPoint](capacity=2000)
    for i in range(2000):
        ell_centers.append(
            FPoint(
                20.0 + Float64((i * 37) % 7600) * 0.1,
                20.0 + Float64((i * 53) % 5600) * 0.1,
            )
        )
    c = Canvas(W, H, WHITE)
    fill_ellipses_aa(c, ell_centers, 5.0, 3.0, INK)
    _say("fill_ellipses_aa x2000 markers batched (5x3)", _changed(base, c))

    c = Canvas(W, H, WHITE)
    fill_arc_aa(c, 400.0, 300.0, 260.0, -1.2, 1.4, INK)
    _say("fill_arc_aa large pie wedge (r=260)", _changed(base, c))

    c = Canvas(W, H, WHITE)
    fill_ring_sector_aa(c, 400.0, 300.0, 150.0, 260.0, -1.2, 1.4, INK)
    _say("fill_ring_sector_aa large donut (150-260)", _changed(base, c))

    c = Canvas(W, H, WHITE)
    for i in range(2000):
        fill_arc_aa(
            c,
            20.0 + Float64((i * 37) % 760),
            20.0 + Float64((i * 53) % 560),
            4.0,
            -0.6,
            1.1,
            INK,
        )
    _say("fill_arc_aa x2000 small (r=4)", _changed(base, c))

    var poly = List[FPoint]()
    for i in range(64):
        var t = Float64(i) / 64.0 * 6.283185307179586
        poly.append(FPoint(400.0 + 250.0 * cos(t), 300.0 + 200.0 * sin(t)))
    c = Canvas(W, H, WHITE)
    fill_polygon_aa(c, poly, INK)
    _say("fill_polygon_aa 64-gon", _changed(base, c))

    var glyph = Path()
    glyph.move_to(10.0, 30.0)
    glyph.cubic_curve_to(14.0, 8.0, 26.0, 8.0, 30.0, 30.0)
    glyph.cubic_curve_to(26.0, 44.0, 14.0, 44.0, 10.0, 30.0)
    glyph.close()
    c = Canvas(W, H, WHITE)
    fill_path_aa(c, glyph, INK)
    _say("fill_path_aa glyph-sized", _changed(base, c))

    var big_path = Path()
    big_path.move_to(60.0, 500.0)
    for i in range(1, 40):
        var x = 60.0 + Float64(i) * 18.0
        big_path.quad_curve_to(x - 9.0, 120.0, x, 500.0)
    big_path.close()
    c = Canvas(W, H, WHITE)
    fill_path_aa(c, big_path, INK)
    _say("fill_path_aa large 39-curve", _changed(base, c))

    c = Canvas(W, H, WHITE)
    fill_path_aa(c, big_path, INK, FillRule.NONZERO)
    _say("fill_path_aa large 39-curve (nonzero)", _changed(base, c))

    c = Canvas(W, H, WHITE)
    c.push_clip(200, 150, 400, 300)
    fill_path_aa(c, big_path, INK)
    c.pop_clip()
    _say("fill_path_aa large under a clip rect", _changed(base, c))

    var grad = LinearGradient(0.0, 0.0, Float64(W), Float64(H))
    grad.add_stop(0.0, INK)
    grad.add_stop(1.0, Color(220, 90, 60))
    c = Canvas(W, H, WHITE)
    c.save()
    c.push_clip(300, 200, 100, 80)
    fill_path_gradient_aa(c, big_path, grad)
    c.restore()
    _say(
        "fill_path_gradient_aa 39-curve, clip misses the path",
        _changed(base, c),
    )

    c = Canvas(W, H, WHITE)
    c.save()
    c.push_clip(300, 400, 100, 80)
    fill_path_gradient_aa(c, big_path, grad)
    c.restore()
    _say("fill_path_gradient_aa 39-curve under a small clip", _changed(base, c))

    # --- strokes ---
    c = Canvas(W, H, WHITE)
    draw_line_aa(c, 30.0, 30.0, 770.0, 570.0, INK, width=2.0)
    _say("draw_line_aa full diagonal (w=2)", _changed(base, c))

    var series = List[FPoint]()
    for i in range(3000):
        series.append(
            FPoint(
                20.0 + Float64(i) * 0.25,
                300.0 + 180.0 * sin(Float64(i) * 0.21),
            )
        )
    c = Canvas(W, H, WHITE)
    draw_polyline_aa(c, series, INK, width=1.5)
    _say("draw_polyline_aa 3000-segment series", _changed(base, c))

    var smooth = List[FPoint]()
    for i in range(3000):
        smooth.append(
            FPoint(
                20.0 + Float64(i) * 0.25,
                300.0 + 180.0 * sin(Float64(i) * 0.005),
            )
        )
    c = Canvas(W, H, WHITE)
    draw_polyline_aa(c, smooth, INK, width=1.5)
    _say("draw_polyline_aa 3000-segment smooth series", _changed(base, c))

    var dashes: List[Float64] = [6.0, 4.0]
    c = Canvas(W, H, WHITE)
    draw_polyline_aa(c, series, INK, width=1.5, dashes=dashes)
    _say("draw_polyline_aa 3000-segment dashed", _changed(base, c))

    c = Canvas(W, H, WHITE)
    draw_line(c, 30, 30, 770, 570, INK, dashes=dashes)
    _say("draw_line dashed full diagonal", _changed(base, c))

    c = Canvas(W, H, WHITE)
    draw_line(c, 30, 30, 770, 570, INK)
    _say("draw_line solid full diagonal", _changed(base, c))

    c = Canvas(W, H, WHITE)
    stroke_path_aa(c, big_path, INK, width=2.0)
    _say("stroke_path_aa 39-curve path", _changed(base, c))

    # --- text ---
    var cache = FontCache()
    var paragraph = String(
        "The quick brown fox jumps over the lazy dog\n"
        "0123456789 -- axis labels, legends, titles\n"
        "Handgloves ABCDEFG abcdefg"
    )
    c = Canvas(W, H, WHITE)
    draw_text(c, 40.0, 100.0, paragraph, INK, size=13.0, cache=cache)
    _say("draw_text 3 lines @13px (cached)", _changed(base, c))

    var label_arc = Path()
    label_arc.move_to(400.0 + 260.0, 320.0)
    label_arc.arc_to(400.0, 320.0, 260.0, 0.0, pi / 2.0)
    c = Canvas(W, H, WHITE)
    draw_text_on_path(
        c, label_arc, String("Twenty glyphs on arc"), INK, 20.0, cache=cache
    )
    _say("draw_text_on_path 20 glyphs on an arc", _changed(base, c))

    # --- transformed compositing ---
    var tile = Canvas(200, 200, Color(240, 240, 245))
    fill_circle_aa(tile, 100.0, 100.0, 80.0, INK)
    fill_rect(tile, 20, 20, 60, 40, Color(220, 90, 60))
    var placed = (
        Matrix2D.scaling(1.7, 1.7)
        .then(Matrix2D.rotation(pi / 6.0))
        .then(Matrix2D.translation(300.0, 120.0))
    )
    c = Canvas(W, H, WHITE)
    draw_canvas(c, tile, placed, filter=Filter.NEAREST)
    _say("draw_canvas 200x200 1.7x rot 30 nearest", _changed(base, c))

    c = Canvas(W, H, WHITE)
    draw_canvas(c, tile, placed, filter=Filter.BILINEAR)
    _say("draw_canvas 200x200 1.7x rot 30 bilinear", _changed(base, c))
