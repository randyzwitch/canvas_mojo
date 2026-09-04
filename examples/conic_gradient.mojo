"""Demo: ConicGradient, the third gradient alongside LinearGradient and
RadialGradient -- offset maps to the angle swept clockwise around a
center rather than a distance. A hue wheel (every stop visible around
one full turn) and a gauge dial (a ring sector swept green to red, the
reading a physical dial would otherwise need a needle to show).

Run with:
    pixi run example
"""

from std.math import cos, pi, sin

from canvas.color import Color
from canvas.buffer import Canvas
from canvas.gradient import ConicGradient
from canvas.path import Path, fill_path_conic_gradient_aa
from canvas.io.bmp import write_bmp
from canvas.io.png import write_png


def main() raises:
    var c = Canvas(1600, 780, Color(255, 255, 255))

    # A hue wheel: six evenly spaced stops sweeping clockwise from +x,
    # with a seventh stop back at offset 1.0 matching the first so the
    # wheel closes without a seam. ConicGradient's own projection wraps
    # at a full turn, but the stop lookup it shares with
    # LinearGradient/RadialGradient only interpolates between the
    # stops it is given, so a smooth loop needs that closing stop
    # spelled out explicitly.
    var wheel_cx = 390.0
    var wheel_cy = 390.0
    var wheel_r = 300.0
    var wheel = ConicGradient(wheel_cx, wheel_cy, 0.0)
    wheel.add_stop(0.0 / 6.0, Color(230, 30, 30))
    wheel.add_stop(1.0 / 6.0, Color(230, 200, 30))
    wheel.add_stop(2.0 / 6.0, Color(60, 200, 60))
    wheel.add_stop(3.0 / 6.0, Color(30, 200, 200))
    wheel.add_stop(4.0 / 6.0, Color(40, 80, 230))
    wheel.add_stop(5.0 / 6.0, Color(200, 40, 200))
    wheel.add_stop(6.0 / 6.0, Color(230, 30, 30))

    var wheel_path = Path()
    wheel_path.move_to(wheel_cx + wheel_r, wheel_cy)
    wheel_path.arc_to(wheel_cx, wheel_cy, wheel_r, 0.0, 2.0 * pi)
    wheel_path.close()
    fill_path_conic_gradient_aa(c, wheel_path, wheel)

    # A gauge dial: a ring sector spanning 270 degrees, leaving a
    # 90-degree gap at the bottom for a needle's rest position. The
    # gradient's start_angle matches the ring's own start, so offset
    # 0.0 (green, a low reading) sits at the gap's left edge, and the
    # highest offset actually painted -- 0.75, three quarters of a
    # turn into the sweep -- lands at the gap's right edge in red.
    # Nothing is painted from 0.75 to 1.0; that quarter turn is the gap
    # itself, outside the ring sector's path.
    var dial_cx = 1180.0
    var dial_cy = 390.0
    var r_outer = 300.0
    var r_inner = 210.0
    var dial_start = 3.0 * pi / 4.0
    var dial_end = dial_start + 3.0 * pi / 2.0

    var dial = ConicGradient(dial_cx, dial_cy, dial_start)
    dial.add_stop(0.0, Color(40, 190, 90))
    dial.add_stop(0.375, Color(230, 200, 30))
    dial.add_stop(0.75, Color(220, 50, 40))

    var dial_path = Path()
    dial_path.move_to(
        dial_cx + r_outer * cos(dial_start),
        dial_cy + r_outer * sin(dial_start),
    )
    dial_path.arc_to(dial_cx, dial_cy, r_outer, dial_start, dial_end)
    dial_path.line_to(
        dial_cx + r_inner * cos(dial_end), dial_cy + r_inner * sin(dial_end)
    )
    dial_path.arc_to(dial_cx, dial_cy, r_inner, dial_end, dial_start)
    dial_path.close()
    fill_path_conic_gradient_aa(c, dial_path, dial)

    write_bmp(c, "examples/out_conic_gradient.bmp")
    write_png(c, "examples/out_conic_gradient.png")
    print("wrote examples/out_conic_gradient.bmp and .png")
