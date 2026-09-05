"""Smoke test for the built package, run from a workspace that depends
on canvas_mojo rather than compiling it from source.

Every import here is deliberate: one from the package root and one from
each subpackage, so a subpackage left out of the built artifact fails
this rather than reaching a user. It draws through the raster and
vector backends, round-trips a PNG, and checks pixels it can derive by
hand -- enough to prove the package is wired up, not to re-test the
renderer, which tests/ already covers under `-I .`.
"""

from canvas import Canvas, Color, fill_circle_aa
from canvas.geometry import FPoint
from canvas.io.bmp import write_bmp
from canvas.io.png import write_png, read_png
from canvas.path import Path, fill_path_aa
from canvas.shapes.rects import fill_rect
from canvas.text.font_cache import FontCache
from canvas.vector.svg import SvgCanvas, write_svg


def main() raises:
    # README.md's own snippet, verbatim in spirit: the shape a reader
    # copies out of the quickstart has to work.
    var c = Canvas(200, 200, Color(255, 255, 255))
    fill_circle_aa(c, 100, 100, 80, Color(40, 100, 200))
    if c.get_pixel(100, 100).b != 200:
        raise Error("smoke: disk center is not the fill color")
    if c.get_pixel(2, 2).r != 255:
        raise Error("smoke: a corner well outside the disk was painted")

    fill_rect(c, 0, 0, 10, 10, Color(0, 0, 0))
    if c.get_pixel(5, 5).r != 0:
        raise Error("smoke: fill_rect did not paint")

    var p = Path()
    p.move_to(120.0, 120.0)
    p.line_to(190.0, 120.0)
    p.line_to(190.0, 190.0)
    p.close()
    fill_path_aa(c, p, Color(10, 160, 60))
    if c.get_pixel(180, 160).g != 160:
        raise Error("smoke: fill_path_aa did not paint inside the triangle")

    # Both file writers, then a read back through the decoder, so the
    # io subpackage is exercised in both directions.
    write_bmp(c, "smoke_out.bmp")
    write_png(c, "smoke_out.png")
    var reread = read_png("smoke_out.png")
    if reread.width != 200 or reread.height != 200:
        raise Error("smoke: PNG round-trip changed the image size")
    if reread.get_pixel(100, 100).b != 200:
        raise Error("smoke: PNG round-trip changed the disk center")

    # The vector backend, a separate subpackage and a different
    # DrawTarget implementation. Reached as a method rather than the
    # free function above: canvas.shapes' free functions take a
    # Canvas, and the trait's methods are what a backend-agnostic
    # caller uses.
    var svg = SvgCanvas(200, 200)
    svg.fill_circle_aa(100, 100, 80, Color(40, 100, 200))
    write_svg(svg, "smoke_out.svg")
    if svg.to_string().byte_length() == 0:
        raise Error("smoke: SvgCanvas produced no markup")

    # Constructed but not exercised: resolving a real font needs fonts
    # installed, which a downstream workspace cannot assume. This only
    # proves canvas.text is present in the built package and links.
    var cache = FontCache()
    _ = cache^

    # FPoint from canvas.geometry, to keep that import honest.
    var pt = FPoint(1.5, 2.5)
    if pt.x != 1.5:
        raise Error("smoke: FPoint did not round-trip")

    print("smoke: built package imports and draws correctly")
