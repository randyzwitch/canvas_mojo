"""Demo: alpha masks -- a coverage separated from how it was made,
then painted through, composited through, and clipped to.

Three panels:

- a conic gradient painted through a star-shaped path mask with
  `fill_mask_source`: the gradient takes the star's shape, edge
  anti-aliased, without a gradient-filling primitive for stars
- a layer of coloured bars faded through the alpha of a blurred disk
  with the masked `draw_canvas`: a soft vignette, from a mask built
  by drawing rather than by geometry
- a hatch pattern clipped to the luminance of a radial gradient with
  `push_clip_mask`: dense at the bright center, gone at the dark rim

Run with:
    pixi run example
"""

from std.math import cos, pi, sin

from canvas.blur import blur
from canvas.buffer import Canvas
from canvas.color import Color
from canvas.compose import draw_canvas
from canvas.gradient import ConicGradient, RadialGradient
from canvas.io.bmp import write_bmp
from canvas.io.png import write_png
from canvas.mask import Mask, fill_mask_source, push_clip_mask
from canvas.path import Path
from canvas.pattern import Extend, Hatch, PatternSource, hatch_tile
from canvas.shapes.circles import fill_circle_aa
from canvas.shapes.rects import (
    fill_rect,
    fill_rect_pattern,
    fill_rect_radial_gradient,
)
from canvas.text.font_cache import FontCache
from canvas.text.render import draw_text

comptime PAGE = Color(255, 255, 255)
comptime PANEL = Color(238, 238, 242)
comptime INK = Color(45, 45, 55)

comptime PANEL_W = 240
comptime PANEL_H = 240


def _star(
    cx: Float64, cy: Float64, outer: Float64, inner: Float64
) raises -> Path:
    """A five-pointed star, alternating outer and inner radii."""
    var p = Path()
    for i in range(10):
        var r = outer if i % 2 == 0 else inner
        var a = -pi / 2.0 + Float64(i) * pi / 5.0
        var x = cx + r * cos(a)
        var y = cy + r * sin(a)
        if i == 0:
            p.move_to(x, y)
        else:
            p.line_to(x, y)
    p.close()
    return p^


def _gradient_through_a_star(mut c: Canvas, x: Int, y: Int) raises:
    fill_rect(c, x, y, PANEL_W, PANEL_H, PANEL)
    var cx = Float64(x + PANEL_W // 2)
    var cy = Float64(y + PANEL_H // 2)
    # The mask is the panel's size, placed at the panel's corner, so
    # the star is built in mask coordinates.
    var star = _star(Float64(PANEL_W // 2), Float64(PANEL_H // 2), 100.0, 42.0)
    var mask = Mask.from_path(star, PANEL_W, PANEL_H)
    var conic = ConicGradient(cx, cy, 0.0)
    conic.add_stop(0.0, Color(220, 70, 60))
    conic.add_stop(0.33, Color(60, 120, 210))
    conic.add_stop(0.66, Color(80, 180, 110))
    conic.add_stop(1.0, Color(220, 70, 60))
    fill_mask_source(c, mask, conic, x, y)


def _layer_through_a_soft_disk(mut c: Canvas, x: Int, y: Int) raises:
    fill_rect(c, x, y, PANEL_W, PANEL_H, PANEL)
    # The layer: vertical bars, drawn in its own coordinates.
    var layer = Canvas(PANEL_W, PANEL_H, Color(0, 0, 0, 0))
    var bar_w = 24
    for i in range(PANEL_W // bar_w):
        var shade = 60 + (i * 37) % 160
        fill_rect(
            layer,
            i * bar_w,
            0,
            bar_w,
            PANEL_H,
            Color(UInt8(shade), UInt8(90), UInt8(255 - shade)),
        )
    # The mask: a disk drawn on a transparent canvas and blurred, so
    # its alpha ramps over ~20 pixels.
    var stencil = Canvas(PANEL_W, PANEL_H, Color(0, 0, 0, 0))
    fill_circle_aa(
        stencil, Float64(PANEL_W // 2), Float64(PANEL_H // 2), 80.0, INK
    )
    blur(stencil, 10.0)
    draw_canvas(c, layer, x, y, Mask.from_alpha(stencil))


def _pattern_clipped_by_a_luminance(mut c: Canvas, x: Int, y: Int) raises:
    fill_rect(c, x, y, PANEL_W, PANEL_H, PANEL)
    # The mask: a radial gradient from white at the center to black at
    # the rim, read as luminance.
    var glow = Canvas(PANEL_W, PANEL_H, Color(0, 0, 0))
    var radial = RadialGradient(
        Float64(PANEL_W // 2), Float64(PANEL_H // 2), 110.0
    )
    radial.add_stop(0.0, Color(255, 255, 255))
    radial.add_stop(1.0, Color(0, 0, 0))
    fill_rect_radial_gradient(glow, 0, 0, PANEL_W, PANEL_H, radial)
    var tile = hatch_tile(10, 2.5, INK, Color(0, 0, 0, 0), Hatch.DIAGONAL)
    var pattern = PatternSource(tile, Extend.REPEAT)
    push_clip_mask(c, Mask.from_luminance(glow), x, y)
    fill_rect_pattern(c, x, y, PANEL_W, PANEL_H, pattern)
    c.pop_clip_path()


def main() raises:
    var c = Canvas(3 * PANEL_W + 60, PANEL_H + 100, PAGE)
    var cache = FontCache()

    draw_text(c, 15, 28, "Alpha masks", INK, 18.0, cache=cache)

    var left = 15
    var top = 44
    var step_x = PANEL_W + 15

    _gradient_through_a_star(c, left, top)
    draw_text(
        c,
        left + 4,
        top + PANEL_H + 18,
        "gradient through a path mask",
        INK,
        14.0,
        cache=cache,
    )
    _layer_through_a_soft_disk(c, left + step_x, top)
    draw_text(
        c,
        left + step_x + 4,
        top + PANEL_H + 18,
        "layer through a blurred alpha",
        INK,
        14.0,
        cache=cache,
    )
    _pattern_clipped_by_a_luminance(c, left + 2 * step_x, top)
    draw_text(
        c,
        left + 2 * step_x + 4,
        top + PANEL_H + 18,
        "pattern clipped by a luminance",
        INK,
        14.0,
        cache=cache,
    )

    write_bmp(c, "examples/out_masks.bmp")
    write_png(c, "examples/out_masks.png")
    print("wrote examples/out_masks.bmp and .png")
