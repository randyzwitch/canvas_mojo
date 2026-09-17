"""Mutation fuzzer for the parsers that read bytes from outside the
process: `decode_png`, `decode_jpeg`, `read_bmp`, `inflate` and the
font parsers behind `TTFFace` (TrueType and CFF) and
`font_discovery` (#430).

A hand-written rejection test covers the malformation its author
thought of; this covers the ones nobody did. Mojo has no
coverage-guided fuzzer, so this is a mutation campaign with a time
box: take a seed file, damage it a little, hand it to the decoder
inside a `try`, repeat. A clean return or a clean `raise` is a pass.
Anything else is a finding: a crash (a checked `List` index past the
end aborts the process; an unsafe read past a buffer faults once it
reaches an unmapped page), a hang, or an allocation bomb. Those kill
the process rather than the iteration, which fixes the protocol:

- Every case is written to `case_path` *before* it is decoded, with
  a sidecar `case_path + ".txt"` naming the seed, the mutation and
  the RNG state, so whatever killed the process is on disk for
  `scripts/fuzz.sh` to collect and for a person to replay.
- A batch that finishes deletes both files and prints one summary
  line. `scripts/fuzz.sh` runs batches under `timeout` and
  `ulimit -v`, so a hang and an allocation bomb also leave the case
  behind, with a distinctive exit status.

Usage, normally through `pixi run fuzz` (see `scripts/fuzz.sh`):

    fuzz_decoders batch <decoder> <seed-dir> <case-path> <iterations> <rng-seed>
    fuzz_decoders one <decoder> <file>

`<decoder>` is one of `png`, `jpeg`, `bmp`, `deflate`, `font`. Seeds
are the files in `<seed-dir>` with that decoder's extensions; for
`deflate` any file is a seed, since the harness compresses it with
this package's own `deflate` to get a valid stream. `one` decodes a
single file and reports, which is how a collected finding is
replayed and how a fixture under `tests/fuzz/` was first confirmed.

Two kinds of mutation, each half the time. The dumb ones -- bit
flips, byte overwrites with random and edge values, truncation, block
duplication and deletion, appended bytes, and stacks of those -- find
truncation and offset-check bugs, which is what a fresh parser usually
has. The structure-aware ones know where a format keeps its lengths,
checksums and counts, since a dumb mutation of a PNG mostly dies at
the next CRC: they rewrite a chunk and recompute its CRC, an edge
value into a JPEG frame or table header, a table offset or a glyph
count in a font, and so reach the code past the first check.
"""

from std.os import listdir, remove
from std.os.path import isdir
from std.sys import argv
from std.time import perf_counter_ns

from canvas.io.bmp import read_bmp
from canvas.io.deflate import deflate, inflate
from canvas.io.jpeg import decode_jpeg
from canvas.io.png import decode_png
from canvas.text.font_discovery import _parse_font_file
from canvas.text.ttf import TTFFace


# --- A small RNG of our own, so a case replays from its seed on any
# Mojo version -------------------------------------------------------------


struct _Rng(Movable):
    """xorshift64*: enough for choosing offsets and values, and its
    whole state is one number a sidecar can record."""

    var state: UInt64

    def __init__(out self, seed: UInt64):
        # The generator's only fixed point is zero.
        self.state = seed if seed != 0 else 0x9E3779B97F4A7C15

    def next(mut self) -> UInt64:
        var x = self.state
        x ^= x >> 12
        x ^= x << 25
        x ^= x >> 27
        self.state = x
        return x * 0x2545F4914F6CDD1D

    def below(mut self, n: Int) -> Int:
        """A value in [0, n); 0 when n is not positive."""
        if n <= 0:
            return 0
        return Int(self.next() % UInt64(n))

    def byte(mut self) -> UInt8:
        return UInt8(self.next() & 0xFF)


# --- Mutations -------------------------------------------------------------


def _edge_values() -> List[Int]:
    """Values a length or count field is most often wrong by: the
    ends of each field width, and the sign bit."""
    var v: List[Int] = [
        0,
        1,
        0x7F,
        0x80,
        0xFF,
        0x7FFF,
        0x8000,
        0xFFFF,
        0x7FFFFFFF,
        0x80000000,
        0xFFFFFFFF,
    ]
    return v^


def _flip_bits(mut data: List[UInt8], mut rng: _Rng) -> String:
    if len(data) == 0:
        return "flip_bits (empty)"
    var n = 1 + rng.below(8)
    for _ in range(n):
        var at = rng.below(len(data))
        data[at] ^= UInt8(1) << UInt8(rng.below(8))
    return String("flip_bits n=", n)


def _overwrite_bytes(mut data: List[UInt8], mut rng: _Rng) -> String:
    if len(data) == 0:
        return "overwrite_bytes (empty)"
    var n = 1 + rng.below(16)
    for _ in range(n):
        data[rng.below(len(data))] = rng.byte()
    return String("overwrite_bytes n=", n)


def _write_edge(mut data: List[UInt8], mut rng: _Rng) -> String:
    """An edge value at a random offset, in one of the field widths a
    format uses, in either byte order."""
    if len(data) == 0:
        return "write_edge (empty)"
    var values = _edge_values()
    var value = values[rng.below(len(values))]
    var width = 1 << rng.below(3)  # 1, 2 or 4 bytes
    var at = rng.below(len(data))
    var big_endian = rng.below(2) == 0
    for k in range(width):
        var pos = at + k
        if pos >= len(data):
            break
        var shift = (width - 1 - k) * 8 if big_endian else k * 8
        data[pos] = UInt8((value >> shift) & 0xFF)
    return String(
        "write_edge value=",
        value,
        " width=",
        width,
        " at=",
        at,
        " big_endian=",
        big_endian,
    )


def _truncate(mut data: List[UInt8], mut rng: _Rng) -> String:
    if len(data) == 0:
        return "truncate (empty)"
    var keep = rng.below(len(data))
    data.resize(keep, 0)
    return String("truncate keep=", keep)


def _duplicate_block(mut data: List[UInt8], mut rng: _Rng) -> String:
    if len(data) < 2:
        return "duplicate_block (too short)"
    var length = 1 + rng.below(min(len(data), 4096))
    var src = rng.below(len(data) - length + 1)
    var dst = rng.below(len(data) + 1)
    var block = List[UInt8](capacity=length)
    for k in range(length):
        block.append(data[src + k])
    var result = List[UInt8](capacity=len(data) + length)
    for k in range(dst):
        result.append(data[k])
    for k in range(length):
        result.append(block[k])
    for k in range(dst, len(data)):
        result.append(data[k])
    data = result^
    return String("duplicate_block src=", src, " len=", length, " at=", dst)


def _delete_block(mut data: List[UInt8], mut rng: _Rng) -> String:
    if len(data) < 2:
        return "delete_block (too short)"
    var length = 1 + rng.below(min(len(data) - 1, 4096))
    var at = rng.below(len(data) - length + 1)
    var result = List[UInt8](capacity=len(data) - length)
    for k in range(at):
        result.append(data[k])
    for k in range(at + length, len(data)):
        result.append(data[k])
    data = result^
    return String("delete_block at=", at, " len=", length)


def _append_bytes(mut data: List[UInt8], mut rng: _Rng) -> String:
    var n = 1 + rng.below(256)
    for _ in range(n):
        data.append(rng.byte())
    return String("append_bytes n=", n)


comptime _SINGLE_MUTATIONS = 7


def _mutate_once(mut data: List[UInt8], mut rng: _Rng, which: Int) -> String:
    if which == 0:
        return _flip_bits(data, rng)
    if which == 1:
        return _overwrite_bytes(data, rng)
    if which == 2:
        return _write_edge(data, rng)
    if which == 3:
        return _truncate(data, rng)
    if which == 4:
        return _duplicate_block(data, rng)
    if which == 5:
        return _delete_block(data, rng)
    return _append_bytes(data, rng)


def _mutate(mut data: List[UInt8], mut rng: _Rng) -> String:
    """One mutation, or a stack of two to four, chosen uniformly."""
    var which = rng.below(_SINGLE_MUTATIONS + 1)
    if which < _SINGLE_MUTATIONS:
        return _mutate_once(data, rng, which)
    var n = 2 + rng.below(3)
    var description = String("stack[")
    for k in range(n):
        if k > 0:
            description += "; "
        description += _mutate_once(data, rng, rng.below(_SINGLE_MUTATIONS))
    return description + "]"


# --- Structure-aware mutations ---------------------------------------------
#
# Each parses just enough of the format to find the fields a dumb
# mutation cannot reach past, and leaves everything else as it was.
# A file the parser here cannot make sense of falls back to a dumb
# mutation, so a mutated seed keeps mutating.


def _u16be(data: List[UInt8], i: Int) -> Int:
    if i + 2 > len(data):
        return 0
    return (Int(data[i]) << 8) | Int(data[i + 1])


def _u32be(data: List[UInt8], i: Int) -> Int:
    if i + 4 > len(data):
        return 0
    return (
        (Int(data[i]) << 24)
        | (Int(data[i + 1]) << 16)
        | (Int(data[i + 2]) << 8)
        | Int(data[i + 3])
    )


def _put_be(mut data: List[UInt8], i: Int, value: Int, width: Int):
    for k in range(width):
        if i + k < len(data):
            data[i + k] = UInt8((value >> ((width - 1 - k) * 8)) & 0xFF)


def _put_le(mut data: List[UInt8], i: Int, value: Int, width: Int):
    for k in range(width):
        if i + k < len(data):
            data[i + k] = UInt8((value >> (k * 8)) & 0xFF)


def _edge_or_random(mut rng: _Rng, width: Int) -> Int:
    """An edge value for a field `width` bytes wide, or a random one."""
    if rng.below(3) == 0:
        return rng.below(1 << (8 * width))
    var values = _edge_values()
    return values[rng.below(len(values))] & ((1 << (8 * width)) - 1)


def _crc32(data: List[UInt8], start: Int, end: Int) -> Int:
    """PNG's CRC-32 over `data[start:end]`, ISO 3309 as the spec
    gives it, so a rewritten chunk still passes the decoder's check."""
    var crc = 0xFFFFFFFF
    for i in range(start, end):
        crc ^= Int(data[i])
        for _ in range(8):
            if crc & 1:
                crc = (crc >> 1) ^ 0xEDB88320
            else:
                crc >>= 1
    return crc ^ 0xFFFFFFFF


struct _Chunk(Copyable, ImplicitlyCopyable, Movable):
    """One PNG chunk: where its length field sits, and its data
    length as declared."""

    var at: Int
    var length: Int

    def __init__(out self, at: Int, length: Int):
        self.at = at
        self.length = length


def _png_chunks(data: List[UInt8]) -> List[_Chunk]:
    var chunks = List[_Chunk]()
    var at = 8
    while at + 12 <= len(data):
        var length = _u32be(data, at)
        if at + 12 + length > len(data):
            break
        chunks.append(_Chunk(at, length))
        at += 12 + length
    return chunks^


def _png_fix_crc(mut data: List[UInt8], chunk: _Chunk):
    var start = chunk.at + 4
    var end = start + 4 + chunk.length
    if end + 4 <= len(data):
        _put_be(data, end, _crc32(data, start, end), 4)


def _mutate_png(mut data: List[UInt8], mut rng: _Rng) -> String:
    var chunks = _png_chunks(data)
    if len(chunks) == 0:
        return _mutate(data, rng)
    var c = chunks[rng.below(len(chunks))]
    var which = rng.below(6)
    if which == 0 and c.length > 0:
        # A byte of the chunk's data, CRC repaired: inside IHDR that
        # is a header field, inside IDAT it is the deflate stream.
        var n = 1 + rng.below(4)
        for _ in range(n):
            data[c.at + 8 + rng.below(c.length)] = rng.byte()
        _png_fix_crc(data, c)
        return String(
            "png: ", n, " data byte(s) of chunk at ", c.at, ", crc fixed"
        )
    if which == 1 and c.length >= 4:
        # An edge value into a four-byte field of the data: IHDR's
        # width or height, a PLTE entry, an IDAT block header.
        var field = rng.below(c.length - 3)
        var width = 1 << rng.below(3)
        if field + width > c.length:
            width = 1
        var value = _edge_or_random(rng, width)
        _put_be(data, c.at + 8 + field, value, width)
        _png_fix_crc(data, c)
        return String(
            "png: edge ",
            value,
            " width ",
            width,
            " at data+",
            field,
            " of chunk at ",
            c.at,
            ", crc fixed",
        )
    if which == 2:
        # The declared length, with the CRC recomputed over the new
        # extent when it still lies inside the file.
        var value = (
            _edge_or_random(rng, 4) if rng.below(2)
            == 0 else c.length + rng.below(64) - 32
        )
        if value < 0:
            value = 0
        _put_be(data, c.at, value, 4)
        var moved = _Chunk(c.at, value)
        if value <= len(data) - c.at - 12:
            _png_fix_crc(data, moved)
        return String(
            "png: chunk at ", c.at, " length ", c.length, " -> ", value
        )
    if which == 3 and len(chunks) > 1:
        # Drop the chunk.
        var result = List[UInt8](capacity=len(data))
        for i in range(c.at):
            result.append(data[i])
        for i in range(c.at + 12 + c.length, len(data)):
            result.append(data[i])
        data = result^
        return String("png: chunk at ", c.at, " deleted")
    if which == 4:
        # Duplicate the chunk in place, right after itself.
        var result = List[UInt8](capacity=len(data) + 12 + c.length)
        var end = c.at + 12 + c.length
        for i in range(end):
            result.append(data[i])
        for i in range(c.at, end):
            result.append(data[i])
        for i in range(end, len(data)):
            result.append(data[i])
        data = result^
        return String("png: chunk at ", c.at, " duplicated")
    # The chunk type: a critical chunk renamed, or a private one made
    # critical.
    var k = c.at + 4 + rng.below(4)
    data[k] = data[k] ^ 0x20 if rng.below(2) == 0 else rng.byte()
    _png_fix_crc(data, c)
    return String("png: type byte of chunk at ", c.at, " changed, crc fixed")


struct _Segment(Copyable, ImplicitlyCopyable, Movable):
    """One JPEG marker segment: the marker byte, where the marker
    sits, and its declared length (the two length bytes included)."""

    var marker: Int
    var at: Int
    var length: Int

    def __init__(out self, marker: Int, at: Int, length: Int):
        self.marker = marker
        self.at = at
        self.length = length


def _jpeg_segments(data: List[UInt8]) -> List[_Segment]:
    """The segments up to and including SOS; the entropy-coded data
    after it is not a segment."""
    var segments = List[_Segment]()
    var at = 2
    while at + 4 <= len(data):
        if data[at] != 0xFF:
            break
        var marker = Int(data[at + 1])
        if (
            marker == 0xD8
            or marker == 0x01
            or (marker >= 0xD0 and marker <= 0xD7)
        ):
            at += 2
            continue
        var length = _u16be(data, at + 2)
        if length < 2 or at + 2 + length > len(data):
            break
        segments.append(_Segment(marker, at, length))
        at += 2 + length
        if marker == 0xDA:
            break
    return segments^


def _mutate_jpeg(mut data: List[UInt8], mut rng: _Rng) -> String:
    var segments = _jpeg_segments(data)
    if len(segments) == 0:
        return _mutate(data, rng)
    var seg = segments[rng.below(len(segments))]
    var payload = seg.at + 4
    var which = rng.below(7)
    if which == 0 and seg.length > 2:
        var n = 1 + rng.below(4)
        for _ in range(n):
            data[payload + rng.below(seg.length - 2)] = rng.byte()
        return String(
            "jpeg: ", n, " byte(s) of segment ", hex(seg.marker), " at ", seg.at
        )
    if which == 1 and seg.length > 2:
        # An edge value into a field: SOF's height, width, component
        # count or sampling factors; DHT's counts; DQT's precision;
        # SOS's selectors and spectral band; DRI's interval.
        var field = rng.below(seg.length - 2)
        var width = 1 if rng.below(2) == 0 or field + 2 > seg.length - 2 else 2
        var value = _edge_or_random(rng, width)
        _put_be(data, payload + field, value, width)
        return String(
            "jpeg: edge ",
            value,
            " width ",
            width,
            " at payload+",
            field,
            " of segment ",
            hex(seg.marker),
        )
    if which == 2:
        # The declared length.
        var value = (
            _edge_or_random(rng, 2) if rng.below(2)
            == 0 else seg.length + rng.below(16) - 8
        )
        if value < 0:
            value = 0
        _put_be(data, seg.at + 2, value, 2)
        return String(
            "jpeg: segment ",
            hex(seg.marker),
            " at ",
            seg.at,
            " length ",
            seg.length,
            " -> ",
            value,
        )
    if which == 3 and seg.marker != 0xDA and len(segments) > 1:
        var result = List[UInt8](capacity=len(data))
        for i in range(seg.at):
            result.append(data[i])
        for i in range(seg.at + 2 + seg.length, len(data)):
            result.append(data[i])
        data = result^
        return String(
            "jpeg: segment ", hex(seg.marker), " at ", seg.at, " deleted"
        )
    if which == 4:
        var result = List[UInt8](capacity=len(data) + 2 + seg.length)
        var end = seg.at + 2 + seg.length
        for i in range(end):
            result.append(data[i])
        for i in range(seg.at, end):
            result.append(data[i])
        for i in range(end, len(data)):
            result.append(data[i])
        data = result^
        return String(
            "jpeg: segment ", hex(seg.marker), " at ", seg.at, " duplicated"
        )
    # Into the entropy-coded data after SOS: bytes overwritten, a
    # marker planted (FF Dx restart, FF D9 end, FF 00 stuffing), or
    # a stuffing zero removed so a stray FF reads as a marker.
    var last = segments[len(segments) - 1]
    var scan = last.at + 2 + last.length
    if last.marker != 0xDA or scan >= len(data) - 1:
        return _mutate(data, rng)
    var at = scan + rng.below(len(data) - scan - 1)
    var kind = rng.below(3)
    if kind == 0:
        data[at] = rng.byte()
        return String("jpeg: scan byte at ", at, " overwritten")
    if kind == 1:
        var markers: List[Int] = [0xD0, 0xD7, 0xD9, 0x00, 0xC4, 0xFF]
        var m = markers[rng.below(len(markers))]
        data[at] = 0xFF
        data[at + 1] = UInt8(m)
        return String(
            "jpeg: marker FF ", hex(m), " planted in the scan at ", at
        )
    for i in range(at, len(data) - 1):
        if data[i] == 0xFF and data[i + 1] == 0x00:
            data[i + 1] = rng.byte()
            return String("jpeg: stuffing byte at ", i + 1, " replaced")
    return _mutate(data, rng)


struct _Table(Copyable, ImplicitlyCopyable, Movable):
    """One sfnt table directory record: where the record sits, and
    the table's tag, offset and length as declared."""

    var record: Int
    var tag: String
    var offset: Int
    var length: Int

    def __init__(out self, record: Int, tag: String, offset: Int, length: Int):
        self.record = record
        self.tag = tag
        self.offset = offset
        self.length = length


def _font_tables(data: List[UInt8]) -> List[_Table]:
    var tables = List[_Table]()
    var base = 0
    if len(data) >= 16 and _u32be(data, 0) == 0x74746366:  # 'ttcf'
        base = _u32be(data, 12)
    var count = _u16be(data, base + 4)
    if count > 512:
        return tables^
    for i in range(count):
        var record = base + 12 + i * 16
        if record + 16 > len(data):
            break
        var tag = String()
        for k in range(4):
            tag += chr(Int(data[record + k]))
        tables.append(
            _Table(
                record, tag, _u32be(data, record + 8), _u32be(data, record + 12)
            )
        )
    return tables^


def _mutate_font(mut data: List[UInt8], mut rng: _Rng) -> String:
    var tables = _font_tables(data)
    if len(tables) == 0:
        return _mutate(data, rng)
    var t = tables[rng.below(len(tables))]
    var which = rng.below(6)
    if which == 0:
        # The record's offset or length: past the end of the file,
        # zero, or a little off so it overlaps a neighbour.
        var field = t.record + (8 if rng.below(2) == 0 else 12)
        var value = (
            _edge_or_random(rng, 4) if rng.below(2)
            == 0 else _u32be(data, field) + rng.below(64) - 32
        )
        if value < 0:
            value = 0
        _put_be(data, field, value, 4)
        return String(
            "font: ",
            t.tag,
            " record ",
            "offset" if field == t.record + 8 else "length",
            " -> ",
            value,
        )
    var inside = t.offset < len(data) and t.length > 0
    var span = min(t.length, len(data) - t.offset) if inside else 0
    if which == 1 and span > 0:
        var n = 1 + rng.below(8)
        for _ in range(n):
            data[t.offset + rng.below(span)] = rng.byte()
        return String("font: ", n, " byte(s) inside ", t.tag)
    if which == 2 and span >= 2:
        # An edge value into a two- or four-byte field of the table:
        # maxp's numGlyphs, head's indexToLocFormat, a loca entry, a
        # glyf point count or composite flag, a GPOS count, a CFF
        # INDEX count or offSize.
        var width = 2 if rng.below(3) > 0 or span < 4 else 4
        var field = rng.below(span - width + 1)
        var value = _edge_or_random(rng, width)
        _put_be(data, t.offset + field, value, width)
        return String(
            "font: edge ", value, " width ", width, " at ", t.tag, "+", field
        )
    if which == 3:
        # numTables, or a table's tag swapped with another's so the
        # parser reads one table with the other's expectations.
        if rng.below(2) == 0 or len(tables) < 2:
            var value = _edge_or_random(rng, 2)
            _put_be(data, 4, value, 2)
            return String("font: numTables -> ", value)
        var other = tables[rng.below(len(tables))]
        for k in range(4):
            var a = data[t.record + k]
            data[t.record + k] = data[other.record + k]
            data[other.record + k] = a
        return String("font: tags ", t.tag, " and ", other.tag, " swapped")
    if which == 4 and span > 0:
        # A run of the table cleared or filled, which a glyph or
        # subroutine parser reads as many zero-length or maximal items.
        var length = 1 + rng.below(min(span, 512))
        var start = t.offset + rng.below(span - length + 1)
        var fill = 0 if rng.below(2) == 0 else 0xFF
        for i in range(start, start + length):
            data[i] = UInt8(fill)
        return String("font: ", length, " bytes of ", t.tag, " set to ", fill)
    # Point the record at another table's bytes.
    if len(tables) > 1:
        var other = tables[rng.below(len(tables))]
        _put_be(data, t.record + 8, other.offset, 4)
        _put_be(data, t.record + 12, other.length, 4)
        return String("font: ", t.tag, " record aimed at ", other.tag)
    return _mutate(data, rng)


def _mutate_bmp(mut data: List[UInt8], mut rng: _Rng) -> String:
    """The header's fixed fields: file size, pixel offset, DIB size,
    width, height, planes, bit depth, compression, image size."""
    if len(data) < 54:
        return _mutate(data, rng)
    var fields: List[Int] = [2, 10, 14, 18, 22, 26, 28, 30, 34]
    var widths: List[Int] = [4, 4, 4, 4, 4, 2, 2, 4, 4]
    var k = rng.below(len(fields))
    var value = _edge_or_random(rng, widths[k])
    if widths[k] == 4 and rng.below(2) == 0:
        # A negative height is the top-down flag; other negatives are
        # what a signed read of an edge value gives.
        value = (1 << 32) - 1 - rng.below(4096)
    _put_le(data, fields[k], value, widths[k])
    return String("bmp: header field at ", fields[k], " -> ", value)


def _mutate_deflate(mut data: List[UInt8], mut rng: _Rng) -> String:
    """The block header and the code-length tables are the first few
    dozen bytes of a stream; bit flips concentrated there reach the
    table construction, where dumb flips spread over the whole stream
    mostly land in literal data."""
    if len(data) == 0:
        return _mutate(data, rng)
    var head = min(len(data), 48)
    var n = 1 + rng.below(4)
    for _ in range(n):
        var at = rng.below(head)
        data[at] ^= UInt8(1) << UInt8(rng.below(8))
    return String(
        "deflate: ", n, " bit(s) flipped in the first ", head, " bytes"
    )


def _mutate_for(
    decoder: String, mut data: List[UInt8], mut rng: _Rng
) -> String:
    """Half the time a structure-aware mutation for `decoder`, the
    rest a dumb one; both are described for the sidecar."""
    if rng.below(2) == 0:
        return _mutate(data, rng)
    if decoder == "png":
        return _mutate_png(data, rng)
    if decoder == "jpeg":
        return _mutate_jpeg(data, rng)
    if decoder == "font":
        return _mutate_font(data, rng)
    if decoder == "bmp":
        return _mutate_bmp(data, rng)
    if decoder == "deflate":
        return _mutate_deflate(data, rng)
    return _mutate(data, rng)


# --- Decoders --------------------------------------------------------------


def _decode(decoder: String, path: String) raises:
    """Run one decoder over the file at `path`, reaching past the
    header into the parts a real caller reaches. A `raise` here is
    the decoder rejecting the file, which is a pass; the caller
    catches it."""
    if decoder == "png":
        var f = open(path, "r")
        var data = f.read_bytes()
        f.close()
        var image = decode_png(data^)
        _ = image.get_pixel(0, 0)
    elif decoder == "jpeg":
        var f = open(path, "r")
        var data = f.read_bytes()
        f.close()
        var image = decode_jpeg(data^)
        _ = image.get_pixel(0, 0)
    elif decoder == "bmp":
        var image = read_bmp(path)
        _ = image.get_pixel(0, 0)
    elif decoder == "deflate":
        var f = open(path, "r")
        var data = f.read_bytes()
        f.close()
        var plain = inflate(data^)
        _ = len(plain)
    elif decoder == "font":
        # What discovery does to every file on the machine, then what
        # a text call does to the one it picked: outlines, advances,
        # a kern pair and a few code point lookups. Outlines are
        # sampled, since a CJK face has tens of thousands.
        _ = len(_parse_font_file(path))
        var face = TTFFace(path)
        var n = face.num_glyphs
        var step = 1 if n <= 512 else n // 512
        var g = 0
        var prev = 0
        while g < n:
            var outline = face.glyph_outline(g)
            _ = len(outline.points_x)
            _ = face.advance_width(g)
            _ = face.kern_adjustment(prev, g)
            prev = g
            g += step
        var codepoints: List[Int] = [0x41, 0x61, 0x20, 0x2603, 0x5B57, 0x1F600]
        for cp in codepoints:
            _ = face.glyph_index_for_codepoint(cp)
    else:
        raise Error(String("fuzz_decoders: unknown decoder '", decoder, "'"))


def _seed_ok(decoder: String, name: String) -> Bool:
    var lower = name.lower()
    if decoder == "png":
        return lower.endswith(".png")
    if decoder == "jpeg":
        return lower.endswith(".jpg") or lower.endswith(".jpeg")
    if decoder == "bmp":
        return lower.endswith(".bmp")
    if decoder == "font":
        return (
            lower.endswith(".ttf")
            or lower.endswith(".otf")
            or lower.endswith(".ttc")
        )
    return True


def _seeds(decoder: String, source: String) raises -> List[String]:
    var paths = List[String]()
    if isdir(source):
        for entry in listdir(source):
            if _seed_ok(decoder, entry):
                paths.append(source + "/" + entry)
    elif _seed_ok(decoder, source):
        paths.append(source)
    if len(paths) == 0:
        raise Error(
            String("fuzz_decoders: no seeds for '", decoder, "' in ", source)
        )
    return paths^


def _read_seed(decoder: String, path: String) raises -> List[UInt8]:
    var f = open(path, "r")
    var data = f.read_bytes()
    f.close()
    if decoder == "deflate":
        # Any file is a deflate seed once compressed; cap the input so
        # an iteration stays cheap.
        if len(data) > 262144:
            data.resize(262144, 0)
        return deflate(data)
    return data^


def _write(path: String, data: List[UInt8]) raises:
    var f = open(path, "w")
    f.write_bytes(Span(data))
    f.close()


def _write_text(path: String, text: String) raises:
    var f = open(path, "w")
    f.write(text)
    f.close()


def _remove(path: String):
    try:
        remove(path)
    except:
        pass


# --- Entry points ----------------------------------------------------------


def _one(decoder: String, path: String) raises:
    var t0 = perf_counter_ns()
    var outcome = String("ok")
    try:
        _decode(decoder, path)
    except e:
        outcome = String("raised: ", e)
    var us = (perf_counter_ns() - t0) // 1000
    print(decoder, path, outcome, String("(", us, " us)"))


def _batch(
    decoder: String,
    seed_dir: String,
    case_path: String,
    iterations: Int,
    rng_seed: Int,
) raises:
    var seeds = _seeds(decoder, seed_dir)
    var rng = _Rng(UInt64(rng_seed))
    var raised = 0
    var accepted = 0
    var messages = Dict[String, Int]()
    var t0 = perf_counter_ns()
    for i in range(iterations):
        var seed_path = seeds[rng.below(len(seeds))]
        var data = _read_seed(decoder, seed_path)
        var state_before = rng.state
        var description = _mutate_for(decoder, data, rng)
        # On disk before the decoder sees it: if the decoder kills the
        # process, this is what the driver collects.
        _write(case_path, data)
        _write_text(
            case_path + ".txt",
            String(
                "decoder: ",
                decoder,
                "\nseed: ",
                seed_path,
                "\niteration: ",
                i,
                "\nrng_seed: ",
                rng_seed,
                "\nrng_state_before_mutation: ",
                state_before,
                "\nmutation: ",
                description,
                "\nbytes: ",
                len(data),
                "\n",
            ),
        )
        try:
            _decode(decoder, case_path)
            accepted += 1
        except e:
            raised += 1
            # The message up to its first number, so "at offset 1234"
            # and "at offset 99" count as one kind of rejection.
            var msg = String(e)
            var cut = len(msg.as_bytes())
            var bytes = msg.as_bytes()
            for k in range(len(bytes)):
                if bytes[k] >= 0x30 and bytes[k] <= 0x39:
                    cut = k
                    break
            var key = String(msg[byte=0:cut])
            messages[key] = messages.get(key, 0) + 1
    _remove(case_path)
    _remove(case_path + ".txt")
    var seconds = Float64(perf_counter_ns() - t0) / 1e9
    print(
        "batch",
        decoder,
        "iterations=",
        iterations,
        "raised=",
        raised,
        "accepted=",
        accepted,
        "distinct_rejections=",
        len(messages),
        "seeds=",
        len(seeds),
        "seconds=",
        seconds,
    )
    for entry in messages.items():
        print("  ", entry.value, "x", entry.key)


def main() raises:
    var args = argv()
    if len(args) >= 4 and String(args[1]) == "one":
        _one(String(args[2]), String(args[3]))
        return
    if len(args) >= 7 and String(args[1]) == "batch":
        _batch(
            String(args[2]),
            String(args[3]),
            String(args[4]),
            Int(String(args[5])),
            Int(String(args[6])),
        )
        return
    raise Error(
        "usage: fuzz_decoders batch <decoder> <seed-dir> <case-path>"
        " <iterations> <rng-seed> | one <decoder> <file>"
    )
