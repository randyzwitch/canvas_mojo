"""Demo: the pipeline Transform2D exists for -- map a data coordinate
through a transform, then call a primitive. Nothing here knows about
"charts"; this is the raw mechanism a charting layer built on top of
this package would use, exercised directly with a small line-plus-
markers plot.

Note scale_y is negative: pixel-space y increases downward, but the
data's y increases upward, so the transform flips it -- data point
(x, 0) lands at the pixel row near the bottom of the plot area, and
(x, 100) lands near the top.

Two panels, same data: the left uses a plain transform, the right adds
a small rotation, which tilts a whole coordinate frame, axes and all.
Rotating a single label is draw_text's separate feature.

Run with:
    pixi run example
"""

from std.math import pi

from canvas.color import Color
from canvas.buffer import Canvas
from canvas.geometry import Point, Transform2D
from canvas.shapes.lines import draw_line, draw_polyline_aa
from canvas.shapes.circles import fill_circle_aa
from canvas.io.bmp import write_bmp
from canvas.io.png import write_png


def _draw_panel(mut c: Canvas, t: Transform2D):
    """Draw the same line-plus-markers plot through transform `t`, axes
    included, so a rotated transform visibly tilts them too.
    """
    var axis_x0 = t.to_pixel(0.0, 0.0)
    var axis_x1 = t.to_pixel(10.0, 0.0)
    var axis_y1 = t.to_pixel(0.0, 100.0)
    draw_line(
        c, axis_x0.x, axis_x0.y, axis_x1.x, axis_x1.y, Color(180, 180, 180)
    )
    draw_line(
        c, axis_x0.x, axis_x0.y, axis_y1.x, axis_y1.y, Color(180, 180, 180)
    )

    var data_x: List[Float64] = [1.0, 3.0, 5.0, 7.0, 9.0]
    var data_y: List[Float64] = [20.0, 45.0, 30.0, 70.0, 55.0]

    var pixel_points = List[Point]()
    for i in range(len(data_x)):
        pixel_points.append(t.to_pixel(data_x[i], data_y[i]))

    draw_polyline_aa(c, pixel_points, Color(40, 100, 200))
    for i in range(len(pixel_points)):
        var p = pixel_points[i]
        fill_circle_aa(c, p.x, p.y, 15, Color(40, 100, 200))


def main() raises:
    var c = Canvas(2160, 960, Color(255, 255, 255))

    # data x in [0, 10] -> pixel x in [120, 1080] (left panel's own origin)
    # data y in [0, 100] -> pixel y in [840, 120] (flipped)
    var plain = Transform2D(96.0, -7.2, 120.0, 840.0)
    _draw_panel(c, plain)

    # same scale/mapping, shifted into the canvas's right half and
    # tilted 12 degrees, so axes, line and markers all pass through the
    # tilted frame.
    var rotated = Transform2D(96.0, -7.2, 1200.0, 840.0, rotation=pi / 15.0)
    _draw_panel(c, rotated)

    write_bmp(c, "examples/out_transform.bmp")
    write_png(c, "examples/out_transform.png")
    print("wrote examples/out_transform.bmp and .png")
