"""Font embedding for `PdfCanvas`: the glyphs a document used, the
font program carrying them, and the tables a PDF viewer needs to
place and extract them.

A font goes into the file as a composite (`Type0`) font with the
`Identity-H` encoding, so a glyph index is its own two-byte code and
no cmap has to be re-encoded: the text operators carry the glyph
indices the layout already chose (`canvas.text.render`'s shaping, with
its ligatures and kerning), and the viewer draws exactly those. A
`ToUnicode` CMap maps each used glyph back to the character it stood
for, which is what makes the text selectable, searchable and
copyable.

A TrueType (`glyf`) font is subset: the file keeps the tables a
renderer reads outlines from -- `head`, `hhea`, `maxp`, `hmtx`,
`loca`, `glyf`, and the hinting tables `cvt `, `fpgm`, `prep` when
present -- and every unused glyph becomes an empty entry, with the
components of a used composite glyph marked used with it. Glyph
indices are unchanged, so `CIDToGIDMap` stays `/Identity`. A
CFF-flavored OpenType font is embedded whole (`FontFile3`, subtype
`OpenType`); subsetting a CFF program is a separate job.
"""

from std.memory import ArcPointer

from canvas.text.ttf import TTFFace


def _u16(data: List[UInt8], pos: Int) -> Int:
    return (Int(data[pos]) << 8) | Int(data[pos + 1])


def _i16(data: List[UInt8], pos: Int) -> Int:
    var v = _u16(data, pos)
    return v - 65536 if v >= 32768 else v


def _u32(data: List[UInt8], pos: Int) -> Int:
    return (
        (Int(data[pos]) << 24)
        | (Int(data[pos + 1]) << 16)
        | (Int(data[pos + 2]) << 8)
        | Int(data[pos + 3])
    )


def _put_u16(mut out: List[UInt8], v: Int):
    out.append(UInt8((v >> 8) & 0xFF))
    out.append(UInt8(v & 0xFF))


def _put_u32(mut out: List[UInt8], v: Int):
    out.append(UInt8((v >> 24) & 0xFF))
    out.append(UInt8((v >> 16) & 0xFF))
    out.append(UInt8((v >> 8) & 0xFF))
    out.append(UInt8(v & 0xFF))


def _table(data: List[UInt8], tag: String) -> Tuple[Int, Int]:
    """(offset, length) of table `tag` in the font, or (-1, 0)."""
    if len(data) < 12:
        return (-1, 0)
    var num_tables = _u16(data, 4)
    for i in range(num_tables):
        var rec = 12 + 16 * i
        if rec + 16 > len(data):
            break
        var t = String()
        for k in range(4):
            t += chr(Int(data[rec + k]))
        if t == tag:
            return (_u32(data, rec + 8), _u32(data, rec + 12))
    return (-1, 0)


def _checksum(data: List[UInt8], start: Int, length: Int) -> Int:
    var sum = 0
    var i = 0
    while i < length:
        var word = 0
        for k in range(4):
            var b = 0
            if i + k < length:
                b = Int(data[start + i + k])
            word = (word << 8) | b
        sum = (sum + word) & 0xFFFFFFFF
        i += 4
    return sum


def _hex4(v: Int) -> String:
    var digits = "0123456789ABCDEF"
    var out = String()
    for shift in [12, 8, 4, 0]:
        out += digits[byte = (v >> shift) & 15 : ((v >> shift) & 15) + 1]
    return out


struct _EmbeddedFont(Movable):
    """One font the document draws with: the parsed face, which of its
    glyphs the text used and the character each stood for, and its
    resource index (`/F{index + 1}`)."""

    var path: String
    var face: ArcPointer[TTFFace]
    var used: List[Bool]
    # Per glyph, the UTF-16 hex of the characters it stood for, or ""
    # when unknown.
    var unicode: List[String]
    var index: Int

    def __init__(out self, path: String, face: ArcPointer[TTFFace], index: Int):
        self.path = path
        self.face = face
        var n = face[].num_glyphs
        self.used = List[Bool](length=n, fill=False)
        self.unicode = List[String](length=n, fill="")
        self.index = index
        # Glyph 0 (.notdef) is always present.
        if n > 0:
            self.used[0] = True

    def mark(mut self, gid: Int, chars: String):
        """Record that `gid` was drawn for the characters `chars`."""
        if gid < 0 or gid >= len(self.used):
            return
        self.used[gid] = True
        if self.unicode[gid] == "" and chars != "":
            var target = String()
            for cp in chars.codepoints():
                var c = Int(cp)
                if c > 0xFFFF:
                    var v = c - 0x10000
                    target += _hex4(0xD800 + (v >> 10)) + _hex4(
                        0xDC00 + (v & 0x3FF)
                    )
                else:
                    target += _hex4(c)
            self.unicode[gid] = target

    def is_cff(self) -> Bool:
        return self.face[]._has_cff

    def units_per_em(self) -> Int:
        return self.face[].units_per_em

    def advance_1000(self, gid: Int) -> Int:
        """`gid`'s advance width in 1000ths of the em."""
        ref face = self.face[]
        var n = face.num_h_metrics
        if n <= 0:
            return 0
        var i = gid if gid < n else n - 1
        var raw = _u16(face.data, face._hmtx_offset + 4 * i)
        return Int(Float64(raw) * 1000.0 / Float64(face.units_per_em) + 0.5)

    def base_name(self) -> String:
        """A PostScript-style name from the file's stem, with a subset
        tag: `AAAAAA+DejaVuSans`."""
        var stem = self.path
        var slash = stem.rfind("/")
        if slash >= 0:
            var tail = String(self.path[byte = slash + 1 :])
            stem = tail
        var dot = stem.rfind(".")
        if dot > 0:
            var head = String(stem[byte=:dot])
            stem = head
        var clean = String()
        for cp in stem.codepoints():
            var c = Int(cp)
            var ok = (
                (c >= 48 and c <= 57)
                or (c >= 65 and c <= 90)
                or (c >= 97 and c <= 122)
                or c == 45
            )
            if ok:
                clean += chr(c)
        if clean == "":
            clean = "Font"
        return "AAAAAA+" + clean

    def bbox_1000(self) -> Tuple[Int, Int, Int, Int]:
        """The font bounding box from `head`, in 1000ths of the em."""
        ref face = self.face[]
        var head = _table(face.data, "head")
        if head[0] < 0:
            return (0, -200, 1000, 800)
        var scale = 1000.0 / Float64(face.units_per_em)
        var o = head[0]
        return (
            Int(Float64(_i16(face.data, o + 36)) * scale),
            Int(Float64(_i16(face.data, o + 38)) * scale),
            Int(Float64(_i16(face.data, o + 40)) * scale),
            Int(Float64(_i16(face.data, o + 42)) * scale),
        )

    def ascent_1000(self) -> Int:
        return Int(
            Float64(self.face[].ascender)
            * 1000.0
            / Float64(self.face[].units_per_em)
        )

    def descent_1000(self) -> Int:
        return Int(
            Float64(self.face[].descender)
            * 1000.0
            / Float64(self.face[].units_per_em)
        )

    def widths_array(self) -> String:
        """The `/W` array: each used glyph's width, as `gid [w]`
        entries."""
        var out = String("[")
        for gid in range(len(self.used)):
            if self.used[gid]:
                out += (
                    String(gid) + " [" + String(self.advance_1000(gid)) + "] "
                )
        out += "]"
        return out

    def to_unicode(self) -> String:
        """The `ToUnicode` CMap: a `bfchar` line per used glyph with
        known characters -- several for a ligature -- code points past
        the BMP as surrogate pairs."""
        var entries = List[String]()
        for gid in range(len(self.used)):
            if self.used[gid] and self.unicode[gid] != "":
                entries.append(
                    "<" + _hex4(gid) + "> <" + self.unicode[gid] + ">\n"
                )
        var out = String(
            "/CIDInit /ProcSet findresource begin\n12 dict"
            " begin\nbegincmap\n/CIDSystemInfo << /Registry (Adobe) /Ordering"
            " (UCS) /Supplement 0 >> def\n/CMapName /Adobe-Identity-UCS"
            " def\n/CMapType 2 def\n1 begincodespacerange\n<0000>"
            " <FFFF>\nendcodespacerange\n"
        )
        var i = 0
        while i < len(entries):
            var n = min(100, len(entries) - i)
            out += String(n) + " beginbfchar\n"
            for k in range(i, i + n):
                out += entries[k]
            out += "endbfchar\n"
            i += n
        out += (
            "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"
        )
        return out

    def font_file(mut self) -> List[UInt8]:
        """The font program to embed: the whole file for CFF, the
        `glyf` subset otherwise."""
        if self.is_cff():
            return self.face[].data.copy()
        return _subset_truetype(self.face[], self.used)


def _glyph_range(face: TTFFace, gid: Int) -> Tuple[Int, Int]:
    """(offset, length) of `gid`'s data in `glyf`."""
    var loca = face._loca_offset
    var start = 0
    var end = 0
    if face.index_to_loc_format == 0:
        start = _u16(face.data, loca + 2 * gid) * 2
        end = _u16(face.data, loca + 2 * gid + 2) * 2
    else:
        start = _u32(face.data, loca + 4 * gid)
        end = _u32(face.data, loca + 4 * gid + 4)
    return (face._glyf_offset + start, end - start)


def _mark_components(face: TTFFace, mut used: List[Bool]):
    """Every component of a used composite glyph is used too, to any
    depth; a pass that marks nothing new ends it."""
    var changed = True
    while changed:
        changed = False
        for gid in range(len(used)):
            if not used[gid]:
                continue
            var r = _glyph_range(face, gid)
            if r[1] < 10:
                continue
            var contours = _i16(face.data, r[0])
            if contours >= 0:
                continue
            var p = r[0] + 10
            while p + 4 <= r[0] + r[1]:
                var flags = _u16(face.data, p)
                var component = _u16(face.data, p + 2)
                p += 4
                if component < len(used) and not used[component]:
                    used[component] = True
                    changed = True
                p += 4 if (flags & 0x0001) != 0 else 2
                if (flags & 0x0008) != 0:
                    p += 2
                elif (flags & 0x0040) != 0:
                    p += 4
                elif (flags & 0x0080) != 0:
                    p += 8
                if (flags & 0x0020) == 0:
                    break


def _subset_truetype(face: TTFFace, mut used: List[Bool]) -> List[UInt8]:
    """A TrueType file holding only the used glyphs' outlines: the
    renderer's tables copied, `glyf` rebuilt from the used glyphs,
    `loca` rebuilt in the long format to match, unused glyphs empty."""
    _mark_components(face, used)
    ref data = face.data
    var n = face.num_glyphs

    var glyf = List[UInt8]()
    var loca = List[UInt8]()
    for gid in range(n):
        _put_u32(loca, len(glyf))
        if used[gid]:
            var r = _glyph_range(face, gid)
            for i in range(r[1]):
                glyf.append(data[r[0] + i])
            while len(glyf) % 4 != 0:
                glyf.append(0)
    _put_u32(loca, len(glyf))

    var tags = List[String]()
    var bodies = List[List[UInt8]]()
    for tag in ["cvt ", "fpgm", "head", "hhea", "hmtx", "maxp", "prep"]:
        var t = _table(data, String(tag))
        if t[0] < 0:
            continue
        var body = List[UInt8](capacity=t[1])
        for i in range(t[1]):
            body.append(data[t[0] + i])
        if String(tag) == "head" and len(body) >= 54:
            # Long loca offsets, and no checksum adjustment to be wrong.
            body[50] = 0
            body[51] = 1
            body[8] = 0
            body[9] = 0
            body[10] = 0
            body[11] = 0
        tags.append(String(tag))
        bodies.append(body^)
    tags.append("glyf")
    bodies.append(glyf^)
    tags.append("loca")
    bodies.append(loca^)

    # Directory entries are sorted by tag; the search fields are the
    # spec's derivations from the table count.
    var order = List[Int](capacity=len(tags))
    for i in range(len(tags)):
        order.append(i)
    for i in range(1, len(order)):
        var j = i
        while j > 0 and tags[order[j - 1]] > tags[order[j]]:
            var t = order[j - 1]
            order[j - 1] = order[j]
            order[j] = t
            j -= 1

    var count = len(tags)
    var entry_selector = 0
    while (1 << (entry_selector + 1)) <= count:
        entry_selector += 1
    var search_range = (1 << entry_selector) * 16
    var out = List[UInt8]()
    _put_u32(out, 0x00010000)
    _put_u16(out, count)
    _put_u16(out, search_range)
    _put_u16(out, entry_selector)
    _put_u16(out, count * 16 - search_range)
    var offset = 12 + 16 * count
    var offsets = List[Int]()
    for k in range(count):
        var i = order[k]
        offsets.append(offset)
        offset += (len(bodies[i]) + 3) // 4 * 4
    for k in range(count):
        var i = order[k]
        for c in tags[i].codepoints():
            out.append(UInt8(Int(c)))
        _put_u32(out, _checksum(bodies[i], 0, len(bodies[i])))
        _put_u32(out, offsets[k])
        _put_u32(out, len(bodies[i]))
    for k in range(count):
        var i = order[k]
        out.extend(bodies[i].copy())
        while len(out) % 4 != 0:
            out.append(0)
    return out^
