"""Demo: LinearGradient with fill_rect_gradient (a bar-chart-style
fill) and fill_path_gradient (an arbitrary shape, here reusing the
donut from path.mojo's own example, so a gradient fill interacting
with a punched-through hole is visible directly) -- plus
RadialGradient with fill_rect_radial_gradient (a swatch with a radial
highlight) and fill_path_radial_gradient (the same donut, now with a
*genuinely* concentric gradient around its center, not the
LinearGradient-along-a-diameter approximation this example used before
RadialGradient existed).

Run with:
    pixi run example
"""

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas
from canvas_mojo.gradient import LinearGradient, RadialGradient
from canvas_mojo.path import Path, fill_path_gradient, fill_path_radial_gradient
from canvas_mojo.primitives import fill_rect_gradient, fill_rect_radial_gradient
from canvas_mojo.io.bmp import write_bmp


def main() raises:
    var c = Canvas(640, 260, Color(255, 255, 255))

    # A horizontal bar-fill gradient -- axis matches the rect's own
    # width, so the gradient's two stops land exactly on its edges.
    var horizontal = LinearGradient(40.0, 0.0, 240.0, 0.0)
    horizontal.add_stop(0.0, Color(40, 100, 200))
    horizontal.add_stop(1.0, Color(220, 60, 120))
    fill_rect_gradient(c, 40, 40, 200, 80, horizontal)

    # A vertical, three-stop gradient on a second rect.
    var vertical = LinearGradient(0.0, 140.0, 0.0, 220.0)
    vertical.add_stop(0.0, Color(250, 220, 60))
    vertical.add_stop(0.5, Color(230, 100, 40))
    vertical.add_stop(1.0, Color(150, 30, 60))
    fill_rect_gradient(c, 40, 140, 200, 80, vertical)

    # fill_path_gradient on a donut (see canvas_mojo/examples/path.mojo) --
    # the gradient still applies per-pixel across both the outer shape
    # and around the punched-through hole correctly.
    var donut = Path()
    var cx = 370.0
    var cy = 130.0
    var k = 0.5523
    var r_outer = 90.0
    var ko = r_outer * k
    donut.move_to(cx + r_outer, cy)
    donut.cubic_curve_to(cx + r_outer, cy + ko, cx + ko, cy + r_outer, cx, cy + r_outer)
    donut.cubic_curve_to(cx - ko, cy + r_outer, cx - r_outer, cy + ko, cx - r_outer, cy)
    donut.cubic_curve_to(cx - r_outer, cy - ko, cx - ko, cy - r_outer, cx, cy - r_outer)
    donut.cubic_curve_to(cx + ko, cy - r_outer, cx + r_outer, cy - ko, cx + r_outer, cy)
    donut.close()

    var r_inner = 40.0
    var ki = r_inner * k
    donut.move_to(cx + r_inner, cy)
    donut.cubic_curve_to(cx + r_inner, cy + ki, cx + ki, cy + r_inner, cx, cy + r_inner)
    donut.cubic_curve_to(cx - ki, cy + r_inner, cx - r_inner, cy + ki, cx - r_inner, cy)
    donut.cubic_curve_to(cx - r_inner, cy - ki, cx - ki, cy - r_inner, cx, cy - r_inner)
    donut.cubic_curve_to(cx + ki, cy - r_inner, cx + r_inner, cy - ki, cx + r_inner, cy)
    donut.close()

    var donut_radial = RadialGradient(cx, cy, r_outer)
    donut_radial.add_stop(0.0, Color(40, 180, 140))
    donut_radial.add_stop(1.0, Color(60, 60, 160))
    fill_path_radial_gradient(c, donut, donut_radial)

    # A rectangular swatch with a genuine radial highlight -- the
    # fill_rect_radial_gradient case: no circle primitive involved,
    # just a rect whose fill happens to source from a RadialGradient
    # centered on it (a "spotlight"/"glow" panel background, or a
    # legend swatch that wants a soft highlight rather than a flat
    # fill or a hard-edged circle drawn on top).
    var swatch_cx = 550.0
    var swatch_cy = 130.0
    var swatch_radial = RadialGradient(swatch_cx, swatch_cy, 90.0)
    swatch_radial.add_stop(0.0, Color(255, 240, 200))
    swatch_radial.add_stop(1.0, Color(120, 70, 20))
    fill_rect_radial_gradient(c, 470, 40, 160, 180, swatch_radial)

    write_bmp(c, "canvas_mojo/examples/out_gradient.bmp")
    print("wrote canvas_mojo/examples/out_gradient.bmp")
