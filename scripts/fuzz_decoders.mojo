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

The mutations are deliberately dumb: bit flips, byte overwrites with
random and edge values, truncation, block duplication and deletion,
appended bytes, and stacks of those. They find truncation and
offset-check bugs, which is what a fresh parser usually has. A
mutation that survives a length field or a checksum needs to know
where those are, and that structure-aware pass is the second half of
#430, not this file.
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
        var description = _mutate(data, rng)
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
