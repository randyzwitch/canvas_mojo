"""CFF (Compact Font Format) outlines, for OpenType-CFF (`OTTO`) fonts:
the `CFF ` table's INDEX and DICT structures, and a Type 2 charstring
interpreter that turns a glyph's program into a `RawGlyphOutline` of
cubic contours. Layout and operator semantics follow Adobe Technical
Notes #5176 (CFF) and #5177 (Type 2 charstrings).

Scope:

- **Type 2 charstrings only.** CFF version 1 with Type 2 programs,
  which is every OpenType-CFF font; a CharstringType of 1 raises.
  `CFF2` (variable CFF) is a different table and is not read.
- **CID-keyed fonts** (`ROS` in the Top DICT) are supported: each
  glyph's Private DICT and local subroutines come from `FDArray`
  through `FDSelect` (formats 0 and 3).
- **Every path operator**, the four flex operators, subroutine calls
  with the size-dependent bias, and the deprecated `endchar` accent
  composition (`seac`) via the charset and Standard Encoding. Hint
  operators are counted so `hintmask` bytes are skipped and otherwise
  ignored, as `glyf` hinting is. The arithmetic operators a Type 1
  conversion can leave behind (`abs`, `add`, `sub`, `div`, `neg`,
  `mul`, `sqrt`, `drop`, `dup`, `exch`, `put`, `get`) are honored;
  the rest raise.
- **Coordinates round to whole font units.** Charstrings can carry
  fractions (16.16 numbers, `div`); `RawGlyphOutline` holds integer
  units, so a point rounds to its nearest unit, 1/1000 em in nearly
  every CFF font. `FontMatrix` is not read: `head`'s unitsPerEm is
  taken as the charstring unit, which holds for every font whose
  matrix is the default 1/1000.
"""

from std.math import sqrt

from canvas.geometry import round_to_int
from canvas.text.ttf import RawGlyphOutline, _u8, _u16, _u32


# Subroutine index bias, Type 2 charstrings section 4.7.
def _bias(count: Int) -> Int:
    if count < 1240:
        return 107
    if count < 33900:
        return 1131
    return 32768


# Standard Encoding code -> Standard String id, for `seac`. Codes 32
# through 126 are the contiguous run SIDs 1 through 95; the rest of
# the encoding (CFF appendix B) is sparse and listed by hand.
def _standard_encoding_sid(code: Int) -> Int:
    if code >= 32 and code <= 126:
        return code - 31
    var high: List[Int] = [
        161,
        162,
        163,
        164,
        165,
        166,
        167,
        168,
        169,
        170,
        171,
        172,
        173,
        174,
        175,
        177,
        178,
        179,
        180,
        182,
        183,
        184,
        185,
        186,
        187,
        188,
        189,
        191,
        193,
        194,
        195,
        196,
        197,
        198,
        199,
        200,
        202,
        203,
        205,
        206,
        207,
        208,
        225,
        227,
        232,
        233,
        234,
        235,
        241,
        245,
        248,
        249,
        250,
        251,
    ]
    for i in range(len(high)):
        if high[i] == code:
            return 96 + i
    return 0


struct _CffFont(Movable):
    """The parts of a `CFF ` table a glyph needs: where each charstring
    and subroutine starts (absolute file offsets, `count + 1` entries
    so entry i's program is bytes [i, i + 1)), the charset for `seac`,
    and for a CID-keyed font the per-glyph choice of local
    subroutines.
    """

    var charstrings: List[Int]
    var gsubrs: List[Int]
    var lsubrs: List[Int]
    var is_cid: Bool
    var fd_select: List[Int]
    var fd_subrs: List[List[Int]]
    var charset: List[Int]
    var num_glyphs: Int

    def __init__(out self):
        self.charstrings = List[Int]()
        self.gsubrs = List[Int]()
        self.lsubrs = List[Int]()
        self.is_cid = False
        self.fd_select = List[Int]()
        self.fd_subrs = List[List[Int]]()
        self.charset = List[Int]()
        self.num_glyphs = 0

    def local_subrs(self, glyph_index: Int) -> List[Int]:
        """The local subroutine offsets `glyph_index`'s program calls
        into: the font's own for a plain font, its FD's for a CID font.
        """
        if not self.is_cid:
            return self.lsubrs.copy()
        if glyph_index < len(self.fd_select):
            var fd = self.fd_select[glyph_index]
            if fd < len(self.fd_subrs):
                return self.fd_subrs[fd].copy()
        return List[Int]()

    def gid_for_sid(self, sid: Int) -> Int:
        """The glyph whose charset entry is `sid`, 0 if none."""
        for gid in range(len(self.charset)):
            if self.charset[gid] == sid:
                return gid
        return 0


def _read_index(data: List[UInt8], pos: Int) raises -> Tuple[List[Int], Int]:
    """A CFF INDEX at `pos`: the absolute offset of each item plus one
    past the last, and the position after the INDEX. An empty INDEX is
    two bytes.
    """
    var count = _u16(data, pos)
    var offsets = List[Int]()
    if count == 0:
        return (offsets^, pos + 2)
    var off_size = _u8(data, pos + 2)
    if off_size < 1 or off_size > 4:
        raise Error(String("cff: bad INDEX offSize ", off_size))
    var array = pos + 3
    # Offsets are 1-based from the byte before the data.
    var base = array + (count + 1) * off_size - 1
    for i in range(count + 1):
        var v = 0
        for k in range(off_size):
            v = (v << 8) | _u8(data, array + i * off_size + k)
        offsets.append(base + v)
    return (offsets^, offsets[count])


def _dict_operands(
    data: List[UInt8], start: Int, end: Int, op: Int
) raises -> List[Float64]:
    """The operands of DICT operator `op` (an escaped operator is
    1200 + its second byte) in the DICT at [start, end), empty if the
    operator is absent.
    """
    var operands = List[Float64]()
    var i = start
    while i < end:
        var b0 = _u8(data, i)
        if b0 <= 21:
            var key = b0
            i += 1
            if b0 == 12:
                key = 1200 + _u8(data, i)
                i += 1
            if key == op:
                return operands^
            operands = List[Float64]()
        elif b0 == 28:
            var v = _u16(data, i + 1)
            if v >= 32768:
                v -= 65536
            operands.append(Float64(v))
            i += 3
        elif b0 == 29:
            var v = _u32(data, i + 1)
            if v >= 2147483648:
                v -= 4294967296
            operands.append(Float64(v))
            i += 5
        elif b0 == 30:
            # A real number as packed nibbles, ended by 0xF.
            var text = String()
            i += 1
            var done = False
            while not done:
                var byte = _u8(data, i)
                i += 1
                for half in range(2):
                    var nib = (byte >> 4) if half == 0 else (byte & 15)
                    if nib <= 9:
                        text += String(nib)
                    elif nib == 10:
                        text += "."
                    elif nib == 11:
                        text += "E"
                    elif nib == 12:
                        text += "E-"
                    elif nib == 14:
                        text += "-"
                    elif nib == 15:
                        done = True
                        break
            operands.append(_parse_real(text))
        elif b0 >= 32 and b0 <= 246:
            operands.append(Float64(b0 - 139))
            i += 1
        elif b0 >= 247 and b0 <= 250:
            operands.append(Float64((b0 - 247) * 256 + _u8(data, i + 1) + 108))
            i += 2
        elif b0 >= 251 and b0 <= 254:
            operands.append(Float64(-(b0 - 251) * 256 - _u8(data, i + 1) - 108))
            i += 2
        else:
            raise Error(String("cff: reserved DICT byte ", b0))
    return List[Float64]()


def _parse_real(text: String) raises -> Float64:
    """A DICT real from its nibble text: digits, one optional point,
    an optional exponent. Parsed by hand; the values here are font
    matrices and the like, not precision-critical.
    """
    var mantissa = 0.0
    var scale = 1.0
    var seen_point = False
    var negative = False
    var exponent = 0
    var exp_negative = False
    var in_exponent = False
    for cp in text.codepoints():
        var c = Int(cp)
        if in_exponent:
            if c == 45:
                exp_negative = True
            elif c >= 48 and c <= 57:
                exponent = exponent * 10 + (c - 48)
            continue
        if c == 45:
            negative = True
        elif c == 46:
            seen_point = True
        elif c == 69:
            in_exponent = True
        elif c >= 48 and c <= 57:
            mantissa = mantissa * 10.0 + Float64(c - 48)
            if seen_point:
                scale *= 10.0
    var value = mantissa / scale
    for _ in range(exponent):
        value = value / 10.0 if exp_negative else value * 10.0
    return -value if negative else value


def _read_private_subrs(
    data: List[UInt8], private: List[Float64]
) raises -> List[Int]:
    """The local subroutine INDEX a Private DICT points at, from the
    Top DICT's `Private` operands (size, offset): empty when the
    Private DICT has no `Subrs`.
    """
    if len(private) < 2:
        return List[Int]()
    var size = Int(private[0])
    var offset = Int(private[1])
    var subrs = _dict_operands(data, offset, offset + size, 19)
    if len(subrs) == 0:
        return List[Int]()
    var index = _read_index(data, offset + Int(subrs[0]))
    return index[0].copy()


def _parse_cff(
    data: List[UInt8], base: Int, num_glyphs: Int
) raises -> _CffFont:
    """Read the `CFF ` table at absolute offset `base`: header, the
    four top-level INDEXes, the first font's Top DICT, its Private
    DICT and local subrs, its charset, and for a CID font the FDArray
    and FDSelect. Offsets inside the table are relative to `base`.
    """
    var hdr_size = _u8(data, base + 2)
    var pos = base + hdr_size
    var names = _read_index(data, pos)
    pos = names[1]
    var tops = _read_index(data, pos)
    pos = tops[1]
    var strings = _read_index(data, pos)
    pos = strings[1]
    var gsubrs = _read_index(data, pos)
    if len(tops[0]) < 2:
        raise Error("cff: no Top DICT")
    var top_start = tops[0][0]
    var top_end = tops[0][1]

    var out = _CffFont()
    out.gsubrs = gsubrs[0].copy()
    out.num_glyphs = num_glyphs

    var cs_type = _dict_operands(data, top_start, top_end, 1206)
    if len(cs_type) > 0 and Int(cs_type[0]) != 2:
        raise Error(
            String(
                "cff: CharstringType ",
                Int(cs_type[0]),
                " -- only Type 2 charstrings are supported",
            )
        )
    var cs = _dict_operands(data, top_start, top_end, 17)
    if len(cs) == 0:
        raise Error("cff: Top DICT has no CharStrings")
    var cs_index = _read_index(data, base + Int(cs[0]))
    out.charstrings = cs_index[0].copy()
    if len(out.charstrings) < num_glyphs + 1:
        out.num_glyphs = max(0, len(out.charstrings) - 1)

    # Private DICT and its local subrs. Offsets in the Private
    # operands are relative to the table; Subrs is relative to the
    # Private DICT itself.
    var private = _dict_operands(data, top_start, top_end, 18)
    if len(private) >= 2:
        var shifted: List[Float64] = [private[0], private[1] + Float64(base)]
        out.lsubrs = _read_private_subrs(data, shifted)

    # Charset: the SID (or CID) of every glyph, for seac.
    var charset = _dict_operands(data, top_start, top_end, 15)
    var charset_off = Int(charset[0]) if len(charset) > 0 else 0
    out.charset = _read_charset(data, base, charset_off, out.num_glyphs)

    var ros = _dict_operands(data, top_start, top_end, 1230)
    if len(ros) > 0:
        out.is_cid = True
        var fdarray = _dict_operands(data, top_start, top_end, 1236)
        var fdselect = _dict_operands(data, top_start, top_end, 1237)
        if len(fdarray) == 0 or len(fdselect) == 0:
            raise Error("cff: CID font without FDArray/FDSelect")
        var fd_index = _read_index(data, base + Int(fdarray[0]))
        var fds = fd_index[0].copy()
        for i in range(len(fds) - 1):
            var fd_private = _dict_operands(data, fds[i], fds[i + 1], 18)
            if len(fd_private) >= 2:
                var shifted: List[Float64] = [
                    fd_private[0],
                    fd_private[1] + Float64(base),
                ]
                out.fd_subrs.append(_read_private_subrs(data, shifted))
            else:
                out.fd_subrs.append(List[Int]())
        out.fd_select = _read_fd_select(
            data, base + Int(fdselect[0]), out.num_glyphs
        )
    return out^


def _read_charset(
    data: List[UInt8], base: Int, offset: Int, num_glyphs: Int
) raises -> List[Int]:
    """Every glyph's SID. Offsets 0, 1 and 2 name the predefined
    charsets; ISOAdobe (0) is the identity over the standard strings,
    and the two Expert charsets are treated the same way, since only
    `seac` reads this and Expert fonts do not use it.
    """
    var sids = List[Int](capacity=num_glyphs)
    if offset <= 2:
        for gid in range(num_glyphs):
            sids.append(gid)
        return sids^
    var pos = base + offset
    var fmt = _u8(data, pos)
    pos += 1
    sids.append(0)  # .notdef
    if fmt == 0:
        while len(sids) < num_glyphs:
            sids.append(_u16(data, pos))
            pos += 2
    elif fmt == 1 or fmt == 2:
        while len(sids) < num_glyphs:
            var first = _u16(data, pos)
            var left: Int
            if fmt == 1:
                left = _u8(data, pos + 2)
                pos += 3
            else:
                left = _u16(data, pos + 2)
                pos += 4
            for k in range(left + 1):
                if len(sids) >= num_glyphs:
                    break
                sids.append(first + k)
    else:
        raise Error(String("cff: charset format ", fmt))
    return sids^


def _read_fd_select(
    data: List[UInt8], pos: Int, num_glyphs: Int
) raises -> List[Int]:
    """Each glyph's Font DICT index, from an FDSelect of format 0 (one
    byte per glyph) or 3 (ranges)."""
    var out = List[Int](length=num_glyphs, fill=0)
    var fmt = _u8(data, pos)
    if fmt == 0:
        for gid in range(num_glyphs):
            out[gid] = _u8(data, pos + 1 + gid)
    elif fmt == 3:
        var n_ranges = _u16(data, pos + 1)
        var p = pos + 3
        var sentinel = _u16(data, pos + 3 + n_ranges * 3)
        for i in range(n_ranges):
            var first = _u16(data, p)
            var fd = _u8(data, p + 2)
            var next_first = _u16(data, p + 3) if i + 1 < n_ranges else sentinel
            for gid in range(first, min(next_first, num_glyphs)):
                out[gid] = fd
            p += 3
    else:
        raise Error(String("cff: FDSelect format ", fmt))
    return out^


struct _Type2State(Movable):
    """The interpreter's state across a program and the subroutines
    it calls: the operand stack, the transient array, the current
    point, stem count (for the width of a hintmask), and the outline
    being built.
    """

    var stack: List[Float64]
    var trans: List[Float64]
    var x: Float64
    var y: Float64
    var nstems: Int
    var width_parsed: Bool
    var open: Bool
    var done: Bool
    var outline: RawGlyphOutline

    def __init__(out self):
        self.stack = List[Float64]()
        self.trans = List[Float64](length=32, fill=0.0)
        self.x = 0.0
        self.y = 0.0
        self.nstems = 0
        self.width_parsed = False
        self.open = False
        self.done = False
        self.outline = RawGlyphOutline()
        self.outline.cubic = True

    def _add(mut self, x: Float64, y: Float64, on: Bool):
        self.outline.points_x.append(round_to_int(x))
        self.outline.points_y.append(round_to_int(y))
        self.outline.on_curve.append(on)

    def close_contour(mut self):
        if self.open:
            self.outline.contour_ends.append(len(self.outline.points_x) - 1)
            self.open = False

    def move_to(mut self, dx: Float64, dy: Float64):
        self.close_contour()
        self.x += dx
        self.y += dy
        self._add(self.x, self.y, True)
        self.open = True

    def line_to(mut self, dx: Float64, dy: Float64):
        self.x += dx
        self.y += dy
        self._add(self.x, self.y, True)

    def curve_to(
        mut self,
        dx1: Float64,
        dy1: Float64,
        dx2: Float64,
        dy2: Float64,
        dx3: Float64,
        dy3: Float64,
    ):
        var c1x = self.x + dx1
        var c1y = self.y + dy1
        var c2x = c1x + dx2
        var c2y = c1y + dy2
        self.x = c2x + dx3
        self.y = c2y + dy3
        self._add(c1x, c1y, False)
        self._add(c2x, c2y, False)
        self._add(self.x, self.y, True)

    def take_width(mut self, even: Int):
        """Drop a leading width operand if this stack-clearing operator
        carries one: the stack holds `even` more operands than the
        operator takes, and the width has not been seen yet.
        """
        if not self.width_parsed:
            self.width_parsed = True
            if (
                len(self.stack) % 2
                == 1 if even
                == 2 else len(self.stack)
                > even
            ):
                _ = self.stack.pop(0)


def _run(
    data: List[UInt8],
    start: Int,
    end: Int,
    gsubrs: List[Int],
    lsubrs: List[Int],
    mut st: _Type2State,
    depth: Int,
) raises:
    """Execute the charstring bytes [start, end), calling into
    `gsubrs`/`lsubrs` as needed, until `endchar` or `return`.
    """
    if depth > 10:
        raise Error("cff: subroutine nesting too deep")
    var i = start
    while i < end and not st.done:
        var b0 = _u8(data, i)
        i += 1
        if b0 >= 32 or b0 == 28:
            # An operand.
            if b0 == 28:
                var v = _u16(data, i)
                if v >= 32768:
                    v -= 65536
                st.stack.append(Float64(v))
                i += 2
            elif b0 <= 246:
                st.stack.append(Float64(b0 - 139))
            elif b0 <= 250:
                st.stack.append(Float64((b0 - 247) * 256 + _u8(data, i) + 108))
                i += 1
            elif b0 <= 254:
                st.stack.append(Float64(-(b0 - 251) * 256 - _u8(data, i) - 108))
                i += 1
            else:
                var v = _u32(data, i)
                if v >= 2147483648:
                    v -= 4294967296
                st.stack.append(Float64(v) / 65536.0)
                i += 4
            continue

        if b0 == 1 or b0 == 3 or b0 == 18 or b0 == 23:
            # hstem vstem hstemhm vstemhm
            st.take_width(2)
            st.nstems += len(st.stack) // 2
            st.stack.clear()
        elif b0 == 19 or b0 == 20:
            # hintmask cntrmask, with an implicit vstem if operands
            # are waiting, then one mask bit per stem.
            st.take_width(2)
            st.nstems += len(st.stack) // 2
            st.stack.clear()
            i += (st.nstems + 7) // 8
        elif b0 == 21:
            st.take_width(2)
            if len(st.stack) >= 2:
                st.move_to(st.stack[0], st.stack[1])
            st.stack.clear()
        elif b0 == 22:
            st.take_width(1)
            if len(st.stack) >= 1:
                st.move_to(st.stack[0], 0.0)
            st.stack.clear()
        elif b0 == 4:
            st.take_width(1)
            if len(st.stack) >= 1:
                st.move_to(0.0, st.stack[0])
            st.stack.clear()
        elif b0 == 5:
            var k = 0
            while k + 1 < len(st.stack):
                st.line_to(st.stack[k], st.stack[k + 1])
                k += 2
            st.stack.clear()
        elif b0 == 6 or b0 == 7:
            # hlineto / vlineto: alternating, starting horizontal for 6.
            var horizontal = b0 == 6
            for k in range(len(st.stack)):
                if horizontal:
                    st.line_to(st.stack[k], 0.0)
                else:
                    st.line_to(0.0, st.stack[k])
                horizontal = not horizontal
            st.stack.clear()
        elif b0 == 8:
            var k = 0
            while k + 5 < len(st.stack):
                st.curve_to(
                    st.stack[k],
                    st.stack[k + 1],
                    st.stack[k + 2],
                    st.stack[k + 3],
                    st.stack[k + 4],
                    st.stack[k + 5],
                )
                k += 6
            st.stack.clear()
        elif b0 == 24:
            # rcurveline: curves, then one line.
            var k = 0
            while len(st.stack) - k >= 8:
                st.curve_to(
                    st.stack[k],
                    st.stack[k + 1],
                    st.stack[k + 2],
                    st.stack[k + 3],
                    st.stack[k + 4],
                    st.stack[k + 5],
                )
                k += 6
            if k + 1 < len(st.stack):
                st.line_to(st.stack[k], st.stack[k + 1])
            st.stack.clear()
        elif b0 == 25:
            # rlinecurve: lines, then one curve.
            var k = 0
            while len(st.stack) - k >= 8:
                st.line_to(st.stack[k], st.stack[k + 1])
                k += 2
            if k + 5 < len(st.stack):
                st.curve_to(
                    st.stack[k],
                    st.stack[k + 1],
                    st.stack[k + 2],
                    st.stack[k + 3],
                    st.stack[k + 4],
                    st.stack[k + 5],
                )
            st.stack.clear()
        elif b0 == 26 or b0 == 27:
            # vvcurveto / hhcurveto: an odd count leads with the other
            # axis's first delta.
            var k = 0
            var d1 = 0.0
            if len(st.stack) % 4 == 1:
                d1 = st.stack[0]
                k = 1
            while k + 3 < len(st.stack):
                if b0 == 26:
                    st.curve_to(
                        d1,
                        st.stack[k],
                        st.stack[k + 1],
                        st.stack[k + 2],
                        0.0,
                        st.stack[k + 3],
                    )
                else:
                    st.curve_to(
                        st.stack[k],
                        d1,
                        st.stack[k + 1],
                        st.stack[k + 2],
                        st.stack[k + 3],
                        0.0,
                    )
                d1 = 0.0
                k += 4
            st.stack.clear()
        elif b0 == 30 or b0 == 31:
            # vhcurveto / hvcurveto: alternating, with an optional
            # final delta on the last curve's end.
            var horizontal = b0 == 31
            var k = 0
            var n = len(st.stack)
            while k + 3 < n:
                var last = k + 8 > n
                var dlast = st.stack[k + 4] if (last and k + 4 < n) else 0.0
                if horizontal:
                    st.curve_to(
                        st.stack[k],
                        0.0,
                        st.stack[k + 1],
                        st.stack[k + 2],
                        dlast,
                        st.stack[k + 3],
                    )
                else:
                    st.curve_to(
                        0.0,
                        st.stack[k],
                        st.stack[k + 1],
                        st.stack[k + 2],
                        st.stack[k + 3],
                        dlast,
                    )
                horizontal = not horizontal
                k += 4
            st.stack.clear()
        elif b0 == 10 or b0 == 29:
            if len(st.stack) == 0:
                raise Error("cff: subroutine call with an empty stack")
            var raw = Int(st.stack.pop())
            if b0 == 10:
                _call_subr(data, lsubrs, raw, gsubrs, lsubrs, st, depth)
            else:
                _call_subr(data, gsubrs, raw, gsubrs, lsubrs, st, depth)
        elif b0 == 11:
            return
        elif b0 == 14:
            # endchar, with the width and the deprecated accent
            # composition: adx ady bchar achar.
            if not st.width_parsed:
                st.width_parsed = True
                if len(st.stack) == 1 or len(st.stack) == 5:
                    _ = st.stack.pop(0)
            st.close_contour()
            if len(st.stack) >= 4:
                st.outline.contour_ends.append(-1)  # marker, see _seac
                st.trans[0] = st.stack[len(st.stack) - 4]
                st.trans[1] = st.stack[len(st.stack) - 3]
                st.trans[2] = st.stack[len(st.stack) - 2]
                st.trans[3] = st.stack[len(st.stack) - 1]
            st.stack.clear()
            st.done = True
        elif b0 == 12:
            var b1 = _u8(data, i)
            i += 1
            _escaped(b1, st)
        else:
            raise Error(String("cff: reserved charstring operator ", b0))


def _call_subr(
    data: List[UInt8],
    subrs: List[Int],
    raw: Int,
    gsubrs: List[Int],
    lsubrs: List[Int],
    mut st: _Type2State,
    depth: Int,
) raises:
    """Run subroutine `raw + bias` of `subrs`."""
    var count = max(0, len(subrs) - 1)
    var index = raw + _bias(count)
    if index < 0 or index >= count:
        raise Error(String("cff: subroutine ", index, " out of range"))
    _run(data, subrs[index], subrs[index + 1], gsubrs, lsubrs, st, depth + 1)


def _escaped(op: Int, mut st: _Type2State) raises:
    """The two-byte operators: flex and arithmetic."""
    var n = len(st.stack)
    if op == 35:
        # flex: two curves, fd ignored.
        if n >= 13:
            st.curve_to(
                st.stack[0],
                st.stack[1],
                st.stack[2],
                st.stack[3],
                st.stack[4],
                st.stack[5],
            )
            st.curve_to(
                st.stack[6],
                st.stack[7],
                st.stack[8],
                st.stack[9],
                st.stack[10],
                st.stack[11],
            )
        st.stack.clear()
    elif op == 34:
        # hflex: dx1 dx2 dy2 dx3 dx4 dx5 dx6, back to the start y.
        if n >= 7:
            var y0 = st.y
            st.curve_to(
                st.stack[0], 0.0, st.stack[1], st.stack[2], st.stack[3], 0.0
            )
            st.curve_to(
                st.stack[4], 0.0, st.stack[5], y0 - st.y, st.stack[6], 0.0
            )
        st.stack.clear()
    elif op == 36:
        # hflex1: dx1 dy1 dx2 dy2 dx3 dx4 dx5 dy5 dx6.
        if n >= 9:
            var y0 = st.y
            st.curve_to(
                st.stack[0],
                st.stack[1],
                st.stack[2],
                st.stack[3],
                st.stack[4],
                0.0,
            )
            var dy5 = st.stack[7]
            # The last point returns to the start y: dy6 is whatever
            # closes the gap after the two control points.
            var c2y = st.y + dy5
            st.curve_to(
                st.stack[5], 0.0, st.stack[6], dy5, st.stack[8], y0 - c2y
            )
        st.stack.clear()
    elif op == 37:
        # flex1: dx1 dy1 dx2 dy2 dx3 dy3 dx4 dy4 dx5 dy5 d6; the end
        # returns to the start on the axis of lesser travel.
        if n >= 11:
            var x0 = st.x
            var y0 = st.y
            var dx = 0.0
            var dy = 0.0
            for k in range(5):
                dx += st.stack[2 * k]
                dy += st.stack[2 * k + 1]
            st.curve_to(
                st.stack[0],
                st.stack[1],
                st.stack[2],
                st.stack[3],
                st.stack[4],
                st.stack[5],
            )
            var c1x = st.x + st.stack[6]
            var c1y = st.y + st.stack[7]
            var c2x = c1x + st.stack[8]
            var c2y = c1y + st.stack[9]
            var ex: Float64
            var ey: Float64
            if abs(dx) > abs(dy):
                ex = c2x + st.stack[10]
                ey = y0
            else:
                ex = x0
                ey = c2y + st.stack[10]
            st.curve_to(
                c1x - st.x, c1y - st.y, c2x - c1x, c2y - c1y, ex - c2x, ey - c2y
            )
        st.stack.clear()
    elif op == 9:
        if n >= 1:
            st.stack[n - 1] = abs(st.stack[n - 1])
    elif op == 10:
        if n >= 2:
            var b = st.stack.pop()
            st.stack[n - 2] = st.stack[n - 2] + b
    elif op == 11:
        if n >= 2:
            var b = st.stack.pop()
            st.stack[n - 2] = st.stack[n - 2] - b
    elif op == 12:
        if n >= 2:
            var b = st.stack.pop()
            st.stack[n - 2] = st.stack[n - 2] / b if b != 0.0 else 0.0
    elif op == 14:
        if n >= 1:
            st.stack[n - 1] = -st.stack[n - 1]
    elif op == 18:
        if n >= 1:
            _ = st.stack.pop()
    elif op == 20:
        if n >= 2:
            var j = Int(st.stack.pop())
            var v = st.stack.pop()
            if j >= 0 and j < 32:
                st.trans[j] = v
    elif op == 21:
        if n >= 1:
            var j = Int(st.stack.pop())
            st.stack.append(st.trans[j] if (j >= 0 and j < 32) else 0.0)
    elif op == 24:
        if n >= 2:
            var b = st.stack.pop()
            st.stack[n - 2] = st.stack[n - 2] * b
    elif op == 26:
        if n >= 1:
            st.stack[n - 1] = sqrt(abs(st.stack[n - 1]))
    elif op == 27:
        if n >= 1:
            st.stack.append(st.stack[n - 1])
    elif op == 28:
        if n >= 2:
            var a = st.stack[n - 2]
            st.stack[n - 2] = st.stack[n - 1]
            st.stack[n - 1] = a
    else:
        raise Error(String("cff: unsupported escaped operator 12 ", op))


def _interpret(
    data: List[UInt8],
    start: Int,
    end: Int,
    gsubrs: List[Int],
    lsubrs: List[Int],
) raises -> _Type2State:
    """Run one program to completion and return the state, outline
    included. `endchar` composition leaves a -1 marker at the end of
    `contour_ends` and the four operands in the transient array for
    `_cff_glyph_outline` to resolve; it needs the charset, which the
    bytes alone do not carry.
    """
    var st = _Type2State()
    _run(data, start, end, gsubrs, lsubrs, st, 0)
    st.close_contour()
    return st^


def _cff_glyph_outline(
    cff: _CffFont, data: List[UInt8], glyph_index: Int, depth: Int
) raises -> RawGlyphOutline:
    """Glyph `glyph_index`'s outline: its charstring interpreted, plus
    the base and accent glyphs an `endchar` composition names."""
    if depth > 4:
        raise Error("cff: seac nesting too deep")
    if glyph_index < 0 or glyph_index + 1 >= len(cff.charstrings):
        raise Error(String("cff: glyph index ", glyph_index, " out of range"))
    var st = _interpret(
        data,
        cff.charstrings[glyph_index],
        cff.charstrings[glyph_index + 1],
        cff.gsubrs,
        cff.local_subrs(glyph_index),
    )
    var outline = st.outline.copied()
    var n_ends = len(outline.contour_ends)
    if n_ends > 0 and outline.contour_ends[n_ends - 1] == -1:
        _ = outline.contour_ends.pop()
        var adx = st.trans[0]
        var ady = st.trans[1]
        var bchar = Int(st.trans[2])
        var achar = Int(st.trans[3])
        var base_gid = cff.gid_for_sid(_standard_encoding_sid(bchar))
        var accent_gid = cff.gid_for_sid(_standard_encoding_sid(achar))
        var base = _cff_glyph_outline(cff, data, base_gid, depth + 1)
        var accent = _cff_glyph_outline(cff, data, accent_gid, depth + 1)
        _append_outline(outline, base, 0, 0)
        _append_outline(outline, accent, round_to_int(adx), round_to_int(ady))
    return outline^


def _append_outline(
    mut into: RawGlyphOutline, part: RawGlyphOutline, dx: Int, dy: Int
):
    var offset = len(into.points_x)
    for i in range(len(part.points_x)):
        into.points_x.append(part.points_x[i] + dx)
        into.points_y.append(part.points_y[i] + dy)
        into.on_curve.append(part.on_curve[i])
    for e in part.contour_ends:
        into.contour_ends.append(e + offset)
