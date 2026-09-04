"""Generates docs/src/examples/*.md from examples/*.mojo, run as part of
`pixi run docs` before `mojo doc`/`modo build`, so a new example gets a
docs page without anyone hand-writing one.

The shown snippet is the whole example file minus its leading module
docstring: nothing is extracted or trimmed, because each example is the
pattern being taught start to finish -- imports, any helper, `main()`,
and the write_bmp()/write_png() call producing the picture above the
snippet. The docstring becomes the page's hook sentence and prose
instead (see `_first_sentence()`).

A Mojo script rather than Python, so this repo's tooling stays in the
language it showcases. String primitives (`.strip()`, `.startswith()`,
`.find()`) do what Python's `re` would; Mojo has no regex module.

Adding an example: list it in both `_titles()` and exactly one category
in `_categories()`. `main()`'s assertions catch either omission -- a
file with no category, or a category naming a file that doesn't exist --
rather than skipping it silently or failing deep in formatting.
"""

from std.collections import Dict
from std.os import listdir

comptime _EXAMPLES_DIR = "examples"
comptime _OUT_DIR = "docs/src/examples"


def _titles() -> Dict[String, String]:
    var d = Dict[String, String]()
    d["fill_rect_blend"] = "Fill & Blend"
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
    d["dashes"] = "Dashes"
    d["transform"] = "Transforms"
    d["canvas_state"] = "Canvas Transform State"
    d["clipping"] = "Clipping"
    d["layers"] = "Layers & Compositing"
    d["clip_path"] = "Clipping to a Path"
    d["joins"] = "Caps & Joins"
    d["png_output"] = "PNG I/O"
    d["transparency"] = "Transparency"
    d["text"] = "Text"
    d["vector"] = "Vector Output"
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
            ["path", "fill_rule", "gradient", "conic_gradient"],
        )
    )
    cats.append(
        Category(
            "Styling & transforms",
            (
                "Dash patterns, the Transform2D coordinate pipeline, the"
                " canvas's own save/restore transform state, clip regions,"
                " and composing separate layers into one image."
            ),
            [
                "dashes",
                "joins",
                "transform",
                "canvas_state",
                "clipping",
                "clip_path",
                "layers",
            ],
        )
    )
    cats.append(
        Category(
            "Text",
            (
                "Real system-font text rendering -- native font matching,"
                " TrueType parsing, bidi."
            ),
            ["text"],
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


def _extract_docstring(source: String) -> String:
    var start = source.find('"""')
    if start == -1:
        return ""
    var content_start = start + 3
    var end = source.find('"""', content_start)
    if end == -1:
        return ""
    var raw = String(source[byte=content_start:end])
    return String(raw.strip())


def _first_sentence(docstring: String) -> String:
    # Every docstring starts "Demo: <one-line hook> -- <detail>".
    # Collapse the first paragraph's hand-wrapped newlines into one
    # line, then cut at the first " -- " if present, else keep the
    # whole first sentence.
    var para_end = docstring.find("\n\n")
    var first_para = (
        String(docstring[byte=0:para_end]) if para_end != -1 else docstring
    )

    var words = List[String]()
    for line in first_para.split("\n"):
        var stripped = String(line.strip())
        if stripped:
            words.append(stripped)
    var flat = String(" ").join(words)

    if flat.startswith("Demo: "):
        var without_prefix = String(flat[byte=6:])  # 6 == len("Demo: ")
        flat = without_prefix

    var idx = flat.find(" -- ")
    var sentence = String(flat[byte=0:idx]) if idx != -1 else flat
    var trimmed = String(sentence.strip())
    sentence = trimmed
    if sentence.endswith("."):
        var without_dot = String(
            sentence[byte = 0 : sentence.byte_length() - 1]
        )
        sentence = without_dot
    sentence = sentence + "."

    var first_char = String(sentence[byte=0:1]).upper()
    return first_char + String(sentence[byte=1:])


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


def _build_page(name: String, title: String) raises -> String:
    var source = _read_file(_EXAMPLES_DIR + "/" + name + ".mojo")
    var docstring = _extract_docstring(source)
    var hook = _first_sentence(docstring)
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
    page.append(hook)
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

    for n in all_names:
        var page = _build_page(n, titles[n])
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
        for n in cat.names:
            idx.append("- [" + titles[n] + "](" + n + "/)")
        idx.append("")
    _write_file(_OUT_DIR + "/_index.md", String("\n").join(idx))

    print("Wrote", len(all_names), "example pages + _index.md to", _OUT_DIR)
