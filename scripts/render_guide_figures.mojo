"""Render guide illustrations with the library whose conventions they teach.

The documentation build creates the destination directory first. Text bounds
come from the same layout and font cache used to draw the illustrated glyphs.
"""

from canvas import (
    Canvas,
    Color,
    FontCache,
    draw_layout,
    draw_text,
    measure_layout,
    measure_text,
    prepare_text,
    write_png,
)

comptime _DIR = "docs/site/static/guide-figures/"


def label(
    mut canvas: Canvas,
    x: Int,
    y: Int,
    text: String,
    mut cache: FontCache,
    size: Float64 = 18.0,
) raises:
    draw_text(canvas, x, y, text, Color(35, 45, 60), size, cache=cache)


def pixels(mut cache: FontCache) raises:
    var canvas = Canvas(720, 350, Color(250, 250, 252))
    var sample = Canvas(6, 4, Color(235, 239, 245))
    sample.fill_rect(2, 1, 3, 2, Color(40, 100, 200))
    label(canvas, 30, 34, "Pixel centers and rectangle edges", cache, 24.0)
    # Enlarge the actual six-by-four raster without smoothing its pixels.
    for y in range(4):
        for x in range(6):
            canvas.fill_rect(
                50 + x * 50, 75 + y * 50, 49, 49, sample.get_pixel(x, y)
            )
            canvas.fill_circle_aa(
                75 + x * 50, 100 + y * 50, 2, Color(25, 35, 50)
            )
    for x in range(6):
        label(canvas, 70 + x * 50, 65, String(x), cache)
    for y in range(4):
        label(canvas, 25, 106 + y * 50, String(y), cache)
    label(canvas, 385, 104, "Blue pixels: x = 2, 3, 4", cache)
    label(canvas, 385, 134, "Rows: y = 1, 2", cache)
    label(canvas, 385, 184, "Left edge: x = 1.5", cache)
    label(canvas, 385, 214, "Right edge: x = 4.5", cache)
    label(canvas, 385, 264, "Dots mark pixel centers.", cache)
    label(
        canvas,
        50,
        316,
        "fill_rect(2, 1, 3, 2) = fill_rect(1.5, 0.5, 3.0, 2.0)",
        cache,
    )
    write_png(canvas, _DIR + "pixels.png")


def transforms(mut cache: FontCache) raises:
    var canvas = Canvas(720, 310, Color(250, 250, 252))
    label(canvas, 30, 34, "Transform order changes placement", cache, 24.0)
    label(canvas, 30, 78, "translate(60, 0), then scale(2, 2)", cache, 17.0)
    label(canvas, 375, 78, "scale(2, 2), then translate(60, 0)", cache, 17.0)
    for i in range(2):
        var origin = 55 + i * 345
        canvas.draw_line_aa(
            origin, 155, origin + 250, 155, Color(150, 160, 175)
        )
        canvas.draw_line_aa(origin, 100, origin, 210, Color(150, 160, 175))
        canvas.save()
        canvas.translate(Float64(origin), 155.0)
        if i == 0:
            canvas.translate(60.0, 0.0)
            canvas.scale(2.0, 2.0)
        else:
            canvas.scale(2.0, 2.0)
            canvas.translate(60.0, 0.0)
        canvas.fill_rect(0.0, -15.0, 40.0, 30.0, Color(40, 100, 200, 75))
        canvas.fill_circle_aa(20.0, 0.0, 3.0, Color(40, 100, 200))
        canvas.restore()
        label(canvas, origin - 4, 235, "0", cache)
    label(
        canvas, 30, 280, "x = 20 becomes 60 + 2 * 20 = 100", cache, 16.0
    )
    label(
        canvas,
        375,
        280,
        "x = 20 becomes 2 * (60 + 20) = 160",
        cache,
        16.0,
    )
    write_png(canvas, _DIR + "transforms.png")


def text_bounds(mut cache: FontCache) raises:
    var canvas = Canvas(720, 310, Color(250, 250, 252))
    label(canvas, 30, 34, "Text anchor, ink bounds, and advance", cache, 24.0)
    var text = String("Ag ")
    var layout = prepare_text(text, 80.0, cache=cache)
    var bounds = measure_layout(layout)
    var metrics = measure_text(text, 80.0, cache=cache)
    var x = 65.0
    var y = 145.0
    canvas.fill_rect(
        x + bounds.x,
        y + bounds.y,
        bounds.width,
        bounds.height,
        Color(30, 160, 80, 45),
    )
    draw_layout(canvas, x, y, layout, Color(35, 45, 60), cache=cache)
    canvas.draw_line_aa(35.0, y, 325.0, y, Color(40, 100, 200))
    canvas.fill_circle_aa(x, y, 4.0, Color(40, 100, 200))
    canvas.draw_line_aa(
        x, 205.0, x + metrics.advance, 205.0, Color(180, 90, 20)
    )
    canvas.draw_line_aa(x, 198.0, x, 212.0, Color(180, 90, 20))
    canvas.draw_line_aa(
        x + metrics.advance,
        198.0,
        x + metrics.advance,
        212.0,
        Color(180, 90, 20),
    )
    label(canvas, 65, 242, "advance (includes the trailing space)", cache, 16.0)
    label(canvas, 365, 95, "Green: tight ink bounding box", cache)
    label(canvas, 365, 130, "Blue: baseline and left anchor", cache)
    label(canvas, 365, 165, "The g extends below the baseline.", cache)
    label(canvas, 365, 200, "The trailing space has no ink.", cache)
    label(
        canvas,
        30,
        287,
        "Draw the bounds at (anchor.x + bounds.x, anchor.y + bounds.y).",
        cache,
    )
    write_png(canvas, _DIR + "text-bounds.png")


def main() raises:
    var cache = FontCache()
    pixels(cache)
    transforms(cache)
    text_bounds(cache)
