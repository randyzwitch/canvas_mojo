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
"""

from std.math import cos, pi, sin
from std.time import perf_counter_ns

from canvas.blend import BlendMode
from canvas.blur import blur
from canvas.buffer import Canvas
from canvas.color import Color
from canvas.compose import Filter, draw_canvas
from canvas.fill_rule import FillRule
from canvas.geometry import FPoint, Matrix2D, Point
from canvas.gradient import ConicGradient, LinearGradient, RadialGradient
from canvas.path import (
    Path,
    fill_path_aa,
    fill_path_conic_gradient_aa,
    fill_path_gradient_aa,
    fill_path_radial_gradient_aa,
    stroke_path_aa,
)
from canvas.io.png import write_png, read_png
from canvas.resize import downsample
from canvas.shapes.arcs import fill_arc_aa, fill_ring_sector_aa
from canvas.shapes.circles import fill_circle_aa
from canvas.shapes.ellipses import fill_ellipse_aa
from canvas.shapes.lines import draw_line, draw_line_aa, draw_polyline_aa
from canvas.shapes.polygon_fill import fill_polygon_aa
from canvas.shapes.rects import fill_rect
from canvas.text.font_cache import FontCache
from canvas.text.render import (
    draw_text,
    draw_text_on_path,
    measure_text,
    measure_text_block,
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


def main() raises:
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
    _report(rows, "Canvas(800x600) construct+fill", perf_counter_ns() - t0, iters)

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
    _report(rows, "Canvas.fill translucent (blend)", perf_counter_ns() - t0, iters)

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
    _report(rows, "fill_circle_aa x2000 markers (r=3.5)", perf_counter_ns() - t0, iters)

    iters = 200
    t0 = perf_counter_ns()
    for _ in range(iters):
        fill_circle_aa(canvas, 400.0, 300.0, 250.0, INK)
        sink += Int(canvas.get_pixel(400, 300).r)
    _report(rows, "fill_circle_aa one large (r=250)", perf_counter_ns() - t0, iters)

    iters = 200
    t0 = perf_counter_ns()
    for _ in range(iters):
        fill_ellipse_aa(canvas, 400.0, 300.0, 340.0, 220.0, INK)
        sink += Int(canvas.get_pixel(400, 300).r)
    _report(rows, "fill_ellipse_aa one large (340x220)", perf_counter_ns() - t0, iters)

    iters = 40
    t0 = perf_counter_ns()
    for _ in range(iters):
        for i in range(2000):
            var ex = 20.0 + Float64((i * 37) % 760)
            var ey = 20.0 + Float64((i * 53) % 560)
            fill_ellipse_aa(canvas, ex, ey, 5.0, 3.0, INK)
        sink += Int(canvas.get_pixel(100, 100).r)
    _report(rows, "fill_ellipse_aa x2000 small (5x3)", perf_counter_ns() - t0, iters)

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

    var poly = List[FPoint]()
    for i in range(64):
        var t = Float64(i) / 64.0 * 6.283185307179586
        poly.append(
            FPoint(400.0 + 250.0 * cos(t), 300.0 + 200.0 * sin(t))
        )
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
        rows, "fill_path_aa glyph-sized (nonzero)", perf_counter_ns() - t0, iters
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
    _report(rows, "fill_path_gradient_aa glyph-sized", perf_counter_ns() - t0, iters)

    iters = 60
    t0 = perf_counter_ns()
    for _ in range(iters):
        fill_path_gradient_aa(canvas, big_path, gradient)
        sink += Int(canvas.get_pixel(400, 400).r)
    _report(rows, "fill_path_gradient_aa large 39-curve", perf_counter_ns() - t0, iters)

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
        rows, "fill_path_radial_gradient_aa glyph-sized", perf_counter_ns() - t0, iters
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
        rows, "fill_path_conic_gradient_aa glyph-sized", perf_counter_ns() - t0, iters
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
    _report(rows, "draw_line_aa full diagonal (w=2)", perf_counter_ns() - t0, iters)

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
    _report(rows, "draw_polyline_aa 3000-segment series", perf_counter_ns() - t0, iters)

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
    _report(rows, "draw_polyline_aa 3000-segment dashed", perf_counter_ns() - t0, iters)

    iters = 400
    t0 = perf_counter_ns()
    for _ in range(iters):
        draw_line(canvas, 30, 30, 770, 570, INK, dashes=dashes)
        sink += Int(canvas.get_pixel(400, 300).r)
    _report(rows, "draw_line dashed full diagonal", perf_counter_ns() - t0, iters)

    # The solid counterpart of the row above: same Bresenham walk with
    # no dash pattern, which is what every caller that omits `dashes`
    # runs.
    iters = 400
    t0 = perf_counter_ns()
    for _ in range(iters):
        draw_line(canvas, 30, 30, 770, 570, INK)
        sink += Int(canvas.get_pixel(400, 300).r)
    _report(rows, "draw_line solid full diagonal", perf_counter_ns() - t0, iters)

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
    _report(rows, "draw_text 3 lines @13px (cached)", perf_counter_ns() - t0, iters)

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
        rows, "draw_text 3 lines @13px (uncached)", perf_counter_ns() - t0, iters
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
    _report(rows, "measure_text one label (cached)", perf_counter_ns() - t0, iters)

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

    _print_table(rows)
    # Printed so nothing above can be optimized away as unused. The
    # value itself is not meaningful; only that it was computed is.
    print("checksum:", sink)
