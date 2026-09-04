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
    FontCache,
    FontDatabase,
    FontSlant,
    FontWeight,
    LinearGradient,
    Path,
    SvgCanvas,
    TextAlign,
    downsample,
    draw_canvas,
    fill_path_aa,
    read_bmp,
    read_png,
    resolve_font_file,
    write_bmp,
    write_png,
    write_svg,
)


def _draw_scene[T: DrawTarget](mut target: T):
    """Written against the trait, so the `DrawTarget` import is
    exercised as a constraint rather than only as a name.
    """
    target.fill_rect(0, 0, 2, 2, Color(255, 0, 0))


def test_root_exports_draw_and_round_trip() raises:
    var canvas = Canvas(4, 4, Color(0, 0, 0))
    _draw_scene(canvas)
    assert_equal(canvas.get_pixel(0, 0).r, 255)
    assert_equal(canvas.get_pixel(3, 3).r, 0)

    canvas.set_blend_mode(BlendMode.MULTIPLY)
    assert_true(canvas.blend_mode() == BlendMode.MULTIPLY)
    canvas.set_blend_mode(BlendMode.SOURCE_OVER)

    var layer = Canvas(2, 2, Color(0, 255, 0))
    draw_canvas(canvas, layer, 2, 2)
    assert_equal(canvas.get_pixel(3, 3).g, 255)

    var small = downsample(canvas, 2)
    assert_equal(small.width, 2)

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
    assert_true("<rect" in svg.to_string())
    write_svg(svg, "tests/_test_exports.svg")


def test_root_exports_text_types() raises:
    # Enum-like types and the gradient type resolve and compare; the
    # font database and cache are constructible. Nothing here needs a
    # particular font to be installed.
    assert_true(FontSlant.ITALIC == FontSlant.ITALIC)
    assert_true(not (FontWeight.BOLD == FontWeight.NORMAL))
    assert_true(TextAlign.CENTER == TextAlign.CENTER)
    var gradient = LinearGradient(0.0, 0.0, 1.0, 0.0)
    gradient.add_stop(0.0, Color(0, 0, 0))
    assert_equal(gradient.color_at(0.0, 0.0).a, 255)
    var database = FontDatabase()
    var cache = FontCache()
    _ = len(database.faces)
    _ = cache^
    _ = resolve_font_file  # the free function is re-exported too


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
