"""The names `from canvas import ...` resolves: every entry point a
downstream caller reaches for, importable from the package root without
knowing which module defines it. Each name below is used, not just
imported, so a dropped re-export fails here rather than in a user's
project.
"""

from std.testing import TestSuite, assert_equal, assert_true

from canvas import (
    BlendMode,
    Canvas,
    Color,
    DrawTarget,
    Extend,
    FontCache,
    FontDatabase,
    FontSlant,
    FontWeight,
    FPoint,
    Hatch,
    LinearGradient,
    Mask,
    Path,
    PatternSource,
    PdfCanvas,
    SvgCanvas,
    TextAlign,
    blur,
    downsample,
    draw_canvas,
    draw_image,
    draw_shadowed,
    encode_png,
    fill_mask,
    fill_path_aa,
    fill_path_pattern,
    fill_path_pattern_aa,
    fill_rect_pattern,
    hatch_tile,
    read_bmp,
    read_png,
    resolve_font_file,
    write_bmp,
    write_png,
    write_svg,
)


def _draw_markers[T: DrawTarget](mut target: T, radius: Float64) raises:
    """A scatter drawn through the trait, which is the shape a chart
    library's mark layer has: generic over the backend, so it cannot
    name `Canvas` and cannot specialize on it either (#333).
    """
    var centers = List[FPoint]()
    var colors = List[Color]()
    for i in range(60):
        centers.append(
            FPoint(
                2.0 + Float64((i * 7) % 56) * 0.5,
                2.0 + Float64((i * 11) % 52) * 0.5,
            )
        )
        colors.append(Color(UInt8(40 + i * 3), 90, 200, UInt8(120 + i * 2)))
    target.fill_circles_aa(centers, radius, Color(200, 60, 40, 180))
    target.fill_circles_aa(centers, radius, colors)


def _draw_markers_singly[T: DrawTarget](mut target: T, radius: Float64) raises:
    """The same scatter, one call per marker: what the batch has to
    match."""
    var centers = List[FPoint]()
    var colors = List[Color]()
    for i in range(60):
        centers.append(
            FPoint(
                2.0 + Float64((i * 7) % 56) * 0.5,
                2.0 + Float64((i * 11) % 52) * 0.5,
            )
        )
        colors.append(Color(UInt8(40 + i * 3), 90, 200, UInt8(120 + i * 2)))
    for i in range(len(centers)):
        target.fill_circle_aa(
            centers[i].x, centers[i].y, radius, Color(200, 60, 40, 180)
        )
    for i in range(len(centers)):
        target.fill_circle_aa(centers[i].x, centers[i].y, radius, colors[i])


def test_batched_markers_reach_every_backend_through_the_trait() raises:
    """#333: a caller generic over `DrawTarget` could not reach the
    batched marker path, because it takes a concrete `Canvas` and Mojo
    has no way to specialize a generic function on the concrete type.

    Raster output must be identical to the per-marker loop, and both
    vector backends must emit the same markup either way -- there the
    batch *is* the loop, so anything else would mean the trait method
    had drifted from the single one.
    """
    var batched = Canvas(40, 34, Color(255, 255, 255))
    _draw_markers(batched, 3.0)
    var singly = Canvas(40, 34, Color(255, 255, 255))
    _draw_markers_singly(singly, 3.0)
    var differing = 0
    for y in range(34):
        for x in range(40):
            var a = batched.get_pixel(x, y)
            var b = singly.get_pixel(x, y)
            if a.r != b.r or a.g != b.g or a.b != b.b or a.a != b.a:
                differing += 1
    assert_equal(differing, 0, "raster batch differs from the loop")

    var svg_a = SvgCanvas(40, 34)
    _draw_markers(svg_a, 3.0)
    var svg_b = SvgCanvas(40, 34)
    _draw_markers_singly(svg_b, 3.0)
    assert_equal(svg_a.to_string(), svg_b.to_string(), "SVG markup")

    var pdf_a = PdfCanvas(40, 34)
    _draw_markers(pdf_a, 3.0)
    var pdf_b = PdfCanvas(40, 34)
    _draw_markers_singly(pdf_b, 3.0)
    assert_equal(len(pdf_a.to_bytes()), len(pdf_b.to_bytes()), "PDF bytes")

    # A radius past the closed-form limit takes the per-marker
    # fallback; the trait method still has to agree with the loop.
    var big_a = Canvas(40, 34, Color(255, 255, 255))
    _draw_markers(big_a, 11.0)
    var big_b = Canvas(40, 34, Color(255, 255, 255))
    _draw_markers_singly(big_b, 11.0)
    for y in range(34):
        for x in range(40):
            var a = big_a.get_pixel(x, y)
            var b = big_b.get_pixel(x, y)
            assert_equal(a.r, b.r, String("large r at (", x, ", ", y, ")"))
            assert_equal(a.a, b.a, String("large a at (", x, ", ", y, ")"))


def test_a_colour_list_of_the_wrong_length_raises_on_every_backend() raises:
    var centers = List[FPoint]()
    centers.append(FPoint(5.0, 5.0))
    centers.append(FPoint(9.0, 9.0))
    var one = List[Color]()
    one.append(Color(255, 0, 0))
    var raised = 0
    var c = Canvas(20, 20, Color(255, 255, 255))
    try:
        c.fill_circles_aa(centers, 2.0, one)
    except:
        raised += 1
    var s = SvgCanvas(20, 20)
    try:
        s.fill_circles_aa(centers, 2.0, one)
    except:
        raised += 1
    var p = PdfCanvas(20, 20)
    try:
        p.fill_circles_aa(centers, 2.0, one)
    except:
        raised += 1
    assert_equal(raised, 3, "every backend must reject a short color list")


def _draw_scene[T: DrawTarget](mut target: T):
    """Written against the trait, so the `DrawTarget` import is
    exercised as a constraint rather than only as a name, and so the
    blend mode is reachable through it on every backend.
    """
    target.fill_rect(0, 0, 2, 2, Color(255, 0, 0))
    # The Float64 overloads reach both backends through the trait.
    target.fill_rect(2.5, 2.5, 1.0, 1.0, Color(0, 255, 0))
    target.fill_circle_aa(1.5, 1.5, 0.5, Color(0, 0, 255))
    target.set_blend_mode(BlendMode.MULTIPLY)
    target.fill_rect(0, 0, 1, 1, Color(255, 255, 255))
    target.set_blend_mode(BlendMode.SOURCE_OVER)
    target.draw_circle_aa(2.0, 2.0, 1.0, Color(0, 0, 255), width=1.0)
    target.draw_ellipse_aa(2.0, 2.0, 1.5, 1.0, Color(0, 255, 0), width=1.0)


def test_root_exports_draw_and_round_trip() raises:
    var canvas = Canvas(4, 4, Color(0, 0, 0))
    _draw_scene(canvas)
    assert_equal(canvas.get_pixel(0, 0).r, 255)
    assert_equal(canvas.get_pixel(3, 3).r, 0)

    assert_equal(canvas.blend_mode(), BlendMode.SOURCE_OVER)

    var layer = Canvas(2, 2, Color(0, 255, 0))
    draw_canvas(canvas, layer, 2, 2)
    assert_equal(canvas.get_pixel(3, 3).g, 255)
    draw_image(canvas, layer, 1.5, 1.5)
    assert_equal(canvas.get_pixel(2, 2).g, 255)
    assert_true(len(encode_png(layer)) > 8, "a PNG in memory")

    var small = downsample(canvas, 2)
    assert_equal(small.width, 2)

    blur(small, 2.0)
    assert_equal(small.width, 2, "blur() leaves the canvas's size alone")

    var shadow_shape = Canvas(3, 3, Color(0, 0, 0, 0))
    shadow_shape.set_pixel(1, 1, Color(255, 0, 0))
    draw_shadowed(canvas, shadow_shape, 0, 0, Color(0, 0, 0, 180), 2.0, 1, 1)

    var path = Path()
    path.rect(0.0, 0.0, 2.0, 2.0)
    fill_path_aa(small, path, Color(0, 0, 255))

    write_png(small, "tests/_test_exports.png")
    var back = read_png("tests/_test_exports.png")
    assert_equal(back.width, 2)
    write_bmp(small, "tests/_test_exports.bmp")
    assert_equal(read_bmp("tests/_test_exports.bmp").height, 2)

    var svg = SvgCanvas(4, 4)
    _draw_scene(svg)
    var svg_string = svg.to_string()
    assert_true("<rect" in svg_string)
    assert_true("<circle" in svg_string)
    assert_true("<ellipse" in svg_string)
    write_svg(svg, "tests/_test_exports.svg")


def test_root_exports_text_types() raises:
    # Enum-like types and the gradient type resolve and compare; the
    # font database and cache are constructible. Nothing here needs a
    # particular font to be installed.
    assert_equal(FontSlant.ITALIC, FontSlant.ITALIC)
    assert_true(not (FontWeight.BOLD == FontWeight.NORMAL))
    assert_equal(TextAlign.CENTER, TextAlign.CENTER)
    var gradient = LinearGradient(0.0, 0.0, 1.0, 0.0)
    gradient.add_stop(0.0, Color(0, 0, 0))
    assert_equal(gradient.color_at(0.0, 0.0).a, 255)
    var database = FontDatabase()
    var cache = FontCache()
    _ = len(database.faces)
    _ = cache^
    _ = resolve_font_file  # the free function is re-exported too


def test_root_exports_pattern_fills() raises:
    # hatch_tile/PatternSource/Extend/Hatch, and both fills that take a
    # PatternSource, resolve from the package root and produce a
    # solid-ink pixel at the tile's own center.
    var tile = hatch_tile(
        8, 3.0, Color(0, 0, 0), Color(255, 255, 255), Hatch.DOTS
    )
    var pattern = PatternSource(tile, Extend.REPEAT)

    var rect_canvas = Canvas(8, 8, Color(255, 255, 255))
    fill_rect_pattern(rect_canvas, 0, 0, 8, 8, pattern)
    assert_equal(rect_canvas.get_pixel(4, 4).r, 0)

    var path = Path()
    path.rect(0.0, 0.0, 8.0, 8.0)
    var path_canvas = Canvas(8, 8, Color(255, 255, 255))
    fill_path_pattern(path_canvas, path, pattern)
    assert_equal(path_canvas.get_pixel(4, 4).r, 0)

    var aa_canvas = Canvas(8, 8, Color(255, 255, 255))
    fill_path_pattern_aa(aa_canvas, path, pattern)
    assert_equal(aa_canvas.get_pixel(4, 4).r, 0)


def test_root_exports_masks() raises:
    # Mask and fill_mask resolve from the package root: a half mask
    # paints an opaque color at half alpha.
    var c = Canvas(2, 2, Color(0, 0, 0, 0))
    fill_mask(c, Mask(2, 2, 128), Color(255, 0, 0))
    assert_equal(c.get_pixel(0, 0).a, 128)


def test_enum_likes_print_as_their_names() raises:
    # Every enum-like is Writable, so assert_equal on one reports the
    # constant it found rather than failing to compile.
    assert_equal(String(BlendMode.SOFT_LIGHT), "SOFT_LIGHT")
    assert_equal(String(FontSlant.OBLIQUE), "OBLIQUE")
    assert_equal(String(FontWeight.BOLD), "BOLD")
    assert_equal(String(TextAlign.RIGHT), "RIGHT")
    assert_equal(String(Extend.REFLECT), "REFLECT")
    assert_equal(String(Hatch.DOTS), "DOTS")
    assert_equal(String(BlendMode(99)), "BlendMode(99)", "an unknown value")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
