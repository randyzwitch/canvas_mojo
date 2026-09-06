"""Tests for vector/pdf.mojo: what each `DrawTarget` call becomes in
the page's content stream, the resources those calls register, the
embedded fonts real text draws with, pages and images, the file's
structure (objects, the cross-reference table's offsets, the
compressed stream inflating back to the operators), and the state
stack. The operators are read back from `PdfCanvas.content()` as
text, the way test_svg.mojo reads markup.

Rendering correctness -- that a viewer draws the same picture the
raster backend does, and that a viewer extracts the text drawn --
was checked by rendering the file through `pdftoppm` beside
`write_png` of the same scene and by `pdftotext`, which a Mojo test
cannot do; see the wiki Changelog for those comparisons.
"""

from std.math import pi
from std.testing import assert_equal, assert_true, TestSuite

from canvas.blend import BlendMode
from canvas.buffer import Canvas
from canvas.color import Color, ColorSpace
from canvas.text.font_discovery import FontSlant, FontWeight
from canvas.fill_rule import FillRule
from canvas.geometry import Matrix2D
from canvas.gradient import LinearGradient, RadialGradient
from canvas.io.deflate import inflate
from canvas.path import Path
from canvas.shapes.lines import LineCap, LineJoin
from canvas.text.font_cache import FontCache
from canvas.vector.pdf import PdfCanvas, write_pdf, _pdf_string

comptime INK = Color(30, 60, 120)


def _bytes_to_string(data: List[UInt8]) -> String:
    var s = String()
    for b in data:
        s += chr(Int(b)) if Int(b) < 128 else "."
    return s


def test_fill_rect_is_re_f_with_rgb_fill() raises:
    var pdf = PdfCanvas(100, 80)
    pdf.fill_rect(10, 20, 30, 40, Color(255, 0, 0))
    var c = pdf.content()
    assert_true("1.000 0.000 0.000 rg" in c, "fill color as rg")
    assert_true("10.000 20.000 30.000 40.000 re f" in c, "rect then fill")
    assert_true(c.startswith("q "), "an element opens with q")
    assert_true("Q\n" in c, "and closes with Q")
    assert_true("gs" not in c, "an opaque source-over fill needs no ExtGState")


def test_translucent_color_registers_an_extgstate() raises:
    var pdf = PdfCanvas(100, 80)
    pdf.fill_rect(0, 0, 10, 10, Color(0, 0, 255, 128))
    pdf.fill_rect(0, 0, 10, 10, Color(0, 255, 0, 128))
    pdf.draw_line_aa(0.0, 0.0, 10.0, 10.0, Color(0, 0, 0, 128))
    var c = pdf.content()
    assert_true("/GS1 gs" in c, "the first translucent fill uses GS1")
    assert_true("/GS3" not in c, "the same alpha and mode share one state")
    assert_true("/GS2 gs" in c, "stroke alpha (/CA) is a different state")
    var file = _bytes_to_string(pdf.to_bytes(compress=False))
    assert_true("/GS1 << /ca 0.502 >>" in file, "fill alpha as /ca")
    assert_true("/GS2 << /CA 0.502 >>" in file, "stroke alpha as /CA")


def test_blend_mode_is_bm_and_porter_duff_is_dropped() raises:
    var pdf = PdfCanvas(100, 80)
    pdf.set_blend_mode(BlendMode.MULTIPLY)
    pdf.fill_rect(0, 0, 10, 10, INK)
    pdf.set_blend_mode(BlendMode.XOR)
    pdf.fill_rect(0, 0, 10, 10, INK)
    var file = _bytes_to_string(pdf.to_bytes(compress=False))
    assert_true("/BM /Multiply" in file, "a blend mode becomes /BM")
    assert_true("/GS2" not in file, "a Porter-Duff operator registers nothing")


def test_stroke_attributes() raises:
    var pdf = PdfCanvas(100, 80)
    var dashes: List[Float64] = [4.0, 2.0]
    pdf.draw_line_aa(
        1.0,
        2.0,
        3.0,
        4.0,
        INK,
        2.5,
        dashes,
        1.0,
        LineCap.SQUARE,
        LineJoin.MITER,
        8.0,
    )
    var c = pdf.content()
    assert_true("RG" in c and "rg" not in c, "a stroke sets RG, not rg")
    assert_true("2.500 w" in c, "line width")
    assert_true("2 J" in c, "square cap")
    assert_true("0 j" in c, "miter join")
    assert_true("8.000 M" in c, "miter limit")
    assert_true("[4.000 2.000 ] 1.000 d" in c, "dash array and phase")
    assert_true("1.000 2.000 m 3.000 4.000 l S" in c, "the segment, stroked")


def test_path_ops_and_fill_rules() raises:
    var pdf = PdfCanvas(100, 80)
    var p = Path()
    p.move_to(0.0, 0.0)
    p.line_to(10.0, 0.0)
    p.quad_curve_to(10.0, 10.0, 0.0, 10.0)
    p.cubic_curve_to(1.0, 2.0, 3.0, 4.0, 0.0, 0.0)
    p.close()
    pdf.fill_path_aa(p, INK)
    pdf.fill_path_aa(p, INK, FillRule.NONZERO)
    var c = pdf.content()
    assert_true("0.000 0.000 m 10.000 0.000 l " in c, "move and line")
    # The quadratic raised to a cubic: control points two thirds of
    # the way from each end toward the quadratic's control point.
    assert_true(
        "10.000 6.667 6.667 10.000 0.000 10.000 c" in c, "quad as cubic"
    )
    assert_true(
        "1.000 2.000 3.000 4.000 0.000 0.000 c h f*" in c,
        "cubic, close, even-odd",
    )
    assert_true("h f Q" in c, "nonzero fills with f")


def test_arcs_become_quarter_turn_cubics() raises:
    var pdf = PdfCanvas(400, 400)
    pdf.fill_arc_aa(200.0, 200.0, 100.0, 0.0, pi, INK)
    var c = pdf.content()
    assert_true(
        "200.000 200.000 m 300.000 200.000 l" in c,
        "wedge starts at the center, lines to the arc",
    )
    # A half turn is two quarter-turn cubics.
    var count = 0
    var pos = 0
    while True:
        var i = c.find(" c ", pos)
        if i < 0:
            break
        count += 1
        pos = i + 3
    assert_equal(count, 2, "two cubics for a half turn")
    assert_true(
        "100.000 200.000 c h f" in c,
        "the arc ends opposite the start and closes",
    )

    var ring = PdfCanvas(400, 400)
    ring.fill_ring_sector_aa(200.0, 200.0, 50.0, 100.0, 0.0, pi / 2.0, INK)
    var r = ring.content()
    assert_true("300.000 200.000 m" in r, "outer arc starts the sub-path")
    assert_true("200.000 250.000 l" in r, "a line to the inner arc's start")
    assert_true("h f" in r, "closed and filled")


def test_circle_and_ellipse_are_four_cubics() raises:
    var pdf = PdfCanvas(100, 100)
    pdf.fill_circle_aa(50.0, 50.0, 20.0, INK)
    var c = pdf.content()
    assert_true("70.000 50.000 m" in c, "starts at the rightmost point")
    assert_true(
        "70.000 61.046 61.046 70.000 50.000 70.000 c" in c,
        "first quadrant with kappa",
    )
    assert_true(" h f" in c, "closed and filled")
    var e = PdfCanvas(100, 100)
    e.draw_ellipse_aa(50.0, 50.0, 30.0, 10.0, INK, 2.0)
    assert_true(
        "2.000 w 80.000 50.000 m" in e.content(),
        "stroked ellipse sets the width first",
    )


def test_transform_is_cm_inside_the_element() raises:
    var pdf = PdfCanvas(100, 100)
    pdf.translate(10.0, 20.0)
    pdf.scale(2.0, 3.0)
    pdf.fill_rect(0, 0, 1, 1, INK)
    var c = pdf.content()
    assert_true(
        "q 2.000 0.000 0.000 3.000 10.000 20.000 cm" in c,
        "the matrix as cm after q",
    )
    pdf.reset_transform()
    pdf.fill_rect(0, 0, 1, 1, INK)
    assert_true(not pdf.has_transform(), "reset clears it")
    assert_true(pdf.content().count("cm") == 1, "no cm once reset")


def test_clips_and_restore_close_them() raises:
    var pdf = PdfCanvas(100, 100)
    pdf.push_clip(10, 10, 50, 50)
    pdf.fill_rect(0, 0, 100, 100, INK)
    pdf.pop_clip()
    var c = pdf.content()
    assert_true("q 10.000 10.000 50.000 50.000 re W n\n" in c, "a rect clip")
    assert_equal(c.count("Q"), 2, "the element's Q and the clip's Q")

    var s = PdfCanvas(100, 100)
    var tri = Path()
    tri.move_to(0.0, 0.0)
    tri.line_to(50.0, 0.0)
    tri.line_to(0.0, 50.0)
    tri.close()
    s.save()
    s.push_clip_path(tri, FillRule.NONZERO)
    s.push_clip(0, 0, 10, 10)
    s.restore()
    assert_true("h W n\n" in s.content(), "a path clip under nonzero")
    assert_equal(s.content().count("Q\n"), 2, "restore pops both clips")

    # Under a transform the clip's points are mapped, not the clip
    # written under a cm of its own.
    var t = PdfCanvas(100, 100)
    t.translate(5.0, 5.0)
    t.push_clip(0, 0, 10, 10)
    assert_true("cm" not in t.content(), "no cm for a clip")
    assert_true(
        "5.000 5.000 m 15.000 5.000 l" in t.content(),
        "the rectangle's corners moved by the translation",
    )


def test_gradients_become_shadings() raises:
    var pdf = PdfCanvas(200, 100)
    var g = LinearGradient(0.0, 0.0, 200.0, 0.0)
    g.add_stop(0.0, Color(255, 0, 0))
    g.add_stop(1.0, Color(0, 0, 255))
    pdf.fill_rect_gradient(0, 0, 200, 100, g)
    var c = pdf.content()
    assert_true(
        "re W n /Sh1 sh" in c, "clip to the rect, then paint the shading"
    )
    var file = _bytes_to_string(pdf.to_bytes(compress=False))
    assert_true("/ShadingType 2" in file, "axial")
    assert_true("/Coords [0.000 0.000 200.000 0.000 ]" in file, "the axis")
    assert_true(
        "/FunctionType 2 /Domain [0.000 1.000 ] /C0 [1.000 0.000 0.000 ] /C1"
        " [0.000 0.000 1.000 ] /N 1"
        in file,
        "two stops are one exponential function",
    )
    assert_true("/Extend [true true]" in file, "padded past the axis")

    var three = PdfCanvas(200, 100)
    var g3 = LinearGradient(0.0, 0.0, 200.0, 0.0)
    g3.add_stop(0.0, Color(255, 0, 0))
    g3.add_stop(0.25, Color(0, 255, 0))
    g3.add_stop(1.0, Color(0, 0, 255))
    var p = Path()
    p.move_to(0.0, 0.0)
    p.line_to(100.0, 0.0)
    p.line_to(0.0, 100.0)
    p.close()
    three.fill_path_gradient_aa(p, g3)
    var f3 = _bytes_to_string(three.to_bytes(compress=False))
    assert_true("/FunctionType 3" in f3, "three stops stitch")
    assert_true("/Bounds [0.250 ]" in f3, "the middle stop is the bound")
    assert_true(
        "h W* n /Sh1 sh" in three.content(),
        "a path clip under even-odd, then the shading",
    )

    var radial = PdfCanvas(200, 200)
    var r = RadialGradient(100.0, 100.0, 80.0)
    r.add_stop(0.0, Color(255, 255, 255))
    r.add_stop(1.0, Color(0, 0, 0))
    radial.fill_rect_radial_gradient(0, 0, 200, 200, r)
    var fr = _bytes_to_string(radial.to_bytes(compress=False))
    assert_true("/ShadingType 3" in fr, "radial")
    assert_true(
        "/Coords [100.000 100.000 0.000 100.000 100.000 80.000 ]" in fr,
        "focal point at the center, radius 0, then the circle",
    )

    var one = PdfCanvas(10, 10)
    var g1 = LinearGradient(0.0, 0.0, 1.0, 0.0)
    g1.add_stop(0.0, Color(9, 9, 9))
    one.fill_rect_gradient(0, 0, 10, 10, g1)
    assert_true(
        "sh" not in one.content() and "re f" in one.content(),
        "one stop fills solid",
    )


def test_annotated_group_is_marked_content() raises:
    var pdf = PdfCanvas(10, 10)
    pdf.begin_annotated_group("Sales (Q1) \\ 2026")
    pdf.fill_rect(0, 0, 1, 1, INK)
    pdf.end_annotated_group()
    var c = pdf.content()
    assert_true(
        "/Span << /Alt (Sales \\(Q1\\) \\\\ 2026) >> BDC\n" in c,
        "escaped label opens the sequence",
    )
    assert_true("EMC\n" in c, "and EMC closes it")
    assert_equal(_pdf_string("a(b)c\\"), "(a\\(b\\)c\\\\)")


def test_text_is_real_text_in_an_embedded_subset() raises:
    var pdf = PdfCanvas(200, 100)
    pdf.draw_text(10.0, 60.0, "Hi", Color(0, 0, 0), 24.0)
    var c = pdf.content()
    assert_true(
        "BT /F1 24.000 Tf " in c, "a text object selecting the font at size"
    )
    assert_true(
        "1.000 0.000 0.000 -1.000 10.000 60.000 Tm " in c,
        "the text matrix flips the glyphs upright at the anchor",
    )
    assert_true("] TJ ET" in c, "one TJ run, then ET")
    assert_true("<" in c and ">" in c, "glyph indices as hex codes")
    var file = _bytes_to_string(pdf.to_bytes(compress=False))
    assert_true(
        "/Subtype /Type0" in file and "/Encoding /Identity-H" in file,
        "a composite font",
    )
    assert_true(
        "/Subtype /CIDFontType2" in file and "/CIDToGIDMap /Identity" in file,
        "TrueType descendant",
    )
    assert_true(
        "/FontFile2" in file and "/Length1" in file,
        "an embedded TrueType program",
    )
    assert_true(
        "begincmap" in file and "beginbfchar" in file, "a ToUnicode map"
    )
    assert_true("<0048>" in file and "<0069>" in file, "H and i in the map")
    assert_true(
        "/Font << /F1 3 0 R >>" in file, "the font in the page resources"
    )
    assert_true("/BaseFont /AAAAAA+" in file, "a subset tag on the name")

    # The subset is a small fraction of the font file it came from.
    var cache = FontCache()
    var full = cache.resolve_face(
        "Sans", FontSlant.NORMAL, FontWeight.NORMAL, 24.0
    )
    var packed = pdf.to_bytes(compress=False)
    assert_true(
        len(packed) < len(full[].data) // 4,
        String("subset file ", len(packed), " vs font ", len(full[].data)),
    )


def test_ligature_maps_to_its_characters() raises:
    var pdf = PdfCanvas(200, 100)
    pdf.draw_text(10.0, 60.0, "fi", Color(0, 0, 0), 24.0)
    var file = _bytes_to_string(pdf.to_bytes(compress=False))
    # Whether or not the font ligates, both characters are reachable:
    # as one glyph mapped to <00660069> or two glyphs mapped one each.
    assert_true(
        "<00660069>" in file or ("<0066>" in file and "<0069>" in file),
        "f and i survive into ToUnicode",
    )


def test_kerning_is_a_tj_adjustment() raises:
    var pdf = PdfCanvas(200, 100)
    pdf.draw_text(10.0, 60.0, "AVA", Color(0, 0, 0), 24.0)
    var c = pdf.content()
    # DejaVu Sans kerns A-V; a negative number moves the next glyph
    # right (the pen advanced by the kern), a positive one left.
    var tj = String(c[byte = c.find("[") : c.find("] TJ")])
    # An adjustment follows a glyph code directly: `<0024>64 <0039>`.
    var adjusted = False
    var bytes = tj.as_bytes()
    for i in range(len(bytes) - 1):
        var here = Int(bytes[i])
        var next = Int(bytes[i + 1])
        if here == 62 and (next == 45 or (next >= 48 and next <= 57)):
            adjusted = True
    assert_true(adjusted, "adjustments between glyph codes")


def test_stroke_text_uses_render_mode_1() raises:
    var s = PdfCanvas(200, 100)
    s.stroke_text(10.0, 60.0, "Hi", Color(0, 0, 0), 24.0, 1.5)
    var c = s.content()
    assert_true("1.500 w" in c and "1 Tr " in c and "BT" in c, "stroked text")
    assert_true("RG" in c, "the stroke color")


def test_empty_and_outline_text() raises:
    var e = PdfCanvas(10, 10)
    e.draw_text(1.0, 1.0, "", Color(0, 0, 0), 12.0)
    assert_equal(e.content(), "", "empty text draws nothing")
    var o = PdfCanvas(100, 100)
    var outline = o.text_outline(10.0, 60.0, "Hi", 24.0)
    assert_true(
        len(outline.commands) > 8, "an outline path with the glyph contours"
    )
    o.fill_path_aa(outline, Color(0, 0, 0), FillRule.NONZERO)
    assert_true(
        "BT" not in o.content() and " l " in o.content(),
        "drawn as a path, not text",
    )


def test_pages() raises:
    var pdf = PdfCanvas(100, 50)
    pdf.fill_rect(0, 0, 10, 10, INK)
    pdf.push_clip(0, 0, 5, 5)
    pdf.begin_annotated_group("a")
    pdf.new_page(200, 100)
    assert_equal(pdf.page_count(), 2)
    assert_equal(pdf.content(), "", "the new page starts empty")
    pdf.fill_rect(0, 0, 10, 10, INK)
    var file = _bytes_to_string(pdf.to_bytes(compress=False))
    assert_true("/Count 2" in file, "two pages in the tree")
    assert_true(
        "/MediaBox [0 0 100 50]" in file and "/MediaBox [0 0 200 100]" in file,
        "each page its own size",
    )
    assert_true("/Kids [3 0 R 5 0 R ]" in file, "pages are objects 3 and 5")
    # The first page's open clip and group were closed on that page.
    var first_stream = file[
        byte = file.find("stream\n") : file.find("endstream")
    ]
    assert_true(
        "EMC\nQ\n" in first_stream, "group and clip closed at the page's end"
    )


def test_images_are_xobjects_with_a_soft_mask() raises:
    var img = Canvas(4, 3, Color(10, 20, 30))
    var pdf = PdfCanvas(100, 100)
    pdf.draw_image(img, 5.0, 6.0, 40.0, 30.0)
    var c = pdf.content()
    assert_true(
        "40.000 0.000 0.000 -30.000 5.000 36.000 cm /Im1 Do" in c,
        "placed with a flipped unit square at the top-left",
    )
    var file = _bytes_to_string(pdf.to_bytes(compress=False))
    assert_true(
        "/Subtype /Image /Width 4 /Height 3 /ColorSpace /DeviceRGB" in file,
        "an RGB image",
    )
    assert_true("/SMask" not in file, "opaque pixels need no mask")
    assert_true("/XObject << /Im1 3 0 R >>" in file, "in the resources")

    var translucent = Canvas(2, 2, Color(255, 0, 0, 128))
    var m = PdfCanvas(100, 100)
    m.draw_image(translucent, 0.0, 0.0)
    var mf = _bytes_to_string(m.to_bytes(compress=False))
    assert_true(
        "/SMask 4 0 R" in mf and "/ColorSpace /DeviceGray" in mf,
        "a soft mask for the alpha",
    )
    assert_true(
        "2.000 0.000 0.000 -2.000 0.000 2.000 cm" in m.content(),
        "the image's own size by default",
    )


def test_file_structure_and_xref_offsets() raises:
    var pdf = PdfCanvas(120, 80)
    pdf.set_title("Report")
    pdf.set_author("Me")
    pdf.fill_rect(0, 0, 10, 10, INK)
    pdf.draw_text(5.0, 40.0, "x", Color(0, 0, 0), 12.0)
    var data = pdf.to_bytes(compress=False)
    var file = _bytes_to_string(data)
    assert_true(file.startswith("%PDF-1.4\n%"), "header")
    assert_true("/MediaBox [0 0 120 80]" in file, "page size")
    assert_true("1 0 0 -1 0 80.000 cm\n" in file, "the flip opens the stream")
    assert_true(
        "/Title (Report)" in file and "/Author (Me)" in file,
        "title and author in Info",
    )
    assert_true("/Producer (canvas_mojo)" in file, "producer")
    assert_true(file.endswith("%%EOF\n"), "trailer")
    # startxref points at the xref table, and each entry at its object.
    var sx = file.rfind("startxref\n")
    var xref_off = Int(
        String(file[byte = sx + 10 : file.rfind("\n%%EOF")]).strip()
    )
    assert_true(
        file[byte = xref_off : xref_off + 4] == "xref",
        "startxref lands on xref",
    )
    var header_end = file.find("\n", xref_off + 5)
    var count = Int(String(file[byte = xref_off + 7 : header_end]))
    assert_true(
        count >= 10,
        "catalog, pages, five font objects, a page, its stream, info",
    )
    for n in range(1, count):
        var entry_start = header_end + 1 + 20 * n
        var off = Int(String(file[byte = entry_start : entry_start + 10]))
        assert_true(
            file[byte = off : off + 12].startswith(String(n) + " 0 obj"),
            String("xref entry ", n, " points at its object"),
        )
    assert_true(("/Size " + String(count)) in file, "the trailer's size")


def test_compressed_stream_inflates_to_the_operators() raises:
    var pdf = PdfCanvas(50, 50)
    pdf.fill_circle_aa(25.0, 25.0, 10.0, INK)
    var packed = pdf.to_bytes()
    var plain = _bytes_to_string(pdf.to_bytes(compress=False))
    var file = _bytes_to_string(packed)
    assert_true("/Filter /FlateDecode" in file, "compressed by default")
    var start = file.find("stream\n") + 7
    var end = file.find("\nendstream")
    var body = List[UInt8]()
    for i in range(
        start + 2, end - 4
    ):  # past the zlib header, before the Adler-32
        body.append(packed[i])
    var raw = _bytes_to_string(inflate(body^))
    var pstart = plain.find("stream\n") + 7
    var pend = plain.find("\nendstream")
    assert_equal(
        raw, plain[byte=pstart:pend], "the stream inflates to the readable one"
    )


def test_state_accessors() raises:
    var pdf = PdfCanvas(10, 10)
    assert_true(pdf.blend_mode() == BlendMode.SOURCE_OVER)
    assert_true(pdf.color_space() == ColorSpace.SRGB)
    pdf.set_color_space(ColorSpace.LINEAR)
    assert_true(
        pdf.color_space() == ColorSpace.LINEAR, "kept though not applied"
    )
    pdf.set_transform(Matrix2D.translation(1.0, 2.0))
    assert_true(pdf.has_transform())
    assert_equal(pdf.current_transform().e, 1.0)
    pdf.save()
    pdf.set_blend_mode(BlendMode.SCREEN)
    pdf.restore()
    assert_true(
        pdf.blend_mode() == BlendMode.SOURCE_OVER, "restore puts the mode back"
    )


def test_write_pdf_round_trips_through_the_file() raises:
    var pdf = PdfCanvas(30, 30)
    pdf.fill_rect(5, 5, 10, 10, INK)
    var path = "tests/_test_pdf_output.pdf"
    write_pdf(pdf, path)
    var f = open(path, "r")
    var back = f.read_bytes()
    f.close()
    assert_equal(len(back), len(pdf.to_bytes()), "the file is the bytes")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
