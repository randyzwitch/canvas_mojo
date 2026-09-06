"""Tests for `ColorSpace`: the sRGB transfer tables, linear-light
source-over on the canvas, gradient interpolation in linear light,
and the SVG backend's `color-interpolation` attribute.

The numbers are the textbook ones. A 50% mix of black and white in
linear light reflects half the light, which sRGB encodes as 188 (the
transfer function's value at 0.5 is 0.7354); mixed by byte value it
is 128. A red-to-green ramp's midpoint is (188, 188, 0) in linear
light and (128, 128, 0) by byte.
"""

from std.testing import assert_equal, assert_true, TestSuite

from canvas.blend import BlendMode
from canvas.buffer import Canvas
from canvas.color import Color, ColorSpace, _Transfer
from canvas.compose import draw_canvas
from canvas.gradient import GradientStops, LinearGradient
from canvas.shapes.rects import fill_rect, fill_rect_gradient
from canvas.vector.svg import SvgCanvas

comptime WHITE = Color(255, 255, 255)
comptime BLACK = Color(0, 0, 0)
comptime HALF_WHITE = Color(255, 255, 255, 128)


def _close(a: UInt8, b: Int, tol: Int) -> Bool:
    return abs(Int(a) - b) <= tol


def test_transfer_round_trips_every_byte() raises:
    var t = _Transfer()
    t.build()
    for i in range(256):
        assert_equal(
            t.byte(t.linear(UInt8(i))),
            UInt8(i),
            String("byte ", i, " must survive linear and back"),
        )
    assert_true(t.linear(0) == 0.0, "black is zero light")
    assert_true(t.linear(255) == 1.0, "white is unit light")
    assert_true(
        t.linear(128) > 0.21 and t.linear(128) < 0.22,
        "sRGB 128 is about 21.6% light",
    )


def test_canvas_blends_in_linear_light_when_asked() raises:
    var srgb = Canvas(4, 4, BLACK)
    fill_rect(srgb, 0, 0, 4, 4, HALF_WHITE)
    assert_true(_close(srgb.get_pixel(1, 1).r, 128, 1), "sRGB: byte midpoint")

    var linear = Canvas(4, 4, BLACK)
    linear.set_color_space(ColorSpace.LINEAR)
    assert_true(linear.color_space() == ColorSpace.LINEAR, "space is set")
    fill_rect(linear, 0, 0, 4, 4, HALF_WHITE)
    var p = linear.get_pixel(1, 1)
    assert_true(
        _close(p.r, 188, 1), String("linear: half the light, got ", p.r)
    )
    assert_equal(p.a, 255, "opaque backdrop stays opaque")

    # The same through set_pixel and write_pixel, one pixel at a time.
    var one = Canvas(2, 2, BLACK)
    one.set_color_space(ColorSpace.LINEAR)
    one.set_pixel(0, 0, HALF_WHITE)
    one.write_pixel(1, 1, HALF_WHITE)
    assert_true(_close(one.get_pixel(0, 0).r, 188, 1), "set_pixel in linear")
    assert_true(_close(one.get_pixel(1, 1).r, 188, 1), "write_pixel in linear")


def test_linear_blend_onto_translucent_backdrop() raises:
    var c = Canvas(2, 1, Color(0, 0, 0, 0))
    c.set_color_space(ColorSpace.LINEAR)
    c.set_pixel(0, 0, Color(255, 255, 255, 128))
    var p = c.get_pixel(0, 0)
    # Over a transparent backdrop the source is the result, in either
    # space.
    assert_equal(p.a, 128, "alpha is the source's over transparency")
    assert_equal(p.r, 255, "color is the source's over transparency")
    c.set_pixel(0, 0, Color(0, 0, 0, 128))
    p = c.get_pixel(0, 0)
    # Half black over half white: the light is 0.5 * 0.5 / 0.75 = 1/3
    # of full, sRGB 156; by byte it would be 85.
    assert_true(
        _close(p.r, 156, 2), String("linear over translucent, got ", p.r)
    )


def test_composite_and_draw_canvas_follow_the_space() raises:
    var layer = Canvas(3, 3, HALF_WHITE)
    var dst = Canvas(3, 3, BLACK)
    dst.set_color_space(ColorSpace.LINEAR)
    draw_canvas(dst, layer, 0, 0)
    assert_true(
        _close(dst.get_pixel(1, 1).r, 188, 1),
        "draw_canvas blends in linear light",
    )

    var alphas: List[UInt8] = [128, 128, 128]
    var row = Canvas(3, 1, BLACK)
    row.set_color_space(ColorSpace.LINEAR)
    row.composite_alpha_row(0, 0, alphas, 0, 3, WHITE)
    assert_true(
        _close(row.get_pixel(2, 0).r, 188, 1),
        "composite_alpha_row blends in linear light",
    )


def test_blend_modes_stay_in_srgb() raises:
    var c = Canvas(1, 1, Color(128, 128, 128))
    c.set_color_space(ColorSpace.LINEAR)
    c.set_blend_mode(BlendMode.MULTIPLY)
    c.set_pixel(0, 0, Color(128, 128, 128))
    # Multiply of two byte-128 grays by byte value.
    assert_true(
        _close(c.get_pixel(0, 0).r, 64, 1), "multiply is unchanged by the space"
    )


def test_save_restore_carries_the_space() raises:
    var c = Canvas(1, 1, BLACK)
    c.save()
    c.set_color_space(ColorSpace.LINEAR)
    c.restore()
    assert_true(c.color_space() == ColorSpace.SRGB, "restore puts SRGB back")
    c.set_color_space(ColorSpace.LINEAR)
    c.save()
    c.set_color_space(ColorSpace.SRGB)
    c.restore()
    assert_true(
        c.color_space() == ColorSpace.LINEAR, "restore puts LINEAR back"
    )


def test_gradient_interpolates_in_linear_light() raises:
    var stops = GradientStops()
    stops.add_stop(0.0, Color(255, 0, 0))
    stops.add_stop(1.0, Color(0, 255, 0))
    var mid = stops.color_at(0.5)
    assert_true(
        _close(mid.r, 128, 1) and _close(mid.g, 128, 1), "sRGB midpoint by byte"
    )
    stops.set_color_space(ColorSpace.LINEAR)
    mid = stops.color_at(0.5)
    assert_true(
        _close(mid.r, 188, 1) and _close(mid.g, 188, 1) and mid.b == 0,
        String("linear midpoint, got ", mid.r, " ", mid.g),
    )
    assert_equal(stops.color_at(0.0).r, 255, "the ends are the stops")
    assert_equal(stops.color_at(1.0).g, 255, "the ends are the stops")
    # A copy keeps the space.
    var copy = stops.copy()
    assert_true(copy.color_space() == ColorSpace.LINEAR, "copy keeps the space")
    assert_true(
        _close(copy.color_at(0.5).r, 188, 1), "copy interpolates the same"
    )

    var g = LinearGradient(0.0, 0.0, 10.0, 0.0)
    g.add_stop(0.0, Color(255, 0, 0))
    g.add_stop(1.0, Color(0, 255, 0))
    g.set_color_space(ColorSpace.LINEAR)
    var c = Canvas(10, 1, BLACK)
    fill_rect_gradient(c, 0, 0, 10, 1, g)
    var p = c.get_pixel(5, 0)
    assert_true(
        _close(p.r, 188, 3) and _close(p.g, 188, 3),
        "a filled linear-light ramp",
    )


def test_svg_emits_color_interpolation() raises:
    var svg = SvgCanvas(10, 10)
    svg.fill_rect(0, 0, 5, 5, Color(1, 2, 3))
    var plain = svg.to_string()
    assert_true("color-interpolation" not in plain, "nothing under SRGB")
    svg.set_color_space(ColorSpace.LINEAR)
    svg.fill_rect(0, 0, 5, 5, Color(1, 2, 3))
    var g = LinearGradient(0.0, 0.0, 10.0, 0.0)
    g.add_stop(0.0, Color(255, 0, 0))
    g.add_stop(1.0, Color(0, 255, 0))
    g.set_color_space(ColorSpace.LINEAR)
    svg.fill_rect_gradient(0, 0, 10, 10, g)
    var markup = svg.to_string()
    assert_true(
        "<rect" in markup and 'color-interpolation="linearRGB"' in markup,
        "elements carry the attribute under LINEAR",
    )
    assert_true(
        '<linearGradient id="grad1" color-interpolation="linearRGB"' in markup,
        "a linear-light ramp carries it on the gradient",
    )
    svg.save()
    svg.set_color_space(ColorSpace.SRGB)
    svg.restore()
    assert_true(
        svg.color_space() == ColorSpace.LINEAR, "save/restore carries it"
    )


def test_color_space_is_printable_and_comparable() raises:
    assert_equal(String(ColorSpace.LINEAR), "LINEAR")
    assert_equal(String(ColorSpace.SRGB), "SRGB")
    assert_true(ColorSpace.LINEAR != ColorSpace.SRGB)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
