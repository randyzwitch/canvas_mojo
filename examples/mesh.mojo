"""Demo: a surface plot's faces drawn two ways. On the left, each face
is its own anti-aliased fill, and a light line shows along every edge
two faces share, because each face's edge coverage blends against the
background rather than against its neighbour. On the right the same
faces go through `fill_mesh`, which draws them as one shape: full
coverage inside, anti-aliasing only at the silhouette.

The third panel is `fill_mesh_shaded`: the same faces with a color
per vertex rather than per face, interpolated across each, so the
surface reads as continuous rather than faceted.

The surface is a height field over a grid, projected with a fixed
oblique view and depth-sorted so nearer faces are drawn last, which is
all the 3D a static plot needs; the projection and the sort are the
caller's, and the canvas only ever sees 2D triangles in draw order.

Run with:
    pixi run example
"""

from std.math import cos, sin, sqrt

from canvas.buffer import Canvas
from canvas.color import Color
from canvas.geometry import FPoint
from canvas.io.bmp import write_bmp
from canvas.io.png import write_png
from canvas.path import Path
from canvas.shapes.mesh import fill_mesh, fill_mesh_shaded
from canvas.text.render import draw_text

comptime N = 28
comptime BG = Color(255, 255, 255)


def _height(u: Float64, v: Float64) -> Float64:
    """The surface: a ripple, in [-1, 1]."""
    var r = sqrt(u * u + v * v) * 3.0
    return cos(r) * 0.8 - v * 0.15


def _project(u: Float64, v: Float64, h: Float64, ox: Float64) -> FPoint:
    """A fixed oblique view: `u` runs right and a little down, `v` runs
    down-left, height runs straight up."""
    return FPoint(
        ox + 200.0 + u * 190.0 - v * 120.0,
        190.0 + u * 55.0 + v * 130.0 - h * 60.0,
    )


def _shade(h: Float64, nx: Float64, ny: Float64) -> Color:
    """Height maps to a blue-to-yellow ramp; a lambert term from the
    surface slope darkens faces turned away from the light."""
    var t = (h + 1.0) / 2.0
    var r = 30.0 + t * 220.0
    var g = 70.0 + t * 150.0
    var b = 180.0 - t * 150.0
    # Light from the upper left; the normal's slope gives the term.
    var lit = 0.55 + 0.45 * max(0.0, (-nx * 0.6 + ny * 0.3 + 0.75) / 1.0)
    return Color(
        UInt8(min(255.0, r * lit)),
        UInt8(min(255.0, g * lit)),
        UInt8(min(255.0, b * lit)),
    )


def _surface(
    ox: Float64,
    mut pts: List[FPoint],
    mut faces: List[Int],
    mut colors: List[Color],
):
    """The grid's vertices projected into `pts`, its faces sorted far
    to near into `faces`, and a shade per face into `colors`."""
    for j in range(N + 1):
        for i in range(N + 1):
            var u = Float64(i) / Float64(N) * 2.0 - 1.0
            var v = Float64(j) / Float64(N) * 2.0 - 1.0
            pts.append(_project(u, v, _height(u, v), ox))
    # Each cell as two triangles, keyed by its depth along the view --
    # larger `u + v` is nearer under this projection -- so a sort puts
    # far cells first.
    var keys = List[Float64]()
    var tris = List[Int]()
    var shades = List[Color]()
    for j in range(N):
        for i in range(N):
            var a = j * (N + 1) + i
            var u = (Float64(i) + 0.5) / Float64(N) * 2.0 - 1.0
            var v = (Float64(j) + 0.5) / Float64(N) * 2.0 - 1.0
            var h = _height(u, v)
            var e = 0.01
            var nx = (_height(u + e, v) - _height(u - e, v)) / (2.0 * e)
            var ny = (_height(u, v + e) - _height(u, v - e)) / (2.0 * e)
            var c = _shade(h, nx, ny)
            keys.append(u + v)
            tris.append(a)
            tris.append(a + 1)
            tris.append(a + N + 2)
            shades.append(c)
            keys.append(u + v)
            tris.append(a)
            tris.append(a + N + 2)
            tris.append(a + N + 1)
            shades.append(c)
    # Insertion sort on the keys, carrying the faces and shades along:
    # far to near is the painter's order the mesh relies on.
    var order = List[Int]()
    for k in range(len(keys)):
        order.append(k)
    for k in range(1, len(order)):
        var idx = order[k]
        var m = k - 1
        while m >= 0 and keys[order[m]] > keys[idx]:
            order[m + 1] = order[m]
            m -= 1
        order[m + 1] = idx
    for k in range(len(order)):
        var t = order[k]
        faces.append(tris[t * 3])
        faces.append(tris[t * 3 + 1])
        faces.append(tris[t * 3 + 2])
        colors.append(shades[t])


def _vertex_colors(mut colors: List[Color]):
    """A shade per vertex, from the height and slope there: what the
    smooth panel interpolates."""
    for j in range(N + 1):
        for i in range(N + 1):
            var u = Float64(i) / Float64(N) * 2.0 - 1.0
            var v = Float64(j) / Float64(N) * 2.0 - 1.0
            var e = 0.01
            var nx = (_height(u + e, v) - _height(u - e, v)) / (2.0 * e)
            var ny = (_height(u, v + e) - _height(u, v - e)) / (2.0 * e)
            colors.append(_shade(_height(u, v), nx, ny))


def main() raises:
    var c = Canvas(1440, 400, BG)

    # Left: one fill per face, which is what a loop over `fill_path_aa`
    # gives, and what leaves the mesh of light seams.
    var pts = List[FPoint]()
    var faces = List[Int]()
    var colors = List[Color]()
    _surface(0.0, pts, faces, colors)
    for f in range(0, len(faces), 3):
        var a = pts[faces[f]]
        var b = pts[faces[f + 1]]
        var d = pts[faces[f + 2]]
        var p = Path()
        p.move_to(a.x, a.y)
        p.line_to(b.x, b.y)
        p.line_to(d.x, d.y)
        p.close()
        c.fill_path_aa(p, colors[f // 3])

    # Right: the same faces as one mesh.
    var pts2 = List[FPoint]()
    var faces2 = List[Int]()
    var colors2 = List[Color]()
    _surface(480.0, pts2, faces2, colors2)
    fill_mesh(c, pts2, faces2, colors2)

    # Far right: a color per vertex, interpolated across each face.
    var pts3 = List[FPoint]()
    var faces3 = List[Int]()
    var colors3 = List[Color]()
    _surface(960.0, pts3, faces3, colors3)
    var vertex = List[Color]()
    _vertex_colors(vertex)
    fill_mesh_shaded(c, pts3, faces3, vertex)

    draw_text(c, 40.0, 370.0, "one fill per face", Color(60, 60, 60), 16.0)
    draw_text(c, 520.0, 370.0, "fill_mesh", Color(60, 60, 60), 16.0)
    draw_text(c, 1000.0, 370.0, "fill_mesh_shaded", Color(60, 60, 60), 16.0)

    write_bmp(c, "examples/out_mesh.bmp")
    write_png(c, "examples/out_mesh.png")
    print("wrote examples/out_mesh.bmp and .png")
