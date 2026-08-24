"""Tests for canvas_mojo/text/ttf.mojo.

Needs a "Sans"-resolvable system font (fontconfig's generic sans-serif
alias, DejaVu Sans on this machine), the same real-machine dependency
test_glyph_outline.mojo and test_font_discovery.mojo document.

Every locked-in value was cross-checked against an independent source:
`units_per_em`/`num_glyphs`/`ascender`/`descender` match both the
font's well-known metrics and a from-scratch Python oracle (plain
`struct.unpack`, no font libraries) written against the same file. The
composite glyph point data was diffed byte for byte against that
oracle's decode of the same glyph.
"""

from std.testing import assert_equal, assert_true, TestSuite

from canvas_mojo.buffer import Canvas
from canvas_mojo.color import Color
from canvas_mojo.path import fill_path_aa
from canvas_mojo.text.font_discovery import resolve_font_file
from canvas_mojo.text.ttf import TTFFace, outline_to_path

comptime BG = Color(255, 255, 255)
comptime FG = Color(0, 0, 0)


def _sans_face() raises -> TTFFace:
    var path = resolve_font_file("Sans")
    return TTFFace(path)


def test_head_maxp_hhea_match_known_font_metrics() raises:
    # DejaVu Sans's well-known metrics: units_per_EM/num_glyphs/
    # ascender/descender of 2048/6253/1901/-483, which
    # glyph_outline.mojo records and a Python oracle reads
    # independently from the same bytes.
    var face = _sans_face()
    assert_equal(face.units_per_em, 2048)
    assert_equal(face.num_glyphs, 6253)
    assert_equal(face.ascender, 1901)
    assert_equal(face.descender, -483)


def test_cmap_format4_and_format12_agree_on_known_codepoints() raises:
    # DejaVu Sans exposes both a format 4 (BMP-only) and a format 12
    # (full Unicode) cmap subtable for the same characters: platform
    # 0/encoding 3 and platform 3/encoding 1 point at the format-4 one,
    # platform 0/encoding 4 and platform 3/encoding 10 at the format-12
    # one. Two separately-decoded subtables agreeing on a glyph index
    # cross-checks both decoders rather than one against itself.
    var face = _sans_face()
    var gid_format12 = face.glyph_index_for_codepoint(0x41)  # 'A', prefers format 12
    var abs_offset_format4 = face._cmap_offset + 44  # confirmed via probe: format-4 subtable's own offset
    var gid_format4 = face._lookup_cmap_format4(abs_offset_format4, 0x41)
    assert_equal(gid_format12, gid_format4)
    assert_true(gid_format12 != 0)


def test_missing_codepoint_maps_to_notdef() raises:
    # 0x10FFFE, the last valid Unicode codepoint, which the Python
    # oracle places outside every group in this font's format-12
    # subtable.
    var face = _sans_face()
    assert_equal(face.glyph_index_for_codepoint(0x10FFFE), 0)


def test_i_glyph_is_a_simple_rectangle() raises:
    # Capital "I", also recorded in glyph_outline.mojo: exactly 1
    # contour, 4 points, all on-curve -- a rectangle with no curves.
    var face = _sans_face()
    var gid = face.glyph_index_for_codepoint(0x49)
    var outline = face.glyph_outline(gid)
    assert_equal(len(outline.contour_ends), 1)
    assert_equal(len(outline.points_x), 4)
    for i in range(4):
        assert_true(outline.on_curve[i])


def test_o_glyph_has_off_curve_points_and_two_contours() raises:
    # "O", a curved multi-contour glyph (outer ring plus inner hole),
    # the structural fact glyph_outline.mojo's tests confirm one level
    # up.
    var face = _sans_face()
    var gid = face.glyph_index_for_codepoint(0x4F)
    var outline = face.glyph_outline(gid)
    assert_equal(len(outline.contour_ends), 2)
    var any_off_curve = False
    for i in range(len(outline.on_curve)):
        if not outline.on_curve[i]:
            any_off_curve = True
    assert_true(any_off_curve)


def test_o_glyph_renders_a_round_shape_with_a_hole() raises:
    # The end-to-end check, mirroring glyph_outline.mojo's
    # identically-named test: decompose a curved multi-contour glyph
    # and rasterize it through fill_path_aa. A correct render has ink
    # in the ring and a hole at the visual center, the inner contour
    # punched by the default EVEN_ODD rule.
    var face = _sans_face()
    var scale = 40.0 / Float64(face.units_per_em)
    var gid = face.glyph_index_for_codepoint(0x4F)  # 'O'
    var outline = face.glyph_outline(gid)
    var path = outline_to_path(outline, 5.0, 45.0, scale)

    var c = Canvas(60, 60, BG)
    fill_path_aa(c, path, FG)

    var ink_pixels = 0
    for y in range(c.height):
        for x in range(c.width):
            var pix = c.get_pixel(x, y)
            if not (pix.r == BG.r and pix.g == BG.g and pix.b == BG.b):
                ink_pixels += 1
    assert_true(ink_pixels > 0)

    var advance_px = Float64(face.advance_width(gid)) * scale
    var center_x = 5 + Int(advance_px / 2.0)
    var center_y = 45 - 15
    var center_pixel = c.get_pixel(center_x, center_y)
    assert_equal(center_pixel.r, BG.r)
    assert_equal(center_pixel.g, BG.g)
    assert_equal(center_pixel.b, BG.b)


def test_composite_glyph_matches_independently_computed_points() raises:
    # 'é' (U+00E9), a composite glyph in DejaVu Sans -- numberOfContours
    # == -1, so it references component glyphs rather than describing
    # an outline -- built from a base "e" plus an offset, scaled acute
    # accent. Every point below was computed independently by the
    # Python oracle, implementing OpenType's `x' = xscale*x +
    # scale10*y` separately from this code, then diffed byte for byte
    # against the real output. That cross-validates the whole composite
    # path: component offsets, scale application, and point renumbering
    # across components.
    var face = _sans_face()
    var gid = face.glyph_index_for_codepoint(0xE9)
    var outline = face.glyph_outline(gid)

    assert_equal(len(outline.points_x), 32)
    assert_equal(outline.contour_ends[0], 20)
    assert_equal(outline.contour_ends[1], 27)
    assert_equal(outline.contour_ends[2], 31)

    # Spot-check one point from each of the three contours -- "e"'s
    # outer contour, its inner hole, and the accent mark -- rather than
    # embedding all 32, which is enough to catch either a base-glyph
    # decode or a component transform/offset failure.
    assert_equal(outline.points_x[0], 1151)
    assert_equal(outline.points_y[0], 606)
    assert_true(outline.on_curve[0])

    assert_equal(outline.points_x[3], 317)
    assert_equal(outline.points_y[3], 326)
    assert_true(not outline.on_curve[3])

    # Last point (index 31) belongs to the accent-mark component.
    assert_equal(outline.points_x[31], 510)
    assert_equal(outline.points_y[31], 1262)
    assert_true(outline.on_curve[31])


def test_advance_width_matches_hmtx() raises:
    # 'O's advance width in raw font-design units, cross-checked
    # against the Python oracle reading the same hmtx LongHorMetric
    # record.
    var face = _sans_face()
    var gid = face.glyph_index_for_codepoint(0x4F)
    assert_equal(face.advance_width(gid), 1612)


def test_cff_font_raises_a_clear_error() raises:
    # A real CFF/OpenType-CFF font: "Nimbus Sans" from
    # `fonts-urw-base35`, URW's metric-compatible replacements for the
    # 35 PostScript Level 2 base fonts. Its sfntVersion really is
    # 'OTTO' (0x4F54544F), so this is the case the rejection path
    # exists for rather than a synthetic stand-in.
    var path = resolve_font_file("Nimbus Sans")
    var raised = False
    var message = String()
    try:
        var face = TTFFace(path)
        _ = face
    except e:
        raised = True
        message = String(e)
    assert_true(raised)
    assert_true("CFF" in message or "OpenType-CFF" in message)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
