"""Whole-image regression tests against committed reference renders.

Every other test in this repo asserts individual pixels at hand-derived
coordinates. That catches a wrong value at a known place; it does not
catch an entire glyph moving half a pixel, a fill losing its last
column, or a blend change shifting every anti-aliased edge by one.

Each scene below draws a small figure, and its render is compared
against a PNG committed under tests/golden/. A scene is dense --
overlapping shapes, partial coverage everywhere, translucency -- to
cover as much of the renderer per image as possible rather than to
isolate anything. When one fails, the per-pixel tests say what broke;
this one says that something did.

## Tolerance: how many pixels, not how far

Two thresholds, of which the count is the load-bearing one.

Allowing a small per-channel difference and comparing nothing else does
not work here. Injecting a real regression (coverage-to-alpha truncating
instead of rounding to nearest, a plausible one-character mistake)
shifted 207 to 238 pixels per scene by *exactly one level* each, which a
per-channel tolerance of 2 passes silently. Subtle rasterizer bugs move
many pixels a little, so a magnitude-only threshold does not see them.

What legitimately differs between platforms has the opposite shape. IEEE
754 pins +, -, *, / and sqrt exactly, so the only cross-platform freedom
here is in `cos`/`sin`, which the arcs and circles use to place vertices.
A ULP difference there moves a vertex by ~1e-16 of a pixel, which changes
nothing unless a sub-sample happens to sit that close to an edge -- and
if one does, that pixel's coverage jumps by a whole sub-sample step
(1/16 at the default supersample, so ~16 levels), not by one.

So a handful of pixels differing by a lot is the platform's noise floor,
and many pixels differing by a little is a bug. The thresholds follow
that shape rather than a single fuzzy radius.

_MAX_DIFFERING_PIXELS is 8 out of 19200 -- roughly 25x below the
injected regression above, and well above the zero-to-few a
transcendental disagreement could produce.

## No text

Text is excluded. It depends on which fonts are installed and on their
exact version, neither of which this repo controls, so a text golden
would fail for reasons that are not regressions. `tests/test_text.mojo`
covers text with 29 assertions that do not have that problem.

## Updating the goldens

When a change is *supposed* to alter output:

    CANVAS_REGEN_GOLDEN=1 pixi run test

That rewrites every reference from the current renderer and passes
trivially, so the diff it produces is the thing to review -- committing
a regenerated golden asserts that the new pixels are correct.

Regeneration lives in this file rather than a separate script so the
scenes are defined exactly once; a script that drew them separately
could drift from what the test checks.
"""

from std.math import cos, pi, sin
from std.os import getenv
from std.testing import assert_true, TestSuite

from canvas.buffer import Canvas
from canvas.color import Color
from canvas.compose import draw_canvas
from canvas.fill_rule import FillRule
from canvas.geometry import FPoint, Point
from canvas.gradient import LinearGradient, RadialGradient
from canvas.io.png import read_png, write_png
from canvas.path import Path, fill_path_aa, stroke_path_aa
from canvas.resize import downsample
from canvas.shapes.arcs import fill_arc_aa, fill_ring_sector_aa
from canvas.shapes.circles import fill_circle_aa
from canvas.shapes.ellipses import fill_ellipse_aa
from canvas.shapes.lines import draw_line_aa, draw_polyline_aa
from canvas.shapes.polygon_fill import fill_polygon_aa
from canvas.shapes.rects import fill_rect, fill_rect_gradient

comptime _W = 160
comptime _H = 120
# At most this many pixels may differ from the golden at all...
comptime _MAX_DIFFERING_PIXELS = 8
# ...and none of them by more than one supersample step of coverage,
# which is the largest a single flipped sub-sample can move a pixel.
comptime _MAX_CHANNEL_GAP = 24
comptime _DIR = "tests/golden/"

comptime _PAPER = Color(250, 250, 248)
comptime _INK = Color(35, 45, 70)
comptime _WARM = Color(220, 95, 70)
comptime _COOL = Color(50, 120, 200)


def _regenerating() -> Bool:
    return getenv("CANVAS_REGEN_GOLDEN", "") != ""


def _check(name: String, canvas: Canvas) raises:
    """Compare `canvas` against tests/golden/<name>.png, or rewrite it
    when regenerating.
    """
    var path = String(_DIR) + name + ".png"
    if _regenerating():
        write_png(canvas, path)
        return

    var golden = read_png(path)
    assert_true(
        golden.width == canvas.width and golden.height == canvas.height,
        String("golden ")
        + name
        + " is "
        + String(golden.width)
        + "x"
        + String(golden.height)
        + " but the scene rendered "
        + String(canvas.width)
        + "x"
        + String(canvas.height),
    )

    var worst = 0
    var worst_x = 0
    var worst_y = 0
    var differing = 0
    for y in range(canvas.height):
        for x in range(canvas.width):
            var a = canvas.get_pixel(x, y)
            var b = golden.get_pixel(x, y)
            var d = _channel_gap(a, b)
            if d > 0:
                differing += 1
            if d > worst:
                worst = d
                worst_x = x
                worst_y = y

    var detail = String(" (")
    detail += String(differing)
    detail += " pixels differ, worst channel gap "
    detail += String(worst)
    detail += " at ("
    detail += String(worst_x)
    detail += ", "
    detail += String(worst_y)
    detail += "))."
    detail += " Re-run with CANVAS_REGEN_GOLDEN=1 only if the new output"
    detail += " is known correct."

    # Count first: it is the threshold that catches a systematic shift,
    # which is the failure mode a per-pixel magnitude check misses.
    assert_true(
        differing <= _MAX_DIFFERING_PIXELS,
        String("golden ") + name + ": too many pixels changed" + detail,
    )
    assert_true(
        worst <= _MAX_CHANNEL_GAP,
        String("golden ") + name + ": a pixel changed too much" + detail,
    )


def _channel_gap(a: Color, b: Color) -> Int:
    var dr = Int(a.r) - Int(b.r)
    var dg = Int(a.g) - Int(b.g)
    var db = Int(a.b) - Int(b.b)
    var da = Int(a.a) - Int(b.a)
    if dr < 0:
        dr = -dr
    if dg < 0:
        dg = -dg
    if db < 0:
        db = -db
    if da < 0:
        da = -da
    return max(max(dr, dg), max(db, da))


def test_golden_shapes() raises:
    """Circles, ellipses, wedges and a ring, at sub-pixel centers so
    every boundary carries partial coverage.
    """
    var c = Canvas(_W, _H, _PAPER)
    fill_circle_aa(c, 34.5, 34.25, 22.0, _COOL)
    fill_ellipse_aa(c, 96.3, 32.0, 34.0, 18.75, Color(240, 190, 70))
    fill_arc_aa(c, 40.0, 90.5, 28.0, -pi / 2.0, pi / 4.0, _WARM)
    fill_ring_sector_aa(
        c, 116.0, 88.0, 14.5, 27.0, pi / 6.0, 5.0 * pi / 3.0, _INK
    )
    _check("shapes", c)


def test_golden_lines_and_polys() raises:
    """Strokes at several widths and angles, a dashed run, and filled
    polygons under both fill rules.
    """
    var c = Canvas(_W, _H, _PAPER)
    for i in range(6):
        var t = Float64(i)
        draw_line_aa(
            c, 8.0, 10.0 + t * 3.5, 150.0, 10.0 + t * 8.0, _INK, width=0.5 + t
        )
    var dashes: List[Float64] = [6.0, 4.0]
    draw_line_aa(c, 8.0, 66.5, 152.0, 66.5, _WARM, 2.0, 4, dashes, 0.0)

    var star = List[FPoint]()
    for i in range(10):
        var ang = -pi / 2.0 + Float64(i) * pi / 5.0
        var r = 26.0 if i % 2 == 0 else 11.0
        star.append(FPoint(42.0 + r * cos(ang), 92.0 + r * sin(ang)))
    fill_polygon_aa(c, star, _COOL, FillRule.EVEN_ODD)

    var bowtie: List[FPoint] = [
        FPoint(94.0, 74.5),
        FPoint(146.0, 112.0),
        FPoint(146.0, 74.5),
        FPoint(94.0, 112.0),
    ]
    fill_polygon_aa(c, bowtie, Color(120, 170, 90), FillRule.NONZERO)
    _check("lines_and_polys", c)


def test_golden_paths() raises:
    """Bezier fills and strokes, a hole punched by a second sub-path,
    and an arc_to segment.
    """
    var c = Canvas(_W, _H, _PAPER)

    var ring = Path()
    ring.move_to(12.0, 20.0)
    ring.cubic_curve_to(12.0, 4.0, 68.0, 4.0, 68.0, 20.0)
    ring.cubic_curve_to(68.0, 52.0, 12.0, 52.0, 12.0, 20.0)
    ring.close()
    ring.move_to(28.0, 22.0)
    ring.cubic_curve_to(28.0, 14.0, 52.0, 14.0, 52.0, 22.0)
    ring.cubic_curve_to(52.0, 34.0, 28.0, 34.0, 28.0, 22.0)
    ring.close()
    fill_path_aa(c, ring, _COOL)

    var wave = Path()
    wave.move_to(84.0, 44.0)
    wave.quad_curve_to(100.0, 8.0, 116.0, 30.0)
    wave.quad_curve_to(132.0, 52.0, 150.0, 16.0)
    stroke_path_aa(c, wave, _WARM, width=3.0)

    var wedge = Path()
    wedge.move_to(80.0 + 30.0, 88.0)
    wedge.arc_to(80.0, 88.0, 30.0, 0.0, 2.0 * pi / 3.0)
    wedge.line_to(80.0, 88.0)
    wedge.close()
    fill_path_aa(c, wedge, Color(240, 190, 70))

    var zig = Path()
    zig.move_to(10.0, 108.5)
    zig.line_to(26.5, 74.0)
    zig.line_to(43.0, 108.5)
    zig.line_to(59.5, 74.0)
    stroke_path_aa(c, zig, _INK, width=1.5)
    _check("paths", c)


def test_golden_gradients_and_alpha() raises:
    """Linear and radial gradients, overlapping translucent fills, and
    a translucent stroke over both.
    """
    var c = Canvas(_W, _H, _PAPER)
    var lg = LinearGradient(0.0, 0.0, Float64(_W), 0.0)
    lg.add_stop(0.0, Color(250, 200, 60))
    lg.add_stop(0.55, _WARM)
    lg.add_stop(1.0, Color(70, 50, 140))
    fill_rect_gradient(c, 0, 0, _W, 46, lg)

    var rg = RadialGradient(46.0, 84.0, 34.0)
    rg.add_stop(0.0, Color(255, 255, 255))
    rg.add_stop(1.0, _COOL)
    fill_rect(c, 8, 52, 76, 62, Color(235, 240, 245))
    fill_circle_aa(c, 46.0, 84.0, 30.0, Color(0, 0, 0, 0))
    for yy in range(52, 114):
        for xx in range(8, 84):
            var col = rg.color_at(Float64(xx), Float64(yy))
            c.set_pixel(xx, yy, Color(col.r, col.g, col.b, 200))

    fill_circle_aa(c, 108.0, 74.5, 24.0, Color(220, 95, 70, 150))
    fill_circle_aa(c, 128.5, 92.0, 24.0, Color(50, 120, 200, 150))
    draw_line_aa(c, 88.0, 110.0, 154.0, 58.0, Color(35, 45, 70, 120), 5.0)
    _check("gradients_and_alpha", c)


def test_golden_clip_and_compose() raises:
    """A path clip over a dense pattern, a rectangle clip, and a
    translucent layer composed on top -- the three newest subsystems in
    one image.
    """
    var base = Canvas(_W, _H, _PAPER)

    var blob = Path()
    blob.move_to(20.0, 60.0)
    blob.cubic_curve_to(20.0, 14.0, 78.0, 14.0, 78.0, 52.0)
    blob.cubic_curve_to(78.0, 100.0, 20.0, 100.0, 20.0, 60.0)
    blob.close()
    base.push_clip_path(blob)
    var s = 0
    while s < 120:
        draw_line_aa(
            base,
            Float64(s) - 40.0,
            0.0,
            Float64(s) + 30.0,
            Float64(_H),
            _COOL if s % 16 == 0 else _WARM,
            width=4.0,
        )
        s += 8
    base.pop_clip_path()

    base.push_clip(92, 16, 56, 88)
    fill_circle_aa(base, 120.0, 60.0, 42.0, Color(120, 170, 90))
    base.pop_clip()

    # A layer drawn on its own transparent canvas, composed at partial
    # opacity -- so the composite path and the alpha channel are both
    # in the comparison.
    var layer = Canvas(_W, _H, Color(0, 0, 0, 0))
    fill_rect(layer, 0, 96, _W, 24, _INK)
    fill_circle_aa(layer, 40.0, 96.0, 16.5, Color(240, 190, 70))
    draw_canvas(base, layer, 0, 0, 170)
    _check("clip_and_compose", base)


def test_golden_large_curves() raises:
    """Curves big enough that the flattening step count matters.

    Every other scene here uses curves spanning tens of pixels, where
    almost any reasonable step count looks the same. These span most of
    the canvas, which is where a fixed count visibly facets: at 16
    steps the cubic below deviates from the true curve by 1.6 pixels,
    against 0.02 with the count chosen from the curvature.

    Without this scene, reverting to fixed-step flattening would pass
    every test in the repo.
    """
    var c = Canvas(_W, _H, _PAPER)

    var swoop = Path()
    swoop.move_to(4.0, 108.0)
    swoop.cubic_curve_to(30.0, 2.0, 130.0, 118.0, 156.0, 12.0)
    stroke_path_aa(c, swoop, _COOL, width=2.5)

    var blob = Path()
    blob.move_to(80.0, 8.0)
    blob.cubic_curve_to(158.0, 20.0, 158.0, 100.0, 80.0, 112.0)
    blob.cubic_curve_to(2.0, 100.0, 2.0, 20.0, 80.0, 8.0)
    blob.close()
    fill_path_aa(c, blob, Color(240, 190, 70, 130))

    var arc_sweep = Path()
    arc_sweep.move_to(8.0, 60.0)
    arc_sweep.quad_curve_to(80.0, 118.0, 152.0, 60.0)
    stroke_path_aa(c, arc_sweep, _WARM, width=1.5)
    _check("large_curves", c)


def test_golden_downsampled_supersample() raises:
    """A 3x supersampled render brought back down -- the resize path,
    and a second, independent route to an anti-aliased edge.
    """
    var big = Canvas(_W * 3, _H * 3, _PAPER)
    fill_circle_aa(big, 240.0, 180.0, 150.0, _COOL)
    var tri: List[FPoint] = [
        FPoint(60.0, 330.0),
        FPoint(240.0, 40.0),
        FPoint(420.0, 330.0),
    ]
    fill_polygon_aa(big, tri, Color(240, 190, 70, 160))
    var small = downsample(big, 3)
    _check("downsampled_supersample", small)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
