"""Generates docs/src/examples/*.md from examples/*.mojo, run as part of
`pixi run docs` before `mojo doc`/`modo build`, so a new example gets a
docs page without anyone hand-writing one.

The shown snippet is the whole example file minus its leading module
docstring: nothing is extracted or trimmed, because each example is the
pattern being taught start to finish -- imports, any helper, `main()`,
and the write_bmp()/write_png() call producing the picture above the
snippet. Page titles and descriptions live in explicit documentation
metadata below; module docstrings remain free to explain the source.

A Mojo script rather than Python, so this repo's tooling stays in the
language it showcases. String primitives (`.strip()`, `.startswith()`,
`.find()`) do what Python's `re` would; Mojo has no regex module.

Adding an example: list it in `_titles()`, `_descriptions()`, and exactly
one category in `_categories()`. `main()`'s assertions catch omissions --
a file with no metadata or category, or a category naming a file that
doesn't exist -- rather than skipping it silently or failing deep in
formatting.
"""

from std.collections import Dict
from std.os import listdir

comptime _EXAMPLES_DIR = "examples"
comptime _OUT_DIR = "docs/src/examples"


def _titles() -> Dict[String, String]:
    var d = Dict[String, String]()
    d["fill_rect_blend"] = "Fill & Blend"
    d["blend_modes"] = "Blend & Composite Modes"
    d["rect_stroke"] = "Rectangle Stroke"
    d["lines"] = "Lines"
    d["circles"] = "Circles"
    d["ellipse"] = "Ellipses"
    d["arc"] = "Arcs & Wedges"
    d["polyline"] = "Polylines"
    d["polygon"] = "Polygons"
    d["path"] = "Paths"
    d["fill_rule"] = "Fill Rules"
    d["gradient"] = "Gradients"
    d["conic_gradient"] = "Conic Gradients"
    d["color_space"] = "Linear-Light Color"
    d["patterns"] = "Pattern Fills"
    d["dashes"] = "Dashes"
    d["transform"] = "Transforms"
    d["canvas_state"] = "Canvas Transform State"
    d["clipping"] = "Clipping"
    d["layers"] = "Layers & Compositing"
    d["draw_image"] = "Drawing a Canvas Scaled & Rotated"
    d["shadows"] = "Shadows & Blur"
    d["clip_path"] = "Clipping to a Path"
    d["masks"] = "Alpha Masks"
    d["joins"] = "Caps & Joins"
    d["png_output"] = "PNG I/O"
    d["transparency"] = "Transparency"
    d["text"] = "Text"
    d["text_on_path"] = "Text on a Path & Stroked Text"
    d["vector"] = "Vector Output"
    return d^


def _descriptions() -> Dict[String, String]:
    """Website copy kept separate from the example source docstrings."""
    var d = Dict[String, String]()
    d["fill_rect_blend"] = "Fill rectangles and layer translucent colors."
    d["blend_modes"] = "Compare blend and Porter-Duff composite modes."
    d["rect_stroke"] = "Draw crisp rectangle outlines at several widths."
    d["lines"] = "Compare hard-edged and anti-aliased lines."
    d[
        "circles"
    ] = "Compare filled, outlined, hard-edged, and anti-aliased circles."
    d[
        "ellipse"
    ] = "Compare filled, outlined, hard-edged, and anti-aliased ellipses."
    d["arc"] = "Draw arcs, wedges, and ring sectors."
    d[
        "polyline"
    ] = "Connect several points with hard-edged and anti-aliased lines."
    d[
        "polygon"
    ] = "Compare polygon outlines and fills with and without anti-aliasing."
    d[
        "path"
    ] = "Build and fill a multi-subpath shape with lines and Bezier curves."
    d["fill_rule"] = "Compare even-odd and nonzero filling on one path."
    d["gradient"] = "Apply linear and radial gradients to rectangles and paths."
    d["conic_gradient"] = "Sweep colors around a center with conic gradients."
    d[
        "color_space"
    ] = "Compare sRGB and linear-light interpolation and blending."
    d["patterns"] = "Fill geometry from a repeating canvas pattern."
    d["dashes"] = "Apply dash patterns to lines and polygon outlines."
    d[
        "transform"
    ] = "Map data coordinates into a translated and rotated pixel frame."
    d["canvas_state"] = "Compose transforms with Canvas save and restore state."
    d["clipping"] = "Restrict drawing to stacked rectangular clip regions."
    d["layers"] = "Compose independently rendered canvases into one image."
    d["draw_image"] = "Place a scaled and rotated canvas through a matrix."
    d["shadows"] = "Blur pixels and draw a reusable shadowed shape."
    d["clip_path"] = "Restrict drawing to an arbitrary path."
    d["masks"] = "Control per-pixel coverage with alpha masks."
    d["joins"] = "Compare stroke caps, joins, and miter limits."
    d["png_output"] = "Write a PNG and read its pixels back."
    d["transparency"] = "Preserve a transparent background in PNG output."
    d["text"] = "Render aligned and rotated text from system fonts."
    d["text_on_path"] = "Place text along a curve and draw outlined glyphs."
    d["vector"] = "Render one DrawTarget routine to PNG, SVG, and PDF."
    return d^


struct Category(Copyable, Movable):
    var title: String
    var blurb: String
    var names: List[String]

    def __init__(
        out self, title: String, blurb: String, var names: List[String]
    ):
        self.title = title
        self.blurb = blurb
        self.names = names^


def _categories() -> List[Category]:
    var cats = List[Category]()
    cats.append(
        Category(
            "Shapes & lines",
            (
                "The discrete shape primitives -- hard-edged and anti-aliased"
                " variants side by side."
            ),
            [
                "lines",
                "rect_stroke",
                "fill_rect_blend",
                "circles",
                "ellipse",
                "arc",
                "polyline",
                "polygon",
            ],
        )
    )
    cats.append(
        Category(
            "Paths & fills",
            (
                "The general Path API -- Bezier curves, multi-sub-path fill"
                " rules, and gradient fills."
            ),
            [
                "path",
                "fill_rule",
                "gradient",
                "conic_gradient",
                "color_space",
                "patterns",
            ],
        )
    )
    cats.append(
        Category(
            "Style",
            (
                "Control strokes, compositing, and effects independently of"
                " geometry."
            ),
            ["dashes", "joins", "blend_modes", "shadows"],
        )
    )
    cats.append(
        Category(
            "Transforms & composition",
            (
                "Move between coordinate spaces, preserve drawing state, clip"
                " content, and compose canvases."
            ),
            [
                "transform",
                "canvas_state",
                "clipping",
                "clip_path",
                "masks",
                "layers",
                "draw_image",
            ],
        )
    )
    cats.append(
        Category(
            "Text",
            (
                "Real system-font text rendering -- native font matching,"
                " TrueType parsing, bidi, text along a curve, and outlined"
                " glyphs."
            ),
            ["text", "text_on_path"],
        )
    )
    cats.append(
        Category(
            "Image I/O",
            (
                "Writing (and reading back) the pixel buffer as a real image"
                " file, and which format can carry an alpha channel."
            ),
            ["png_output", "transparency"],
        )
    )
    cats.append(
        Category(
            "Vector output",
            (
                "One drawing routine written against the DrawTarget trait,"
                " rendered through both the raster and vector backends."
            ),
            ["vector"],
        )
    )
    return cats^


def _read_file(path: String) raises -> String:
    var f = open(path, "r")
    var content = f.read()
    f.close()
    return content


def _write_file(path: String, content: String) raises:
    var f = open(path, "w")
    f.write(content)
    f.close()


def _snippet_after_docstring(source: String) -> String:
    """Everything after the leading module docstring's closing
    `\"\"\"` -- imports, helpers, `main()`, the write_bmp()/write_png()
    call -- with the separating blank lines trimmed from both ends. The
    example unabridged."""
    var start = source.find('"""')
    if start == -1:
        return String(source.strip())
    var end = source.find('"""', start + 3)
    if end == -1:
        return String(source.strip())
    var rest = String(source[byte = end + 3 :])
    return String(rest.strip())


def _build_page(
    name: String, title: String, description: String
) raises -> String:
    var source = _read_file(_EXAMPLES_DIR + "/" + name + ".mojo")
    # Every example writes both a .bmp and a .png through this
    # package's own write_png; docs display uses the .png, which
    # `pixi run docs-build` copies straight out of examples/.
    var image = "out_" + name + ".png"
    var snippet = _snippet_after_docstring(source)

    var page = List[String]()
    page.append("---")
    page.append("title: " + title)
    page.append("---")
    page.append("")
    page.append(description)
    page.append("")
    page.append("![" + title + "](" + image + ")")
    page.append("")
    page.append("## Usage")
    page.append("")
    page.append("```mojo")
    page.append(snippet)
    page.append("```")
    page.append("")
    return String("\n").join(page)


def main() raises:
    var titles = _titles()
    var descriptions = _descriptions()
    var categories = _categories()

    var all_names = List[String]()
    for entry in listdir(_EXAMPLES_DIR):
        if entry.endswith(".mojo"):
            all_names.append(
                String(entry[byte = 0 : entry.byte_length() - 5])
            )  # 5 == len(".mojo")
    sort(all_names)

    var categorized = List[String]()
    for cat in categories:
        for n in cat.names:
            categorized.append(n)

    for n in all_names:
        if n not in categorized:
            raise Error("Example not placed in any category: " + n)
    for n in categorized:
        if n not in all_names:
            raise Error("Category references a non-existent example: " + n)
    for n in all_names:
        if n not in titles:
            raise Error("Example has no title: " + n)
        if n not in descriptions:
            raise Error("Example has no description: " + n)

    for n in all_names:
        var page = _build_page(n, titles[n], descriptions[n])
        _write_file(_OUT_DIR + "/" + n + ".md", page)

    var idx = List[String]()
    idx.append("---")
    idx.append("title: Examples")
    idx.append("type: docs")
    idx.append("weight: 200")
    idx.append("cascade:")
    idx.append("  type: docs")
    idx.append("---")
    idx.append("")
    idx.append(
        "Every example below is a complete, runnable `.mojo` file in this "
        "repo's own `examples/` directory -- each page shows the actual "
        "source next to its actual rendered output, so you can see "
        "exactly what it takes to draw that primitive."
    )
    idx.append("")
    for cat in categories:
        idx.append("## " + cat.title)
        idx.append("")
        idx.append(cat.blurb)
        idx.append("")
        idx.append("| | |")
        idx.append("| --- | --- |")
        var i = 0
        while i < len(cat.names):
            var left = cat.names[i]
            var left_card = (
                "[!["
                + titles[left]
                + "](out_"
                + left
                + ".png)]("
                + left
                + "/) **["
                + titles[left]
                + "]("
                + left
                + "/)** — "
                + descriptions[left]
            )
            var right_card = ""
            if i + 1 < len(cat.names):
                var right = cat.names[i + 1]
                right_card = (
                    "[!["
                    + titles[right]
                    + "](out_"
                    + right
                    + ".png)]("
                    + right
                    + "/) **["
                    + titles[right]
                    + "]("
                    + right
                    + "/)** — "
                    + descriptions[right]
                )
            idx.append("| " + left_card + " | " + right_card + " |")
            i += 2
        idx.append("")
    _write_file(_OUT_DIR + "/_index.md", String("\n").join(idx))

    print("Wrote", len(all_names), "example pages + _index.md to", _OUT_DIR)
