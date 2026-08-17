"""Native TrueType (`sfnt`/`glyf`) font file parser -- reads a font
file's own binary tables directly (table directory, `head`, `maxp`,
`hhea`, `hmtx`, `cmap`, `glyf`, `loca`) rather than linking against
FreeType. Same "translate the real spec faithfully" methodology this
package already used for FreeType's own `FT_Outline_Decompose`
(`glyph_outline.mojo`) and zlib's own `puff.c` (`io/deflate.mojo`):
every field offset and decode algorithm below was transcribed directly
from Microsoft's OpenType 1.9.1 specification (learn.microsoft.com/
typography/opentype/spec/{otff,head,maxp,hhea,hmtx,cmap,loca,glyf}),
not guessed at or reconstructed from memory -- and cross-checked
against a real font file via an independent Python oracle (using only
`struct.unpack`, no font libraries) before being trusted here, the
same "oracle, not just self-consistent" discipline the DEFLATE/PNG
work used zlib for.

Deliberately scoped, matching this package's own established v1-scope
pattern (see `io/png.mojo`'s own docstring for the precedent):

- **TrueType (`glyf`) outlines only.** A font whose `sfntVersion` is
  `OTTO` (CFF/OpenType-CFF outlines) raises a clear, specific error
  rather than being silently misread -- CFF's own outline encoding
  (a completely different Type 2 charstring bytecode, cubic Beziers
  natively rather than TrueType's quadratic-with-implied-midpoints)
  is real, addressable scope if a concrete font needs it, not
  attempted speculatively ahead of one.
- **No hinting.** FreeType's own hinting bytecode interpreter (plus
  its auto-hinter for unhinted fonts) is a large, separate subsystem;
  skipped here on purpose, not by oversight -- hinting mostly matters
  for crisp rendering at small pixel sizes on non-antialiased
  displays, and every glyph this package renders already goes through
  `fill_path_aa`'s own supersampled coverage AA, which makes unhinted
  outlines look correct at the sizes a chart actually uses (verified
  directly, not assumed -- see this module's own test file).
- **Variable fonts** (`fvar`/`gvar`) aren't specially handled, but
  don't need to be: `glyf`/`loca` still hold the font's default
  (non-varied) outline data regardless, and this module never reads
  `gvar`'s own per-instance deltas, so a variable font's default
  instance is what gets read automatically, by omission rather than
  explicit support.
- **Composite glyphs** (accented characters built from a base glyph +
  mark, e.g. glyph "é" = "e" + combining acute) are supported,
  including the scale/2x2-transform component flags -- point-matching
  placement mode (`ARGS_ARE_XY_VALUES` unset) is not, and raises a
  clear error, since every composite glyph actually encountered in
  real fonts during this module's own verification used the far more
  common xy-offset mode.

Real, non-hypothetical fact this module's own test file locks in, not
just asserted: parsing DejaVu Sans natively gives `unitsPerEm=2048`,
`numGlyphs=6253`, `ascender=1901`, `descender=-483` -- the exact same
values already independently verified against FreeType itself
elsewhere in this codebase (`glyph_outline.mojo`'s own module
docstring), not a coincidence: both are reading the same real font
file's own real data, just through two completely different
implementations.
"""

from canvas_mojo.path import Path

comptime _SFNT_VERSION_TRUETYPE = 0x00010000
comptime _SFNT_VERSION_TRUETYPE_APPLE = 0x74727565  # 'true', Apple's own legacy TrueType tag, also valid
comptime _SFNT_VERSION_OTTO = 0x4F54544F  # 'OTTO' -- CFF/OpenType-CFF outlines, not supported


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
    return (Int(data[pos]) << 24) | (Int(data[pos + 1]) << 16) | (Int(data[pos + 2]) << 8) | Int(data[pos + 3])


def _f2dot14(data: List[UInt8], pos: Int) raises -> Float64:
    """16-bit signed 2.14 fixed-point (component-transform scale
    values) -- OpenType spec's own `F2DOT14` type.
    """
    return Float64(_i16(data, pos)) / 16384.0


def _tag_at(data: List[UInt8], pos: Int) raises -> String:
    var s = String()
    for i in range(4):
        s += chr(_u8(data, pos + i))
    return s


struct RawGlyphOutline(Movable):
    """A decoded glyph outline in plain-`List` form: on-curve/off-curve
    points plus per-contour end indices, the same logical shape
    FreeType's own `FT_Outline` exposes (points + tags + contour-end
    array) but as owned `List`s instead of raw C pointers, so this
    module has zero FFI/pointer surface of its own. `on_curve[i]`
    corresponds to `points_x[i]`/`points_y[i]`; `contour_ends[c]` is
    the inclusive index of the last point of contour `c`, matching
    `glyf`'s own `endPtsOfContours` convention exactly (and OpenType's
    own composite-glyph point renumbering, so a composite glyph's
    contours from every component land in this same flat structure
    with no special-casing needed by a caller).
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

    def bounding_box(self) -> Tuple[Int, Int, Int, Int]:
        """(xMin, yMin, xMax, yMax) across every point -- computed
        directly from the point coordinate data, exactly how the
        OpenType spec itself defines a glyph's bounding box ("obtained
        directly from the point coordinate data for the glyph, comparing
        all on-curve and off-curve points"), rather than trusting the
        `glyf` header's own xMin/yMin/xMax/yMax fields -- those exist
        for simple glyphs, but scanning the (already fully assembled,
        post-transform) point list works uniformly for composite glyphs
        too, with no extra table reads or format-specific cases needed.
        A glyph with no points (whitespace) returns all zeros, matching
        FreeType's own convention for an empty outline's metrics.
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
    """A parsed TrueType font file -- owns the raw file bytes plus the
    handful of table offsets/global metrics this module actually
    reads. See this module's own docstring for exactly which tables
    and which parts of them.
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
    var _pixel_size: Int
    """-1 until `set_pixel_size` is called -- deliberately not a valid
    size by default, the same "no unset-size default to silently trust"
    stance this codebase's now-removed FreeType FFI binding needed for
    the same reason (confirmed via probe there that an unset size
    doesn't crash on its own, it just silently returns a small,
    wrong-looking size instead -- the same trap worth guarding against
    here, not a new concern this module introduces).
    """

    def __init__(out self, path: String) raises:
        var f = open(path, "r")
        var content = f.read_bytes()
        f.close()
        var data = List[UInt8](capacity=len(content))
        for b in content:
            data.append(b)

        if len(data) < 12:
            raise Error("ttf: file too short to be a TrueType font")

        var sfnt_version = _u32(data, 0)
        if sfnt_version == _SFNT_VERSION_OTTO:
            raise Error(
                "ttf: CFF/OpenType-CFF font ('OTTO') -- only TrueType 'glyf' outlines are supported"
            )
        if sfnt_version != _SFNT_VERSION_TRUETYPE and sfnt_version != _SFNT_VERSION_TRUETYPE_APPLE:
            raise Error(String("ttf: unrecognized sfntVersion 0x", hex(sfnt_version)))

        var num_tables = _u16(data, 4)

        var cmap_off = -1
        var glyf_off = -1
        var loca_off = -1
        var head_off = -1
        var maxp_off = -1
        var hhea_off = -1
        var hmtx_off = -1

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
            pos += 16

        if head_off == -1 or maxp_off == -1 or hhea_off == -1 or hmtx_off == -1 or cmap_off == -1:
            raise Error("ttf: missing a required table (head/maxp/hhea/hmtx/cmap)")
        if glyf_off == -1 or loca_off == -1:
            raise Error("ttf: no glyf/loca table -- likely a CFF/OpenType-CFF font, not supported")

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
        self._pixel_size = -1
        self.data = data^

    def set_pixel_size(mut self, pixel_size: Int):
        """Set this face's own active rasterization size, in pixels --
        must be called before `scale()`/any pixel-space metric or
        outline query.
        """
        self._pixel_size = pixel_size

    def scale(self) raises -> Float64:
        """Raw font-design-units -> pixels conversion factor at this
        face's own active pixel size (`pixel_size / units_per_em`) --
        raises if `set_pixel_size` was never called, the same "don't
        silently trust an unset size" stance this codebase's
        now-removed FreeType FFI binding took for the same reason.
        """
        if self._pixel_size < 0:
            raise Error(
                "ttf: no active pixel size on this TTFFace -- call set_pixel_size()"
                " before measuring or loading glyphs"
            )
        return Float64(self._pixel_size) / Float64(self.units_per_em)

    def advance_width(self, glyph_index: Int) raises -> Int:
        """`hmtx`'s own "if fewer hMetrics entries than glyphs, the
        last entry's advance width repeats for every remaining glyph"
        rule (spec's own explicit optimization for monospace/large
        fonts) -- not a simplification made here.
        """
        var index = glyph_index if glyph_index < self.num_h_metrics else self.num_h_metrics - 1
        return _u16(self.data, self._hmtx_offset + index * 4)

    def glyph_index_for_codepoint(self, codepoint: Int) raises -> Int:
        """Look up `codepoint` in this font's own `cmap` table,
        preferring a full-Unicode format 12 subtable (covers
        supplementary planes -- emoji, some CJK) over a
        BMP-only format 4 one, matching real encoding-record
        priority real text stacks already use (see this module's own
        docstring / OpenType `cmap` spec's own "Windows platform"
        section). Returns 0 (".notdef") if no installed subtable maps
        this codepoint, the same "not found" convention `cmap` itself
        defines.
        """
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
            # over anything else -- matches the actual priority DejaVu
            # Sans's own cmap table exposes for exactly this reason
            # (confirmed via probe, not assumed): platform 0/encoding 4
            # and platform 3/encoding 10 both point at its one format-12
            # subtable, which is the superset of what its format-4
            # subtable covers.
            var is_unicode_platform = platform_id == 0 or (platform_id == 3 and (encoding_id == 1 or encoding_id == 10))
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

    def _lookup_cmap_format4(self, subtable_offset: Int, codepoint: Int) raises -> Int:
        if codepoint > 0xFFFF:
            return 0  # format 4 is BMP-only by definition
        var seg_count_x2 = _u16(self.data, subtable_offset + 6)
        var seg_count = seg_count_x2 // 2
        var end_code_off = subtable_offset + 14
        var start_code_off = end_code_off + seg_count * 2 + 2  # +2 skips reservedPad
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
                    # the font file" -- OpenType spec's own words,
                    # translated directly: glyphId = *(idRangeOffset[i]/2
                    # + (c - startCode[i]) + &idRangeOffset[i]).
                    var glyph_addr = id_range_offset_off + i * 2 + range_offset + (codepoint - start_code) * 2
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

    def _lookup_cmap_format12(self, subtable_offset: Int, codepoint: Int) raises -> Int:
        var num_groups = _u32(self.data, subtable_offset + 12)
        var groups_off = subtable_offset + 16
        # Linear scan -- groups are sorted per spec, so a binary search
        # would be faster, but correctness first: num_groups is small
        # (tens, not thousands) for every real font checked so far.
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
            var end = _u16(self.data, self._loca_offset + (glyph_index + 1) * 2) * 2
            return (start, end)
        else:
            var start = _u32(self.data, self._loca_offset + glyph_index * 4)
            var end = _u32(self.data, self._loca_offset + (glyph_index + 1) * 4)
            return (start, end)

    def glyph_outline(self, glyph_index: Int) raises -> RawGlyphOutline:
        return self._glyph_outline_impl(glyph_index, 0)

    def _glyph_outline_impl(self, glyph_index: Int, depth: Int) raises -> RawGlyphOutline:
        if depth > 8:
            raise Error("ttf: composite glyph nesting too deep (possible cycle)")
        if glyph_index < 0 or glyph_index >= self.num_glyphs:
            raise Error(String("ttf: glyph index ", glyph_index, " out of range"))

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
        self, glyph_start: Int, number_of_contours: Int, mut outline: RawGlyphOutline
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
        pos += 2 + instruction_length  # skip instructions -- no hinting, see module docstring

        # Flags: packed with a repeat-count byte -- decode into one
        # flag byte per point (REPEAT_FLAG, mask 0x08) before reading
        # any coordinates, matching the spec's own required order
        # (flags array fully precedes both coordinate arrays).
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
            elif not (f & 0x10):  # not short, not "same as previous" -> signed 16-bit delta
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

    def _parse_composite_glyph(self, glyph_start: Int, depth: Int, mut outline: RawGlyphOutline) raises:
        var pos = glyph_start + 10
        while True:
            var flags = _u16(self.data, pos)
            var child_index = _u16(self.data, pos + 2)
            pos += 4

            if not (flags & 0x0002):  # ARGS_ARE_XY_VALUES not set
                raise Error("ttf: composite glyph point-matching mode is not supported")

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
                # -- OpenType spec's own component-transform formula,
                # translated directly. UNSCALED_COMPONENT_OFFSET is the
                # documented Microsoft/Apple default (used whenever
                # neither offset flag is explicitly set, which is every
                # real font checked so far): the arg1/arg2 offset is in
                # the *parent's* coordinate system, added after scaling,
                # not scaled itself.
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
    outline: RawGlyphOutline, first: Int, last: Int, mut path: Path, pen_x: Float64, pen_y: Float64, scale: Float64
) raises:
    """Same algorithm this codebase's now-removed FreeType FFI binding
    used (itself a direct translation of FreeType's own
    `FT_Outline_Decompose`), adapted to this module's plain-`List`-based
    `RawGlyphOutline` instead of FreeType's pointer-based `FT_Outline`
    -- and simplified accordingly: `glyf` outlines are always quadratic
    (on-curve/off-curve only), never cubic, so the CUBIC branch that
    algorithm needs (FreeType's outline API is format-agnostic; it can
    hand back cubic control points for CFF-outline fonts) simply never
    applies to native TrueType parsing and is omitted, not forgotten.
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

    path.move_to(_native_px(pen_x, v_start_x, scale), _native_py(pen_y, v_start_y, scale))

    var closed = False

    while point_idx < limit and not closed:
        point_idx += 1
        var px_ = outline.points_x[point_idx]
        var py_ = outline.points_y[point_idx]
        var on = outline.on_curve[point_idx]

        if on:
            path.line_to(_native_px(pen_x, px_, scale), _native_py(pen_y, py_, scale))
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
        path.line_to(_native_px(pen_x, v_start_x, scale), _native_py(pen_y, v_start_y, scale))
    path.close()


def outline_to_path(outline: RawGlyphOutline, pen_x: Float64, pen_y: Float64, scale: Float64) raises -> Path:
    """One glyph's full outline (all contours) as a `Path`, positioned
    so its own local (0, 0) lands at (pen_x, pen_y) -- same convention
    `glyph_outline.mojo`'s own `glyph_path` uses.
    `scale` converts raw font-design-units (this font's own
    `units_per_em` grid) to pixels -- typically `pixel_size /
    face.units_per_em`.
    """
    var path = Path()
    var last = -1
    for n in range(len(outline.contour_ends)):
        var first = last + 1
        last = outline.contour_ends[n]
        _decompose_contour_native(outline, first, last, path, pen_x, pen_y, scale)
    return path^
