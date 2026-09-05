"""Native TrueType (`sfnt`/`glyf`) font file parser: reads a font file's
binary tables directly (table directory, `head`, `maxp`, `hhea`,
`hmtx`, `cmap`, `glyf`, `loca`, `kern`, `GPOS`) rather than linking a
font library. Field offsets and decode algorithms follow Microsoft's
OpenType 1.9.1 specification (learn.microsoft.com/typography/opentype/
spec/{otff,head,maxp,hhea,hmtx,cmap,loca,glyf,kern,gpos,chapter2}).

Scope:

- **TrueType (`glyf`) outlines only.** A font whose `sfntVersion` is
  `OTTO` (CFF outlines) raises rather than being misread; CFF is a
  different Type 2 charstring bytecode, natively cubic where TrueType is
  quadratic-with-implied-midpoints.
- **Pair kerning only**, through `kern_adjustment`: `GPOS` lookup type 2
  (PairPos formats 1 and 2, including behind an extension lookup type
  9) under the `kern` feature, and the `kern` table's format 0
  horizontal subtables. No `GSUB` (ligatures, contextual substitution),
  no mark attachment, no contextual positioning, and lookup flags such
  as IgnoreMarks are not honored -- an intervening mark glyph breaks a
  pair here where a full shaper would kern through it.
- **No hinting.** Every glyph goes through `fill_path_aa`'s supersampled
  coverage AA instead, which keeps unhinted outlines correct at the sizes
  a chart uses.
- **Variable fonts** (`fvar`/`gvar`) read as their default instance:
  `glyf`/`loca` hold the non-varied outlines and `gvar`'s per-instance
  deltas are never read.
- **Composite glyphs** ("é" = "e" + combining acute) are supported,
  including the scale/2x2-transform component flags. Point-matching
  placement (`ARGS_ARE_XY_VALUES` unset) raises.
"""

from std.memory import ArcPointer

from canvas.path import Path


def _u8(data: List[UInt8], pos: Int) raises -> Int:
    if pos < 0 or pos >= len(data):
        raise Error("ttf: read past end of file")
    return Int(data[pos])


def _u16(data: List[UInt8], pos: Int) raises -> Int:
    if pos < 0 or pos + 2 > len(data):
        raise Error("ttf: read past end of file")
    return (Int(data[pos]) << 8) | Int(data[pos + 1])


def _i16(data: List[UInt8], pos: Int) raises -> Int:
    var v = _u16(data, pos)
    if v >= 32768:
        return v - 65536
    return v


def _i8(data: List[UInt8], pos: Int) raises -> Int:
    var v = _u8(data, pos)
    if v >= 128:
        return v - 256
    return v


def _u32(data: List[UInt8], pos: Int) raises -> Int:
    if pos < 0 or pos + 4 > len(data):
        raise Error("ttf: read past end of file")
    return (
        (Int(data[pos]) << 24)
        | (Int(data[pos + 1]) << 16)
        | (Int(data[pos + 2]) << 8)
        | Int(data[pos + 3])
    )


def _f2dot14(data: List[UInt8], pos: Int) raises -> Float64:
    """16-bit signed 2.14 fixed-point, OpenType's `F2DOT14`, used for
    component-transform scale values.
    """
    return Float64(_i16(data, pos)) / 16384.0


def _tag_at(data: List[UInt8], pos: Int) raises -> String:
    var s = String()
    for i in range(4):
        s += chr(_u8(data, pos + i))
    return s


# `kern` subtable coverage bits (low byte of the `coverage` field; the
# high byte is the subtable format).
comptime _KERN_HORIZONTAL = 0x0001
comptime _KERN_MINIMUM = 0x0002
comptime _KERN_OVERRIDE = 0x0008

# GPOS lookup types read here: pair adjustment, and the extension
# wrapper that holds one when the table is large enough to need 32-bit
# subtable offsets.
comptime _GPOS_LOOKUP_PAIR = 2
comptime _GPOS_LOOKUP_EXTENSION = 9

# ValueRecord field bits. Only XAdvance is read; XPlacement and
# YPlacement precede it in the record when set, so their bits decide
# where it sits.
comptime _VALUE_X_PLACEMENT = 0x0001
comptime _VALUE_Y_PLACEMENT = 0x0002
comptime _VALUE_X_ADVANCE = 0x0004


def _append_unique(mut values: List[Int], value: Int):
    for i in range(len(values)):
        if values[i] == value:
            return
    values.append(value)


def _contains(values: List[Int], value: Int) -> Bool:
    for i in range(len(values)):
        if values[i] == value:
            return True
    return False


def _value_record_size(value_format: Int) -> Int:
    """A ValueRecord's byte length: one 16-bit field per set bit of
    `valueFormat`, the eight defined bits being four metrics and four
    device-table offsets.
    """
    var size = 0
    for bit in range(8):
        if (value_format & (1 << bit)) != 0:
            size += 2
    return size


def _x_advance(data: List[UInt8], pos: Int, value_format: Int) raises -> Int:
    """A ValueRecord's `xAdvance`, in font design units, or 0 when the
    record does not carry one. Fields appear in `valueFormat` bit
    order, so only XPlacement and YPlacement can precede it.
    """
    if (value_format & _VALUE_X_ADVANCE) == 0:
        return 0
    var offset = pos
    if (value_format & _VALUE_X_PLACEMENT) != 0:
        offset += 2
    if (value_format & _VALUE_Y_PLACEMENT) != 0:
        offset += 2
    return _i16(data, offset)


def _coverage_index(
    data: List[UInt8], coverage: Int, glyph_index: Int
) raises -> Int:
    """`glyph_index`'s position in a Coverage table, or -1 if absent.
    Both formats store their entries sorted by glyph id, so both are
    searched by bisection.
    """
    var format = _u16(data, coverage)
    if format == 1:
        var count = _u16(data, coverage + 2)
        var lo = 0
        var hi = count - 1
        while lo <= hi:
            var mid = (lo + hi) // 2
            var g = _u16(data, coverage + 4 + mid * 2)
            if g == glyph_index:
                return mid
            elif g < glyph_index:
                lo = mid + 1
            else:
                hi = mid - 1
        return -1
    if format == 2:
        var count = _u16(data, coverage + 2)
        var lo = 0
        var hi = count - 1
        while lo <= hi:
            var mid = (lo + hi) // 2
            var record = coverage + 4 + mid * 6
            var start = _u16(data, record)
            var end = _u16(data, record + 2)
            if glyph_index < start:
                hi = mid - 1
            elif glyph_index > end:
                lo = mid + 1
            else:
                return _u16(data, record + 4) + (glyph_index - start)
        return -1
    return -1


def _class_value(
    data: List[UInt8], class_def: Int, glyph_index: Int
) raises -> Int:
    """`glyph_index`'s class in a ClassDef table. A glyph listed by
    neither format is class 0, the spec's catch-all for "everything
    else".
    """
    var format = _u16(data, class_def)
    if format == 1:
        var start = _u16(data, class_def + 2)
        var count = _u16(data, class_def + 4)
        if glyph_index < start or glyph_index >= start + count:
            return 0
        return _u16(data, class_def + 6 + (glyph_index - start) * 2)
    if format == 2:
        var count = _u16(data, class_def + 2)
        var lo = 0
        var hi = count - 1
        while lo <= hi:
            var mid = (lo + hi) // 2
            var record = class_def + 4 + mid * 6
            var start = _u16(data, record)
            var end = _u16(data, record + 2)
            if glyph_index < start:
                hi = mid - 1
            elif glyph_index > end:
                lo = mid + 1
            else:
                return _u16(data, record + 4)
        return 0
    return 0


def _pair_pos_lookup(
    data: List[UInt8], subtable: Int, left: Int, right: Int
) raises -> Tuple[Bool, Int]:
    """One PairPos subtable's x-advance adjustment for (`left`,
    `right`), and whether the subtable covers the pair at all. A
    covered pair adjusting by 0 returns (True, 0), which stops the
    search through its lookup's remaining subtables; an uncovered one
    returns (False, 0) and lets the search continue.

    Format 1 stores an explicit PairValueRecord per second glyph,
    sorted by it. Format 2 assigns both glyphs a class and indexes a
    class1_count x class2_count matrix, which is how a font expresses
    kerning for thousands of pairs in a few kilobytes.
    """
    var format = _u16(data, subtable)
    var coverage_offset = _u16(data, subtable + 2)
    if coverage_offset == 0:
        return (False, 0)
    var value_format1 = _u16(data, subtable + 4)
    var value_format2 = _u16(data, subtable + 6)
    var index = _coverage_index(data, subtable + coverage_offset, left)
    if index < 0:
        return (False, 0)

    if format == 1:
        if index >= _u16(data, subtable + 8):
            return (False, 0)
        var pair_set_offset = _u16(data, subtable + 10 + index * 2)
        if pair_set_offset == 0:
            return (False, 0)
        var pair_set = subtable + pair_set_offset
        var pair_count = _u16(data, pair_set)
        var record_size = (
            2
            + _value_record_size(value_format1)
            + _value_record_size(value_format2)
        )
        var lo = 0
        var hi = pair_count - 1
        while lo <= hi:
            var mid = (lo + hi) // 2
            var record = pair_set + 2 + mid * record_size
            var second = _u16(data, record)
            if second == right:
                return (True, _x_advance(data, record + 2, value_format1))
            elif second < right:
                lo = mid + 1
            else:
                hi = mid - 1
        return (False, 0)

    if format == 2:
        var class_def1 = _u16(data, subtable + 8)
        var class_def2 = _u16(data, subtable + 10)
        var class1_count = _u16(data, subtable + 12)
        var class2_count = _u16(data, subtable + 14)
        # A null ClassDef offset puts every glyph in class 0.
        var c1 = 0 if class_def1 == 0 else _class_value(
            data, subtable + class_def1, left
        )
        var c2 = 0 if class_def2 == 0 else _class_value(
            data, subtable + class_def2, right
        )
        if c1 >= class1_count or c2 >= class2_count:
            return (False, 0)
        var record_size = _value_record_size(
            value_format1
        ) + _value_record_size(value_format2)
        var record = subtable + 16 + (c1 * class2_count + c2) * record_size
        return (True, _x_advance(data, record, value_format1))

    return (False, 0)


struct _PairPosLookups(Movable):
    """Every PairPos subtable the `kern` feature reaches, grouped by
    the lookup holding it: `subtables[bounds[i]]` through
    `subtables[bounds[i + 1]]` are lookup `i`'s, in the order the font
    lists them. The grouping is what makes the lookup rule expressible
    -- within one lookup the first subtable covering a pair wins, and
    across lookups the adjustments add.
    """

    var subtables: List[Int]
    var bounds: List[Int]

    def __init__(out self):
        self.subtables = List[Int]()
        self.bounds = List[Int]()
        self.bounds.append(0)


def _gpos_kern_lookups(
    data: List[UInt8], gpos_offset: Int
) raises -> _PairPosLookups:
    """Walk `GPOS`'s script -> feature -> lookup lists and collect the
    PairPos subtables the `kern` feature selects.

    Every script's default language system contributes its feature
    indices; the language-specific LangSys records are not read, so a
    font whose kerning hangs off one of those alone kerns as if it had
    none. Lookups are visited in LookupList order, which is the order
    the spec applies them in.
    """
    var out = _PairPosLookups()
    if gpos_offset < 0:
        return out^
    var script_list = gpos_offset + _u16(data, gpos_offset + 4)
    var feature_list = gpos_offset + _u16(data, gpos_offset + 6)
    var lookup_list = gpos_offset + _u16(data, gpos_offset + 8)

    var feature_indices = List[Int]()
    var script_count = _u16(data, script_list)
    for i in range(script_count):
        var script = script_list + _u16(data, script_list + 2 + i * 6 + 4)
        var default_lang_sys = _u16(data, script)
        if default_lang_sys == 0:
            continue
        var lang_sys = script + default_lang_sys
        var count = _u16(data, lang_sys + 4)
        for k in range(count):
            _append_unique(feature_indices, _u16(data, lang_sys + 6 + k * 2))

    var lookup_indices = List[Int]()
    for i in range(len(feature_indices)):
        var record = feature_list + 2 + feature_indices[i] * 6
        if _tag_at(data, record) != "kern":
            continue
        var feature = feature_list + _u16(data, record + 4)
        var count = _u16(data, feature + 2)
        for k in range(count):
            _append_unique(lookup_indices, _u16(data, feature + 4 + k * 2))

    var lookup_count = _u16(data, lookup_list)
    for index in range(lookup_count):
        if not _contains(lookup_indices, index):
            continue
        var lookup = lookup_list + _u16(data, lookup_list + 2 + index * 2)
        var lookup_type = _u16(data, lookup)
        if (
            lookup_type != _GPOS_LOOKUP_PAIR
            and lookup_type != _GPOS_LOOKUP_EXTENSION
        ):
            continue
        var sub_count = _u16(data, lookup + 4)
        var added = False
        for k in range(sub_count):
            var subtable = lookup + _u16(data, lookup + 6 + k * 2)
            if lookup_type == _GPOS_LOOKUP_EXTENSION:
                # ExtensionPos format 1: the wrapped lookup's type plus
                # a 32-bit offset from the wrapper's own start.
                if _u16(data, subtable) != 1:
                    continue
                if _u16(data, subtable + 2) != _GPOS_LOOKUP_PAIR:
                    continue
                subtable += _u32(data, subtable + 4)
            var format = _u16(data, subtable)
            if format != 1 and format != 2:
                continue
            out.subtables.append(subtable)
            added = True
        if added:
            out.bounds.append(len(out.subtables))
    return out^


def _kern_format0_subtables(
    data: List[UInt8], kern_offset: Int
) raises -> List[Int]:
    """Offsets of the `kern` table's format 0 horizontal subtables, in
    table order.

    Only Microsoft's version 0 header is read (a 16-bit version and a
    16-bit subtable count); Apple's version 1 lays its header and its
    subtable headers out differently, and a font carrying one kerns as
    if it had no `kern` table. Subtables flagged "minimum" state a
    floor on the distance between two glyphs rather than an adjustment
    to it, so they are skipped as well.
    """
    var out = List[Int]()
    if kern_offset < 0:
        return out^
    if _u16(data, kern_offset) != 0:
        return out^
    var num_subtables = _u16(data, kern_offset + 2)
    var pos = kern_offset + 4
    for _ in range(num_subtables):
        var length = _u16(data, pos + 2)
        var coverage = _u16(data, pos + 4)
        var format = coverage >> 8
        if (
            format == 0
            and (coverage & _KERN_HORIZONTAL) != 0
            and (coverage & _KERN_MINIMUM) == 0
        ):
            out.append(pos)
        if length == 0:
            break
        pos += length
    return out^


def _kern_format0_lookup(
    data: List[UInt8], subtable: Int, left: Int, right: Int
) raises -> Tuple[Bool, Int]:
    """One format 0 `kern` subtable's adjustment for (`left`, `right`),
    and whether the pair is listed at all. Pairs are sorted by the
    32-bit value (left << 16) | right, so a bisection on that key is
    the lookup -- what the subtable's own searchRange/entrySelector/
    rangeShift fields exist to drive, and which this recomputes rather
    than trusting.
    """
    var num_pairs = _u16(data, subtable + 6)
    var first_pair = subtable + 14
    var target = (left << 16) | right
    var lo = 0
    var hi = num_pairs - 1
    while lo <= hi:
        var mid = (lo + hi) // 2
        var record = first_pair + mid * 6
        var key = (_u16(data, record) << 16) | _u16(data, record + 2)
        if key == target:
            return (True, _i16(data, record + 4))
        elif key < target:
            lo = mid + 1
        else:
            hi = mid - 1
    return (False, 0)


struct RawGlyphOutline(Movable):
    """A decoded glyph outline in plain-`List` form: on-curve/off-curve
    points plus per-contour end indices -- FreeType's `FT_Outline`
    shape (points, tags, contour ends) as owned `List`s rather than raw
    C pointers, so this module has no pointer surface.

    `on_curve[i]` corresponds to `points_x[i]`/`points_y[i]`, and
    `contour_ends[c]` is the inclusive index of contour `c`'s last
    point, matching `glyf`'s `endPtsOfContours` and OpenType's
    composite-glyph point renumbering -- so every component's contours
    land in this one flat structure with no special-casing.
    """

    var points_x: List[Int]
    var points_y: List[Int]
    var on_curve: List[Bool]
    var contour_ends: List[Int]

    def __init__(out self):
        self.points_x = List[Int]()
        self.points_y = List[Int]()
        self.on_curve = List[Bool]()
        self.contour_ends = List[Int]()

    def copied(self) -> RawGlyphOutline:
        """An independent copy of this outline's point lists."""
        var out = RawGlyphOutline()
        out.points_x = self.points_x.copy()
        out.points_y = self.points_y.copy()
        out.on_curve = self.on_curve.copy()
        out.contour_ends = self.contour_ends.copy()
        return out^

    def bounding_box(self) -> Tuple[Int, Int, Int, Int]:
        """(xMin, yMin, xMax, yMax) across every point, computed from
        the point coordinate data the way the OpenType spec defines a
        glyph's bounding box ("obtained directly from the point
        coordinate data for the glyph, comparing all on-curve and
        off-curve points"), rather than from the `glyf` header's
        xMin/yMin/xMax/yMax. Those exist only for simple glyphs, while
        scanning the assembled post-transform point list also covers
        composite ones. A glyph with no points (whitespace) returns all
        zeros.
        """
        if len(self.points_x) == 0:
            return (0, 0, 0, 0)
        var x_min = self.points_x[0]
        var y_min = self.points_y[0]
        var x_max = self.points_x[0]
        var y_max = self.points_y[0]
        for i in range(1, len(self.points_x)):
            var x = self.points_x[i]
            var y = self.points_y[i]
            if x < x_min:
                x_min = x
            if x > x_max:
                x_max = x
            if y < y_min:
                y_min = y
            if y > y_max:
                y_max = y
        return (x_min, y_min, x_max, y_max)


struct TTFFace(Movable):
    """A parsed TrueType font file: the raw file bytes plus the table
    offsets and global metrics this module reads.
    """

    var data: List[UInt8]
    var units_per_em: Int
    var num_glyphs: Int
    var index_to_loc_format: Int
    var ascender: Int
    var descender: Int
    var line_gap: Int
    var num_h_metrics: Int
    var _cmap_offset: Int
    var _glyf_offset: Int
    var _loca_offset: Int
    var _hmtx_offset: Int
    var _glyph_cache: Dict[Int, ArcPointer[RawGlyphOutline]]
    """Decoded outlines, keyed by glyph index.

    Decoding depends only on the glyph, not the size it is drawn at,
    since a `RawGlyphOutline` is in font design units and scaled later.
    `ArcPointer`, because `RawGlyphOutline` owns its point lists and is
    Movable only, so a hit is a refcount bump rather than a copy.
    """

    var _cmap_cache: Dict[Int, Int]
    """Codepoint -> glyph index, memoizing the `cmap` subtable scan."""

    var _gpos_kern: _PairPosLookups
    """PairPos subtables the `GPOS` `kern` feature reaches, grouped by
    lookup. Empty when the font has no `GPOS` kerning.
    """

    var _kern_subtables: List[Int]
    """Format 0 horizontal `kern` subtable offsets, the fallback when
    `_gpos_kern` is empty.
    """

    var _kern_cache: Dict[Int, Int]
    """(left << 16) | right -> x-advance adjustment in font design
    units, memoizing `kern_adjustment`'s table walk.
    """

    var _pixel_size: Int
    """-1 until `set_pixel_size` is called, so an unset size is not a
    valid one. Every read goes through `scale()`, which raises rather
    than measuring and drawing at a defaulted size.
    """

    def __init__(out self, path: String) raises:
        """Parse a TrueType (`glyf`-outline) font file.

        Args:
            path: Path to a `.ttf` file.

        Raises:
            Error: `path` can't be read, isn't a TrueType font (a
                CFF/OpenType-CFF `.otf` included), or is missing a
                required table.
        """
        var f = open(path, "r")
        var data = f.read_bytes()
        f.close()

        if len(data) < 12:
            raise Error("ttf: file too short to be a TrueType font")

        comptime _SFNT_VERSION_TRUETYPE = 0x00010000
        # 'true', Apple's own legacy TrueType tag, also valid
        comptime _SFNT_VERSION_TRUETYPE_APPLE = 0x74727565
        # 'OTTO' -- CFF/OpenType-CFF outlines, not supported
        comptime _SFNT_VERSION_OTTO = 0x4F54544F

        var sfnt_version = _u32(data, 0)
        if sfnt_version == _SFNT_VERSION_OTTO:
            raise Error(
                "ttf: CFF/OpenType-CFF font ('OTTO') -- only TrueType 'glyf'"
                " outlines are supported"
            )
        if (
            sfnt_version != _SFNT_VERSION_TRUETYPE
            and sfnt_version != _SFNT_VERSION_TRUETYPE_APPLE
        ):
            raise Error(
                String("ttf: unrecognized sfntVersion 0x", hex(sfnt_version))
            )

        var num_tables = _u16(data, 4)

        var cmap_off = -1
        var glyf_off = -1
        var loca_off = -1
        var head_off = -1
        var maxp_off = -1
        var hhea_off = -1
        var hmtx_off = -1
        var kern_off = -1
        var gpos_off = -1

        var pos = 12
        for _ in range(num_tables):
            var tag = _tag_at(data, pos)
            var offset = _u32(data, pos + 8)
            if tag == "cmap":
                cmap_off = offset
            elif tag == "glyf":
                glyf_off = offset
            elif tag == "loca":
                loca_off = offset
            elif tag == "head":
                head_off = offset
            elif tag == "maxp":
                maxp_off = offset
            elif tag == "hhea":
                hhea_off = offset
            elif tag == "hmtx":
                hmtx_off = offset
            elif tag == "kern":
                kern_off = offset
            elif tag == "GPOS":
                gpos_off = offset
            pos += 16

        if (
            head_off == -1
            or maxp_off == -1
            or hhea_off == -1
            or hmtx_off == -1
            or cmap_off == -1
        ):
            raise Error(
                "ttf: missing a required table (head/maxp/hhea/hmtx/cmap)"
            )
        if glyf_off == -1 or loca_off == -1:
            raise Error(
                "ttf: no glyf/loca table -- likely a CFF/OpenType-CFF font, not"
                " supported"
            )

        self.units_per_em = _u16(data, head_off + 18)
        self.index_to_loc_format = _i16(data, head_off + 50)
        self.num_glyphs = _u16(data, maxp_off + 4)
        self.ascender = _i16(data, hhea_off + 4)
        self.descender = _i16(data, hhea_off + 6)
        self.line_gap = _i16(data, hhea_off + 8)
        self.num_h_metrics = _u16(data, hhea_off + 34)

        self._cmap_offset = cmap_off
        self._glyf_offset = glyf_off
        self._loca_offset = loca_off
        self._hmtx_offset = hmtx_off
        self._glyph_cache = Dict[Int, ArcPointer[RawGlyphOutline]]()
        self._cmap_cache = Dict[Int, Int]()
        # Collecting the kerning subtable offsets walks a few hundred
        # bytes of list headers, not the pair data itself, so it runs
        # here rather than lazily on the first pair queried.
        self._gpos_kern = _gpos_kern_lookups(data, gpos_off)
        self._kern_subtables = _kern_format0_subtables(data, kern_off)
        self._kern_cache = Dict[Int, Int]()
        self._pixel_size = -1
        self.data = data^

    def set_pixel_size(mut self, pixel_size: Int):
        """Set this face's active rasterization size in pixels. Must
        precede `scale()` or any pixel-space metric or outline query.

        Args:
            pixel_size: Rasterization size in pixels.
        """
        self._pixel_size = pixel_size

    def scale(self) raises -> Float64:
        """Font-design-units -> pixels conversion factor at the active
        pixel size (`pixel_size / units_per_em`). Raises if
        `set_pixel_size` was never called (see `_pixel_size`).
        """
        if self._pixel_size < 0:
            raise Error(
                "ttf: no active pixel size on this TTFFace -- call"
                " set_pixel_size() before measuring or loading glyphs"
            )
        return Float64(self._pixel_size) / Float64(self.units_per_em)

    def advance_width(self, glyph_index: Int) raises -> Int:
        """`hmtx`'s rule that when there are fewer hMetrics entries
        than glyphs, the last entry's advance width repeats for the
        rest -- the spec's optimization for monospace and large fonts.

        Args:
            glyph_index: Glyph to look up.

        Returns:
            The glyph's advance width, in font design units.
        """
        var index = (
            glyph_index if glyph_index
            < self.num_h_metrics else self.num_h_metrics - 1
        )
        return _u16(self.data, self._hmtx_offset + index * 4)

    def has_kerning(self) -> Bool:
        """Whether this font carries pair kerning this module reads --
        a `GPOS` `kern` feature with PairPos lookups, or a format 0
        horizontal `kern` subtable.

        Returns:
            True if `kern_adjustment` can return a nonzero value.
        """
        return (
            len(self._gpos_kern.subtables) > 0 or len(self._kern_subtables) > 0
        )

    def kern_adjustment(mut self, left: Int, right: Int) raises -> Int:
        """The x-advance adjustment to apply between two adjacent
        glyphs, in font design units. Negative pulls them together,
        which is what most kerned pairs ("AV", "To") ask for.

        `GPOS` takes precedence over the `kern` table when the font has
        both, since a font shipping both writes `GPOS` for shapers and
        `kern` for the legacy path, and every shaper resolves the
        overlap the same way. Memoized, since text repeats pairs.

        Args:
            left: Glyph index of the left-hand glyph.
            right: Glyph index of the right-hand glyph.

        Returns:
            The pair's x-advance adjustment in font design units, 0
            when the font kerns neither pair nor at all.
        """
        if left == 0 or right == 0:
            return 0
        var key = (left << 16) | right
        if key in self._kern_cache:
            return self._kern_cache[key]
        var value: Int
        if len(self._gpos_kern.subtables) > 0:
            value = self._gpos_pair_adjustment(left, right)
        else:
            value = self._kern_table_adjustment(left, right)
        self._kern_cache[key] = value
        return value

    def _gpos_pair_adjustment(self, left: Int, right: Int) raises -> Int:
        """Sum the `kern` feature's lookups, each contributing the
        first of its subtables that covers the pair -- the spec's rule
        that a lookup stops at its first match while the lookups
        themselves all apply.
        """
        var total = 0
        for i in range(len(self._gpos_kern.bounds) - 1):
            for k in range(
                self._gpos_kern.bounds[i], self._gpos_kern.bounds[i + 1]
            ):
                var found = _pair_pos_lookup(
                    self.data, self._gpos_kern.subtables[k], left, right
                )
                if found[0]:
                    total += found[1]
                    break
        return total

    def _kern_table_adjustment(self, left: Int, right: Int) raises -> Int:
        """Accumulate the format 0 subtables in table order. A subtable
        flagged "override" replaces what the earlier ones accumulated
        rather than adding to it.
        """
        var total = 0
        for i in range(len(self._kern_subtables)):
            var subtable = self._kern_subtables[i]
            var found = _kern_format0_lookup(self.data, subtable, left, right)
            if not found[0]:
                continue
            if (_u16(self.data, subtable + 4) & _KERN_OVERRIDE) != 0:
                total = found[1]
            else:
                total += found[1]
        return total

    def glyph_index_for_codepoint(mut self, codepoint: Int) raises -> Int:
        """Look up `codepoint` in the `cmap` table, preferring a
        full-Unicode format 12 subtable (covering supplementary planes:
        emoji, some CJK) over a BMP-only format 4 one. Returns 0
        (".notdef") when no subtable maps it, `cmap`'s convention.

        Memoized, since text repeats characters.

        Args:
            codepoint: Unicode codepoint to look up.

        Returns:
            The mapped glyph index, or 0 (".notdef") if unmapped.
        """
        if codepoint in self._cmap_cache:
            return self._cmap_cache[codepoint]
        var result = self._glyph_index_uncached(codepoint)
        self._cmap_cache[codepoint] = result
        return result

    def _glyph_index_uncached(self, codepoint: Int) raises -> Int:
        var cmap_off = self._cmap_offset
        var num_tables = _u16(self.data, cmap_off + 2)

        var best_offset = -1
        var best_format = -1
        var pos = cmap_off + 4
        for _ in range(num_tables):
            var platform_id = _u16(self.data, pos)
            var encoding_id = _u16(self.data, pos + 2)
            var subtable_offset = _u32(self.data, pos + 4)
            var absolute = cmap_off + subtable_offset
            var format = _u16(self.data, absolute)
            # Prefer format 12 (full Unicode) over format 4 (BMP-only)
            # over anything else, the priority DejaVu Sans's cmap
            # exposes: platform 0/encoding 4 and platform 3/encoding 10
            # both point at its one format-12 subtable, a superset of
            # what its format-4
            # subtable covers.
            var is_unicode_platform = platform_id == 0 or (
                platform_id == 3 and (encoding_id == 1 or encoding_id == 10)
            )
            if is_unicode_platform:
                if format == 12 and best_format != 12:
                    best_offset = absolute
                    best_format = 12
                elif format == 4 and best_format != 12 and best_format != 4:
                    best_offset = absolute
                    best_format = 4
            pos += 8

        if best_offset == -1:
            return 0
        if best_format == 12:
            return self._lookup_cmap_format12(best_offset, codepoint)
        return self._lookup_cmap_format4(best_offset, codepoint)

    def _lookup_cmap_format4(
        self, subtable_offset: Int, codepoint: Int
    ) raises -> Int:
        if codepoint > 0xFFFF:
            return 0  # format 4 is BMP-only by definition
        var seg_count_x2 = _u16(self.data, subtable_offset + 6)
        var seg_count = seg_count_x2 // 2
        var end_code_off = subtable_offset + 14
        var start_code_off = (
            end_code_off + seg_count * 2 + 2
        )  # +2 skips reservedPad
        var id_delta_off = start_code_off + seg_count * 2
        var id_range_offset_off = id_delta_off + seg_count * 2

        for i in range(seg_count):
            var end_code = _u16(self.data, end_code_off + i * 2)
            if codepoint <= end_code:
                var start_code = _u16(self.data, start_code_off + i * 2)
                if codepoint < start_code:
                    return 0
                var id_delta = _i16(self.data, id_delta_off + i * 2)
                var range_offset = _u16(self.data, id_range_offset_off + i * 2)
                var glyph_id: Int
                if range_offset == 0:
                    glyph_id = codepoint + id_delta
                else:
                    # "This obscure indexing trick works because
                    # glyphIdArray immediately follows idRangeOffset in
                    # the font file" -- the OpenType spec's words,
                    # translated directly: glyphId = *(idRangeOffset[i]/2
                    # + (c - startCode[i]) + &idRangeOffset[i]).
                    var glyph_addr = (
                        id_range_offset_off
                        + i * 2
                        + range_offset
                        + (codepoint - start_code) * 2
                    )
                    var raw = _u16(self.data, glyph_addr)
                    if raw == 0:
                        return 0
                    glyph_id = raw + id_delta
                # idDelta arithmetic is modulo 65536 per spec, including
                # wrapping a negative result back into range.
                glyph_id = glyph_id % 65536
                if glyph_id < 0:
                    glyph_id += 65536
                return glyph_id
        return 0

    def _lookup_cmap_format12(
        self, subtable_offset: Int, codepoint: Int
    ) raises -> Int:
        var num_groups = _u32(self.data, subtable_offset + 12)
        var groups_off = subtable_offset + 16
        # Linear scan; num_groups is in the tens for every real font
        # checked. Groups are sorted per spec, so a binary search would
        # fit if that ever stops holding.
        for i in range(num_groups):
            var group_off = groups_off + i * 12
            var start_char = _u32(self.data, group_off)
            var end_char = _u32(self.data, group_off + 4)
            if codepoint >= start_char and codepoint <= end_char:
                var start_glyph = _u32(self.data, group_off + 8)
                return start_glyph + (codepoint - start_char)
        return 0

    def _loca_entry(self, glyph_index: Int) raises -> Tuple[Int, Int]:
        if self.index_to_loc_format == 0:
            var start = _u16(self.data, self._loca_offset + glyph_index * 2) * 2
            var end = (
                _u16(self.data, self._loca_offset + (glyph_index + 1) * 2) * 2
            )
            return (start, end)
        else:
            var start = _u32(self.data, self._loca_offset + glyph_index * 4)
            var end = _u32(self.data, self._loca_offset + (glyph_index + 1) * 4)
            return (start, end)

    def glyph_outline(mut self, glyph_index: Int) raises -> RawGlyphOutline:
        """This glyph's decoded outline, in font design units.

        Returns an owned outline, copying the cached one's point lists.
        `glyph_outline_shared` is what the rendering path uses.

        Args:
            glyph_index: Glyph to decode.

        Returns:
            The glyph's contours/points, in font design units.
        """
        return self.glyph_outline_shared(glyph_index)[].copied()

    def glyph_outline_shared(
        mut self, glyph_index: Int
    ) raises -> ArcPointer[RawGlyphOutline]:
        """This glyph's decoded outline, shared rather than copied.

        Args:
            glyph_index: Glyph to decode.

        Returns:
            The glyph's contours/points, in font design units, shared
            with every other caller decoding the same glyph index.
        """
        if glyph_index in self._glyph_cache:
            return self._glyph_cache[glyph_index]
        var outline = self._glyph_outline_impl(glyph_index, 0)
        var shared = ArcPointer(outline^)
        self._glyph_cache[glyph_index] = shared
        return shared

    def _glyph_outline_impl(
        self, glyph_index: Int, depth: Int
    ) raises -> RawGlyphOutline:
        if depth > 8:
            raise Error(
                "ttf: composite glyph nesting too deep (possible cycle)"
            )
        if glyph_index < 0 or glyph_index >= self.num_glyphs:
            raise Error(
                String("ttf: glyph index ", glyph_index, " out of range")
            )

        var loca = self._loca_entry(glyph_index)
        var glyph_start = self._glyf_offset + loca[0]
        var glyph_len = loca[1] - loca[0]

        var outline = RawGlyphOutline()
        if glyph_len == 0:
            return outline^  # no outline (space, etc.)

        var number_of_contours = _i16(self.data, glyph_start)
        if number_of_contours >= 0:
            self._parse_simple_glyph(glyph_start, number_of_contours, outline)
        else:
            self._parse_composite_glyph(glyph_start, depth, outline)
        return outline^

    def _parse_simple_glyph(
        self,
        glyph_start: Int,
        number_of_contours: Int,
        mut outline: RawGlyphOutline,
    ) raises:
        var pos = glyph_start + 10

        var contour_ends = List[Int](capacity=number_of_contours)
        for i in range(number_of_contours):
            contour_ends.append(_u16(self.data, pos + i * 2))
        pos += number_of_contours * 2

        var num_points = 0
        if number_of_contours > 0:
            num_points = contour_ends[number_of_contours - 1] + 1

        var instruction_length = _u16(self.data, pos)
        pos += (
            2 + instruction_length
        )  # skip instructions -- no hinting, see module docstring

        # Flags are packed with a repeat-count byte (REPEAT_FLAG, mask
        # 0x08). Decode one flag byte per point before reading
        # coordinates: the spec puts the whole flags array ahead of
        # both coordinate arrays.
        var flags = List[Int](capacity=num_points)
        while len(flags) < num_points:
            var f = _u8(self.data, pos)
            pos += 1
            flags.append(f)
            if f & 0x08:
                var repeat_count = _u8(self.data, pos)
                pos += 1
                for _ in range(repeat_count):
                    if len(flags) >= num_points:
                        break
                    flags.append(f)

        var xs = List[Int](capacity=num_points)
        var x = 0
        for i in range(num_points):
            var f = flags[i]
            if f & 0x02:  # X_SHORT_VECTOR
                var dx = _u8(self.data, pos)
                pos += 1
                x += dx if (f & 0x10) else -dx
            elif not (
                f & 0x10
            ):  # not short, not "same as previous" -> signed 16-bit delta
                var dx = _i16(self.data, pos)
                pos += 2
                x += dx
            # else: X_SHORT_VECTOR clear and X_IS_SAME_OR_POSITIVE set
            # -> delta is 0, x unchanged, no bytes consumed.
            xs.append(x)

        var ys = List[Int](capacity=num_points)
        var y = 0
        for i in range(num_points):
            var f = flags[i]
            if f & 0x04:  # Y_SHORT_VECTOR
                var dy = _u8(self.data, pos)
                pos += 1
                y += dy if (f & 0x20) else -dy
            elif not (f & 0x20):
                var dy = _i16(self.data, pos)
                pos += 2
                y += dy
            ys.append(y)

        for i in range(num_points):
            outline.points_x.append(xs[i])
            outline.points_y.append(ys[i])
            outline.on_curve.append((flags[i] & 0x01) != 0)
        for i in range(number_of_contours):
            outline.contour_ends.append(contour_ends[i])

    def _parse_composite_glyph(
        self, glyph_start: Int, depth: Int, mut outline: RawGlyphOutline
    ) raises:
        var pos = glyph_start + 10
        while True:
            var flags = _u16(self.data, pos)
            var child_index = _u16(self.data, pos + 2)
            pos += 4

            if not (flags & 0x0002):  # ARGS_ARE_XY_VALUES not set
                raise Error(
                    "ttf: composite glyph point-matching mode is not supported"
                )

            var arg1: Int
            var arg2: Int
            if flags & 0x0001:  # ARG_1_AND_2_ARE_WORDS
                arg1 = _i16(self.data, pos)
                arg2 = _i16(self.data, pos + 2)
                pos += 4
            else:
                arg1 = _i8(self.data, pos)
                arg2 = _i8(self.data, pos + 1)
                pos += 2

            var xscale = 1.0
            var scale01 = 0.0
            var scale10 = 0.0
            var yscale = 1.0
            if flags & 0x0008:  # WE_HAVE_A_SCALE
                var s = _f2dot14(self.data, pos)
                xscale = s
                yscale = s
                pos += 2
            elif flags & 0x0040:  # WE_HAVE_AN_X_AND_Y_SCALE
                xscale = _f2dot14(self.data, pos)
                yscale = _f2dot14(self.data, pos + 2)
                pos += 4
            elif flags & 0x0080:  # WE_HAVE_A_TWO_BY_TWO
                xscale = _f2dot14(self.data, pos)
                scale01 = _f2dot14(self.data, pos + 2)
                scale10 = _f2dot14(self.data, pos + 4)
                yscale = _f2dot14(self.data, pos + 6)
                pos += 8

            var child = self._glyph_outline_impl(child_index, depth + 1)
            var point_base = len(outline.points_x)
            for i in range(len(child.points_x)):
                var cx = Float64(child.points_x[i])
                var cy = Float64(child.points_y[i])
                # x' = xscale*x + scale10*y ; y' = scale01*x + yscale*y
                # -- OpenType's component-transform formula.
                # UNSCALED_COMPONENT_OFFSET is the documented
                # Microsoft/Apple default when neither offset flag is
                # set: the arg1/arg2 offset is in the *parent's*
                # coordinate system, added after scaling rather than
                # scaled itself.
                var tx = xscale * cx + scale10 * cy
                var ty = scale01 * cx + yscale * cy
                outline.points_x.append(Int(round(tx)) + arg1)
                outline.points_y.append(Int(round(ty)) + arg2)
                outline.on_curve.append(child.on_curve[i])
            for i in range(len(child.contour_ends)):
                outline.contour_ends.append(child.contour_ends[i] + point_base)

            if not (flags & 0x0020):  # MORE_COMPONENTS not set -> done
                break


def _native_px(pen_x: Float64, raw: Int, scale: Float64) -> Float64:
    return pen_x + Float64(raw) * scale


def _native_py(pen_y: Float64, raw: Int, scale: Float64) -> Float64:
    # Font-design space has y increasing upward; canvas pixel space has
    # y increasing downward -- same flip glyph_outline.mojo applies.
    return pen_y - Float64(raw) * scale


def _decompose_contour_native(
    outline: RawGlyphOutline,
    first: Int,
    last: Int,
    mut path: Path,
    pen_x: Float64,
    pen_y: Float64,
    scale: Float64,
) raises:
    """A direct translation of FreeType's `FT_Outline_Decompose`
    algorithm, against this module's plain-`List`-based
    `RawGlyphOutline` rather than a pointer-based `FT_Outline` -- and
    simplified accordingly: `glyf` outlines are always quadratic
    (on-curve/off-curve only), never cubic, so that algorithm's CUBIC
    branch (needed only because FreeType's outline API is
    format-agnostic and can hand back cubic control points for
    CFF-outline fonts) never applies here and is omitted, not
    forgotten.
    """
    if last < first:
        return

    var v_start_raw_x = outline.points_x[first]
    var v_start_raw_y = outline.points_y[first]
    var v_last_raw_x = outline.points_x[last]
    var v_last_raw_y = outline.points_y[last]

    var limit = last
    var point_idx = first
    var start_on_curve = outline.on_curve[first]

    var v_start_x: Int
    var v_start_y: Int

    if not start_on_curve:  # contour starts on a control point
        var last_on_curve = outline.on_curve[last]
        if last_on_curve:
            v_start_x = v_last_raw_x
            v_start_y = v_last_raw_y
            limit -= 1
        else:
            v_start_x = (v_start_raw_x + v_last_raw_x) // 2
            v_start_y = (v_start_raw_y + v_last_raw_y) // 2
        point_idx -= 1
    else:
        v_start_x = v_start_raw_x
        v_start_y = v_start_raw_y

    path.move_to(
        _native_px(pen_x, v_start_x, scale), _native_py(pen_y, v_start_y, scale)
    )

    var closed = False

    while point_idx < limit and not closed:
        point_idx += 1
        var px_ = outline.points_x[point_idx]
        var py_ = outline.points_y[point_idx]
        var on = outline.on_curve[point_idx]

        if on:
            path.line_to(
                _native_px(pen_x, px_, scale), _native_py(pen_y, py_, scale)
            )
        else:
            var v_control_x = px_
            var v_control_y = py_
            var emitted = False
            while point_idx < limit:
                point_idx += 1
                var p2x = outline.points_x[point_idx]
                var p2y = outline.points_y[point_idx]
                var on2 = outline.on_curve[point_idx]
                if on2:
                    path.quad_curve_to(
                        _native_px(pen_x, v_control_x, scale),
                        _native_py(pen_y, v_control_y, scale),
                        _native_px(pen_x, p2x, scale),
                        _native_py(pen_y, p2y, scale),
                    )
                    emitted = True
                    break
                # Two consecutive off-curve points: the implied on-curve
                # point is their midpoint (the classic TrueType
                # quadratic-spline encoding trick).
                var mid_x = (v_control_x + p2x) // 2
                var mid_y = (v_control_y + p2y) // 2
                path.quad_curve_to(
                    _native_px(pen_x, v_control_x, scale),
                    _native_py(pen_y, v_control_y, scale),
                    _native_px(pen_x, mid_x, scale),
                    _native_py(pen_y, mid_y, scale),
                )
                v_control_x = p2x
                v_control_y = p2y
            if not emitted:
                # Ran out of points still holding a pending control
                # point -- close back to v_start via one final quad
                # segment.
                path.quad_curve_to(
                    _native_px(pen_x, v_control_x, scale),
                    _native_py(pen_y, v_control_y, scale),
                    _native_px(pen_x, v_start_x, scale),
                    _native_py(pen_y, v_start_y, scale),
                )
                closed = True

    if not closed:
        path.line_to(
            _native_px(pen_x, v_start_x, scale),
            _native_py(pen_y, v_start_y, scale),
        )
    path.close()


def outline_to_path(
    outline: RawGlyphOutline, pen_x: Float64, pen_y: Float64, scale: Float64
) raises -> Path:
    """One glyph's full outline (all contours) as a `Path`, positioned
    so its local (0, 0) lands at (pen_x, pen_y), the convention
    `glyph_outline.glyph_path` uses. `scale` converts font-design-units
    on this font's `units_per_em` grid to pixels, typically
    `pixel_size / face.units_per_em`.

    Args:
        outline: Decoded glyph outline, in font design units.
        pen_x: Glyph origin x, in pixel space.
        pen_y: Glyph origin y, in pixel space.
        scale: Font-design-units -> pixels conversion factor.

    Returns:
        The glyph's outline as a Path, positioned at (pen_x, pen_y).
    """
    var path = Path()
    var last = -1
    for n in range(len(outline.contour_ends)):
        var first = last + 1
        last = outline.contour_ends[n]
        _decompose_contour_native(
            outline, first, last, path, pen_x, pen_y, scale
        )
    return path^
