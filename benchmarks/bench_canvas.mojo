"""A benchmark suite for the drawing primitives, run with
`pixi run bench`.

Constants in the source marked "set by benchmark (#NN)" were tuned
with this file; the named pull request carries the numbers.

It is a stopwatch, not a statistics package. Each case runs a warmup
pass, then `iters` timed passes, and reports nanoseconds per iteration.
There is no distribution, no outlier rejection, and no significance
test; treat a change under about 10% as noise unless it repeats. Its use
is running it before and after a change and seeing which way a number
moved. For a change to one primitive, micro_canvas.mojo (`pixi run
micro`) times that primitive in interleaved rounds and reports a median
with its spread; quote that in the pull request rather than a row from
here.

Every case ends by reading a pixel back out of the canvas it drew into
and folding that into a checksum the suite prints. That is a sink rather
than a correctness check: without it the optimizer can delete the
drawing it was asked to time. An empty loop measured 50ns for a million
iterations here before the sink was added.

Sizes are chart-shaped rather than maximal: an 800x600 surface, a
scatter of a few thousand markers, a series with a few thousand
segments, a paragraph of real text.

## Reference numbers

A run compares rows only with each other, so a row that doubled in an
earlier release looks like the number rather than a doubled one --
which is how #251 made large nonzero fills 2.3x slower for four
releases until dataviz_mojo bisected canvas versions (dataviz #329).
`benchmarks/reference.txt` is the memory this file lacks: every row's
time on one named machine, written by `pixi run bench-record` and
read by `pixi run bench-check`, which runs the survey twice, keeps
each row's faster time, and fails on any row more than
`_REGRESSION_FACTOR` slower than its reference. Run the check before
tagging a release; re-record after a change that moved rows on
purpose, on a quiet machine. The file is keyed to the machine it was
recorded on (CPU model and thread count); on another machine the
check reports that and passes, since absolute numbers do not carry
across hardware.
"""

from std.math import cos, pi, sin
from std.os import getenv
from std.runtime.asyncrt import parallelism_level
from std.time import perf_counter_ns

from canvas.blend import BlendMode
from canvas.blur import blur
from canvas.buffer import Canvas, BYTES_PER_PIXEL
from canvas.color import Color
from canvas.compose import Filter, draw_canvas
from canvas.fill_rule import FillRule
from canvas.geometry import FPoint, Matrix2D, Point
from canvas.gradient import ConicGradient, LinearGradient, RadialGradient
from canvas.mask import Mask
from canvas.path import (
    Path,
    fill_path_aa,
    fill_path_conic_gradient_aa,
    fill_path_gradient_aa,
    fill_path_radial_gradient_aa,
    stroke_path_aa,
)
from canvas.io.png import write_png, read_png
from canvas.resize import downsample, resize
from canvas.shapes.arcs import (
    fill_arc_aa,
    fill_arcs_aa,
    fill_ring_sector_aa,
)
from canvas.shapes.circles import fill_circle_aa, fill_circles_aa
from canvas.shapes.ellipses import fill_ellipse_aa, fill_ellipses_aa
from canvas.shapes.lines import draw_line, draw_line_aa, draw_polyline_aa
from canvas.shapes.polygon_fill import fill_polygon_aa
from canvas.shapes.rects import fill_rect
from canvas.text.font_cache import FontCache
from canvas.text.render import (
    draw_layout,
    draw_text,
    draw_text_on_path,
    measure_layout,
    measure_text,
    measure_text_block,
    prepare_text,
)

comptime W = 800
comptime H = 600
comptime WHITE = Color(255, 255, 255)
comptime INK = Color(30, 60, 120)
comptime TRANSLUCENT = Color(30, 60, 120, 128)


struct _Row(ImplicitlyCopyable, Movable):
    var name: String
    var ns_per_iter: Float64
    var iters: Int

    def __init__(out self, name: String, ns_per_iter: Float64, iters: Int):
        self.name = name
        self.ns_per_iter = ns_per_iter
        self.iters = iters


def _pad(text: String, width: Int) -> String:
    var out = text
    while out.byte_length() < width:
        out += " "
    return out


def _lpad(text: String, width: Int) -> String:
    var out = text
    while out.byte_length() < width:
        out = " " + out
    return out


def _fixed(value: Float64, places: Int) -> String:
    """`value` rendered with exactly `places` decimals. Mojo's default
    Float64 formatting is full precision, which makes a column of
    timings unreadable.
    """
    var scale = 1.0
    for _ in range(places):
        scale *= 10.0
    var scaled = Int(value * scale + 0.5)
    var whole = scaled // Int(scale)
    var frac = scaled - whole * Int(scale)
    var frac_text = String(frac)
    while frac_text.byte_length() < places:
        frac_text = "0" + frac_text
    return String(whole) + "." + frac_text


def _report(mut rows: List[_Row], name: String, elapsed_ns: Int, iters: Int):
    rows.append(_Row(name, Float64(elapsed_ns) / Float64(iters), iters))


def _print_table(rows: List[_Row]):
    var name_w = 4
    for i in range(len(rows)):
        if rows[i].name.byte_length() > name_w:
            name_w = rows[i].name.byte_length()

    print("")
    print(_pad("case", name_w), _lpad("iters", 8), _lpad("us/iter", 14))
    var rule = String("")
    for _ in range(name_w + 8 + 14 + 2):
        rule += "-"
    print(rule)
    for i in range(len(rows)):
        ref r = rows[i]
        print(
            _pad(r.name, name_w),
            _lpad(String(r.iters), 8),
            _lpad(_fixed(r.ns_per_iter / 1000.0, 3), 14),
        )
    print(rule)


def _survey() raises -> List[_Row]:
    """One pass over every case: the rows, in order."""
    var rows = List[_Row]()
    var sink = 0

    # --- buffer -------------------------------------------------------
    # Allocation + solid fill, the cost every render pays before it
    # draws anything.
    var c0 = Canvas(W, H, WHITE)
    sink += Int(c0.get_pixel(0, 0).r)
    var iters = 200
    var t0 = perf_counter_ns()
    for _ in range(iters):
        var c = Canvas(W, H, WHITE)
        sink += Int(c.get_pixel(0, 0).r)
    _report(
        rows, "Canvas(800x600) construct+fill", perf_counter_ns() - t0, iters
    )

    var canvas = Canvas(W, H, WHITE)
    iters = 200
    t0 = perf_counter_ns()
    for _ in range(iters):
        canvas.fill(INK)
        sink += Int(canvas.get_pixel(0, 0).r)
    _report(rows, "Canvas.fill opaque", perf_counter_ns() - t0, iters)

    iters = 200
    t0 = perf_counter_ns()
    for _ in range(iters):
        canvas.fill(TRANSLUCENT)
        sink += Int(canvas.get_pixel(0, 0).r)
    _report(
        rows, "Canvas.fill translucent (blend)", perf_counter_ns() - t0, iters
    )

    iters = 500
    t0 = perf_counter_ns()
    for _ in range(iters):
        fill_rect(canvas, 40, 40, 600, 400, INK)
        sink += Int(canvas.get_pixel(50, 50).r)
    _report(rows, "fill_rect 600x400 opaque", perf_counter_ns() - t0, iters)

    # The same fill under a blend mode, which cannot take the packed
    # store and goes through write_pixel per pixel -- the cost of any
    # mode but source-over.
    canvas.set_blend_mode(BlendMode.MULTIPLY)
    iters = 100
    t0 = perf_counter_ns()
    for _ in range(iters):
        fill_rect(canvas, 40, 40, 600, 400, INK)
        sink += Int(canvas.get_pixel(50, 50).r)
    _report(rows, "fill_rect 600x400 multiply", perf_counter_ns() - t0, iters)
    canvas.set_blend_mode(BlendMode.SOURCE_OVER)

    # --- anti-aliased fills -------------------------------------------
    # A scatter plot's markers: many small disks, where per-call
    # overhead matters more than per-pixel throughput.
    iters = 40
    t0 = perf_counter_ns()
    for _ in range(iters):
        for i in range(2000):
            var fx = 20.0 + Float64((i * 37) % 760)
            var fy = 20.0 + Float64((i * 53) % 560)
            fill_circle_aa(canvas, fx, fy, 3.5, INK)
        sink += Int(canvas.get_pixel(100, 100).r)
    _report(
        rows,
        "fill_circle_aa x2000 markers (r=3.5)",
        perf_counter_ns() - t0,
        iters,
    )

    # The same 2000 markers through the batch entry point, which bands
    # the canvas instead of drawing one at a time (#290). Centers are
    # fractional here, unlike the row above, so no two markers share a
    # sub-pixel phase.
    var marker_centers = List[FPoint](capacity=2000)
    for i in range(2000):
        marker_centers.append(
            FPoint(
                20.0 + Float64((i * 37) % 7600) * 0.1,
                20.0 + Float64((i * 53) % 5600) * 0.1,
            )
        )
    t0 = perf_counter_ns()
    for _ in range(iters):
        fill_circles_aa(canvas, marker_centers, 3.5, INK)
        sink += Int(canvas.get_pixel(100, 100).r)
    _report(
        rows,
        "fill_circles_aa x2000 markers batched (r=3.5)",
        perf_counter_ns() - t0,
        iters,
    )

    # The same batch at a radius past the closed-form limit, which is
    # where a supersampling caller's markers land (#340). Until the
    # row-restricted polygon sweep this fell back to one call each and
    # batching bought nothing at all.
    t0 = perf_counter_ns()
    for _ in range(iters):
        fill_circles_aa(canvas, marker_centers, 10.5, INK)
        sink += Int(canvas.get_pixel(100, 100).r)
    _report(
        rows,
        "fill_circles_aa x2000 markers batched (r=10.5)",
        perf_counter_ns() - t0,
        iters,
    )

    iters = 200
    t0 = perf_counter_ns()
    for _ in range(iters):
        fill_circle_aa(canvas, 400.0, 300.0, 250.0, INK)
        sink += Int(canvas.get_pixel(400, 300).r)
    _report(
        rows, "fill_circle_aa one large (r=250)", perf_counter_ns() - t0, iters
    )

    iters = 200
    t0 = perf_counter_ns()
    for _ in range(iters):
        fill_ellipse_aa(canvas, 400.0, 300.0, 340.0, 220.0, INK)
        sink += Int(canvas.get_pixel(400, 300).r)
    _report(
        rows,
        "fill_ellipse_aa one large (340x220)",
        perf_counter_ns() - t0,
        iters,
    )

    iters = 40
    t0 = perf_counter_ns()
    for _ in range(iters):
        for i in range(2000):
            var ex = 20.0 + Float64((i * 37) % 760)
            var ey = 20.0 + Float64((i * 53) % 560)
            fill_ellipse_aa(canvas, ex, ey, 5.0, 3.0, INK)
        sink += Int(canvas.get_pixel(100, 100).r)
    _report(
        rows, "fill_ellipse_aa x2000 small (5x3)", perf_counter_ns() - t0, iters
    )

    # The same 2000 markers through the batch entry point, which bands
    # the canvas instead of the markers -- the ellipse counterpart of
    # the batched disks above. Centers are fractional here, so no two
    # markers share a sub-pixel phase.
    var ellipse_centers = List[FPoint](capacity=2000)
    for i in range(2000):
        ellipse_centers.append(
            FPoint(
                20.0 + Float64((i * 37) % 7600) * 0.1,
                20.0 + Float64((i * 53) % 5600) * 0.1,
            )
        )
    t0 = perf_counter_ns()
    for _ in range(iters):
        fill_ellipses_aa(canvas, ellipse_centers, 5.0, 3.0, INK)
        sink += Int(canvas.get_pixel(100, 100).r)
    _report(
        rows,
        "fill_ellipses_aa x2000 markers batched (5x3)",
        perf_counter_ns() - t0,
        iters,
    )

    # Pie and donut segments, the shapes a chart makes most of these
    # for. A near-half sweep specifically, since the wedge's
    # provably-inside fast path is guarded on sweep width.
    iters = 100
    t0 = perf_counter_ns()
    for _ in range(iters):
        fill_arc_aa(canvas, 400.0, 300.0, 260.0, -1.2, 1.4, INK)
        sink += Int(canvas.get_pixel(420, 300).r)
    _report(
        rows,
        "fill_arc_aa large pie wedge (r=260)",
        perf_counter_ns() - t0,
        iters,
    )

    iters = 100
    t0 = perf_counter_ns()
    for _ in range(iters):
        fill_ring_sector_aa(canvas, 400.0, 300.0, 150.0, 260.0, -1.2, 1.4, INK)
        sink += Int(canvas.get_pixel(400, 100).r)
    _report(
        rows,
        "fill_ring_sector_aa large donut (150-260)",
        perf_counter_ns() - t0,
        iters,
    )

    # Many small wedges, to check the banding threshold does not tax
    # the case it is meant to leave alone.
    iters = 40
    t0 = perf_counter_ns()
    for _ in range(iters):
        for i in range(2000):
            var wx = 20.0 + Float64((i * 37) % 760)
            var wy = 20.0 + Float64((i * 53) % 560)
            fill_arc_aa(canvas, wx, wy, 4.0, -0.6, 1.1, INK)
        sink += Int(canvas.get_pixel(100, 100).r)
    _report(
        rows, "fill_arc_aa x2000 small (r=4)", perf_counter_ns() - t0, iters
    )

    # The same 2000 wedges through the batch entry point, which bands
    # the canvas instead of the wedges.
    var wedge_centers = List[FPoint](capacity=2000)
    for i in range(2000):
        wedge_centers.append(
            FPoint(
                20.0 + Float64((i * 37) % 7600) * 0.1,
                20.0 + Float64((i * 53) % 5600) * 0.1,
            )
        )
    t0 = perf_counter_ns()
    for _ in range(iters):
        fill_arcs_aa(canvas, wedge_centers, 4.0, -0.6, 1.1, INK)
        sink += Int(canvas.get_pixel(100, 100).r)
    _report(
        rows,
        "fill_arcs_aa x2000 wedges batched (r=4)",
        perf_counter_ns() - t0,
        iters,
    )

    var poly = List[FPoint]()
    for i in range(64):
        var t = Float64(i) / 64.0 * 6.283185307179586
        poly.append(FPoint(400.0 + 250.0 * cos(t), 300.0 + 200.0 * sin(t)))
    iters = 100
    t0 = perf_counter_ns()
    for _ in range(iters):
        fill_polygon_aa(canvas, poly, INK)
        sink += Int(canvas.get_pixel(400, 300).r)
    _report(rows, "fill_polygon_aa 64-gon", perf_counter_ns() - t0, iters)

    # A glyph-sized path: the case the AA sweep's buffer reuse was
    # tuned for, and the one text rendering hits thousands of times.
    var glyph = Path()
    glyph.move_to(10.0, 30.0)
    glyph.cubic_curve_to(14.0, 8.0, 26.0, 8.0, 30.0, 30.0)
    glyph.cubic_curve_to(26.0, 44.0, 14.0, 44.0, 10.0, 30.0)
    glyph.close()
    iters = 2000
    t0 = perf_counter_ns()
    for _ in range(iters):
        fill_path_aa(canvas, glyph, INK)
        sink += Int(canvas.get_pixel(20, 30).r)
    _report(rows, "fill_path_aa glyph-sized", perf_counter_ns() - t0, iters)

    # The same glyph under NONZERO: the exact-area rasterizer, which is
    # what text goes through.
    t0 = perf_counter_ns()
    for _ in range(iters):
        fill_path_aa(canvas, glyph, INK, FillRule.NONZERO)
        sink += Int(canvas.get_pixel(20, 30).r)
    _report(
        rows,
        "fill_path_aa glyph-sized (nonzero)",
        perf_counter_ns() - t0,
        iters,
    )

    var big_path = Path()
    big_path.move_to(60.0, 500.0)
    for i in range(1, 40):
        var x = 60.0 + Float64(i) * 18.0
        big_path.quad_curve_to(x - 9.0, 120.0, x, 500.0)
    big_path.close()
    iters = 60
    t0 = perf_counter_ns()
    for _ in range(iters):
        fill_path_aa(canvas, big_path, INK)
        sink += Int(canvas.get_pixel(400, 400).r)
    _report(rows, "fill_path_aa large 39-curve", perf_counter_ns() - t0, iters)

    t0 = perf_counter_ns()
    for _ in range(iters):
        fill_path_aa(canvas, big_path, INK, FillRule.NONZERO)
        sink += Int(canvas.get_pixel(400, 400).r)
    _report(
        rows,
        "fill_path_aa large 39-curve (nonzero)",
        perf_counter_ns() - t0,
        iters,
    )

    # The same fill with most of it clipped away: what a series drawn
    # past its plot area costs. The rows outside the clip should cost
    # nothing.
    canvas.push_clip(200, 150, 400, 300)
    iters = 60
    t0 = perf_counter_ns()
    for _ in range(iters):
        fill_path_aa(canvas, big_path, INK)
        sink += Int(canvas.get_pixel(400, 400).r)
    _report(
        rows,
        "fill_path_aa large under a clip rect",
        perf_counter_ns() - t0,
        iters,
    )
    canvas.pop_clip()

    # Gradient-sourced path fills go through a coverage mask first;
    # the small case is where the mask's own size shows.
    var gradient = LinearGradient(0.0, 0.0, Float64(W), Float64(H))
    gradient.add_stop(0.0, INK)
    gradient.add_stop(1.0, Color(220, 90, 60))
    iters = 2000
    t0 = perf_counter_ns()
    for _ in range(iters):
        fill_path_gradient_aa(canvas, glyph, gradient)
        sink += Int(canvas.get_pixel(20, 30).r)
    _report(
        rows, "fill_path_gradient_aa glyph-sized", perf_counter_ns() - t0, iters
    )

    iters = 60
    t0 = perf_counter_ns()
    for _ in range(iters):
        fill_path_gradient_aa(canvas, big_path, gradient)
        sink += Int(canvas.get_pixel(400, 400).r)
    _report(
        rows,
        "fill_path_gradient_aa large 39-curve",
        perf_counter_ns() - t0,
        iters,
    )

    # The same path behind a small rectangular clip. The coverage mask
    # is allocated and swept for the clip's intersection with the path
    # bounds rather than the whole path (#320), so this row tracks a
    # cost that used to be the row above's regardless of how little
    # was visible.
    #
    # Two clips, because they measure different things and the first
    # one alone was read as the second for two releases. The path is
    # 39 arches rising to y=120 from a base at y=500, so a window high
    # up sits in the gap between two arches and the fill paints
    # nothing at all: that row is the cost of flattening the curves
    # and finding there is no coverage, which is worth knowing but is
    # not what "under a small clip" sounds like. The window lower down
    # is about 70% covered, and is the one that measures painting
    # through an intersecting clip.
    iters = 200
    t0 = perf_counter_ns()
    for _ in range(iters):
        canvas.save()
        canvas.push_clip(300, 200, 100, 80)
        fill_path_gradient_aa(canvas, big_path, gradient)
        canvas.restore()
        sink += Int(canvas.get_pixel(350, 240).r)
    _report(
        rows,
        "fill_path_gradient_aa 39-curve, clip misses the path",
        perf_counter_ns() - t0,
        iters,
    )

    iters = 200
    t0 = perf_counter_ns()
    for _ in range(iters):
        canvas.save()
        canvas.push_clip(300, 400, 100, 80)
        fill_path_gradient_aa(canvas, big_path, gradient)
        canvas.restore()
        sink += Int(canvas.get_pixel(350, 440).r)
    _report(
        rows,
        "fill_path_gradient_aa 39-curve under a small clip",
        perf_counter_ns() - t0,
        iters,
    )

    # RadialGradient's projection is a sqrt per pixel; ConicGradient's
    # is an atan2 per pixel. Same shapes as the linear rows above, so
    # the three are directly comparable.
    var radial = RadialGradient(Float64(W) / 2.0, Float64(H) / 2.0, Float64(H))
    radial.add_stop(0.0, INK)
    radial.add_stop(1.0, Color(220, 90, 60))
    iters = 2000
    t0 = perf_counter_ns()
    for _ in range(iters):
        fill_path_radial_gradient_aa(canvas, glyph, radial)
        sink += Int(canvas.get_pixel(20, 30).r)
    _report(
        rows,
        "fill_path_radial_gradient_aa glyph-sized",
        perf_counter_ns() - t0,
        iters,
    )

    iters = 60
    t0 = perf_counter_ns()
    for _ in range(iters):
        fill_path_radial_gradient_aa(canvas, big_path, radial)
        sink += Int(canvas.get_pixel(400, 400).r)
    _report(
        rows,
        "fill_path_radial_gradient_aa large 39-curve",
        perf_counter_ns() - t0,
        iters,
    )

    var conic = ConicGradient(Float64(W) / 2.0, Float64(H) / 2.0, 0.0)
    conic.add_stop(0.0, INK)
    conic.add_stop(1.0, Color(220, 90, 60))
    iters = 2000
    t0 = perf_counter_ns()
    for _ in range(iters):
        fill_path_conic_gradient_aa(canvas, glyph, conic)
        sink += Int(canvas.get_pixel(20, 30).r)
    _report(
        rows,
        "fill_path_conic_gradient_aa glyph-sized",
        perf_counter_ns() - t0,
        iters,
    )

    iters = 60
    t0 = perf_counter_ns()
    for _ in range(iters):
        fill_path_conic_gradient_aa(canvas, big_path, conic)
        sink += Int(canvas.get_pixel(400, 400).r)
    _report(
        rows,
        "fill_path_conic_gradient_aa large 39-curve",
        perf_counter_ns() - t0,
        iters,
    )

    # --- strokes -------------------------------------------------------
    iters = 400
    t0 = perf_counter_ns()
    for _ in range(iters):
        draw_line_aa(canvas, 30.0, 30.0, 770.0, 570.0, INK, width=2.0)
        sink += Int(canvas.get_pixel(400, 300).r)
    _report(
        rows, "draw_line_aa full diagonal (w=2)", perf_counter_ns() - t0, iters
    )

    var series = List[FPoint]()
    for i in range(3000):
        var x = 20.0 + Float64(i) * 0.25
        var y = 300.0 + 180.0 * sin(Float64(i) * 0.21)
        series.append(FPoint(x, y))
    iters = 20
    t0 = perf_counter_ns()
    for _ in range(iters):
        draw_polyline_aa(canvas, series, INK, width=1.5)
        sink += Int(canvas.get_pixel(400, 300).r)
    _report(
        rows,
        "draw_polyline_aa 3000-segment series",
        perf_counter_ns() - t0,
        iters,
    )

    # The same length of line without the hairpins: a gentle sine whose
    # outline is simple, so it rasterizes by exact area. The series
    # above turns through nearly 180 degrees at every peak and takes the
    # sampled fallback; a chart's series can be either.
    var smooth = List[FPoint]()
    for i in range(3000):
        var x = 20.0 + Float64(i) * 0.25
        var y = 300.0 + 180.0 * sin(Float64(i) * 0.005)
        smooth.append(FPoint(x, y))
    t0 = perf_counter_ns()
    for _ in range(iters):
        draw_polyline_aa(canvas, smooth, INK, width=1.5)
        sink += Int(canvas.get_pixel(400, 300).r)
    _report(
        rows,
        "draw_polyline_aa 3000-segment smooth series",
        perf_counter_ns() - t0,
        iters,
    )

    # Dashed strokes query the dash pattern per piece (AA) or per pixel
    # (Bresenham), so the pattern's own cost shows here and nowhere
    # else.
    var dashes: List[Float64] = [6.0, 4.0]
    iters = 20
    t0 = perf_counter_ns()
    for _ in range(iters):
        draw_polyline_aa(canvas, series, INK, width=1.5, dashes=dashes)
        sink += Int(canvas.get_pixel(400, 300).r)
    _report(
        rows,
        "draw_polyline_aa 3000-segment dashed",
        perf_counter_ns() - t0,
        iters,
    )

    iters = 400
    t0 = perf_counter_ns()
    for _ in range(iters):
        draw_line(canvas, 30, 30, 770, 570, INK, dashes=dashes)
        sink += Int(canvas.get_pixel(400, 300).r)
    _report(
        rows, "draw_line dashed full diagonal", perf_counter_ns() - t0, iters
    )

    # The solid counterpart of the row above: same Bresenham walk with
    # no dash pattern, which is what every caller that omits `dashes`
    # runs.
    iters = 400
    t0 = perf_counter_ns()
    for _ in range(iters):
        draw_line(canvas, 30, 30, 770, 570, INK)
        sink += Int(canvas.get_pixel(400, 300).r)
    _report(
        rows, "draw_line solid full diagonal", perf_counter_ns() - t0, iters
    )

    iters = 200
    t0 = perf_counter_ns()
    for _ in range(iters):
        stroke_path_aa(canvas, big_path, INK, width=2.0)
        sink += Int(canvas.get_pixel(400, 400).r)
    _report(rows, "stroke_path_aa 39-curve path", perf_counter_ns() - t0, iters)

    # --- text ----------------------------------------------------------
    # Through a shared FontCache, which is how a real caller draws more
    # than one string -- without it this measures font discovery, not
    # rasterization.
    var cache = FontCache()
    var paragraph = String(
        "The quick brown fox jumps over the lazy dog\n"
        "0123456789 -- axis labels, legends, titles\n"
        "Handgloves ABCDEFG abcdefg"
    )
    draw_text(canvas, 40.0, 100.0, paragraph, INK, size=13.0, cache=cache)
    iters = 40
    t0 = perf_counter_ns()
    for _ in range(iters):
        draw_text(canvas, 40.0, 100.0, paragraph, INK, size=13.0, cache=cache)
        sink += Int(canvas.get_pixel(45, 95).r)
    _report(
        rows, "draw_text 3 lines @13px (cached)", perf_counter_ns() - t0, iters
    )

    # The same paragraph through the overload that takes no cache --
    # the shortest call to write, and the one a reader reaches for
    # first. It builds a FontCache internally, so every call rescans
    # every font file installed on the machine.
    #
    # Timed separately from that scan below, because the two answer
    # different questions: this one is what a caller pays per label,
    # and the constructor is the one-time cost the cached path pays
    # instead. Neither is a rasterization measurement.
    iters = 5
    t0 = perf_counter_ns()
    for _ in range(iters):
        draw_text(canvas, 40.0, 100.0, paragraph, INK, size=13.0)
        sink += Int(canvas.get_pixel(45, 95).r)
    _report(
        rows,
        "draw_text 3 lines @13px (uncached)",
        perf_counter_ns() - t0,
        iters,
    )

    # Text along a curve: 20 glyphs on a quarter-circle arc, through
    # the same shared cache. Every glyph here is rotated, so none of
    # them takes the glyph mask cache and each fills its own outline --
    # compare it against the cached draw_text row above, not the
    # uncached one.
    var label_arc = Path()
    label_arc.move_to(400.0 + 260.0, 320.0)
    label_arc.arc_to(400.0, 320.0, 260.0, 0.0, pi / 2.0)
    var curved = String("Twenty glyphs on arc")
    draw_text_on_path(canvas, label_arc, curved, INK, 20.0, cache=cache)
    iters = 40
    t0 = perf_counter_ns()
    for _ in range(iters):
        draw_text_on_path(canvas, label_arc, curved, INK, 20.0, cache=cache)
        sink += Int(canvas.get_pixel(650, 340).r)
    _report(
        rows,
        "draw_text_on_path 20 glyphs on an arc",
        perf_counter_ns() - t0,
        iters,
    )

    # What the cached path pays once and the uncached path pays per
    # call. Scales with the number of font files installed, so it is a
    # property of the machine as much as of this code -- compare it
    # against the uncached row above rather than reading it alone.
    iters = 5
    t0 = perf_counter_ns()
    for _ in range(iters):
        var scan = FontCache()
        _ = scan^
    _report(rows, "FontCache() font scan", perf_counter_ns() - t0, iters)

    # --- image i/o -----------------------------------------------------
    var scene = Canvas(W, H, WHITE)
    fill_rect(scene, 0, 0, W, H // 2, INK)
    fill_circle_aa(scene, 400.0, 300.0, 180.0, Color(220, 90, 60))
    var png_path = String("benchmarks/_bench_out.png")
    write_png(scene, png_path)
    iters = 20
    t0 = perf_counter_ns()
    for _ in range(iters):
        write_png(scene, png_path)
    _report(rows, "write_png 800x600 (deflate)", perf_counter_ns() - t0, iters)

    iters = 20
    t0 = perf_counter_ns()
    for _ in range(iters):
        var back = read_png(png_path)
        sink += Int(back.get_pixel(0, 0).r)
    _report(rows, "read_png 800x600 (inflate)", perf_counter_ns() - t0, iters)

    # --- resize --------------------------------------------------------
    var supersampled = Canvas(W * 2, H * 2, WHITE)
    fill_circle_aa(supersampled, 800.0, 600.0, 500.0, INK)
    iters = 40
    t0 = perf_counter_ns()
    for _ in range(iters):
        var small = downsample(supersampled, 2)
        sink += Int(small.get_pixel(10, 10).r)
    _report(rows, "downsample 1600x1200 -> 2x", perf_counter_ns() - t0, iters)

    # Factor 3, the ratio a supersampling consumer reaches for by
    # default (#364). It has its own row because it was the one common
    # factor with no fixed-size kernel, and nothing in the suite
    # pointed at it.
    var super3 = Canvas(W * 3, H * 3, WHITE)
    fill_circle_aa(super3, 1200.0, 900.0, 750.0, INK)
    iters = 20
    t0 = perf_counter_ns()
    for _ in range(iters):
        var small3 = downsample(super3, 3)
        sink += Int(small3.get_pixel(10, 10).r)
    _report(rows, "downsample 2400x1800 -> 3x", perf_counter_ns() - t0, iters)

    # The same reduction through the arbitrary-size path, which cannot
    # use the fixed-factor kernels and carries a Float64 intermediate
    # (#298), and then one no integer factor can express. The pair
    # says what the generality costs.
    iters = 5
    t0 = perf_counter_ns()
    for _ in range(iters):
        var same = resize(supersampled, 800, 600)
        sink += Int(same.get_pixel(10, 10).r)
    _report(rows, "resize 1600x1200 -> 800x600", perf_counter_ns() - t0, iters)

    t0 = perf_counter_ns()
    for _ in range(iters):
        var odd = resize(supersampled, 741, 533)
        sink += Int(odd.get_pixel(10, 10).r)
    _report(rows, "resize 1600x1200 -> 741x533", perf_counter_ns() - t0, iters)

    # --- blur ------------------------------------------------------
    # blur() runs the same three box-blur passes whatever the radius --
    # only the derived box widths change, and each pass is a sliding
    # window sum that costs the same however wide its box is (see
    # blur.mojo's _box_blur_line) -- so r=4 and r=16 are timed
    # separately to show the cost is flat across radius, not to compare
    # them as a quality/speed tradeoff.
    var blur_source = Canvas(W, H, WHITE)
    fill_circle_aa(blur_source, 400.0, 300.0, 250.0, INK)
    fill_rect(blur_source, 100, 100, 200, 150, TRANSLUCENT)

    iters = 20
    t0 = perf_counter_ns()
    for _ in range(iters):
        var c = Canvas(W, H, blur_source.pixels.copy())
        blur(c, 4.0)
        sink += Int(c.get_pixel(400, 300).r)
    _report(rows, "blur 800x600 r=4", perf_counter_ns() - t0, iters)

    t0 = perf_counter_ns()
    for _ in range(iters):
        var c = Canvas(W, H, blur_source.pixels.copy())
        blur(c, 16.0)
        sink += Int(c.get_pixel(400, 300).r)
    _report(rows, "blur 800x600 r=16", perf_counter_ns() - t0, iters)

    # --- clipping --------------------------------------------------
    # A clip path is a whole-canvas coverage mask plus a per-pixel
    # masked write for everything drawn inside it, which is the shape
    # a chart clipping a series to its plot area pays.
    var clip_path = Path()
    clip_path.rect(60.0, 60.0, 680.0, 480.0)
    iters = 100
    t0 = perf_counter_ns()
    for _ in range(iters):
        canvas.push_clip_path(clip_path)
        canvas.pop_clip_path()
        sink += Int(canvas.get_pixel(400, 300).r)
    _report(rows, "push_clip_path rect mask", perf_counter_ns() - t0, iters)

    canvas.push_clip_path(clip_path)
    iters = 20
    t0 = perf_counter_ns()
    for _ in range(iters):
        for i in range(2000):
            var cx = 20.0 + Float64((i * 37) % 760)
            var cy = 20.0 + Float64((i * 53) % 560)
            fill_circle_aa(canvas, cx, cy, 3.5, INK)
        sink += Int(canvas.get_pixel(400, 300).r)
    _report(
        rows,
        "fill_circle_aa x2000 under a clip path",
        perf_counter_ns() - t0,
        iters,
    )
    canvas.pop_clip_path()

    # The rectangle clip for comparison: a range test, not a mask, so
    # this is what the mask above costs over the cheap kind of clip.
    canvas.push_clip(60, 60, 680, 480)
    iters = 20
    t0 = perf_counter_ns()
    for _ in range(iters):
        for i in range(2000):
            var rx = 20.0 + Float64((i * 37) % 760)
            var ry = 20.0 + Float64((i * 53) % 560)
            fill_circle_aa(canvas, rx, ry, 3.5, INK)
        sink += Int(canvas.get_pixel(400, 300).r)
    _report(
        rows,
        "fill_circle_aa x2000 under a clip rect",
        perf_counter_ns() - t0,
        iters,
    )
    canvas.pop_clip()

    # --- compositing -----------------------------------------------
    # Layers: each part of a figure drawn onto its own transparent
    # canvas and composed in order.
    var layer = Canvas(W, H, Color(0, 0, 0, 0))
    fill_circle_aa(layer, 400.0, 300.0, 200.0, TRANSLUCENT)
    var opaque_layer = Canvas(W, H, WHITE)
    iters = 100
    t0 = perf_counter_ns()
    for _ in range(iters):
        draw_canvas(canvas, opaque_layer, 0, 0)
        sink += Int(canvas.get_pixel(400, 300).r)
    _report(rows, "draw_canvas 800x600 opaque", perf_counter_ns() - t0, iters)

    iters = 100
    t0 = perf_counter_ns()
    for _ in range(iters):
        draw_canvas(canvas, layer, 0, 0)
        sink += Int(canvas.get_pixel(400, 300).r)
    _report(
        rows, "draw_canvas 800x600 translucent", perf_counter_ns() - t0, iters
    )

    iters = 100
    t0 = perf_counter_ns()
    for _ in range(iters):
        draw_canvas(canvas, layer, 0, 0, 128)
        sink += Int(canvas.get_pixel(400, 300).r)
    _report(
        rows,
        "draw_canvas 800x600 at half opacity",
        perf_counter_ns() - t0,
        iters,
    )

    # Through a mask, the overload a layer effect uses. Timed
    # separately because it takes a different route entirely: the
    # coverage multiplies into the source alpha as the composite runs.
    var layer_mask = Mask(W, H)
    var lmp = layer_mask.coverage.unsafe_ptr()
    for i in range(W * H):
        lmp[unsafe_offset=i] = UInt8((i * 7) & 0xFF)
    iters = 100
    t0 = perf_counter_ns()
    for _ in range(iters):
        draw_canvas(canvas, layer, 0, 0, layer_mask)
        sink += Int(canvas.get_pixel(400, 300).r)
    _report(
        rows,
        "draw_canvas 800x600 through a mask",
        perf_counter_ns() - t0,
        iters,
    )

    # A tile drawn through a matrix: every destination pixel in the
    # mapped rectangle's bounding box is inverse-mapped and sampled,
    # so the work is per destination pixel and the filter decides how
    # many source reads each one costs.
    var tile = Canvas(200, 200, Color(240, 240, 245))
    fill_circle_aa(tile, 100.0, 100.0, 80.0, INK)
    fill_rect(tile, 20, 20, 60, 40, Color(220, 90, 60))
    var placed = (
        Matrix2D.scaling(1.7, 1.7)
        .then(Matrix2D.rotation(pi / 6.0))
        .then(Matrix2D.translation(300.0, 120.0))
    )

    iters = 100
    t0 = perf_counter_ns()
    for _ in range(iters):
        draw_canvas(canvas, tile, placed, filter=Filter.NEAREST)
        sink += Int(canvas.get_pixel(400, 300).r)
    _report(
        rows,
        "draw_canvas 200x200 1.7x rot 30 nearest",
        perf_counter_ns() - t0,
        iters,
    )

    iters = 100
    t0 = perf_counter_ns()
    for _ in range(iters):
        draw_canvas(canvas, tile, placed, filter=Filter.BILINEAR)
        sink += Int(canvas.get_pixel(400, 300).r)
    _report(
        rows,
        "draw_canvas 200x200 1.7x rot 30 bilinear",
        perf_counter_ns() - t0,
        iters,
    )

    # --- text measurement ------------------------------------------
    # Laying out axis labels without drawing them: what a chart runs
    # before it knows where anything goes.
    iters = 200
    t0 = perf_counter_ns()
    for _ in range(iters):
        var m = measure_text("−12,345.67", 13.0, cache=cache)
        sink += Int(m.advance)
    _report(
        rows, "measure_text one label (cached)", perf_counter_ns() - t0, iters
    )

    iters = 100
    t0 = perf_counter_ns()
    for _ in range(iters):
        var b = measure_text_block(paragraph, 13.0, cache=cache)
        sink += Int(b.height)
    _report(
        rows,
        "measure_text_block 3 lines (cached)",
        perf_counter_ns() - t0,
        iters,
    )

    # The measure-then-draw pair a chart makes for every label, laid
    # out twice and then once (#294). The two rows are the same work;
    # the difference is the duplicated layout.
    iters = 100
    t0 = perf_counter_ns()
    for _ in range(iters):
        var b = measure_text_block(paragraph, 13.0, cache=cache)
        draw_text(canvas, 40.0, 500.0, paragraph, INK, 13.0, cache=cache)
        sink += Int(b.height)
    _report(
        rows,
        "measure then draw 3 lines (laid out twice)",
        perf_counter_ns() - t0,
        iters,
    )

    t0 = perf_counter_ns()
    for _ in range(iters):
        var lay = prepare_text(paragraph, 13.0, cache=cache)
        var b = measure_layout(lay)
        draw_layout(canvas, 40.0, 500.0, lay, INK, cache=cache)
        sink += Int(b.height)
    _report(
        rows,
        "measure then draw 3 lines (prepared once)",
        perf_counter_ns() - t0,
        iters,
    )

    # Printed so nothing above can be optimized away as unused. The
    # value itself is not meaningful; only that it was computed is.
    print("checksum:", sink)
    return rows^


# A row this many times slower than its reference fails the check.
# The survey's own run-to-run swing on parallel rows is about 20%;
# the regression this exists to catch was 2.3x.
comptime _REGRESSION_FACTOR = 1.5

# Rows faster than this are not compared. A case measuring tens of
# nanoseconds -- the cached font scan is one -- swings by a factor on
# timer granularity alone, and reporting that as a regression trains
# the reader to ignore the check.
comptime _MIN_COMPARABLE_US = 1.0
comptime _REFERENCE_PATH = "benchmarks/reference.txt"


def _machine_id() -> String:
    """The CPU model and thread count, which is what a reference is
    valid for."""
    var model = String("unknown")
    try:
        var f = open("/proc/cpuinfo", "r")
        var text = f.read()
        f.close()
        for line in text.split("\n"):
            if line.startswith("model name"):
                var colon = line.find(":")
                model = String(line[byte = colon + 1 :].strip())
                break
    except:
        pass
    return model + " x" + String(parallelism_level())


def _package_version() -> String:
    try:
        var f = open("pixi.toml", "r")
        var text = f.read()
        f.close()
        for line in text.split("\n"):
            if line.startswith("version = "):
                return String(line[byte=10:].strip()).replace('"', "")
    except:
        pass
    return "unknown"


def _best_of_two() raises -> List[_Row]:
    """The survey twice, each row at its faster time, which takes the
    edge off a run that another process leaned on."""
    var first = _survey()
    var second = _survey()
    var rows = List[_Row]()
    for i in range(len(first)):
        var ns = first[i].ns_per_iter
        if i < len(second) and second[i].ns_per_iter < ns:
            ns = second[i].ns_per_iter
        rows.append(_Row(first[i].name, ns, first[i].iters))
    return rows^


def _record(rows: List[_Row]) raises:
    var out = String(
        "# canvas_mojo bench reference: us/iter per row, the faster of two"
        " runs.\n"
    )
    out += "# machine: " + _machine_id() + "\n"
    out += "# workers: " + String(parallelism_level()) + "\n"
    out += "# version: " + _package_version() + "\n"
    out += (
        "# Written by `pixi run bench-record`; read by `pixi run"
        " bench-check`.\n"
    )
    for i in range(len(rows)):
        out += (
            rows[i].name + "\t" + _fixed(rows[i].ns_per_iter / 1000.0, 3) + "\n"
        )
    var f = open(_REFERENCE_PATH, "w")
    f.write(out)
    f.close()
    print(
        "recorded", len(rows), "rows to", _REFERENCE_PATH, "for", _machine_id()
    )


def _check(rows: List[_Row]) raises:
    var f = open(_REFERENCE_PATH, "r")
    var text = f.read()
    f.close()
    var machine = String("")
    var version = String("")
    var workers = String("")
    var names = List[String]()
    var times = List[Float64]()
    for line in text.split("\n"):
        if line.startswith("# machine: "):
            machine = String(line[byte=11:].strip())
        elif line.startswith("# workers: "):
            workers = String(line[byte=11:].strip())
        elif line.startswith("# version: "):
            version = String(line[byte=11:].strip())
        elif line.startswith("#") or String(line.strip()) == "":
            continue
        else:
            var tab = line.find("\t")
            names.append(String(line[byte=:tab]))
            times.append(Float64(String(line[byte = tab + 1 :].strip())))
    var here = _machine_id()
    if machine != here:
        print("bench-check: reference was recorded on", machine)
        print("             this machine is", here)
        print(
            "             absolute numbers do not carry across hardware;"
            " nothing checked."
        )
        return
    print("")
    print("bench-check against", _REFERENCE_PATH, "(version", version + ")")
    var here_workers = String(parallelism_level())
    if workers != "" and workers != here_workers:
        # Banding decisions read the worker count, so a reference taken
        # at a different one is comparing two different plans.
        print(
            "             recorded at",
            workers,
            "workers, running at",
            here_workers,
        )
    var name_w = 4
    for i in range(len(rows)):
        if rows[i].name.byte_length() > name_w:
            name_w = rows[i].name.byte_length()
    print(
        _pad("case", name_w),
        _lpad("ref us", 12),
        _lpad("now us", 12),
        _lpad("ratio", 8),
        "  verdict",
    )
    var regressions = 0
    for i in range(len(rows)):
        ref r = rows[i]
        var now = r.ns_per_iter / 1000.0
        var ref_us = -1.0
        for k in range(len(names)):
            if names[k] == r.name:
                ref_us = times[k]
                break
        if ref_us < 0.0:
            print(
                _pad(r.name, name_w),
                _lpad("-", 12),
                _lpad(_fixed(now, 1), 12),
                _lpad("-", 8),
                "  no reference (record to add)",
            )
            continue
        if ref_us < _MIN_COMPARABLE_US and now < _MIN_COMPARABLE_US:
            print(
                _pad(r.name, name_w),
                _lpad(_fixed(ref_us, 1), 12),
                _lpad(_fixed(now, 1), 12),
                _lpad("-", 8),
                "  below the comparable floor",
            )
            continue
        var ratio = now / ref_us
        var verdict = String("ok")
        if ratio > _REGRESSION_FACTOR:
            verdict = "REGRESSION"
            regressions += 1
        elif ratio < 1.0 / _REGRESSION_FACTOR:
            verdict = "faster; re-record when intended"
        print(
            _pad(r.name, name_w),
            _lpad(_fixed(ref_us, 1), 12),
            _lpad(_fixed(now, 1), 12),
            _lpad(_fixed(ratio, 2), 8),
            "  " + verdict,
        )
    var stale = 0
    for k in range(len(names)):
        var still = False
        for i in range(len(rows)):
            if rows[i].name == names[k]:
                still = True
                break
        if not still:
            print(
                _pad(names[k], name_w),
                _lpad(_fixed(times[k], 1), 12),
                _lpad("-", 12),
                _lpad("-", 8),
                "  in the reference but no longer measured",
            )
            stale += 1
    if stale > 0:
        print(
            "bench-check:",
            stale,
            "reference row(s) no longer measured; re-record to drop them",
        )
    if regressions > 0:
        raise Error(
            String(
                "bench-check: ",
                regressions,
                " row(s) more than ",
                _REGRESSION_FACTOR,
                "x slower than the reference",
            )
        )
    print(
        "bench-check: no row more than",
        _REGRESSION_FACTOR,
        "x slower than its reference",
    )


# --- complete-output verification ---------------------------------------
#
# The `sink` the survey prints is an anti-elimination device: a few
# sampled channels folded together so the compiler cannot delete the
# work that produced them. It cannot establish that output is
# unchanged, because almost every pixel never reaches it. This section
# is the check that can: a set of scenes rendered outside any timed
# region, each digested over every byte of its buffer, against digests
# recorded in `benchmarks/digests.txt`.
#
# A digest is a convenient way to persist the comparison, not a proof
# of equality -- two different images can collide. What it does give is
# detection of a change anywhere in the buffer rather than only where
# the sink happened to sample.
#
# Every scene here is font-independent, for the reason the golden
# suite draws no text: glyphs come from whatever fonts the machine has
# installed, so a text scene's digest would differ between machines
# without anything being wrong. Text keeps its timing rows and is
# excluded from this check, which `_verify` says out loud rather than
# leaving to be inferred.

comptime _DIGEST_PATH = "benchmarks/digests.txt"
comptime _FNV_OFFSET = UInt64(0xCBF29CE484222325)
comptime _FNV_PRIME = UInt64(0x100000001B3)


def _digest(canvas: Canvas) -> UInt64:
    """FNV-1a over every byte of `canvas`, with its dimensions folded
    in first so two differently shaped buffers cannot agree by holding
    the same bytes.
    """
    var h = _FNV_OFFSET
    var dims: List[Int] = [canvas.width, canvas.height]
    for d in dims:
        var v = d
        for _ in range(4):
            h = (h ^ UInt64(v & 0xFF)) * _FNV_PRIME
            v >>= 8
    var p = canvas.pixels.unsafe_ptr()
    for i in range(canvas.width * canvas.height * BYTES_PER_PIXEL):
        h = (h ^ UInt64(p[unsafe_offset=i])) * _FNV_PRIME
    return h


def _hex(value: UInt64) -> String:
    comptime DIGITS = String("0123456789abcdef")
    var out = String()
    for shift in range(60, -4, -4):
        var nibble = Int((value >> UInt64(shift)) & 0xF)
        out += DIGITS[byte=nibble]
    return out^


struct _Scene(Copyable, Movable):
    """One verified render: its name and the digest of every byte."""

    var name: String
    var digest: UInt64

    def __init__(out self, name: String, digest: UInt64):
        self.name = name
        self.digest = digest


def _lcg(seed: Int) -> Int:
    return (seed * 1103515245 + 12345) & 0x7FFFFFFF


def _wiggle(seed_in: Int) raises -> Path:
    """A closed path of cubics, deterministic and self-overlapping, so
    both fill rules and the stroke have something to disagree about.
    """
    var p = Path()
    p.move_to(30.0, 150.0)
    var seed = seed_in
    for i in range(14):
        seed = _lcg(seed)
        var a = Float64(i) * 0.37 + Float64(seed % 100) * 0.004
        p.cubic_curve_to(
            40.0 + 22.0 * Float64(i),
            150.0 + 110.0 * sin(a),
            55.0 + 22.0 * Float64(i),
            150.0 - 110.0 * cos(a * 1.3),
            70.0 + 21.0 * Float64(i),
            150.0 + 70.0 * sin(a * 1.9),
        )
    p.close()
    return p^


def _verify_scenes() raises -> List[_Scene]:
    """Every scene, rendered and digested. Nothing here is timed."""
    comptime VW = 320
    comptime VH = 240
    var scenes = List[_Scene]()
    var path = _wiggle(7)

    # Solid and blended rectangle fills, including a non-source-over
    # mode, which the survey times but never samples away from (0, 0).
    var c = Canvas(VW, VH, WHITE)
    fill_rect(c, 20, 20, 200, 140, INK)
    fill_rect(c, 90, 60, 180, 150, Color(220, 90, 60, 140))
    c.set_blend_mode(BlendMode.MULTIPLY)
    fill_rect(c, 40, 100, 160, 90, Color(90, 200, 120, 200))
    c.set_blend_mode(BlendMode.SOURCE_OVER)
    scenes.append(_Scene("rect fills and blend modes", _digest(c)))

    # Anti-aliased primitives at fractional centers, both the
    # closed-form sizes and the ones that flatten to polygons.
    var c2 = Canvas(VW, VH, WHITE)
    for i in range(60):
        var fx = 12.0 + Float64((i * 37) % 300) + 0.25
        var fy = 12.0 + Float64((i * 53) % 210) + 0.75
        fill_circle_aa(c2, fx, fy, 1.5 + Float64(i % 9), INK)
    fill_ellipse_aa(c2, 160.5, 120.25, 90.0, 55.0, Color(40, 80, 200, 170))
    fill_arc_aa(c2, 100.0, 90.0, 60.0, -1.2, 1.4, Color(200, 60, 40, 200))
    fill_ring_sector_aa(c2, 220.0, 160.0, 30.0, 70.0, 0.3, 2.9, INK)
    scenes.append(_Scene("aa circles, ellipse, arc, ring", _digest(c2)))

    # Both fill rules over a self-overlapping path, plus a stroke.
    var c3 = Canvas(VW, VH, WHITE)
    fill_path_aa(c3, path, Color(30, 90, 160, 200), FillRule.EVEN_ODD)
    scenes.append(_Scene("path fill, even-odd", _digest(c3)))
    var c4 = Canvas(VW, VH, WHITE)
    fill_path_aa(c4, path, Color(30, 90, 160, 200), FillRule.NONZERO)
    scenes.append(_Scene("path fill, nonzero", _digest(c4)))
    var c5 = Canvas(VW, VH, WHITE)
    stroke_path_aa(c5, path, INK, width=3.5)
    scenes.append(_Scene("path stroke", _digest(c5)))

    # Lines and polylines, solid and dashed, at sub-pixel positions.
    var c6 = Canvas(VW, VH, WHITE)
    var series = List[FPoint]()
    for i in range(240):
        series.append(
            FPoint(
                10.0 + Float64(i) * 1.25,
                120.0 + 90.0 * sin(Float64(i) * 0.11),
            )
        )
    draw_polyline_aa(c6, series, INK, width=2.5)
    var dashes: List[Float64] = [6.0, 4.0]
    draw_polyline_aa(
        c6, series, Color(200, 40, 40, 200), width=1.5, dashes=dashes
    )
    draw_line_aa(c6, 0.0, 0.0, 320.0, 240.0, Color(20, 160, 90), width=2.0)
    draw_line(c6, 0, 239, 319, 0, INK)
    scenes.append(_Scene("lines and dashed polyline", _digest(c6)))

    # A polygon under a rectangle clip and a path clip.
    var c7 = Canvas(VW, VH, WHITE)
    var poly = List[FPoint]()
    for i in range(9):
        var a = Float64(i) * 2.0 * pi / 9.0
        poly.append(FPoint(160.0 + 120.0 * cos(a), 120.0 + 100.0 * sin(a)))
    c7.push_clip(30, 25, 240, 180)
    fill_polygon_aa(c7, poly, Color(120, 40, 200, 210), FillRule.NONZERO)
    c7.pop_clip()
    c7.push_clip_path(path)
    fill_rect(c7, 0, 0, VW, VH, Color(240, 190, 40, 180))
    c7.pop_clip()
    scenes.append(_Scene("clip rect and clip path", _digest(c7)))

    # All three gradients, with a duplicate stop and transparent stops.
    var lin = LinearGradient(-20.0, 10.0, 340.0, 230.0)
    lin.add_stop(0.0, Color(255, 0, 0, 255))
    lin.add_stop(0.5, Color(0, 255, 128, 90))
    lin.add_stop(0.5, Color(250, 240, 230, 255))
    lin.add_stop(1.0, Color(0, 0, 255, 200))
    var rad = RadialGradient(160.0, 120.0, 140.0)
    rad.add_stop(0.0, Color(255, 200, 40, 255))
    rad.add_stop(1.0, Color(20, 40, 160, 60))
    var con = ConicGradient(160.0, 120.0, -0.7)
    con.add_stop(0.0, Color(255, 60, 60, 255))
    con.add_stop(1.0, Color(60, 60, 255, 255))
    var c8 = Canvas(VW, VH, WHITE)
    fill_path_gradient_aa(c8, path, lin, FillRule.NONZERO)
    scenes.append(_Scene("linear gradient path", _digest(c8)))
    var c9 = Canvas(VW, VH, WHITE)
    fill_path_radial_gradient_aa(c9, path, rad, FillRule.NONZERO)
    scenes.append(_Scene("radial gradient path", _digest(c9)))
    var c10 = Canvas(VW, VH, WHITE)
    fill_path_conic_gradient_aa(c10, path, con, FillRule.NONZERO)
    scenes.append(_Scene("conic gradient path", _digest(c10)))

    # Compositing: opaque, translucent, scaled opacity, and through a
    # mask -- the four the compositor dispatches between.
    var layer = Canvas(VW, VH, Color(0, 0, 0, 0))
    fill_circle_aa(layer, 150.0, 110.0, 80.0, Color(60, 120, 200, 128))
    fill_rect(layer, 30, 30, 90, 60, Color(240, 90, 30, 255))
    var opaque_layer = Canvas(VW, VH, Color(30, 90, 160, 255))
    var mask = Mask(VW, VH)
    var mp = mask.coverage.unsafe_ptr()
    var seed = 4242
    for i in range(VW * VH):
        seed = _lcg(seed)
        mp[unsafe_offset=i] = UInt8((seed >> 11) & 0xFF)
    var c11 = Canvas(VW, VH, WHITE)
    draw_canvas(c11, opaque_layer, 5, 7)
    draw_canvas(c11, layer, -12, 9)
    draw_canvas(c11, layer, 40, 25, 128)
    draw_canvas(c11, layer, 18, -6, mask)
    scenes.append(_Scene("composited layers and mask", _digest(c11)))

    # Transform state: the mapped path, rect and gradient paths.
    var c12 = Canvas(VW, VH, WHITE)
    c12.translate(17.5, 9.25)
    c12.rotate(0.41)
    c12.scale(1.3, 0.75)
    fill_rect(c12, 10, 10, 180, 120, Color(200, 60, 120, 220))
    fill_path_gradient_aa(c12, path, lin, FillRule.NONZERO)
    fill_circle_aa(c12, 120.0, 80.0, 40.0, Color(20, 200, 160, 190))
    scenes.append(_Scene("transformed shapes", _digest(c12)))

    # Blur, and both a power-of-two and an odd downsample factor.
    var c13 = Canvas(VW, VH, WHITE)
    fill_circle_aa(c13, 160.0, 120.0, 90.0, INK)
    fill_rect(c13, 20, 20, 80, 60, Color(220, 60, 60, 200))
    blur(c13, 5)
    scenes.append(_Scene("blur r=5", _digest(c13)))
    var big = Canvas(VW * 2, VH * 2, Color(0, 0, 0, 0))
    fill_circle_aa(big, 320.0, 240.0, 200.0, Color(240, 90, 30, 255))
    fill_rect(big, 40, 40, 200, 160, Color(30, 90, 160, 110))
    scenes.append(_Scene("downsample by 2", _digest(downsample(big, 2))))
    var big3 = Canvas(VW * 3, VH * 3, Color(0, 0, 0, 0))
    fill_circle_aa(big3, 480.0, 360.0, 300.0, Color(240, 90, 30, 255))
    fill_rect(big3, 60, 60, 300, 240, Color(30, 90, 160, 110))
    scenes.append(_Scene("downsample by 3", _digest(downsample(big3, 3))))

    # A PNG round trip, which exercises both codecs end to end.
    var png_path = String("benchmarks/_verify_out.png")
    write_png(c2, png_path)
    scenes.append(_Scene("png round trip", _digest(read_png(png_path))))

    return scenes^


def _digest_machine() -> String:
    """The machine `benchmarks/digests.txt` was recorded on."""
    try:
        var f = open(_DIGEST_PATH, "r")
        var text = f.read()
        f.close()
        for line in text.split("\n"):
            if line.startswith("# machine: "):
                return String(line[byte=11:].strip())
    except:
        pass
    return "unknown"


def _read_digests() -> List[_Scene]:
    """`benchmarks/digests.txt`, or an empty list if it is not there."""
    var out = List[_Scene]()
    try:
        var f = open(_DIGEST_PATH, "r")
        var text = f.read()
        f.close()
        for line in text.split("\n"):
            if line.startswith("#"):
                continue
            var cut = line.find("\t")
            if cut < 0:
                continue
            var name = String(line[byte=0:cut])
            var value = UInt64(0)
            var digits = String(line[byte = cut + 1 :].strip())
            for i in range(digits.byte_length()):
                var c = Int(digits.as_bytes()[i])
                var nibble: Int
                if 48 <= c <= 57:
                    nibble = c - 48
                elif 97 <= c <= 102:
                    nibble = c - 87
                else:
                    continue
                value = (value << UInt64(4)) | UInt64(nibble)
            out.append(_Scene(name, value))
    except:
        pass
    return out^


def _environment() -> String:
    """What a digest or a timing was produced on, for the header."""
    return String(
        "# machine: ",
        _machine_id(),
        "\n# workers: ",
        parallelism_level(),
        "\n# version: ",
        _package_version(),
    )


def _record_digests() raises:
    """Write every scene's digest to `benchmarks/digests.txt`."""
    var scenes = _verify_scenes()
    var out = String(
        "# canvas_mojo render digests: FNV-1a over every byte of each"
        " scene.\n"
        "# Font-dependent scenes are deliberately absent -- see"
        " `_verify_scenes`.\n"
    )
    out += _environment()
    out += "\n# Written by `pixi run bench-record-digests`; read by"
    out += " `pixi run bench-verify`.\n"
    for s in scenes:
        out += s.name + "\t" + _hex(s.digest) + "\n"
    var f = open(_DIGEST_PATH, "w")
    f.write(out)
    f.close()
    print("wrote", len(scenes), "digests to", _DIGEST_PATH)


def _verify() raises:
    """Render every scene and compare its digest with the recorded
    one. Exits non-zero on any mismatch, so a caller can gate on it.
    """
    var scenes = _verify_scenes()
    var known = _read_digests()
    var recorded_on = _digest_machine()
    var here = _machine_id()
    # A digest is exact, and the transcendentals a curve goes through
    # are a platform's own libm. Two machines can render the same
    # scene a level apart in a pixel or two without either being
    # wrong, so a mismatch is only a failure where the digests were
    # taken. Elsewhere it is reported and nothing is gated on it --
    # the golden suite, with its tolerance, is the cross-platform
    # check.
    var same_machine = recorded_on == here
    var bad = 0
    var missing = 0
    print("scene                                   digest            state")
    print("-" * 68)
    for s in scenes:
        var found = False
        var expected = UInt64(0)
        for k in known:
            if k.name == s.name:
                found = True
                expected = k.digest
                break
        var state = String("ok")
        if not found:
            state = "NOT RECORDED"
            missing += 1
        elif expected != s.digest:
            state = String("CHANGED, expected ", _hex(expected))
            bad += 1
        var pad = String()
        for _ in range(max(40 - s.name.byte_length(), 1)):
            pad += " "
        print(s.name, pad, _hex(s.digest), " ", state, sep="")
    for k in known:
        var still = False
        for s in scenes:
            if s.name == k.name:
                still = True
                break
        if not still:
            print("recorded but no longer rendered:", k.name)
            missing += 1
    print()
    print(_environment())
    print(
        "# text scenes are excluded: glyphs come from the machine's own fonts."
    )
    if not same_machine:
        print("digests were recorded on", recorded_on)
        print("this machine is         ", here)
        print(
            "exact digests bind only on the machine that took them, so this"
            " is a report, not a gate."
        )
        if bad != 0:
            print(bad, "scene(s) differ, which may be this machine's libm.")
        return
    if bad != 0:
        raise Error(
            String(
                bad,
                (
                    " scene(s) changed. Re-record with `pixi run"
                    " bench-record-digests` only when the new output is known"
                    " correct, and say why in the PR."
                ),
            )
        )
    if missing != 0:
        raise Error(
            String(
                missing,
                (
                    " scene(s) have no recorded digest, or are recorded but no"
                    " longer rendered. Run `pixi run bench-record-digests`."
                ),
            )
        )
    print("bench-verify:", len(scenes), "scenes match their digests")


def main() raises:
    var mode = getenv("CANVAS_BENCH_MODE")
    if mode == "verify":
        _verify()
        return
    if mode == "record-digests":
        _record_digests()
        return
    if mode == "record":
        _record(_best_of_two())
        return
    if mode == "check":
        _check(_best_of_two())
        return
    _print_table(_survey())
