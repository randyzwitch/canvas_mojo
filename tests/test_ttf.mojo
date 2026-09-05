"""Tests for canvas/text/ttf.mojo.

Needs a "Sans"-resolvable system font (the generic sans-serif
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

from canvas.buffer import Canvas
from canvas.color import Color
from canvas.path import fill_path_aa
from canvas.text.font_discovery import resolve_font_file
from canvas.text.ttf import (
    TTFFace,
    outline_to_path,
    _gpos_kern_lookups,
    _gsub_subst_lookups,
    _kern_format0_lookup,
    _kern_format0_subtables,
    _ligature_subst_lookup,
    _pair_pos_lookup,
    _single_subst_lookup,
)

comptime BG = Color(255, 255, 255)
comptime FG = Color(0, 0, 0)


def _sans_face() raises -> TTFFace:
    var path = resolve_font_file("Sans")
    return TTFFace(path)


def _ubuntu_face() raises -> TTFFace:
    var path = resolve_font_file("Ubuntu")
    return TTFFace(path)


def _push_u16(mut data: List[UInt8], value: Int):
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))


def _push_i16(mut data: List[UInt8], value: Int):
    _push_u16(data, value & 0xFFFF)


def _push_u32(mut data: List[UInt8], value: Int):
    _push_u16(data, (value >> 16) & 0xFFFF)
    _push_u16(data, value & 0xFFFF)


def _push_tag(mut data: List[UInt8], tag: String):
    for cp in tag.codepoints():
        data.append(UInt8(Int(cp)))


def _pad_to(mut data: List[UInt8], length: Int):
    while len(data) < length:
        data.append(0)


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
    var gid_format12 = face.glyph_index_for_codepoint(
        0x41
    )  # 'A', prefers format 12
    var abs_offset_format4 = (
        face._cmap_offset + 44
    )  # confirmed via probe: format-4 subtable's own offset
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


def test_cached_outline_is_shared_but_the_owned_copy_is_independent() raises:
    # `glyph_outline_shared` hands back the cached outline itself, so a
    # second call for the same glyph must see identical data rather
    # than re-decoding. `glyph_outline` returns an owned copy of that
    # same cached value: were it an alias, a caller mutating what it
    # got back would corrupt the cache for every later lookup.
    #
    # Mojo already rules that out -- `List` is not ImplicitlyCopyable,
    # so writing the alias is a compile error, confirmed by trying it.
    # This documents the contract and would catch a future `copied()`
    # that copies some fields and not others, which does compile.
    var face = _sans_face()
    var gid = face.glyph_index_for_codepoint(0x4F)  # 'O'

    var first = face.glyph_outline_shared(gid)
    var second = face.glyph_outline_shared(gid)
    assert_equal(len(first[].points_x), len(second[].points_x))
    assert_equal(first[].points_x[0], second[].points_x[0])

    var owned = face.glyph_outline(gid)
    assert_equal(len(owned.points_x), len(first[].points_x))
    var before = first[].points_x[0]
    owned.points_x[0] = before + 9999
    assert_equal(face.glyph_outline_shared(gid)[].points_x[0], before)


def test_cmap_lookup_is_memoized_without_changing_answers() raises:
    # The codepoint -> glyph index memo has to be transparent: repeated
    # lookups, and a codepoint the font does not map, must give what an
    # uncached scan gives.
    var face = _sans_face()
    for _ in range(3):
        assert_equal(
            face.glyph_index_for_codepoint(0x49),
            face.glyph_index_for_codepoint(0x49),
        )
    assert_true(face.glyph_index_for_codepoint(0x49) != 0)
    # unmapped codepoint stays .notdef on every call
    assert_equal(face.glyph_index_for_codepoint(0x10FFFE), 0)
    assert_equal(face.glyph_index_for_codepoint(0x10FFFE), 0)


def _synthetic_kern_table() raises -> List[UInt8]:
    """A `kern` table with one format 0 horizontal subtable holding
    three pairs, preceded by four filler bytes so the parser has to
    honor the table directory's offset rather than assume zero.

    Byte layout, from the OpenType `kern` spec: a version 0 header (16
    bit version, 16 bit subtable count), then per subtable a 16 bit
    version, a 16 bit byte length and a 16 bit coverage whose high byte
    is the format and whose low bit means horizontal. Format 0's own
    data is a pair count, three binary-search hint fields, and the
    pairs as (left, right, FWORD value).
    """
    var data = List[UInt8]()
    _pad_to(data, 4)

    _push_u16(data, 0)  # version
    _push_u16(data, 1)  # nTables

    _push_u16(data, 0)  # subtable version
    # length: 6 byte subtable header + 8 bytes of format 0 header +
    # 3 pairs x 6 bytes = 32.
    _push_u16(data, 32)
    _push_u16(data, 0x0001)  # format 0 (high byte), horizontal
    _push_u16(data, 3)  # nPairs
    # searchRange/entrySelector/rangeShift, the spec's precomputed
    # binary-search hints: 6 * 2^floor(log2(3)) = 12, floor(log2(3)) =
    # 1, and 6 * 3 - 12 = 6.
    _push_u16(data, 12)
    _push_u16(data, 1)
    _push_u16(data, 6)
    # Pairs, sorted by (left << 16) | right as the format requires.
    _push_u16(data, 10)
    _push_u16(data, 20)
    _push_i16(data, -100)
    _push_u16(data, 10)
    _push_u16(data, 30)
    _push_i16(data, 25)
    _push_u16(data, 11)
    _push_u16(data, 20)
    _push_i16(data, -7)
    return data^


def test_synthetic_kern_format0_subtable_decodes_its_pairs() raises:
    var data = _synthetic_kern_table()
    var subtables = _kern_format0_subtables(data, 4)
    # The one subtable starts right after the table's 4 byte header.
    assert_equal(len(subtables), 1)
    assert_equal(subtables[0], 8)

    var av = _kern_format0_lookup(data, 8, 10, 20)
    assert_true(av[0])
    assert_equal(av[1], -100)

    # Same left glyph, second pair: catches a bisection that stops at
    # the first matching left glyph rather than the exact pair.
    var second = _kern_format0_lookup(data, 8, 10, 30)
    assert_true(second[0])
    assert_equal(second[1], 25)

    var third = _kern_format0_lookup(data, 8, 11, 20)
    assert_true(third[0])
    assert_equal(third[1], -7)

    # Unlisted pairs: a listed left with an unlisted right, and a left
    # the subtable never mentions.
    var missing_right = _kern_format0_lookup(data, 8, 10, 25)
    assert_true(not missing_right[0])
    assert_equal(missing_right[1], 0)
    var missing_left = _kern_format0_lookup(data, 8, 12, 20)
    assert_true(not missing_left[0])


def _synthetic_gpos(extension: Bool) raises -> List[UInt8]:
    """A `GPOS` table whose one script (DFLT), through its default
    language system, selects a `kern` feature holding one lookup with
    one PairPos format 1 subtable -- reached directly when `extension`
    is False, and through an ExtensionPos (lookup type 9) wrapper when
    it is True.

    Six filler bytes precede the table. Every offset below is relative
    to the record the spec measures it from, which is the part a parser
    gets wrong: a subtable offset is relative to its Lookup, but an
    ExtensionPos's 32 bit offset is relative to the wrapper itself.
    """
    var data = List[UInt8]()
    _pad_to(data, 6)

    _push_u32(data, 0x00010000)  # version 1.0
    _push_u16(data, 0x0A)  # scriptListOffset
    _push_u16(data, 0x1E)  # featureListOffset
    _push_u16(data, 0x2C)  # lookupListOffset

    # ScriptList at 0x0A: one DFLT script whose table sits 8 bytes on.
    _push_u16(data, 1)
    _push_tag(data, "DFLT")
    _push_u16(data, 8)
    # Script at 0x12: a default LangSys 4 bytes on, no named ones.
    _push_u16(data, 4)
    _push_u16(data, 0)
    # LangSys at 0x16: no required feature, one optional feature, #0.
    _push_u16(data, 0)
    _push_u16(data, 0xFFFF)
    _push_u16(data, 1)
    _push_u16(data, 0)
    # FeatureList at 0x1E: feature #0 is 'kern', 8 bytes on.
    _push_u16(data, 1)
    _push_tag(data, "kern")
    _push_u16(data, 8)
    # Feature at 0x26: no params, one lookup, #0.
    _push_u16(data, 0)
    _push_u16(data, 1)
    _push_u16(data, 0)
    # LookupList at 0x2C: one lookup, 4 bytes on.
    _push_u16(data, 1)
    _push_u16(data, 4)
    # Lookup at 0x30.
    _push_u16(data, 9 if extension else 2)
    _push_u16(data, 0)  # lookupFlag
    _push_u16(data, 1)  # subTableCount
    _push_u16(data, 8)  # subtable offset, from the Lookup's own start
    if extension:
        # ExtensionPos at 0x38: format 1, wrapping a type 2 lookup 8
        # bytes past this record's start, so the PairPos lands at 0x40.
        _push_u16(data, 1)
        _push_u16(data, 2)
        _push_u32(data, 8)

    # PairPos format 1. valueFormat1 is XPlacement | XAdvance, not
    # XAdvance alone: XPlacement then precedes XAdvance inside every
    # ValueRecord, so a decoder that ignores the bit reads the wrong
    # 16 bits and the values below say so.
    _push_u16(data, 1)  # posFormat
    _push_u16(data, 0x0E)  # coverageOffset
    _push_u16(data, 0x0005)  # valueFormat1
    _push_u16(data, 0x0000)  # valueFormat2
    _push_u16(data, 2)  # pairSetCount
    _push_u16(data, 0x16)  # pairSetOffsets[0]
    _push_u16(data, 0x24)  # pairSetOffsets[1]
    # Coverage format 1 at +0x0E: glyphs 10 and 11.
    _push_u16(data, 1)
    _push_u16(data, 2)
    _push_u16(data, 10)
    _push_u16(data, 11)
    # PairSet for glyph 10 at +0x16: two second glyphs, sorted.
    _push_u16(data, 2)
    _push_u16(data, 20)
    _push_i16(data, 3)  # XPlacement, not the advance
    _push_i16(data, -100)  # XAdvance
    _push_u16(data, 30)
    _push_i16(data, 0)
    _push_i16(data, 25)
    # PairSet for glyph 11 at +0x24: one second glyph.
    _push_u16(data, 1)
    _push_u16(data, 20)
    _push_i16(data, 0)
    _push_i16(data, -7)

    return data^


def _assert_synthetic_pair_pos(data: List[UInt8], subtable: Int) raises:
    var first = _pair_pos_lookup(data, subtable, 10, 20)
    assert_true(first[0])
    # -100, not 3: XPlacement occupies the first 16 bits of the record
    # because valueFormat1 sets its bit.
    assert_equal(first[1], -100)

    var second = _pair_pos_lookup(data, subtable, 10, 30)
    assert_true(second[0])
    assert_equal(second[1], 25)

    var third = _pair_pos_lookup(data, subtable, 11, 20)
    assert_true(third[0])
    assert_equal(third[1], -7)

    # Covered left glyph, second glyph absent from its PairSet.
    var no_pair = _pair_pos_lookup(data, subtable, 10, 25)
    assert_true(not no_pair[0])
    assert_equal(no_pair[1], 0)
    # Left glyph outside Coverage.
    var no_cover = _pair_pos_lookup(data, subtable, 12, 20)
    assert_true(not no_cover[0])


def test_synthetic_gpos_pair_pos_format1_decodes_through_the_lists() raises:
    var data = _synthetic_gpos(False)
    var lookups = _gpos_kern_lookups(data, 6)
    assert_equal(len(lookups.subtables), 1)
    assert_equal(lookups.subtables[0], 6 + 0x38)
    # One lookup, so one group spanning the single subtable.
    assert_equal(len(lookups.bounds), 2)
    assert_equal(lookups.bounds[0], 0)
    assert_equal(lookups.bounds[1], 1)
    _assert_synthetic_pair_pos(data, lookups.subtables[0])


def test_synthetic_gpos_extension_lookup_reaches_the_pair_pos() raises:
    # Lookup type 9 wraps the real subtable behind a 32 bit offset
    # measured from the wrapper, not from the Lookup -- the same
    # subtable as above, 8 bytes further out.
    var data = _synthetic_gpos(True)
    var lookups = _gpos_kern_lookups(data, 6)
    assert_equal(len(lookups.subtables), 1)
    assert_equal(lookups.subtables[0], 6 + 0x40)
    _assert_synthetic_pair_pos(data, lookups.subtables[0])


def test_synthetic_gpos_pair_pos_format2_indexes_the_class_matrix() raises:
    # PairPos format 2 puts both glyphs in a class and reads a
    # class1Count x class2Count matrix of ValueRecords, row-major by
    # the first glyph's class. The matrix below is asymmetric in a way
    # a transposed index reads wrong: (10, 20) is class (0, 1), which
    # is 5 row-major and 0 column-major.
    #
    # Layout, all offsets from the subtable's start: a 16 byte header,
    # the 2 x 3 matrix of 16 bit XAdvances at +16, Coverage at +28,
    # ClassDef1 at +36, ClassDef2 at +46.
    var data = List[UInt8]()
    _pad_to(data, 2)
    var subtable = 2

    _push_u16(data, 2)  # posFormat
    _push_u16(data, 28)  # coverageOffset
    _push_u16(data, 0x0004)  # valueFormat1: XAdvance only
    _push_u16(data, 0x0000)  # valueFormat2
    _push_u16(data, 36)  # classDef1Offset
    _push_u16(data, 46)  # classDef2Offset
    _push_u16(data, 2)  # class1Count
    _push_u16(data, 3)  # class2Count
    # Class1Record 0, then 1; three Class2Records each.
    _push_i16(data, 0)
    _push_i16(data, 5)
    _push_i16(data, 0)
    _push_i16(data, 0)
    _push_i16(data, -40)
    _push_i16(data, 11)
    # Coverage format 1 at +28: glyphs 10 and 11.
    _push_u16(data, 1)
    _push_u16(data, 2)
    _push_u16(data, 10)
    _push_u16(data, 11)
    # ClassDef1 format 1 at +36: glyph 10 -> class 0, glyph 11 -> 1.
    _push_u16(data, 1)
    _push_u16(data, 10)
    _push_u16(data, 2)
    _push_u16(data, 0)
    _push_u16(data, 1)
    # ClassDef2 format 2 at +46: glyphs 20-21 -> class 1.
    _push_u16(data, 2)
    _push_u16(data, 1)
    _push_u16(data, 20)
    _push_u16(data, 21)
    _push_u16(data, 1)

    var row0 = _pair_pos_lookup(data, subtable, 10, 20)
    assert_true(row0[0])
    assert_equal(row0[1], 5)

    var row1 = _pair_pos_lookup(data, subtable, 11, 20)
    assert_true(row1[0])
    assert_equal(row1[1], -40)

    # Glyph 21 falls in the same ClassDef2 range as 20.
    var same_class = _pair_pos_lookup(data, subtable, 11, 21)
    assert_true(same_class[0])
    assert_equal(same_class[1], -40)

    # A right glyph in no ClassDef2 range is class 0: a covered pair
    # whose matrix cell is 0, reported as covered, since that is what
    # stops a lookup trying its next subtable.
    var class_zero = _pair_pos_lookup(data, subtable, 11, 99)
    assert_true(class_zero[0])
    assert_equal(class_zero[1], 0)

    # A left glyph outside Coverage is not covered at all, however its
    # ClassDef1 entry reads.
    var uncovered = _pair_pos_lookup(data, subtable, 12, 20)
    assert_true(not uncovered[0])


def test_kern_pairs_match_an_independent_gpos_decode() raises:
    # DejaVu Sans's GPOS kerning, read by a from-scratch Python oracle
    # (plain struct.unpack, no font libraries) walking the same bytes:
    # its 'kern' feature reaches two PairPos format 2 lookups, and
    # these pairs come back at 2048 units per em as below. "AA" is
    # positive, so this pins the sign as well as the magnitude.
    var face = _sans_face()
    assert_true(face.has_kerning())

    var a = face.glyph_index_for_codepoint(0x41)
    var v = face.glyph_index_for_codepoint(0x56)
    var t = face.glyph_index_for_codepoint(0x54)
    var o = face.glyph_index_for_codepoint(0x6F)
    var y = face.glyph_index_for_codepoint(0x79)
    var el = face.glyph_index_for_codepoint(0x4C)

    assert_equal(face.kern_adjustment(a, v), -131)
    assert_equal(face.kern_adjustment(t, o), -348)
    assert_equal(face.kern_adjustment(t, y), -319)
    assert_equal(face.kern_adjustment(el, t), -282)
    assert_equal(face.kern_adjustment(a, a), 57)

    # An unkerned pair, and .notdef on either side, are zero.
    assert_equal(face.kern_adjustment(o, o), 0)
    assert_equal(face.kern_adjustment(0, v), 0)
    assert_equal(face.kern_adjustment(a, 0), 0)


def test_gpos_and_kern_table_agree_in_a_font_carrying_both() raises:
    # DejaVu Sans ships both a GPOS 'kern' feature and a legacy `kern`
    # table. `kern_adjustment` reads the GPOS one; this reads the other
    # decoder directly and checks the two agree, cross-validating them
    # against each other rather than against themselves. The `kern`
    # table omits pairs that adjust by zero, so only the pairs it lists
    # are compared.
    var face = _sans_face()
    assert_true(len(face._gpos_kern.subtables) > 0)
    assert_true(len(face._kern_subtables) > 0)

    var codepoints: List[Int] = [0x41, 0x56, 0x54, 0x6F, 0x79, 0x4C, 0x2E]
    var compared = 0
    for i in range(len(codepoints)):
        for k in range(len(codepoints)):
            var left = face.glyph_index_for_codepoint(codepoints[i])
            var right = face.glyph_index_for_codepoint(codepoints[k])
            var legacy = face._kern_table_adjustment(left, right)
            if legacy == 0:
                continue
            assert_equal(face.kern_adjustment(left, right), legacy)
            compared += 1
    # "AV", "To", "Ty", "LT", "AA", "F." and their like among these
    # seven characters: enough that an empty loop would not pass.
    assert_true(compared >= 10)


def test_extension_lookup_kerning_in_a_real_font() raises:
    # Ubuntu reaches its pair kerning through a single lookup of type 9
    # holding nine wrapped subtables, the first PairPos format 1 and
    # the rest format 2, so a pair resolves only after the walk skips
    # the subtables that do not cover it. Ubuntu's design values are
    # not pinned the way DejaVu Sans's are, since the packaged font
    # differs between the Linux and macOS CI images, so this asserts
    # the shape kerning has: "AV" pulls together, "oo" does not move.
    var face = _ubuntu_face()
    assert_true(face.has_kerning())
    var a = face.glyph_index_for_codepoint(0x41)
    var v = face.glyph_index_for_codepoint(0x56)
    var o = face.glyph_index_for_codepoint(0x6F)
    assert_true(face.kern_adjustment(a, v) < 0)
    assert_equal(face.kern_adjustment(o, o), 0)


def test_kern_adjustment_is_memoized_without_changing_answers() raises:
    # The pair memo has to be transparent the same way the cmap one is.
    var face = _sans_face()
    var a = face.glyph_index_for_codepoint(0x41)
    var v = face.glyph_index_for_codepoint(0x56)
    var o = face.glyph_index_for_codepoint(0x6F)
    for _ in range(3):
        assert_equal(face.kern_adjustment(a, v), -131)
        assert_equal(face.kern_adjustment(o, o), 0)


def test_synthetic_gsub_single_subst_formats_map_their_coverage() raises:
    # SingleSubst format 1 adds a signed delta to the glyph id modulo
    # 65536; format 2 lists a replacement per covered glyph. Both are
    # built here on the same coverage so the two decodes are compared
    # against the same input.
    #
    # Format 1 layout, offsets from the subtable's start: a 6 byte
    # header, Coverage at +6. The covered glyphs are 10, 11 and 65533,
    # and the delta is +5, so 65533 wraps to (65533 + 5) mod 65536 = 2
    # -- the one value a decoder adding without masking gets wrong.
    var one = List[UInt8]()
    _pad_to(one, 2)
    _push_u16(one, 1)  # substFormat
    _push_u16(one, 6)  # coverageOffset
    _push_i16(one, 5)  # deltaGlyphID
    _push_u16(one, 1)  # Coverage format 1
    _push_u16(one, 3)
    _push_u16(one, 10)
    _push_u16(one, 11)
    _push_u16(one, 65533)

    assert_equal(_single_subst_lookup(one, 2, 10), 15)
    assert_equal(_single_subst_lookup(one, 2, 11), 16)
    assert_equal(_single_subst_lookup(one, 2, 65533), 2)
    # An uncovered glyph is left alone, which -1 says and 0 could not:
    # 0 is a real glyph id (".notdef").
    assert_equal(_single_subst_lookup(one, 2, 12), -1)

    # Format 2 layout: a 6 byte header, the substituteGlyphIDs array at
    # +6, Coverage at +10. The replacements are deliberately not the
    # delta's, so a decoder reading the wrong format says so.
    var two = List[UInt8]()
    _pad_to(two, 2)
    _push_u16(two, 2)  # substFormat
    _push_u16(two, 10)  # coverageOffset
    _push_u16(two, 2)  # glyphCount
    _push_u16(two, 30)
    _push_u16(two, 31)
    _push_u16(two, 1)  # Coverage format 1
    _push_u16(two, 2)
    _push_u16(two, 10)
    _push_u16(two, 11)

    assert_equal(_single_subst_lookup(two, 2, 10), 30)
    assert_equal(_single_subst_lookup(two, 2, 11), 31)
    assert_equal(_single_subst_lookup(two, 2, 12), -1)


def _synthetic_gsub(extension: Bool) raises -> List[UInt8]:
    """A `GSUB` table whose one script (DFLT), through its default
    language system, selects a `liga` feature holding one lookup with
    one LigatureSubst subtable -- reached directly when `extension` is
    False, and through an ExtensionSubst (lookup type 7, not GPOS's 9)
    wrapper when it is True.

    Six filler bytes precede the table, and the header and list layout
    match `_synthetic_gpos`'s, which is the point: the two tables share
    them.

    Coverage holds glyphs 10 and 20, one LigatureSet each. Glyph 10's
    set is ordered longest-first the way a font writes it:

        10 11 12 -> 100    10 11 -> 101    10 13 -> 102

    so the three-component record is tried before the two-component
    record that is its own prefix.
    """
    var data = List[UInt8]()
    _pad_to(data, 6)

    _push_u32(data, 0x00010000)  # version 1.0
    _push_u16(data, 0x0A)  # scriptListOffset
    _push_u16(data, 0x1E)  # featureListOffset
    _push_u16(data, 0x2C)  # lookupListOffset

    # ScriptList at 0x0A: one DFLT script whose table sits 8 bytes on.
    _push_u16(data, 1)
    _push_tag(data, "DFLT")
    _push_u16(data, 8)
    # Script at 0x12: a default LangSys 4 bytes on, no named ones.
    _push_u16(data, 4)
    _push_u16(data, 0)
    # LangSys at 0x16: no required feature, one optional feature, #0.
    _push_u16(data, 0)
    _push_u16(data, 0xFFFF)
    _push_u16(data, 1)
    _push_u16(data, 0)
    # FeatureList at 0x1E: feature #0 is 'liga', 8 bytes on.
    _push_u16(data, 1)
    _push_tag(data, "liga")
    _push_u16(data, 8)
    # Feature at 0x26: no params, one lookup, #0.
    _push_u16(data, 0)
    _push_u16(data, 1)
    _push_u16(data, 0)
    # LookupList at 0x2C: one lookup, 4 bytes on.
    _push_u16(data, 1)
    _push_u16(data, 4)
    # Lookup at 0x30.
    _push_u16(data, 7 if extension else 4)
    _push_u16(data, 0)  # lookupFlag
    _push_u16(data, 1)  # subTableCount
    _push_u16(data, 8)  # subtable offset, from the Lookup's own start
    if extension:
        # ExtensionSubst at 0x38: format 1, wrapping a type 4 lookup 8
        # bytes past this record's start, so the LigatureSubst lands
        # at 0x40.
        _push_u16(data, 1)
        _push_u16(data, 4)
        _push_u32(data, 8)

    # LigatureSubst format 1: a 10 byte header, Coverage at +10,
    # glyph 10's LigatureSet at +18 and glyph 20's at +46.
    _push_u16(data, 1)  # substFormat
    _push_u16(data, 10)  # coverageOffset
    _push_u16(data, 2)  # ligatureSetCount
    _push_u16(data, 18)
    _push_u16(data, 46)
    # Coverage format 1 at +10: the ligatures' first components.
    _push_u16(data, 1)
    _push_u16(data, 2)
    _push_u16(data, 10)
    _push_u16(data, 20)
    # LigatureSet at +18: three ligatures, at +8, +16 and +22 from
    # this set's own start.
    _push_u16(data, 3)
    _push_u16(data, 8)
    _push_u16(data, 16)
    _push_u16(data, 22)
    # componentCount counts the first component, which Coverage
    # already matched, so only the rest are stored.
    _push_u16(data, 100)  # ligatureGlyph
    _push_u16(data, 3)  # componentCount
    _push_u16(data, 11)
    _push_u16(data, 12)
    _push_u16(data, 101)
    _push_u16(data, 2)
    _push_u16(data, 11)
    _push_u16(data, 102)
    _push_u16(data, 2)
    _push_u16(data, 13)
    # LigatureSet at +46: one ligature, 4 bytes on.
    _push_u16(data, 1)
    _push_u16(data, 4)
    _push_u16(data, 200)
    _push_u16(data, 2)
    _push_u16(data, 21)

    return data^


def _assert_synthetic_ligature_subst(data: List[UInt8], subtable: Int) raises:
    # Longest-first: 10 11 12 takes the three-component record, not the
    # two-component 10 11 that also matches at this position.
    var longest = _ligature_subst_lookup(data, subtable, [10, 11, 12], 0)
    assert_equal(longest[0], 100)
    assert_equal(longest[1], 3)

    # A partial match falls through to the next record rather than
    # failing: 10 11 99 matches the first record's first component and
    # diverges at its last.
    var partial = _ligature_subst_lookup(data, subtable, [10, 11, 99], 0)
    assert_equal(partial[0], 101)
    assert_equal(partial[1], 2)

    # So does a record whose components run past the end of the
    # sequence.
    var truncated = _ligature_subst_lookup(data, subtable, [10, 11], 0)
    assert_equal(truncated[0], 101)
    assert_equal(truncated[1], 2)

    # The third record, which shares neither of the others' second
    # component.
    var third = _ligature_subst_lookup(data, subtable, [10, 13], 0)
    assert_equal(third[0], 102)
    assert_equal(third[1], 2)

    # Matching starts at `start`, not at the front of the sequence.
    var offset = _ligature_subst_lookup(data, subtable, [5, 10, 11, 12], 1)
    assert_equal(offset[0], 100)
    assert_equal(offset[1], 3)

    # The second LigatureSet, selected by its own coverage entry.
    var second_set = _ligature_subst_lookup(data, subtable, [20, 21], 0)
    assert_equal(second_set[0], 200)
    assert_equal(second_set[1], 2)

    # A covered first glyph whose set holds no matching record, and a
    # first glyph outside Coverage: both leave the sequence alone.
    var no_record = _ligature_subst_lookup(data, subtable, [10, 99], 0)
    assert_equal(no_record[0], -1)
    assert_equal(no_record[1], 0)
    var uncovered = _ligature_subst_lookup(data, subtable, [11, 12], 0)
    assert_equal(uncovered[0], -1)
    assert_equal(uncovered[1], 0)


def test_synthetic_gsub_ligature_subst_decodes_through_the_lists() raises:
    var data = _synthetic_gsub(False)
    var lookups = _gsub_subst_lookups(data, 6)
    assert_equal(len(lookups.subtables), 1)
    assert_equal(lookups.subtables[0], 6 + 0x38)
    assert_equal(lookups.types[0], 4)
    # One lookup, so one group spanning the single subtable.
    assert_equal(len(lookups.bounds), 2)
    assert_equal(lookups.bounds[0], 0)
    assert_equal(lookups.bounds[1], 1)
    _assert_synthetic_ligature_subst(data, lookups.subtables[0])


def test_synthetic_gsub_extension_lookup_reaches_the_ligature_subst() raises:
    # GSUB's extension wrapper is lookup type 7 where GPOS's is 9, and
    # its 32 bit offset is measured from the wrapper rather than from
    # the Lookup -- the same subtable as above, 8 bytes further out.
    # The type recorded is the wrapped 4, not the wrapper's 7.
    var data = _synthetic_gsub(True)
    var lookups = _gsub_subst_lookups(data, 6)
    assert_equal(len(lookups.subtables), 1)
    assert_equal(lookups.subtables[0], 6 + 0x40)
    assert_equal(lookups.types[0], 4)
    _assert_synthetic_ligature_subst(data, lookups.subtables[0])


def test_ligature_substitution_in_a_real_font() raises:
    # DejaVu Sans's 'liga' feature reaches one LigatureSet, on "f",
    # ordered ffl, ffi, fl, fi, ff. Each ligature glyph is checked
    # against an independent route to the same glyph: the font also
    # maps the precomposed Alphabetic Presentation Forms (U+FB00 "ff"
    # through U+FB04 "ffl") in `cmap`, and GSUB substitutes to those
    # same glyphs.
    var face = _sans_face()
    assert_true(face.has_substitutions())
    var f = face.glyph_index_for_codepoint(0x66)
    var i = face.glyph_index_for_codepoint(0x69)
    var l = face.glyph_index_for_codepoint(0x6C)

    var ffi = face.substitute_glyphs([f, f, i])
    assert_equal(len(ffi.glyphs), 1)
    assert_equal(ffi.glyphs[0], face.glyph_index_for_codepoint(0xFB03))
    assert_equal(ffi.clusters[0], 3)

    # "fl" then "i": both three-component records diverge, so the
    # two-component "fl" applies and the "i" passes through. The
    # clusters sum to the three glyphs that went in.
    var fli = face.substitute_glyphs([f, l, i])
    assert_equal(len(fli.glyphs), 2)
    assert_equal(fli.glyphs[0], face.glyph_index_for_codepoint(0xFB02))
    assert_equal(fli.glyphs[1], i)
    assert_equal(fli.clusters[0], 2)
    assert_equal(fli.clusters[1], 1)

    # A sequence with no ligature in it comes back unchanged.
    var plain = face.substitute_glyphs([i, l, f])
    assert_equal(len(plain.glyphs), 3)
    assert_equal(plain.glyphs[0], i)
    assert_equal(plain.glyphs[1], l)
    assert_equal(plain.glyphs[2], f)


def test_ligature_substitution_in_a_second_real_font() raises:
    # Ubuntu writes the same set in a different order -- ffi, ffl, ff,
    # fi, fl -- and has no precomposed U+FB03 to check against, so this
    # asserts the shape rather than the glyph ids, which differ between
    # the Linux and macOS CI images: three glyphs become one, and that
    # one is neither a component nor the shorter "ff" ligature.
    var face = _ubuntu_face()
    assert_true(face.has_substitutions())
    var f = face.glyph_index_for_codepoint(0x66)
    var i = face.glyph_index_for_codepoint(0x69)

    var ffi = face.substitute_glyphs([f, f, i])
    assert_equal(len(ffi.glyphs), 1)
    assert_equal(ffi.clusters[0], 3)
    assert_true(ffi.glyphs[0] != f and ffi.glyphs[0] != i)

    var ff = face.substitute_glyphs([f, f])
    assert_equal(len(ff.glyphs), 1)
    assert_equal(ff.clusters[0], 2)
    assert_true(ff.glyphs[0] != ffi.glyphs[0])
