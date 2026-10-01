"""Record a small illustration once and replay it into several targets."""

from canvas import (
    Canvas,
    Color,
    DisplayList,
    DrawTarget,
    FontCache,
    Path,
    PdfCanvas,
    SvgCanvas,
    write_png,
    write_pdf,
    write_svg,
)


def _badge[T: DrawTarget](mut target: T, mut cache: FontCache) raises:
    target.save()
    var outline = Path()
    outline.round_rect(0.0, 0.0, 120.0, 80.0, 12.0)
    target.push_clip_path(outline)
    target.fill_rect(0.0, 0.0, 120.0, 80.0, Color(230, 240, 250))
    target.begin_batch()
    for i in range(5):
        var height = Float64(15 + i * 7)
        target.fill_rect(
            12.0 + Float64(i) * 20.0,
            60.0 - height,
            12.0,
            height,
            Color(35, 95, 175),
        )
    target.end_batch()
    target.draw_text(
        12.0, 73.0, "Recorded once", Color(25, 45, 65), 10.0, cache=cache
    )
    target.pop_clip_path()
    target.restore()


def _place[
    T: DrawTarget
](mut target: T, scene: DisplayList, mut cache: FontCache) raises:
    target.save()
    target.translate(20.0, 25.0)
    scene.replay(target, cache=cache)
    target.restore()
    target.save()
    target.translate(180.0, 25.0)
    target.scale(2.0, 2.0)
    scene.replay(target, cache=cache)
    target.restore()


def main() raises:
    var cache = FontCache()
    var scene = DisplayList()
    _badge(scene, cache)
    var raster = Canvas(440, 210, Color(255, 255, 255))
    var svg = SvgCanvas(440, 210)
    var pdf = PdfCanvas(440, 210)
    _place(raster, scene, cache)
    _place(svg, scene, cache)
    _place(pdf, scene, cache)
    write_png(raster, "examples/out_display_list.png")
    write_svg(svg, "examples/out_display_list.svg")
    write_pdf(pdf, "examples/out_display_list.pdf")
    print("wrote examples/out_display_list.png, .svg and .pdf")
