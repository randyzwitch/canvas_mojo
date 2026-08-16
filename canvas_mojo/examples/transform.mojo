"""Demo: the full pipeline Transform2D exists for -- map a data
coordinate through a transform, then call a primitive. Nothing here
knows about "charts"; this is exactly the raw mechanism a charting
layer built on top of this package would use, exercised directly with
a small line-plus-markers plot.

Note scale_y is negative: pixel-space y increases downward, but the
data's y increases upward, so the transform flips it -- data point
(x, 0) lands at the pixel row near the bottom of the plot area, and
(x, 100) lands near the top.

Two panels, same data: the left one is the plain transform from
before; the right one adds a small rotation, to make what that
parameter actually does visually obvious (a whole tilted coordinate
frame, axes and all -- not a single rotated label, which is a
different feature entirely; see geometry.mojo's Transform2D
docstring).

Run with:
    pixi run example
"""

from std.math import pi

from canvas_mojo.color import Color
from canvas_mojo.buffer import Canvas
from canvas_mojo.geometry import Point, Transform2D
from canvas_mojo.primitives import draw_line, draw_polyline_aa, fill_circle_aa
from canvas_mojo.io.bmp import write_bmp


def _draw_panel(mut c: Canvas, t: Transform2D):
    """Draw the same small line-plus-markers plot through whatever
    transform `t` is -- axes included, so a rotated transform visibly
    tilts them too, not just the plotted data.
    """
    var axis_x0 = t.to_pixel(0.0, 0.0)
    var axis_x1 = t.to_pixel(10.0, 0.0)
    var axis_y1 = t.to_pixel(0.0, 100.0)
    draw_line(c, axis_x0.x, axis_x0.y, axis_x1.x, axis_x1.y, Color(180, 180, 180))
    draw_line(c, axis_x0.x, axis_x0.y, axis_y1.x, axis_y1.y, Color(180, 180, 180))

    var data_x: List[Float64] = [1.0, 3.0, 5.0, 7.0, 9.0]
    var data_y: List[Float64] = [20.0, 45.0, 30.0, 70.0, 55.0]

    var pixel_points = List[Point]()
    for i in range(len(data_x)):
        pixel_points.append(t.to_pixel(data_x[i], data_y[i]))

    draw_polyline_aa(c, pixel_points, Color(40, 100, 200))
    for i in range(len(pixel_points)):
        var p = pixel_points[i]
        fill_circle_aa(c, p.x, p.y, 5, Color(40, 100, 200))


def main() raises:
    var c = Canvas(720, 320, Color(255, 255, 255))

    # data x in [0, 10] -> pixel x in [40, 360] (left panel's own origin)
    # data y in [0, 100] -> pixel y in [280, 40] (flipped)
    var plain = Transform2D(32.0, -2.4, 40.0, 280.0)
    _draw_panel(c, plain)

    # same scale/mapping, shifted into the right half of the canvas
    # and tilted 12 degrees -- everything the plain panel draws
    # (axes, line, markers) goes through this same tilted frame.
    var rotated = Transform2D(32.0, -2.4, 400.0, 280.0, rotation=pi / 15.0)
    _draw_panel(c, rotated)

    write_bmp(c, "canvas_mojo/examples/out_transform.bmp")
    print("wrote canvas_mojo/examples/out_transform.bmp")
