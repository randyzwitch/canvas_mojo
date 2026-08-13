"""Demo: the general Path API -- quadratic and cubic Bezier curves,
multi-sub-path hole punching, and hard-edged vs. AA stroking and
filling, none of which the discrete shape functions in primitives.mojo
can do on their own (they're what fill_path/stroke_path actually call
once a Path is flattened -- see path.mojo's own docstring).

Run with:
    pixi run example
"""

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas
from canvas_mojo.path import Path, fill_path, fill_path_aa, stroke_path, stroke_path_aa
from canvas_mojo.io.bmp import write_bmp


def main() raises:
    var c = Canvas(900, 260, Color(255, 255, 255))

    # A rounded, leaf-like shape mixing all three curve/line command
    # types in one sub-path, filled solid.
    var leaf = Path()
    leaf.move_to(80.0, 60.0)
    leaf.line_to(160.0, 60.0)
    leaf.quad_curve_to(210.0, 100.0, 160.0, 140.0)
    leaf.cubic_curve_to(140.0, 180.0, 100.0, 180.0, 80.0, 140.0)
    leaf.close()
    fill_path(c, leaf, Color(40, 130, 90))

    # The same outline, stroked instead of filled -- hard-edged on the
    # left half, AA on the right, so the jaggedness difference is
    # directly comparable (same technique circles.mojo/ellipse.mojo
    # use elsewhere in this examples/ directory).
    var outline_hard = Path()
    outline_hard.move_to(280.0, 60.0)
    outline_hard.line_to(360.0, 60.0)
    outline_hard.quad_curve_to(410.0, 100.0, 360.0, 140.0)
    outline_hard.cubic_curve_to(340.0, 180.0, 300.0, 180.0, 280.0, 140.0)
    outline_hard.close()
    stroke_path(c, outline_hard, Color(150, 60, 20))

    var outline_aa = Path()
    outline_aa.move_to(480.0, 60.0)
    outline_aa.line_to(560.0, 60.0)
    outline_aa.quad_curve_to(610.0, 100.0, 560.0, 140.0)
    outline_aa.cubic_curve_to(540.0, 180.0, 500.0, 180.0, 480.0, 140.0)
    outline_aa.close()
    stroke_path_aa(c, outline_aa, Color(150, 60, 20), width=2.0)

    # A donut: an outer circle-ish sub-path (approximated with cubic
    # curves, the standard 4-curve circle trick) plus an inner one --
    # fill_path combines both sub-paths' crossings, punching the hole.
    var donut = Path()
    var cx = 590.0
    var cy = 210.0
    var k = 0.5523  # magic constant for a 4-cubic circle approximation
    var r_outer = 40.0
    var ko = r_outer * k
    donut.move_to(cx + r_outer, cy)
    donut.cubic_curve_to(cx + r_outer, cy + ko, cx + ko, cy + r_outer, cx, cy + r_outer)
    donut.cubic_curve_to(cx - ko, cy + r_outer, cx - r_outer, cy + ko, cx - r_outer, cy)
    donut.cubic_curve_to(cx - r_outer, cy - ko, cx - ko, cy - r_outer, cx, cy - r_outer)
    donut.cubic_curve_to(cx + ko, cy - r_outer, cx + r_outer, cy - ko, cx + r_outer, cy)
    donut.close()

    var r_inner = 18.0
    var ki = r_inner * k
    donut.move_to(cx + r_inner, cy)
    donut.cubic_curve_to(cx + r_inner, cy + ki, cx + ki, cy + r_inner, cx, cy + r_inner)
    donut.cubic_curve_to(cx - ki, cy + r_inner, cx - r_inner, cy + ki, cx - r_inner, cy)
    donut.cubic_curve_to(cx - r_inner, cy - ki, cx - ki, cy - r_inner, cx, cy - r_inner)
    donut.cubic_curve_to(cx + ki, cy - r_inner, cx + r_inner, cy - ki, cx + r_inner, cy)
    donut.close()

    fill_path(c, donut, Color(180, 40, 120))

    # The same leaf shape as the very first one, filled via
    # fill_path_aa instead of fill_path -- directly comparable to it
    # since it's an identical curved outline, only the fill's edge
    # treatment differs. Curves are exactly where fill_path's
    # hard-edged jaggedness is most visible, unlike the axis-aligned
    # shapes fill_polygon(_aa) examples tend to use.
    var leaf_aa = Path()
    leaf_aa.move_to(720.0, 60.0)
    leaf_aa.line_to(800.0, 60.0)
    leaf_aa.quad_curve_to(850.0, 100.0, 800.0, 140.0)
    leaf_aa.cubic_curve_to(780.0, 180.0, 740.0, 180.0, 720.0, 140.0)
    leaf_aa.close()
    fill_path_aa(c, leaf_aa, Color(40, 130, 90))

    write_bmp(c, "canvas_mojo/examples/out_path.bmp")
    print("wrote canvas_mojo/examples/out_path.bmp")
